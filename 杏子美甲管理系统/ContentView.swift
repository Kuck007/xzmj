//
//  ContentView.swift
//  杏子美甲管理系统
//
//  Created by 李高翔 on 2026/8/1.
//

import SwiftUI
import SwiftData

// MARK: - 侧边栏偏好设置（持久化到 UserDefaults，为未来账号系统预留）
enum SidebarPreferences {
    private static let orderKey = "sidebar_order"
    private static let hiddenKey = "sidebar_hidden"

    /// 固定项：仪表盘始终第一个且不可隐藏
    static let fixedItem: SidebarItem = .dashboard
    /// 可排序项（除仪表盘外）
    static var sortableItems: [SidebarItem] {
        SidebarItem.allCases.filter { $0 != fixedItem }
    }

    /// 获取可见项列表（仪表盘 + 用户排序的可见项）
    static func visibleItems() -> [SidebarItem] {
        let order = UserDefaults.standard.stringArray(forKey: orderKey) ?? sortableItems.map { $0.rawValue }
        let hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        var result: [SidebarItem] = [fixedItem]
        for id in order {
            if id != fixedItem.rawValue,
               let item = sortableItems.first(where: { $0.rawValue == id }),
               !hidden.contains(id) {
                result.append(item)
            }
        }
        // 新增项兜底（版本升级添加新模块时自动出现在末尾）
        for item in sortableItems {
            if !order.contains(item.rawValue) && !hidden.contains(item.rawValue) {
                result.append(item)
            }
        }
        return result
    }

    static func isHidden(_ item: SidebarItem) -> Bool {
        guard item != fixedItem else { return false }
        let hidden = UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []
        return hidden.contains(item.rawValue)
    }

    static func setHidden(_ hidden: Bool, for item: SidebarItem) {
        guard item != fixedItem else { return }
        var current = UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []
        if hidden {
            if !current.contains(item.rawValue) { current.append(item.rawValue) }
        } else {
            current.removeAll { $0 == item.rawValue }
        }
        UserDefaults.standard.set(current, forKey: hiddenKey)
    }

    /// 保存排序（仅可排序项，不含固定项）
    static func saveOrder(_ items: [SidebarItem]) {
        let order = items.filter { $0 != fixedItem }.map { $0.rawValue }
        UserDefaults.standard.set(order, forKey: orderKey)
    }

    /// 调整单个项目的顺序（向上/向下）
    static func move(_ item: SidebarItem, _ delta: Int) {
        var order = UserDefaults.standard.stringArray(forKey: orderKey) ?? sortableItems.map { $0.rawValue }
        guard let i = order.firstIndex(of: item.rawValue) else { return }
        let j = i + delta
        guard j >= 0 && j < order.count else { return }
        order.swapAt(i, j)
        UserDefaults.standard.set(order, forKey: orderKey)
    }

    /// 恢复默认顺序
    static func resetOrder() {
        UserDefaults.standard.removeObject(forKey: orderKey)
        UserDefaults.standard.removeObject(forKey: hiddenKey)
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "仪表盘"
    case appointments = "预约排班"
    case records = "服务记录"
    case orders = "收银结账"
    case customers = "客户信息"
    case technicians = "技师管理"
    case services = "服务项目"
    case inventory = "库存管理"
    case lashReminder = "补睫提醒"
    case income = "收入统计"
    case salary = "技师工资"
    case userManagement = "用户管理"

    var id: String { rawValue }

    /// 权限检查用的稳定模块ID（英文，不随中文翻译变更）
    var moduleId: String {
        switch self {
        case .dashboard: return "dashboard"
        case .appointments: return "appointments"
        case .records: return "records"
        case .orders: return "orders"
        case .customers: return "customers"
        case .technicians: return "technicians"
        case .services: return "services"
        case .inventory: return "inventory"
        case .lashReminder: return "lashReminder"
        case .income: return "income"
        case .salary: return "salary"
        case .userManagement: return "userManagement"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .appointments: return "calendar"
        case .records: return "photo.on.rectangle"
        case .orders: return "creditcard"
        case .customers: return "person.2"
        case .technicians: return "person.crop.square"
        case .services: return "list.bullet.rectangle"
        case .inventory: return "shippingbox"
        case .lashReminder: return "bell.badge"
        case .income: return "chart.bar"
        case .salary: return "banknote"
        case .userManagement: return "person.3.fill"
        }
    }
}

// MARK: - 空状态占位组件（HIG：SF Symbols + 引导文案）
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.brand.opacity(0.35))
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.title2.weight(.medium))
                .foregroundStyle(.primary)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 服务项目全名辅助（拼接树形分类路径）
