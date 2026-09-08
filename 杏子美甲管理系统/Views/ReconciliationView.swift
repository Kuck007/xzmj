//
//  ReconciliationView.swift
//  杏子美甲管理系统
//
//  技师日结对账确认
//

import SwiftUI
import SwiftData
import CryptoKit

struct ReconciliationView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Technician.name) private var technicians: [Technician]
    @Query(sort: \Order.paidAt, order: .reverse) private var orders: [Order]
    @Query private var reconciliations: [DailyReconciliation]
    @Query private var users: [User]

    /// 当前查看的日期
    @State private var currentDate = Date()
    /// 当前选中的技师（nil=显示卡片列表）
    @State private var selectedTechnician: Technician? = nil
    /// 当前选中的订单（详情sheet）
    @State private var selectedOrder: Order? = nil
    /// 是否显示确认对账sheet
    @State private var showingConfirmSheet = false
    /// 确认sheet中的安全码
    @State private var confirmCode = ""
    /// 确认sheet错误提示
    @State private var confirmError = ""

    private let calendar = Calendar.current

    // MARK: - 日期工具

    private var dayStart: Date {
        calendar.startOfDay(for: currentDate)
    }

    private var dayEnd: Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    }

    private var dateTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE"
        return f.string(from: currentDate)
    }

    // MARK: - 数据计算

    /// 某日某技师的订单
    private func orders(for technician: Technician, on date: Date) -> [Order] {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return orders.filter {
            $0.technicianId == technician.id
            && $0.paidAt >= start && $0.paidAt < end
        }
    }

    /// 某日某技师的业绩
    private func amount(for technician: Technician, on date: Date) -> Double {
        orders(for: technician, on: date).reduce(0) { $0 + $1.totalAmount }
    }

    /// 某日某技师的对账记录
    private func reconciliation(for technician: Technician, on date: Date) -> DailyReconciliation? {
        let start = calendar.startOfDay(for: date)
        return reconciliations.first {
            $0.technicianId == technician.id
            && calendar.startOfDay(for: $0.date) == start
        }
    }

    /// 某日某技师是否已确认
    private func isConfirmed(technician: Technician, on date: Date) -> Bool {
        reconciliation(for: technician, on: date)?.confirmedAt != nil
    }

    /// 客户名查找
    private func customerName(for order: Order) -> String {
        // 从订单的 customerId 查找客户名，这里用 @Query 太麻烦，简化显示
        // 实际项目中可以通过 @Query customers 查找
        return "客户"
    }

    // MARK: - 安全码验证

    /// 通过技师关联的username查找对应用户
    private func user(for technician: Technician) -> User? {
        guard let username = technician.userUsername else { return nil }
        return users.first { $0.username == username }
    }

    /// 验证安全码
    private func verifyCode(_ code: String, for technician: Technician) -> Bool {
        guard let user = user(for: technician) else { return false }
        let hash = SHA256.hash(data: Data(code.utf8))
        let hashStr = hash.compactMap { String(format: "%02x", $0) }.joined()
        return hashStr == user.securityCodeHash
    }

    /// 确认对账
    private func confirmReconciliation(for technician: Technician) {
        let amt = amount(for: technician, on: currentDate)
        let cnt = orders(for: technician, on: currentDate).count

        if let existing = reconciliation(for: technician, on: currentDate) {
            existing.confirmedAt = Date()
            existing.snapshotAmount = amt
            existing.snapshotCount = cnt
        } else {
            let recon = DailyReconciliation(
                technicianId: technician.id,
                date: dayStart,
                confirmedAt: Date(),
                snapshotAmount: amt,
                snapshotCount: cnt
            )
            context.insert(recon)
        }
        try? context.save()
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 顶部日期导航
            HStack {
                Button {
                    currentDate = calendar.date(byAdding: .day, value: -1, to: currentDate) ?? currentDate
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)

                Text(dateTitle)
                    .font(.title2.bold())
                    .frame(minWidth: 240)

                Button {
                    currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)

                Button("今天") {
                    currentDate = Date()
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider()

            if let tech = selectedTechnician {
                // 技师订单详情视图
                technicianDetailView(tech)
            } else {
                // 技师卡片网格
                technicianGridView
            }
        }
        .sheet(isPresented: Binding(get: { selectedOrder != nil }, set: { if !$0 { selectedOrder = nil } })) {
            if let order = selectedOrder {
                OrderReadOnlyDetailSheet(order: order)
            }
        }
        .sheet(isPresented: $showingConfirmSheet) {
            confirmSheet
        }
        .navigationTitle("对账确认")
    }

    // MARK: - 技师卡片网格

    private var technicianGridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(technicians.filter { $0.isActive }) { tech in
                    let amt = amount(for: tech, on: currentDate)
                    let cnt = orders(for: tech, on: currentDate).count
                    let confirmed = isConfirmed(technician: tech, on: currentDate)

                    Button {
                        selectedTechnician = tech
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(tech.name)
                                    .font(.headline)
                                Spacer()
                                if confirmed {
                                    Label("已确认", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                } else {
                                    Label("未确认", systemImage: "circle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            HStack(spacing: 16) {
                                VStack(alignment: .leading) {
                                    Text("服务单数")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("\(cnt)")
                                        .font(.title2.bold())
                                }
                                VStack(alignment: .leading) {
                                    Text("业绩")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("¥" + String(format: "%.0f", amt))
                                        .font(.title2.bold())
                                        .foregroundStyle(Color.brand)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(confirmed ? Color.green.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    // MARK: - 技师订单详情

    private func technicianDetailView(_ tech: Technician) -> some View {
        let techOrders = orders(for: tech, on: currentDate)
        let amt = amount(for: tech, on: currentDate)
        let confirmed = isConfirmed(technician: tech, on: currentDate)

        return VStack(spacing: 0) {
            // 顶部返回 + 汇总
            HStack {
                Button {
                    selectedTechnician = nil
                } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)

                Text(tech.name)
                    .font(.title3.bold())
                    .padding(.leading, 8)

                Spacer()

                Text("业绩：¥" + String(format: "%.0f", amt))
                    .font(.headline)
                    .foregroundStyle(Color.brand)
                Text("(\(techOrders.count)单)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider()

            if techOrders.isEmpty {
                Spacer()
                ContentUnavailableView("当日无订单", systemImage: "doc.text", description: Text("该技师当日没有服务记录"))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(techOrders, id: \.id) { order in
                            Button {
                                selectedOrder = order
                            } label: {
                                HoverHighlightRow {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(order.paidAt.formatted(date: .omitted, time: .shortened))
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                            Text(order.lineItems.map { $0.name }.joined(separator: "、"))
                                                .font(.body)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text("¥" + String(format: "%.0f", order.totalAmount))
                                            .font(.headline)
                                            .foregroundStyle(Color.brand)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }

            Divider()

            // 底部确认按钮
            HStack {
                Spacer()
                if confirmed {
                    Label("已确认对账", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding(.trailing, 16)
                } else if user(for: tech) == nil {
                    Label("未关联登录账号", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .padding(.trailing, 16)
                } else {
                    Button("对账确认") {
                        confirmCode = ""
                        confirmError = ""
                        showingConfirmSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.trailing, 16)
                }
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - 确认对账 Sheet

    private var confirmSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("确认对账")
                        .font(.headline)
                    Text("请输入\(selectedTechnician?.name ?? "")的安全码")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingConfirmSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider()

            Form {
                Section {
                    SecureField("安全码", text: $confirmCode)
                        .textFieldStyle(.roundedBorder)
                    if !confirmError.isEmpty {
                        Text(confirmError)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                } footer: {
                    Text("安全码是该技师登录账号的安全码，确保只有本人可以确认对账。")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("取消") {
                    showingConfirmSheet = false
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("确认") {
                    guard let tech = selectedTechnician else { return }
                    if confirmCode.isEmpty {
                        confirmError = "请输入安全码"
                        return
                    }
                    if verifyCode(confirmCode, for: tech) {
                        confirmReconciliation(for: tech)
                        showingConfirmSheet = false
                    } else {
                        confirmError = "安全码错误"
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 420, height: 280)
    }
}

// MARK: - 只读订单详情 Sheet

struct OrderReadOnlyDetailSheet: View {
    let order: Order
    @Environment(\.dismiss) private var dismiss
    @Query private var customers: [Customer]

    private var customerName: String {
        customers.first { $0.id == order.customerId }?.name ?? "未知客户"
    }

    var body: some View {
        VStack(spacing: 0) {
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
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider()

            Form {
                Section("收款信息") {
                    LabeledContent("客户", value: customerName)
                    LabeledContent("付款时间", value: order.paidAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("支付方式", value: order.paymentMethod ?? "未记录")
                    if order.discountAmount > 0 {
                        LabeledContent("原价合计", value: "¥" + String(format: "%.0f", order.originalTotal))
                            .foregroundStyle(.secondary)
                        LabeledContent("优惠金额", value: "-¥" + String(format: "%.0f", order.discountAmount))
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("实收合计", value: "¥" + String(format: "%.0f", order.totalAmount))
                        .font(.headline)
                    if order.walletDeducted > 0 {
                        LabeledContent("会员卡扣款", value: "¥" + String(format: "%.0f", order.walletDeducted))
                    }
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
                Text("只读视图，修改请前往收银结账")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 440, idealHeight: 520, maxHeight: 700)
    }
}
