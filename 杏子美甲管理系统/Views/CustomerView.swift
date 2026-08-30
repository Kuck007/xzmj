//
//  CustomerView.swift
//  杏子美甲管理系统
//

import SwiftUI
import SwiftData

// MARK: - 中文日期格式化（24小时制）
private let cnDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "yyyy年M月d日 HH:mm"
    return f
}()

private extension Date {
    var cnDateTime: String { cnDateFormatter.string(from: self) }
}

/// 会员等级对应的徽章颜色：普通=品牌色，银卡=银色，金卡=金色
func membershipColor(_ level: String) -> Color {
    switch level {
    case "金卡": return Color(red: 0.72, green: 0.53, blue: 0.04)  // 金色
    case "银卡": return Color(red: 0.45, green: 0.45, blue: 0.5)   // 银色
    default: return .brand                                            // 普通 → 品牌色
    }
}

/// 客户信息模块的会员筛选
enum MembershipFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case member = "会员"
    case nonMember = "非会员"
    var id: String { rawValue }
}

struct CustomerView: View {
    @Query private var customers: [Customer]
    @Query private var allOrders: [Order]
    @Query private var allLashReminders: [LashReminder]
    @Query(sort: \RechargeRecord.rechargeAt, order: .reverse) private var allRecharges: [RechargeRecord]
    @Environment(\.modelContext) private var context
    @State private var searchText = ""
    @State private var membershipFilter: MembershipFilter = .all
    @State private var showingAdd = false
    @State private var pendingDelete: Customer?
    @State private var actionsForCustomer: Customer?
    @State private var editingCustomer: Customer?
    @State private var selectedCustomer: Customer?
    @State private var currentPage = 1
    @State private var showingRecharge = false
    private let pageSize = 20

    // 按客户分组动态计算（从实际记录统计，不依赖存储字段）
    private var rechargedByCustomer: [UUID: Double] {
        Dictionary(grouping: allRecharges, by: { $0.customerId })
            .mapValues { $0.reduce(0) { $0 + $1.amount } }
    }
    /// 钱包余额 = 累计充值 + 累计赠送 - 各订单中钱包扣除的总和
    private var walletByCustomer: [UUID: Double] {
        let walletUsed = Dictionary(grouping: allOrders, by: { $0.customerId })
            .mapValues { $0.reduce(0) { $0 + $1.walletDeducted } }
        let bonusByCustomer = Dictionary(grouping: allRecharges, by: { $0.customerId })
            .mapValues { $0.reduce(0) { $0 + $1.bonus } }
        let allIds = Set(rechargedByCustomer.keys).union(walletUsed.keys)
        var result: [UUID: Double] = [:]
        for cid in allIds {
            let recharge = rechargedByCustomer[cid] ?? 0
            let bonus = bonusByCustomer[cid] ?? 0
            let used = walletUsed[cid] ?? 0
            result[cid] = max(0, recharge + bonus - used)
        }
        return result
    }
    /// 累计消费 = 累计充值 + 所有订单中非钱包实付部分
    private var totalSpentByCustomer: [UUID: Double] {
        let orderTopUp = Dictionary(grouping: allOrders, by: { $0.customerId })
            .mapValues { $0.reduce(0) { $0 + max(0, $1.totalAmount - $1.walletDeducted) } }
        let allIds = Set(rechargedByCustomer.keys).union(orderTopUp.keys)
        var result: [UUID: Double] = [:]
        for cid in allIds {
            let recharge = rechargedByCustomer[cid] ?? 0
            let topUp = orderTopUp[cid] ?? 0
            result[cid] = recharge + topUp
        }
        return result
    }

    private var filtered: [Customer] {
        var result = customers.sorted { pinyinLess($0.name, $1.name) }
        if !searchText.isEmpty {
            result = result.filter { customerMatches($0, text: searchText) }
        }
        switch membershipFilter {
        case .all: break
        case .member: result = result.filter { $0.membershipLevel != "普通" }
        case .nonMember: result = result.filter { $0.membershipLevel == "普通" }
        }
        return result
    }

    // 分页计算
    private var totalPages: Int {
        max(1, Int(ceil(Double(filtered.count) / Double(pageSize))))
    }

    private var pagedCustomers: [Customer] {
        let start = (currentPage - 1) * pageSize
        let end = min(start + pageSize, filtered.count)
        guard start < end else { return [] }
        return Array(filtered[start..<end])
    }

