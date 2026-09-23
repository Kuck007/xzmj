//
//  DashboardView.swift
//  杏子美甲管理系统
//
//  首页仪表盘：可扩展 Widget 框架。
//
//  ===== 如何新增一个仪表盘组件（可塑性说明）=====
//  1) 在文件底部写一个 `struct 某某Widget: View`，内部用 @Query 拉数据、任意画 UI；
//  2) 在 `DashboardRegistry.all` 里注册一行描述：
//        .init(id: "唯一.id", title: "标题", icon: "sf符号", tint: .color,
//              spans: 1,           // 占 1 或 2 列
//              module: .预约模块) {  // "查看全部"跳转到的模块，nil 则隐藏该按钮
//            AnyView(某某Widget())
//        }
//  3) 完成。新组件自动出现在看板，且用户可随时在"编辑布局"里开关/排序。
//  所有组件顺序与显隐偏好持久化在 UserDefaults，不会因重启丢失。
//

import SwiftUI
import SwiftData
import Charts
import AppKit
import Combine

// MARK: - 跨模块跳转（Widget 点"查看全部"→ 切到对应模块）

struct OpenDashboardModuleKey: EnvironmentKey {
    static let defaultValue: (SidebarItem) -> Void = { _ in }
}

extension EnvironmentValues {
    var openDashboardModule: (SidebarItem) -> Void {
        get { self[OpenDashboardModuleKey.self] }
        set { self[OpenDashboardModuleKey.self] = newValue }
    }
}

// MARK: - Widget 描述（注册表条目）

/// 一个仪表盘组件的完整描述。实际内容通过 `makeView` 延迟构建，
/// 确保 @Query 在 SwiftUI 渲染时才初始化，数据才能正确注入。
struct DashboardWidgetDescriptor: Identifiable {
    let id: String                 // 稳定 id，用于持久化顺序/显隐
    let title: String
    let icon: String
    let tint: Color
    var spans: Int = 1             // 占 1 或 2 列
    var module: SidebarItem?       // "查看全部"跳转目标
    let makeView: () -> AnyView

    init(id: String, title: String, icon: String, tint: Color,
         spans: Int = 1, module: SidebarItem? = nil,
         @ViewBuilder _ makeView: @escaping () -> AnyView) {
        self.id = id
        self.title = title
        self.icon = icon
        self.tint = tint
        self.spans = spans
        self.module = module
        self.makeView = makeView
    }
}

// MARK: - 组件注册表（以后新功能在这里登记即可）

enum DashboardRegistry {
    /// 全部已注册的组件（顺序即默认顺序）
    static var all: [DashboardWidgetDescriptor] {
        [
            .init(id: "today.appointments", title: "今日预约", icon: "calendar",
                  tint: .brandMono, module: .appointments) {
                AnyView(TodayAppointmentsWidget())
            },
            .init(id: "checkout.today", title: "今日收银", icon: "creditcard",
                  tint: .brandMono, module: .orders) {
                AnyView(CheckoutTodayWidget())
            },
            .init(id: "inventory.lowstock", title: "低库存预警", icon: "shippingbox",
                  tint: .brandMono, module: .inventory) {
                AnyView(LowStockWidget())
            },
            .init(id: "customers.overview", title: "客户信息", icon: "person.2",
                  tint: .brandMono, module: .customers) {
                AnyView(CustomersWidget())
            },
            .init(id: "income.trend", title: "收入统计", icon: "chart.bar",
                  tint: .brandMono, module: .income) {
                AnyView(IncomeTrendWidget())
            },
            .init(id: "records.recent", title: "服务记录", icon: "photo.on.rectangle",
                  tint: .brandMono, module: .records) {
                AnyView(RecentRecordsWidget())
            },
            .init(id: "lash.reminder", title: "补睫提醒", icon: "bell.badge",
                  tint: .brandMono, module: .lashReminder) {
                AnyView(LashReminderWidget())
            }
        ]
    }
}

// MARK: - 持久化（顺序 + 显隐）

final class DashboardPreferences {
    static let shared = DashboardPreferences()
    private let d = UserDefaults.standard
    private let orderKey = "dashboard.widgetOrder"
    private let hiddenKey = "dashboard.hiddenWidgets"
    private init() {}

    /// 按用户保存的顺序返回；未记录过的新组件自动追加到末尾（保证新增即可见）
    func ordered(_ all: [DashboardWidgetDescriptor]) -> [DashboardWidgetDescriptor] {
        let stored = d.stringArray(forKey: orderKey) ?? []
        var result: [DashboardWidgetDescriptor] = []
        for id in stored {
            if let w = all.first(where: { $0.id == id }) { result.append(w) }
        }
        for w in all where !stored.contains(w.id) { result.append(w) }
        return result
    }

    func saveOrder(_ ids: [String]) { d.set(ids, forKey: orderKey) }

    func hidden() -> Set<String> { Set(d.stringArray(forKey: hiddenKey) ?? []) }

