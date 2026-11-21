//
//  SyncContracts.swift
//  杏子美甲管理系统
//
//  增量同步内核（阶段 1）：身份、版本、变更包、同步状态等纯值类型。
//  本文件不触碰 SwiftData、不依赖 UI、不读写网络，可在任意线程构造与编解码。
//  详细设计见 docs/增量同步方案.md（v3.1）。
//

import Foundation

// MARK: - 实体

/// 参与同步的 12 个业务实体。
/// `User` 不同步：账号与权限各机独立（见方案 §0）。
enum SyncEntity: String, CaseIterable, Codable {
    case customers
    case technicians
    case serviceCategories
    case serviceItems
    case records
    case appointments
    case orders
    case inventoryItems
    case commissionRules
    case lashReminders
    case rechargeRecords
    case reconciliations
}

// MARK: - HLC 版本

/// 混合逻辑时钟版本：wallMs → logical → writerId 构成稳定全序。
/// 只用于冲突判定，不写进业务模型（守住 SwiftData 迁移红线）。
struct SyncVersion: Codable, Hashable, Comparable {
    var wallMs: Int64
    var logical: Int
    var writerId: String

    static func < (lhs: SyncVersion, rhs: SyncVersion) -> Bool {
        if lhs.wallMs != rhs.wallMs { return lhs.wallMs < rhs.wallMs }
        if lhs.logical != rhs.logical { return lhs.logical < rhs.logical }
        return lhs.writerId < rhs.writerId
    }
}

/// 业务行 + 其同步版本。版本在外层包装，业务行结构保持备份格式不变。
struct SyncVersionedRow<Row: Codable>: Codable {
    var version: SyncVersion
    var row: Row
}

/// 墓碑：记录被删除的事实与删除版本，永久保留（不按时间过期）。
struct SyncTombstone: Codable, Hashable {
    var entity: SyncEntity
    var uuid: UUID
    var version: SyncVersion
}

// MARK: - 变更包

/// 一次本地变更的不可变快照。上传后同一 changeId 永远对应同一字节。
struct SyncChangeSet: Codable {
    static let currentFormatVersion = 3
    static let currentRulesVersion = 1

    var formatVersion: Int
    var rulesVersion: Int
    var storeId: String
    var changeId: String
    var writerId: String
    var writerSeq: Int
    var createdAt: Double

    var customers: [SyncVersionedRow<BackupCustomer>]
    var technicians: [SyncVersionedRow<BackupTechnician>]
    var serviceCategories: [SyncVersionedRow<BackupServiceCategory>]
    var serviceItems: [SyncVersionedRow<BackupServiceItem>]
    var records: [SyncVersionedRow<BackupServiceRecord>]
    var appointments: [SyncVersionedRow<BackupAppointment>]
    var orders: [SyncVersionedRow<BackupOrder>]
    var inventoryItems: [SyncVersionedRow<BackupInventoryItem>]
    var commissionRules: [SyncVersionedRow<BackupCommissionRule>]
    var lashReminders: [SyncVersionedRow<BackupLashReminder>]
    var rechargeRecords: [SyncVersionedRow<BackupRechargeRecord>]
    var reconciliations: [SyncVersionedRow<BackupDailyReconciliation>]
    var deletes: [SyncTombstone]

    /// 空包不上传（见方案 §7.4）。
    var isEmpty: Bool {
        upsertCount == 0 && deletes.isEmpty
    }

    var upsertCount: Int {
        customers.count + technicians.count + serviceCategories.count + serviceItems.count
            + records.count + appointments.count + orders.count + inventoryItems.count
            + commissionRules.count + lashReminders.count + rechargeRecords.count
            + reconciliations.count
    }

    /// 各表 upsert 条数，用于日志与状态页。
    var upsertCounts: [String: Int] {
        [
            SyncEntity.customers.rawValue: customers.count,
            SyncEntity.technicians.rawValue: technicians.count,
            SyncEntity.serviceCategories.rawValue: serviceCategories.count,
            SyncEntity.serviceItems.rawValue: serviceItems.count,
            SyncEntity.records.rawValue: records.count,
            SyncEntity.appointments.rawValue: appointments.count,
            SyncEntity.orders.rawValue: orders.count,
            SyncEntity.inventoryItems.rawValue: inventoryItems.count,
            SyncEntity.commissionRules.rawValue: commissionRules.count,
            SyncEntity.lashReminders.rawValue: lashReminders.count,
            SyncEntity.rechargeRecords.rawValue: rechargeRecords.count,
            SyncEntity.reconciliations.rawValue: reconciliations.count
        ].filter { $0.value > 0 }
    }

