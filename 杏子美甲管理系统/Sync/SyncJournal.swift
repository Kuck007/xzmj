//
//  SyncJournal.swift
//  杏子美甲管理系统
//
//  增量同步内核（阶段 1）：HLC 时钟 + 全量哈希差分。
//  v3.1 起不使用 DidSave 主捕获，唯一捕获路径是「保存成功 → 20 秒防抖 → 全量差分」。
//

import Foundation

// MARK: - HLC 时钟

/// 混合逻辑时钟发生器。规则：本机版本严格单调；同毫秒或时钟回拨时 logical+1。
struct SyncHLCGenerator {
    private(set) var lastWallMs: Int64
    private(set) var lastLogical: Int
    let writerId: String

    init(writerId: String, lastWallMs: Int64 = 0, lastLogical: Int = 0) {
        self.writerId = writerId
        self.lastWallMs = lastWallMs
        self.lastLogical = lastLogical
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// 生成下一个本机版本。
    mutating func next(now: Date = Date()) -> SyncVersion {
        let nowMs = Self.millis(now)
        if nowMs > lastWallMs {
            lastWallMs = nowMs
            lastLogical = 0
        } else {
            lastLogical += 1
        }
        return SyncVersion(wallMs: lastWallMs, logical: lastLogical, writerId: writerId)
    }

    /// 收到远端版本后推进本地时钟，保证本机后续版本不会小于刚见过的版本。
    mutating func observe(_ remote: SyncVersion, now: Date = Date()) {
        let nowMs = Self.millis(now)
        let newWall = max(nowMs, max(lastWallMs, remote.wallMs))
        if newWall == lastWallMs && newWall == remote.wallMs {
            lastLogical = max(lastLogical, remote.logical) + 1
        } else if newWall == lastWallMs {
            lastLogical += 1
        } else if newWall == remote.wallMs {
            lastLogical = remote.logical + 1
        } else {
            lastLogical = 0
        }
        lastWallMs = newWall
    }
}

// MARK: - 差分结果

struct SyncDiffStats: Equatable {
    var upserts: [String: Int] = [:]
    var deletes: [String: Int] = [:]

    var totalUpserts: Int { upserts.values.reduce(0, +) }
    var totalDeletes: Int { deletes.values.reduce(0, +) }
    var isEmpty: Bool { totalUpserts == 0 && totalDeletes == 0 }

    var summary: String {
        let up = upserts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let del = deletes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "upsert[\(up)] delete[\(del)]"
    }
}

struct SyncPlan {
    var changeSet: SyncChangeSet?
    var stats: SyncDiffStats
}

// MARK: - 差分规划

enum SyncJournal {

