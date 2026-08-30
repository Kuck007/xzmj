import Foundation
import SwiftData

// MARK: - 服务分类

/// 服务分类：自引用树形结构
/// ⚠️ 所有非可选字段均有默认值，确保 SwiftData 轻量迁移安全
@Model
final class ServiceCategory {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String = ""
    var parentId: UUID?
    var sortOrder: Int = 0
    var isActive: Bool = true

    init(id: UUID = UUID(), name: String, parentId: UUID? = nil, sortOrder: Int = 0, isActive: Bool = true) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.sortOrder = sortOrder
        self.isActive = isActive
    }
}

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

// 预置基础分类
func defaultCategories() -> [ServiceCategory] {
    let meijia = ServiceCategory(name: "美甲", sortOrder: 1)
    let hand = ServiceCategory(name: "手部", parentId: meijia.id, sortOrder: 1)
    let foot = ServiceCategory(name: "脚部", parentId: meijia.id, sortOrder: 2)
    let meijie = ServiceCategory(name: "美睫", sortOrder: 2)
    return [meijia, hand, foot, meijie]
}
