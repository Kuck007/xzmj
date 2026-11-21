//
//  SyncLogger.swift
//  杏子美甲管理系统
//
//  冲突与异常日志：按月追加 JSONL，便于追溯“为什么这条记录最后是这个值”。
//  不记录密码、密钥、完整照片内容。
//

import Foundation

struct SyncConflictEntry: Codable {
    var at: Double
    var entity: String
    var uuid: String
    /// keptLocal / appliedRemote / blocked
    var resolution: String
    var localVersion: SyncVersion?
    var incomingVersion: SyncVersion?
    var detail: String?
}

enum SyncConflictLogger {

    static func log(_ entry: SyncConflictEntry) {
        let fm = FileManager.default
        var dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xzmj", isDirectory: true)
            .appendingPathComponent("conflicts", isDirectory: true)
        #if DEBUG
        dir.appendPathComponent("Debug", isDirectory: true)
        #endif
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        let file = dir.appendingPathComponent("\(formatter.string(from: Date())).jsonl")

        guard let data = try? SyncCodec.encode(entry) else { return }
        var line = data
        line.append(0x0A)

        if fm.fileExists(atPath: file.path), let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file, options: .atomic)
        }
    }

    static func recordConflict(entity: SyncEntity,
                               uuid: UUID,
                               local: SyncVersion?,
                               incoming: SyncVersion,
                               detail: String) {
        log(SyncConflictEntry(at: Date().timeIntervalSince1970,
                              entity: entity.rawValue,
                              uuid: uuid.uuidString,
                              resolution: "keptLocal",
                              localVersion: local,
                              incomingVersion: incoming,
                              detail: detail))
    }

    static func blocked(entity: SyncEntity, uuid: UUID, incoming: SyncVersion, detail: String) {
        log(SyncConflictEntry(at: Date().timeIntervalSince1970,
                              entity: entity.rawValue,
                              uuid: uuid.uuidString,
                              resolution: "blocked",
                              localVersion: nil,
                              incomingVersion: incoming,
                              detail: detail))
    }

    /// 整包级别失败（下载/校验/解密/应用），uuid 用全 0 占位。
    static func packageFailure(changeId: String, detail: String) {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        log(SyncConflictEntry(at: Date().timeIntervalSince1970,
                              entity: "package",
                              uuid: zero.uuidString,
                              resolution: "blocked",
                              localVersion: nil,
                              incomingVersion: nil,
                              detail: "\(changeId)：\(detail)"))
    }
}

// MARK: - 性能日志

/// 合并 / 下载各阶段耗时日志：同时打印到控制台并追加到 `sync[/Debug]/perf.log`。
/// 每次合并开始时清空，便于定位“合并到底慢在哪一步”。
enum SyncPerf {
    private static let fm = FileManager.default
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static var fileURL: URL {
        var dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xzmj/sync", isDirectory: true)
        #if DEBUG
        dir.appendPathComponent("Debug", isDirectory: true)
        #endif
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("perf.log")
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func log(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        print("[SYNC-PERF] \(message)")
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 包裹一段异步工作并记录耗时。
    static func measure<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        let start = Date()
        let result = try await work()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        log("\(label) \(ms)ms")
        return result
    }
}
