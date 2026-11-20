//
//  SyncIdentity.swift
//  杏子美甲管理系统
//
//  增量同步身份（阶段 2）：storeId（一套店数据的身份）、writerId（一次写入生命周期）、store.json。
//  storeId 与「应用标题」解耦：改标题只改显示名，不迁移云端、不切断数据（方案 §4.1）。
//

import Foundation

/// 云端 store.json：只描述“目录属于哪套数据”，不含任何业务信息。
struct SyncStoreDescriptor: Codable, Equatable {
    var formatVersion: Int
    var rulesVersion: Int
    var storeId: String
    var displayTitle: String
    var createdAt: Double
}

enum SyncIdentity {

    private static let fallbackTitle = "杏子美甲管理系统"

    /// 云端目录名：过滤文件系统非法字符，避免把标题里的斜杠等带进路径。
    static func sanitizedTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined()
        return safe.isEmpty ? fallbackTitle : safe
    }

    /// 默认同步根目录：{应用标题}/sync（方案 §4.1）。
    /// 目录需由用户在 WebDAV 服务器上手动创建（部分服务器禁止 MKCOL）。
    static func syncRoot(title: String) -> String {
        "\(sanitizedTitle(title))/sync"
    }

    /// 写入者显示名：只用于状态页与冲突日志，不参与身份判断。
    static func writerName() -> String {
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }

    /// 读取本机状态；首次启用同步时创建 storeId / writerId 并落盘。
    /// `syncRoot` 直接使用用户在「数据备份」里配置的 WebDAV 目录（不新建子目录，部分服务器禁止 MKCOL）。
    /// 注意：这里不生成 storeKey——storeKey 只在设置同步口令、真正建立同步空间时创建。
    static func loadOrCreateState(store: SyncStateStore,
                                 displayTitle: String,
                                 syncRoot: String,
                                 now: Date = Date()) throws -> (state: SyncState, created: Bool) {
        if var existing = try store.loadState() {
            // 还没产生任何同步数据时，允许跟随用户当前配置的目录（避免旧路径把用户永久钉死）
            if existing.records.isEmpty,
               existing.appliedChangeIds.isEmpty,
               existing.syncRoot != syncRoot {
                existing.syncRoot = syncRoot
                try store.saveState(existing)
            }
            return (existing, false)
        }
        var state = SyncState(storeId: UUID().uuidString,
                              syncRoot: syncRoot,
                              writerId: SyncCodec.newWriterId(),
                              writerName: writerName())
        state.storeCreatedAt = now.timeIntervalSince1970
        try store.saveState(state)
        return (state, true)
    }

    static func descriptor(for state: SyncState,
                           displayTitle: String,
                           now: Date = Date()) -> SyncStoreDescriptor {
        SyncStoreDescriptor(formatVersion: SyncState.currentFormatVersion,
                            rulesVersion: SyncChangeSet.currentRulesVersion,
                            storeId: state.storeId,
                            displayTitle: sanitizedTitle(displayTitle),
                            createdAt: state.storeCreatedAt ?? now.timeIntervalSince1970)
    }

    /// 校验云端 store.json 与本机是否同一套数据。
    /// 不一致必须停止同步，绝不能自动合并（方案 §4.1、§S10）。
    static func verify(remote: SyncStoreDescriptor, matches state: SyncState) throws {
        guard remote.storeId == state.storeId else {
            throw SyncError.stateCorrupted("云端目录属于另一套数据（storeId 不一致），已停止同步")
        }
        guard remote.formatVersion <= SyncState.currentFormatVersion else {
            throw SyncError.stateCorrupted("云端同步格式版本 \(remote.formatVersion) 高于本机，请升级 App")
        }
        guard remote.rulesVersion <= SyncChangeSet.currentRulesVersion else {
            throw SyncError.stateCorrupted("云端业务规则版本 \(remote.rulesVersion) 高于本机，请升级 App")
        }
    }
}
