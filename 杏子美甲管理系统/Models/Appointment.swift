import Foundation
import SwiftData

/// 预约（"预约排班"模块）
/// ⚠️ 所有非可选字段均有默认值，确保 SwiftData 轻量迁移安全
@Model
final class Appointment {
    @Attribute(.unique) var id: UUID = UUID()
    var customerId: UUID = UUID()
    var technicianId: UUID = UUID()
    var serviceItemIds: [UUID] = []
    var startTime: Date = Date()
    var endTime: Date = Date()
    var status: String = "已预约"
    var arrivedAt: Date?
    var notes: String?
    var createdAt: Date = Date()
    var reminderId: UUID?

    init(
        id: UUID = UUID(),
        customerId: UUID,
        technicianId: UUID,
        serviceItemIds: [UUID] = [],
        startTime: Date,
        endTime: Date,
        status: String = "已预约",
        arrivedAt: Date? = nil,
        notes: String? = nil,
        createdAt: Date = Date(),
        reminderId: UUID? = nil
    ) {
        self.id = id
        self.customerId = customerId
        self.technicianId = technicianId
        self.serviceItemIds = serviceItemIds
        self.startTime = startTime
        self.endTime = endTime
        self.status = status
        self.arrivedAt = arrivedAt
        self.notes = notes
        self.createdAt = createdAt
        self.reminderId = reminderId
    }
}