    init(storeId: String,
         changeId: String,
         writerId: String,
         writerSeq: Int,
         createdAt: Double,
         formatVersion: Int = SyncChangeSet.currentFormatVersion,
         rulesVersion: Int = SyncChangeSet.currentRulesVersion,
         customers: [SyncVersionedRow<BackupCustomer>] = [],
         technicians: [SyncVersionedRow<BackupTechnician>] = [],
         serviceCategories: [SyncVersionedRow<BackupServiceCategory>] = [],
         serviceItems: [SyncVersionedRow<BackupServiceItem>] = [],
         records: [SyncVersionedRow<BackupServiceRecord>] = [],
         appointments: [SyncVersionedRow<BackupAppointment>] = [],
         orders: [SyncVersionedRow<BackupOrder>] = [],
         inventoryItems: [SyncVersionedRow<BackupInventoryItem>] = [],
         commissionRules: [SyncVersionedRow<BackupCommissionRule>] = [],
         lashReminders: [SyncVersionedRow<BackupLashReminder>] = [],
         rechargeRecords: [SyncVersionedRow<BackupRechargeRecord>] = [],
         reconciliations: [SyncVersionedRow<BackupDailyReconciliation>] = [],
         deletes: [SyncTombstone] = []) {
        self.formatVersion = formatVersion
        self.rulesVersion = rulesVersion
        self.storeId = storeId
        self.changeId = changeId
        self.writerId = writerId
        self.writerSeq = writerSeq
        self.createdAt = createdAt
        self.customers = customers
        self.technicians = technicians
        self.serviceCategories = serviceCategories
        self.serviceItems = serviceItems
        self.records = records
        self.appointments = appointments
        self.orders = orders
        self.inventoryItems = inventoryItems
        self.commissionRules = commissionRules
        self.lashReminders = lashReminders
        self.rechargeRecords = rechargeRecords
        self.reconciliations = reconciliations
        self.deletes = deletes
    }

    /// 所有数组缺省为空：新版本新增实体时，旧包不会因为缺 key 解码失败。
    enum CodingKeys: String, CodingKey {
        case formatVersion, rulesVersion, storeId, changeId, writerId, writerSeq, createdAt
        case customers, technicians, serviceCategories, serviceItems, records, appointments
        case orders, inventoryItems, commissionRules, lashReminders, rechargeRecords
        case reconciliations, deletes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.currentFormatVersion
        rulesVersion = try c.decodeIfPresent(Int.self, forKey: .rulesVersion) ?? Self.currentRulesVersion
        storeId = try c.decode(String.self, forKey: .storeId)
        changeId = try c.decode(String.self, forKey: .changeId)
        writerId = try c.decode(String.self, forKey: .writerId)
        writerSeq = try c.decodeIfPresent(Int.self, forKey: .writerSeq) ?? 0
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        customers = try c.decodeIfPresent([SyncVersionedRow<BackupCustomer>].self, forKey: .customers) ?? []
        technicians = try c.decodeIfPresent([SyncVersionedRow<BackupTechnician>].self, forKey: .technicians) ?? []
        serviceCategories = try c.decodeIfPresent([SyncVersionedRow<BackupServiceCategory>].self, forKey: .serviceCategories) ?? []
        serviceItems = try c.decodeIfPresent([SyncVersionedRow<BackupServiceItem>].self, forKey: .serviceItems) ?? []
        records = try c.decodeIfPresent([SyncVersionedRow<BackupServiceRecord>].self, forKey: .records) ?? []
        appointments = try c.decodeIfPresent([SyncVersionedRow<BackupAppointment>].self, forKey: .appointments) ?? []
        orders = try c.decodeIfPresent([SyncVersionedRow<BackupOrder>].self, forKey: .orders) ?? []
        inventoryItems = try c.decodeIfPresent([SyncVersionedRow<BackupInventoryItem>].self, forKey: .inventoryItems) ?? []
        commissionRules = try c.decodeIfPresent([SyncVersionedRow<BackupCommissionRule>].self, forKey: .commissionRules) ?? []
        lashReminders = try c.decodeIfPresent([SyncVersionedRow<BackupLashReminder>].self, forKey: .lashReminders) ?? []
        rechargeRecords = try c.decodeIfPresent([SyncVersionedRow<BackupRechargeRecord>].self, forKey: .rechargeRecords) ?? []
        reconciliations = try c.decodeIfPresent([SyncVersionedRow<BackupDailyReconciliation>].self, forKey: .reconciliations) ?? []
        deletes = try c.decodeIfPresent([SyncTombstone].self, forKey: .deletes) ?? []
    }
}