    func setHidden(_ id: String, _ isHidden: Bool) {
        var arr = d.stringArray(forKey: hiddenKey) ?? []
        if isHidden {
            if !arr.contains(id) { arr.append(id) }
        } else {
            arr.removeAll { $0 == id }
        }
        d.set(arr, forKey: hiddenKey)
    }

    // MARK: - 备份导出 / 恢复（供 BackupManager 全量备份使用）
    var snapshotOrder: [String] { d.stringArray(forKey: orderKey) ?? [] }
    var snapshotHidden: [String] { d.stringArray(forKey: hiddenKey) ?? [] }

    func restoreOrder(_ ids: [String]) { d.set(ids, forKey: orderKey) }
    func restoreHidden(_ ids: [String]) { d.set(ids, forKey: hiddenKey) }
}

// MARK: - 仪表盘持久化快照（统计结果显示缓存）

/// 7 个 widget 的显示数据快照：打开仪表盘时秒显上次统计，后台物化重算后刷新回写。
/// UserDefaults 按 bundle 隔离，Debug/Release 互不干扰。
struct DashboardSnapshot: Codable, Equatable {
    struct RowData: Codable, Equatable {        // 今日预约
        var time: String
        var customer: String
        var technician: String
        var status: String
    }
    struct NameAmountRow: Codable, Equatable {  // 今日订单
        var name: String
        var amount: Double
    }
    struct LowStockRow: Codable, Equatable {    // 低库存
        var name: String
        var quantity: String
    }
    struct TrendRow: Codable, Equatable {       // 收入趋势
        var label: String
        var amount: Double
    }
    struct RecordRow: Codable, Equatable {      // 最近服务记录
        var customer: String
        var technician: String
        var date: String
        var craft: String
        var isPaid: Bool
    }
    struct LashRow: Codable, Equatable {        // 补睫提醒
        var customer: String
        var due: String
        var status: String
        var days: Int
    }

    // 信号：快照生成时间 + 各表数量（今天生成且数量一致 → 直接秒显不重算）
    var generatedAt: Date = Date()
    var orderCount: Int = 0
    var rechargeCount: Int = 0
    var recordCount: Int = 0
    var reminderCount: Int = 0
    var customerCount: Int = 0
    var inventoryCount: Int = 0
    var appointmentCount: Int = 0

    // 今日预约（前 5）
    var todayAppointments: [RowData] = []
    // 今日收银
    var todayIncome: Double = 0
    var todayOrderCount: Int = 0
    var todayAverage: Double = 0
    var todayRecharge: Double = 0
    var todayOrders: [NameAmountRow] = []
    // 低库存
    var lowStockCount: Int = 0
    var lowStock: [LowStockRow] = []
    // 客户信息
    var totalCustomers: Int = 0
    var newThisMonth: Int = 0
    var memberCount: Int = 0
    var visitsThisMonth: Int = 0
    var visitingMembersThisMonth: Int = 0
    var dormantCustomers: Int = 0
    var repurchaseRate: String = "0%"
    var repurchaseCycle: String = "—"
    var lowBalanceMembers: Int = 0
    // 收入趋势（近 7 日）
    var incomeTrend: [TrendRow] = []
    // 最近服务记录
    var recentRecords: [RecordRow] = []
    // 补睫提醒
    var pendingLashCount: Int = 0
    var dueSoonCount: Int = 0
    var lashTop: [LashRow] = []
}

enum DashboardSnapshotStore {
    private static let key = "dashboard.statsCache.v1"

