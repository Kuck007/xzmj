//
//  NailServiceRecord.swift
//  杏子美甲管理系统
//
//  Created by 李高翔 on 2026/8/1.
//

import Foundation
import SwiftData

// 服务记录（"备份"模块）：客户做完一次服务的完整留档
/// ⚠️ 所有非可选字段均有默认值，确保 SwiftData 轻量迁移安全
@Model
final class NailServiceRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var customerId: UUID = UUID()
    var technicianId: UUID = UUID()
    var serviceDate: Date = Date()
    var serviceItemIds: [UUID] = []
    var photos: [PhotoRecord] = []
    var materialsUsed: [MaterialItem] = []
    var accessories: [AccessoryItem] = []
    var craft: String?
    var hasConstruction: Bool = false
    var preferences: String?
    var notes: String?
    var isArchived: Bool = false
    var isPaid: Bool = false
    var reminderId: UUID?

    init(
        id: UUID = UUID(),
        customerId: UUID,
        technicianId: UUID,
        serviceDate: Date = Date(),
        serviceItemIds: [UUID] = [],
        photos: [PhotoRecord] = [],
        materialsUsed: [MaterialItem] = [],
        accessories: [AccessoryItem] = [],
        craft: String? = nil,
        hasConstruction: Bool = false,
        preferences: String? = nil,
        notes: String? = nil,
        isArchived: Bool = false,
        isPaid: Bool = false,
        reminderId: UUID? = nil
    ) {
        self.id = id
        self.customerId = customerId
        self.technicianId = technicianId
        self.serviceDate = serviceDate
        self.serviceItemIds = serviceItemIds
        // 任何方式进入 NailServiceRecord 的照片都走一次压缩：
        // 1) 新上传照片通过 PhotoRecord.init 已经压过一遍（见上）
        // 2) 从备份导入 / 代码迁移旧数据的照片（没有走 PhotoRecord 成员 init）在这里再兜底压一遍
        //    保证整个数据库/备份里的图永远是 JPEG 压缩版，体积控制在 80-200KB/张左右
        self.photos = photos.map { p in
            guard let d = p.imageData,
                  let compressed = ImageCompressor.compressToJPEG(d) else { return p }
            var mut = p
            mut.imageData = compressed
            return mut
        }
        self.materialsUsed = materialsUsed
        self.accessories = accessories
        self.craft = craft
        self.hasConstruction = hasConstruction
        self.preferences = preferences
        self.notes = notes
        self.isArchived = isArchived
        self.isPaid = isPaid
        self.reminderId = reminderId
    }
}

// 照片记录（嵌入值类型）
struct PhotoRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var angle: String          // "正面" / "侧面" / "指尖特写"
    var note: String?
    var timestamp: Date
    var imageData: Data?       // 图片二进制数据

    enum CodingKeys: String, CodingKey {
        case id, angle, note, timestamp, imageData
    }

    init(id: UUID = UUID(), angle: String, note: String? = nil, timestamp: Date = Date(), imageData: Data? = nil) {
        self.id = id
        self.angle = angle
        self.note = note
        self.timestamp = timestamp
        // 统一转成 JPEG 压缩保存（长边 2000px，质量 0.7），
        // 支持 PNG/JPEG/BMP/HEIC/WebP/部分 RAW 等 macOS 原生可读格式，
        // 自动等比缩放 + EXIF 方向修正，显著降低数据库和备份体积
        self.imageData = imageData.flatMap { ImageCompressor.compressToJPEG($0) } ?? nil
    }

    /// 向后兼容：未来 PhotoRecord 加字段 / angle 改名（比如叫 title），旧备份里缺 key 也能正常导入
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        angle = try c.decodeIfPresent(String.self, forKey: .angle) ?? "正面"
        note = try c.decodeIfPresent(String.self, forKey: .note)
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
    }
}

// 用料记录（色胶/底胶/封层等）
struct MaterialItem: Codable, Identifiable, Equatable {
    let id: UUID
    var brand: String          // 品牌名
    var location: String       // 位置（左手/右手/第N指/全手等）
    var colorCode: String      // 色号
    var quantity: String       // 用量描述（保留以兼容旧数据，UI不再编辑）
    var category: String       // "底胶" / "功能胶" / "色胶" / "封层" / 用户自定义字符串

    /// 类别预设选项（用于 Picker）
    static let presetCategories: [String] = ["底胶", "功能胶", "色胶", "封层"]
    /// 自定义类别的哨兵值，选此项时弹出输入框
    static let customSentinel: String = "自定义"

    enum CodingKeys: String, CodingKey {
        case id, brand, location, colorCode, quantity, category
    }

    init(
        id: UUID = UUID(),
        brand: String,
        location: String = "",
        colorCode: String,
        quantity: String = "",
        category: String = "色胶"
    ) {
        self.id = id
        self.brand = brand
        self.location = location
        self.colorCode = colorCode
        self.quantity = quantity
        self.category = category
    }

    /// 自定义解码：location 为新增字段，旧数据没有此 key 时用空字符串兜底
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        brand = try container.decode(String.self, forKey: .brand)
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
        colorCode = try container.decode(String.self, forKey: .colorCode)
        quantity = try container.decodeIfPresent(String.self, forKey: .quantity) ?? ""
        category = try container.decode(String.self, forKey: .category)
    }
}

// 饰品记录
struct AccessoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String           // 饰品名
    var quantity: Int
    var note: String?

    enum CodingKeys: String, CodingKey { case id, name, quantity, note }

    init(id: UUID = UUID(), name: String, quantity: Int = 1, note: String? = nil) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.note = note
    }

    /// 向后兼容：
    /// - id / name / note 缺失时用默认值
    /// - quantity：早期备份可能是 String（比如"2个"），要先按 String 解再转 Int；也可能就是 Int
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
        // quantity 兼容两种：直接 Int、或者以前的字符串描述
        if let intValue = try? c.decode(Int.self, forKey: .quantity) {
            quantity = intValue
        } else if let strValue = try? c.decodeIfPresent(String.self, forKey: .quantity) {
            let digits = strValue.filter { $0.isNumber }
            quantity = digits.isEmpty ? 1 : (Int(digits) ?? 1)
        } else {
            quantity = 1
        }
    }
}
