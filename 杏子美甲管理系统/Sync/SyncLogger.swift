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