    var body: some View {
        // macOS NavigationSplitView 的 detail column 会自动处理 .navigationTitle/.toolbar/.searchable，NavigationStack 在 detail 里是冗余的，且会吃掉 sheet 首次 present 的进入动画
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // 会员筛选栏
                HStack {
                    Picker("", selection: $membershipFilter) {
                        ForEach(MembershipFilter.allCases) { f in Text(f.rawValue).tag(f) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
                Group {
                    if filtered.isEmpty {
                        EmptyStateView(
                            systemImage: "person.2",
                            title: searchText.isEmpty ? "暂无客户" : "无匹配客户",
                            message: searchText.isEmpty ? "点击右上角「添加客户」开始记录客户信息" : "尝试更换搜索关键词"
                        )
                    } else {
                        VStack(spacing: 0) {
                            List {
                                ForEach(pagedCustomers) { customer in
                                    CustomerRow(
                                        customer: customer,
                                        totalSpent: totalSpentByCustomer[customer.id] ?? 0,
                                        walletBalance: walletByCustomer[customer.id] ?? 0,
                                        onTap: { selectedCustomer = customer },
                                        onShowActions: { actionsForCustomer = customer }
                                    )
                                    .swipeActions {
                                        Button("删除", role: .destructive) { pendingDelete = customer }
                                    }
                                }
                            }
                            .listStyle(.inset)
                            Divider()
                            PaginationBar(currentPage: $currentPage,
                                          totalPages: totalPages,
                                          totalItems: filtered.count)
                        }
                    }
                }
            }
            .navigationTitle("客户信息")
            .searchable(text: $searchText)
            .onChange(of: searchText) { _, _ in currentPage = 1 }
            .onChange(of: membershipFilter) { _, _ in currentPage = 1 }
            .onChange(of: filtered.count) { _, _ in
                if currentPage > totalPages { currentPage = totalPages }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 8) {
                        Button {
                            showingRecharge = true
                        } label: {
                            Text("客户充值")
                        }
                        .buttonStyle(BrandPrimaryButtonStyle())
                        Button {
                            showingAdd = true
                        } label: {
                            Text("添加客户")
                        }
                        .buttonStyle(BrandPrimaryButtonStyle())
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                CustomerFormView { context.insert($0) }
                
            }
            .sheet(isPresented: $showingRecharge) {
                RechargeSheet(customers: customers) { customer, amount, bonus, paymentMethod, note, rechargeAt in
                    performRecharge(customer: customer, amount: amount, bonus: bonus,
                                    paymentMethod: paymentMethod, note: note, rechargeAt: rechargeAt)
                }
                
            }
            .sheet(isPresented: Binding(get: { selectedCustomer != nil }, set: { if !$0 { selectedCustomer = nil } })) {
                if let c = selectedCustomer {
                    CustomerDetailSheet(customer: c)
                }
                
            }
            .sheet(isPresented: Binding(get: { actionsForCustomer != nil }, set: { if !$0 { actionsForCustomer = nil } })) {
                if let c = actionsForCustomer {
                    CustomerActionsSheet(
                        customer: c,
                        onEdit: {
                            actionsForCustomer = nil
                            editingCustomer = c
                        },
                        onDelete: {
                            actionsForCustomer = nil
                            pendingDelete = c
                        }
                    )
                }
                
            }
            .sheet(isPresented: Binding(get: { editingCustomer != nil }, set: { if !$0 { editingCustomer = nil } })) {
                if let c = editingCustomer {
                    CustomerFormView(customer: c) { _ in }
                }
                
            }
            .alert("删除客户？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let c = pendingDelete { context.delete(c) }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("该客户将被永久删除，无法恢复。")
            }
        }
    }
}

// MARK: - 客户行
struct CustomerRow: View {
    let customer: Customer
    let totalSpent: Double
    let walletBalance: Double
    var onTap: () -> Void
    var onShowActions: () -> Void