/// 快照中的单条记录状态：版本 + 是否墓碑。
struct SyncSnapshotRecord: Codable, Equatable {
    var version: SyncVersion
    var deleted: Bool
}

/// 某一时刻的完整同步视图。只用于：首台种子、新机初始化、以后人工压缩云端历史。
/// 不是“链断了”的补救手段（方案 §6.4）。
struct SyncSnapshot: Codable {
    static let currentFormatVersion = 3

    var formatVersion: Int
    var rulesVersion: Int
    var storeId: String
    var snapshotId: String
    var createdAt: Double
    var rows: SyncRowsSnapshot
    var records: [String: [String: SyncSnapshotRecord]]
    var includedChangeIds: [String]

    static func fileName(snapshotId: String) -> String {
        SyncCodec.snapshotFileName(snapshotId: snapshotId)
    }

    static func metaFileName(snapshotId: String) -> String {
        SyncCodec.snapshotMetaFileName(snapshotId: snapshotId)
    }
}

/// 快照明文 meta（不含业务数据）。
struct SyncSnapshotMeta: Codable, Equatable {
    var formatVersion: Int
    var storeId: String
    var snapshotId: String
    var writerId: String
    var createdAt: Double
    var rowCount: Int
    var sha256: String
    var size: Int
    var keyId: String
    var fileName: String
    /// 本快照覆盖的全部 changeId（只增不减）。
    /// 可选：2.4.3 及更早生成的快照没有该字段，消费方退化为“按时间水位线”判断。
    var includedChangeIds: [String]?
}

/// 明文 meta：只含技术信息，不含客户姓名、手机号、金额（见方案 §6.3）。
struct SyncChangeSetMeta: Codable, Equatable {
    var formatVersion: Int
    var storeId: String
    var changeId: String
    var writerId: String
    var writerName: String
    var writerSeq: Int
    var createdAt: Double
    var upsertCount: Int
    var deleteCount: Int
    var sha256: String
    var size: Int
    var keyId: String
    var fileName: String
}

// MARK: - 本机同步状态

/// 单条记录的同步状态（方案 v3.1 §5.2：每记录一行，避免多表交叉写）。
struct SyncRecordState: Codable, Equatable {
    var version: SyncVersion
    var deleted: Bool
    /// 已确认同步（上传成功或远端应用）的内容哈希；nil 表示从未同步。
    var syncedHash: String?
    /// 已组进 outbox、尚未确认云端提交的包 id；nil 表示无待确认上传。
    var pendingChangeId: String?
    /// 待确认包内该行的哈希，用于差分包时判断“是否已经打包过”。
    var pendingHash: String?
}

/// 本机同步状态。写盘必须原子，任何字段失败都不能继续假装成功。
struct SyncState: Codable {
    static let currentFormatVersion = 3

    var formatVersion: Int
    var storeId: String
    var syncRoot: String
    var writerId: String
    var writerName: String
    var writerSeq: Int
    var lastWallMs: Int64
    var lastLogical: Int
    /// entity.rawValue → uuidString → 记录状态
    var records: [String: [String: SyncRecordState]]
    var appliedChangeIds: [String]
    var latestSnapshotId: String?
    var recoveryRequired: Bool
    /// 本套数据首次创建同步空间的时间（store.json 的 createdAt）。
    var storeCreatedAt: Double?
    var lastUploadAt: Double?
    var lastCheckAt: Double?
    var lastMergeAt: Double?
    /// 最近一次成功上传快照的时间；用于「每 7 天自动生成新快照」。
    var lastSnapshotAt: Double?
    /// 最近一次快照对应的 writerSeq；用于「每 100 个包自动生成新快照」。
    var lastSnapshotSeq: Int?
    /// 已被快照覆盖过的全部 changeId，只增不减。
    /// 旧包被「整理云端」删除后，它的 id 仍留在这里，用于晚回来的机器判断自己是否漏包。
    var coveredChangeIds: [String]?

