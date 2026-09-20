//
//  LashReminder.swift
//  杏子美甲管理系统
//
//  补睫提醒：根据已付款订单中的美睫服务项目自动生成。
//  普通会员：付款日起 10 天；银卡/金卡会员：付款日起 15 天。
//  具体天数可在「补睫时间设置」中修改。
//
//  天数固化规则（2026-09-21 改造）：
//  应补日期 dueDate 在提醒「创建时」按当时的会员等级 + 当时的设置天数一次性算好并落库，
//  此后不再随「补睫天数设置」修改、客户会员等级升级而追溯重算。
//  - 改设置 / 升级会员：只对之后新生成的提醒生效，老提醒保持原日期。
//  - 已付款订单不允许改付款时间，只能删除（删除会按 orderId 联动删除本提醒），重新付款再生成新提醒，
//    因此不存在「订单付款时间被改、提醒需跟随平移」的场景。
//  - 唯一的人工重算入口：用户在「修改」表单里主动改客户/付款日期并保存。
//

import Foundation
import SwiftData

// MARK: - 补睫时间设置（可配置会员等级对应的补睫天数）

/// 管理补睫提醒的会员等级 → 补睫天数映射。
/// 持久化到 UserDefaults，新增会员等级自动使用默认值。
final class LashReminderSettings {
    static let shared = LashReminderSettings()
    private let d = UserDefaults.standard
    private init() {}

    /// 默认各等级补睫天数
    private let defaults: [String: Int] = [
        "普通": 10,
        "银卡": 15,
        "金卡": 15
    ]

    /// 获取指定会员等级的补睫天数（未配置则使用默认值）
    func days(for membershipLevel: String) -> Int {
        let key = "lash.days.\(membershipLevel)"
        if let v = d.object(forKey: key) as? Int { return v }
        return defaults[membershipLevel] ?? 10
    }

    /// 保存指定会员等级的补睫天数
    func setDays(_ days: Int, for membershipLevel: String) {
        let key = "lash.days.\(membershipLevel)"
        d.set(days, forKey: key)
    }

    /// 所有已知会员等级（固定顺序）
    static var membershipLevels: [String] { ["普通", "银卡", "金卡"] }
}

/// 管理「美睫大类」的标记：哪些顶级分类是美睫分类。
///
/// 关键设计：只把顶级分类的 UUID 存到 UserDefaults，**不往 ServiceCategory 这个 @Model 上加字段**。
/// 历史教训：给 @Model 加布尔字段会触发 SwiftData 轻量迁移，迁移后补睫页（动态扫全量订单）明显卡顿。
/// 存 UserDefaults 完全不动 schema，零迁移、零清库风险。
/// 勾选某顶级分类后，该分类及其所有子分类下的项目都视为美睫项目（子分类/项目强制继承，不单独设开关）。
final class LashCategorySettings {
    static let shared = LashCategorySettings()
    private let d = UserDefaults.standard
    private let key = "lash.rootCategoryIds"
    private init() {}

    /// 美睫顶级分类的 UUID（支持多个，默认一个）
    var rootIds: [UUID] {
        (d.stringArray(forKey: key) ?? []).compactMap { UUID(uuidString: $0) }
    }

    /// 某顶级分类是否被标记为美睫大类
    func isLashRoot(_ id: UUID) -> Bool {
        rootIds.contains(id)
    }

    /// 设置/取消某顶级分类的美睫标记
    func setLashRoot(_ id: UUID, isLash: Bool) {
        var ids = Set(rootIds)
        if isLash { ids.insert(id) } else { ids.remove(id) }
        d.set(ids.map { $0.uuidString }, forKey: key)
    }

    /// 删除分类时清理其标记，避免留下悬空 UUID
    func remove(_ id: UUID) {
        let ids = rootIds.filter { $0 != id }
        d.set(ids.map { $0.uuidString }, forKey: key)
    }

    /// 一次性替换为给定 UUID 集合（仅用于首启/升级时按旧 name 逻辑迁移一次）
    func replaceRootIds(_ ids: [UUID]) {
        d.set(ids.map { $0.uuidString }, forKey: key)
    }
}

// MARK: - 补睫提醒模型

