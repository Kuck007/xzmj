//
//  BackupManager.swift
//  杏子美甲管理系统
//

import Foundation
import SwiftData
import CryptoKit

/// 应用级设置快照（仪表盘布局等非数据库配置，原名 UserDefaults）
struct BackupAppSettings: Codable, Equatable {
    var dashboardWidgetOrder: [String]
    var dashboardHiddenWidgets: [String]
}

/// 全量备份数据容器（所有模块全部实体 + 应用设置）
struct BackupPackage: Codable, Equatable {
    let version: Int
    let exportedAt: Date
    let customers: [BackupCustomer]
    let technicians: [BackupTechnician]
    let serviceCategories: [BackupServiceCategory]
    let serviceItems: [BackupServiceItem]
    let records: [BackupServiceRecord]
    let appointments: [BackupAppointment]
    let orders: [BackupOrder]
    let inventoryItems: [BackupInventoryItem]
    let commissionRules: [BackupCommissionRule]
    let lashReminders: [BackupLashReminder]
    let rechargeRecords: [BackupRechargeRecord]
    let appSettings: BackupAppSettings?

    static let currentVersion = 1

    enum CodingKeys: String, CodingKey {
        case version, exportedAt, customers, technicians, serviceCategories,
             serviceItems, records, appointments, orders, inventoryItems,
             commissionRules, lashReminders, rechargeRecords, appSettings
    }

    init(
        exportedAt: Date = Date(),
        customers: [BackupCustomer],
        technicians: [BackupTechnician],
        serviceCategories: [BackupServiceCategory],
        serviceItems: [BackupServiceItem],
        records: [BackupServiceRecord],
        appointments: [BackupAppointment],
        orders: [BackupOrder],
        inventoryItems: [BackupInventoryItem],
        commissionRules: [BackupCommissionRule] = [],
        lashReminders: [BackupLashReminder] = [],
        rechargeRecords: [BackupRechargeRecord] = [],
        appSettings: BackupAppSettings? = nil
    ) {
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.customers = customers
        self.technicians = technicians
        self.serviceCategories = serviceCategories
        self.serviceItems = serviceItems
        self.records = records
        self.appointments = appointments
        self.orders = orders
        self.inventoryItems = inventoryItems
        self.commissionRules = commissionRules
        self.lashReminders = lashReminders
        self.rechargeRecords = rechargeRecords
        self.appSettings = appSettings
    }

    /// 严格向后兼容：所有"历史上后来才加进来的/早期备份可能缺失的"字段，一律 decodeIfPresent + 默认值
    /// —— 即使是 customers/technicians 这种必选字段，在**最早期备份**（备份体系比某些模块先出现时）也可能完全缺失 key，一律兜底。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? BackupPackage.currentVersion
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        customers = try c.decodeIfPresent([BackupCustomer].self, forKey: .customers) ?? []
        technicians = try c.decodeIfPresent([BackupTechnician].self, forKey: .technicians) ?? []
        serviceCategories = try c.decodeIfPresent([BackupServiceCategory].self, forKey: .serviceCategories) ?? []
        serviceItems = try c.decodeIfPresent([BackupServiceItem].self, forKey: .serviceItems) ?? []
        records = try c.decodeIfPresent([BackupServiceRecord].self, forKey: .records) ?? []
        appointments = try c.decodeIfPresent([BackupAppointment].self, forKey: .appointments) ?? []
        orders = try c.decodeIfPresent([BackupOrder].self, forKey: .orders) ?? []
        inventoryItems = try c.decodeIfPresent([BackupInventoryItem].self, forKey: .inventoryItems) ?? []
        commissionRules = try c.decodeIfPresent([BackupCommissionRule].self, forKey: .commissionRules) ?? []
        lashReminders = try c.decodeIfPresent([BackupLashReminder].self, forKey: .lashReminders) ?? []
        rechargeRecords = try c.decodeIfPresent([BackupRechargeRecord].self, forKey: .rechargeRecords) ?? []
        appSettings = try c.decodeIfPresent(BackupAppSettings.self, forKey: .appSettings)
    }
}

// MARK: - 数据备份映射结构体（纯 Codable，不受 @Model 限制）

