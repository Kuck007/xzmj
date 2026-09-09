import Foundation
import SwiftData

// MARK: - 服务项目

/// 具体服务项目（挂在某个叶子分类下）
/// ⚠️ 所有非可选字段均有默认值，确保 SwiftData 轻量迁移安全
@Model
final class ServiceItem {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String = ""
    var categoryId: UUID = UUID()
    var price: Double = 0
    var durationMinutes: Int = 60
    var itemDescription: String?
    var sortOrder: Int = 0
    var isActive: Bool = true
    var isLashTouchUp: Bool = false

    init(id: UUID = UUID(), name: String, categoryId: UUID, price: Double, durationMinutes: Int = 60, itemDescription: String? = nil, sortOrder: Int = 0, isActive: Bool = true, isLashTouchUp: Bool = false) {
        self.id = id
        self.name = name
        self.categoryId = categoryId
        self.price = price
        self.durationMinutes = durationMinutes
        self.itemDescription = itemDescription
        self.sortOrder = sortOrder
        self.isActive = isActive
        self.isLashTouchUp = isLashTouchUp
    }
}