    static func load() -> DashboardSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DashboardSnapshot.self, from: data)
    }

    static func save(_ snapshot: DashboardSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - 仪表盘共享数据加载器（性能优化）

/// 打开仪表盘时一次性物化全库数据，所有 widget 共享，
/// 避免之前每个 widget 各自 @Query（orders 被 3 个 widget 各物化一遍 → 打开 ~2s）。
/// 视图秒开，数据分批物化填充（每批间让出主线程保持 UI 响应）。
@Observable
final class DashboardDataLoader {
    private(set) var appointments: [Appointment] = []
    var customers: [Customer] = []
    private(set) var technicians: [Technician] = []
    private(set) var orders: [Order] = []
    private(set) var recharges: [RechargeRecord] = []
    private(set) var inventory: [InventoryItem] = []
    var serviceItems: [ServiceItem] = []
    private(set) var records: [NailServiceRecord] = []
    private(set) var reminders: [LashReminder] = []
    private(set) var isLoading = false
    /// 最近一次统计快照（持久化秒显 + 信号校验用）
    private(set) var snapshot: DashboardSnapshot? = nil

    /// 分批物化全部表；快照今天生成且各表数量一致时秒回（来回切零物化），否则物化重算 + 刷新快照
    func load(context: ModelContext) async {
        #if DEBUG
        let loadT0 = CFAbsoluteTimeGetCurrent()
        #endif
        if isLoading {
            // 已有加载进行中（如 App 启动任务）：等待其完成，避免并发重复物化。
            // 物化本身分批 + 让出主线程，等待期间不阻塞 UI。
            while isLoading {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        // 持久化快照秒显：widget 立刻有上次统计数据（物化完成前先展示缓存）
        if snapshot == nil, let stored = DashboardSnapshotStore.load() {
            snapshot = stored
        }

        // 信号校验：快照今天生成 + 各表数量一致 → 数据未变，直接返回
        if let snap = snapshot, Calendar.current.isDateInToday(snap.generatedAt) {
            let oc = (try? context.fetchCount(FetchDescriptor<Order>())) ?? -1
            if oc == snap.orderCount {
                let rc = (try? context.fetchCount(FetchDescriptor<RechargeRecord>())) ?? -1
                let recC = (try? context.fetchCount(FetchDescriptor<NailServiceRecord>())) ?? -1
                let rmC = (try? context.fetchCount(FetchDescriptor<LashReminder>())) ?? -1
                let cuC = (try? context.fetchCount(FetchDescriptor<Customer>())) ?? -1
                let ivC = (try? context.fetchCount(FetchDescriptor<InventoryItem>())) ?? -1
                let apC = (try? context.fetchCount(FetchDescriptor<Appointment>())) ?? -1
                if rc == snap.rechargeCount && recC == snap.recordCount && rmC == snap.reminderCount
                    && cuC == snap.customerCount && ivC == snap.inventoryCount && apC == snap.appointmentCount {
                    // 数据未变：物化小表（客户/服务项目/技师/预约/库存）供列表/详情直接读；
                    // 大表（订单/充值/记录/提醒）统计已由有效快照覆盖（widget 读 snapshot），不重复物化
                    await Task.yield()
                    appointments = (try? context.fetch(FetchDescriptor<Appointment>())) ?? []
                    await Task.yield()
                    customers = (try? context.fetch(FetchDescriptor<Customer>())) ?? []
                    await Task.yield()
                    technicians = (try? context.fetch(FetchDescriptor<Technician>())) ?? []
                    await Task.yield()
                    inventory = (try? context.fetch(FetchDescriptor<InventoryItem>())) ?? []
                    await Task.yield()
                    serviceItems = (try? context.fetch(FetchDescriptor<ServiceItem>())) ?? []
                    #if DEBUG
                    print("[LOAD] signal-hit small tables done: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - loadT0) * 1000))ms")
                    #endif
                    return
                }
            }
        }

        isLoading = true
        await Task.yield()  // 先渲染首帧卡片

        // 小表一次物化
        appointments = (try? context.fetch(FetchDescriptor<Appointment>())) ?? []
        await Task.yield()
        customers = (try? context.fetch(FetchDescriptor<Customer>())) ?? []
        await Task.yield()
        technicians = (try? context.fetch(FetchDescriptor<Technician>())) ?? []
        await Task.yield()
        inventory = (try? context.fetch(FetchDescriptor<InventoryItem>())) ?? []
        await Task.yield()
        serviceItems = (try? context.fetch(FetchDescriptor<ServiceItem>())) ?? []
        await Task.yield()

        // 大表分批物化
        orders = await fetchBatched(context: context)
        recharges = await fetchBatched(context: context)
        records = await fetchBatched(context: context)
        reminders = await fetchBatched(context: context)

        // 构建统计快照并持久化（widget 数据源自动刷新）
        let newSnap = buildSnapshot()
        snapshot = newSnap
        DashboardSnapshotStore.save(newSnap)

        isLoading = false
        #if DEBUG
        print("[LOAD] full load done: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - loadT0) * 1000))ms")
        #endif
    }

    /// 客户信息模块本地新增客户后同步到内存数组（数据库由 context 管理，避免等下次全量物化）
    func insertCustomer(_ customer: Customer) {
        if !customers.contains(where: { $0.id == customer.id }) {
            customers.append(customer)
        }
    }

    /// 客户信息模块删除客户后同步从内存数组移除
    func removeCustomer(_ customer: Customer) {
        customers.removeAll { $0.id == customer.id }
    }

    /// 从已物化的原始数据计算全部 widget 的显示统计（widget 不再各自遍历订单）
    private func buildSnapshot() -> DashboardSnapshot {
        let cal = Calendar.current
        var snap = DashboardSnapshot()
        snap.generatedAt = Date()

        let cMap = Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) })
        let tMap = Dictionary(uniqueKeysWithValues: technicians.map { ($0.id, $0) })
        let timeF = DateFormatter()
        timeF.dateFormat = "HH:mm"
        let cnDateF = DateFormatter()
        cnDateF.locale = Locale(identifier: "zh_CN")
        cnDateF.dateFormat = "yyyy年M月d日"

        // 今日预约（前 5，按时间升序）
        let todayApps = appointments.filter { cal.isDateInToday($0.startTime) }.sorted { $0.startTime < $1.startTime }
        snap.todayAppointments = Array(todayApps.prefix(5)).map {
            DashboardSnapshot.RowData(time: timeF.string(from: $0.startTime),
                                      customer: cMap[$0.customerId]?.name ?? "客户",
                                      technician: tMap[$0.technicianId]?.name ?? "技师",
                                      status: $0.status)
        }

        // 今日收银 = 订单补足部分（非钱包扣除）+ 今日充值
        let todayOrders = orders.filter { cal.isDateInToday($0.paidAt) }
        let todayRecharges = recharges.filter { cal.isDateInToday($0.rechargeAt) }
        let orderIncome = todayOrders.reduce(0) { $0 + max(0, $1.totalAmount - $1.walletDeducted) }
        let rechargeIncome = todayRecharges.reduce(0) { $0 + $1.amount }
        snap.todayIncome = orderIncome + rechargeIncome
        snap.todayOrderCount = todayOrders.count
        snap.todayAverage = todayOrders.isEmpty ? 0 : (orderIncome + rechargeIncome) / Double(todayOrders.count)
        snap.todayRecharge = rechargeIncome
        snap.todayOrders = todayOrders.sorted { $0.paidAt > $1.paidAt }.prefix(3).map {
            DashboardSnapshot.NameAmountRow(name: cMap[$0.customerId]?.name ?? "客户", amount: $0.totalAmount)
        }

        // 低库存
        let lowItems = inventory.filter(\.isLowStock).sorted { $0.quantity < $1.quantity }
        snap.lowStockCount = lowItems.count
        snap.lowStock = lowItems.prefix(6).map {
            DashboardSnapshot.LowStockRow(name: $0.name, quantity: "剩 \($0.quantity.clean)\($0.unit)")
        }

        // 客户信息（9 项统计）
        let active = customers.filter(\.isActive)
        let serviceItemMap = Dictionary(uniqueKeysWithValues: serviceItems.map { ($0.id, $0) })
        // 有效订单 = 非纯补睫订单（空行项视为有效）
        let validOrders = orders.filter { order in
            guard !order.lineItems.isEmpty else { return true }
            return !order.lineItems.allSatisfy { item in serviceItemMap[item.serviceItemId]?.isLashTouchUp ?? false }
        }
        snap.totalCustomers = active.count
        snap.newThisMonth = active.filter { cal.isDate($0.createdAt, equalTo: Date(), toGranularity: .month) }.count
        snap.memberCount = active.filter { $0.membershipLevel != "普通" }.count
        let ordersThisMonth = validOrders.filter { cal.isDate($0.paidAt, equalTo: Date(), toGranularity: .month) }
        snap.visitsThisMonth = ordersThisMonth.count
        let memberIds = Set(active.filter { $0.membershipLevel != "普通" }.map { $0.id })
        snap.visitingMembersThisMonth = memberIds.intersection(Set(ordersThisMonth.map { $0.customerId })).count
        let threeMonthsAgo = cal.date(byAdding: .month, value: -3, to: Date()) ?? Date()
        let lastVisitByCustomer = Dictionary(validOrders.map { ($0.customerId, $0.paidAt) }, uniquingKeysWith: max)
        snap.dormantCustomers = active.filter { c in
            guard let last = lastVisitByCustomer[c.id] else { return true } // 从未消费算沉睡
            return last < threeMonthsAgo
        }.count
        let orderCountByCustomer = Dictionary(grouping: validOrders, by: { $0.customerId })
            .mapValues { $0.count }
        let repurchaseOrders = ordersThisMonth.filter { (orderCountByCustomer[$0.customerId] ?? 0) >= 2 }.count
        snap.repurchaseRate = ordersThisMonth.isEmpty
            ? "0%"
            : "\(Int(Double(repurchaseOrders) / Double(ordersThisMonth.count) * 100))%"
        let sixMonthsAgo = cal.date(byAdding: .month, value: -6, to: Date()) ?? Date()
        let recentOrders = validOrders.filter { $0.paidAt >= sixMonthsAgo }
        let grouped = Dictionary(grouping: recentOrders, by: { $0.customerId })
        var allIntervals: [Double] = []
        for (_, customerOrders) in grouped {
            guard customerOrders.count >= 2 else { continue }
            let sorted = customerOrders.sorted { $0.paidAt < $1.paidAt }
            for i in 1..<sorted.count {
                allIntervals.append(sorted[i].paidAt.timeIntervalSince(sorted[i-1].paidAt) / 86400)
            }
        }
        snap.repurchaseCycle = allIntervals.isEmpty
            ? "—"
            : "\(Int((allIntervals.reduce(0, +) / Double(allIntervals.count)).rounded()))天"
        let recharged = Dictionary(grouping: recharges, by: { $0.customerId })
            .mapValues { $0.reduce(0) { $0 + $1.amount + $1.bonus } }
        let walletUsed = Dictionary(grouping: orders, by: { $0.customerId })
            .mapValues { $0.reduce(0) { $0 + $1.walletDeducted } }
        snap.lowBalanceMembers = active.filter { c in
            guard c.membershipLevel != "普通" else { return false }
            let balance = (recharged[c.id] ?? 0) - (walletUsed[c.id] ?? 0)
            return balance < 50
        }.count

        // 收入趋势（近 7 日）
        let today = cal.startOfDay(for: Date())
        let trendF = DateFormatter()
        trendF.locale = Locale(identifier: "zh_CN")
        trendF.dateFormat = "M/d"
        for offset in stride(from: 6, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            let dayOrderIncome = orders
                .filter { cal.isDate($0.paidAt, inSameDayAs: day) }
                .reduce(0) { $0 + max(0, $1.totalAmount - $1.walletDeducted) }
            let dayRechargeIncome = recharges
                .filter { cal.isDate($0.rechargeAt, inSameDayAs: day) }
                .reduce(0) { $0 + $1.amount }
            snap.incomeTrend.append(DashboardSnapshot.TrendRow(label: trendF.string(from: day),
                                                              amount: dayOrderIncome + dayRechargeIncome))
        }

        // 最近服务记录（前 5）
        snap.recentRecords = records.sorted { $0.serviceDate > $1.serviceDate }.prefix(5).map {
            DashboardSnapshot.RecordRow(customer: cMap[$0.customerId]?.name ?? "客户",
                                        technician: tMap[$0.technicianId]?.name ?? "技师",
                                        date: cnDateF.string(from: $0.serviceDate),
                                        craft: $0.craft ?? "",
                                        isPaid: $0.isPaid)
        }

        // 补睫提醒（未完成且今天到期或之后；已过期条目在补睫提醒模块查看）
        let pending = reminders.filter { !$0.isCompleted && $0.daysUntilDue >= 0 }
        snap.pendingLashCount = pending.count
        snap.dueSoonCount = pending.filter { $0.isDueSoon }.count
        snap.lashTop = pending.sorted { $0.daysUntilDue < $1.daysUntilDue }.prefix(5).map {
            let days = $0.daysUntilDue
            let status = days <= 3 ? (days == 0 ? "今天到期" : "剩 \(days) 天") : "还有 \(days) 天"
            return DashboardSnapshot.LashRow(customer: cMap[$0.customerId]?.name ?? "客户",
                                             due: cnDateF.string(from: $0.dueDate),
                                             status: status,
                                             days: days)
        }

        // 信号（供下次进入时校验）
        snap.orderCount = orders.count
        snap.rechargeCount = recharges.count
        snap.recordCount = records.count
        snap.reminderCount = reminders.count
        snap.customerCount = customers.count
        snap.inventoryCount = inventory.count
        snap.appointmentCount = appointments.count
        return snap
    }

    /// 分批物化（每批 400 条，批间让出主线程保持 UI 响应）
    private func fetchBatched<T: PersistentModel>(context: ModelContext) async -> [T] {
        var result: [T] = []
        let total = (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
        let pageSize = 400
        var offset = 0
        while offset < total {
            var desc = FetchDescriptor<T>()
            desc.fetchLimit = pageSize
            desc.fetchOffset = offset
            let page = (try? context.fetch(desc)) ?? []
            result.append(contentsOf: page)
            offset += pageSize
            await Task.yield()
        }
        return result
    }
}

// MARK: - 主视图

struct DashboardView: View {
    var onOpen: (SidebarItem) -> Void
    @Environment(SessionManager.self) private var session
    @Environment(\.modelContext) private var context
    @Environment(DashboardDataLoader.self) private var loader
    @State private var showingEdit = false
    @State private var contentID = UUID()

    init(onOpen: @escaping (SidebarItem) -> Void) { self.onOpen = onOpen }

    /// 当前用户有权限的小组件（不考虑显隐偏好）
    private var allowedWidgetDescriptors: [DashboardWidgetDescriptor] {
        DashboardRegistry.all.filter { descriptor in
            if let module = descriptor.module {
                return session.hasPermission(moduleId: module.moduleId)
            }
            return true
        }
    }

    /// 按权限过滤 + 用户显隐偏好过滤
    private var visible: [DashboardWidgetDescriptor] {
        let all = DashboardPreferences.shared.ordered(DashboardRegistry.all)
        return all.filter { descriptor in
            // 权限过滤：如果小组件关联了模块，需要有权限才显示
            if let module = descriptor.module {
                guard session.hasPermission(moduleId: module.moduleId) else { return false }
            }
            // 显隐偏好过滤
            return !DashboardPreferences.shared.hidden().contains(descriptor.id)
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 20),
                GridItem(.flexible(), spacing: 20)
            ], spacing: 20) {
                ForEach(visible) { descriptor in
                    DashboardCard(descriptor: descriptor)
                        .gridCellColumns(descriptor.spans)
                        .environment(\.openDashboardModule, onOpen)
                }
            }
            .id(contentID)
            .padding(20)
        }
        .navigationTitle("仪表盘")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showingEdit = true
                } label: {
                    Label("编辑布局", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            DashboardEditSheet(allowedWidgets: allowedWidgetDescriptors) { contentID = UUID() }
        }
        .environment(loader)
        .task { await loader.load(context: context) }
    }
}

