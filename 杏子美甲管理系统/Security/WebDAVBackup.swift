//
//  WebDAVBackup.swift
//  杏子美甲管理系统
//

import Foundation

/// WebDAV 地址规范化：中文输入法下容易输入全角标点（`：`、`／`、`．`），
/// 直接存入会导致 URL 解析失败。这里统一转成半角并去掉首尾空白。
enum WebDAVURLNormalizer {
    private static let replacements: [Character: Character] = [
        "：": ":",   // 全角冒号
        "／": "/",   // 全角斜杠
        "．": ".",   // 全角句点
        "。": ".",   // 中文句号
        "－": "-",   // 全角连字符
    ]

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\u{3000}", with: "") // 全角空格
        s = String(s.map { replacements[$0] ?? $0 })
        return s
    }
}

/// WebDAV 网络备份客户端（纯 URLSession + Foundation，不引第三方库）。
///
/// 职责边界：
/// - 只做网络层：上传 / 测试连接 / 列目录 / 下载
/// - 备份内容由调用方（SettingsView，MainActor）先打包 + 加密（系统密码派生密钥）再传入
/// - 凭据由调用方通过 `SecurityManager.webDAVCredentials()` 传入
/// - 所有方法 `nonisolated`，可安全在后台线程调用，不触碰 UI 与数据库
final class WebDAVBackup {
    static let shared = WebDAVBackup()
    private init() {}

    // MARK: - 上传（全量加密备份，由调用方打包加密后 PUT）

    /// 上传备份数据到远程目录，返回云端文件名与字节数
    /// - Parameter ensureDirectory: 是否在上传前逐级 MKCOL。同步引擎已确保目录存在时可传 false，
    ///   避免每次上传都对“只允许手动创建的顶层目录”发 MKCOL。
    nonisolated func upload(data: Data,
                            fileName: String,
                            url: String,
                            username: String,
                            password: String,
                            remoteDir: String,
                            ensureDirectory: Bool = true) async throws -> (name: String, size: Int) {
        let endpoint = try remoteURL(base: url, dir: remoteDir, name: fileName)
        // 上传前确保远程目录存在（幂等：已存在自动跳过，缺失自动逐级创建）
        if ensureDirectory {
            try await ensureRemoteDir(url: url, username: username, password: password, remoteDir: remoteDir)
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(authHeader(user: username, pass: password), forHTTPHeaderField: "Authorization")
        req.httpBody = data
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 403 {
                throw WebDAVError.server("上传被拒绝（403）：该账号对该目录没有写入权限，请在 NAS 上检查 WebDAV 共享目录的读写权限")
            }
            throw WebDAVError.server("上传失败（HTTP \(code)）")
        }
        return (fileName, data.count)
    }

    // MARK: - 测试连接（PROPFIND 远程目录）

