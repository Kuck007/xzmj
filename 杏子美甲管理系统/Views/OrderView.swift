//
//  OrderView.swift
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

// MARK: - 悬停高亮行（霓虹描边 + 发光，沿用侧边栏动画节奏：0.02s 亮 / 0.6s 灭）
struct HoverHighlightRow<Content: View>: View {
    let content: Content
    @State private var isHovering = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.brand.opacity(isHovering ? 0.13 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.brand.opacity(isHovering ? 0.55 : 0), lineWidth: isHovering ? 1 : 0)
            )
            .shadow(color: isHovering ? Color.brand.opacity(0.18) : .clear, radius: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: hovering ? 0.02 : 0.6)) {
                    isHovering = hovering
                }
            }
    }
}

// MARK: - 订单行
struct OrderRow: View {
    let order: Order
    let customerName: String
    let technicianName: String
    var onTap: () -> Void

    private var methodColor: Color {
        let method = order.paymentMethod ?? ""
        if method.hasPrefix("会员钱包") { return Color(red: 1.0, green: 0.55, blue: 0.0) }  // 橙色
        switch method {
        case "微信": return .green
        case "支付宝": return .blue
        case "现金": return .orange
        case "刷卡": return .purple
        default: return .secondary
        }
    }

    var body: some View {
        HoverHighlightRow {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(customerName).font(.headline).foregroundStyle(.primary)
                    if !technicianName.isEmpty {
                        Text("· \(technicianName)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("¥" + String(format: "%.0f", order.totalAmount))
                        .font(.headline).foregroundStyle(Color.accentColor)
                }
                HStack {
                    Text(order.paidAt.cnDateTime)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let m = order.paymentMethod {
                        Text(m)
                            .font(.caption)
                            .foregroundStyle(methodColor)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(methodColor.opacity(0.1), in: Capsule())
                    }
                }
                let names = order.lineItems.map { $0.name }
                if !names.isEmpty {
                    Text(names.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - 订单视图
struct OrderView: View {
    @Query(sort: \Order.paidAt, order: .reverse) private var orders: [Order]
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @Query private var records: [NailServiceRecord]
    @Query private var allLashReminders: [LashReminder]
    @Environment(\.modelContext) private var context
    @State private var showingAdd = false
    @State private var selectedOrder: Order?
    @State private var capturedPrefill: NailServiceRecord?
    // 跨模块跳转：从服务记录详情"跳转收银"时传入
    var prefillRecord: NailServiceRecord?
    var onPrefillConsumed: (() -> Void)?

    // 分页状态
    @State private var currentPage = 1
    private let pageSize = 10

    private var customerMap: [UUID: Customer] { Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) }) }
    private var technicianMap: [UUID: Technician] { Dictionary(uniqueKeysWithValues: technicians.map { ($0.id, $0) }) }

    // 分页计算
    private var totalPages: Int {
        max(1, Int(ceil(Double(orders.count) / Double(pageSize))))
    }

    private var pagedOrders: [Order] {
        let start = (currentPage - 1) * pageSize
        let end = min(start + pageSize, orders.count)
        guard start < end else { return [] }
        return Array(orders[start..<end])
    }

    private func deleteOrder(_ o: Order) {
        // 如果订单关联了服务记录，则恢复为未付款
        if let rid = o.recordId, let r = records.first(where: { $0.id == rid }) {
            r.isPaid = false
        }
        // 同步删除由该订单生成的补睫提醒
        for reminder in allLashReminders.filter({ $0.orderId == o.id }) {
            context.delete(reminder)
        }
        context.delete(o)
    }

    var body: some View {
        // macOS NavigationSplitView 的 detail column 会自动处理 .navigationTitle/.toolbar/.searchable，NavigationStack 在 detail 里是冗余的，且会吃掉 sheet 首次 present 的进入动画
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Group {
                    if orders.isEmpty {
                        EmptyStateView(
                            systemImage: "creditcard",
                            title: "暂无订单",
                            message: "点击右上角「收银」开始收银结账"
                        )
                    } else {
                        List {
                            ForEach(pagedOrders) { o in
                                OrderRow(
                                    order: o,
                                    customerName: customerMap[o.customerId]?.name ?? "未知客户",
                                    technicianName: o.technicianId.flatMap { technicianMap[$0]?.name } ?? ""
                                ) {
                                    selectedOrder = o
                                }
                            }
                        }
                        .listStyle(.inset)
                    }
                }

                // 分页控件
                if !orders.isEmpty {
                    Divider()
                    PaginationBar(
                        currentPage: $currentPage,
                        totalPages: totalPages,
                        totalItems: orders.count
                    )
                }
            }
            .navigationTitle("收银结账")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Text("收银")
                    }
                    .buttonStyle(BrandPrimaryButtonStyle())
                    .disabled(customers.isEmpty)
                }
            }
            .sheet(isPresented: $showingAdd) {
                OrderFormView(prefillRecord: capturedPrefill) { context.insert($0) }
                    
            }
            .sheet(isPresented: Binding(get: { selectedOrder != nil }, set: { if !$0 { selectedOrder = nil } })) {
                if let order = selectedOrder {
                    OrderDetailSheet(
                        order: order,
                        customerName: customerMap[order.customerId]?.name ?? "未知客户",
                        technicianName: order.technicianId.flatMap { technicianMap[$0]?.name } ?? "",
                        onDelete: {
                            selectedOrder = nil
                            deleteOrder(order)
                        }
                    )
                }
                
            }
        }
        .onAppear {
            // 接收到预填记录时捕获并自动打开表单（消费后清除，避免重复触发）
            if let rec = prefillRecord {
                capturedPrefill = rec
                showingAdd = true
                onPrefillConsumed?()
            }
        }
    }
}

