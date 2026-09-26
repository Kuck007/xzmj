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
    /// 全部已注册的组件（顺序即默认顺序）。static let 只创建一次，避免每次 body 重建数组。
    static let all: [DashboardWidgetDescriptor] = [
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

// MARK: - 主视图

struct DashboardView: View {
    var onOpen: (SidebarItem) -> Void
    @Environment(AppCore.self) private var appCore
    @Environment(SessionManager.self) private var session
    @State private var showingEdit = false
    @State private var contentID = UUID()
    /// 缓存可见组件列表，避免每次 body 都读 UserDefaults + 遍历
    @State private var cachedVisible: [DashboardWidgetDescriptor]?

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

    /// 按权限过滤 + 用户显隐偏好过滤（带缓存，编辑布局后由 contentID 变更触发重建）
    private var visible: [DashboardWidgetDescriptor] {
        cachedVisible ?? computeVisible()
    }

    private func computeVisible() -> [DashboardWidgetDescriptor] {
        let all = DashboardPreferences.shared.ordered(DashboardRegistry.all)
        return all.filter { descriptor in
            if let module = descriptor.module {
                guard session.hasPermission(moduleId: module.moduleId) else { return false }
            }
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
        .task { cachedVisible = computeVisible() }
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
            DashboardEditSheet(allowedWidgets: allowedWidgetDescriptors) {
                cachedVisible = nil
                contentID = UUID()
            }
        }
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
            descriptor.makeView()
                .frame(maxWidth: .infinity, alignment: .leading)
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
    @Environment(AppCore.self) private var appCore

    var body: some View {
        let todayList = appCore.dashboardTodayAppointments
        VStack(alignment: .leading, spacing: 6) {
            if todayList.isEmpty {
                EmptyMiniView(systemImage: "calendar.badge.checkmark", text: "今天暂无预约")
            } else {
                ForEach(todayList.prefix(5)) { a in
                    HStack(spacing: 8) {
                        Text(a.startTime, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(appCore.customerNameMap[a.customerId] ?? "客户")
                                .font(.callout).lineLimit(1)
                            Text((appCore.technicianNameMap[a.technicianId] ?? "技师") + " · " + a.status)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        statusDot(a.status)
                    }
                    if a.id != todayList.prefix(5).last?.id { Divider() }
                }
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
    @Environment(AppCore.self) private var appCore

    var body: some View {
        let r = appCore.dashboardTodayCheckout
        VStack(alignment: .leading, spacing: 10) {
            Text("今日实收")
                .font(.caption).foregroundStyle(.secondary)
            Text("¥" + String(format: "%.2f", r.total))
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Color.brand)
            HStack(spacing: 12) {
                MiniStat(value: "\(r.orderCount)", label: "订单数", tint: .primary)
                MiniStat(value: "¥" + String(format: "%.0f", r.average), label: "客单价", tint: .primary)
                if r.rechargeTotal > 0 {
                    MiniStat(value: "¥" + String(format: "%.0f", r.rechargeTotal),
                             label: "充值", tint: .primary)
                }
            }
            if !r.recentOrders.isEmpty {
                Divider()
                ForEach(r.recentOrders) { o in
                    HStack {
                        Text(appCore.customerNameMap[o.customerId] ?? "客户").lineLimit(1)
                        Spacer()
                        Text("¥" + String(format: "%.0f", o.totalAmount))
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

// MARK: - Widget: 低库存预警

struct LowStockWidget: View {
    @Environment(AppCore.self) private var appCore

    var body: some View {
        let lowItems = appCore.dashboardLowStock
        VStack(alignment: .leading, spacing: 6) {
            if lowItems.isEmpty {
                EmptyMiniView(systemImage: "checkmark.circle", text: "库存充足，暂无预警")
                    .foregroundStyle(.secondary)
            } else {
                Text("共 \(lowItems.count) 项库存不足")
                    .font(.caption).foregroundStyle(.red)
                ForEach(lowItems.prefix(6)) { item in
                    HStack(spacing: 6) {
                        Text(item.name).lineLimit(1)
                        Spacer()
                        Text("剩 \(item.quantity.clean)\(item.unit)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fontWeight(.semibold)
                    }
                    .font(.callout)
                    if item.id != lowItems.prefix(6).last?.id { Divider() }
                }
            }
        }
    }
}



// MARK: - Widget: 客户信息

struct CustomersWidget: View {
    @Environment(AppCore.self) private var appCore

    var body: some View {
        let s = appCore.dashboardCustomerStats
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                MiniStat(value: "\(s.totalCustomers)", label: "客户总数", tint: .primary)
                MiniStat(value: "\(s.newThisMonth)", label: "本月新增", tint: .primary)
                MiniStat(value: "\(s.memberCount)", label: "会员数量", tint: .primary)
            }
            HStack(spacing: 12) {
                MiniStat(value: "\(s.visitsThisMonth)", label: "本月到店客户", tint: .primary)
                MiniStat(value: "\(s.visitingMembersThisMonth)", label: "本月到店会员", tint: .primary)
                MiniStat(value: "\(s.dormantCustomers)", label: "沉睡客户", tint: .primary)
            }
            HStack(spacing: 12) {
                MiniStat(value: s.repurchaseRate, label: "复购率", tint: .primary)
                MiniStat(value: s.repurchaseCycle, label: "复购周期", tint: .primary)
                MiniStat(value: "\(s.lowBalanceMembers)", label: "低余额会员", tint: .primary)
            }
        }
    }
}

// MARK: - Widget: 收入统计（近 7 日趋势）

struct IncomeTrendWidget: View {
    @Environment(AppCore.self) private var appCore

    var body: some View {
        let trend = appCore.dashboardIncomeTrend
        VStack(alignment: .leading, spacing: 8) {
            Chart(trend) { row in
                BarMark(x: .value("日", row.label), y: .value("金额", row.amount))
                    .foregroundStyle(Color.brandGradient)
                    .cornerRadius(3)
            }
            .chartYAxisLabel("元")
            .frame(height: 130)
            HStack {
                Text("近 7 日合计 ¥" + String(format: "%.2f", appCore.dashboardIncome7DayTotal))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("按日")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Widget: 服务记录（最近）

struct RecentRecordsWidget: View {
    @Environment(AppCore.self) private var appCore

    private let cnDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    var body: some View {
        let recent = appCore.dashboardRecentRecords
        VStack(alignment: .leading, spacing: 6) {
            if recent.isEmpty {
                EmptyMiniView(systemImage: "photo.on.rectangle", text: "还没有服务记录，去服务记录模块录入吧")
            } else {
                ForEach(recent) { r in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(appCore.customerNameMap[r.customerId] ?? "客户")
                                .font(.callout).lineLimit(1)
                            Text((appCore.technicianNameMap[r.technicianId] ?? "技师") + " · " + cnDateFormatter.string(from: r.serviceDate))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let craft = r.craft, !craft.isEmpty {
                            Text(craft).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        BadgePaid(isPaid: r.isPaid)
                    }
                    if r.id != recent.last?.id { Divider() }
                }
            }
        }
    }
}

// MARK: - Widget: 补睫提醒

struct LashReminderWidget: View {
    @Environment(AppCore.self) private var appCore

    private let cnDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    var body: some View {
        let pending = appCore.dashboardPendingReminders
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                compactStat(value: "\(pending.count)", label: "待补睫", tint: .primary)
                compactStat(value: "\(appCore.dashboardDueSoonCount)", label: "即将到期", tint: .primary)
            }
            if pending.isEmpty {
                EmptyMiniView(systemImage: "checkmark.circle", text: "暂无待补睫")
                    .foregroundStyle(.secondary)
            } else {
                Divider().padding(.vertical, 2)
                let top = Array(pending.prefix(5))
                ForEach(top) { r in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(appCore.customerNameMap[r.customerId] ?? "客户")
                                .font(.caption).lineLimit(1)
                            Text("应补 \(cnDateFormatter.string(from: r.dueDate))")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(reminderStatusText(r))
                            .font(.caption2)
                            .foregroundStyle(r.daysUntilDue < 0 ? .red : r.isDueSoon ? .orange : .secondary)
                            .fontWeight(.semibold)
                    }
                    if r.id != top.prefix(4).last?.id { Divider() }
                }
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

    private func reminderStatusText(_ r: LashReminder) -> String {
        let days = r.daysUntilDue
        if days < 0 { return "已过期 \(abs(days)) 天" }
        if days <= 3 { return days == 0 ? "今天到期" : "剩 \(days) 天" }
        return "还有 \(days) 天"
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
