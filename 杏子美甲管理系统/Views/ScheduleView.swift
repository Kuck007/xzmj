//
//  ScheduleView.swift
//  杏子美甲管理系统
//
//  日程总览模块：月视图（哪几天有预约）+ 日视图（每个技师的24小时时间轴）
//  只读展示，预约的添加/编辑在「预约排班」模块完成。
//

import SwiftUI
import SwiftData

// MARK: - 日程主视图

struct ScheduleView: View {
    @Query(sort: \Appointment.startTime) private var appointments: [Appointment]
    @Query private var technicians: [Technician]
    @Query private var customers: [Customer]
    @Query private var serviceItems: [ServiceItem]

    @State private var mode: ScheduleMode = .month
    @State private var selectedDate = Date()
    @State private var currentMonth = Date()
    @State private var selectedAppointment: Appointment?

    private var activeTechnicians: [Technician] {
        technicians.filter { $0.isActive }.sorted { $0.name < $1.name }
    }

    private var customerMap: [UUID: Customer] {
        Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) })
    }

    private var serviceMap: [UUID: ServiceItem] {
        Dictionary(uniqueKeysWithValues: serviceItems.map { ($0.id, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            ScheduleToolbar(
                mode: $mode,
                date: mode == .month ? currentMonth : selectedDate,
                onPrev: { navigate(-1) },
                onNext: { navigate(1) },
                onToday: goToday
            )

            Divider()

            if mode == .month {
                MonthScheduleView(
                    month: currentMonth,
                    appointments: appointments,
                    onSelectDate: { date in
                        selectedDate = date
                        mode = .day
                    }
                )
            } else {
                DayScheduleView(
                    date: selectedDate,
                    appointments: appointments,
                    technicians: activeTechnicians,
                    customerMap: customerMap,
                    serviceMap: serviceMap,
                    onSelectAppointment: { apt in
                        selectedAppointment = apt
                    }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedAppointment != nil },
            set: { if !$0 { selectedAppointment = nil } }
        )) {
            if let apt = selectedAppointment {
                AppointmentDetailSheet(
                    appointment: apt,
                    customer: customerMap[apt.customerId],
                    technician: technicians.first(where: { $0.id == apt.technicianId }),
                    serviceMap: serviceMap
                )
                .frame(minWidth: 420, minHeight: 380)
            }
        }
    }

    private func navigate(_ delta: Int) {
        if mode == .month {
            currentMonth = Calendar.current.date(byAdding: .month, value: delta, to: currentMonth) ?? currentMonth
        } else {
            selectedDate = Calendar.current.date(byAdding: .day, value: delta, to: selectedDate) ?? selectedDate
        }
    }

    private func goToday() {
        let now = Date()
        currentMonth = now
        selectedDate = now
    }
}

enum ScheduleMode {
    case month, day
}

// MARK: - 顶部工具栏

private struct ScheduleToolbar: View {
    @Binding var mode: ScheduleMode
    let date: Date
    let onPrev: () -> Void
    let onNext: () -> Void
    let onToday: () -> Void

    private var title: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if mode == .month {
            f.dateFormat = "yyyy年M月"
        } else {
            f.dateFormat = "yyyy年M月d日 EEEE"
        }
        return f.string(from: date)
    }

    var body: some View {
        HStack(spacing: 12) {
            // 月/日切换
            Picker("", selection: $mode) {
                Text("月视图").tag(ScheduleMode.month)
                Text("日视图").tag(ScheduleMode.day)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Spacer()

            // 日期导航
            Button(action: onPrev) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(Color.secondary.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Circle())

            Text(title)
                .font(.system(size: 22, weight: .bold))
                .frame(minWidth: 200)

            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(Color.secondary.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Circle())

            Button("今天") { onToday() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 月视图

private struct MonthScheduleView: View {
    let month: Date
    let appointments: [Appointment]
    let onSelectDate: (Date) -> Void

    private let calendar = Calendar.current

    private var daysInMonth: [Date?] {
        let interval = calendar.dateInterval(of: .month, for: month)!
        // weekday: 1=周日, 2=周一 ... 转为周一开头的偏移量
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let offset = (firstWeekday + 5) % 7
        let days = calendar.range(of: .day, in: .month, for: month)!

        var result: [Date?] = Array(repeating: nil, count: offset)
        for day in days {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: interval.start) {
                result.append(date)
            }
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private func appointmentCount(for date: Date) -> Int {
        appointments.filter { apt in
            calendar.isDate(apt.startTime, inSameDayAs: date) && apt.status != "已取消"
        }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 星期头
                HStack(spacing: 0) {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                        Text(day)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                Divider()

                // 日期网格
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7),
                    spacing: 1
                ) {
                    ForEach(Array(daysInMonth.enumerated()), id: \.offset) { _, date in
                        if let date = date {
                            MonthDayCell(
                                date: date,
                                count: appointmentCount(for: date),
                                onTap: { onSelectDate(date) }
                            )
                        } else {
                            Color.clear.frame(minHeight: 90)
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct MonthDayCell: View {
    let date: Date
    let count: Int
    let onTap: () -> Void
    @State private var isHovering = false

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text("\(Calendar.current.component(.day, from: date))日")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isToday ? Color.brand : .primary)
                    .padding(.top, 8)

                Spacer(minLength: 0)

                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Circle().fill(Color.brand))
                        .padding(.bottom, 8)
                } else {
                    Color.clear.frame(height: 20)
                        .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isToday ? Color.brand.opacity(0.1) : (isHovering ? Color.brand.opacity(0.08) : Color.brandBackground.opacity(0.4)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isToday ? Color.brand : (isHovering ? Color.brand.opacity(0.6) : Color.clear), lineWidth: isToday ? 1.5 : (isHovering ? 1 : 0))
            )
            .shadow(color: isHovering ? Color.brand.opacity(0.25) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: hovering ? 0.02 : 0.6)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - 日视图（24小时时间轴 + 技师列）

private struct DayScheduleView: View {
    let date: Date
    let appointments: [Appointment]
    let technicians: [Technician]
    let customerMap: [UUID: Customer]
    let serviceMap: [UUID: ServiceItem]
    let onSelectAppointment: (Appointment) -> Void

    private let calendar = Calendar.current

    private var dayStart: Date {
        calendar.startOfDay(for: date)
    }

    private var dayEnd: Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart)!
    }

    /// 筛选与某天某技师有时间交集的预约（已取消的排除），计算当天可见部分
    private func visibleAppointments(for technician: Technician) -> [VisibleAppointment] {
        appointments.compactMap { apt in
            guard apt.technicianId == technician.id else { return nil }
            guard apt.status != "已取消" else { return nil }
            let visibleStart = max(apt.startTime, dayStart)
            let visibleEnd = min(apt.endTime, dayEnd)
            guard visibleStart < visibleEnd else { return nil }
            return VisibleAppointment(
                appointment: apt,
                visibleStart: visibleStart,
                visibleEnd: visibleEnd,
                startsBeforeDay: apt.startTime < dayStart,
                endsAfterDay: apt.endTime > dayEnd
            )
        }
    }

    var body: some View {
        GeometryReader { geo in
            let available = max(geo.size.height - 44, 0)
            let dynamicHourHeight = max(available / 12, 24)
            let lineColor = Color.primary.opacity(0.18)

            // 水平滚动包裹整体，技师表头固定在顶部不随垂直滚动消失
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    // === 固定表头行（无竖线框）===
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 60, height: 44) // 时间轴列占位

                        ForEach(technicians) { tech in
                            TechnicianHeader(technician: tech)
                                .frame(width: 150, height: 44)
                        }
                        if technicians.isEmpty {
                            Text("暂无在职技师")
                                .foregroundStyle(.secondary)
                                .frame(width: 200, height: 44)
                        }
                    }
                    Rectangle().fill(lineColor).frame(height: 1)

                    // === 垂直滚动内容区 ===
                    ScrollView(.vertical) {
                        HStack(spacing: 0) {
                            // 时间轴列（仅文字，无横线）
                            VStack(spacing: 0) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text(String(format: "%02d:00", hour))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary.opacity(0.85))
                                        .frame(width: 48, alignment: .trailing)
                                        .padding(.trailing, 6)
                                        .offset(y: -2) // 微调上移，与右侧横线对齐
                                        .frame(width: 60, height: dynamicHourHeight, alignment: .top)
                                }
                            }
                            .frame(width: 60)

                            Rectangle().fill(lineColor).frame(width: 1)

                            // 技师网格列（有横线+竖线）
                            ForEach(technicians) { tech in
                                TechnicianGrid(
                                    technician: tech,
                                    appointments: visibleAppointments(for: tech),
                                    customerMap: customerMap,
                                    serviceMap: serviceMap,
                                    hourHeight: dynamicHourHeight,
                                    dayStart: dayStart,
                                    lineColor: lineColor,
                                    onSelect: onSelectAppointment
                                )
                                .frame(width: 150, height: 24 * dynamicHourHeight)
                                Rectangle().fill(lineColor).frame(width: 1)
                            }
                        }
                        .frame(height: 24 * dynamicHourHeight)
                    }
                }
            }
        }
    }
}