    nonisolated func testConnection(url: String,
                                    username: String,
                                    password: String,
                                    remoteDir: String) async throws -> String {
        let endpoint = try remoteURL(base: url, dir: remoteDir, name: nil)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue(authHeader(user: username, pass: password), forHTTPHeaderField: "Authorization")
        req.httpBody = propfindBody(properties: ["displayname"])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw WebDAVError.network }
        switch http.statusCode {
        case 200...299:
            return "连接成功"
        case 401:
            throw WebDAVError.server("认证失败（401）：请检查用户名/密码")
        case 404:
            // 远程目录不存在：尝试在 app 内逐级自动创建（MKCOL）
            try await ensureRemoteDir(url: url, username: username, password: password, remoteDir: remoteDir)
            return "连接成功（已自动创建远程目录）"
        default:
            throw WebDAVError.server("连接失败（HTTP \(http.statusCode)）")
        }
    }

    // MARK: - 列目录（PROPFIND，解析文件条目）

    nonisolated func listBackups(url: String,
                                 username: String,
                                 password: String,
                                 remoteDir: String) async throws -> [CloudBackupItem] {
        let endpoint = try remoteURL(base: url, dir: remoteDir, name: nil)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue(authHeader(user: username, pass: password), forHTTPHeaderField: "Authorization")
        req.httpBody = propfindBody(properties: ["getcontentlength", "getlastmodified", "displayname"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WebDAVError.server("列目录失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)）")
        }
        return Self.parsePropfind(data)
    }

    // MARK: - 下载（流式 + Range 断点续传，不占内存）

    /// 断点续传下载到指定目标文件：
    /// - 目标文件已有部分内容 → 从断点续传（GET 带 Range: bytes=N-），网络闪断自动重试（最多 3 次，1s 退避）
    /// - 服务器不支持 Range（续传请求仍回 200 全量）→ 清空部分文件、从头全量下载（自动降级）
    /// - 流式逐块写磁盘，内存零占用；无数据 5 分钟才判定超时
    nonisolated func downloadToFile(name: String,
                                    url: String,
                                    username: String,
                                    password: String,
                                    remoteDir: String,
                                    to target: URL) async throws {
        let endpoint = try remoteURL(base: url, dir: remoteDir, name: name)
        let fm = FileManager.default
        var attempts = 0
        while true {
            let offset = ((try? fm.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value ?? 0
            var req = URLRequest(url: endpoint)
            req.httpMethod = "GET"
            req.setValue(authHeader(user: username, pass: password), forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 300 // 无数据 5 分钟才判定超时
            if offset > 0 {
                req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            }
            do {
                // 用下载任务落到临时文件（内核流式），不要用 AsyncBytes 逐字节 for-await：
                // 25MB 逐字节迭代实测要几分钟，curl 同样文件仅 6 秒。
                let (tempURL, resp) = try await URLSession.shared.download(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    try? fm.removeItem(at: tempURL)
                    throw WebDAVError.network
                }
                let status = http.statusCode
                // 服务器忽略 Range 且回 200 全量：从头重下（offset 归 0）
                if status == 200 && offset > 0 {
                    try? fm.removeItem(at: tempURL)
                    try? fm.removeItem(at: target)
                    continue
                }
                guard status == 206 || status == 200 else {
                    try? fm.removeItem(at: tempURL)
                    if status == 416 { return } // Range 超出文件末尾 = 已下载完整
                    throw WebDAVError.server("下载失败（HTTP \(status)）")
                }
                if offset > 0 && status == 206 {
                    // 续传：把临时文件追加到已有目标
                    guard let out = try? FileHandle(forWritingTo: target) else {
                        try? fm.removeItem(at: tempURL)
                        throw WebDAVError.server("无法写入下载文件")
                    }
                    defer { try? out.close() }
                    try out.seekToEnd()
                    let input = try FileHandle(forReadingFrom: tempURL)
                    defer { try? input.close() }
                    while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                        try out.write(contentsOf: chunk)
                    }
                    try? fm.removeItem(at: tempURL)
                } else {
                    // 全量：直接替换目标文件
                    try? fm.removeItem(at: target)
                    try fm.moveItem(at: tempURL, to: target)
                }
                return // 下载完成
            } catch is CancellationError {
                throw CancellationError() // 任务被取消，不重试
            } catch {
                attempts += 1
                if attempts >= 3 { throw error }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s 退避后从断点续传
            }
        }
    }

    // MARK: - 云端文件名（与本地自动备份命名风格一致，带时间戳天然不覆盖）

    /// WebDAV 备份文件名：应用显示名称-WebDAV备份-日期时间.json
    nonisolated static func cloudFileName() -> String {
        let name = UserDefaults.standard.string(forKey: "app.displayName") ?? "杏子美甲管理系统"
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined()
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "\(safe)-WebDAV备份-\(f.string(from: Date())).json"
    }

    // MARK: - 远程目录

    /// 确保远程目录存在：按路径**逐级** MKCOL（幂等）。
    /// 服务器语义差异（实测 fnOS / Go x/net/webdav）：
    /// - WebDAV 根 `/` 是虚拟索引，根上 MKCOL / PUT 一律 405，一级共享文件夹必须在 NAS 后台创建；
    /// - 共享文件夹内部可读写，但一次只能建一级（多级同发返回 405 而非 409）；
    /// - 对已存在目录再次 MKCOL 也返回 405。
    /// 因此这里逐级发送，405 时用 PROPFIND 验证是否已存在，存在则继续。
    nonisolated func ensureRemoteDir(url: String, username: String, password: String, remoteDir: String) async throws {
        let base = try baseURL(url)
        let parts = remoteDir.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return }
        var path = base
        for (index, part) in parts.enumerated() {
            path += "/" + part
            guard let u = URL(string: path) else { throw WebDAVError.invalidURL }
            var req = URLRequest(url: u)
            req.httpMethod = "MKCOL"
            req.setValue(authHeader(user: username, pass: password), forHTTPHeaderField: "Authorization")
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw WebDAVError.network }
            switch http.statusCode {
            case 200...299:
                continue // 201 Created 创建成功（或 200 已存在）
            case 301, 302:
                continue // 重定向，跟随
            case 405:
                // 405 有两种含义：目录已存在，或服务器（/根目录）不允许在此创建。
                // 必须用 PROPFIND 验证真伪，否则会误报"已创建"（实际目录没建成，随后上传 403/404）。
                let exists = try await dirExists(url: path, username: username, password: password)
                if exists { continue }
                if index == 0 {
                    throw WebDAVError.server("WebDAV 根目录不可写，无法自动创建第一层「\(part)」。请在 NAS 后台把「\(part)」创建为共享文件夹（或手动创建同名一级目录），再重试")
                }
                throw WebDAVError.server("无法创建目录「\(part)」：父级不存在，或服务器不允许自动创建；请先在 NAS 上手动建立该目录")
            case 401:
                throw WebDAVError.server("创建远程目录认证失败（401）：请检查用户名/密码")
            case 403:
                throw WebDAVError.server("创建远程目录被拒绝（403）：该账号没有写权限，请在 NAS 上手动创建目录")
            case 409:
                throw WebDAVError.server("创建远程目录失败（409）：父级目录不可访问")
            default:
                throw WebDAVError.server("创建远程目录失败（HTTP \(http.statusCode)）")
            }
        }
    }

    /// 检查远程路径是否存在（PROPFIND Depth:0）：2xx = 存在，404 = 不存在
    private nonisolated func dirExists(url: String,
                                       username: String,
                                       password: String) async throws -> Bool {
        guard let u = URL(string: url) else { throw WebDAVError.invalidURL }
        var req = URLRequest(url: u)
        req.httpMethod = "PROPFIND"
        req.setValue("0", forHTTPHeaderField: "Depth")
        req.setValue(authHeader(user: username, pass: password), forHTTPHeaderField: "Authorization")
        req.httpBody = propfindBody(properties: ["displayname"])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw WebDAVError.network }
        return (200...299).contains(http.statusCode)
    }

    // MARK: - 工具

    /// 规范化 base URL（去尾斜杠）
    private nonisolated func baseURL(_ base: String) throws -> String {
        // 兜底：旧配置里可能已经存了全角冒号/斜杠，连接前统一规范化
        var s = WebDAVURLNormalizer.normalize(base)
        while s.hasSuffix("/") { s.removeLast() }
        guard URL(string: s) != nil else { throw WebDAVError.invalidURL }
        return s
    }

    /// Basic 认证头：Base64(user:pass)
    private nonisolated func authHeader(user: String, pass: String) -> String {
        let raw = "\(user):\(pass)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }

    /// 拼接完整 URL：base + 远程目录 + 可选文件名，统一处理首尾斜杠
    private nonisolated func remoteURL(base: String, dir: String, name: String?) throws -> URL {
        let s = try baseURL(base)
        let dirT = dir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var path = s
        if !dirT.isEmpty { path += "/" + dirT }
        if let name = name { path += "/" + name }
        guard let url = URL(string: path) else { throw WebDAVError.invalidURL }
        return url
    }

    /// PROPFIND 请求体（DAV 命名空间）
    private nonisolated func propfindBody(properties: [String]) -> Data {
        let props = properties.map { "<d:prop><d:\($0)/></d:prop>" }.joined()
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\">\(props)</d:propfind>"
        return Data(xml.utf8)
    }

    /// 取 XML 元素本地名（去掉 "d:" / "D:" 等命名空间前缀）。
    /// XMLParser 的 elementName 是带前缀的限定名，服务器 PROPFIND 响应通常带 DAV: 命名空间前缀。
    private nonisolated static func xmlLocalName(_ qualified: String) -> String {
        if let idx = qualified.lastIndex(of: ":") {
            return String(qualified[qualified.index(after: idx)...])
        }
        return qualified
    }

    /// 解析 PROPFIND 响应 XML：只取远程目录下的文件条目（跳过目录自身与子目录）
    /// 注意：XMLParser 的 elementName 是带前缀的限定名（如 "d:response"），
    /// 必须按冒号后的本地名比较，否则服务器带命名空间前缀时全部匹配不上、列表为空。
    nonisolated private static func parsePropfind(_ data: Data) -> [CloudBackupItem] {
        final class Delegate: NSObject, XMLParserDelegate {
            var items: [CloudBackupItem] = []
            private var curHref = ""
            private var curLength = 0
            private var curModified: Date?
            private var text = ""
            private var inResponse = false

            func parser(_ parser: XMLParser,
                        didStartElement elementName: String,
                        namespaceURI: String?,
                        qualifiedName qName: String?,
                        attributes attributeDict: [String: String] = [:]) {
                if WebDAVBackup.xmlLocalName(elementName) == "response" {
                    inResponse = true
                    curHref = ""; curLength = 0; curModified = nil
                }
                text = ""
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                text += string
            }

            func parser(_ parser: XMLParser,
                        didEndElement elementName: String,
                        namespaceURI: String?,
                        qualifiedName qName: String?) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch WebDAVBackup.xmlLocalName(elementName) {
                case "href":
                    curHref = t
                case "getcontentlength":
                    curLength = Int(t) ?? 0
                case "getlastmodified":
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    f.timeZone = .gmt
                    curModified = f.date(from: t)
                case "response":
                    guard inResponse else { break }
                    // 目录条目（href 以 / 结尾）跳过，只保留文件
                    if !curHref.hasSuffix("/") {
                        // 服务器返回的文件名是 URL 百分号编码（中文 → %E6%B5%8B...），显示前解码
                        let rawName = (curHref as NSString).lastPathComponent
                        let name = rawName.removingPercentEncoding ?? rawName
                        if !name.isEmpty {
                            items.append(CloudBackupItem(id: curHref, name: name,
                                                         size: curLength, modified: curModified,
                                                         href: curHref))
                        }
                    }
                    inResponse = false
                default:
                    break
                }
                text = ""
            }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }
}

/// 一台 WebDAV 服务器的配置（不含密码；密码按 id 独立存钥匙串）
struct WebDAVServerConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var url: String = ""
    var username: String = ""
    var remoteDir: String = ""
}

/// 云端备份文件条目（列表展示用）
struct CloudBackupItem: Identifiable {
    let id: String
    let name: String
    let size: Int
    let modified: Date?
    let href: String
}

enum WebDAVError: LocalizedError {
    case invalidURL
    case network
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务器地址无效"
        case .network: return "网络请求失败，请检查网络"
        case .server(let msg): return msg
        }
    }
}