// MARK: - 卡片容器

/// 所有卡片统一高度，保证网格内 6 个卡片等高对齐。
/// 高度已足够容纳各卡片当前的完整内容（5 行列表/图表等），
/// 现有数据下卡片内部不再需要滚动；ScrollView 仅作极端数据溢出时的兜底。
private let dashboardCardHeight: CGFloat = 290

struct DashboardCard: View {
    let descriptor: DashboardWidgetDescriptor
    @Environment(\.openDashboardModule) private var openModule
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            ScrollView {
                descriptor.makeView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: dashboardCardHeight,
               maxHeight: dashboardCardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Corner.large, style: .continuous)
                .fill(isHovering ? Color.brand.opacity(0.07) : Color.brandSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Corner.large, style: .continuous)
                .stroke(Color.brand.opacity(isHovering ? 0.5 : 0.16),
                        lineWidth: isHovering ? 1.2 : 0.6)
        )
        .shadow(color: isHovering ? Color.brand.opacity(0.25) : Color.clear,
                radius: isHovering ? 14 : 0, y: isHovering ? 2 : 0)
        .scaleEffect(isHovering ? 1.012 : 1)
        .onHover { hovering in
            // 滑入 0.02s 瞬间亮起；滑出 0.6s 缓慢熄灭，形成平滑扫过的层次
            withAnimation(.easeOut(duration: hovering ? 0.02 : 0.6)) {
                isHovering = hovering
            }
        }
        // 整卡可点击：点击任意位置 → 跳转到对应功能模块
        .onTapGesture {
            if let m = descriptor.module { openModule(m) }
        }
        .pointerOnHover()
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconChip(systemName: descriptor.icon, tint: descriptor.tint, size: 30, corner: 9)
            Text(descriptor.title)
                .font(.headline)
            Spacer()
            // 悬停时出现"前往"箭头，提示可点击
            if isHovering {
                HStack(spacing: 3) {
                    Text("前往").font(.caption)
                    Image(systemName: "arrow.up.right").font(.caption)
                }
                .foregroundStyle(Color.brand)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
    }
}

