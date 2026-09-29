//
//  SecurityManager.swift
//  杏子美甲管理系统
//

import Foundation
import CryptoKit
import Security

/// 密码与安全问题管理（本地存储，SHA256 哈希）
final class SecurityManager {
    static let shared = SecurityManager()
    private let defaults = UserDefaults.standard

    private let passwordKey = "security.passwordHash"
    private let questionsKey = "security.questions"      // [[String]] 3个问题的文本
    private let answersKey = "security.answersHash"      // [String] 3个答案的哈希
    private let lastBackupKey = "backup.lastDate"        // 上次成功备份时间（主动备份）
    private let lastAutoBackupKey = "backup.lastAutoDate" // 上次自动兜底备份时间
    private let autoBackupDaysKey = "backup.autoDays"     // 自动备份周期（天），默认 15
    private let customBackupDirKey = "backup.customDirectory" // 自定义备份目录（空 = 默认 Application Support/xzmj/Backups）
    private let appNameKey = "app.displayName"            // 应用显示名称，默认 "杏子美甲管理系统"

    /// 备份提醒阈值：超过这个天数没备份就提醒（15 天一次，既防止忘记手动备份、也不会过于频繁）
    let backupReminderDays: TimeInterval = 15 * 24 * 3600

    /// 自动兜底备份间隔（秒），用户可配置 1-99 天，默认 15 天
    var autoBackupInterval: TimeInterval {
        let days = defaults.object(forKey: autoBackupDaysKey) as? Int ?? 15
        return TimeInterval(days) * 24 * 3600
    }

    /// 自动备份周期（天），用于设置界面显示
    var autoBackupDays: Int {
        get { defaults.object(forKey: autoBackupDaysKey) as? Int ?? 15 }
        set {
            let clamped = max(1, min(99, newValue))
            defaults.set(clamped, forKey: autoBackupDaysKey)
        }
    }

    /// 自定义备份目录（nil/空 = 使用默认 Application Support/xzmj/Backups）
    var customBackupDirectory: String? {
        get {
            let v = defaults.string(forKey: customBackupDirKey) ?? ""
            return v.isEmpty ? nil : v
        }
        set {
            if let v = newValue, !v.isEmpty {
                defaults.set(v, forKey: customBackupDirKey)
            } else {
                defaults.removeObject(forKey: customBackupDirKey)
            }
        }
    }

    // MARK: - WebDAV 网络备份（多服务器，macOS 分栏式设置）
    // 服务器列表（不含密码）存 UserDefaults JSON；每台密码独立存钥匙串（account = 服务器 id）
    // 旧版单台配置（backup.webdav.url 等）首次访问自动迁移为第一台服务器

    private static let webDAVServersKey = "backup.webdav.servers"
    private static let webDAVKeychainService = "com.kuck.nail.webdav"

    /// 全部 WebDAV 服务器（不含密码；密码按 id 走钥匙串）
    var webDAVServers: [WebDAVServerConfig] {
        get {
            Self.migrateLegacyWebDAVIfNeeded()
            guard let data = defaults.data(forKey: Self.webDAVServersKey) else { return [] }
            return (try? JSONDecoder().decode([WebDAVServerConfig].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.webDAVServersKey)
            }
        }
    }

    /// 保存服务器列表（增删改统一入口）
    func saveWebDAVServers(_ servers: [WebDAVServerConfig]) {
        webDAVServers = servers
    }

    /// 服务器数量（仅读 UserDefaults，不触发钥匙串访问——供设置主菜单行显示，避免进设置就弹授权）
    var webDAVServerCount: Int {
        if let data = defaults.data(forKey: Self.webDAVServersKey),
           let list = try? JSONDecoder().decode([WebDAVServerConfig].self, from: data) {
            return list.count
        }
        if defaults.string(forKey: "backup.webdav.url") != nil { return 1 } // 旧单台配置
        return 0
    }

