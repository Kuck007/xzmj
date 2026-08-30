//
//  SalaryView.swift
//  杏子美甲管理系统
//
//  技师工资·提成模块：
//  - 底薪 + 提成；底薪与提成比例都在「技师管理」里逐技师设置（Technician.baseSalary / commissionRate）
//  - 提成 = 核算区间内该技师「收银结账 Order 实收金额」的合计 × 该技师提成比例
//  - 只统计在职技师（isActive == true），离职的不显示
//

import SwiftUI
import SwiftData

struct SalaryView: View {
    @Query(sort: \Technician.name) private var technicians: [Technician]
    @Query private var orders: [Order]

    // 按月浏览历史（monthOffset：0=本月，-1=上月，…）；showAll=true 时显示全部
    @State private var showAll = false
    @State private var monthOffset = 0

    /// 在职技师（工资只统计在职的，离职的不显示）
    private var activeTechnicians: [Technician] {
        technicians.filter(\.isActive)
    }

    /// 当前浏览的月份
    private var navMonth: Date {
        Calendar.current.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
    }

    private func ordersInPeriod(for techId: UUID) -> [Order] {
        let cal = Calendar.current
        return orders.filter { o in
            guard o.technicianId == techId else { return false }
            if showAll { return true }
            return cal.isDate(o.paidAt, equalTo: navMonth, toGranularity: .month)
        }
    }

    private func paid(for techId: UUID) -> Double {
        // NOTE: 技师分成按「订单服务全额 totalAmount」统计，不扣钱包抵扣：
        // - 充值金额本身不算入技师分成（那时候还没消费）
        // - 客户实际来消费时，不管是掏钱包余额还是掏现金，技师都按这笔服务全款计提
        ordersInPeriod(for: techId).reduce(0) { $0 + $1.totalAmount }
    }

    /// 当前核算期的中文年月显示（如 "2026年8月"），全部时为 "全部"
    private var periodLabel: String {
        guard !showAll else { return "全部" }
        let cal = Calendar.current
        return "\(cal.component(.year, from: navMonth))年\(cal.component(.month, from: navMonth))月"
    }

    // MARK: - Body
    var body: some View {
        // macOS NavigationSplitView 的 detail column 会自动处理 .navigationTitle/.toolbar/.searchable，NavigationStack 在 detail 里是冗余的，且会吃掉 sheet 首次 present 的进入动画
        VStack(spacing: 0) {
            mainContent
        }
        .navigationTitle("技师工资")
    }

    @ViewBuilder
    private var mainContent: some View {
        if technicians.isEmpty {
            EmptyStateView(
                systemImage: "banknote",
                title: "暂无技师",
                message: "请先在「技师管理」模块添加技师，即可在此核算工资提成"
            )
        } else {
            payrollList
        }
    }

    private var payrollList: some View {
        List {
            // 顶部：月份导航按钮 + 当前核算期（居中、放大、统一字体）
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Button("上一个月") { showAll = false; monthOffset -= 1 }
                        .buttonStyle(.bordered)
                    Button("下一个月") { showAll = false; monthOffset += 1 }
                        .buttonStyle(.bordered)
                        .disabled(monthOffset >= 0)   // 不能查看未来
                    Button("本月") { showAll = false; monthOffset = 0 }
                        .buttonStyle(.bordered)
                    Button("全部") { showAll = true }
                        .buttonStyle(.bordered).tint(showAll ? .accentColor : .gray)
                }
                Text("当前核算期  \(periodLabel)")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)

            salarySection
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var salarySection: some View {
        Section("技师工资表（\(periodLabel)）") {
            if activeTechnicians.isEmpty {
                Text("暂无在职技师可核算工资")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                headerRow
                ForEach(activeTechnicians) { t in
                    TechnicianSalaryRow(
                        technician: t,
                        paid: paid(for: t.id),
                        commission: paid(for: t.id) * t.commissionRate
                    )
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            headerCell("技师", 70, .leading)
            headerCell("底薪", 72, .trailing)
            headerCell("比例", 54, .trailing)
            headerCell("实收", 78, .trailing)
            headerCell("提成", 78, .trailing)
            headerCell("合计工资", 88, .trailing)
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
    }

    private func headerCell(_ title: String, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Text(title)
            .frame(width: width, alignment: alignment)
    }
}


// MARK: - 技师工资行（底薪 / 比例来自「技师管理」，此处只读展示）

struct TechnicianSalaryRow: View {
    let technician: Technician
    let paid: Double
    let commission: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(technician.name)
                .frame(width: 70, alignment: .leading)
                .lineLimit(1)
            Text(technician.baseSalary.cny)
                .frame(width: 72, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("\(Int((technician.commissionRate * 100).rounded()))%")
                .frame(width: 54, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(paid.cny)
                .frame(width: 78, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(commission.cny)
                .frame(width: 78, alignment: .trailing)
                .foregroundStyle(.green)
                .monospacedDigit()
            Text((technician.baseSalary + commission).cny)
                .frame(width: 88, alignment: .trailing)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.callout)
    }
}

private extension Double {
    var cny: String { String(format: "%.2f", self) }
}
