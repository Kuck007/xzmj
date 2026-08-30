//
//  InventoryItem.swift
//  杏子美甲管理系统
//
//  Created by 李高翔 on 2026/8/1.
//

import Foundation
import SwiftData

// 库存项（"库存管理"模块）：完全自定义，可统计色胶色号/消耗品数量及库存状态
@Model
final class InventoryItem {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String = ""
    var brand: String?
    var colorCode: String?
    var category: String = "消耗品"
    var quantity: Double = 0
    var unit: String = "个"
    var lowStockThreshold: Double = 1
    var notes: String?
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        name: String,
        brand: String? = nil,
        colorCode: String? = nil,
        category: String = "消耗品",
        quantity: Double = 0,
        unit: String = "个",
        lowStockThreshold: Double = 1,
        notes: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.colorCode = colorCode
        self.category = category
        self.quantity = quantity
        self.unit = unit
        self.lowStockThreshold = lowStockThreshold
        self.notes = notes
        self.updatedAt = updatedAt
    }

    var isLowStock: Bool { quantity <= lowStockThreshold }
}
