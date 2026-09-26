//
//  AppCore.swift
//  杏子美甲管理系统
//
//  全 App 唯一的数据与计算中枢（“内核”）。
//
//  设计目标（2026-09-25）：
//  - 前台视图只负责“显示算好的结果”和“把用户操作交给内核”，自身不做全表计算；
//  - 全 App 只用【主 context】，杜绝多 context 撞库与跨 context 失效；
//  - 重计算在后台对【值类型快照】用多核并行（TaskGroup），算完回主线程，不卡界面；
//  - 算好的结果持久化一份，冷启动先显示上次结果。
//
//  内部分四层：
//   ② 数据层  Store   —— 13 张表启动时物化到内存数组
//   ③ 计算层  Engine  —— 统计 / 钱包 / 补睫时间，数据变化只算一次并缓存（多核并行）
//   ① 写入层  Command —— 增删改唯一入口，内部 save + 更新数据 + 触发重算
//   ④ 结果层  State   —— 算好的数字 / 分组，视图直接显示
//
//  第 0 步（本文件当前状态）：只实现骨架 + 数据层首次物化，不接任何模块。
//  现有视图仍走各自的 @Query，行为零影响。
//

import Foundation
import SwiftData
import CoreData
import Observation

// MARK: - 仪表盘结果类型（值类型，保证 @Observable 能检测整体替换）

/// 今日收银结果
struct TodayCheckoutResult: Equatable {
    var total: Double
    var orderCount: Int
    var average: Double
    var rechargeTotal: Double
    var recentOrders: [Order]
    static let zero = TodayCheckoutResult(total: 0, orderCount: 0, average: 0,
                                           rechargeTotal: 0, recentOrders: [])
}

/// 客户信息统计（9 项指标）
struct CustomerStats: Equatable {
    var totalCustomers: Int
    var newThisMonth: Int
    var memberCount: Int
    var visitsThisMonth: Int
    var visitingMembersThisMonth: Int
    var dormantCustomers: Int
    var repurchaseRate: String
    var repurchaseCycle: String
    var lowBalanceMembers: Int
    static let zero = CustomerStats(totalCustomers: 0, newThisMonth: 0, memberCount: 0,
                                     visitsThisMonth: 0, visitingMembersThisMonth: 0,
                                     dormantCustomers: 0, repurchaseRate: "0%",
                                     repurchaseCycle: "—", lowBalanceMembers: 0)
}

/// 单日收入（收入趋势图用）
struct DayRevenue: Identifiable {
    let id = UUID()
    let label: String
    let amount: Double
}

@MainActor
@Observable
final class AppCore {

    /// 全局唯一实例；同时通过 SwiftUI environment 注入（同一实例）。
    static let shared = AppCore()

    // MARK: - ④ 结果层 / 内核状态

    /// 是否已完成首次全量物化
    private(set) var isReady = false
    /// 内核正在物化（防止并发重入）
    private var isBootstrapping = false

    // MARK: - ② 数据层：13 张表的内存数组（主 context 物化）

    private(set) var customers: [Customer] = []
    private(set) var technicians: [Technician] = []
    private(set) var categories: [ServiceCategory] = []
    private(set) var serviceItems: [ServiceItem] = []
    private(set) var records: [NailServiceRecord] = []
    private(set) var appointments: [Appointment] = []
    private(set) var orders: [Order] = []
    private(set) var inventoryItems: [InventoryItem] = []
    private(set) var commissionRules: [CommissionRule] = []
    private(set) var lashReminders: [LashReminder] = []
    private(set) var recharges: [RechargeRecord] = []
    private(set) var reconciliations: [DailyReconciliation] = []
    private(set) var users: [User] = []

    /// 主 context 引用（启动后保存，供数据变更时 refresh 重新拉取）
    private weak var modelContext: ModelContext?

    // MARK: - ④ 结果层：仪表盘 7 组算好的结果（Widget 直接读，零计算）