/// 技师表头（固定在顶部）
private struct TechnicianHeader: View {
    let technician: Technician

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.brand.opacity(0.15))
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.brand)
                )
            Text(technician.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .background(Color.brand.opacity(0.06))
    }
}

/// 某天可见的预约片段（处理跨天：只显示当天部分）
private struct VisibleAppointment: Identifiable {
    let appointment: Appointment
    let visibleStart: Date
    let visibleEnd: Date
    let startsBeforeDay: Bool  // 前一天开始，跨到今天
    let endsAfterDay: Bool     // 今天开始，跨到明天

    var id: PersistentIdentifier { appointment.persistentModelID }
}

/// 技师日视图网格（仅网格，不含表头）
private struct TechnicianGrid: View {
    let technician: Technician
    let appointments: [VisibleAppointment]
    let customerMap: [UUID: Customer]
    let serviceMap: [UUID: ServiceItem]
    let hourHeight: CGFloat
    let dayStart: Date
    let lineColor: Color
    let onSelect: (Appointment) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            // 小时分隔线（固定高度）
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Rectangle().fill(lineColor).frame(height: 1)
                    Color.clear.frame(height: hourHeight - 1)
                }
                Rectangle().fill(lineColor).frame(height: 1)
            }

            // 预约块
            ForEach(appointments) { va in
                AppointmentBlock(
                    visible: va,
                    customer: customerMap[va.appointment.customerId],
                    serviceMap: serviceMap,
                    hourHeight: hourHeight,
                    dayStart: dayStart,
                    onSelect: { onSelect(va.appointment) }
                )
            }
        }
    }
}