struct BackupCustomer: Codable, Equatable {
    let id: UUID
    let name: String
    let phone: String
    let gender: String?
    let birthday: Date?
    let avatarURL: String?
    let wechat: String?
    let email: String?
    let tags: [String]
    let preferredTechnicianId: UUID?
    let membershipLevel: String
    let points: Int
    let totalSpent: Double
    let lastVisitDate: Date?
    let createdAt: Date
    let updatedAt: Date
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, phone, gender, birthday, avatarURL, wechat, email, tags,
             preferredTechnicianId, membershipLevel, points, totalSpent,
             lastVisitDate, createdAt, updatedAt, isActive
    }

    /// 旧备份兼容：缺失字段时用默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        phone = try c.decode(String.self, forKey: .phone)
        gender = try c.decodeIfPresent(String.self, forKey: .gender)
        birthday = try c.decodeIfPresent(Date.self, forKey: .birthday)
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        wechat = try c.decodeIfPresent(String.self, forKey: .wechat)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        tags = try c.decode([String].self, forKey: .tags)
        preferredTechnicianId = try c.decodeIfPresent(UUID.self, forKey: .preferredTechnicianId)
        membershipLevel = try c.decode(String.self, forKey: .membershipLevel)
        points = try c.decode(Int.self, forKey: .points)
        totalSpent = try c.decode(Double.self, forKey: .totalSpent)
        lastVisitDate = try c.decodeIfPresent(Date.self, forKey: .lastVisitDate)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        isActive = try c.decode(Bool.self, forKey: .isActive)
    }

    /// 成员逐一赋值 init（SwiftData → BackupStruct 映射使用）
    init(
        id: UUID, name: String, phone: String, gender: String?, birthday: Date?,
        avatarURL: String?, wechat: String?, email: String?, tags: [String],
        preferredTechnicianId: UUID?, membershipLevel: String, points: Int,
        totalSpent: Double, lastVisitDate: Date?, createdAt: Date, updatedAt: Date, isActive: Bool
    ) {
        self.id = id; self.name = name; self.phone = phone; self.gender = gender
        self.birthday = birthday; self.avatarURL = avatarURL; self.wechat = wechat
        self.email = email; self.tags = tags; self.preferredTechnicianId = preferredTechnicianId
        self.membershipLevel = membershipLevel; self.points = points; self.totalSpent = totalSpent
        self.lastVisitDate = lastVisitDate; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.isActive = isActive
    }
}

struct BackupTechnician: Codable, Equatable {
    let id: UUID
    let name: String
    let phone: String
    let avatarURL: String?
    let bio: String?
    let availableServices: [UUID]
    let rating: Int
    let totalServices: Int
    let baseSalary: Double?        // 可选：旧版备份无此字段
    let commissionRate: Double?    // 可选：旧版备份无此字段
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, phone, avatarURL, bio, availableServices, rating,
             totalServices, baseSalary, commissionRate, isActive
    }

    /// 向后兼容：baseSalary / commissionRate 缺失则给默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        phone = try c.decode(String.self, forKey: .phone)
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        bio = try c.decodeIfPresent(String.self, forKey: .bio)
        availableServices = try c.decodeIfPresent([UUID].self, forKey: .availableServices) ?? []
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 5
        totalServices = try c.decodeIfPresent(Int.self, forKey: .totalServices) ?? 0
        // 这两个字段是后续增加的，旧备份里可能没有
        baseSalary = try c.decodeIfPresent(Double.self, forKey: .baseSalary) ?? 0
        commissionRate = try c.decodeIfPresent(Double.self, forKey: .commissionRate) ?? 0.10
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }

    init(
        id: UUID, name: String, phone: String, avatarURL: String?, bio: String?,
        availableServices: [UUID], rating: Int, totalServices: Int,
        baseSalary: Double?, commissionRate: Double?, isActive: Bool
    ) {
        self.id = id; self.name = name; self.phone = phone; self.avatarURL = avatarURL
        self.bio = bio; self.availableServices = availableServices; self.rating = rating
        self.totalServices = totalServices; self.baseSalary = baseSalary
        self.commissionRate = commissionRate; self.isActive = isActive
    }
}

struct BackupServiceCategory: Codable, Equatable {
    let id: UUID
    let name: String
    let parentId: UUID?
    let sortOrder: Int
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, parentId, sortOrder, isActive
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        parentId = try c.decodeIfPresent(UUID.self, forKey: .parentId)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }
    init(id: UUID, name: String, parentId: UUID?, sortOrder: Int, isActive: Bool) {
        self.id = id; self.name = name; self.parentId = parentId
        self.sortOrder = sortOrder; self.isActive = isActive
    }
}

struct BackupServiceItem: Codable, Equatable {
    let id: UUID
    let name: String
    let categoryId: UUID
    let price: Double
    let durationMinutes: Int
    let itemDescription: String?
    let sortOrder: Int
    let isActive: Bool
    let isLashTouchUp: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, categoryId, price, durationMinutes,
             itemDescription, sortOrder, isActive, isLashTouchUp
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        categoryId = try c.decode(UUID.self, forKey: .categoryId)
        price = try c.decode(Double.self, forKey: .price)
        durationMinutes = try c.decodeIfPresent(Int.self, forKey: .durationMinutes) ?? 60
        itemDescription = try c.decodeIfPresent(String.self, forKey: .itemDescription)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        isLashTouchUp = try c.decodeIfPresent(Bool.self, forKey: .isLashTouchUp) ?? false
    }
    init(id: UUID, name: String, categoryId: UUID, price: Double,
         durationMinutes: Int, itemDescription: String?,
         sortOrder: Int, isActive: Bool, isLashTouchUp: Bool) {
        self.id = id; self.name = name; self.categoryId = categoryId
        self.price = price; self.durationMinutes = durationMinutes
        self.itemDescription = itemDescription; self.sortOrder = sortOrder
        self.isActive = isActive; self.isLashTouchUp = isLashTouchUp
    }
}

