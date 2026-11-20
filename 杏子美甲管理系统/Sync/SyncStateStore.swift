//
//  SyncStateStore.swift
//  杏子美甲管理系统
//
//  同步状态与 outbox 的本地文件读写。只做文件 I/O，不触碰 SwiftData / UI。
//  路径隔离：Debug 全部落在 sync/Debug/ 下，release 落在 sync/（见方案 §5.1、§S12）。
//

import Foundation

final class SyncStateStore {

    /// 生产路径：~/Library/Application Support/xzmj/sync[ /Debug]
    static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var root = support.appendingPathComponent("xzmj", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
        #if DEBUG
        root.appendPathComponent("Debug", isDirectory: true)
        #endif
        return root
    }

    /// 共享实例（阶段 2 起由 SyncEngine 使用）。
    static let shared = SyncStateStore(root: SyncStateStore.defaultRoot)

    let root: URL
    private let fm = FileManager.default

    init(root: URL) {
        self.root = root
    }

    // MARK: - 路径

    var stateURL: URL { root.appendingPathComponent("sync-state.json") }
    var outboxDir: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    var incomingDir: URL { root.appendingPathComponent("incoming", isDirectory: true) }
    var logURL: URL { root.appendingPathComponent("sync.log") }

    func ensureDirectories() throws {
        do {
            try fm.createDirectory(at: outboxDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: incomingDir, withIntermediateDirectories: true)
        } catch {
            throw SyncError.stateDirectoryUnavailable
        }
    }

    // MARK: - 状态

    /// 读取状态；文件不存在时返回 nil（首次启用同步）。
    func loadState() throws -> SyncState? {
        guard fm.fileExists(atPath: stateURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: stateURL)
            return try SyncCodec.decode(SyncState.self, from: data)
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.stateCorrupted(error.localizedDescription)
        }
    }

    /// 原子写：任一步失败都不会留下半个状态文件。
    func saveState(_ state: SyncState) throws {
        try ensureDirectories()
        let data = try SyncCodec.encode(state)
        do {
            try data.write(to: stateURL, options: .atomic)
        } catch {
            throw SyncError.stateDirectoryUnavailable
        }
    }

    func deleteState() throws {
        if fm.fileExists(atPath: stateURL.path) {
            try fm.removeItem(at: stateURL)
        }
    }

    // MARK: - outbox

    func outboxURL(changeId: String) -> URL {
        outboxDir.appendingPathComponent("\(changeId).json")
    }

    /// 包先落盘，再进入上传队列（见方案 §5.3）。
    func writeOutbox(_ changeSet: SyncChangeSet) throws -> URL {
        try ensureDirectories()
        let data = try SyncCodec.encode(changeSet)
        let url = outboxURL(changeId: changeSet.changeId)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SyncError.stateDirectoryUnavailable
        }
        return url
    }

    func loadOutbox(changeId: String) throws -> SyncChangeSet {
        let data = try Data(contentsOf: outboxURL(changeId: changeId))
        return try SyncCodec.decode(SyncChangeSet.self, from: data)
    }

    /// outbox 中的 changeId 列表（`pendingBatchIds` 不落盘，由此得出）。
    func listOutboxChangeIds() throws -> [String] {
        guard fm.fileExists(atPath: outboxDir.path) else { return [] }
        let names = try fm.contentsOfDirectory(atPath: outboxDir.path)
        return names
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    func removeOutbox(changeId: String) throws {
        let url = outboxURL(changeId: changeId)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    func clearOutbox() throws {
        for id in try listOutboxChangeIds() {
            try removeOutbox(changeId: id)
        }
    }
}