    /// 客户/技师名称查找表（多个 Widget 共享）
    private(set) var customerNameMap: [UUID: String] = [:]
    private(set) var technicianNameMap: [UUID: String] = [:]

    /// 今日预约（已按时间排序）
    private(set) var dashboardTodayAppointments: [Appointment] = []
    /// 今日收银
    private(set) var dashboardTodayCheckout: TodayCheckoutResult = .zero
    /// 低库存预警（已按数量升序）
    private(set) var dashboardLowStock: [InventoryItem] = []
    /// 客户信息统计（9 项指标）
    private(set) var dashboardCustomerStats: CustomerStats = .zero
    /// 近 7 日收入趋势
    private(set) var dashboardIncomeTrend: [DayRevenue] = []
    private(set) var dashboardIncome7DayTotal: Double = 0
    /// 最近 5 条服务记录
    private(set) var dashboardRecentRecords: [NailServiceRecord] = []
    /// 待补睫提醒（已按到期天数升序）
    private(set) var dashboardPendingReminders: [LashReminder] = []
    private(set) var dashboardDueSoonCount: Int = 0

    // MARK: - ④ 结果层：客户列表聚合（CustomerView 直接读，不在 body 里算）

    /// 客户按拼音排序后的列表（refresh 时算一次，避免每次 body 渲染重排）
    private(set) var customersSortedByPinyin: [Customer] = []
    /// 每个客户的累计充值金额
    private(set) var rechargedByCustomer: [UUID: Double] = [:]
    /// 每个客户的钱包余额 = 累计充值 + 累计赠送 - 钱包扣除
    private(set) var walletByCustomer: [UUID: Double] = [:]
    /// 每个客户的累计消费 = 累计充值 + 订单中非钱包实付部分
    private(set) var totalSpentByCustomer: [UUID: Double] = [:]
    /// 每个客户最近一次有效到店时间
    private(set) var lastVisitByCustomer: [UUID: Date] = [:]
    /// 有效订单 ID 集合（排除纯补睫订单）
    private(set) var validOrderIds: Set<UUID> = []

    // MARK: - ④ 结果层：常用预排序列表（避免视图每次 body 重排）

    /// 订单按结账时间倒序
    private(set) var ordersByPaidAtDesc: [Order] = []
    /// 服务记录按服务日期倒序
    private(set) var recordsByServiceDateDesc: [NailServiceRecord] = []
    /// 预约按开始时间正序
    private(set) var appointmentsByStartTimeAsc: [Appointment] = []
    /// 充值记录按充值时间倒序
    private(set) var rechargesByRechargeAtDesc: [RechargeRecord] = []
    /// 技师按姓名正序
    private(set) var techniciansByNameAsc: [Technician] = []
    /// 补睫提醒按应补日期正序
    private(set) var lashRemindersByDueDateAsc: [LashReminder] = []

    // MARK: - ④ 结果层：通用查找表（避免视图每次 body 重建 Dictionary）

    private(set) var customerMap: [UUID: Customer] = [:]
    private(set) var serviceMap: [UUID: ServiceItem] = [:]
    private(set) var categoryMap: [UUID: ServiceCategory] = [:]
    private(set) var technicianMap: [UUID: Technician] = [:]

    private init() {}

    // MARK: - 启动物化

    /// 用【主 context】把 13 张表物化到内存。重复调用安全（只执行一次）。
    /// 必须在首屏渲染之后、且在 seed / 迁移完成之后调用。
    func bootstrapIfNeeded(context: ModelContext) async {
        guard !isReady, !isBootstrapping else { return }
        isBootstrapping = true

        // 先让出主线程，确保首屏已经上屏，再开始搬数据
        await Task.yield()
        let t0 = Date()

        modelContext = context
        await materialize(context: context, yielding: true)
        syncLashRemindersFromOrders()  // 启动时同步补睫提醒（幂等）

        isReady = true
        isBootstrapping = false

        recomputeDashboard()
        startObservingChanges()

        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("""
        [Core] 物化完成 \(ms)ms：客户\(customers.count) 技师\(technicians.count) \
        分类\(categories.count) 项目\(serviceItems.count) 预约\(appointments.count) \
        服务记录\(records.count) 订单\(orders.count) 库存\(inventoryItems.count) \
        提成规则\(commissionRules.count) 补睫提醒\(lashReminders.count) \
        充值\(recharges.count) 日结\(reconciliations.count) 用户\(users.count)
        """)
        #endif
    }