struct BackupServiceRecord: Codable, Equatable {
    let id: UUID
    let customerId: UUID
    let technicianId: UUID
    let serviceDate: Date
    let serviceItemIds: [UUID]
    let photos: [PhotoRecord]
    let materialsUsed: [MaterialItem]
    let accessories: [AccessoryItem]
    let craft: String?
    let hasConstruction: Bool
    let preferences: String?
    let notes: String?
    let isArchived: Bool
    let isPaid: Bool
    let reminderId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, customerId, technicianId, serviceDate, serviceItemIds,
             photos, materialsUsed, accessories, craft, hasConstruction,
             preferences, notes, isArchived, isPaid, reminderId
    }
    /// 向后兼容：craft / preferences / isArchived / isPaid 等后续新增字段缺失时给默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        customerId = try c.decode(UUID.self, forKey: .customerId)
        technicianId = try c.decode(UUID.self, forKey: .technicianId)
        serviceDate = try c.decode(Date.self, forKey: .serviceDate)
        serviceItemIds = try c.decodeIfPresent([UUID].self, forKey: .serviceItemIds) ?? []
        photos = try c.decodeIfPresent([PhotoRecord].self, forKey: .photos) ?? []
        // materialsUsed/accessories 内部 MaterialItem 已经自己做了 decodeIfPresent 兜底
        materialsUsed = try c.decodeIfPresent([MaterialItem].self, forKey: .materialsUsed) ?? []
        accessories = try c.decodeIfPresent([AccessoryItem].self, forKey: .accessories) ?? []
        craft = try c.decodeIfPresent(String.self, forKey: .craft)
        hasConstruction = try c.decodeIfPresent(Bool.self, forKey: .hasConstruction) ?? true
        preferences = try c.decodeIfPresent(String.self, forKey: .preferences)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isPaid = try c.decodeIfPresent(Bool.self, forKey: .isPaid) ?? false
        reminderId = try c.decodeIfPresent(UUID.self, forKey: .reminderId)
    }
    init(id: UUID, customerId: UUID, technicianId: UUID, serviceDate: Date,
         serviceItemIds: [UUID], photos: [PhotoRecord], materialsUsed: [MaterialItem],
         accessories: [AccessoryItem], craft: String?, hasConstruction: Bool,
         preferences: String?, notes: String?, isArchived: Bool, isPaid: Bool,
         reminderId: UUID?) {
        self.id = id; self.customerId = customerId; self.technicianId = technicianId
        self.serviceDate = serviceDate; self.serviceItemIds = serviceItemIds
        self.photos = photos; self.materialsUsed = materialsUsed
        self.accessories = accessories; self.craft = craft
        self.hasConstruction = hasConstruction; self.preferences = preferences
        self.notes = notes; self.isArchived = isArchived; self.isPaid = isPaid
        self.reminderId = reminderId
    }
}

struct BackupAppointment: Codable, Equatable {
    let id: UUID
    let customerId: UUID
    let technicianId: UUID
    let serviceItemIds: [UUID]
    let startTime: Date
    let endTime: Date
    let status: String
    let arrivedAt: Date?
    let notes: String?
    let createdAt: Date
    let reminderId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, customerId, technicianId, serviceItemIds, startTime, endTime,
             status, arrivedAt, notes, createdAt, reminderId
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        customerId = try c.decode(UUID.self, forKey: .customerId)
        technicianId = try c.decode(UUID.self, forKey: .technicianId)
        serviceItemIds = try c.decodeIfPresent([UUID].self, forKey: .serviceItemIds) ?? []
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decode(Date.self, forKey: .endTime)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "已预约"
        arrivedAt = try c.decodeIfPresent(Date.self, forKey: .arrivedAt)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? startTime
        reminderId = try c.decodeIfPresent(UUID.self, forKey: .reminderId)
    }
    init(id: UUID, customerId: UUID, technicianId: UUID, serviceItemIds: [UUID],
         startTime: Date, endTime: Date, status: String, arrivedAt: Date?,
         notes: String?, createdAt: Date, reminderId: UUID?) {
        self.id = id; self.customerId = customerId; self.technicianId = technicianId
        self.serviceItemIds = serviceItemIds; self.startTime = startTime
        self.endTime = endTime; self.status = status; self.arrivedAt = arrivedAt
        self.notes = notes; self.createdAt = createdAt; self.reminderId = reminderId
    }
}

struct BackupOrder: Codable, Equatable {
    let id: UUID
    let recordId: UUID?
    let customerId: UUID
    let technicianId: UUID?
    let lineItems: [OrderLineItem]
    let totalAmount: Double
    let originalTotal: Double
    let discountAmount: Double
    let paymentMethod: String?
    let walletDeducted: Double
    let topUpPaymentMethod: String?
    let paidAt: Date
    let notes: String?

