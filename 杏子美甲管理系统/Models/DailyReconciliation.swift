//
//  DailyReconciliation.swift
//  杏子美甲管理系统
//
//  技师日结对账确认记录
//

import Foundation
import SwiftData

@Model
final class DailyReconciliation {
    @Attribute(.unique) var id: UUID = UUID()
    /// 关联技师ID
    var technicianId: UUID = UUID()
    /// 对账日期（精确到日，时分秒置0）
    var date: Date = Date()
    /// 确认时间，nil表示未确认
    var confirmedAt: Date? = nil
    /// 确认时的业绩快照（防止后续改单导致数据变化）
    var snapshotAmount: Double = 0
    /// 确认时的订单数快照
    var snapshotCount: Int = 0

    init(
        id: UUID = UUID(),
        technicianId: UUID,
        date: Date,
        confirmedAt: Date? = nil,
        snapshotAmount: Double = 0,
        snapshotCount: Int = 0
    ) {
        self.id = id
        self.technicianId = technicianId
        self.date = date
        self.confirmedAt = confirmedAt
        self.snapshotAmount = snapshotAmount
        self.snapshotCount = snapshotCount
    }
}