    var body: some View {
        HoverHighlightRow {
            HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(customer.name).font(.headline).foregroundStyle(.primary)
                    Text(customer.membershipLevel)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(membershipColor(customer.membershipLevel), in: Capsule())
                    if !customer.isActive {
                        Text("已停用")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.red.opacity(0.1), in: Capsule())
                    }
                }
                HStack {
                    Text(customer.phone).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("累计 ¥" + String(format: "%.0f", totalSpent))
                            .font(.caption).foregroundStyle(.secondary)
                        if walletBalance > 0 {
                            Text("钱包 ¥" + String(format: "%.0f", walletBalance))
                                .font(.caption2).foregroundStyle(Color.orange)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

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
            .padding(.vertical, 4)
        }
    }
}

// MARK: - 三点操作菜单
struct CustomerActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let customer: Customer
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("客户操作").font(.headline)
                    Text(customer.name).font(.caption).foregroundStyle(.secondary)
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
                onEdit()
            } label: {
                HStack { Text("修改客户"); Spacer(); Image(systemName: "pencil") }
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
                HStack { Text("删除客户"); Spacer(); Image(systemName: "trash") }
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

// MARK: - 客户详情（Sheet 弹出）
struct CustomerDetailSheet: View {
    let customer: Customer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var records: [NailServiceRecord]
    @Query private var orders: [Order]
    @Query(sort: \RechargeRecord.rechargeAt, order: .reverse) private var recharges: [RechargeRecord]
    @Query private var technicians: [Technician]
    @Query private var allRecords: [NailServiceRecord]
    @Query private var allLashReminders: [LashReminder]
    @Query private var services: [ServiceItem]
    @Query private var categories: [ServiceCategory]
    @State private var showingEdit = false
    @State private var selectedRecord: NailServiceRecord?
    @State private var selectedOrder: Order?
    @State private var showingRecordCalendar = false
    @State private var showingOrderCalendar = false
    @State private var showingRechargeCalendar = false
    @State private var rechargeToDelete: RechargeRecord?
    @State private var deletePassword = ""
    @State private var passwordError: String?
    @State private var showingDeleteError = false

    init(customer: Customer) {
        self.customer = customer
        let cid = customer.id
        _records = Query(filter: #Predicate<NailServiceRecord> { $0.customerId == cid },
                         sort: \.serviceDate, order: .reverse)
        _orders = Query(filter: #Predicate<Order> { $0.customerId == cid },
                        sort: \.paidAt, order: .reverse)
        _recharges = Query(filter: #Predicate<RechargeRecord> { $0.customerId == cid },
                           sort: \.rechargeAt, order: .reverse)
    }

    // 动态计算：累计消费
    private var ordersTotal: Double { orders.reduce(0) { $0 + $1.totalAmount } }
    // 动态计算：最后到店时间（取最新一笔订单的付款时间）
    private var latestOrderDate: Date? { orders.first?.paidAt }
    private var technicianMap: [UUID: Technician] { Dictionary(uniqueKeysWithValues: technicians.map { ($0.id, $0) }) }
    private var serviceMap: [UUID: ServiceItem] { Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) }) }
    private var categoryMap: [UUID: ServiceCategory] { Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) }) }

    // MARK: - 动态计算（从实际记录统计，不依赖存储字段）
    /// 累计充值 = 所有充值记录金额之和
    private var computedTotalRecharged: Double { recharges.reduce(0) { $0 + $1.amount } }
    /// 钱包余额 = 累计充值 + 累计赠送 - 所有订单中钱包扣除的总和
    private var computedWalletBalance: Double {
        let walletUsed = orders.reduce(0) { $0 + $1.walletDeducted }
        return max(0, computedTotalRecharged + computedTotalBonus - walletUsed)
    }
    /// 累计赠送 = 所有充值记录中赠送金额之和
    private var computedTotalBonus: Double { recharges.reduce(0) { $0 + $1.bonus } }
    /// 累计消费 = 累计充值 + 所有订单中非钱包实付部分（补足部分或全额现金/微信等）
    private var computedTotalSpent: Double {
        let orderTopUp = orders.reduce(0) { $0 + max(0, $1.totalAmount - $1.walletDeducted) }
        return computedTotalRecharged + orderTopUp
    }

    private func recordDisplayText(_ r: NailServiceRecord) -> String {
        let names = r.serviceItemIds.compactMap { sid -> String? in
            guard let s = serviceMap[sid] else { return nil }
            return fullServiceName(for: s.id, serviceMap: serviceMap, categoryMap: categoryMap)
        }
        let text = names.isEmpty ? "无项目" : names.joined(separator: " · ")
        let total = r.serviceItemIds.compactMap { serviceMap[$0]?.price }.reduce(0, +)
        return text + "  ¥\(String(format: "%.0f", total))"
    }

    private func orderDisplayText(_ o: Order) -> String {
        let names = o.lineItems.map { $0.name }
        let text = names.isEmpty ? "无明细" : names.joined(separator: " · ")
        return text + "  ¥\(String(format: "%.0f", o.totalAmount))"
    }

    private func rechargeDisplayText(_ r: RechargeRecord) -> String {
        let method = (r.paymentMethod ?? "未知支付") + "充值"
        var text = method + "  ¥\(String(format: "%.0f", r.amount))"
        if r.bonus > 0 {
            text += " (赠¥\(String(format: "%.0f", r.bonus)))"
        }
        return text
    }

    private func deleteOrder(_ o: Order) {
        if let rid = o.recordId, let r = allRecords.first(where: { $0.id == rid }) {
            r.isPaid = false
        }
        // 同步删除由该订单生成的补睫提醒
        for reminder in allLashReminders.filter({ $0.orderId == o.id }) {
            context.delete(reminder)
        }
        context.delete(o)
    }

    private func deleteRecharge(_ r: RechargeRecord) {
        // 计算删除后的累计充值，用于会员等级降级判定
        let afterRecharged = computedTotalRecharged - r.amount
        // 降级判定
        if afterRecharged < 5000, customer.membershipLevel == "金卡" {
            customer.membershipLevel = "银卡"
        }
        if afterRecharged <= 0, customer.membershipLevel != "普通" {
            customer.membershipLevel = "普通"
        }
        customer.updatedAt = Date()
        context.delete(r)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("客户详情").font(.headline)
                    Text(customer.name + " · " + customer.phone)
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
                Section("基本信息") {
                    LabeledContent("姓名", value: customer.name)
                    LabeledContent("电话", value: customer.phone)
                    if let g = customer.gender { LabeledContent("性别", value: g) }
                    if let w = customer.wechat { LabeledContent("微信", value: w) }
                    LabeledContent("会员等级") {
                        Text(customer.membershipLevel)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(membershipColor(customer.membershipLevel), in: Capsule())
                    }
                    LabeledContent("钱包余额", value: "¥" + String(format: "%.0f", computedWalletBalance))
                        .foregroundStyle(computedWalletBalance > 0 ? Color.orange : .secondary)
                    LabeledContent("累计充值", value: "¥" + String(format: "%.0f", computedTotalRecharged))
                    LabeledContent("累计消费", value: "¥" + String(format: "%.0f", computedTotalSpent))
                    if let d = latestOrderDate {
                        LabeledContent("最后到店", value: d.cnDateTime)
                    } else {
                        LabeledContent("最后到店", value: "从未到店")
                    }
                }
                Section("服务记录（\(records.count)）") {
                    if records.isEmpty {
                        Text("暂无记录").foregroundStyle(.secondary).font(.caption)
                    } else {
                        ForEach(Array(records.prefix(10))) { r in
                            Button { selectedRecord = r } label: {
                                HStack {
                                    Text(r.serviceDate.cnDateTime)
                                    Spacer()
                                    Text("\(r.serviceItemIds.count) 个项目").foregroundStyle(.secondary).font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                        if records.count > 10 {
                            Button { showingRecordCalendar = true } label: {
                                HStack {
                                    Spacer()
                                    Text("查看更多（\(records.count) 条）")
                                    Image(systemName: "chevron.right")
                                }
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                    }
                }
                Section("消费记录（\(orders.count)）") {
                    if orders.isEmpty {
                        Text("暂无订单").foregroundStyle(.secondary).font(.caption)
                    } else {
                        ForEach(Array(orders.prefix(10))) { o in
                            Button { selectedOrder = o } label: {
                                HStack {
                                    Text(o.paidAt.cnDateTime)
                                    Spacer()
                                    Text("¥" + String(format: "%.0f", o.totalAmount)).foregroundStyle(.secondary)
                                    if let m = o.paymentMethod { Text(m).foregroundStyle(.secondary).font(.caption) }
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                        if orders.count > 10 {
                            Button { showingOrderCalendar = true } label: {
                                HStack {
                                    Spacer()
                                    Text("查看更多（\(orders.count) 条）")
                                    Image(systemName: "chevron.right")
                                }
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                    }
                }
                Section("充值记录（\(recharges.count)）") {
                    if recharges.isEmpty {
                        Text("暂无充值记录").foregroundStyle(.secondary).font(.caption)
                    } else {
                        ForEach(Array(recharges.prefix(10))) { r in
                            HStack {
                                Text(r.rechargeAt.cnDateTime)
                                Spacer()
                                Text("+" + String(format: "%.0f", r.amount))
                                    .foregroundStyle(Color.orange).fontWeight(.semibold)
                                if r.bonus > 0 {
                                    Text("(赠¥" + String(format: "%.0f", r.bonus) + ")")
                                        .foregroundStyle(Color.green).font(.caption)
                                }
                                if let m = r.paymentMethod { Text(m).foregroundStyle(.secondary).font(.caption) }
                                // 仅最新一条充值记录显示删除按钮，逐条倒叙删除
                                if r.id == recharges.first?.id {
                                    Button {
                                        rechargeToDelete = r
                                        deletePassword = ""
                                        passwordError = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.red)
                                            .font(.system(size: 16))
                                    }
                                    .buttonStyle(.plain)
                                    .help("删除此充值记录")
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        if recharges.count > 10 {
                            Button { showingRechargeCalendar = true } label: {
                                HStack {
                                    Spacer()
                                    Text("查看更多（\(recharges.count) 条）")
                                    Image(systemName: "chevron.right")
                                }
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("编辑") { showingEdit = true }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 480, idealHeight: 600, maxHeight: 720)
        .sheet(isPresented: $showingEdit) {
            CustomerFormView(customer: customer) { _ in }
            
        }
        .sheet(isPresented: Binding(get: { selectedRecord != nil }, set: { if !$0 { selectedRecord = nil } })) {
            if let record = selectedRecord {
                ServiceRecordDetailView(record: record) { _ in }
            }
            
        }
        .sheet(isPresented: Binding(get: { selectedOrder != nil }, set: { if !$0 { selectedOrder = nil } })) {
            if let order = selectedOrder {
                OrderDetailSheet(
                    order: order,
                    customerName: customer.name,
                    technicianName: order.technicianId.flatMap { technicianMap[$0]?.name } ?? "",
                    onDelete: {
                        selectedOrder = nil
                        deleteOrder(order)
                    }
                )
            }
            
        }
        .sheet(isPresented: $showingRecordCalendar) {
            RecordCalendarView(
                title: "服务记录",
                records: records,
                dateKey: { $0.serviceDate },
                rowDisplayText: { self.recordDisplayText($0) },
                onSelectRecord: { r in
                    showingRecordCalendar = false
                    selectedRecord = r
                }
            )
            
        }
        .sheet(isPresented: $showingOrderCalendar) {
            RecordCalendarView(
                title: "消费记录",
                records: orders,
                dateKey: { $0.paidAt },
                rowDisplayText: { self.orderDisplayText($0) },
                onSelectRecord: { o in
                    showingOrderCalendar = false
                    selectedOrder = o
                }
            )
            
        }
        .sheet(isPresented: $showingRechargeCalendar) {
            RecordCalendarView(
                title: "充值记录",
                records: recharges,
                dateKey: { $0.rechargeAt },
                rowDisplayText: { self.rechargeDisplayText($0) },
                onSelectRecord: { _ in showingRechargeCalendar = false }
            )
            
        }
        .alert("确认删除充值记录？", isPresented: .init(
            get: { rechargeToDelete != nil },
            set: { if !$0 { rechargeToDelete = nil; deletePassword = ""; passwordError = nil } }
        )) {
            SecureField("密码", text: $deletePassword)
            Button("删除", role: .destructive) {
                if SecurityManager.shared.verifyPassword(deletePassword) {
                    guard let r = rechargeToDelete else { return }
                    // 检查余额是否足够扣除（充值+赠送），防止余额变负数
                    if computedWalletBalance - r.amount - r.bonus < 0 {
                        rechargeToDelete = nil
                        deletePassword = ""
                        passwordError = nil
                        showingDeleteError = true
                        return
                    }
                    deleteRecharge(r)
                    rechargeToDelete = nil
                    deletePassword = ""
                    passwordError = nil
                } else {
                    passwordError = "密码错误"
                }
            }
            Button("取消", role: .cancel) {
                rechargeToDelete = nil
                deletePassword = ""
                passwordError = nil
            }
        } message: {
            if let err = passwordError {
                Text(err)
            } else {
                Text("删除后该金额将从店铺收入、客户累计消费和钱包余额中扣除。此操作不可撤销。")
            }
        }
        .alert("删除失败", isPresented: $showingDeleteError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("余额不足，不支持删除该充值记录。")
        }
    }
}

// MARK: - 客户表单
struct CustomerFormView: View {
    @Environment(\.dismiss) private var dismiss
    var customer: Customer?
    var onSave: (Customer) -> Void

    @State private var name = ""
    @State private var phone = ""
    @State private var gender = ""
    @State private var wechat = ""
    @State private var membershipLevel = "普通"
    @State private var isActive = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("姓名", text: $name)
                TextField("电话", text: $phone)
                Picker("性别", selection: $gender) {
                    Text("未填").tag(""); Text("女").tag("女"); Text("男").tag("男")
                }
                TextField("微信", text: $wechat)
                Picker("会员等级", selection: $membershipLevel) {
                    Text("普通").tag("普通"); Text("银卡").tag("银卡"); Text("金卡").tag("金卡")
                }
                Toggle("启用", isOn: $isActive)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || phone.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 420, minHeight: 360, idealHeight: 420, maxHeight: 600)
        .onAppear { load() }
    }

    private func load() {
        guard let c = customer else { return }
        name = c.name; phone = c.phone; gender = c.gender ?? ""
        wechat = c.wechat ?? ""; membershipLevel = c.membershipLevel; isActive = c.isActive
    }

    private func save() {
        if let c = customer {
            c.name = name; c.phone = phone
            c.gender = gender.isEmpty ? nil : gender
            c.wechat = wechat.isEmpty ? nil : wechat
            c.membershipLevel = membershipLevel
            c.isActive = isActive
            c.updatedAt = Date()
            onSave(c)
        } else {
            let c = Customer(name: name, phone: phone,
                             gender: gender.isEmpty ? nil : gender,
                             wechat: wechat.isEmpty ? nil : wechat,
                             membershipLevel: membershipLevel, isActive: isActive)
            onSave(c)
        }
        dismiss()
    }
}

// MARK: - 年历视图（服务记录/消费记录通用）
struct RecordCalendarView<T: Identifiable & AnyObject>: View {
    let title: String
    let records: [T]
    let dateKey: (T) -> Date
    let rowDisplayText: (T) -> String
    let onSelectRecord: (T) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var displayYear = Calendar.current.component(.year, from: Date())
    @State private var multiSelectDay: DayRecords<T>?
    private let calendar = Calendar.current

    // 按"年-月-日"分组
    private var dateMap: [Date: [T]] {
        var map: [Date: [T]] = [:]
        for r in records {
            let day = calendar.startOfDay(for: dateKey(r))
            map[day, default: []].append(r)
        }
        return map
    }

    private var yearRange: ClosedRange<Int> {
        let years = records.map { calendar.component(.year, from: dateKey($0)) }
        let minY = years.min() ?? displayYear
        let maxY = years.max() ?? displayYear
        return min(minY, displayYear)...max(maxY, displayYear)
    }

    private let monthNames = ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"]
    private let weekDays = ["日","一","二","三","四","五","六"]

    private func daysInMonth(_ month: Int) -> [Date?] {
        let comps = DateComponents(year: displayYear, month: month, day: 1)
        guard let firstDay = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: firstDay) else { return [] }
        let weekday = calendar.component(.weekday, from: firstDay) - 1
        var days: [Date?] = Array(repeating: nil, count: weekday)
        for day in range {
            if let d = calendar.date(byAdding: .day, value: day - 1, to: firstDay) {
                days.append(d)
            }
        }
        return days
    }

    private func recordCountOnDay(_ day: Date) -> Int {
        dateMap[day]?.count ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            HStack {
                Text(title + " · \(displayYear)年")
                    .font(.headline)
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
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            // 年份切换
            HStack(spacing: 16) {
                Button {
                    displayYear -= 1
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .frame(width: 36, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(displayYear <= yearRange.lowerBound)

                Text("\(displayYear)年")
                    .font(.title2.weight(.semibold))
                    .frame(width: 100)

                Button {
                    displayYear += 1
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .frame(width: 36, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(displayYear >= yearRange.upperBound)
            }
            .padding(.vertical, 10)

            // 12 个月日历
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(1...12, id: \.self) { month in
                        VStack(spacing: 4) {
                            Text(monthNames[month - 1])
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 0) {
                                ForEach(weekDays, id: \.self) { w in
                                    Text(w)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity)
                                }
                            }

                            let days = daysInMonth(month)
                            let rows = Int(ceil(Double(days.count) / 7.0))
                            ForEach(0..<rows, id: \.self) { row in
                                HStack(spacing: 0) {
                                    ForEach(0..<7, id: \.self) { col in
                                        let idx = row * 7 + col
                                        if idx < days.count, let day = days[idx] {
                                            let count = recordCountOnDay(day)
                                            let dayNum = calendar.component(.day, from: day)
                                            Button {
                                                if count > 0 {
                                                    let recs = dateMap[day]!
                                                    if recs.count == 1 {
                                                        onSelectRecord(recs[0])
                                                    } else {
                                                        multiSelectDay = DayRecords(date: day, records: recs)
                                                    }
                                                }
                                            } label: {
                                                ZStack {
                                                    if count > 0 {
                                                        Circle()
                                                            .fill(Color.green.opacity(0.2))
                                                            .frame(width: 22, height: 22)
                                                    }
                                                    Text("\(dayNum)")
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(count > 0 ? Color.green : .primary)
                                                    if count > 1 {
                                                        Text("\(count)")
                                                            .font(.system(size: 7, weight: .bold))
                                                            .foregroundStyle(.white)
                                                            .padding(.horizontal, 3)
                                                            .background(Capsule().fill(Color.green))
                                                            .offset(x: 8, y: -8)
                                                    }
                                                }
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 20)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(count == 0)
                                        } else {
                                            Color.clear
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 20)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 900, minHeight: 500, idealHeight: 700, maxHeight: 800)
        .sheet(isPresented: Binding(get: { multiSelectDay != nil }, set: { if !$0 { multiSelectDay = nil } })) {
            if let dayRecs = multiSelectDay {
                MultiRecordPickerView(
                    title: title,
                    date: dayRecs.date,
                    records: dayRecs.records,
                    rowDisplayText: rowDisplayText,
                    onSelectRecord: { r in
                        multiSelectDay = nil
                        onSelectRecord(r)
                    }
                )
            }
            
        }
    }
}

// 同一天多条记录的包装器
struct DayRecords<T: Identifiable>: Identifiable {
    let id = UUID()
    let date: Date
    let records: [T]
}

// 同一天多条记录的选择列表
struct MultiRecordPickerView<T: Identifiable>: View {
    let title: String
    let date: Date
    let records: [T]
    let rowDisplayText: (T) -> String
    let onSelectRecord: (T) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("选择\(title)").font(.headline)
                    Text(date, format: .dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))
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
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            List(records) { r in
                Button {
                    onSelectRecord(r)
                } label: {
                    HStack {
                        Text(rowDisplayText(r))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 400, minHeight: 320, idealHeight: 400, maxHeight: 600)
    }
}

// MARK: - 客户充值辅助（CustomerView 内的 perform 方法）

private extension CustomerView {
    /// 执行充值：仅生成 RechargeRecord 记录，累计消费/余额等由动态计算得出
    /// 赠送金额（bonus）加到余额里，但不计入累计充值和累计消费
    func performRecharge(customer: Customer, amount: Double, bonus: Double,
                         paymentMethod: String?, note: String?, rechargeAt: Date) {
        guard amount > 0 else { return }
        customer.updatedAt = Date()

        // 动态计算充值后的总额（当前已有记录 + 本次新增）
        let currentRecharged = allRecharges
            .filter { $0.customerId == customer.id }
            .reduce(0) { $0 + $1.amount } + amount

        // 升级规则：首次充值 → 银卡；累计充值 ≥5000 → 金卡
        switch customer.membershipLevel {
        case "普通": customer.membershipLevel = "银卡"
        case "银卡": if currentRecharged >= 5000 { customer.membershipLevel = "金卡" }
        default: break
        }

        // 生成充值记录（计入店铺收入）
        let rec = RechargeRecord(
            customerId: customer.id,
            amount: amount,
            paymentMethod: paymentMethod,
            bonus: bonus,
            operatorNote: note,
            rechargeAt: rechargeAt
        )
        context.insert(rec)
    }
}

// MARK: - 充值表单 Sheet

private struct RechargeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let customers: [Customer]
    var onConfirm: (Customer, Double, Double, String?, String?, Date) -> Void
    @Query(sort: \RechargeRecord.rechargeAt, order: .reverse) private var allRecharges: [RechargeRecord]
    @Query private var allOrders: [Order]

    @State private var selectedCustomerId: UUID?
    @State private var amountText: String = ""
    @State private var bonusText: String = ""
    @State private var paymentMethod: String = "微信"
    @State private var rechargeDate: Date = Date()
    @State private var note: String = ""

    private var selectedCustomer: Customer? {
        guard let id = selectedCustomerId else { return nil }
        return customers.first(where: { $0.id == id })
    }

    private var amountValue: Double {
        Double(amountText.filter { "0123456789.".contains($0) }) ?? 0
    }

    private var bonusValue: Double {
        Double(bonusText.filter { "0123456789.".contains($0) }) ?? 0
    }

    private var canSubmit: Bool {
        selectedCustomer != nil && amountValue > 0
    }

    /// 动态计算：当前选中客户的钱包余额（累计充值 + 累计赠送 - 所有订单钱包扣除总和）
    private var dynamicWalletBalance: Double {
        guard let id = selectedCustomerId else { return 0 }
        let recharged = allRecharges.filter { $0.customerId == id }.reduce(0) { $0 + $1.amount }
        let bonus = allRecharges.filter { $0.customerId == id }.reduce(0) { $0 + $1.bonus }
        let used = allOrders.filter { $0.customerId == id }.reduce(0) { $0 + $1.walletDeducted }
        return max(0, recharged + bonus - used)
    }

    /// 动态计算：当前选中客户的累计赠送金额
    private var dynamicTotalBonus: Double {
        guard let id = selectedCustomerId else { return 0 }
        return allRecharges.filter { $0.customerId == id }.reduce(0) { $0 + $1.bonus }
    }

    /// 动态计算：当前选中客户的累计充值总额
    private var dynamicTotalRecharged: Double {
        guard let id = selectedCustomerId else { return 0 }
        return allRecharges.filter { $0.customerId == id }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("客户充值").font(.headline)
                    Text("充值金额将计入客人累计消费与店铺收入")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).contentShape(Rectangle())
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            Form {
                Section("选择客户") {
                    CustomerField(customerId: $selectedCustomerId, customers: customers)
                    .labelsHidden()
                    if let c = selectedCustomer {
                        HStack(spacing: 12) {
                            Text(c.membershipLevel)
                                .font(.caption).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(membershipColor(c.membershipLevel), in: Capsule())
                            LabeledContent("当前钱包余额",
                                           value: "¥" + String(format: "%.0f", dynamicWalletBalance))
                            Spacer()
                            LabeledContent("累计充值",
                                           value: "¥" + String(format: "%.0f", dynamicTotalRecharged))
                        }
                        .font(.caption)
                    }
                }

                Section("充值信息") {
                    LabeledContent("充值金额") {
                        TextField("请输入金额", text: $amountText,
                                  prompt: Text("0.00"))
                        .frame(maxWidth: 180, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("赠送金额") {
                        TextField("选填", text: $bonusText,
                                  prompt: Text("0.00"))
                        .frame(maxWidth: 180, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    }
                    Picker("支付方式", selection: $paymentMethod) {
                        Text("微信").tag("微信"); Text("支付宝").tag("支付宝")
                        Text("现金").tag("现金"); Text("刷卡").tag("刷卡")
                    }
                    LabeledContent("充值时间") {
                        TechCalendarPicker("", selection: $rechargeDate,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                    LabeledContent("备注") {
                        TextField("选填", text: $note, axis: .vertical)
                            .lineLimit(1...3)
                            .frame(minWidth: 200, alignment: .trailing)
                    }
                }

                if let c = selectedCustomer, amountValue > 0 {
                    Section("充值结果预览") {
                        if bonusValue > 0 {
                            HStack {
                                Text("充值+赠送").foregroundStyle(.secondary)
                                Spacer()
                                Text("¥\(String(format: "%.0f", amountValue)) + ¥\(String(format: "%.0f", bonusValue))")
                                    .font(.subheadline)
                            }
                        }
                        HStack {
                            Text("充值后钱包余额").foregroundStyle(.secondary)
                            Spacer()
                            Text("¥\(String(format: "%.0f", dynamicWalletBalance + amountValue + bonusValue))")
                                .font(.headline)
                        }
                        HStack {
                            Text("新会员等级").foregroundStyle(.secondary)
                            Spacer()
                            Text(targetLevel(c: c, amount: amountValue))
                                .font(.caption).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(membershipColor(targetLevel(c: c, amount: amountValue)),
                                            in: Capsule())
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction).buttonStyle(.bordered)
                Button("确认充值") {
                    guard let c = selectedCustomer, amountValue > 0 else { return }
                    let method = paymentMethod.isEmpty ? nil : paymentMethod
                    let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    onConfirm(c, amountValue, bonusValue, method, n.isEmpty ? nil : n, rechargeDate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 480, idealHeight: 560, maxHeight: 700)
    }

    /// 预览充值后的会员等级
    private func targetLevel(c: Customer, amount: Double) -> String {
        let after = dynamicTotalRecharged + amount
        switch c.membershipLevel {
        case "金卡": return "金卡"
        case "银卡": return after >= 5000 ? "金卡" : "银卡"
        default: return after >= 5000 ? "金卡" : "银卡"
        }
    }
}
