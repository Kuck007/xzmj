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

// 预置基础分类
func defaultCategories() -> [ServiceCategory] {
    let meijia = ServiceCategory(name: "美甲", sortOrder: 1)
    let hand = ServiceCategory(name: "手部", parentId: meijia.id, sortOrder: 1)
    let foot = ServiceCategory(name: "脚部", parentId: meijia.id, sortOrder: 2)
    let meijie = ServiceCategory(name: "美睫", sortOrder: 2)
    return [meijia, hand, foot, meijie]
}