    /// 某台服务器的密码（钥匙串，account = 服务器 id）
    nonisolated static func webDAVPassword(for id: UUID) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webDAVKeychainService,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 写入/覆盖某台服务器密码（nil 或空串 = 删除）
    nonisolated static func setWebDAVPassword(_ password: String?, for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webDAVKeychainService,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
        guard let v = password, !v.isEmpty else { return }
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webDAVKeychainService,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: Data(v.utf8)
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    /// 供后台网络层读取某台服务器的凭据（nonisolated：UserDefaults + Keychain 均线程安全）。
    /// 未填地址返回 nil。
    nonisolated static func webDAVCredentials(for server: WebDAVServerConfig) -> (url: String, username: String, password: String, remoteDir: String)? {
        let url = server.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let dir = server.remoteDir.trimmingCharacters(in: .whitespacesAndNewlines)
        return (url, server.username, webDAVPassword(for: server.id) ?? "",
                dir.isEmpty ? defaultWebDAVDir() : dir)
    }

    /// 默认远程目录：当前应用显示名称（登录页标题）/backups，特殊字符过滤
    nonisolated static func defaultWebDAVDir() -> String {
        let name = UserDefaults.standard.string(forKey: "app.displayName") ?? "杏子美甲管理系统"
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined()
        return "\(safe)/backups"
    }

    /// 迁移旧版单台配置（backup.webdav.url/username/remoteDir + 钥匙串 backup 账号）→ 第一台服务器
    nonisolated static func migrateLegacyWebDAVIfNeeded() {
        let d = UserDefaults.standard
        let serversKey = "backup.webdav.servers"
        guard d.data(forKey: serversKey) == nil else { return } // 已有新列表，跳过
        let oldURL = d.string(forKey: "backup.webdav.url") ?? ""
        guard !oldURL.isEmpty else { return }                   // 旧配置不存在，跳过
        let id = UUID()
        let server = WebDAVServerConfig(id: id,
                                        name: host(from: oldURL),
                                        url: oldURL,
                                        username: d.string(forKey: "backup.webdav.username") ?? "",
                                        remoteDir: d.string(forKey: "backup.webdav.remoteDir") ?? "")
        // 挪钥匙串旧密码（旧 account = "backup"）到新 id
        let oldService = "com.kuck.nail.webdav"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldService,
            kSecAttrAccount as String: "backup",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let pwd = String(data: data, encoding: .utf8) {
            setWebDAVPassword(pwd, for: id)
        }
        // 写新列表，清旧 key 与旧钥匙串
        if let data = try? JSONEncoder().encode([server]) { d.set(data, forKey: serversKey) }
        d.removeObject(forKey: "backup.webdav.url")
        d.removeObject(forKey: "backup.webdav.username")
        d.removeObject(forKey: "backup.webdav.remoteDir")
        var delQ: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldService,
            kSecAttrAccount as String: "backup"
        ]
        SecItemDelete(delQ as CFDictionary)
    }

    /// 从地址提取主机名作服务器显示名
    private nonisolated static func host(from url: String) -> String {
        let s = url.replacingOccurrences(of: "https://", with: "")
                     .replacingOccurrences(of: "http://", with: "")
        return s.split(separator: "/").first.map(String.init) ?? s
    }

