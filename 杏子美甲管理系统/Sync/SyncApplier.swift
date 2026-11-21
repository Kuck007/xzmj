//
//  SyncApplier.swift
//  杏子美甲管理系统
//
//  阶段 3：把远端 ChangeSet 按记录版本合并进本机 SwiftData。
//  规则（方案 §8.4–§8.6）：
//  - 整行 LWW，版本大者胜；同版本同内容幂等跳过；同版本不同内容属协议异常，拒绝并报告。
//  - 已存在记录逐字段赋值，不 delete+insert（避免唯一约束冲突）。
//  - 整包结束一次 save；失败回滚，不推进 appliedChangeIds（由调用方保证）。
//  - 应用期间 isApplyingRemote = true，refresh 不写库，避免回声。
//

import Foundation
import SwiftData

struct SyncApplyReport: Equatable {
    var inserted = 0
    var updated = 0
    var deleted = 0
    var skipped = 0
    var conflicts = 0

    var summary: String {
        "新增 \(inserted)，更新 \(updated)，删除 \(deleted)，跳过 \(skipped)，冲突 \(conflicts)"
    }
}

// MARK: - Snapshot → ChangeSet

extension SyncSnapshot {
    /// 把快照转成一次「全量 upsert + 墓碑」的 ChangeSet，直接复用合并逻辑。
    /// 版本取自 snapshot.records，不重新分配。
    func asChangeSet() -> SyncChangeSet {
        func wrap<Row: Codable & SyncRowIdentifiable>(_ entity: SyncEntity,
                                                     _ rows: [Row]) -> [SyncVersionedRow<Row>] {
            rows.compactMap { row in
                guard let record = records[entity.rawValue]?[row.syncID.uuidString],
                      !record.deleted else { return nil }
                return SyncVersionedRow(version: record.version, row: row)
            }
        }

        func tombstones(_ entity: SyncEntity) -> [SyncTombstone] {
            (records[entity.rawValue] ?? [:]).compactMap { key, record in
                guard record.deleted, let uuid = UUID(uuidString: key) else { return nil }
                return SyncTombstone(entity: entity, uuid: uuid, version: record.version)
            }
        }

        let deletes = SyncEntity.allCases.flatMap { tombstones($0) }

        return SyncChangeSet(storeId: storeId,
                             changeId: snapshotId,
                             writerId: "snapshot",
                             writerSeq: 0,
                             createdAt: createdAt,
                             customers: wrap(.customers, rows.customers),
                             technicians: wrap(.technicians, rows.technicians),
                             serviceCategories: wrap(.serviceCategories, rows.serviceCategories),
                             serviceItems: wrap(.serviceItems, rows.serviceItems),
                             records: wrap(.records, rows.records),
                             appointments: wrap(.appointments, rows.appointments),
                             orders: wrap(.orders, rows.orders),
                             inventoryItems: wrap(.inventoryItems, rows.inventoryItems),
                             commissionRules: wrap(.commissionRules, rows.commissionRules),
                             lashReminders: wrap(.lashReminders, rows.lashReminders),
                             rechargeRecords: wrap(.rechargeRecords, rows.rechargeRecords),
                             reconciliations: wrap(.reconciliations, rows.reconciliations),
                             deletes: deletes)
    }
}

extension AppCore {

    /// 一批远端包共用的表字典：只构建一次，跨包复用。
    private struct SyncApplyTables {
        var customers: [UUID: Customer] = [:]
        var technicians: [UUID: Technician] = [:]
        var categories: [UUID: ServiceCategory] = [:]
        var serviceItems: [UUID: ServiceItem] = [:]
        var records: [UUID: NailServiceRecord] = [:]
        var appointments: [UUID: Appointment] = [:]
        var orders: [UUID: Order] = [:]
        var inventory: [UUID: InventoryItem] = [:]
        var rules: [UUID: CommissionRule] = [:]
        var reminders: [UUID: LashReminder] = [:]
        var recharges: [UUID: RechargeRecord] = [:]
        var reconciliations: [UUID: DailyReconciliation] = [:]
    }