    // 向后兼容：解码旧版备份时，缺少 originalTotal/discountAmount/walletDeducted 则用默认值
    enum CodingKeys: String, CodingKey {
        case id, recordId, customerId, technicianId, lineItems,
             totalAmount, originalTotal, discountAmount,
             paymentMethod, walletDeducted, topUpPaymentMethod, paidAt, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        recordId = try container.decodeIfPresent(UUID.self, forKey: .recordId)
            ?? container.decodeIfPresent(UUID.self, forKey: .recordId)
        customerId = try container.decode(UUID.self, forKey: .customerId)
        technicianId = try container.decodeIfPresent(UUID.self, forKey: .technicianId)
        lineItems = try container.decode([OrderLineItem].self, forKey: .lineItems)
        totalAmount = try container.decode(Double.self, forKey: .totalAmount)
        // 旧版备份无这两个字段，用 totalAmount 作为 originalTotal，优惠为 0
        originalTotal = try container.decodeIfPresent(Double.self, forKey: .originalTotal) ?? totalAmount
        discountAmount = try container.decodeIfPresent(Double.self, forKey: .discountAmount) ?? 0
        paymentMethod = try container.decodeIfPresent(String.self, forKey: .paymentMethod)
        walletDeducted = try container.decodeIfPresent(Double.self, forKey: .walletDeducted) ?? 0
        topUpPaymentMethod = try container.decodeIfPresent(String.self, forKey: .topUpPaymentMethod)
        paidAt = try container.decode(Date.self, forKey: .paidAt)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    init(
        id: UUID, recordId: UUID?, customerId: UUID, technicianId: UUID?,
        lineItems: [OrderLineItem], totalAmount: Double,
        originalTotal: Double, discountAmount: Double,
        paymentMethod: String?, walletDeducted: Double, topUpPaymentMethod: String?,
        paidAt: Date, notes: String?
    ) {
        self.id = id; self.recordId = recordId; self.customerId = customerId
        self.technicianId = technicianId; self.lineItems = lineItems
        self.totalAmount = totalAmount; self.originalTotal = originalTotal
        self.discountAmount = discountAmount; self.paymentMethod = paymentMethod
        self.walletDeducted = walletDeducted; self.topUpPaymentMethod = topUpPaymentMethod
        self.paidAt = paidAt; self.notes = notes
    }
}

struct BackupRechargeRecord: Codable, Equatable {
    let id: UUID
    let customerId: UUID
    let amount: Double
    let paymentMethod: String?
    let bonus: Double
    let operatorNote: String?
    let rechargeAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, customerId, amount, paymentMethod, bonus,
             operatorNote, rechargeAt, createdAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        customerId = try c.decode(UUID.self, forKey: .customerId)
        amount = try c.decode(Double.self, forKey: .amount)
        paymentMethod = try c.decodeIfPresent(String.self, forKey: .paymentMethod)
        bonus = try c.decodeIfPresent(Double.self, forKey: .bonus) ?? 0
        operatorNote = try c.decodeIfPresent(String.self, forKey: .operatorNote)
        rechargeAt = try c.decodeIfPresent(Date.self, forKey: .rechargeAt) ?? Date()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? rechargeAt
    }
    init(id: UUID, customerId: UUID, amount: Double, paymentMethod: String?,
         bonus: Double, operatorNote: String?, rechargeAt: Date, createdAt: Date) {
        self.id = id; self.customerId = customerId; self.amount = amount
        self.paymentMethod = paymentMethod; self.bonus = bonus
        self.operatorNote = operatorNote; self.rechargeAt = rechargeAt
        self.createdAt = createdAt
    }
}

struct BackupInventoryItem: Codable, Equatable {
    let id: UUID
    let name: String
    let brand: String?
    let colorCode: String?
    let category: String
    let quantity: Double
    let unit: String
    let lowStockThreshold: Double
    let notes: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, brand, colorCode, category, quantity, unit,
             lowStockThreshold, notes, updatedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        colorCode = try c.decodeIfPresent(String.self, forKey: .colorCode)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "消耗品"
        quantity = try c.decodeIfPresent(Double.self, forKey: .quantity) ?? 0
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? "个"
        lowStockThreshold = try c.decodeIfPresent(Double.self, forKey: .lowStockThreshold) ?? 1
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
    init(id: UUID, name: String, brand: String?, colorCode: String?, category: String,
         quantity: Double, unit: String, lowStockThreshold: Double,
         notes: String?, updatedAt: Date) {
        self.id = id; self.name = name; self.brand = brand
        self.colorCode = colorCode; self.category = category
        self.quantity = quantity; self.unit = unit
        self.lowStockThreshold = lowStockThreshold
        self.notes = notes; self.updatedAt = updatedAt
    }
}