@Model
final class LashReminder {
    /// 哨兵值：手动创建、不关联任何订单的补睫提醒，orderId 统一用它。
    /// 真实订单 id 是随机 UUID，永不等于全 0，因此：
    /// 1) sync 的悬空关联逻辑会跳过它，不会被错误绑定到某个订单；
    /// 2) 删除订单时 `orderId == 订单.id` 的联动删除不会命中它，避免手动提醒被误删；
    /// 3) 不影响「标记已补睫」——精确匹配走 LashReminder.id、模糊匹配走 customerId+dueDate，都不读 orderId。
    static let noOrderID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    @Attribute(.unique) var id: UUID = UUID()
    var orderId: UUID = UUID()
    var customerId: UUID = UUID()
    var serviceItemIds: [UUID] = []
    var paidAt: Date = Date()
    var dueDate: Date = Date()
    var isCompleted: Bool = false
    var completedAt: Date?
    /// 标记本提醒为已补睫的那笔「补睫付款订单」id（精确/模糊两条付款标记路径都会写入）。
    /// 删除该补睫付款订单时，据此把提醒恢复为未补睫；nil 表示未完成、或由用户手动点「已补睫」标记（不随任何删单恢复）。
    var completedByOrderId: UUID? = nil
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        orderId: UUID,
        customerId: UUID,
        serviceItemIds: [UUID] = [],
        paidAt: Date,
        dueDate: Date,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        completedByOrderId: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.orderId = orderId
        self.customerId = customerId
        self.serviceItemIds = serviceItemIds
        self.paidAt = paidAt
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.completedByOrderId = completedByOrderId
        self.createdAt = createdAt
    }

    /// 根据会员等级计算补睫天数（从可配置设置读取）
    static func reminderDays(for membershipLevel: String) -> Int {
        LashReminderSettings.shared.days(for: membershipLevel)
    }

    /// 根据会员等级计算应补睫日期
    static func dueDate(from paidAt: Date, membershipLevel: String) -> Date {
        let days = reminderDays(for: membershipLevel)
        return Calendar.current.date(byAdding: .day, value: days, to: paidAt) ?? paidAt
    }

    /// 距离应补睫日期的天数（基于创建时固化的 dueDate，不再随设置/等级/订单动态重算）。
    /// 负数 = 已过期几天；0 = 今天到期；正数 = 还有几天。
    var daysUntilDue: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let due = cal.startOfDay(for: dueDate)
        return cal.dateComponents([.day], from: today, to: due).day ?? 0
    }

    /// 是否已过期（应补睫日期已过且未完成）
    var isOverdue: Bool {
        !isCompleted && daysUntilDue < 0
    }

    /// 是否即将到期（3天内）
    var isDueSoon: Bool {
        !isCompleted && daysUntilDue >= 0 && daysUntilDue <= 3
    }
}

// MARK: - 备份映射

struct BackupLashReminder: Codable, Equatable {
    let id: UUID
    let orderId: UUID
    let customerId: UUID
    let serviceItemIds: [UUID]
    let paidAt: Date
    let dueDate: Date
    let isCompleted: Bool
    let completedAt: Date?
    // 新增可选字段：旧备份无此 key 时，Codable 对可选属性自动解为 nil（向后兼容）
    let completedByOrderId: UUID?
    let createdAt: Date
}

extension LashReminder {
    convenience init(from b: BackupLashReminder) {
        self.init(id: b.id, orderId: b.orderId, customerId: b.customerId,
                  serviceItemIds: b.serviceItemIds, paidAt: b.paidAt,
                  dueDate: b.dueDate, isCompleted: b.isCompleted,
                  completedAt: b.completedAt,
                  completedByOrderId: b.completedByOrderId,
                  createdAt: b.createdAt)
    }
}

extension BackupLashReminder {
    init(_ r: LashReminder) {
        self.init(id: r.id, orderId: r.orderId, customerId: r.customerId,
                  serviceItemIds: r.serviceItemIds, paidAt: r.paidAt,
                  dueDate: r.dueDate, isCompleted: r.isCompleted,
                  completedAt: r.completedAt,
                  completedByOrderId: r.completedByOrderId,
                  createdAt: r.createdAt)
    }
}