struct OrderFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @Query private var records: [NailServiceRecord]
    @Query private var services: [ServiceItem]
    @Query private var categories: [ServiceCategory]
    @Query private var lashReminders: [LashReminder]
    @Query private var allRecharges: [RechargeRecord]
    @Query private var allOrders: [Order]
    var prefillRecord: NailServiceRecord?
    var onSave: (Order) -> Void

    @State private var customerId: UUID?
    @State private var technicianId: UUID?
    @State private var recordId: UUID?
    @State private var paymentMethod = "微信"
    /// 余额不足时的「补足部分」支付方式（钱包之外再付）
    @State private var topUpPaymentMethod = "微信"
    @State private var paidAt = Date()
    @State private var notes = ""
    @State private var manualItems: [OrderLineItem] = []
    @State private var didPrefill = false
    @State private var showingServicePicker = false
    // 快速新增客户
    @State private var quickName = ""
    @State private var quickPhone = ""
    @State private var showingQuickAddConfirm = false
    // 价格调整
    @State private var discountAmount: Double = 0
    @State private var discountInput: String = "0"

    private var serviceMap: [UUID: ServiceItem] { Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) }) }
    private var categoryMap: [UUID: ServiceCategory] { Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) }) }
    /// 动态计算：当前选中客户的钱包余额（累计充值 + 累计赠送 - 所有订单钱包扣除总和）
    private var currentWallet: Double {
        guard let cid = customerId else { return 0 }
        let recharged = allRecharges.filter { $0.customerId == cid }.reduce(0) { $0 + $1.amount }
        let bonus = allRecharges.filter { $0.customerId == cid }.reduce(0) { $0 + $1.bonus }
        let used = allOrders.filter { $0.customerId == cid }.reduce(0) { $0 + $1.walletDeducted }
        return max(0, recharged + bonus - used)
    }
    /// 会员钱包实际抵扣金额（finalTotal 内优先用钱包）
    private var walletDeducted: Double {
        guard paymentMethod == "会员钱包" else { return 0 }
        return min(currentWallet, finalTotal)
    }
    /// 钱包不足时用户需要再实付的金额（补足部分）
    private var topUpAmount: Double {
        max(0, finalTotal - walletDeducted)
    }
    /// 最终展示的「支付方式」字符串（写入 Order.paymentMethod）
    private var resolvedPaymentMethod: String {
        if paymentMethod != "会员钱包" { return paymentMethod }
        if topUpAmount <= 0 { return "会员钱包" }
        return "会员钱包+" + topUpPaymentMethod
    }

    private var customerRecords: [NailServiceRecord] {
        guard let cid = customerId else { return [] }
        return records.filter { $0.customerId == cid && !$0.isPaid }.sorted { $0.serviceDate > $1.serviceDate }
    }

    private var lineItems: [OrderLineItem] {
        if let rid = recordId, let r = records.first(where: { $0.id == rid }) {
            return r.serviceItemIds.compactMap { sid in
                guard let s = serviceMap[sid] else { return nil }
                let fullName = fullServiceName(for: s.id, serviceMap: serviceMap, categoryMap: categoryMap)
                return OrderLineItem(serviceItemId: s.id, name: fullName, price: s.price)
            }
        }
        return manualItems
    }
    private var total: Double { lineItems.reduce(0) { $0 + $1.price } }
    private var finalTotal: Double { max(0, total - discountAmount) }

    // 构造关联记录的显示文案："时间 · 项目1/项目2"
    private func recordLabel(_ r: NailServiceRecord) -> String {
        let time = r.serviceDate.cnDateTime
        let names = r.serviceItemIds.compactMap { sid -> String? in
            guard let s = serviceMap[sid] else { return nil }
            return fullServiceName(for: s.id, serviceMap: serviceMap, categoryMap: categoryMap)
        }
        let nameText = names.isEmpty ? "无项目" : names.joined(separator: "/")
        return "\(time) · \(nameText)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("客户") {
                    CustomerField(customerId: $customerId, customers: customers)
                }
                .onChange(of: customerId) { _, _ in
                    if let rid = recordId, let r = records.first(where: { $0.id == rid }) {
                        if r.customerId != customerId { recordId = nil; manualItems = [] }
                    } else {
                        recordId = nil; manualItems = []
                    }
                    // 有余额时自动建议用会员钱包，无余额时重置为微信让用户自选
                    if currentWallet > 0 { paymentMethod = "会员钱包" }
                    else { paymentMethod = "微信" }
                }
                // 客户钱包余额实时提示
                if let cid = customerId, let c = customers.first(where: { $0.id == cid }), currentWallet > 0 {
                    HStack(spacing: 12) {
                        Text(c.membershipLevel)
                            .font(.caption).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(membershipColor(c.membershipLevel), in: Capsule())
                        LabeledContent("钱包余额",
                                       value: "¥" + String(format: "%.0f", currentWallet))
                        .font(.caption).foregroundStyle(currentWallet > 0 ? Color.orange : .secondary)
                    }
                }

                Picker("技师", selection: $technicianId) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(technicians) { Text($0.name).tag(Optional($0.id)) }
                }

                if customerId == nil {
                    Section("快速新增客户") {
                        HStack(spacing: 12) {
                            TextField("姓名", text: $quickName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                            TextField("电话", text: $quickPhone)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                            Button {
                                showingQuickAddConfirm = true
                            } label: {
                                Text("确认")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(quickName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }

                Picker("关联服务记录", selection: $recordId) {
                    Text("（不关联）").tag(UUID?.none)
                    ForEach(customerRecords) { r in
                        Text(recordLabel(r)).tag(Optional(r.id))
                    }
                }
                .onChange(of: recordId) { _, _ in
                    manualItems = []
                    // 选中关联记录时自动填充技师
                    if let rid = recordId, let r = records.first(where: { $0.id == rid }) {
                        technicianId = r.technicianId
                    }
                }

                LabeledContent("付款时间") {
                    TechCalendarPicker("", selection: $paidAt)
                }
                Picker("支付方式", selection: $paymentMethod) {
                    Text("微信").tag("微信"); Text("支付宝").tag("支付宝")
                    Text("现金").tag("现金"); Text("刷卡").tag("刷卡")
                    Text("会员钱包").tag("会员钱包")
                }
                // 选「会员钱包」且余额不足时，需要再选一种补足支付方式
                if paymentMethod == "会员钱包", walletDeducted < finalTotal, finalTotal > 0 {
                    Picker("补足部分支付方式", selection: $topUpPaymentMethod) {
                        Text("微信").tag("微信"); Text("支付宝").tag("支付宝")
                        Text("现金").tag("现金"); Text("刷卡").tag("刷卡")
                    }
                }

                Section("结账明细") {
                    if lineItems.isEmpty {
                        Text("暂无项目，可选择关联记录或「添加项目」").foregroundStyle(.secondary).font(.caption)
                    }
                    ForEach(lineItems) { item in
                        HoverHighlightRow {
                            HStack { Text(item.name); Spacer(); Text("¥" + String(format: "%.0f", item.price)).foregroundStyle(.secondary) }
                        }
                    }
                    if recordId == nil {
                        Button("添加项目") { showingServicePicker = true }
                            .buttonStyle(.bordered)
                    }
                }
                Section("价格调整") {
                    HStack {
                        Text("原价合计")
                        Spacer()
                        Text("¥" + String(format: "%.0f", total))
                            .foregroundStyle(.secondary)
                    }
                    if walletDeducted > 0 {
                        HStack {
                            Text("会员钱包抵扣")
                            Spacer()
                            Text("-¥" + String(format: "%.0f", walletDeducted))
                                .foregroundStyle(Color.orange)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("优惠金额")
                        Spacer()
                        Button {
                            discountAmount = max(0, discountAmount - 1)
                            discountInput = String(format: "%.0f", discountAmount)
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                Image(systemName: "minus")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .frame(width: 24, height: 20)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(discountAmount <= 0)

                        TextField("", text: $discountInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(width: 56, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                            .multilineTextAlignment(.center)
                            .onChange(of: discountInput) { _, newVal in
                                if let v = Double(newVal), v >= 0 {
                                    discountAmount = v
                                } else {
                                    discountAmount = 0
                                }
                            }

                        Button {
                            discountAmount += 1
                            discountInput = String(format: "%.0f", discountAmount)
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .frame(width: 24, height: 20)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(discountAmount >= total)

                        Button {
                            discountAmount = 0
                            discountInput = "0"
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                Text("重置")
                                    .font(.system(size: 12))
                            }
                            .frame(width: 40, height: 20)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(discountAmount == 0)
                    }
                    if discountAmount > 0 {
                        HStack {
                            Text("优惠后小计")
                            Spacer()
                            Text("-¥" + String(format: "%.0f", discountAmount))
                                .foregroundStyle(.orange)
                        }
                    }
                    if paymentMethod == "会员钱包", topUpAmount > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack {
                                Text("会员钱包抵扣")
                                Spacer()
                                Text("-¥" + String(format: "%.0f", walletDeducted))
                                    .foregroundStyle(Color.orange)
                            }
                            HStack {
                                Text("需补足（\(topUpPaymentMethod)）")
                                Spacer()
                                Text("¥" + String(format: "%.0f", topUpAmount))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    HStack {
                        Text("实收合计")
                            .font(.headline)
                        Spacer()
                        Text("¥" + String(format: "%.0f", finalTotal))
                            .font(.title3.bold())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                TextField("备注", text: $notes, axis: .vertical).lineLimit(2...4)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("收银") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(customerId == nil
                              || technicianId == nil
                              || lineItems.isEmpty
                              || (paymentMethod == "会员钱包" && currentWallet <= 0))
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 480, idealHeight: 560, maxHeight: 750)
        .sheet(isPresented: $showingServicePicker) {
            ServicePickerSheet(
                services: services,
                categories: categories,
                serviceMap: serviceMap,
                categoryMap: categoryMap,
                existingIds: Set(manualItems.map { $0.serviceItemId })
            ) { selected in
                // 合并已选与新增，去重
                var dict: [UUID: OrderLineItem] = [:]
                for m in manualItems { dict[m.serviceItemId] = m }
                for s in selected {
                    guard let item = serviceMap[s.id] else { continue }
                    let fullName = fullServiceName(for: item.id, serviceMap: serviceMap, categoryMap: categoryMap)
                    dict[item.id] = OrderLineItem(serviceItemId: item.id, name: fullName, price: item.price)
                }
                manualItems = dict.values.sorted { $0.name < $1.name }
            }
            
        }
        .alert("确认新增客户？", isPresented: $showingQuickAddConfirm) {
            Button("取消", role: .cancel) { }
            Button("确认") {
                createQuickCustomer()
            }
        } message: {
            Text("将创建客户「\(quickName)」\(quickPhone.isEmpty ? "" : " · \(quickPhone)")")
        }
        .onAppear { applyPrefillIfNeeded() }
        .onChange(of: total) { _, newTotal in
            if discountAmount > newTotal {
                discountAmount = 0
                discountInput = "0"
            }
        }
    }

    private func createQuickCustomer() {
        let name = quickName.trimmingCharacters(in: .whitespaces)
        let phone = quickPhone.trimmingCharacters(in: .whitespaces)
        let customer = Customer(name: name, phone: phone)
        context.insert(customer)
        customerId = customer.id
        quickName = ""
        quickPhone = ""
    }

    /// 检查订单是否包含美睫项目，若包含则自动生成补睫提醒（同一订单不会重复生成）
    private func createLashReminderIfNeeded(order: Order) {
        // 防护1：同 order.id 是否已存在补睫提醒，避免重复创建（即使已完成也不重复）
        if lashReminders.contains(where: { $0.orderId == order.id }) { return }
        // 找出所有美睫分类（顶层分类名为"美睫"）—— 防护2：分类不存在时 lashCategoryIds 为空，直接跳过
        let lashCategoryIds = Set(categories.filter { $0.name == "美睫" }.map { $0.id })
        // 检查订单行项是否属于美睫分类
        let lashItemIds = order.lineItems.compactMap { item -> UUID? in
            guard let s = serviceMap[item.serviceItemId] else { return nil }
            // 补睫类项目不再生成新的补睫提醒，避免循环
            if s.isLashTouchUp { return nil }
            // 看该项目的 categoryId 是否属于美睫分类或其子分类
            var catId: UUID? = s.categoryId
            while let cid = catId {
                if lashCategoryIds.contains(cid) { return s.id }
                // 防护3：父分类不存在时 while 循环正常退出，不崩溃
                guard let parent = categories.first(where: { $0.id == cid }) else { break }
                catId = parent.parentId
            }
            return nil
        }
        guard !lashItemIds.isEmpty else { return }

        // 获取客户会员等级
        let customer = customers.first(where: { $0.id == order.customerId })
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

    private func applyPrefillIfNeeded() {
        guard !didPrefill, let rec = prefillRecord else { return }
        didPrefill = true
        customerId = rec.customerId
        technicianId = rec.technicianId
        recordId = rec.id
    }

    private func save() {
        guard let cid = customerId else { return }

        // 计算钱包抵扣金额 & 补足部分支付方式
        let deductWallet = walletDeducted
        let realTopUpMethod: String?
        if deductWallet > 0 {
            if topUpAmount > 0 {
                realTopUpMethod = topUpPaymentMethod
            } else {
                realTopUpMethod = nil
            }
        } else {
            realTopUpMethod = nil
        }


        let order = Order(recordId: recordId, customerId: cid,
                          technicianId: technicianId,
                          lineItems: lineItems,
                          totalAmount: finalTotal,
                          originalTotal: total,
                          discountAmount: discountAmount,
                          paymentMethod: resolvedPaymentMethod,
                          walletDeducted: deductWallet,
                          topUpPaymentMethod: realTopUpMethod,
                          paidAt: paidAt,
                          notes: notes.isEmpty ? nil : notes)
        if let c = customers.first(where: { $0.id == cid }) {
            c.updatedAt = Date()
            // 最后到店时间
            c.lastVisitDate = paidAt
        }
        // 标记关联服务记录为已付款
        if let rid = recordId, let r = records.first(where: { $0.id == rid }) {
            r.isPaid = true
        }
        onSave(order)
        // 检查订单是否包含美睫项目，自动生成补睫提醒
        createLashReminderIfNeeded(order: order)
        // 收银含美睫项目时，自动将该客户关联的待补睫提醒标记为已完成
        completeLashReminderIfNeeded(order: order)
        dismiss()
    }

    /// 收银含美睫项目时，通过 recordId → NailServiceRecord.reminderId 精确定位关联的补睫提醒并标记为已补睫。
    /// 仅当订单是从补睫提醒→预约→服务记录这条精确链路产生时才标记，避免误标记新生成的美睫提醒。
    private func completeLashReminderIfNeeded(order: Order) {
        guard let rid = order.recordId,
              let record = records.first(where: { $0.id == rid }),
              let reminderId = record.reminderId,
              let target = lashReminders.first(where: { $0.id == reminderId }) else { return }
        target.isCompleted = true
        target.completedAt = order.paidAt
    }
}

// MARK: - 服务项目多选 Sheet
struct ServicePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let services: [ServiceItem]
    let categories: [ServiceCategory]
    let serviceMap: [UUID: ServiceItem]
    let categoryMap: [UUID: ServiceCategory]
    let existingIds: Set<UUID>
    let onConfirm: ([ServiceItem]) -> Void

    @State private var selectedIds: Set<UUID>

    init(services: [ServiceItem],
         categories: [ServiceCategory],
         serviceMap: [UUID: ServiceItem],
         categoryMap: [UUID: ServiceCategory],
         existingIds: Set<UUID>,
         onConfirm: @escaping ([ServiceItem]) -> Void) {
        self.services = services
        self.categories = categories
        self.serviceMap = serviceMap
        self.categoryMap = categoryMap
        self.existingIds = existingIds
        self.onConfirm = onConfirm
        _selectedIds = State(initialValue: existingIds)
    }

    private var sortedServices: [ServiceItem] {
        services.sorted { a, b in
            let na = fullServiceName(for: a.id, serviceMap: serviceMap, categoryMap: categoryMap)
            let nb = fullServiceName(for: b.id, serviceMap: serviceMap, categoryMap: categoryMap)
            return na < nb
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择服务项目")
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

            if sortedServices.isEmpty {
                Spacer()
                EmptyStateView(
                    systemImage: "bag",
                    title: "暂无服务项目",
                    message: "请先在「服务项目」模块创建项目"
                )
                Spacer()
            } else {
                List {
                    CollapsibleServiceMultiSelect(
                        services: services,
                        categories: categories,
                        selectedIds: $selectedIds
                    ) { s in
                        HStack(spacing: 6) {
                            if existingIds.contains(s.id) {
                                Text("已在明细中")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text("¥" + String(format: "%.0f", s.price))
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button("全选") {
                    selectedIds.formUnion(services.map { $0.id })
                }
                .buttonStyle(.bordered)
                Button("清空") {
                    selectedIds.removeAll()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button("确认") {
                    let items = sortedServices.filter { selectedIds.contains($0.id) }
                    onConfirm(items)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIds.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 440, idealHeight: 520, maxHeight: 700)
    }
}

// MARK: - 订单详情（含密码保护的删除）
struct OrderDetailSheet: View {
    let order: Order
    let customerName: String
    let technicianName: String
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showingDeleteConfirm = false
    @State private var needsSetupPassword = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("收款详情").font(.headline)
                    Text(customerName + " · ¥" + String(format: "%.0f", order.totalAmount))
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
                Section("收款信息") {
                    LabeledContent("客户", value: customerName)
                    if !technicianName.isEmpty {
                        LabeledContent("技师", value: technicianName)
                    }
                    LabeledContent("付款时间", value: order.paidAt.cnDateTime)
                    LabeledContent("支付方式", value: order.paymentMethod ?? "未记录")
                    if order.discountAmount > 0 {
                        LabeledContent("原价合计", value: "¥" + String(format: "%.0f", order.originalTotal))
                            .foregroundStyle(.secondary)
                        LabeledContent("优惠金额", value: "-¥" + String(format: "%.0f", order.discountAmount))
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("实收合计", value: "¥" + String(format: "%.0f", order.totalAmount))
                        .font(.headline)
                }
                Section("结账明细（\(order.lineItems.count)）") {
                    if order.lineItems.isEmpty {
                        Text("无明细").foregroundStyle(.secondary).font(.caption)
                    } else {
                        ForEach(order.lineItems) { item in
                            HStack {
                                Text(item.name)
                                Spacer()
                                Text("¥" + String(format: "%.0f", item.price)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let n = order.notes, !n.isEmpty {
                    Section("备注") { Text(n) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("删除") {
                    if SecurityManager.shared.hasPassword {
                        showingDeleteConfirm = true
                    } else {
                        needsSetupPassword = true
                    }
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 440, idealHeight: 520, maxHeight: 700)
        .alert("需要设置密码", isPresented: $needsSetupPassword) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("删除收款记录需要先在「设置」中设置密码。")
        }
        .sheet(isPresented: $showingDeleteConfirm) {
            PasswordConfirmSheet(
                title: "确认删除收款记录？",
                message: "请输入密码以确认删除，此操作不可撤销。",
                confirmTitle: "删除",
                destructive: true
            ) {
                onDelete()
                dismiss()
            }
            
        }
    }
}

// MARK: - 分页控件
struct PaginationBar: View {
    @Binding var currentPage: Int
    let totalPages: Int
    let totalItems: Int
    @State private var jumpText = ""

    var body: some View {
        HStack(spacing: 4) {
            // 首页
            Button {
                currentPage = 1
            } label: {
                Text("首页")
                    .font(.caption)
                    .frame(minWidth: 40)
            }
            .buttonStyle(.bordered)
            .disabled(currentPage == 1)

            // 上一页
            Button {
                currentPage -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .disabled(currentPage == 1)

            // 页码按钮
            ForEach(0..<pageNumbers.count, id: \.self) { idx in
                PageNumberItem(
                    page: pageNumbers[idx],
                    currentPage: $currentPage
                )
            }

            // 下一页
            Button {
                currentPage += 1
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .disabled(currentPage == totalPages)

            // 尾页
            Button {
                currentPage = totalPages
            } label: {
                Text("尾页")
                    .font(.caption)
                    .frame(minWidth: 40)
            }
            .buttonStyle(.bordered)
            .disabled(currentPage == totalPages)

            Spacer()

            Text("共 \(totalItems) 条")
                .font(.caption)
                .foregroundStyle(.secondary)

            // 跳转页码输入框
            TextField("页码", text: $jumpText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .multilineTextAlignment(.center)
                .onSubmit { jumpToPage() }
            Button("跳转") { jumpToPage() }
                .buttonStyle(.bordered)
                .disabled(Int(jumpText.trimmingCharacters(in: .whitespaces)) == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // 计算显示的页码（标准论坛式：固定首尾 + 当前页周边窗口，间隔用省略号 -1）
    private var pageNumbers: [Int] {
        guard totalPages > 1 else { return [1] }
        var pages: Set<Int> = []
        // 固定前两页
        pages.insert(1)
        if totalPages >= 2 { pages.insert(2) }
        // 固定后两页
        if totalPages >= 2 { pages.insert(totalPages - 1) }
        pages.insert(totalPages)
        // 当前页周边窗口（±2）
        for p in (currentPage - 2)...(currentPage + 2) {
            if p >= 1 && p <= totalPages { pages.insert(p) }
        }
        // 排序后，间隔 > 1 的地方插入省略号
        let sorted = pages.sorted()
        var result: [Int] = []
        var prev: Int?
        for p in sorted {
            if let last = prev, p - last > 1 {
                result.append(-1) // 省略号
            }
            result.append(p)
            prev = p
        }
        return result
    }

    private func jumpToPage() {
        guard let n = Int(jumpText.trimmingCharacters(in: .whitespaces)),
              (1...totalPages).contains(n) else {
            jumpText = ""
            return
        }
        currentPage = n
        jumpText = ""
    }
}

// MARK: - 页码项（单独视图避免 ForEach 类型推断问题）
private struct PageNumberItem: View {
    let page: Int
    @Binding var currentPage: Int

    var body: some View {
        if page == -1 {
            Text("...")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 28)
        } else if page == currentPage {
            Button {
                currentPage = page
            } label: {
                Text("\(page)")
                    .font(.caption)
                    .frame(minWidth: 28)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                currentPage = page
            } label: {
                Text("\(page)")
                    .font(.caption)
                    .frame(minWidth: 28)
            }
            .buttonStyle(.bordered)
        }
    }
}