// 悬停时鼠标改为"手形"指针
struct PointerHoverModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { inside in
            DispatchQueue.main.async {
                if inside { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
    }
}

extension View {
    func pointerOnHover() -> some View { modifier(PointerHoverModifier()) }
}


// MARK: - 编辑布局 Sheet（开关组件 + 排序）

struct DashboardEditSheet: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var orderIDs: [String] = []
    @State private var hidden: Set<String> = []

    /// 只包含当前用户有权限的小组件
    let allowedWidgets: [DashboardWidgetDescriptor]

    init(allowedWidgets: [DashboardWidgetDescriptor], onSaved: @escaping () -> Void) {
        self.onSaved = onSaved
        self.allowedWidgets = allowedWidgets
        _orderIDs = State(initialValue: DashboardPreferences.shared.ordered(allowedWidgets).map(\.id))
        _hidden = State(initialValue: DashboardPreferences.shared.hidden())
    }

    private var ordered: [DashboardWidgetDescriptor] {
        orderIDs.compactMap { id in
            allowedWidgets.first(where: { $0.id == id })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑布局").font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()

            List {
                ForEach(ordered) { w in
                    HStack(spacing: 10) {
                        Image(systemName: w.icon).foregroundStyle(w.tint).frame(width: 18)
                        Text(w.title)
                        Spacer()
                        Button {
                            move(w, -1)
                        } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderless)
                            .disabled(orderIDs.first == w.id)
                        Button {
                            move(w, 1)
                        } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(.borderless)
                            .disabled(orderIDs.last == w.id)
                        Toggle("", isOn: Binding(
                            get: { !hidden.contains(w.id) },
                            set: { show in if show { hidden.remove(w.id) } else { hidden.insert(w.id) } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }

            Divider()
            HStack {
                Button("恢复默认") { reset() }
                Spacer()
                Button("完成") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 360, height: 460)
    }

    private func move(_ w: DashboardWidgetDescriptor, _ delta: Int) {
        guard let i = orderIDs.firstIndex(of: w.id) else { return }
        let j = i + delta
        guard j >= 0 && j < orderIDs.count else { return }
        orderIDs.swapAt(i, j)
    }

    private func reset() {
        orderIDs = allowedWidgets.map(\.id)
        hidden = []
    }

    private func save() {
        DashboardPreferences.shared.saveOrder(orderIDs)
        for w in allowedWidgets {
            DashboardPreferences.shared.setHidden(w.id, hidden.contains(w.id))
        }
        onSaved()
    }
}

// MARK: - 通用小组件

/// 数值统计块（用于"今日收银""客户信息"等卡片内的数值展示）
private struct MiniStat: View {
    let value: String
    let label: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Widget: 今日预约

struct TodayAppointmentsWidget: View {
    @Environment(DashboardDataLoader.self) private var loader
    @Environment(\.modelContext) private var context
    @State private var cachedDay = Calendar.current.startOfDay(for: Date())

    private var rows: [DashboardSnapshot.RowData] { loader.snapshot?.todayAppointments ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                EmptyMiniView(systemImage: "calendar.badge.checkmark", text: "今天暂无预约")
            } else {
                ForEach(rows.indices, id: \.self) { i in
                    let a = rows[i]
                    HStack(spacing: 8) {
                        Text(a.time)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.customer)
                                .font(.callout).lineLimit(1)
                            Text(a.technician + " · " + a.status)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        statusDot(a.status)
                    }
                    if i != rows.count - 1 { Divider() }
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if !Calendar.current.isDateInToday(cachedDay) {
                cachedDay = Calendar.current.startOfDay(for: Date())
                Task { await loader.load(context: context) }  // 跨天触发重算
            }
        }
    }

    @ViewBuilder
    private func statusDot(_ status: String) -> some View {
        let color: Color = {
            switch status {
            case "已完成": return .green
            case "已到店": return .blue
            case "已取消": return .gray
            default: return .orange
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Widget: 今日收银

struct CheckoutTodayWidget: View {
    @Environment(DashboardDataLoader.self) private var loader
    @Environment(\.modelContext) private var context
    @State private var cachedDay = Calendar.current.startOfDay(for: Date())

    private var snap: DashboardSnapshot? { loader.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日实收")
                .font(.caption).foregroundStyle(.secondary)
            Text("¥" + String(format: "%.2f", snap?.todayIncome ?? 0))
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Color.brand)
            HStack(spacing: 12) {
                MiniStat(value: "\(snap?.todayOrderCount ?? 0)", label: "订单数", tint: .primary)
                MiniStat(value: "¥" + String(format: "%.0f", snap?.todayAverage ?? 0), label: "客单价", tint: .primary)
                if (snap?.todayRecharge ?? 0) > 0 {
                    MiniStat(value: "¥" + String(format: "%.0f", snap?.todayRecharge ?? 0),
                             label: "充值", tint: .primary)
                }
            }
            if let rows = snap?.todayOrders, !rows.isEmpty {
                Divider()
                ForEach(rows.indices, id: \.self) { i in
                    HStack {
                        Text(rows[i].name).lineLimit(1)
                        Spacer()
                        Text("¥" + String(format: "%.0f", rows[i].amount))
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if !Calendar.current.isDateInToday(cachedDay) {
                cachedDay = Calendar.current.startOfDay(for: Date())
                Task { await loader.load(context: context) }  // 跨天触发重算
            }
        }
    }
}

// MARK: - Widget: 低库存预警

struct LowStockWidget: View {
    @Environment(DashboardDataLoader.self) private var loader
    @Environment(\.modelContext) private var context
    @State private var cachedDay = Calendar.current.startOfDay(for: Date())

    private var snap: DashboardSnapshot? { loader.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if (snap?.lowStock ?? []).isEmpty {
                EmptyMiniView(systemImage: "checkmark.circle", text: "库存充足，暂无预警")
                    .foregroundStyle(.secondary)
            } else {
                Text("共 \(snap?.lowStockCount ?? 0) 项库存不足")
                    .font(.caption).foregroundStyle(.red)
                ForEach(snap!.lowStock.indices, id: \.self) { i in
                    let item = snap!.lowStock[i]
                    HStack(spacing: 6) {
                        Text(item.name).lineLimit(1)
                        Spacer()
                        Text(item.quantity)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fontWeight(.semibold)
                    }
                    .font(.callout)
                    if i != snap!.lowStock.count - 1 { Divider() }
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if !Calendar.current.isDateInToday(cachedDay) {
                cachedDay = Calendar.current.startOfDay(for: Date())
                Task { await loader.load(context: context) }  // 跨天触发重算
            }
        }
    }
}



// MARK: - Widget: 客户信息

struct CustomersWidget: View {
    @Environment(DashboardDataLoader.self) private var loader
    @Environment(\.modelContext) private var context
    @State private var cachedDay = Calendar.current.startOfDay(for: Date())

    private var snap: DashboardSnapshot? { loader.snapshot }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                MiniStat(value: "\(snap?.totalCustomers ?? 0)", label: "客户总数", tint: .primary)
                MiniStat(value: "\(snap?.newThisMonth ?? 0)", label: "本月新增", tint: .primary)
                MiniStat(value: "\(snap?.memberCount ?? 0)", label: "会员数量", tint: .primary)
            }
            HStack(spacing: 12) {
                MiniStat(value: "\(snap?.visitsThisMonth ?? 0)", label: "本月到店客户", tint: .primary)
                MiniStat(value: "\(snap?.visitingMembersThisMonth ?? 0)", label: "本月到店会员", tint: .primary)
                MiniStat(value: "\(snap?.dormantCustomers ?? 0)", label: "沉睡客户", tint: .primary)
            }
            HStack(spacing: 12) {
                MiniStat(value: snap?.repurchaseRate ?? "0%", label: "复购率", tint: .primary)
                MiniStat(value: snap?.repurchaseCycle ?? "—", label: "复购周期", tint: .primary)
                MiniStat(value: "\(snap?.lowBalanceMembers ?? 0)", label: "低余额会员", tint: .primary)
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if !Calendar.current.isDateInToday(cachedDay) {
                cachedDay = Calendar.current.startOfDay(for: Date())
                Task { await loader.load(context: context) }  // 跨天触发重算
            }
        }
    }
}

// MARK: - Widget: 收入统计（近 7 日趋势）

struct IncomeTrendWidget: View {
    @Environment(DashboardDataLoader.self) private var loader
    @Environment(\.modelContext) private var context
    @State private var cachedDay = Calendar.current.startOfDay(for: Date())

    private var trend: [DashboardSnapshot.TrendRow] { loader.snapshot?.incomeTrend ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(trend, id: \.label) { row in
                BarMark(x: .value("日", row.label), y: .value("金额", row.amount))
                    .foregroundStyle(Color.brandGradient)
                    .cornerRadius(3)
            }
            .chartYAxisLabel("元")
            .frame(height: 130)
            HStack {
                Text("近 7 日合计 ¥" + String(format: "%.2f", trend.reduce(0) { $0 + $1.amount }))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("按日")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if !Calendar.current.isDateInToday(cachedDay) {
                cachedDay = Calendar.current.startOfDay(for: Date())
                Task { await loader.load(context: context) }  // 跨天触发重算
            }
        }
    }
}

// MARK: - Widget: 服务记录（最近）

struct RecentRecordsWidget: View {
    @Environment(DashboardDataLoader.self) private var loader
    @Environment(\.modelContext) private var context
    @State private var cachedDay = Calendar.current.startOfDay(for: Date())

    private var rows: [DashboardSnapshot.RecordRow] { loader.snapshot?.recentRecords ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                EmptyMiniView(systemImage: "photo.on.rectangle", text: "还没有服务记录，去服务记录模块录入吧")
            } else {
                ForEach(rows.indices, id: \.self) { i in
                    let r = rows[i]
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.customer)
                                .font(.callout).lineLimit(1)
                            Text(r.technician + " · " + r.date)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !r.craft.isEmpty {
                            Text(r.craft).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        BadgePaid(isPaid: r.isPaid)
                    }
                    if i != rows.count - 1 { Divider() }
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if !Calendar.current.isDateInToday(cachedDay) {
                cachedDay = Calendar.current.startOfDay(for: Date())
                Task { await loader.load(context: context) }  // 跨天触发重算
            }
        }
    }
}

// MARK: - Widget: 补睫提醒

struct LashReminderWidget: View {
    @Environment(DashboardDataLoader.self) private var loader
    @Environment(\.modelContext) private var context
    @State private var cachedDay = Calendar.current.startOfDay(for: Date())

    private var snap: DashboardSnapshot? { loader.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                compactStat(value: "\(snap?.pendingLashCount ?? 0)", label: "待补睫", tint: .primary)
                compactStat(value: "\(snap?.dueSoonCount ?? 0)", label: "即将到期", tint: .primary)
            }
            let rows = snap?.lashTop ?? []
            if rows.isEmpty {
                EmptyMiniView(systemImage: "checkmark.circle", text: "暂无待补睫")
                    .foregroundStyle(.secondary)
            } else {
                Divider().padding(.vertical, 2)
                ForEach(rows.indices, id: \.self) { i in
                    let r = rows[i]
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.customer)
                                .font(.caption).lineLimit(1)
                            Text("应补 \(r.due)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(r.status)
                            .font(.caption2)
                            .foregroundStyle(r.days < 0 ? .red : r.days <= 3 ? .orange : .secondary)
                            .fontWeight(.semibold)
                    }
                    if i != rows.count - 1 { Divider() }
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if !Calendar.current.isDateInToday(cachedDay) {
                cachedDay = Calendar.current.startOfDay(for: Date())
                Task { await loader.load(context: context) }  // 跨天触发重算
            }
        }
    }

    private func compactStat(value: String, label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.callout.bold()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 小工具

/// 卡片内空状态
struct EmptyMiniView: View {
    let systemImage: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 16))
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 60)
    }
}

/// 已付款 / 未付款 徽章
struct BadgePaid: View {
    let isPaid: Bool
    var body: some View {
        Text(isPaid ? "已收款" : "未收款")
            .font(.caption2)
            .foregroundStyle(isPaid ? .green : .orange)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill((isPaid ? Color.green : Color.orange).opacity(0.12)))
    }
}

private extension Double {
    /// 整数显示为整数，否则保留一位小数（用于库存数量等）
    var clean: String {
        self == self.rounded() ? String(format: "%.0f", self) : String(format: "%.1f", self)
    }
}
