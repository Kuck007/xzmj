import Foundation
import SwiftData

/// 客户信息模型
/// ⚠️ 所有非可选字段均有默认值，确保 SwiftData 轻量迁移安全
@Model
final class Customer {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String = ""
    var phone: String = ""
    var gender: String?
    var birthday: Date?
    var avatarURL: String?
    var wechat: String?
    var email: String?
    var tags: [String] = []
    var preferredTechnicianId: UUID?
    var membershipLevel: String = "普通"
    var points: Int = 0
    var totalSpent: Double = 0
    var lastVisitDate: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isActive: Bool = true

    init(
        id: UUID = UUID(),
        name: String,
        phone: String,
        gender: String? = nil,
        birthday: Date? = nil,
        avatarURL: String? = nil,
        wechat: String? = nil,
        email: String? = nil,
        tags: [String] = [],
        preferredTechnicianId: UUID? = nil,
        membershipLevel: String = "普通",
        points: Int = 0,
        totalSpent: Double = 0,
        lastVisitDate: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.phone = phone
        self.gender = gender
        self.birthday = birthday
        self.avatarURL = avatarURL
        self.wechat = wechat
        self.email = email
        self.tags = tags
        self.preferredTechnicianId = preferredTechnicianId
        self.membershipLevel = membershipLevel
        self.points = points
        self.totalSpent = totalSpent
        self.lastVisitDate = lastVisitDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isActive = isActive
    }
}