struct BackupCommissionRule: Codable, Equatable {
    let id: UUID
    let categoryId: UUID
    let categoryName: String
    let rate: Double
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id, categoryId, categoryName, rate, isActive
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        categoryId = try c.decode(UUID.self, forKey: .categoryId)
        categoryName = try c.decode(String.self, forKey: .categoryName)
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 0.10
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }
    init(id: UUID, categoryId: UUID, categoryName: String, rate: Double, isActive: Bool) {
        self.id = id; self.categoryId = categoryId; self.categoryName = categoryName
        self.rate = rate; self.isActive = isActive
    }
}

final class BackupManager {
    static let shared = BackupManager()
    private init() {}

    /// App 启动时注入的 ModelContainer 引用（线程安全，只写一次只读）
    /// 后台线程创建独立 ModelContext 需要用到容器，避免触碰主线程 @Query 的对象
    weak var modelContainer: ModelContainer?

    // MARK: - 构建备份包（读取 SwiftData 模型属性需主线程）
    @MainActor
    func buildPackage(
        customers: [Customer],
        technicians: [Technician],
        categories: [ServiceCategory],
        serviceItems: [ServiceItem],
        records: [NailServiceRecord],
        appointments: [Appointment],
        orders: [Order],
        inventoryItems: [InventoryItem],
        commissionRules: [CommissionRule],
        lashReminders: [LashReminder] = [],
        rechargeRecords: [RechargeRecord] = [],
        appSettings: BackupAppSettings?
    ) -> BackupPackage {
        BackupPackage(
            customers: customers.map(BackupCustomer.init),
            technicians: technicians.map(BackupTechnician.init),
            serviceCategories: categories.map(BackupServiceCategory.init),
            serviceItems: serviceItems.map(BackupServiceItem.init),
            records: records.map(BackupServiceRecord.init),
            appointments: appointments.map(BackupAppointment.init),
            orders: orders.map(BackupOrder.init),
            inventoryItems: inventoryItems.map(BackupInventoryItem.init),
            commissionRules: commissionRules.map(BackupCommissionRule.init),
            lashReminders: lashReminders.map(BackupLashReminder.init),
            rechargeRecords: rechargeRecords.map(BackupRechargeRecord.init),
            appSettings: appSettings
        )
    }

    // MARK: - 纯数据编码/解码（不触碰 SwiftData，可安全在后台）

