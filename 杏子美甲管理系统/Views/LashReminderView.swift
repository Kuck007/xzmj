//
//  LashReminderView.swift
//  杏子美甲管理系统
//
//  补睫提醒模块：根据已付款订单中的美睫项目自动生成提醒。
//  显示客户、会员等级、已付天数、应补日期、状态，支持标记已补睫。
//  支持手动增加补睫条目、快速标记已补睫、三点菜单查看/修改/删除。
//  补睫天数可在「补睫时间设置」中配置各会员等级。
//

import SwiftUI
import SwiftData

// MARK: - 中文日期格式化
private let cnDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "yyyy年M月d日"
    return f
}()

private extension Date {
    var cnDate: String { cnDateFormatter.string(from: self) }
}

struct LashReminderView: View {
    @Query(sort: \LashReminder.dueDate) private var reminders: [LashReminder]
    @Query private var customers: [Customer]
    @Query private var orders: [Order]
    @Query private var services: [ServiceItem]
    @Query private var categories: [ServiceCategory]
    @Environment(\.modelContext) private var context
    @State private var searchText = ""
    @State private var selectedReminder: LashReminder?
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var actionsForReminder: LashReminder?
    @State private var editingReminder: LashReminder?
    @State private var pendingDelete: LashReminder?
    @State private var appointmentForReminder: LashReminder?  // 从补睫提醒发起的预约