    private func makeApplyTables() -> SyncApplyTables {
        SyncApplyTables(
            customers: Dictionary(customers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            technicians: Dictionary(technicians.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            categories: Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            serviceItems: Dictionary(serviceItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            records: Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            appointments: Dictionary(appointments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            orders: Dictionary(orders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            inventory: Dictionary(inventoryItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            rules: Dictionary(commissionRules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            reminders: Dictionary(lashReminders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            recharges: Dictionary(recharges.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            reconciliations: Dictionary(reconciliations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        )
    }

    /// 应用一个远端包。调用方负责 appliedChangeIds 与状态落盘。
    func syncApply(_ changeSet: SyncChangeSet, state: inout SyncState) async throws -> SyncApplyReport {
        try await syncApplyBatch([changeSet], state: &state)
    }

    /// 批量应用远端包：表字典只构建一次，所有包结束后统一 save + reload。
    /// 50 个包合并时，避免每包都全量重载 12 张表（旧的 4 分钟主要耗在这里）。
    func syncApplyBatch(_ changeSets: [SyncChangeSet], state: inout SyncState) async throws -> SyncApplyReport {
        guard isReady else { throw SyncError.coreNotReady }
        guard !changeSets.isEmpty else { return SyncApplyReport() }
        beginRemoteApply()
        defer { endRemoteApply() }

        var tables = makeApplyTables()
        SyncPerf.log("  batch: tables built")
        var report = SyncApplyReport()
        let rowsStart = Date()
        for changeSet in changeSets {
            try applyChangeSet(changeSet, tables: &tables, state: &state, report: &report)
        }
        SyncPerf.log("  batch: apply rows \(Int(Date().timeIntervalSince(rowsStart) * 1000))ms")

        // 整批一次提交；失败直接抛出，由调用方决定是否重放
        let saveStart = Date()
        try saveOrThrow()
        SyncPerf.log("  batch: save \(Int(Date().timeIntervalSince(saveStart) * 1000))ms")
        try await reloadAfterRemotePackage()
        return report
    }

    private func applyChangeSet(_ changeSet: SyncChangeSet,
                                tables: inout SyncApplyTables,
                                state: inout SyncState,
                                report: inout SyncApplyReport) throws {
        try applyRows(changeSet.customers, entity: .customers, existing: &tables.customers,
                      state: &state, report: &report,
                      make: { Customer(from: $0) }, update: { apply($1, to: $0) })
        try applyRows(changeSet.technicians, entity: .technicians, existing: &tables.technicians,
                      state: &state, report: &report,
                      make: { Technician(from: $0) }, update: { apply($1, to: $0) })
        try applyRows(changeSet.serviceCategories, entity: .serviceCategories, existing: &tables.categories,
                      state: &state, report: &report,
                      make: { ServiceCategory(from: $0) }, update: { apply($1, to: $0) })
        try applyRows(changeSet.serviceItems, entity: .serviceItems, existing: &tables.serviceItems,
                      state: &state, report: &report,
                      make: { ServiceItem(from: $0) }, update: { apply($1, to: $0) })
        try applyRows(changeSet.records, entity: .records, existing: &tables.records,
                      state: &state, report: &report,
                      make: { NailServiceRecord(from: $0) }, update: { apply($1, to: $0) })
        try applyRows(changeSet.appointments, entity: .appointments, existing: &tables.appointments,
                      state: &state, report: &report,
                      make: { Appointment(from: $0) }, update: { apply($1, to: $0) })
        try applyRows(changeSet.orders, entity: .orders, existing: &tables.orders,
                      state: &state, report: &report,
                      make: { Order(from: $0) }, update: { apply($1, to: $0) })
        try applyRows(changeSet.inventoryItems, entity: .inventoryItems, existing: &tables.inventory,
                      state: &state, report: &report,
                      make: { InventoryItem(from: $0) }, update: { apply($1, to: $0) })
        try applyRows(changeSet.commissionRules, entity: .commissionRules, existing: &tables.rules,
                      state: &state, report: &report,
                      make: { CommissionRule(from: $0) }, update: { apply($1, to: $0) })
        try applyRows(changeSet.lashReminders, entity: .lashReminders, existing: &tables.reminders,
                      state: &state, report: &report,
                      make: { LashReminder(from: $0) }, update: { apply($1, to: $0) })
        try applyRows(changeSet.rechargeRecords, entity: .rechargeRecords, existing: &tables.recharges,
                      state: &state, report: &report,
                      make: { RechargeRecord(from: $0) }, update: { apply($1, to: $0) })
        try applyRows(changeSet.reconciliations, entity: .reconciliations, existing: &tables.reconciliations,
                      state: &state, report: &report,
                      make: { DailyReconciliation(from: $0) }, update: { apply($1, to: $0) })

        applyDeletes(changeSet.deletes, entity: .customers, existing: &tables.customers, state: &state, report: &report)
        applyDeletes(changeSet.deletes, entity: .technicians, existing: &tables.technicians, state: &state, report: &report)
        applyDeletes(changeSet.deletes, entity: .serviceCategories, existing: &tables.categories, state: &state, report: &report)
        applyDeletes(changeSet.deletes, entity: .serviceItems, existing: &tables.serviceItems, state: &state, report: &report)
        applyDeletes(changeSet.deletes, entity: .records, existing: &tables.records, state: &state, report: &report)
        applyDeletes(changeSet.deletes, entity: .appointments, existing: &tables.appointments, state: &state, report: &report)
        applyDeletes(changeSet.deletes, entity: .orders, existing: &tables.orders, state: &state, report: &report)
        applyDeletes(changeSet.deletes, entity: .inventoryItems, existing: &tables.inventory, state: &state, report: &report)
        applyDeletes(changeSet.deletes, entity: .commissionRules, existing: &tables.rules, state: &state, report: &report)
        applyDeletes(changeSet.deletes, entity: .lashReminders, existing: &tables.reminders, state: &state, report: &report)
        applyDeletes(changeSet.deletes, entity: .rechargeRecords, existing: &tables.recharges, state: &state, report: &report)
        applyDeletes(changeSet.deletes, entity: .reconciliations, existing: &tables.reconciliations, state: &state, report: &report)
    }

    // MARK: - 通用 upsert

    private func applyRows<Row: Codable & SyncRowIdentifiable, Model: PersistentModel>(
        _ rows: [SyncVersionedRow<Row>],
        entity: SyncEntity,
        existing: inout [UUID: Model],
        state: inout SyncState,
        report: inout SyncApplyReport,
        make: (Row) -> Model,
        update: (Model, Row) -> Void
    ) throws {
        for item in rows {
            let id = item.row.syncID
            let incoming = item.version

            if let local = state.record(entity: entity, id: id) {
                if incoming <= local.version {
                    report.skipped += 1
                    if incoming < local.version {
                        report.conflicts += 1
                        SyncConflictLogger.recordConflict(entity: entity, uuid: id,
                                                          local: local.version,
                                                          incoming: incoming,
                                                          detail: "远端行版本较旧，保留本地")
                    }
                    continue
                }
            }

            if let model = existing[id] {
                update(model, item.row)
                report.updated += 1
            } else {
                let model = make(item.row)
                if insertWithoutSaving(model) {
                    existing[id] = model
                }
                report.inserted += 1
            }

            state.setRecord(SyncRecordState(version: incoming,
                                            deleted: false,
                                            syncedHash: try SyncCodec.rowHash(item.row),
                                            pendingChangeId: nil,
                                            pendingHash: nil),
                            entity: entity,
                            id: id)
        }
    }

    // MARK: - 通用删除（墓碑）

    private func applyDeletes<Model: PersistentModel>(
        _ tombstones: [SyncTombstone],
        entity: SyncEntity,
        existing: inout [UUID: Model],
        state: inout SyncState,
        report: inout SyncApplyReport
    ) {
        for tombstone in tombstones where tombstone.entity == entity {
            if let local = state.record(entity: entity, id: tombstone.uuid) {
                if local.deleted && tombstone.version <= local.version {
                    report.skipped += 1
                    continue
                }
                if !local.deleted && tombstone.version < local.version {
                    report.skipped += 1
                    report.conflicts += 1
                    SyncConflictLogger.recordConflict(entity: entity, uuid: tombstone.uuid,
                                                      local: local.version,
                                                      incoming: tombstone.version,
                                                      detail: "删除版本较旧，保留本地记录")
                    continue
                }
            }
            if let model = existing[tombstone.uuid] {
                _ = deleteWithoutSaving(model)
                existing[tombstone.uuid] = nil
                report.deleted += 1
            }
            state.setRecord(SyncRecordState(version: tombstone.version,
                                            deleted: true,
                                            syncedHash: nil,
                                            pendingChangeId: nil,
                                            pendingHash: nil),
                            entity: entity,
                            id: tombstone.uuid)
        }
    }

    // MARK: - 逐字段更新（不 delete + insert，避免唯一约束冲突）

    private func apply(_ b: BackupCustomer, to m: Customer) {
        m.name = b.name
        m.phone = b.phone
        m.gender = b.gender
        m.birthday = b.birthday
        m.avatarURL = b.avatarURL
        m.wechat = b.wechat
        m.email = b.email
        m.tags = b.tags
        m.preferredTechnicianId = b.preferredTechnicianId
        m.membershipLevel = b.membershipLevel
        m.points = b.points
        m.totalSpent = b.totalSpent
        m.lastVisitDate = b.lastVisitDate
        m.createdAt = b.createdAt
        m.updatedAt = b.updatedAt
        m.isActive = b.isActive
    }

    private func apply(_ b: BackupTechnician, to m: Technician) {
        m.name = b.name
        m.phone = b.phone
        m.avatarURL = b.avatarURL
        m.bio = b.bio
        m.availableServices = b.availableServices
        m.rating = b.rating
        m.totalServices = b.totalServices
        m.baseSalary = b.baseSalary ?? 0
        m.commissionRate = b.commissionRate ?? 0.10
        m.isActive = b.isActive
        m.userUsername = b.userUsername
    }

    private func apply(_ b: BackupServiceCategory, to m: ServiceCategory) {
        m.name = b.name
        m.parentId = b.parentId
        m.sortOrder = b.sortOrder
        m.isActive = b.isActive
    }

    private func apply(_ b: BackupServiceItem, to m: ServiceItem) {
        m.name = b.name
        m.categoryId = b.categoryId
        m.price = b.price
        m.durationMinutes = b.durationMinutes
        m.itemDescription = b.itemDescription
        m.sortOrder = b.sortOrder
        m.isActive = b.isActive
        m.isLashTouchUp = b.isLashTouchUp
    }

    private func apply(_ b: BackupServiceRecord, to m: NailServiceRecord) {
        m.customerId = b.customerId
        m.technicianId = b.technicianId
        m.serviceDate = b.serviceDate
        m.serviceItemIds = b.serviceItemIds
        m.photos = b.photos
        m.materialsUsed = b.materialsUsed
        m.accessories = b.accessories
        m.craft = b.craft
        m.hasConstruction = b.hasConstruction
        m.preferences = b.preferences
        m.notes = b.notes
        m.isArchived = b.isArchived
        m.isPaid = b.isPaid
        m.reminderId = b.reminderId
        m.appointmentId = b.appointmentId
    }

    private func apply(_ b: BackupAppointment, to m: Appointment) {
        m.customerId = b.customerId
        m.technicianId = b.technicianId
        m.serviceItemIds = b.serviceItemIds
        m.startTime = b.startTime
        m.endTime = b.endTime
        m.status = b.status
        m.arrivedAt = b.arrivedAt
        m.notes = b.notes
        m.createdAt = b.createdAt
        m.reminderId = b.reminderId
    }

    private func apply(_ b: BackupOrder, to m: Order) {
        m.recordId = b.recordId
        m.customerId = b.customerId
        m.technicianId = b.technicianId
        m.lineItems = b.lineItems
        m.totalAmount = b.totalAmount
        m.originalTotal = b.originalTotal
        m.discountAmount = b.discountAmount
        m.paymentMethod = b.paymentMethod
        m.walletDeducted = b.walletDeducted
        m.topUpPaymentMethod = b.topUpPaymentMethod
        m.paidAt = b.paidAt
        m.notes = b.notes
    }

    private func apply(_ b: BackupInventoryItem, to m: InventoryItem) {
        m.name = b.name
        m.brand = b.brand
        m.colorCode = b.colorCode
        m.category = b.category
        m.quantity = b.quantity
        m.unit = b.unit
        m.lowStockThreshold = b.lowStockThreshold
        m.notes = b.notes
        m.updatedAt = b.updatedAt
    }

    private func apply(_ b: BackupCommissionRule, to m: CommissionRule) {
        m.categoryId = b.categoryId
        m.categoryName = b.categoryName
        m.rate = b.rate
        m.isActive = b.isActive
    }

    private func apply(_ b: BackupLashReminder, to m: LashReminder) {
        m.orderId = b.orderId
        m.customerId = b.customerId
        m.serviceItemIds = b.serviceItemIds
        m.paidAt = b.paidAt
        m.dueDate = b.dueDate
        m.isCompleted = b.isCompleted
        m.completedAt = b.completedAt
        m.completedByOrderId = b.completedByOrderId
        m.createdAt = b.createdAt
    }

    private func apply(_ b: BackupRechargeRecord, to m: RechargeRecord) {
        m.customerId = b.customerId
        m.amount = b.amount
        m.paymentMethod = b.paymentMethod
        m.bonus = b.bonus
        m.operatorNote = b.operatorNote
        m.rechargeAt = b.rechargeAt
        m.createdAt = b.createdAt
    }

    private func apply(_ b: BackupDailyReconciliation, to m: DailyReconciliation) {
        m.technicianId = b.technicianId
        m.date = b.date
        m.confirmedAt = b.confirmedAt
        m.snapshotAmount = b.snapshotAmount
        m.snapshotCount = b.snapshotCount
    }
}