    /// 应用显示名称（登录页大标题）
    var appDisplayName: String {
        get { defaults.string(forKey: appNameKey) ?? "杏子美甲管理系统" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? "杏子美甲管理系统" : trimmed, forKey: appNameKey)
        }
    }

    /// 侧边栏主标题（短名称）
    var appSidebarTitle: String {
        get { defaults.string(forKey: "app.sidebarTitle") ?? "杏子美甲" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? "杏子美甲" : trimmed, forKey: "app.sidebarTitle")
        }
    }

    /// 侧边栏副标题
    var appSidebarSubtitle: String {
        get { defaults.string(forKey: "app.sidebarSubtitle") ?? "店铺管理系统" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? "店铺管理系统" : trimmed, forKey: "app.sidebarSubtitle")
        }
    }

    private init() {}

    // MARK: - 备份时间记录
    /// 上次成功备份时间（nil 表示从未备份）
    var lastBackupDate: Date? {
        defaults.object(forKey: lastBackupKey) as? Date
    }

    /// 标记备份成功（导出 / 导入都算"刚做完备份"）
    func markBackupDone() {
        defaults.set(Date(), forKey: lastBackupKey)
    }

    // MARK: - 自动兜底备份时间记录（不影响主动备份提醒）

    /// 上次自动兜底备份时间（nil 表示从未自动备份）
    var lastAutoBackupDate: Date? {
        defaults.object(forKey: lastAutoBackupKey) as? Date
    }

    /// 标记自动兜底备份完成
    func markAutoBackupDone() {
        defaults.set(Date(), forKey: lastAutoBackupKey)
    }

    /// 是否需要自动兜底备份（从未自动备份 或 距离上次自动备份超过间隔）
    var needsAutoBackup: Bool {
        guard let last = lastAutoBackupDate else { return true }
        return Date().timeIntervalSince(last) >= autoBackupInterval
    }

    /// 是否需要提醒备份（从未备份 或 超过阈值）
    var needsBackupReminder: Bool {
        guard let last = lastBackupDate else { return true }
        return Date().timeIntervalSince(last) >= backupReminderDays
    }

    /// 距离上次备份的天数（用于提醒文案，nil 表示从未备份）
    var daysSinceLastBackup: Int? {
        guard let last = lastBackupDate else { return nil }
        return Int(Date().timeIntervalSince(last) / 86400)
    }

    // MARK: - 密码
    var hasPassword: Bool {
        defaults.string(forKey: passwordKey) != nil
    }

    func setPassword(_ password: String) {
        defaults.set(hash(password), forKey: passwordKey)
    }

    /// 重置系统密码和安全问题（用于首次初始化，清除残留的旧密码）
    func resetSecurityPassword() {
        defaults.removeObject(forKey: passwordKey)
        defaults.removeObject(forKey: questionsKey)
        defaults.removeObject(forKey: answersKey)
    }

    func verifyPassword(_ password: String) -> Bool {
        guard let stored = defaults.string(forKey: passwordKey) else { return false }
        return stored == hash(password)
    }

    func changePassword(oldPassword: String, newPassword: String) -> Bool {
        guard verifyPassword(oldPassword) else { return false }
        setPassword(newPassword)
        return true
    }

    // MARK: - 安全问题
    var hasSecurityQuestions: Bool {
        defaults.array(forKey: questionsKey) != nil
    }

    func setSecurityQuestions(_ questions: [String], answers: [String]) {
        defaults.set(questions, forKey: questionsKey)
        defaults.set(answers.map { hash($0.lowercased().trimmingCharacters(in: .whitespaces)) }, forKey: answersKey)
    }

    var securityQuestions: [String] {
        defaults.stringArray(forKey: questionsKey) ?? []
    }

    func verifySecurityAnswers(_ answers: [String]) -> Bool {
        guard let storedHashes = defaults.stringArray(forKey: answersKey) else { return false }
        for i in 0..<min(answers.count, storedHashes.count) {
            if hash(answers[i].lowercased().trimmingCharacters(in: .whitespaces)) != storedHashes[i] {
                return false
            }
        }
        return true
    }

    /// 用安全问题重置密码
    func resetPassword(answers: [String], newPassword: String) -> Bool {
        guard verifySecurityAnswers(answers) else { return false }
        setPassword(newPassword)
        return true
    }

    // MARK: - 哈希
    private func hash(_ text: String) -> String {
        let data = Data(text.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 自动备份加密密钥派生
    /// 自动备份使用的固定盐值（与密码哈希混合派生密钥，防止彩虹表）
    private static let autoBackupSalt = "XingziNailAutoBackup_v1"

    /// 派生自动备份加密密钥。设置了密码才返回密钥，没设置密码返回 nil（此时自动备份为明文）。
    /// 密钥 = SHA256(密码哈希 + 盐)，32 字节 = AES-256。
    /// 使用当前存储的密码派生（用于自动备份时加密）。
    func autoBackupEncryptionKey() -> SymmetricKey? {
        guard let storedHash = defaults.string(forKey: passwordKey) else { return nil }
        let combined = (storedHash + Self.autoBackupSalt).data(using: .utf8)!
        let digest = SHA256.hash(data: combined)
        return SymmetricKey(data: digest)
    }

    /// 用指定明文密码派生自动备份解密密钥（用于导入加密备份时，可能是旧密码）。
    /// 密钥 = SHA256(SHA256(密码) + 盐)，与加密时的派生方式一致。
    func autoBackupEncryptionKey(for password: String) -> SymmetricKey {
        let combined = (hash(password) + Self.autoBackupSalt).data(using: .utf8)!
        let digest = SHA256.hash(data: combined)
        return SymmetricKey(data: digest)
    }
}
