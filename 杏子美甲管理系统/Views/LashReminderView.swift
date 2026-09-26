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

// MARK: - 补睫提醒筛选栏
private enum ReminderTab: String, CaseIterable {
    case pending = "未补睫"
    case expired = "已过期"
    case completed = "已补睫"
}

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
    @Environment(AppCore.self) private var appCore

    private var reminders: [LashReminder] { appCore.lashRemindersByDueDateAsc }
    private var customers: [Customer] { appCore.customers }
    private var orders: [Order] { appCore.orders }
    private var services: [ServiceItem] { appCore.serviceItems }
    private var categories: [ServiceCategory] { appCore.categories }
    @State private var searchText = ""
    @State private var selectedReminder: LashReminder?
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var currentTab: ReminderTab = .pending
    @State private var currentPage = 1
    private let pageSize = 10
    @State private var actionsForReminder: LashReminder?
    @State private var editingReminder: LashReminder?
    @State private var pendingDelete: LashReminder?
    @State private var appointmentForReminder: LashReminder?  // 从补睫提醒发起的预约

    private var customerMap: [UUID: Customer] { appCore.customerMap }
    private var serviceMap: [UUID: ServiceItem] { appCore.serviceMap }
    private var categoryMap: [UUID: ServiceCategory] { appCore.categoryMap }

    // 搜索过滤后的全部条目
    private var searchFiltered: [LashReminder] {
        guard !searchText.isEmpty else { return reminders }
        return reminders.filter { r in
            let name = customerMap[r.customerId]?.name ?? ""
            return name.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// 当前 tab 对应的列表（已分组、已排序）
    /// - pending: 未补睫（含未到期 + 过期7天内），按应补日期升序（早的在前）
    /// - expired: 已过期（过期8-20天），按过期天数倒序（过期少的在前）
    /// - completed: 已补睫，按完成时间倒序（最近补的在前）
    private var currentItems: [LashReminder] {
        var result: [LashReminder] = []
        for r in searchFiltered {
            switch currentTab {
            case .pending:
                if !r.isCompleted && r.daysUntilDue >= -7 { result.append(r) }
            case .expired:
                if !r.isCompleted && r.daysUntilDue > -20 && r.daysUntilDue < -7 { result.append(r) }
            case .completed:
                if r.isCompleted { result.append(r) }
            }
        }
        switch currentTab {
        case .pending:
            result.sort { $0.daysUntilDue < $1.daysUntilDue }
        case .expired:
            // 倒序：过期天数少的（daysUntilDue 大的）排最上面
            result.sort { $0.daysUntilDue > $1.daysUntilDue }
        case .completed:
            result.sort { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        }
        return result
    }

    private var totalPages: Int {
        max(1, Int(ceil(Double(currentItems.count) / Double(pageSize))))
    }

    private var pagedItems: [LashReminder] {
        let start = (currentPage - 1) * pageSize
        let end = min(start + pageSize, currentItems.count)
        guard start < end else { return [] }
        return Array(currentItems[start..<end])
    }

    var body: some View {
        // ⚠️ 不用 NavigationStack！macOS 上 NavigationStack 会吃掉 sheet 首次 present 的进入动画。
        // NavigationSplitView 的 detail column 会自动处理 .navigationTitle/.toolbar/.searchable，
        // NavigationStack 在 detail 里是冗余的。

        return VStack(spacing: 0) {
            Group {
                if reminders.isEmpty {
                    EmptyStateView(
                        systemImage: "bell.badge",
                        title: "暂无补睫提醒",
                        message: "当有包含美睫项目的订单付款后，系统将自动生成补睫提醒\n也可点击右上角「增加补睫」手动添加"
                    )
                } else {
                    VStack(spacing: 0) {
                        // 顶部切换栏：未补睫 / 已过期 / 已补睫
                        HStack {
                            Picker("", selection: $currentTab) {
                                ForEach(ReminderTab.allCases, id: \.self) { tab in
                                    Text(tab.rawValue).tag(tab)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 320)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        Divider()

                        if currentItems.isEmpty {
                            EmptyStateView(
                                systemImage: "bell.badge",
                                title: "暂无\(currentTab.rawValue)记录",
                                message: ""
                            )
                        } else {
                            VStack(spacing: 0) {
                                ScrollViewReader { proxy in
                                    List {
                                        ForEach(pagedItems) { reminder in
                                            LashReminderRow(
                                                reminder: reminder,
                                                customer: customerMap[reminder.customerId],
                                                serviceMap: serviceMap,
                                                categoryMap: categoryMap,
                                                onTap: { selectedReminder = reminder },
                                                onMarkCompleted: currentTab == .completed ? {} : { markCompleted(reminder) },
                                                onShowActions: { actionsForReminder = reminder }
                                            )
                                            .id(reminder.id)
                                            .swipeActions(edge: .trailing) {
                                                if currentTab != .completed {
                                                    Button("标记已补") {
                                                        markCompleted(reminder)
                                                    }
                                                    .tint(.green)
                                                }
                                                Button("删除", role: .destructive) {
                                                    pendingDelete = reminder
                                                }
                                            }
                                        }
                                    }
                                    .listStyle(.inset)
                                    .onChange(of: currentPage) { _, _ in
                                        if let first = pagedItems.first {
                                            proxy.scrollTo(first.id, anchor: .top)
                                        }
                                    }
                                }
                                Divider()
                                PaginationBar(currentPage: $currentPage,
                                              totalPages: totalPages,
                                              totalItems: currentItems.count)
                            }
                        }
                    }
                }
            }
        .navigationTitle("补睫提醒")
        .searchable(text: $searchText)
        .onChange(of: searchText) { _, _ in currentPage = 1 }
        .onChange(of: currentTab) { _, _ in currentPage = 1 }
        .onChange(of: currentItems.count) { _, _ in
            if currentPage > totalPages { currentPage = totalPages }
        }
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
                    // 手动改回待补睫：解除与补睫付款的关联，避免删单时残留无效关联
                    reminder.completedByOrderId = nil
                }
                reminder.serviceItemIds = serviceItemIds
                appCore.save()
            }
        }
        
    }
    // 删除确认
    .alert("删除补睫提醒？", isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
    )) {
        Button("删除", role: .destructive) {
            if let r = pendingDelete { appCore.delete(r) }
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
                startTime: reminder.dueDate,
                defaultServiceItemIds: [],
                reminderId: reminder.id
            )
            AppointmentFormView(prefill: prefill) { newAppt in
                appCore.insert(newAppt)
            }
        }
        
    }
}

    private func markCompleted(_ reminder: LashReminder) {
        guard !reminder.isCompleted else { return }
        reminder.isCompleted = true
        reminder.completedAt = Date()
        appCore.save()
    }

    /// 将已补睫条目改回待补睫状态
    private func markPending(_ reminder: LashReminder) {
        guard reminder.isCompleted else { return }
        reminder.isCompleted = false
        reminder.completedAt = nil
        // 手动改回待补睫：解除与补睫付款的关联，避免删单时残留无效关联
        reminder.completedByOrderId = nil
        appCore.save()
    }

    /// 手动创建补睫提醒（不关联任何订单，orderId 用哨兵 noOrderID，避免被 sync 绑定订单后随删单误删）
    private func createReminder(customerId: UUID, paidAt: Date, serviceItemIds: [UUID]) {
        let customer = customers.first(where: { $0.id == customerId })
        let level = customer?.membershipLevel ?? "普通"
        let reminder = LashReminder(
            orderId: LashReminder.noOrderID,
            customerId: customerId,
            serviceItemIds: serviceItemIds,
            paidAt: paidAt,
            dueDate: LashReminder.dueDate(from: paidAt, membershipLevel: level)
        )
        appCore.insert(reminder)
    }
}