    /// 对比「当前快照」与「本机状态」，产出不可变更发包。
    /// - 无变化时返回 changeSet = nil，不占 writerSeq（方案 §7.3 第 1 步）。
    /// - 成功产包后，状态里的 pendingChangeId/pendingHash 指向该包，防止重复造包。
    static func plan(snapshot: SyncRowsSnapshot,
                     state: inout SyncState,
                     now: Date = Date()) throws -> SyncPlan {
        let changeId = SyncCodec.newChangeId()
        var clock = SyncHLCGenerator(writerId: state.writerId,
                                     lastWallMs: state.lastWallMs,
                                     lastLogical: state.lastLogical)
        var stats = SyncDiffStats()
        // 复用同一个编码器：批量哈希时不要每行新建 JSONEncoder
        let rowEncoder = SyncCodec.makeEncoder()

        let customers = try diff(.customers, snapshot.customers, &state, &clock, changeId, now, rowEncoder, &stats)
        let technicians = try diff(.technicians, snapshot.technicians, &state, &clock, changeId, now, rowEncoder, &stats)
        let serviceCategories = try diff(.serviceCategories, snapshot.serviceCategories, &state, &clock, changeId, now, rowEncoder, &stats)
        let serviceItems = try diff(.serviceItems, snapshot.serviceItems, &state, &clock, changeId, now, rowEncoder, &stats)
        let records = try diff(.records, snapshot.records, &state, &clock, changeId, now, rowEncoder, &stats)
        let appointments = try diff(.appointments, snapshot.appointments, &state, &clock, changeId, now, rowEncoder, &stats)
        let orders = try diff(.orders, snapshot.orders, &state, &clock, changeId, now, rowEncoder, &stats)
        let inventoryItems = try diff(.inventoryItems, snapshot.inventoryItems, &state, &clock, changeId, now, rowEncoder, &stats)
        let commissionRules = try diff(.commissionRules, snapshot.commissionRules, &state, &clock, changeId, now, rowEncoder, &stats)
        let lashReminders = try diff(.lashReminders, snapshot.lashReminders, &state, &clock, changeId, now, rowEncoder, &stats)
        let rechargeRecords = try diff(.rechargeRecords, snapshot.rechargeRecords, &state, &clock, changeId, now, rowEncoder, &stats)
        let reconciliations = try diff(.reconciliations, snapshot.reconciliations, &state, &clock, changeId, now, rowEncoder, &stats)

        let allDeletes = customers.deletes + technicians.deletes + serviceCategories.deletes
            + serviceItems.deletes + records.deletes + appointments.deletes
            + orders.deletes + inventoryItems.deletes + commissionRules.deletes
            + lashReminders.deletes + rechargeRecords.deletes + reconciliations.deletes

        let changeSet = SyncChangeSet(
            storeId: state.storeId,
            changeId: changeId,
            writerId: state.writerId,
            writerSeq: state.writerSeq + 1,
            createdAt: now.timeIntervalSince1970,
            customers: customers.upserts,
            technicians: technicians.upserts,
            serviceCategories: serviceCategories.upserts,
            serviceItems: serviceItems.upserts,
            records: records.upserts,
            appointments: appointments.upserts,
            orders: orders.upserts,
            inventoryItems: inventoryItems.upserts,
            commissionRules: commissionRules.upserts,
            lashReminders: lashReminders.upserts,
            rechargeRecords: rechargeRecords.upserts,
            reconciliations: reconciliations.upserts,
            deletes: allDeletes
        )

        // 空包不上传，也不推进 writerSeq 与时钟（避免空转）。
        if changeSet.isEmpty {
            return SyncPlan(changeSet: nil, stats: stats)
        }

        state.writerSeq += 1
        state.lastWallMs = clock.lastWallMs
        state.lastLogical = clock.lastLogical
        return SyncPlan(changeSet: changeSet, stats: stats)
    }

    // MARK: - 快照

    /// 把当前快照固化为 SyncSnapshot，并把 state 里所有行标记为「已同步基线」。
    /// 只用于首台种子 / 新机初始化 / 人工压缩；不推进 writerSeq、不产生 pending。
    static func makeSnapshot(snapshot: SyncRowsSnapshot,
                             state: inout SyncState,
                             now: Date = Date()) throws -> SyncSnapshot {
        var clock = SyncHLCGenerator(writerId: state.writerId,
                                     lastWallMs: state.lastWallMs,
                                     lastLogical: state.lastLogical)
        let encoder = SyncCodec.makeEncoder()

        var records: [String: [String: SyncSnapshotRecord]] = [:]

        func merge(_ entity: SyncEntity, _ map: [String: SyncSnapshotRecord]) {
            guard !map.isEmpty else { return }
            records[entity.rawValue] = map
        }

        merge(.customers, try snapshotTable(.customers, snapshot.customers, &state, &clock, encoder))
        merge(.technicians, try snapshotTable(.technicians, snapshot.technicians, &state, &clock, encoder))
        merge(.serviceCategories, try snapshotTable(.serviceCategories, snapshot.serviceCategories, &state, &clock, encoder))
        merge(.serviceItems, try snapshotTable(.serviceItems, snapshot.serviceItems, &state, &clock, encoder))
        merge(.records, try snapshotTable(.records, snapshot.records, &state, &clock, encoder))
        merge(.appointments, try snapshotTable(.appointments, snapshot.appointments, &state, &clock, encoder))
        merge(.orders, try snapshotTable(.orders, snapshot.orders, &state, &clock, encoder))
        merge(.inventoryItems, try snapshotTable(.inventoryItems, snapshot.inventoryItems, &state, &clock, encoder))
        merge(.commissionRules, try snapshotTable(.commissionRules, snapshot.commissionRules, &state, &clock, encoder))
        merge(.lashReminders, try snapshotTable(.lashReminders, snapshot.lashReminders, &state, &clock, encoder))
        merge(.rechargeRecords, try snapshotTable(.rechargeRecords, snapshot.rechargeRecords, &state, &clock, encoder))
        merge(.reconciliations, try snapshotTable(.reconciliations, snapshot.reconciliations, &state, &clock, encoder))

        state.lastWallMs = clock.lastWallMs
        state.lastLogical = clock.lastLogical

        let snap = SyncSnapshot(formatVersion: SyncSnapshot.currentFormatVersion,
                                rulesVersion: SyncChangeSet.currentRulesVersion,
                                storeId: state.storeId,
                                snapshotId: SyncCodec.newChangeId(),
                                createdAt: now.timeIntervalSince1970,
                                rows: snapshot,
                                records: records,
                                includedChangeIds: [])
        state.latestSnapshotId = snap.snapshotId
        return snap
    }