    func encodePackage(_ pkg: BackupPackage) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(pkg)
    }

    func decodePackage(from data: Data) throws -> BackupPackage {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(BackupPackage.self, from: data)
    }

    // MARK: - 导出：ModelContainer → Data

    @MainActor
    func exportPackage(from container: ModelContainer) throws -> Data {
        // 在当前线程创建独立的 ModelContext（绑定到同一 ModelContainer）
        let bgCtx = ModelContext(container)

        // 在这个后台 context 上 fetch 全部数据（SwiftData / Core Data 按线程隔离，这是官方推荐方式）
        let customers = try bgCtx.fetch(FetchDescriptor<Customer>())
        let technicians = try bgCtx.fetch(FetchDescriptor<Technician>())
        let categories = try bgCtx.fetch(FetchDescriptor<ServiceCategory>())
        let serviceItems = try bgCtx.fetch(FetchDescriptor<ServiceItem>())
        let records = try bgCtx.fetch(FetchDescriptor<NailServiceRecord>())
        let appointments = try bgCtx.fetch(FetchDescriptor<Appointment>())
        let orders = try bgCtx.fetch(FetchDescriptor<Order>())
        let inventoryItems = try bgCtx.fetch(FetchDescriptor<InventoryItem>())
        let commissionRules = try bgCtx.fetch(FetchDescriptor<CommissionRule>())
        let lashReminders = try bgCtx.fetch(FetchDescriptor<LashReminder>())
        let rechargeRecords = try bgCtx.fetch(FetchDescriptor<RechargeRecord>())

        // 收集应用级设置（仪表盘布局等，存于 UserDefaults）
        let appSettings = BackupAppSettings(
            dashboardWidgetOrder: DashboardPreferences.shared.snapshotOrder,
            dashboardHiddenWidgets: DashboardPreferences.shared.snapshotHidden
        )

        let pkg = buildPackage(
            customers: customers, technicians: technicians,
            categories: categories, serviceItems: serviceItems,
            records: records, appointments: appointments,
            orders: orders, inventoryItems: inventoryItems,
            commissionRules: commissionRules,
            lashReminders: lashReminders,
            rechargeRecords: rechargeRecords,
            appSettings: appSettings
        )
        return try encodePackage(pkg)
    }

    /// 使用 App 启动时注入的共享 ModelContainer 导出（无需从主线程 context 取任何属性）
    /// 这是 UI 层优先使用的方法，避免任何跨线程隐患
    @MainActor
    func exportFromSharedContainer() throws -> Data {
        guard let container = modelContainer else {
            throw NSError(domain: "BackupManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "备份管理器未初始化，请重启应用"])
        }
        return try exportPackage(from: container)
    }

    // MARK: - 自动兜底备份（每 15 天一次，不影响主动备份提醒）

    /// 加密备份文件的魔数头（4 字节 "ENCR"），用于区分明文 JSON 和加密备份
    private static let encryptedMagic = Data("ENCR".utf8)

    /// 判断数据是否为加密的自动备份文件
    func isEncryptedBackup(_ data: Data) -> Bool {
        data.starts(with: Self.encryptedMagic)
    }

    /// 加密备份数据（AES-256-GCM），输出格式：[魔数4字节][AES.GCM combined]
    func encryptBackup(_ data: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw NSError(domain: "BackupEncryption", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "加密失败：无法生成密封数据"])
        }
        return Self.encryptedMagic + combined
    }

    /// 解密加密备份数据，输入需以魔数开头
    func decryptBackup(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.starts(with: Self.encryptedMagic) else {
            throw NSError(domain: "BackupEncryption", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "不是加密备份文件"])
        }
        let encryptedPart = data.dropFirst(Self.encryptedMagic.count)
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedPart)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// 自动备份保留的最大数量（超过则删除最老的）
    private static let maxAutoBackups = 10

    /// 检查是否需要自动兜底备份，需要则执行并清理旧备份。
    /// 可安全在后台线程调用。返回是否执行了备份。
    /// 注意：自动备份只更新自动备份时间，不调用 markBackupDone()，
    /// 因此设置页显示的「上次备份」和备份提醒状态不受影响。
    @discardableResult
    func autoBackupIfNeeded() -> Bool {
        guard SecurityManager.shared.needsAutoBackup else { return false }

        do {
            var data = try exportFromSharedContainer()

            // 设置了密码则加密自动备份（AES-256-GCM），没设密码则明文
            if let key = SecurityManager.shared.autoBackupEncryptionKey() {
                data = try encryptBackup(data, key: key)
            }

            let fm = FileManager.default
            guard let appSupport = try? fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true
            ) else {
                print("[AutoBackup] 无法定位 Application Support 目录")
                return false
            }

            // 自动备份放在 Backups/Auto/ 子目录，与手动备份区分
            let autoDir = appSupport.appendingPathComponent("Backups/Auto", isDirectory: true)
            if !fm.fileExists(atPath: autoDir.path) {
                try fm.createDirectory(at: autoDir, withIntermediateDirectories: true)
            }

            let fileURL = autoDir.appendingPathComponent(Self.autoBackupFileName())
            try data.write(to: fileURL, options: .atomic)

            // 清理旧的自动备份，只保留最近 maxAutoBackups 个
            cleanupOldAutoBackups(in: autoDir, keep: Self.maxAutoBackups)

            // 只标记自动备份时间，不影响主动备份提醒
            SecurityManager.shared.markAutoBackupDone()
            print("[AutoBackup] 自动兜底备份完成: \(fileURL.lastPathComponent)")
            return true
        } catch {
            print("[AutoBackup] 自动备份失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 自动备份文件名（区分于手动备份）
    private static func autoBackupFileName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "杏子美甲-自动备份-\(f.string(from: Date())).json"
    }

    /// 清理指定目录下超过 keep 数量的最老备份文件
    private func cleanupOldAutoBackups(in dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // 只处理自动备份文件（按文件名前缀过滤）
        let backupFiles = files.filter { $0.lastPathComponent.hasPrefix("杏子美甲-自动备份-") }
        guard backupFiles.count > keep else { return }

        // 按创建时间排序，删除最老的
        let sorted = backupFiles.sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let dateB = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return dateA < dateB
        }
        for file in sorted.prefix(sorted.count - keep) {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - 导出：一键（主线程） SwiftData → Data —— 仅用于预览场景，不推荐大数据量

    @available(*, deprecated, message: "大数据量请使用 exportPackage(from: ModelContainer) 并在后台线程执行")
    @MainActor
    func exportPackage(
        customers: [Customer],
        technicians: [Technician],
        categories: [ServiceCategory],
        serviceItems: [ServiceItem],
        records: [NailServiceRecord],
        appointments: [Appointment],
        orders: [Order],
        inventoryItems: [InventoryItem],
        commissionRules: [CommissionRule] = [],
        lashReminders: [LashReminder] = [],
        appSettings: BackupAppSettings? = nil
    ) throws -> Data {
        let pkg = buildPackage(
            customers: customers, technicians: technicians,
            categories: categories, serviceItems: serviceItems,
            records: records, appointments: appointments,
            orders: orders, inventoryItems: inventoryItems,
            commissionRules: commissionRules,
            lashReminders: lashReminders,
            appSettings: appSettings
        )
        return try encodePackage(pkg)
    }

    // MARK: - 导入：Data → SwiftData（必须在主线程，触碰 ModelContext）

    @discardableResult
    func `import`(
        from data: Data,
        into context: ModelContext
    ) throws -> BackupPackage {
        let pkg = try decodePackage(from: data)
        try apply(package: pkg, to: context)
        return pkg
    }

    /// 应用已解码好的包到 Context（必须在主线程）
    @discardableResult
    func apply(package pkg: BackupPackage, to context: ModelContext) throws -> BackupPackage {
        // 1. 清空全部旧数据（按顺序避免关系约束）
        try context.delete(model: RechargeRecord.self)
        try context.delete(model: LashReminder.self)
        try context.delete(model: Order.self)
        try context.delete(model: NailServiceRecord.self)
        try context.delete(model: Appointment.self)
        try context.delete(model: InventoryItem.self)
        try context.delete(model: ServiceItem.self)
        try context.delete(model: ServiceCategory.self)
        try context.delete(model: Customer.self)
        try context.delete(model: Technician.self)
        try context.delete(model: CommissionRule.self)

        // 2. 插入新数据
        for c in pkg.customers { context.insert(Customer(from: c)) }
        for t in pkg.technicians { context.insert(Technician(from: t)) }
        for c in pkg.serviceCategories { context.insert(ServiceCategory(from: c)) }
        for s in pkg.serviceItems { context.insert(ServiceItem(from: s)) }
        for r in pkg.records { context.insert(NailServiceRecord(from: r)) }
        for a in pkg.appointments { context.insert(Appointment(from: a)) }
        for o in pkg.orders { context.insert(Order(from: o)) }
        for i in pkg.inventoryItems { context.insert(InventoryItem(from: i)) }
        for rule in pkg.commissionRules { context.insert(CommissionRule(from: rule)) }
        for r in pkg.lashReminders { context.insert(LashReminder(from: r)) }
        for r in pkg.rechargeRecords { context.insert(RechargeRecord(from: r)) }

        // 恢复应用级设置（仪表盘布局等）
        if let s = pkg.appSettings {
            DashboardPreferences.shared.restoreOrder(s.dashboardWidgetOrder)
            DashboardPreferences.shared.restoreHidden(s.dashboardHiddenWidgets)
        }

        try context.save()
        return pkg
    }

    /// 只读解析：用于读取备份文件的概要信息（可后台）
    func decodeSummary(from data: Data) throws -> BackupPackage {
        try decodePackage(from: data)
    }

    /// 生成备份文件名
    static func defaultFileName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "杏子美甲-数据备份-\(f.string(from: Date())).json"
    }
}