// MARK: - 提醒行（含快速标记 + 三点菜单）

struct LashReminderRow: View {
    let reminder: LashReminder
    let customer: Customer?
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

    // 日期均为创建时固化的存储值，不再随设置/等级/订单动态重算
    private var paidAt: Date { reminder.paidAt }
    private var dueDate: Date { reminder.dueDate }
    private var daysUntil: Int { reminder.daysUntilDue }

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
                Text("付款 \(paidAt.cnDate)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("应补 \(dueDate.cnDate)")
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
    @Environment(AppCore.self) private var appCore
    @Environment(\.dismiss) private var dismiss

    private var customers: [Customer] { appCore.customers }
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
        self.serviceMap = serviceMap
        self.categoryMap = categoryMap
        self.onSave = onSave
        _customerId = State(initialValue: reminder.customerId)
        // 付款日期用提醒自身固化的 paidAt（不再跟随订单动态读取）
        _paidAt = State(initialValue: reminder.paidAt)
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
    @Environment(AppCore.self) private var appCore
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedIds: Set<UUID>

    private var services: [ServiceItem] { appCore.serviceItems }
    private var categories: [ServiceCategory] { appCore.categories }

    // 只显示美睫分类下的「种植类主项目」：补睫/卸除等 isLashTouchUp 售后项目不列出
    // （手动增加补睫是为某次美睫种植登记提醒，补睫/卸除本身不会再产生补睫提醒）
    private var lashServices: [ServiceItem] {
        let lashCatIds = lashCategoryIDs(in: categories)
        return services.filter { lashCatIds.contains($0.categoryId) && !$0.isLashTouchUp }
            .sorted { $0.name < $1.name }
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

    // 日期均为创建时固化的存储值，不再随设置/等级/订单动态重算
    private var paidAt: Date { reminder.paidAt }
    private var dueDate: Date { reminder.dueDate }
    private var daysUntil: Int { reminder.daysUntilDue }

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
                    LabeledContent("付款日期", value: paidAt.cnDate)
                    LabeledContent("应补睫日期", value: dueDate.cnDate)
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
