//
//  SyncSnapshot.swift
//  杏子美甲管理系统
//
//  同步用的值类型快照：把 13 张 @Model 转成 12 组备份行（不含 User）。
//  这是“业务数据 → 同步内核”的唯一入口，之后所有计算都不再触碰 @Model。
//

import Foundation

// MARK: - 统一身份

/// 12 组备份行都有 `id: UUID`，用它作为同步记录键（方案 §4：身份只认 UUID）。
protocol SyncRowIdentifiable {
    var syncID: UUID { get }
}

extension BackupCustomer: SyncRowIdentifiable { var syncID: UUID { id } }
extension BackupTechnician: SyncRowIdentifiable { var syncID: UUID { id } }
extension BackupServiceCategory: SyncRowIdentifiable { var syncID: UUID { id } }
extension BackupServiceItem: SyncRowIdentifiable { var syncID: UUID { id } }
extension BackupServiceRecord: SyncRowIdentifiable { var syncID: UUID { id } }
extension BackupAppointment: SyncRowIdentifiable { var syncID: UUID { id } }
extension BackupOrder: SyncRowIdentifiable { var syncID: UUID { id } }
extension BackupInventoryItem: SyncRowIdentifiable { var syncID: UUID { id } }
extension BackupCommissionRule: SyncRowIdentifiable { var syncID: UUID { id } }
extension BackupLashReminder: SyncRowIdentifiable { var syncID: UUID { id } }
extension BackupRechargeRecord: SyncRowIdentifiable { var syncID: UUID { id } }
extension BackupDailyReconciliation: SyncRowIdentifiable { var syncID: UUID { id } }

// MARK: - 快照

/// 某一时刻的 12 表全量行。值类型，可跨线程传递。
struct SyncRowsSnapshot: Codable {
    var customers: [BackupCustomer] = []
    var technicians: [BackupTechnician] = []
    var serviceCategories: [BackupServiceCategory] = []
    var serviceItems: [BackupServiceItem] = []
    var records: [BackupServiceRecord] = []
    var appointments: [BackupAppointment] = []
    var orders: [BackupOrder] = []
    var inventoryItems: [BackupInventoryItem] = []
    var commissionRules: [BackupCommissionRule] = []
    var lashReminders: [BackupLashReminder] = []
    var rechargeRecords: [BackupRechargeRecord] = []
    var reconciliations: [BackupDailyReconciliation] = []

    var totalRowCount: Int {
        customers.count + technicians.count + serviceCategories.count + serviceItems.count
            + records.count + appointments.count + orders.count + inventoryItems.count
            + commissionRules.count + lashReminders.count + rechargeRecords.count
            + reconciliations.count
    }

    /// 各表行数，用于状态页与自检报告。
    var rowCounts: [String: Int] {
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
        ]
    }

    static func make(from pkg: BackupPackage) -> SyncRowsSnapshot {
        SyncRowsSnapshot(
            customers: pkg.customers,
            technicians: pkg.technicians,
            serviceCategories: pkg.serviceCategories,
            serviceItems: pkg.serviceItems,
            records: pkg.records,
            appointments: pkg.appointments,
            orders: pkg.orders,
            inventoryItems: pkg.inventoryItems,
            commissionRules: pkg.commissionRules,
            lashReminders: pkg.lashReminders,
            rechargeRecords: pkg.rechargeRecords,
            reconciliations: pkg.reconciliations
        )
    }
}

// MARK: - AppCore 读取入口

extension AppCore {
    /// 同步专用读取：读的是内核已物化的内存快照，不额外碰 SwiftData。
    /// 未就绪时必须抛错——绝不能把“还没加载”当成“整库为空 = 全部删除”（方案 §S6）。
    func syncSnapshotRows() throws -> SyncRowsSnapshot {
        guard isReady else { throw SyncError.coreNotReady }
        let pkg = BackupManager.shared.buildPackage(
            customers: customers,
            technicians: technicians,
            categories: categories,
            serviceItems: serviceItems,
            records: records,
            appointments: appointments,
            orders: orders,
            inventoryItems: inventoryItems,
            commissionRules: commissionRules,
            lashReminders: lashReminders,
            rechargeRecords: recharges,
            reconciliations: reconciliations,
            users: nil,
            appSettings: nil
        )
        return SyncRowsSnapshot.make(from: pkg)
    }
}