    private static func snapshotTable<Row: Codable & SyncRowIdentifiable>(
        _ entity: SyncEntity,
        _ rows: [Row],
        _ state: inout SyncState,
        _ clock: inout SyncHLCGenerator,
        _ encoder: JSONEncoder
    ) throws -> [String: SyncSnapshotRecord] {
        var map: [String: SyncSnapshotRecord] = [:]

        // 先保留已有墓碑（永久保留，进入后续快照）
        for (key, record) in (state.records[entity.rawValue] ?? [:]) where record.deleted {
            map[key] = SyncSnapshotRecord(version: record.version, deleted: true)
        }

        for row in rows {
            let key = row.syncID.uuidString
            let hash = try SyncCodec.rowHash(row, using: encoder)
            let version = clock.next()
            map[key] = SyncSnapshotRecord(version: version, deleted: false)
            state.setRecord(SyncRecordState(version: version,
                                            deleted: false,
                                            syncedHash: hash,
                                            pendingChangeId: nil,
                                            pendingHash: nil),
                            entity: entity,
                            id: row.syncID)
        }
        return map
    }

    // MARK: - 单表差分

    private struct TableDiff<Row: Codable> {
        var upserts: [SyncVersionedRow<Row>]
        var deletes: [SyncTombstone]
    }

    private static func diff<Row: Codable & SyncRowIdentifiable>(
        _ entity: SyncEntity,
        _ rows: [Row],
        _ state: inout SyncState,
        _ clock: inout SyncHLCGenerator,
        _ changeId: String,
        _ now: Date,
        _ encoder: JSONEncoder,
        _ stats: inout SyncDiffStats
    ) throws -> TableDiff<Row> {
        // 当前快照：uuidString → (行, 行哈希)
        var rowsByKey: [String: Row] = [:]
        var hashByKey: [String: String] = [:]
        for row in rows {
            let key = row.syncID.uuidString
            rowsByKey[key] = row
            hashByKey[key] = try SyncCodec.rowHash(row, using: encoder)
        }

        var upserts: [SyncVersionedRow<Row>] = []
        var tombstoneIDs: [(UUID, SyncVersion)] = []

        // 新增 / 修改（按 key 排序，保证同样内容产出的包结构稳定）
        for key in rowsByKey.keys.sorted() {
            guard let row = rowsByKey[key], let hash = hashByKey[key] else { continue }
            let existing = state.records[entity.rawValue]?[key]

            // 已确认同步且内容未变
            if let existing, !existing.deleted, existing.syncedHash == hash { continue }
            // 已在待上传包中且内容未变，避免重复造包
            if let existing, existing.pendingChangeId != nil, existing.pendingHash == hash { continue }

            let version = clock.next(now: now)
            upserts.append(SyncVersionedRow(version: version, row: row))
            state.setRecord(
                SyncRecordState(version: version,
                                deleted: false,
                                syncedHash: existing?.syncedHash,
                                pendingChangeId: changeId,
                                pendingHash: hash),
                entity: entity,
                id: row.syncID
            )
        }

        // 删除：状态里有、当前快照没有 → 生成墓碑（永久保留，不按时间过期）
        for (key, record) in (state.records[entity.rawValue] ?? [:]) {
            guard !record.deleted, rowsByKey[key] == nil else { continue }
            guard let uuid = UUID(uuidString: key) else { continue }
            let version = clock.next(now: now)
            tombstoneIDs.append((uuid, version))
            state.setRecord(
                SyncRecordState(version: version,
                                deleted: true,
                                syncedHash: nil,
                                pendingChangeId: changeId,
                                pendingHash: nil),
                entity: entity,
                id: uuid
            )
        }

        if !upserts.isEmpty {
            stats.upserts[entity.rawValue] = upserts.count
        }
        if !tombstoneIDs.isEmpty {
            stats.deletes[entity.rawValue] = tombstoneIDs.count
        }

        return TableDiff(
            upserts: upserts,
            deletes: tombstoneIDs.map { SyncTombstone(entity: entity, uuid: $0.0, version: $0.1) }
        )
    }
}