// MARK: - BackupStruct → SwiftData Convenience Init

extension Customer {
    convenience init(from b: BackupCustomer) {
        self.init(
            id: b.id, name: b.name, phone: b.phone, gender: b.gender,
            birthday: b.birthday, avatarURL: b.avatarURL, wechat: b.wechat,
            email: b.email, tags: b.tags, preferredTechnicianId: b.preferredTechnicianId,
            membershipLevel: b.membershipLevel, points: b.points, totalSpent: b.totalSpent,
            lastVisitDate: b.lastVisitDate, createdAt: b.createdAt, updatedAt: b.updatedAt,
            isActive: b.isActive
        )
    }
}

extension Technician {
    convenience init(from b: BackupTechnician) {
        self.init(
            id: b.id, name: b.name, phone: b.phone, avatarURL: b.avatarURL,
            bio: b.bio, availableServices: b.availableServices, rating: b.rating,
            totalServices: b.totalServices, baseSalary: b.baseSalary ?? 0,
            commissionRate: b.commissionRate ?? 0.10,
            isActive: b.isActive
        )
    }
}

extension ServiceCategory {
    convenience init(from b: BackupServiceCategory) {
        self.init(id: b.id, name: b.name, parentId: b.parentId, sortOrder: b.sortOrder, isActive: b.isActive)
    }
}

extension ServiceItem {
    convenience init(from b: BackupServiceItem) {
        self.init(
            id: b.id, name: b.name, categoryId: b.categoryId, price: b.price,
            durationMinutes: b.durationMinutes, itemDescription: b.itemDescription,
            sortOrder: b.sortOrder, isActive: b.isActive, isLashTouchUp: b.isLashTouchUp
        )
    }
}

extension NailServiceRecord {
    convenience init(from b: BackupServiceRecord) {
        self.init(
            id: b.id, customerId: b.customerId, technicianId: b.technicianId,
            serviceDate: b.serviceDate, serviceItemIds: b.serviceItemIds, photos: b.photos,
            materialsUsed: b.materialsUsed, accessories: b.accessories, craft: b.craft,
            hasConstruction: b.hasConstruction, preferences: b.preferences, notes: b.notes,
            isArchived: b.isArchived, isPaid: b.isPaid, reminderId: b.reminderId
        )
    }
}

extension Appointment {
    convenience init(from b: BackupAppointment) {
        self.init(
            id: b.id, customerId: b.customerId, technicianId: b.technicianId,
            serviceItemIds: b.serviceItemIds, startTime: b.startTime, endTime: b.endTime,
            status: b.status, arrivedAt: b.arrivedAt, notes: b.notes, createdAt: b.createdAt,
            reminderId: b.reminderId
        )
    }
}

