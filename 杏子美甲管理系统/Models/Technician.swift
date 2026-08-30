import Foundation
import SwiftData

/// 技师信息模型
/// ⚠️ 所有非可选字段均有默认值，确保 SwiftData 轻量迁移安全
@Model
final class Technician {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String = ""
    var phone: String = ""
    var avatarURL: String?
    var bio: String?
    var availableServices: [UUID] = []
    var rating: Int = 5
    var totalServices: Int = 0
    var baseSalary: Double = 0
    var commissionRate: Double = 0.10
    var isActive: Bool = true

    init(
        id: UUID = UUID(),
        name: String,
        phone: String,
        avatarURL: String? = nil,
        bio: String? = nil,
        availableServices: [UUID] = [],
        rating: Int = 5,
        totalServices: Int = 0,
        baseSalary: Double = 0,
        commissionRate: Double = 0.10,
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.phone = phone
        self.avatarURL = avatarURL
        self.bio = bio
        self.availableServices = availableServices
        self.rating = rating
        self.totalServices = totalServices
        self.baseSalary = baseSalary
        self.commissionRate = commissionRate
        self.isActive = isActive
    }
}
