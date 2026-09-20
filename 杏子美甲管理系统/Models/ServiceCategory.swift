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

// MARK: - 美睫分类识别（基于 LashCategorySettings 的 UUID，替代旧的 name == "美睫" 硬编码）

/// 返回某分类及其所有后代分类的 ID 集合（沿 parentId 自引用树展开）。
/// - Parameters:
///   - rootId: 起点分类 ID（结果包含它自身）
///   - categories: 全部分类
func descendantCategoryIds(of rootId: UUID, in categories: [ServiceCategory]) -> Set<UUID> {
    var result: Set<UUID> = [rootId]
    var changed = true
    while changed {
        changed = false
        for c in categories {
            if let pid = c.parentId, result.contains(pid), !result.contains(c.id) {
                result.insert(c.id)
                changed = true
            }
        }
    }
    return result
}

/// 所有「美睫相关分类」的 ID 集合：被标记为美睫大类的顶级分类 + 其全部子分类。
/// 判断服务项目是否属于美睫大类时，检查 item.categoryId 是否在此集合内即可。
/// 取代历史上散落在多处的 `name == "美睫"` 字符串匹配。
func lashCategoryIDs(in categories: [ServiceCategory]) -> Set<UUID> {
    var result = Set<UUID>()
    for rootId in LashCategorySettings.shared.rootIds {
        result.formUnion(descendantCategoryIds(of: rootId, in: categories))
    }
    return result
}