private struct AppointmentBlock: View {
    let visible: VisibleAppointment
    let customer: Customer?
    let serviceMap: [UUID: ServiceItem]
    let hourHeight: CGFloat
    let dayStart: Date
    let onSelect: () -> Void

    private var offsetY: CGFloat {
        let minutes = visible.visibleStart.timeIntervalSince(dayStart) / 60
        return CGFloat(minutes / 60.0) * hourHeight
    }

    private var blockHeight: CGFloat {
        let minutes = visible.visibleEnd.timeIntervalSince(visible.visibleStart) / 60
        return max(CGFloat(minutes / 60.0) * hourHeight, 26)
    }

    private var statusColor: Color {
        switch visible.appointment.status {
        case "已到店": return Color.brand
        case "已完成": return Color.gray
        default: return Color.brand.opacity(0.55)
        }
    }

    private var serviceSummary: String {
        let names = visible.appointment.serviceItemIds.compactMap { serviceMap[$0]?.name }
        return names.joined(separator: "、")
    }

    private var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: visible.appointment.startTime))-\(f.string(from: visible.appointment.endTime))"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 1) {
                if visible.startsBeforeDay {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.left")
                        Text("前日开始")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.85))
                }

                Text(customer?.name ?? "未知客户")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if blockHeight > 40 {
                    Text(serviceSummary)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                }

                if blockHeight > 60 {
                    Text(timeText)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.75))
                }

                if visible.endsAfterDay {
                    HStack(spacing: 2) {
                        Text("跨至次日")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: blockHeight)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(statusColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.white.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .offset(y: offsetY)
        .padding(.horizontal, 3)
    }
}

// MARK: - 预约详情 Sheet

private struct AppointmentDetailSheet: View {
    let appointment: Appointment
    let customer: Customer?
    let technician: Technician?
    let serviceMap: [UUID: ServiceItem]
    @Environment(\.dismiss) private var dismiss

    private var serviceNames: String {
        appointment.serviceItemIds.compactMap { serviceMap[$0]?.name }.joined(separator: "、")
    }

    private var timeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return "\(f.string(from: appointment.startTime)) ~ \(f.string(from: appointment.endTime))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("预约详情").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            Form {
                Section("基本信息") {
                    LabeledContent("客户", value: customer?.name ?? "未知")
                    LabeledContent("技师", value: technician?.name ?? "未分配")
                    LabeledContent("服务项目", value: serviceNames.isEmpty ? "无" : serviceNames)
                    LabeledContent("时间", value: timeText)
                    LabeledContent("状态", value: appointment.status)
                }
                if let notes = appointment.notes, !notes.isEmpty {
                    Section("备注") {
                        Text(notes).font(.caption)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }
}