    init(storeId: String,
         syncRoot: String,
         writerId: String,
         writerName: String) {
        self.formatVersion = Self.currentFormatVersion
        self.storeId = storeId
        self.syncRoot = syncRoot
        self.writerId = writerId
        self.writerName = writerName
        self.writerSeq = 0
        self.lastWallMs = 0
        self.lastLogical = 0
        self.records = [:]
        self.appliedChangeIds = []
        self.latestSnapshotId = nil
        self.recoveryRequired = false
        self.storeCreatedAt = nil
        self.lastUploadAt = nil
        self.lastCheckAt = nil
        self.lastMergeAt = nil
        self.lastSnapshotAt = nil
        self.lastSnapshotSeq = nil
        self.coveredChangeIds = []
    }

    func record(entity: SyncEntity, id: UUID) -> SyncRecordState? {
        records[entity.rawValue]?[id.uuidString]
    }

    mutating func setRecord(_ value: SyncRecordState?, entity: SyncEntity, id: UUID) {
        // 必须原地改内层字典：先复制出来再写回会触发整表 copy-on-write，
        // 几千行时退化成 O(n²)（实测 6332 行差分明显变慢）。
        if let value {
            records[entity.rawValue, default: [:]][id.uuidString] = value
        } else {
            records[entity.rawValue]?[id.uuidString] = nil
        }
    }

    /// 上传确认后：把该包内的记录标记为“已同步”，清空 pending。
    /// 只对 pendingChangeId 匹配的记录生效，避免误清新包的待上传标记。
    mutating func confirmUpload(changeId: String) {
        for entityKey in records.keys {
            guard var table = records[entityKey] else { continue }
            var changed = false
            for (idKey, record) in table where record.pendingChangeId == changeId {
                var updated = record
                updated.syncedHash = record.pendingHash
                updated.pendingHash = nil
                updated.pendingChangeId = nil
                table[idKey] = updated
                changed = true
            }
            if changed { records[entityKey] = table }
        }
    }

    var appliedChangeIdSet: Set<String> {
        Set(appliedChangeIds)
    }

    /// 已被快照覆盖的 changeId（只增不减）。
    var coveredChangeIdSet: Set<String> {
        Set(coveredChangeIds ?? [])
    }

    /// 合并进覆盖集合：只增不减，旧包被删后 id 仍保留，供漏包检测使用。
    mutating func absorbCoverage(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var set = coveredChangeIdSet
        set.formUnion(ids)
        coveredChangeIds = Array(set)
    }

    /// 本机「已知的全部云端变更」= 逐包应用过的 + 快照覆盖过的。
    var knownChangeIdSet: Set<String> {
        appliedChangeIdSet.union(coveredChangeIdSet)
    }

    /// 已同步记录总数（不含墓碑），用于状态页展示。
    var syncedRecordCount: Int {
        records.values.reduce(0) { partial, table in
            partial + table.values.filter { !$0.deleted }.count
        }
    }
}

// MARK: - 错误

enum SyncError: LocalizedError {
    case coreNotReady
    case stateDirectoryUnavailable
    case stateCorrupted(String)
    case encodeFailed(String)
    case passphraseTooShort(Int)
    case cryptoFailed(String)

    var errorDescription: String? {
        switch self {
        case .coreNotReady:
            return "业务数据尚未就绪，禁止生成同步包"
        case .stateDirectoryUnavailable:
            return "无法访问同步状态目录"
        case .stateCorrupted(let detail):
            return "同步状态文件损坏：\(detail)"
        case .encodeFailed(let detail):
            return "同步数据编码失败：\(detail)"
        case .passphraseTooShort(let minimum):
            return "同步口令至少需要 \(minimum) 位"
        case .cryptoFailed(let detail):
            return "同步密钥操作失败：\(detail)"
        }
    }
}