/// 给定 ServiceItem.id，返回形如 "美甲-手部-纯色" 的完整路径名
func fullServiceName(
    for itemId: UUID,
    serviceMap: [UUID: ServiceItem],
    categoryMap: [UUID: ServiceCategory]
) -> String {
    guard let item = serviceMap[itemId] else { return "未知项目（已删除）" }
    var path: [String] = [item.name]
    var catId: UUID? = item.categoryId
    while let cid = catId, let cat = categoryMap[cid] {
        path.insert(cat.name, at: 0)
        catId = cat.parentId
    }
    return path.joined(separator: "-")
}

// MARK: - 侧边栏悬停高亮行（与仪表盘卡片一致的霓虹效果）
struct SidebarHoverRow<Content: View>: View {
    let content: Content
    @State private var isHovering = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.brand.opacity(isHovering ? 0.13 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.brand.opacity(isHovering ? 0.65 : 0), lineWidth: isHovering ? 1.2 : 0)
            )
            .shadow(color: isHovering ? Color.brand.opacity(0.25) : .clear, radius: 8)
            .onHover { hovering in
                // 滑入 0.02s 瞬间亮起；滑出 0.6s 缓慢熄灭，形成平滑扫过的层次
                withAnimation(.easeOut(duration: hovering ? 0.02 : 0.6)) {
                    isHovering = hovering
                }
            }
            .contentShape(Rectangle())
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .dashboard
    @Environment(\.modelContext) private var modelContext
    @State private var session = SessionManager.shared
    @State private var settingsHovering = false
    @Query private var categories: [ServiceCategory]
    // 跨模块跳转：服务记录 → 收银结账
    @State private var pendingCheckoutRecord: NailServiceRecord?
    @State private var showingSettings = false
    // 备份提醒：启动后检查一次，超过 15 天未备份则弹 Alert
    @State private var showingBackupReminder = false
    // 侧边栏动态项（仪表盘固定，其余可拖拽排序）
    @State private var sidebarItems: [SidebarItem] = SidebarPreferences.visibleItems()
    // 退出登录确认
    @State private var showingLogoutConfirm = false

    /// 按权限过滤后的侧边栏可见项
    private var authorizedSidebarItems: [SidebarItem] {
        sidebarItems.filter { session.hasPermission(moduleId: $0.moduleId) }
    }

    /// 侧边栏选中项的霓虹青色块：更高不透明度 + 霓虹描边 + 发光，制造"灯亮起"效果
    private func sidebarSelectedBackground() -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.brand.opacity(0.32))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.brand.opacity(0.95), lineWidth: 1)
            )
            .shadow(color: Color.brand.opacity(0.6), radius: 8)
            .padding(.horizontal, 6)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // 品牌头部（渐变 logo 方片 + 店名 + 副标题）
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.brandGradient)
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                            )
                            .shadow(color: Color.brand.opacity(0.35), radius: 4, y: 2)
                        Image(systemName: "paintbrush.pointed.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("杏子美甲")
                            .font(.headline)
                        Text("店铺管理系统")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Divider()

                List {
                    // 固定项：仪表盘（不可拖拽、不可隐藏）
                    if session.hasPermission(moduleId: SidebarItem.dashboard.moduleId) {
                        SidebarHoverRow {
                            Label {
                                Text(SidebarItem.dashboard.rawValue)
                            } icon: {
                                Image(systemName: SidebarItem.dashboard.icon)
                                    .foregroundStyle(selection == SidebarItem.dashboard ? Color.brand : Color.brandMono)
                                    .font(.system(size: 14, weight: .medium))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selection = SidebarItem.dashboard }
                        .listRowBackground(
                            selection == SidebarItem.dashboard
                                ? AnyView(sidebarSelectedBackground())
                                : AnyView(Color.clear)
                        )
                    }

                    // 可排序项：支持点击箭头调整顺序（按权限过滤）
                    ForEach(authorizedSidebarItems.filter { $0 != .dashboard }, id: \.self) { item in
                        SidebarHoverRow {
                            Label {
                                Text(item.rawValue)
                            } icon: {
                                Image(systemName: item.icon)
                                    .foregroundStyle(selection == item ? Color.brand : Color.brandMono)
                                    .font(.system(size: 14, weight: .medium))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selection = item }
                        .listRowBackground(
                            selection == item
                                ? AnyView(sidebarSelectedBackground())
                                : AnyView(Color.clear)
                        )
                    }
                }
                .listStyle(.sidebar)
                .contextMenu(ContextMenu(menuItems: { EmptyView() }))

                Divider()

                // 当前用户信息 + 设置 + 退出登录
                VStack(spacing: 0) {
                    // 用户卡片
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.brand.opacity(0.15))
                                .frame(width: 30, height: 30)
                            Image(systemName: "person.fill")
                                .foregroundStyle(Color.brand)
                                .font(.system(size: 12, weight: .bold))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.currentUser?.displayName ?? "未登录")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(session.roleLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    // 设置入口
                    Button {
                        showingSettings = true
                    } label: {
                        HStack(spacing: 8) {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "gearshape")
                                    .foregroundStyle(Color.brandMono)
                                    .font(.system(size: 14, weight: .medium))
                                if SecurityManager.shared.needsBackupReminder {
                                    Circle()
                                        .fill(.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 4, y: -4)
                                }
                            }
                            Text("设置")
                            Spacer()
                            if SecurityManager.shared.needsBackupReminder {
                                Text("待备份")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.red.opacity(0.12)))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.brand.opacity(settingsHovering ? 0.13 : 0))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.brand.opacity(settingsHovering ? 0.65 : 0), lineWidth: settingsHovering ? 1.2 : 0)
                        )
                        .shadow(color: settingsHovering ? Color.brand.opacity(0.25) : .clear, radius: 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: hovering ? 0.02 : 0.6)) {
                            settingsHovering = hovering
                        }
                    }
                    .padding(.horizontal, 8)

                    // 退出登录
                    Button {
                        showingLogoutConfirm = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(Color.brandMono)
                                .font(.system(size: 14, weight: .medium))
                            Text("退出登录")
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            .background(Color.brandBackground.ignoresSafeArea())
            .navigationTitle("杏子美甲")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch selection {
                case .dashboard:
                    DashboardView(onOpen: { selection = $0 })
                case .appointments: AppointmentView()
                case .records:
                    ServiceRecordView(onCheckout: { record in
                        pendingCheckoutRecord = record
                        selection = .orders
                    })
                case .orders:
                    OrderView(prefillRecord: pendingCheckoutRecord, onPrefillConsumed: {
                        pendingCheckoutRecord = nil
                    })
                case .customers: CustomerView()
                case .technicians: TechnicianView()
                case .services: ServiceView()
                case .inventory: InventoryView()
                case .lashReminder: LashReminderView()
                case .income: IncomeStatsView()
                case .salary: SalaryView()
                case .userManagement: UserManagementView()
                case .none:
                    ContentUnavailableView("请选择左侧模块", systemImage: "sidebar.left")
                }
            }
            // 赛博朋克模块切换：淡入 + 轻微放大 + 上滑过渡
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.brandBackground)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985))
                .combined(with: .offset(y: 6)),
            removal: .opacity))
        .animation(.easeInOut(duration: 0.28), value: selection)
        .sheet(isPresented: $showingSettings, onDismiss: {
            // 设置页关闭后刷新侧边栏（用户可能修改了显示/隐藏）
            sidebarItems = SidebarPreferences.visibleItems()
        }) {
            SettingsView()
        }
        // 备份提醒弹窗（HIG：.alert 标准样式，提供"立即备份"和"稍后提醒"两个动作）
        .alert("备份提醒", isPresented: $showingBackupReminder) {
            Button("立即备份") {
                showingSettings = true
            }
            Button("稍后提醒", role: .cancel) {}
        } message: {
            if let days = SecurityManager.shared.daysSinceLastBackup {
                Text("您已经 \(days) 天没有备份数据了。为防止数据丢失，建议立即进行一次备份。")
            } else {
                Text("您还未进行过数据备份。为防止数据丢失，建议立即进行一次备份。")
            }
        }
        .alert("退出登录", isPresented: $showingLogoutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) {
                session.logout()
                selection = .dashboard
                pendingCheckoutRecord = nil
            }
        } message: {
            Text("确认要退出当前登录账号吗？")
        }
        .task {
            seedIfNeeded()
            // 演示数据：仅 Debug + 空库首启时填充一次
            #if DEBUG
            TestDataSeeder.seedIfNeeded(in: modelContext)
            #endif
            // 启动后延迟 1.5 秒检查备份状态，避免和首屏渲染抢主线程
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if SecurityManager.shared.needsBackupReminder {
                    showingBackupReminder = true
                }
            }
            // 权限变更时，如果当前选中模块不在授权列表中，回退到仪表盘
            if let sel = selection, !session.hasPermission(moduleId: sel.moduleId) {
                selection = .dashboard
            }
        }
        .onChange(of: session.currentUser) { _, user in
            if let sel = selection, !session.hasPermission(moduleId: sel.moduleId) {
                selection = .dashboard
            }
        }
    }

    private func seedIfNeeded() {
        guard categories.isEmpty else { return }
        for c in defaultCategories() { modelContext.insert(c) }
        try? modelContext.save()
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Customer.self, Technician.self, ServiceCategory.self, ServiceItem.self,
             NailServiceRecord.self, Appointment.self, Order.self, InventoryItem.self
    )
    ContentView()
        .modelContainer(container)
}
