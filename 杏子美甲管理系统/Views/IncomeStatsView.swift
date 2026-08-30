//
//  IncomeStatsView.swift
//  杏子美甲管理系统
//

import SwiftUI
import SwiftData
import Charts

private struct StatRow: Identifiable {
    let id = UUID()
    let label: String
    let amount: Double
}

struct IncomeStatsView: View {
    @Query(sort: \Order.paidAt, order: .reverse) private var orders: [Order]
    @Query(sort: \RechargeRecord.rechargeAt, order: .reverse) private var recharges: [RechargeRecord]
    @Query private var technicians: [Technician]

    // 统计周期：0=全部 1=月 2=周 3=日
    @State private var period = 1
    // 周导航（周视图）
    @State private var navWeekOffset = 0
    // 日导航（日视图）
    @State private var navDayOffset = 0
    // 技师筛选：nil=全店
    @State private var selectedTechnicianId: UUID?

    // 日历范围选择（月视图下的酒店式日历）
    @State private var calendarMonthOffset = 0   // 日历当前显示的月份偏移
    @State private var rangeStart: Date?          // 范围起始日
    @State private var rangeEnd: Date?            // 范围结束日
    @State private var hasSelectedRange = false   // 是否已完成范围选择

    // 周一为一周第一天的日历
    private var mondayCalendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2  // Monday
        return cal
    }

    private var technicianMap: [UUID: Technician] {
        Dictionary(uniqueKeysWithValues: technicians.map { ($0.id, $0) })
    }

    // MARK: - 日期计算

    /// 当前导航到的周（周一）
    private var navWeekStart: Date {
        let cal = mondayCalendar
        let base = cal.date(byAdding: .weekOfYear, value: navWeekOffset, to: Date()) ?? Date()
        let comp = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: base)
        return cal.date(from: comp) ?? base
    }

    /// 当前导航到的周（周日）
    private var navWeekEnd: Date {
        mondayCalendar.date(byAdding: .day, value: 6, to: navWeekStart) ?? navWeekStart
    }

    /// 当前导航到的日
    private var navDay: Date {
        Calendar.current.date(byAdding: .day, value: navDayOffset, to: Date()) ?? Date()
    }

    /// 日历当前显示的月份
    private var calendarMonth: Date {
        Calendar.current.date(byAdding: .month, value: calendarMonthOffset, to: Date()) ?? Date()
    }

    // MARK: - 标题

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f.string(from: calendarMonth)
    }

    private var weekTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        let cal = Calendar.current
        let startMonth = cal.component(.month, from: navWeekStart)
        let endMonth = cal.component(.month, from: navWeekEnd)
        let startYear = cal.component(.year, from: navWeekStart)
        let endYear = cal.component(.year, from: navWeekEnd)

        if startYear == endYear && startMonth == endMonth {
            // 同年同月：2026年8月3日-9日
            f.dateFormat = "yyyy年M月d日"
            let startStr = f.string(from: navWeekStart)
            f.dateFormat = "d日"
            let endStr = f.string(from: navWeekEnd)
            return "\(startStr)-\(endStr)"
        } else if startYear == endYear {
            // 同年不同月：2026年8月3日-9月1日
            f.dateFormat = "M月d日"
            let startStr = f.string(from: navWeekStart)
            let endStr = f.string(from: navWeekEnd)
            return "\(startYear)年\(startStr)-\(endStr)"
        } else {
            // 跨年：2025年12月29日-2026年1月4日
            f.dateFormat = "yyyy年M月d日"
            return "\(f.string(from: navWeekStart))-\(f.string(from: navWeekEnd))"
        }
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f.string(from: navDay)
    }

    private var periodTitle: String {
        switch period {
        case 1: return monthTitle
        case 2: return weekTitle
        case 3: return dayTitle
        default: return "全部"
        }
    }

    // MARK: - 订单筛选

    /// 按技师筛选后的订单
    private var techFilteredOrders: [Order] {
        guard let tid = selectedTechnicianId else { return orders }
        return orders.filter { $0.technicianId == tid }
    }

    /// 按周期筛选
    private var filtered: [Order] {
        let cal = Calendar.current
        let source = techFilteredOrders
        switch period {
        case 1: // 月视图
            if hasSelectedRange, let start = rangeStart, let end = rangeEnd {
                // 日历选了范围，按范围筛选（end 为次日0点，用 < 排除）
                let dayStart = cal.startOfDay(for: start)
                let dayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: end)) ?? end
                return source.filter { $0.paidAt >= dayStart && $0.paidAt < dayEnd }
            } else {
                // 没选范围，按整个月筛选
                return source.filter { cal.isDate($0.paidAt, equalTo: calendarMonth, toGranularity: .month) }
            }
        case 2: // 周视图：周一0点 ~ 下周一0点
            let weekStart = cal.startOfDay(for: navWeekStart)
            let weekEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: navWeekEnd)) ?? navWeekEnd
            return source.filter { $0.paidAt >= weekStart && $0.paidAt < weekEnd }
        case 3: // 日视图
            return source.filter { cal.isDate($0.paidAt, inSameDayAs: navDay) }
        default: // 全部
            return source
        }
    }

    /// 同周期筛选的充值记录（只在「全店」模式统计充值，技师维度不摊）
    private var filteredRecharges: [RechargeRecord] {
        guard selectedTechnicianId == nil else { return [] }
        let cal = Calendar.current
        switch period {
        case 1:
            if hasSelectedRange, let start = rangeStart, let end = rangeEnd {
                let dayStart = cal.startOfDay(for: start)
                let dayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: end)) ?? end
                return recharges.filter { $0.rechargeAt >= dayStart && $0.rechargeAt < dayEnd }
            } else {
                return recharges.filter { cal.isDate($0.rechargeAt, equalTo: calendarMonth, toGranularity: .month) }
            }
        case 2:
            let weekStart = cal.startOfDay(for: navWeekStart)
            let weekEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: navWeekEnd)) ?? navWeekEnd
            return recharges.filter { $0.rechargeAt >= weekStart && $0.rechargeAt < weekEnd }
        case 3:
            return recharges.filter { cal.isDate($0.rechargeAt, inSameDayAs: navDay) }
        default:
            return recharges
        }
    }

    /// 充值金额合计（全店模式）
    private var rechargeTotal: Double { filteredRecharges.reduce(0) { $0 + $1.amount } }

    /// 订单中的「补足支付」现金收入合计（钱包抵扣部分不算入，因为充值时已计入）
    private var paidInTotal: Double {
        filtered.reduce(0) { $0 + max(0, $1.totalAmount - $1.walletDeducted) }
    }

    /// 店铺总收入 = 实收补足部分 + 当期充值金额
    private var total: Double { paidInTotal + rechargeTotal }
    private var count: Int { filtered.count + filteredRecharges.count }
    /// 客单价：仅订单部分，充值不计入客单价
    private var orderAverage: Double { filtered.isEmpty ? 0 : filtered.reduce(0) { $0 + $1.totalAmount } / Double(filtered.count) }

    /// 标准化支付方式名称，处理数据库中可能的不规范写法
    private func normalizePaymentMethod(_ method: String) -> String {
        switch method {
        case "付宝": return "支付宝"
        default: return method
        }
    }

    /// 按支付方式：订单里只计入「补足支付」；钱包抵扣本身不计；另加「会员充值」条目
    private var byMethod: [StatRow] {
        var dict: [String: Double] = [:]

        for o in filtered {
            let wallet = o.walletDeducted
            // 订单补足部分对应的支付方式（可能是单一方式，也可能是「会员钱包+XX」混合）
            let topUpCash = max(0, o.totalAmount - wallet)
            if topUpCash <= 0 { continue }

            let method = o.paymentMethod ?? "未填"
            if method.hasPrefix("会员钱包+") {
                // 混合支付：把补足部分记到「+」后面的真实支付方式（标准化处理）
                let suffix = normalizePaymentMethod(String(method.dropFirst(6)))
                dict[suffix, default: 0] += topUpCash
            } else if method == "会员钱包" {
                // 全用钱包：没有补足现金
                continue
            } else {
                // 普通单一支付（标准化处理）
                let normalized = normalizePaymentMethod(method)
                dict[normalized, default: 0] += topUpCash
            }
        }

        // 充值金额计入独立条目
        if rechargeTotal > 0 {
            dict["会员充值", default: 0] += rechargeTotal
        }

        return dict.map { StatRow(label: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }
    }

    private var byService: [StatRow] {
        var dict: [String: Double] = [:]
        for o in filtered {
            for item in o.lineItems { dict[item.name, default: 0] += item.price }
        }
        return dict.map { StatRow(label: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }
            .prefix(8)
            .map { $0 }
    }

    /// 按技师统计营收（仅在"全部技师"模式下显示）—— 按 totalAmount（服务全款），
    /// 因为技师分成是在实际消费时按服务全款计提，不管客户用钱包还是现金。
    private var byTechnician: [StatRow] {
        let dict = Dictionary(grouping: filtered, by: { $0.technicianId })
        return dict.compactMap { (tid, orders) -> StatRow? in
            guard let tid = tid else { return StatRow(label: "未关联技师", amount: orders.reduce(0) { $0 + $1.totalAmount }) }
            let name = technicianMap[tid]?.name ?? "未知技师"
            return StatRow(label: name, amount: orders.reduce(0) { $0 + $1.totalAmount })
        }
        .sorted { $0.amount > $1.amount }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 技师筛选
                HStack(spacing: 12) {
                    Picker("统计范围", selection: $selectedTechnicianId) {
                        Text("全店").tag(UUID?.none)
                        ForEach(technicians) { t in
                            Text(t.name).tag(Optional(t.id))
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                .padding(.horizontal, 16)

                // 周期切换：月 / 周 / 日 / 全部
                Picker("统计周期", selection: $period) {
                    Text("月").tag(1); Text("周").tag(2); Text("日").tag(3); Text("全部").tag(0)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .onChange(of: period) { _, newValue in
                    if newValue == 1 {
                        calendarMonthOffset = 0
                        hasSelectedRange = false
                        rangeStart = nil
                        rangeEnd = nil
                    }
                    if newValue == 2 { navWeekOffset = 0 }
                    if newValue == 3 { navDayOffset = 0 }
                }

                // 导航栏（月/周/日视图显示各自导航）
                if period == 1 {
                    calendarView
                } else if period == 2 {
                    weekNavigationView
                } else if period == 3 {
                    dayNavigationView
                }

                if filtered.isEmpty && filteredRecharges.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.bar",
                        title: "暂无数据",
                        message: "\(periodTitle)还没有订单收入或充值记录"
                    )
                } else {
                    // 概览卡片
                    HStack(spacing: 16) {
                        StatCard(title: "总收入",
                                 value: "¥" + String(format: "%.2f", total),
                                 systemImage: "yensign.circle.fill", tint: Color.brand)
                        StatCard(title: "订单数", value: "\(filtered.count)",
                                 systemImage: "doc.text.fill", tint: .brandMono)
                        StatCard(title: "客单价", value: "¥" + String(format: "%.2f", orderAverage),
                                 systemImage: "person.2.fill", tint: .brandMono)
                        if rechargeTotal > 0 {
                            StatCard(title: "会员充值", value: "¥" + String(format: "%.0f", rechargeTotal),
                                     systemImage: "creditcard.circle.fill", tint: Color.brandMono)
                        }
                    }
                    .padding(.horizontal, 16)

                    // 按技师统计（仅在"全店"模式下显示）
                    if selectedTechnicianId == nil && !byTechnician.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("按技师营收").font(.headline).padding(.horizontal, 16)
                            Chart(byTechnician) { row in
                                BarMark(x: .value("金额", row.amount), y: .value("技师", row.label))
                                    .foregroundStyle(Color.brand)
                                    .annotation(position: .trailing) {
                                        Text("¥" + String(format: "%.0f", row.amount)).font(.caption)
                                    }
                            }
                            .frame(height: CGFloat(byTechnician.count * 40 + 40))
                            .padding(.horizontal, 16)
                        }
                    }

                    // 支付方式占比
                    if !byMethod.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("按支付方式").font(.headline).padding(.horizontal, 16)
                            Chart(byMethod) { row in
                                BarMark(x: .value("金额", row.amount), y: .value("方式", row.label))
                                    .foregroundStyle(Color.brand)
                                    .annotation(position: .trailing) {
                                        Text("¥" + String(format: "%.0f", row.amount)).font(.caption)
                                    }
                            }
                            .frame(height: CGFloat(byMethod.count * 40 + 40))
                            .padding(.horizontal, 16)
                        }
                    }

                    // 项目排行
                    if !byService.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("按项目（前8）").font(.headline).padding(.horizontal, 16)
                            ForEach(byService) { row in
                                HStack {
                                    Text(row.label).foregroundStyle(.primary)
                                    Spacer()
                                    Text("¥" + String(format: "%.2f", row.amount))
                                        .foregroundStyle(Color.brand)
                                }
                                .font(.body)
                                .padding(.horizontal, 16).padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("收入统计")
    }

    // MARK: - 周度导航（左右调节按7天1周，周一开始到周日结束）

    private var weekNavigationView: some View {
        HStack(spacing: 16) {
            Button {
                navWeekOffset -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 28, height: 28)
                    .background(Color.brand.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Text(weekTitle)
                .font(.headline)
                .frame(maxWidth: .infinity)

            Button {
                navWeekOffset += 1
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 28, height: 28)
                    .background(Color.brand.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(navWeekOffset >= 0)

            if navWeekOffset != 0 {
                Button {
                    navWeekOffset = 0
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "target")
                            .font(.system(size: 11))
                        Text("本周")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.brand)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(Color.brand.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 日度导航（左右调节增减一日，显示具体哪年哪月哪日）

    private var dayNavigationView: some View {
        HStack(spacing: 16) {
            Button {
                navDayOffset -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 28, height: 28)
                    .background(Color.brand.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Text(dayTitle)
                .font(.headline)
                .frame(maxWidth: .infinity)

            Button {
                navDayOffset += 1
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 28, height: 28)
                    .background(Color.brand.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(navDayOffset >= 0)

            if navDayOffset != 0 {
                Button {
                    navDayOffset = 0
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "target")
                            .font(.system(size: 11))
                        Text("今日")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.brand)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(Color.brand.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 科技感日历日期选择器（月视图下显示）

    /// 日历主视图：可快速调节年月，点击日期选择范围
    private var calendarView: some View {
        VStack(spacing: 12) {
            // 顶部霓虹渐变横条
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.brandGradient)
                .frame(height: 3)
                .padding(.top, 10).padding(.horizontal, 14)

            // 日历标题栏：年月快速调节
            HStack(spacing: 8) {
                // 上一年
                Button {
                    calendarMonthOffset -= 12
                } label: {
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.brand)
                        .frame(width: 26, height: 26)
                        .background(Color.brand.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("上一年")

                // 上一月
                Button {
                    calendarMonthOffset -= 1
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.brand)
                        .frame(width: 26, height: 26)
                        .background(Color.brand.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("上一月")

                Spacer()

                Text(calendarMonthTitle)
                    .font(.title3.weight(.semibold))

                Spacer()

                // 下一月
                Button {
                    calendarMonthOffset += 1
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.brand)
                        .frame(width: 26, height: 26)
                        .background(Color.brand.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(calendarMonthOffset >= 0)
                .help("下一月")

                // 下一年
                Button {
                    calendarMonthOffset += 12
                } label: {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.brand)
                        .frame(width: 26, height: 26)
                        .background(Color.brand.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(calendarMonthOffset + 12 > 0)
                .help("下一年")

                // 返回本月
                if calendarMonthOffset != 0 {
                    Button {
                        calendarMonthOffset = 0
                        clearRangeSelection()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "target")
                                .font(.system(size: 11))
                            Text("本月")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Color.brand)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(Color.brand.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            // 已选范围 / 操作提示
            if hasSelectedRange, let start = rangeStart, let end = rangeEnd {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.checkmark")
                        .foregroundStyle(Color.brand)
                    Text(rangeLabel(start, end))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清除范围") {
                        clearRangeSelection()
                    }
                    .font(.caption)
                    .foregroundStyle(Color.brand)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
            } else if rangeStart != nil {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap")
                        .foregroundStyle(Color.brandAccent)
                    Text("已选起始日，请点击另一个日期选择区间（可前可后，再次点击同一天查询单日）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") {
                        rangeStart = nil
                    }
                    .font(.caption)
                    .foregroundStyle(Color.brand)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
            } else {
                Text("点击日历选择日期：点击第一天再点击第二天查询区间收入；连续两次点击同一天查询单日")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            // 星期标题（周一~周日）
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"].indices, id: \.self) { i in
                    let days = ["一", "二", "三", "四", "五", "六", "日"]
                    Text(days[i])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(i >= 5 ? Color.brandAccent : Color.secondary)
                        .frame(height: 20)
                }
            }
            .padding(.horizontal, 12)

            // 日历网格
            let days = calendarDays
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(days, id: \.timeIntervalSince1970) { date in
                    calendarDayCell(date)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .padding(.vertical, 4)
        .cardSurface(corner: Theme.Corner.large, glow: true)
        .padding(.horizontal, 16)
    }

    /// 日历当前显示的月份标题
    private var calendarMonthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f.string(from: calendarMonth)
    }

    /// 生成日历网格的42天（从本月第一周周一开始）
    private var calendarDays: [Date] {
        let cal = Calendar.current
        guard let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: calendarMonth)) else {
            return []
        }
        // 计算第一天是周几（以周一为0）
        var weekday = cal.component(.weekday, from: firstDay) - 2  // Sunday=1→-1(→6), Monday=2→0
        if weekday < 0 { weekday = 6 }
        // 网格起始日 = 第一天往前推 weekday 天
        let gridStart = cal.date(byAdding: .day, value: -weekday, to: firstDay)!
        return (0..<42).map { offset in
            cal.date(byAdding: .day, value: offset, to: gridStart)!
        }
    }

    /// 日历单元格（科技感霓虹风）
    @ViewBuilder
    private func calendarDayCell(_ date: Date) -> some View {
        let cal = Calendar.current
        let isCurrentMonth = cal.isDate(date, equalTo: calendarMonth, toGranularity: .month)
        let isToday = cal.isDateInToday(date)
        let isStart = rangeStart.map { cal.isDate($0, inSameDayAs: date) } ?? false
        let isEnd = rangeEnd.map { cal.isDate($0, inSameDayAs: date) } ?? false
        let inRange = isInSelectedRange(date, cal: cal)
        let isWeekend = cal.component(.weekday, from: date) == 1 || cal.component(.weekday, from: date) == 7

        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(dayBackgroundColor(isStart: isStart, isEnd: isEnd, inRange: inRange, isToday: isToday))

            if isStart || isEnd || isToday {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.brand.opacity(isStart || isEnd ? 0.9 : 0.5), lineWidth: 1)
                    .shadow(color: (isStart || isEnd) ? Color.brand.opacity(0.5) : .clear, radius: 4)
            }

            Text("\(cal.component(.day, from: date))")
                .font(.system(size: 13, weight: (isStart || isEnd || isToday) ? .semibold : .regular))
                .foregroundStyle(dayTextColor(isCurrentMonth: isCurrentMonth, isStart: isStart, isEnd: isEnd, inRange: inRange, isWeekend: isWeekend))

            // 透明点击层
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture {
                    handleDateTap(date)
                }
        }
        .frame(height: 36)
        .opacity(isCurrentMonth ? 1.0 : 0.3)
    }

    // MARK: - 日历交互逻辑

    /// 处理日期点击（酒店式范围选择）
    /// 第一次点击选起始日，第二次点击可在起始日之前或之后，自动按时间顺序排列为 [start, end]
    private func handleDateTap(_ date: Date) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)

        if rangeStart == nil || hasSelectedRange {
            // 第一次点击 或 已完成选择后重新开始
            rangeStart = day
            rangeEnd = nil
            hasSelectedRange = false
        } else {
            // 第二次点击：无论点击的日期在起始日之前还是之后，都形成范围
            if cal.isDate(day, inSameDayAs: rangeStart!) {
                // 点击同一天 → 查询单日
                rangeEnd = day
                hasSelectedRange = true
            } else if day > rangeStart! {
                // 点击更晚的日期 → 起始日为 start，该日为 end
                rangeEnd = day
                hasSelectedRange = true
            } else {
                // 点击更早的日期 → 该日为 start，原起始日为 end
                rangeEnd = rangeStart
                rangeStart = day
                hasSelectedRange = true
            }
        }
    }

    /// 判断日期是否在已选范围内（仅当范围已完成时）
    private func isInSelectedRange(_ date: Date, cal: Calendar) -> Bool {
        guard hasSelectedRange, let start = rangeStart, let end = rangeEnd else { return false }
        let day = cal.startOfDay(for: date)
        return day >= cal.startOfDay(for: start) && day <= cal.startOfDay(for: end)
    }

    /// 日期单元格文字颜色
    private func dayTextColor(isCurrentMonth: Bool, isStart: Bool, isEnd: Bool, inRange: Bool, isWeekend: Bool = false) -> Color {
        if isStart || isEnd { return Color.brand }
        if inRange { return Color.brand }
        if !isCurrentMonth { return .secondary }
        if isWeekend { return Color.brandAccent.opacity(0.85) }
        return .primary
    }

    /// 日期单元格背景颜色
    private func dayBackgroundColor(isStart: Bool, isEnd: Bool, inRange: Bool, isToday: Bool) -> Color {
        if isStart || isEnd { return Color.brand.opacity(0.18) }
        if inRange { return Color.brand.opacity(0.08) }
        if isToday { return Color.brand.opacity(0.08) }
        return .clear
    }

    /// 范围标签文案
    private func rangeLabel(_ start: Date, _ end: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDate(start, inSameDayAs: end) {
            f.dateFormat = "yyyy年M月d日"
            return "查询日期：\(f.string(from: start))"
        } else {
            f.dateFormat = "M月d日"
            return "查询范围：\(f.string(from: start)) - \(f.string(from: end))"
        }
    }

    /// 清除范围选择
    private func clearRangeSelection() {
        hasSelectedRange = false
        rangeStart = nil
        rangeEnd = nil
    }
}

// MARK: - 统计卡片（科技感赛博朋克风）
private struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .font(.system(size: 16))
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title2.bold()).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface(corner: Theme.Corner.medium, glow: true)
    }
}