extension Order {
    convenience init(from b: BackupOrder) {
        self.init(
            id: b.id, recordId: b.recordId, customerId: b.customerId,
            technicianId: b.technicianId, lineItems: b.lineItems, totalAmount: b.totalAmount,
            originalTotal: b.originalTotal, discountAmount: b.discountAmount,
            paymentMethod: b.paymentMethod, walletDeducted: b.walletDeducted,
            topUpPaymentMethod: b.topUpPaymentMethod, paidAt: b.paidAt, notes: b.notes
        )
    }
}

extension RechargeRecord {
    convenience init(from b: BackupRechargeRecord) {
        self.init(
            id: b.id, customerId: b.customerId, amount: b.amount,
            paymentMethod: b.paymentMethod, bonus: b.bonus,
            operatorNote: b.operatorNote, rechargeAt: b.rechargeAt,
            createdAt: b.createdAt
        )
    }
}

extension InventoryItem {
    convenience init(from b: BackupInventoryItem) {
        self.init(
            id: b.id, name: b.name, brand: b.brand, colorCode: b.colorCode,
            category: b.category, quantity: b.quantity, unit: b.unit,
            lowStockThreshold: b.lowStockThreshold, notes: b.notes, updatedAt: b.updatedAt
        )
    }
}

// MARK: - SwiftData → BackupStruct Convenience Init

extension BackupCustomer {
    init(_ c: Customer) {
        self.init(
            id: c.id, name: c.name, phone: c.phone, gender: c.gender,
            birthday: c.birthday, avatarURL: c.avatarURL, wechat: c.wechat,
            email: c.email, tags: c.tags, preferredTechnicianId: c.preferredTechnicianId,
            membershipLevel: c.membershipLevel, points: c.points, totalSpent: c.totalSpent,
            lastVisitDate: c.lastVisitDate, createdAt: c.createdAt, updatedAt: c.updatedAt,
            isActive: c.isActive
        )
    }
}

extension BackupTechnician {
    init(_ t: Technician) {
        id = t.id; name = t.name; phone = t.phone; avatarURL = t.avatarURL
        bio = t.bio; availableServices = t.availableServices; rating = t.rating
        totalServices = t.totalServices; baseSalary = t.baseSalary
        commissionRate = t.commissionRate; isActive = t.isActive
    }
}

extension BackupServiceCategory {
    init(_ c: ServiceCategory) {
        id = c.id; name = c.name; parentId = c.parentId
        sortOrder = c.sortOrder; isActive = c.isActive
    }
}

extension BackupServiceItem {
    init(_ s: ServiceItem) {
        id = s.id; name = s.name; categoryId = s.categoryId; price = s.price
        durationMinutes = s.durationMinutes; itemDescription = s.itemDescription
        sortOrder = s.sortOrder; isActive = s.isActive; isLashTouchUp = s.isLashTouchUp
    }
}

extension BackupServiceRecord {
    init(_ r: NailServiceRecord) {
        id = r.id; customerId = r.customerId; technicianId = r.technicianId
        serviceDate = r.serviceDate; serviceItemIds = r.serviceItemIds
        photos = r.photos; materialsUsed = r.materialsUsed; accessories = r.accessories
        craft = r.craft; hasConstruction = r.hasConstruction; preferences = r.preferences
        notes = r.notes; isArchived = r.isArchived; isPaid = r.isPaid; reminderId = r.reminderId
    }
}

extension BackupAppointment {
    init(_ a: Appointment) {
        id = a.id; customerId = a.customerId; technicianId = a.technicianId
        serviceItemIds = a.serviceItemIds; startTime = a.startTime; endTime = a.endTime
        status = a.status; arrivedAt = a.arrivedAt; notes = a.notes; createdAt = a.createdAt
        reminderId = a.reminderId
    }
}

extension BackupOrder {
    init(_ o: Order) {
        self.init(
            id: o.id, recordId: o.recordId, customerId: o.customerId,
            technicianId: o.technicianId, lineItems: o.lineItems,
            totalAmount: o.totalAmount,
            originalTotal: o.originalTotal,
            discountAmount: o.discountAmount,
            paymentMethod: o.paymentMethod, walletDeducted: o.walletDeducted,
            topUpPaymentMethod: o.topUpPaymentMethod, paidAt: o.paidAt, notes: o.notes
        )
    }
}

extension BackupRechargeRecord {
    init(_ r: RechargeRecord) {
        id = r.id; customerId = r.customerId; amount = r.amount
        paymentMethod = r.paymentMethod; bonus = r.bonus; operatorNote = r.operatorNote
        rechargeAt = r.rechargeAt; createdAt = r.createdAt
    }
}

extension BackupInventoryItem {
    init(_ i: InventoryItem) {
        id = i.id; name = i.name; brand = i.brand; colorCode = i.colorCode
        category = i.category; quantity = i.quantity; unit = i.unit
        lowStockThreshold = i.lowStockThreshold; notes = i.notes; updatedAt = i.updatedAt
    }
}