    /// 把 13 张表拉到内存数组。yielding=true 时大表之间让出主线程（首屏用）。
    private func materialize(context: ModelContext, yielding: Bool) async {
        // 小表：一次性取
        customers       = fetchAll(Customer.self, context: context)
        technicians     = fetchAll(Technician.self, context: context)
        categories      = fetchAll(ServiceCategory.self, context: context)
        serviceItems    = fetchAll(ServiceItem.self, context: context)
        inventoryItems  = fetchAll(InventoryItem.self, context: context)
        commissionRules = fetchAll(CommissionRule.self, context: context)
        recharges       = fetchAll(RechargeRecord.self, context: context)
        reconciliations = fetchAll(DailyReconciliation.self, context: context)
        users           = fetchAll(User.self, context: context)

        // 大表
        appointments = fetchAll(Appointment.self, context: context)
        if yielding { await Task.yield() }
        records = fetchAll(NailServiceRecord.self, context: context)
        if yielding { await Task.yield() }
        orders = fetchAll(Order.self, context: context)
        if yielding { await Task.yield() }
        lashReminders = fetchAll(LashReminder.self, context: context)
    }

    // MARK: - 数据变更刷新

    /// 重新拉取全部表并重算仪表盘。任何模块 save 后由通知自动调用，也可手动调。
    /// 用 DidSave 通知（只在 save 时触发，fetch 不触发），避免"fetch→通知→refresh"死循环。
    func refresh() {
        guard let context = modelContext, !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            await materialize(context: context, yielding: false)
            syncLashRemindersFromOrders()  // 可能新增提醒，幂等：第二轮无变化不再保存
            recomputeDashboard()
            isRefreshing = false
        }
    }

    // MARK: - 数据层工具

    /// 一次性拉取整张表（不排序，按 SQLite 自然顺序，最快）。
    private func fetchAll<T: PersistentModel>(_ type: T.Type, context: ModelContext) -> [T] {
        let descriptor = FetchDescriptor<T>()
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - ③ 计算层：仪表盘（第 1 步）

    /// 从内存数组一次性算出仪表盘全部 7 组结果。只算一遍，所有 Widget 共享。
    /// 口径与原 Widget 内联计算完全一致。
    func recomputeDashboard() {
        let cal = Calendar.current
        let now = Date()

        // 共享查找表（所有视图共享，不在 body 里重建）
        customerMap = Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) })
        serviceMap = Dictionary(uniqueKeysWithValues: serviceItems.map { ($0.id, $0) })
        categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        technicianMap = Dictionary(uniqueKeysWithValues: technicians.map { ($0.id, $0) })

        // 共享查找表
        customerNameMap = Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0.name) })
        technicianNameMap = Dictionary(uniqueKeysWithValues: technicians.map { ($0.id, $0.name) })

        // 0. 客户列表聚合（CustomerView 用，避免每次 body 重算）
        recomputeCustomerAggregates()

        // 1. 今日预约
        dashboardTodayAppointments = appointments
            .filter { cal.isDateInToday($0.startTime) }
            .sorted { $0.startTime < $1.startTime }

        // 2. 今日收银
        let todayOrders = orders.filter { cal.isDateInToday($0.paidAt) }
        let todayRecharges = recharges.filter { cal.isDateInToday($0.rechargeAt) }
        let orderIncome = todayOrders.reduce(0) { $0 + max(0, $1.totalAmount - $1.walletDeducted) }
        let rechargeIncome = todayRecharges.reduce(0) { $0 + $1.amount }
        let total = orderIncome + rechargeIncome
        let average = todayOrders.isEmpty ? 0 : total / Double(todayOrders.count)
        dashboardTodayCheckout = TodayCheckoutResult(
            total: total,
            orderCount: todayOrders.count,
            average: average,
            rechargeTotal: todayRecharges.reduce(0) { $0 + $1.amount },
            recentOrders: Array(todayOrders.sorted { $0.paidAt > $1.paidAt }.prefix(3))
        )

        // 3. 低库存预警
        dashboardLowStock = inventoryItems
            .filter(\.isLowStock)
            .sorted { $0.quantity < $1.quantity }

        // 4. 客户信息统计
        recomputeCustomerStats(cal: cal, now: now)

        // 5. 收入趋势（近 7 日）
        recomputeIncomeTrend(cal: cal, now: now)

        // 6. 最近服务记录
        dashboardRecentRecords = Array(records.sorted { $0.serviceDate > $1.serviceDate }.prefix(5))

        // 7. 补睫提醒
        let pending = lashReminders.filter { !$0.isCompleted && $0.daysUntilDue >= 0 }
        dashboardPendingReminders = pending.sorted { $0.daysUntilDue < $1.daysUntilDue }
        dashboardDueSoonCount = pending.filter { $0.isDueSoon }.count
    }

    /// 客户列表聚合：拼音排序、钱包余额、累计消费、最后到店。
    /// 在 refresh 时算一次，CustomerView 直接读结果，不在 body 里重算。
    private func recomputeCustomerAggregates() {
        // 拼音排序（pinyinSortKey 有全局缓存，名字不变零转换）
        customersSortedByPinyin = customers.sorted { pinyinLess($0.name, $1.name) }

        // 纯补睫订单判定（所有行项都是补睫项目）
        let serviceItemMap = Dictionary(uniqueKeysWithValues: serviceItems.map { ($0.id, $0) })
        func isPureLashTouchUp(_ order: Order) -> Bool {
            guard !order.lineItems.isEmpty else { return false }
            return order.lineItems.allSatisfy { item in
                serviceItemMap[item.serviceItemId]?.isLashTouchUp ?? false
            }
        }
        let validOrders = orders.filter { !isPureLashTouchUp($0) }
        validOrderIds = Set(validOrders.map { $0.id })

        // 累计充值（按客户）
        rechargedByCustomer = Dictionary(grouping: recharges, by: { $0.customerId })
            .mapValues { $0.reduce(0) { $0 + $1.amount } }

        // 累计赠送（按客户）
        let bonusByCustomer = Dictionary(grouping: recharges, by: { $0.customerId })
            .mapValues { $0.reduce(0) { $0 + $1.bonus } }

        // 钱包扣除（按客户）
        let walletUsed = Dictionary(grouping: orders, by: { $0.customerId })
            .mapValues { $0.reduce(0) { $0 + $1.walletDeducted } }

        // 钱包余额 = 充值 + 赠送 - 扣除
        let allWalletIds = Set(rechargedByCustomer.keys).union(walletUsed.keys)
        var wallet: [UUID: Double] = [:]
        for cid in allWalletIds {
            let recharge = rechargedByCustomer[cid] ?? 0
            let bonus = bonusByCustomer[cid] ?? 0
            let used = walletUsed[cid] ?? 0
            wallet[cid] = max(0, recharge + bonus - used)
        }
        walletByCustomer = wallet

        // 累计消费 = 充值 + 有效订单中非钱包实付
        let orderTopUp = Dictionary(grouping: validOrders, by: { $0.customerId })
            .mapValues { $0.reduce(0) { $0 + max(0, $1.totalAmount - $1.walletDeducted) } }
        let allSpentIds = Set(rechargedByCustomer.keys).union(orderTopUp.keys)
        var spent: [UUID: Double] = [:]
        for cid in allSpentIds {
            spent[cid] = (rechargedByCustomer[cid] ?? 0) + (orderTopUp[cid] ?? 0)
        }
        totalSpentByCustomer = spent

        // 最后到店时间（有效订单的最大 paidAt）
        lastVisitByCustomer = Dictionary(validOrders.map { ($0.customerId, $0.paidAt) },
                                         uniquingKeysWith: max)

        // 常用预排序列表（视图直接读，不在 body 里重排）
        ordersByPaidAtDesc = orders.sorted { $0.paidAt > $1.paidAt }
        recordsByServiceDateDesc = records.sorted { $0.serviceDate > $1.serviceDate }
        appointmentsByStartTimeAsc = appointments.sorted { $0.startTime < $1.startTime }
        rechargesByRechargeAtDesc = recharges.sorted { $0.rechargeAt > $1.rechargeAt }
        techniciansByNameAsc = technicians.sorted { $0.name < $1.name }
        lashRemindersByDueDateAsc = lashReminders.sorted { $0.dueDate < $1.dueDate }
    }

    /// 客户信息 9 项指标（口径与 CustomersWidget 完全一致）
    private func recomputeCustomerStats(cal: Calendar, now: Date) {
        let active = customers.filter(\.isActive)
        let serviceItemMap = Dictionary(uniqueKeysWithValues: serviceItems.map { ($0.id, $0) })

        // 纯补睫订单判定（所有行项都是补睫项目）
        func isPureLashTouchUp(_ order: Order) -> Bool {
            guard !order.lineItems.isEmpty else { return false }
            return order.lineItems.allSatisfy { item in
                serviceItemMap[item.serviceItemId]?.isLashTouchUp ?? false
            }
        }
        let validOrders = orders.filter { !isPureLashTouchUp($0) }

        let totalCustomers = active.count
        let newThisMonth = active.filter { cal.isDate($0.createdAt, equalTo: now, toGranularity: .month) }.count
        let memberCount = active.filter { $0.membershipLevel != "普通" }.count

        let ordersThisMonth = validOrders.filter { cal.isDate($0.paidAt, equalTo: now, toGranularity: .month) }
        let visitsThisMonth = ordersThisMonth.count

        let memberIds = Set(active.filter { $0.membershipLevel != "普通" }.map { $0.id })
        let visitingIds = Set(ordersThisMonth.map { $0.customerId })
        let visitingMembersThisMonth = memberIds.intersection(visitingIds).count

        // 沉睡客户：活跃客户中 3 个月以上无有效订单（含从未消费）
        let threeMonthsAgo = cal.date(byAdding: .month, value: -3, to: now) ?? now
        let lastVisitByCustomer: [UUID: Date] = Dictionary(
            validOrders.map { ($0.customerId, $0.paidAt) },
            uniquingKeysWith: max
        )
        let dormantCustomers = active.filter { c in
            guard let last = lastVisitByCustomer[c.id] else { return true }
            return last < threeMonthsAgo
        }.count

        // 复购率：本月有效订单中客户历史有效消费≥2次的订单占比
        let totalOrders = ordersThisMonth.count
        let repurchaseRate: String
        if totalOrders > 0 {
            let orderCountByCustomer = Dictionary(grouping: validOrders, by: { $0.customerId }).mapValues { $0.count }
            let repurchaseOrders = ordersThisMonth.filter { (orderCountByCustomer[$0.customerId] ?? 0) >= 2 }.count
            let pct = Int(Double(repurchaseOrders) / Double(totalOrders) * 100)
            repurchaseRate = "\(pct)%"
        } else {
            repurchaseRate = "0%"
        }

        // 复购周期：最近 6 个月内有效消费≥2次的客户，相邻两次消费间隔天数的平均值
        let sixMonthsAgo = cal.date(byAdding: .month, value: -6, to: now) ?? now
        let recentOrders = validOrders.filter { $0.paidAt >= sixMonthsAgo }
        let grouped = Dictionary(grouping: recentOrders, by: { $0.customerId })
        var allIntervals: [Double] = []
        for (_, customerOrders) in grouped {
            guard customerOrders.count >= 2 else { continue }
            let sorted = customerOrders.sorted { $0.paidAt < $1.paidAt }
            for i in 1..<sorted.count {
                let interval = sorted[i].paidAt.timeIntervalSince(sorted[i - 1].paidAt) / 86400
                allIntervals.append(interval)
            }
        }
        let repurchaseCycle: String
        if allIntervals.isEmpty {
            repurchaseCycle = "—"
        } else {
            let avg = allIntervals.reduce(0, +) / Double(allIntervals.count)
            repurchaseCycle = "\(Int(avg.rounded()))天"
        }

        // 低余额会员：会员中余额 < 50
        let recharged = Dictionary(grouping: recharges, by: { $0.customerId })
            .mapValues { $0.reduce(0) { $0 + $1.amount + $1.bonus } }
        let walletUsed = Dictionary(grouping: orders, by: { $0.customerId })
            .mapValues { $0.reduce(0) { $0 + $1.walletDeducted } }
        let lowBalanceMembers = active.filter { c in
            guard c.membershipLevel != "普通" else { return false }
            let balance = (recharged[c.id] ?? 0) - (walletUsed[c.id] ?? 0)
            return balance < 50
        }.count

        dashboardCustomerStats = CustomerStats(
            totalCustomers: totalCustomers,
            newThisMonth: newThisMonth,
            memberCount: memberCount,
            visitsThisMonth: visitsThisMonth,
            visitingMembersThisMonth: visitingMembersThisMonth,
            dormantCustomers: dormantCustomers,
            repurchaseRate: repurchaseRate,
            repurchaseCycle: repurchaseCycle,
            lowBalanceMembers: lowBalanceMembers
        )
    }

    /// 近 7 日收入趋势（口径与 IncomeTrendWidget 完全一致）
    private func recomputeIncomeTrend(cal: Calendar, now: Date) {
        let today = cal.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        var trend: [DayRevenue] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            let orderIncome = orders
                .filter { cal.isDate($0.paidAt, inSameDayAs: day) }
                .reduce(0) { $0 + max(0, $1.totalAmount - $1.walletDeducted) }
            let rechargeIncome = recharges
                .filter { cal.isDate($0.rechargeAt, inSameDayAs: day) }
                .reduce(0) { $0 + $1.amount }
            trend.append(DayRevenue(label: formatter.string(from: day), amount: orderIncome + rechargeIncome))
        }
        dashboardIncomeTrend = trend
        dashboardIncome7DayTotal = trend.reduce(0) { $0 + $1.amount }
    }

    // MARK: - 数据变更监听

    private var contextObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing: Bool = false

    /// 监听 Core Data 的 DidSave 通知（仅在 save 时触发，fetch 不触发），
    /// 任何模块增删改并 save 后自动 refresh。
    private func startObservingChanges() {
        guard contextObserver == nil else { return }
        contextObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh()
        }
    }

    /// 防抖 0.3s：连续写入只触发一次 refresh，避免抖动。
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    // MARK: - 补睫提醒同步（从订单自动生成 + 补关联）

    /// 同步补睫提醒与订单：
    /// 1) 扫描所有订单，为含美睫项目但缺补睫提醒的订单自动创建提醒；
    /// 2) 对 orderId 悬空的提醒，按客户+服务项目补关联订单。
    /// 幂等：已有提醒/已有 orderId 的跳过，第二轮调用无变化不保存。
    /// 在 refresh() 的 materialize 之后、recomputeDashboard 之前调用。
    private func syncLashRemindersFromOrders() {
        createMissingLashReminders()

        var changed = false
        let orderMap = Dictionary(uniqueKeysWithValues: orders.map { ($0.id, $0) })
        for r in lashReminders {
            // 手动创建的提醒用哨兵 noOrderID，不关联订单：跳过
            guard r.orderId != LashReminder.noOrderID else { continue }
            guard orderMap[r.orderId] == nil else { continue }
            let customerOrders = orders
                .filter { $0.customerId == r.customerId }
                .sorted { $0.paidAt > $1.paidAt }
            let reminderServiceSet = Set(r.serviceItemIds)
            let matched = customerOrders.first { order in
                let orderServiceIds = Set(order.lineItems.map { $0.serviceItemId })
                return !orderServiceIds.isDisjoint(with: reminderServiceSet)
            } ?? (r.serviceItemIds.isEmpty ? customerOrders.first : nil)
            if let matchedOrder = matched {
                r.orderId = matchedOrder.id
                changed = true
            }
        }
        if changed { save() }
    }

    /// 扫描所有订单，对含美睫项目但没有对应补睫提醒的订单自动创建提醒。
    private func createMissingLashReminders() {
        let existingOrderIds = Set(lashReminders.map { $0.orderId })
        let lashCategoryIds = lashCategoryIDs(in: categories)
        guard !lashCategoryIds.isEmpty else { return }

        var newReminders: [LashReminder] = []
        for order in orders {
            if existingOrderIds.contains(order.id) { continue }

            var lashItemIds: [UUID] = []
            for item in order.lineItems {
                guard let s = serviceMap[item.serviceItemId] else { continue }
                if s.isLashTouchUp { continue }
                var catId: UUID? = s.categoryId
                while let cid = catId {
                    if lashCategoryIds.contains(cid) { lashItemIds.append(s.id); break }
                    guard let parent = categoryMap[cid] else { break }
                    catId = parent.parentId
                }
            }
            if lashItemIds.isEmpty { continue }

            let level = customerMap[order.customerId]?.membershipLevel ?? "普通"
            let reminder = LashReminder(
                orderId: order.id,
                customerId: order.customerId,
                serviceItemIds: lashItemIds,
                paidAt: order.paidAt,
                dueDate: LashReminder.dueDate(from: order.paidAt, membershipLevel: level)
            )
            newReminders.append(reminder)
        }
        guard !newReminders.isEmpty else { return }
        insert(newReminders)
        // 新提醒追加到内存数组，避免本轮 recomputeDashboard 看不到
        lashReminders.append(contentsOf: newReminders)
    }

    // MARK: - ① 写入层（Command）
    // 规则：所有增删改只走这里；在主 context 完成 insert / delete + save，
    // 保存后由 DidSave 通知自动触发 refresh（重新物化 + 重算仪表盘）。
    // 视图不直接碰 context，只调用这些方法。

    /// 插入模型并保存。
    func insert<T: PersistentModel>(_ model: T) {
        guard let context = modelContext else { return }
        context.insert(model)
        try? context.save()
    }

    /// 批量插入并保存（一次 save，减少刷新次数）。
    func insert<T: PersistentModel>(_ models: [T]) {
        guard let context = modelContext, !models.isEmpty else { return }
        for model in models { context.insert(model) }
        try? context.save()
    }

    /// 删除单个模型并保存。
    func delete<T: PersistentModel>(_ model: T) {
        guard let context = modelContext else { return }
        context.delete(model)
        try? context.save()
    }

    /// 批量删除并保存（一次 save，减少刷新次数）。
    func delete<T: PersistentModel>(_ models: [T]) {
        guard let context = modelContext, !models.isEmpty else { return }
        for model in models { context.delete(model) }
        try? context.save()
    }

    /// 仅保存（用于直接修改模型属性后统一落盘，如编辑表单）。
    func save() {
        try? modelContext?.save()
    }

    /// 删除并忽略错误（与 delete 等效，语义上用于"确认删除"场景）。
    func deleteAndSave<T: PersistentModel>(_ model: T) {
        delete(model)
    }
}
