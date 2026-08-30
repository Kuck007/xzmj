//
//  CommissionRule.swift
//  杏子美甲管理系统
//
//  提成规则：按服务「顶层分类」配置提成比例（如 美甲 10%、美睫 12%…）。
//  categoryId 指向 ServiceCategory 的顶层根节点（parentId == nil）。
//

import Foundation
import SwiftData

@Model
final class CommissionRule {
    @Attribute(.unique) var id: UUID = UUID()
    var categoryId: UUID = UUID()
    var categoryName: String = ""
    var rate: Double = 0.10
    var isActive: Bool = true

    init(id: UUID = UUID(), categoryId: UUID, categoryName: String,
         rate: Double = 0.10, isActive: Bool = true) {
        self.id = id
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.rate = rate
        self.isActive = isActive
    }
}

// MARK: - 备份映射（定义在 BackupManager.swift 内，这里只保留双向 init 以避免重复）

extension CommissionRule {
    convenience init(from b: BackupCommissionRule) {
        self.init(id: b.id, categoryId: b.categoryId, categoryName: b.categoryName,
                  rate: b.rate, isActive: b.isActive)
    }
}

extension BackupCommissionRule {
    init(_ r: CommissionRule) {
        self.init(id: r.id, categoryId: r.categoryId, categoryName: r.categoryName,
                  rate: r.rate, isActive: r.isActive)
    }
}