    private var customerMap: [UUID: Customer] {
        Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) })
    }
    private var orderMap: [UUID: Order] {
        Dictionary(uniqueKeysWithValues: orders.map { ($0.id, $0) })
    }
    private var serviceMap: [UUID: ServiceItem] {
        Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
    }
    private var categoryMap: [UUID: ServiceCategory] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    // 搜索过滤后的全部条目
    private var searchFiltered: [LashReminder] {
        guard !searchText.isEmpty else { return reminders }
        return reminders.filter { r in
            let name = customerMap[r.customerId]?.name ?? ""
            return name.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// 待补睫：未完成且过期不超过7天（daysUntil >= -7）
    private var pendingItems: [LashReminder] {
        searchFiltered.filter { r in
            !r.isCompleted && r.dynamicDaysUntilDue(customerMap: customerMap, orderMap: orderMap) >= -7
        }
    }
    /// 已过期：未完成且过期8-20天（-20 < daysUntil < -7）
    private var expiredItems: [LashReminder] {
        searchFiltered.filter { r in
            let d = r.dynamicDaysUntilDue(customerMap: customerMap, orderMap: orderMap)
            return !r.isCompleted && d < -7 && d > -20
        }
    }
    private var completedItems: [LashReminder] {
        searchFiltered.filter { $0.isCompleted }
    }

    private var overdueCount: Int {
        reminders.lazy.filter { r in
            guard !r.isCompleted else { return false }
            return r.dynamicDaysUntilDue(customerMap: customerMap, orderMap: orderMap) < 0
        }.count
    }

    private var dueSoonCount: Int {
        reminders.lazy.filter { r in
            guard !r.isCompleted else { return false }
            let d = r.dynamicDaysUntilDue(customerMap: customerMap, orderMap: orderMap)
            return d >= 0 && d <= 3
        }.count
    }

    /// 把关联 Order 的最新 paidAt 同步回 LashReminder 的持久化字段（保证 SwiftData sort 大致正确 & 老数据被刷新）。
    /// 只在字段真的不一样时才写，避免无意义 save。
    /// 如果 orderId 不存在于 orderMap（手动创建/旧数据迁移丢失关联），自动按客户+服务项目匹配最近订单。
    /// 同时扫描所有订单，为含美睫项目但缺补睫提醒的订单自动创建提醒（导入数据后也能动态生成）。
    private func syncRemindersFromOrders() {
        // —— Part 1: 为缺提醒的订单自动创建补睫提醒 ——
        createMissingLashReminders()

        var changed = false
        for r in reminders {
            // 1) 如果 orderId 不存在于数据库中，尝试按客户+服务项目匹配正确的订单
            if orderMap[r.orderId] == nil {
                let customerOrders = orders
                    .filter { $0.customerId == r.customerId }
                    .sorted { $0.paidAt > $1.paidAt }
                let reminderServiceSet = Set(r.serviceItemIds)
                // 优先匹配 lineItems 中包含 reminder 任意 serviceItemId 的订单；
                // 若 reminder 没有 serviceItemId，则取该客户最新的订单
                let matched = customerOrders.first { order in
                    let orderServiceIds = Set(order.lineItems.map { $0.serviceItemId })
                    return !orderServiceIds.isDisjoint(with: reminderServiceSet)
                } ?? (r.serviceItemIds.isEmpty ? customerOrders.first : nil)
                if let matchedOrder = matched {
                    r.orderId = matchedOrder.id
                    // 更新 paidAt 和 dueDate 在下一步处理
                }
            }
            // 2) 用 resolved 值（从 Order 动态读取或 fallback）更新存储字段
            let realPaid = r.resolvedPaidAt(orderMap: orderMap)
            let realDue = r.resolvedDueDate(customerMap: customerMap, orderMap: orderMap)
            if abs(realPaid.timeIntervalSince(r.paidAt)) > 1 || abs(realDue.timeIntervalSince(r.dueDate)) > 1 {
                r.paidAt = realPaid
                r.dueDate = realDue
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    /// 扫描所有订单，对含美睫项目（非补睫类）但没有对应补睫提醒的订单自动创建提醒。
    /// 确保导入数据、历史订单也能动态生成补睫提醒。
    private func createMissingLashReminders() {
        // 已有提醒的 orderId 集合
        let existingOrderIds = Set(reminders.map { $0.orderId })

        // 找出美睫分类及子分类ID
        let lashRoots = categories.filter { $0.name == "美睫" }
        guard !lashRoots.isEmpty else { return }
        var lashCategoryIds = Set<UUID>()
        for root in lashRoots { lashCategoryIds.formUnion(allDescendantCategoryIds(root.id)) }
        guard !lashCategoryIds.isEmpty else { return }

        for order in orders {
            // 跳过已有提醒的订单
            if existingOrderIds.contains(order.id) { continue }

            // 检查订单是否含美睫项目（跳过 isLashTouchUp 的补睫类项目）
            var lashItemIds: [UUID] = []
            for item in order.lineItems {
                guard let s = serviceMap[item.serviceItemId] else { continue }
                if s.isLashTouchUp { continue }
                var catId: UUID? = s.categoryId
                while let cid = catId {
                    if lashCategoryIds.contains(cid) { lashItemIds.append(s.id); break }
                    guard let parent = categories.first(where: { $0.id == cid }) else { break }
                    catId = parent.parentId
                }
            }
            if lashItemIds.isEmpty { continue }

            // 获取客户会员等级
            let customer = customerMap[order.customerId]
            let level = customer?.membershipLevel ?? "普通"

            // 创建补睫提醒
            let reminder = LashReminder(
                orderId: order.id,
                customerId: order.customerId,
                serviceItemIds: lashItemIds,
                paidAt: order.paidAt,
                dueDate: LashReminder.dueDate(from: order.paidAt, membershipLevel: level)
            )
            context.insert(reminder)
        }
        try? context.save()
    }

    var body: some View {
        // ⚠️ 不用 NavigationStack！macOS 上 NavigationStack 会吃掉 sheet 首次 present 的进入动画。
        // NavigationSplitView 的 detail column 会自动处理 .navigationTitle/.toolbar/.searchable，
        // NavigationStack 在 detail 里是冗余的。
        VStack(spacing: 0) {
            Group {
                if reminders.isEmpty {
                    EmptyStateView(
                        systemImage: "bell.badge",
                        title: "暂无补睫提醒",
                        message: "当有包含美睫项目的订单付款后，系统将自动生成补睫提醒\n也可点击右上角「增加补睫」手动添加"
                    )
                } else {
                    VStack(spacing: 0) {
                        // 提醒概览条 + 设置按钮
                        HStack(spacing: 16) {
                            if dueSoonCount > 0 {
                                Label("\(dueSoonCount) 条即将到期", systemImage: "bell.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button {
                                showingSettings = true
                            } label: {
                                Label("补睫时间设置", systemImage: "clock.badge.checkmark")
                                    .font(.caption)
                            }
                            .help("设置各会员等级的补睫天数")
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))

                        List {
                            // 未补睫区（固定上侧）
                            Section("待补睫（\(pendingItems.count)）") {
                                if pendingItems.isEmpty {
                                    Text("暂无待补睫记录")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    ForEach(pendingItems) { reminder in
                                        LashReminderRow(
                                            reminder: reminder,
                                            customer: customerMap[reminder.customerId],
                                            orderMap: orderMap,
                                            customerMap: customerMap,
                                            serviceMap: serviceMap,
                                            categoryMap: categoryMap,
                                            onTap: { selectedReminder = reminder },
                                            onMarkCompleted: { markCompleted(reminder) },
                                            onShowActions: { actionsForReminder = reminder }
                                        )
                                        .swipeActions(edge: .trailing) {
                                            Button("标记已补") {
                                                markCompleted(reminder)
                                            }
                                            .tint(.green)
                                            Button("删除", role: .destructive) {
                                                pendingDelete = reminder
                                            }
                                        }
                                    }
                                }
                            }

                            // 已过期区（过期8-20天，超过20天不显示）
                            if !expiredItems.isEmpty {
                                Section("已过期（\(expiredItems.count)）") {
                                    ForEach(expiredItems) { reminder in
                                        LashReminderRow(
                                            reminder: reminder,
                                            customer: customerMap[reminder.customerId],
                                            orderMap: orderMap,
                                            customerMap: customerMap,
                                            serviceMap: serviceMap,
                                            categoryMap: categoryMap,
                                            onTap: { selectedReminder = reminder },
                                            onMarkCompleted: { markCompleted(reminder) },
                                            onShowActions: { actionsForReminder = reminder }
                                        )
                                        .swipeActions(edge: .trailing) {
                                            Button("标记已补") {
                                                markCompleted(reminder)
                                            }
                                            .tint(.green)
                                            Button("删除", role: .destructive) {
                                                pendingDelete = reminder
                                            }
                                        }
                                    }
                                }
                            }

                            // 已补睫区（固定下侧）
                            Section("已补睫（\(completedItems.count)）") {
                                if completedItems.isEmpty {
                                    Text("暂无已补睫记录")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    ForEach(completedItems) { reminder in
                                        LashReminderRow(
                                            reminder: reminder,
                                            customer: customerMap[reminder.customerId],
                                            orderMap: orderMap,
                                            customerMap: customerMap,
                                            serviceMap: serviceMap,
                                            categoryMap: categoryMap,
                                            onTap: { selectedReminder = reminder },
                                            onMarkCompleted: {},
                                            onShowActions: { actionsForReminder = reminder }
                                        )
                                        .swipeActions(edge: .trailing) {
                                            Button("删除", role: .destructive) {
                                                pendingDelete = reminder
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(.inset)
                    }
                }
            }
        .navigationTitle("补睫提醒")
        .searchable(text: $searchText)
        .onAppear { DispatchQueue.main.async(execute: syncRemindersFromOrders) }
        .onChange(of: orders.count) { _, _ in DispatchQueue.main.async(execute: syncRemindersFromOrders) }
        .onChange(of: reminders.count) { _, _ in DispatchQueue.main.async(execute: syncRemindersFromOrders) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Button {
                        showingAdd = true
                    } label: {
                        Text("增加补睫")
                    }
                    .buttonStyle(BrandPrimaryButtonStyle())

                    Button {
                        showingSettings = true
                    } label: {
                        Label("补睫时间设置", systemImage: "clock.badge.checkmark")
                    }
                    .help("设置各会员等级的补睫天数")
                }
            }
        }
    }
    // ⚠️ 所有 sheet/alert 必须挂在 NavigationStack 外面！
    // 原因：NavigationStack 在首次 mount + @Query 重评估时，会把内部挂的 sheet 搞成"弹→关→弹"
    // 这是 macOS SwiftUI 臭名昭著的 bug，sheet 必须在 body 根级别。
    // 增加补睫表单
    .sheet(isPresented: $showingAdd) {
        AddLashReminderForm { customerId, paidAt, serviceItemIds in
            createReminder(customerId: customerId, paidAt: paidAt, serviceItemIds: serviceItemIds)
        }
        
    }
    // 补睫时间设置表单
    .sheet(isPresented: $showingSettings) {
        LashReminderSettingsForm()
        
    }
    // 详情
    .sheet(isPresented: Binding(
        get: { selectedReminder != nil },
        set: { if !$0 { selectedReminder = nil } }
    )) {
        if let reminder = selectedReminder {
            LashReminderDetailSheet(
                reminder: reminder,
                customer: customerMap[reminder.customerId],
                orderMap: orderMap,
                customerMap: customerMap,
                serviceMap: serviceMap,
                categoryMap: categoryMap,
                onEdit: {
                    selectedReminder = nil
                    editingReminder = reminder
                },
                onMarkCompleted: {
                    markCompleted(reminder)
                    selectedReminder = nil
                },
                onMarkPending: {
                    markPending(reminder)
                    selectedReminder = nil
                }
            )
        }
        
    }
    // 三点操作菜单
    .sheet(isPresented: Binding(
        get: { actionsForReminder != nil },
        set: { if !$0 { actionsForReminder = nil } }
    )) {
        if let reminder = actionsForReminder {
            LashReminderActionsSheet(
                reminder: reminder,
                customer: customerMap[reminder.customerId],
                onViewDetail: {
                    actionsForReminder = nil
                    selectedReminder = reminder
                },
                onEdit: {
                    actionsForReminder = nil
                    editingReminder = reminder
                },
                onDelete: {
                    actionsForReminder = nil
                    pendingDelete = reminder
                },
                onMakeAppointment: {
                    actionsForReminder = nil
                    appointmentForReminder = reminder
                }
            )
        }
        
    }
    // 编辑表单
    .sheet(isPresented: Binding(
        get: { editingReminder != nil },
        set: { if !$0 { editingReminder = nil } }
    )) {
        if let reminder = editingReminder {
            EditLashReminderForm(
                reminder: reminder,
                customers: customers,
                orderMap: orderMap,
                customerMap: customerMap,
                serviceMap: serviceMap,
                categoryMap: categoryMap
            ) { customerId, paidAt, isCompleted, serviceItemIds in
                reminder.customerId = customerId
                if let cust = customerMap[customerId] {
                    reminder.paidAt = paidAt
                    reminder.dueDate = LashReminder.dueDate(from: paidAt, membershipLevel: cust.membershipLevel)
                }
                reminder.isCompleted = isCompleted
                if isCompleted {
                    if reminder.completedAt == nil { reminder.completedAt = Date() }
                } else {
                    reminder.completedAt = nil
                }
                reminder.serviceItemIds = serviceItemIds
                try? context.save()
            }
        }
        
    }
    // 删除确认
    .alert("删除补睫提醒？", isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
    )) {
        Button("删除", role: .destructive) {
            if let r = pendingDelete { context.delete(r) }
        }
        Button("取消", role: .cancel) { pendingDelete = nil }
    } message: {
        Text("该补睫提醒将被永久删除，无法恢复。")
    }
    // 从补睫提醒发起预约表单
    .sheet(isPresented: Binding(
        get: { appointmentForReminder != nil },
        set: { if !$0 { appointmentForReminder = nil } }
    )) {
        if let reminder = appointmentForReminder {
            let prefill = AppointmentPrefillData(
                customerId: reminder.customerId,
                startTime: reminder.resolvedDueDate(
                    customerMap: customerMap,
                    orderMap: orderMap
                ),
                defaultServiceItemIds: [],
                reminderId: reminder.id
            )
            AppointmentFormView(prefill: prefill) { newAppt in
                context.insert(newAppt)
            }
        }
        
    }
}

    private func markCompleted(_ reminder: LashReminder) {
        guard !reminder.isCompleted else { return }
        reminder.isCompleted = true
        reminder.completedAt = Date()
        try? context.save()
    }

    /// 将已补睫条目改回待补睫状态
    private func markPending(_ reminder: LashReminder) {
        guard reminder.isCompleted else { return }
        reminder.isCompleted = false
        reminder.completedAt = nil
        try? context.save()
    }

    /// 手动创建补睫提醒
    private func createReminder(customerId: UUID, paidAt: Date, serviceItemIds: [UUID]) {
        let customer = customers.first(where: { $0.id == customerId })
        let level = customer?.membershipLevel ?? "普通"
        let reminder = LashReminder(
            orderId: UUID(),
            customerId: customerId,
            serviceItemIds: serviceItemIds,
            paidAt: paidAt,
            dueDate: LashReminder.dueDate(from: paidAt, membershipLevel: level)
        )
        context.insert(reminder)
        try? context.save()
    }

    // MARK: - 查找"美睫-补睫毛"项目

    /// 递归收集某分类下所有子分类ID
    private func allDescendantCategoryIds(_ rootId: UUID) -> Set<UUID> {
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

    /// 查找"美睫-补睫毛"项目（优先 isLashTouchUp 标记，其次按名称匹配）
    private func findLashTouchUpItem() -> ServiceItem? {
        // 1. 优先找标记为 isLashTouchUp 的项目
        if let hit = services.first(where: { $0.isLashTouchUp }) {
            return hit
        }
        // 2. 找"美睫"根分类
        guard let lashRoot = categories.first(where: { $0.name == "美睫" && $0.parentId == nil }) else {
            // 没有美睫分类，尝试找名字含"补睫"或"补睫毛"的项目
            return services.first(where: { $0.name.contains("补睫") })
        }
        // 3. 收集美睫所有子分类ID
        let lashCatIds = allDescendantCategoryIds(lashRoot.id)
        // 4. 按名称找"补睫毛"或"补睫"
        if let hit = services.first(where: { lashCatIds.contains($0.categoryId) && ($0.name == "补睫毛" || $0.name.contains("补睫")) }) {
            return hit
        }
        // 5. 找不到就取美睫分类下第一个项目
        return services.first(where: { lashCatIds.contains($0.categoryId) })
    }
}

// MARK: - 提醒行（含快速标记 + 三点菜单）

struct LashReminderRow: View {
    let reminder: LashReminder
    let customer: Customer?
    let orderMap: [UUID: Order]
    let customerMap: [UUID: Customer]
    let serviceMap: [UUID: ServiceItem]
    let categoryMap: [UUID: ServiceCategory]
    var onTap: () -> Void
    var onMarkCompleted: () -> Void
    var onShowActions: () -> Void

    private var serviceNames: String {
        reminder.serviceItemIds.compactMap { sid -> String? in
            guard let s = serviceMap[sid] else { return nil }
            return fullServiceName(for: s.id, serviceMap: serviceMap, categoryMap: categoryMap)
        }.joined(separator: " · ")
    }

    /// 真实应补日期（优先关联 Order）
    private var resolvedPaidAt: Date { reminder.resolvedPaidAt(orderMap: orderMap) }
    private var resolvedDueDate: Date { reminder.resolvedDueDate(customerMap: customerMap, orderMap: orderMap) }
    private var daysUntil: Int { reminder.dynamicDaysUntilDue(customerMap: customerMap, orderMap: orderMap) }

    private var statusIcon: String {
        if reminder.isCompleted { return "checkmark.circle.fill" }
        if daysUntil < 0 { return "exclamationmark.circle.fill" }
        if daysUntil <= 3 { return "bell.fill" }
        return "clock"
    }

    private var statusColor: Color {
        if reminder.isCompleted { return .green }
        if daysUntil < 0 { return .red }
        if daysUntil <= 3 { return .orange }
        return .secondary
    }

    private var statusText: String {
        if reminder.isCompleted {
            if let d = reminder.completedAt { return "已补睫 \(d.cnDate)" }
            return "已补睫"
        }
        if daysUntil < 0 {
            let days = abs(daysUntil)
            return "已过期 \(days) 天"
        }
        if daysUntil <= 3 {
            return daysUntil == 0 ? "今天到期" : "还剩 \(daysUntil) 天"
        }
        return "还有 \(daysUntil) 天"
    }

    var body: some View {
        HoverHighlightRow {
            HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(customer?.name ?? "未知客户")
                        .font(.headline)
                        .foregroundStyle(daysUntil < 0 ? .red : .primary)

                    if let level = customer?.membershipLevel {
                        Text(level)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(membershipColor(level), in: Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .font(.caption)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }

                if !serviceNames.isEmpty {
                    Text(serviceNames)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("付款 \(resolvedPaidAt.cnDate)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("应补 \(resolvedDueDate.cnDate)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(daysUntil < 0 ? .red : .primary)
            }

            // 未补睫的快速"已补睫"按钮
            if !reminder.isCompleted {
                Button {
                    onMarkCompleted()
                } label: {
                    Text("已补睫")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.green, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("快速标记为已补睫")
            }

            // 三点菜单
            Button {
                onShowActions()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - 三点操作菜单

struct LashReminderActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reminder: LashReminder
    let customer: Customer?
    let onViewDetail: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMakeAppointment: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("补睫操作").font(.headline)
                    Text(customer?.name ?? "未知客户").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            .padding(.bottom, 8)
            Divider()

            Button {
                dismiss()
                onMakeAppointment()
            } label: {
                HStack { Text("发起预约"); Spacer(); Image(systemName: "calendar.badge.plus") }
                    .padding(.vertical, 12).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Divider()

            Button {
                dismiss()
                onViewDetail()
            } label: {
                HStack { Text("查看详情"); Spacer(); Image(systemName: "eye") }
                    .padding(.vertical, 12).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Divider()

            Button {
                dismiss()
                onEdit()
            } label: {
                HStack { Text("修改"); Spacer(); Image(systemName: "pencil") }
                    .padding(.vertical, 12).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Divider()

            Button(role: .destructive) {
                dismiss()
                onDelete()
            } label: {
                HStack { Text("删除条目"); Spacer(); Image(systemName: "trash") }
                    .padding(.vertical, 12).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding()
        .frame(width: 260)
    }
}

// MARK: - 手动增加补睫表单

struct AddLashReminderForm: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var customers: [Customer]
    var onSave: (UUID, Date, [UUID]) -> Void

    @State private var customerId: UUID?
    @State private var paidAt = Date()
    @State private var selectedServiceIds: Set<UUID> = []
    @State private var showingServicePicker = false

    private var selectedCustomer: Customer? {
        customers.first(where: { $0.id == customerId })
    }

    private var dueDatePreview: Date? {
        guard let cid = customerId, let cust = customers.first(where: { $0.id == cid }) else { return nil }
        return LashReminder.dueDate(from: paidAt, membershipLevel: cust.membershipLevel)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("选择客户") {
                    LabeledContent("客户") {
                        CustomerField(customerId: $customerId, customers: customers)
                    }
                    if let cust = selectedCustomer {
                        HStack {
                            Text("会员等级")
                            Spacer()
                            Text(cust.membershipLevel)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(membershipColor(cust.membershipLevel), in: Capsule())
                        }
                    }
                }
                Section("补睫信息") {
                    LabeledContent("付款日期") {
                        TechCalendarPicker("", selection: $paidAt)
                    }
                    if let due = dueDatePreview {
                        HStack {
                            Text("应补睫日期")
                            Spacer()
                            Text(due.cnDate)
                                .fontWeight(.semibold)
                                .foregroundStyle(.orange)
                        }
                    }
                    HStack {
                        Text("服务项目")
                        Spacer()
                        if selectedServiceIds.isEmpty {
                            Text("未选择").foregroundStyle(.secondary)
                        } else {
                            Text("已选 \(selectedServiceIds.count) 项").foregroundStyle(.secondary)
                        }
                        Button("选择") { showingServicePicker = true }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("保存") {
                    if let cid = customerId {
                        onSave(cid, paidAt, Array(selectedServiceIds))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(customerId == nil)
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 420, idealHeight: 480, maxHeight: 650)
        .sheet(isPresented: $showingServicePicker) {
            LashServicePicker(
                selectedIds: $selectedServiceIds
            )
            
        }
    }
}

// MARK: - 编辑补睫表单（可修改客户/付款日期/状态/服务项目，自动重算应补日期）

struct EditLashReminderForm: View {
    @Environment(\.dismiss) private var dismiss
    let reminder: LashReminder
    let customers: [Customer]
    let orderMap: [UUID: Order]
    let customerMap: [UUID: Customer]
    let serviceMap: [UUID: ServiceItem]
    let categoryMap: [UUID: ServiceCategory]
    var onSave: (UUID, Date, Bool, [UUID]) -> Void

    @State private var customerId: UUID?
    @State private var paidAt = Date()
    @State private var isCompleted = false
    @State private var selectedServiceIds: Set<UUID> = []
    @State private var showingServicePicker = false

    private var selectedCustomer: Customer? {
        customers.first(where: { $0.id == customerId })
    }

    init(reminder: LashReminder,
         customers: [Customer],
         serviceMap: [UUID: ServiceItem],
         categoryMap: [UUID: ServiceCategory],
         onSave: @escaping (UUID, Date, Bool, [UUID]) -> Void) {
        self.reminder = reminder
        self.customers = customers
        self.orderMap = [:]   // 未启用（兼容性：这个 init 签名保留）
        self.customerMap = Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) })
        self.serviceMap = serviceMap
        self.categoryMap = categoryMap
        self.onSave = onSave
        _customerId = State(initialValue: reminder.customerId)
        // 优先用关联订单最新的付款时间
        let resolvedPaid = reminder.resolvedPaidAt(orderMap: self.orderMap)
        _paidAt = State(initialValue: resolvedPaid)
        _isCompleted = State(initialValue: reminder.isCompleted)
        _selectedServiceIds = State(initialValue: Set(reminder.serviceItemIds))
    }

    /// 完整 init：支持传入 orderMap / customerMap，用于显示最新 Order.paidAt
    init(reminder: LashReminder,
         customers: [Customer],
         orderMap: [UUID: Order],
         customerMap: [UUID: Customer],
         serviceMap: [UUID: ServiceItem],
         categoryMap: [UUID: ServiceCategory],
         onSave: @escaping (UUID, Date, Bool, [UUID]) -> Void) {
        self.reminder = reminder
        self.customers = customers
        self.orderMap = orderMap
        self.customerMap = customerMap
        self.serviceMap = serviceMap
        self.categoryMap = categoryMap
        self.onSave = onSave
        _customerId = State(initialValue: reminder.customerId)
        // 用关联订单的最新付款时间作为默认值（收银结账那边改了，这里打开就看到最新）
        let resolvedPaid = reminder.resolvedPaidAt(orderMap: orderMap)
        _paidAt = State(initialValue: resolvedPaid)
        _isCompleted = State(initialValue: reminder.isCompleted)
        _selectedServiceIds = State(initialValue: Set(reminder.serviceItemIds))
    }

    /// 根据当前客户会员等级动态计算应补睫日期
    private var dueDatePreview: Date? {
        guard let cust = selectedCustomer else { return nil }
        return LashReminder.dueDate(from: paidAt, membershipLevel: cust.membershipLevel)
    }

    private var serviceNames: String {
        selectedServiceIds.compactMap { sid -> String? in
            guard let s = serviceMap[sid] else { return nil }
            return fullServiceName(for: s.id, serviceMap: serviceMap, categoryMap: categoryMap)
        }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("客户信息") {
                    LabeledContent("客户") {
                        CustomerField(customerId: $customerId, customers: customers)
                    }
                    if let cust = selectedCustomer {
                        HStack {
                            Text("会员等级")
                            Spacer()
                            Text(cust.membershipLevel)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(membershipColor(cust.membershipLevel), in: Capsule())
                        }
                    }
                }
                Section("补睫信息") {
                    LabeledContent("付款日期") {
                        TechCalendarPicker("", selection: $paidAt)
                    }
                    if let due = dueDatePreview {
                        HStack {
                            Text("应补睫日期")
                            Spacer()
                            Text(due.cnDate)
                                .fontWeight(.semibold)
                                .foregroundStyle(.orange)
                        }
                    }
                    Picker("当前状态", selection: $isCompleted) {
                        Text("待补睫").tag(false)
                        Text("已补睫").tag(true)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("服务项目")
                        Spacer()
                        if selectedServiceIds.isEmpty {
                            Text("未选择").foregroundStyle(.secondary)
                        } else {
                            Text(serviceNames).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Button("选择") { showingServicePicker = true }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("保存") {
                    if let cid = customerId {
                        onSave(cid, paidAt, isCompleted, Array(selectedServiceIds))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(customerId == nil)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 440, idealHeight: 480, maxHeight: 700)
        .sheet(isPresented: $showingServicePicker) {
            LashServicePicker(selectedIds: $selectedServiceIds)
            
        }
    }
}

// MARK: - 补睫时间设置表单

struct LashReminderSettingsForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var daysByLevel: [String: Int] = [:]

    private var levels: [String] { LashReminderSettings.membershipLevels }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("补睫时间设置").font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            Form {
                Section("会员等级补睫天数") {
                    ForEach(levels, id: \.self) { level in
                        HStack {
                            Text(level)
                                .frame(width: 60, alignment: .leading)
                            Stepper(value: Binding(
                                get: { daysByLevel[level] ?? LashReminderSettings.shared.days(for: level) },
                                set: { daysByLevel[level] = $0 }
                            ), in: 1...60) {
                                Text("\(daysByLevel[level] ?? LashReminderSettings.shared.days(for: level)) 天")
                            }
                        }
                    }
                }
                Section("说明") {
                    Text("设置各会员等级的补睫提醒天数。\n普通会员默认 10 天，银卡/金卡会员默认 15 天。\n修改后对新生成的提醒生效，已生成的提醒需在「修改」中重新计算。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("保存") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 400, minHeight: 380, idealHeight: 420, maxHeight: 600)
        .onAppear {
            for level in levels {
                daysByLevel[level] = LashReminderSettings.shared.days(for: level)
            }
        }
    }

    private func save() {
        for level in levels {
            if let v = daysByLevel[level] {
                LashReminderSettings.shared.setDays(v, for: level)
            }
        }
    }
}

// MARK: - 服务项目多选 Sheet

struct LashServicePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedIds: Set<UUID>
    @Query private var services: [ServiceItem]
    @Query private var categories: [ServiceCategory]

    // 只显示美睫分类下的项目
    private var lashServices: [ServiceItem] {
        let lashRootIds = Set(categories.filter { $0.name == "美睫" && $0.parentId == nil }.map { $0.id })
        // 收集美睫根分类的所有子分类
        var lashCatIds = Set<UUID>(lashRootIds)
        var changed = true
        while changed {
            changed = false
            for c in categories {
                if let pid = c.parentId, lashCatIds.contains(pid), !lashCatIds.contains(c.id) {
                    lashCatIds.insert(c.id)
                    changed = true
                }
            }
        }
        return services.filter { lashCatIds.contains($0.categoryId) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择美睫服务项目")
                    .font(.headline)
                Text("已选 \(selectedIds.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if lashServices.isEmpty {
                Spacer()
                EmptyStateView(
                    systemImage: "bell.badge",
                    title: "暂无美睫项目",
                    message: "请先在「服务项目」模块创建美睫分类下的项目"
                )
                Spacer()
            } else {
                List {
                    ForEach(lashServices) { s in
                        Button {
                            if selectedIds.contains(s.id) {
                                selectedIds.remove(s.id)
                            } else {
                                selectedIds.insert(s.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: selectedIds.contains(s.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIds.contains(s.id) ? Color.accentColor : .secondary)
                                    .font(.system(size: 16))
                                Text(s.name)
                                Spacer()
                                Text("¥" + String(format: "%.0f", s.price))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Button("确认") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 440, idealHeight: 480, maxHeight: 700)
    }
}

// MARK: - 补睫提醒详情 Sheet

struct LashReminderDetailSheet: View {
    let reminder: LashReminder
    let customer: Customer?
    let orderMap: [UUID: Order]
    let customerMap: [UUID: Customer]
    let serviceMap: [UUID: ServiceItem]
    let categoryMap: [UUID: ServiceCategory]
    var onEdit: () -> Void
    var onMarkCompleted: () -> Void
    var onMarkPending: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var serviceNames: String {
        reminder.serviceItemIds.compactMap { sid -> String? in
            guard let s = serviceMap[sid] else { return nil }
            return fullServiceName(for: s.id, serviceMap: serviceMap, categoryMap: categoryMap)
        }.joined(separator: " · ")
    }

    private var resolvedPaidAt: Date { reminder.resolvedPaidAt(orderMap: orderMap) }
    private var resolvedDueDate: Date { reminder.resolvedDueDate(customerMap: customerMap, orderMap: orderMap) }
    private var daysUntil: Int { reminder.dynamicDaysUntilDue(customerMap: customerMap, orderMap: orderMap) }
    private var isBoundToOrder: Bool { orderMap[reminder.orderId] != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("补睫提醒详情").font(.headline)
                    Text(customer?.name ?? "未知客户")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            Form {
                Section("客户信息") {
                    LabeledContent("姓名", value: customer?.name ?? "未知")
                    if let phone = customer?.phone {
                        LabeledContent("电话", value: phone)
                    }
                    if let level = customer?.membershipLevel {
                        LabeledContent("会员等级") {
                            Text(level)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(membershipColor(level), in: Capsule())
                        }
                    }
                }
                Section("补睫信息") {
                    LabeledContent("付款日期", value: resolvedPaidAt.cnDate)
                    if isBoundToOrder {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                .foregroundStyle(Color.green)
                            Text("跟随收银结账时间同步")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("应补睫日期", value: resolvedDueDate.cnDate)
                    if !reminder.isCompleted {
                        HStack {
                            Text("状态")
                            Spacer()
                            if daysUntil < 0 {
                                Text("已过期 \(abs(daysUntil)) 天")
                                    .foregroundStyle(.red)
                            } else if daysUntil <= 3 {
                                Text(daysUntil == 0 ? "今天到期" : "还剩 \(daysUntil) 天")
                                    .foregroundStyle(.orange)
                            } else {
                                Text("还有 \(daysUntil) 天")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        LabeledContent("状态", value: "已补睫")
                        if let d = reminder.completedAt {
                            LabeledContent("完成时间", value: d.cnDate)
                        }
                    }
                    if !serviceNames.isEmpty {
                        LabeledContent("服务项目", value: serviceNames)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("修改") { onEdit() }
                    .buttonStyle(.bordered)
                if !reminder.isCompleted {
                    Button("标记已补睫") {
                        onMarkCompleted()
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                } else {
                    Button("改为待补睫") {
                        onMarkPending()
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 440, idealHeight: 480, maxHeight: 700)
    }
}
