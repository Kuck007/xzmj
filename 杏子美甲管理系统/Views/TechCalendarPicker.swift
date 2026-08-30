//
//  TechCalendarPicker.swift
//  杏子美甲管理系统
//
//  科技感日期时间选择组件（赛博朋克霓虹风，替代原生 DatePicker 的 graphical/stepperField）。
//  点击整个组件弹出 popover：
//    - 日期部分：自绘月度霓虹日历网格，支持标记"有预约的日期"、高亮今天/选中日
//    - 时间部分：自绘 时:分 霓虹步进器
//  颜色取自 DesignSystem 的品牌自适应色，自动跟随浅色（荧光粉）/深色（霓虹青）主题。
//

import SwiftUI

// MARK: - 日期格式化
private enum TechCalendarFmt {
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()
    static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年 M月"
        return f
    }()
}

// MARK: - 锚点组件
struct TechCalendarPicker: View {
    @Binding var selection: Date
    var displayedComponents: DatePickerComponents = [.date, .hourAndMinute]
    var label: String = ""
    var markedDays: Set<Date> = []

    @State private var showPopover = false

    private var autoCommitOnSelect: Bool {
        displayedComponents == [.date]
    }

    init(_ label: String = "",
         selection: Binding<Date>,
         displayedComponents: DatePickerComponents = [.date, .hourAndMinute],
         markedDays: Set<Date> = []) {
        self.label = label
        _selection = selection
        self.displayedComponents = displayedComponents
        self.markedDays = markedDays
    }

    private var displayText: String {
        if displayedComponents.contains(.hourAndMinute) {
            return TechCalendarFmt.dateTime.string(from: selection)
        }
        return TechCalendarFmt.date.string(from: selection)
    }

    var body: some View {
        Button {
            showPopover = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.brand)
                Text(displayText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.brand.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.brand.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            TechCalendarEditor(
                selection: $selection,
                displayedComponents: displayedComponents,
                markedDays: markedDays,
                isPresented: $showPopover,
                autoCommitOnSelect: autoCommitOnSelect
            )
        }
    }
}

// MARK: - 弹层编辑面板
struct TechCalendarEditor: View {
    @Binding var selection: Date
    let displayedComponents: DatePickerComponents
    let markedDays: Set<Date>
    @Binding var isPresented: Bool
    let autoCommitOnSelect: Bool

    @State private var displayedMonth: Date

    init(selection: Binding<Date>,
         displayedComponents: DatePickerComponents,
         markedDays: Set<Date>,
         isPresented: Binding<Bool>,
         autoCommitOnSelect: Bool) {
        _selection = selection
        self.displayedComponents = displayedComponents
        self.markedDays = markedDays
        _isPresented = isPresented
        self.autoCommitOnSelect = autoCommitOnSelect
        _displayedMonth = State(initialValue: selection.wrappedValue)
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_CN")
        c.firstWeekday = 2
        return c
    }

    var body: some View {
        VStack(spacing: 0) {
            if displayedComponents.contains(.date) {
                calendarPanel
            }
            if displayedComponents.contains(.hourAndMinute) {
                Divider()
                timePanel
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.brandSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.brand.opacity(0.25), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: Color.brand.opacity(0.18), radius: 14, y: 2)
    }

    // MARK: - 日历面板

    private var monthStart: Date {
        cal.date(from: cal.dateComponents([.year, .month], from: displayedMonth))!
    }
    private var daysInMonth: Int {
        cal.range(of: .day, in: .month, for: monthStart)!.count
    }
    private var leadingBlanks: Int {
        (cal.component(.weekday, from: monthStart) + 5) % 7
    }
    private let weekdayTitles = ["一", "二", "三", "四", "五", "六", "日"]

    private var cells: [Int?] {
        var arr: [Int?] = Array(repeating: nil, count: leadingBlanks)
        for d in 1...daysInMonth { arr.append(d) }
        return arr
    }

    private func dayDate(_ day: Int) -> Date {
        cal.date(byAdding: .day, value: day - 1, to: monthStart)!
    }

    private var monthTitle: String {
        TechCalendarFmt.monthTitle.string(from: displayedMonth)
    }

    private var calendarPanel: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.brandGradient)
                .frame(height: 3)
                .padding(.top, 10).padding(.horizontal, 14)

            HStack {
                Button { monthShift(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.brand)
                        .frame(width: 26, height: 26)
                        .background(Color.brand.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("上个月")

                Spacer()
                Text(monthTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()

                Button { monthShift(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.brand)
                        .frame(width: 26, height: 26)
                        .background(Color.brand.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("下个月")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(weekdayTitles.indices, id: \.self) { i in
                    Text(weekdayTitles[i])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(i >= 5 ? Color.brandAccent : Color.secondary)
                        .frame(height: 20)
                }
            }
            .padding(.horizontal, 12)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(cells.indices, id: \.self) { idx in
                    if let day = cells[idx] {
                        dayCell(day: day)
                    } else {
                        Color.clear.frame(height: 32)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Button {
                let today = Date()
                selection = today
                displayedMonth = today
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .foregroundStyle(Color.brand)
                    Text("返回今天")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.brand)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color.brand.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: 288)
    }

    private func monthShift(_ delta: Int) {
        displayedMonth = cal.date(byAdding: .month, value: delta, to: displayedMonth) ?? displayedMonth
    }

    private func dayCell(day: Int) -> some View {
        let date = dayDate(day)
        let isToday = cal.isDateInToday(date)
        let isSelected = cal.isDate(date, inSameDayAs: selection)
        let isMarked = markedDays.contains(cal.startOfDay(for: date))
        let isWeekend = isWeekendDay(date)

        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor(isSelected: isSelected, isToday: isToday))

            if isSelected || isToday {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.brand.opacity(isSelected ? 0.9 : 0.5), lineWidth: 1)
                    .shadow(color: isSelected ? Color.brand.opacity(0.5) : .clear, radius: 4)
            }

            VStack(spacing: 3) {
                Text("\(day)")
                    .font(.system(size: 13, weight: isSelected || isToday ? .semibold : .regular))
                    .foregroundStyle(textColor(isSelected: isSelected, isToday: isToday, isWeekend: isWeekend))
                if isMarked {
                    Circle().fill(Color.brand).frame(width: 4, height: 4)
                } else {
                    Spacer().frame(height: 4)
                }
            }

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture {
                    let h = cal.component(.hour, from: selection)
                    let m = cal.component(.minute, from: selection)
                    if let d = cal.date(bySettingHour: h, minute: m, second: 0, of: date) {
                        selection = d
                    } else {
                        selection = date
                    }
                    if autoCommitOnSelect {
                        isPresented = false
                    }
                }
        }
        .frame(height: 32)
    }

    private func isWeekendDay(_ date: Date) -> Bool {
        let w = cal.component(.weekday, from: date)
        return w == 1 || w == 7
    }

    private func backgroundColor(isSelected: Bool, isToday: Bool) -> Color {
        if isSelected { return Color.brand.opacity(0.18) }
        if isToday { return Color.brand.opacity(0.08) }
        return .clear
    }

    private func textColor(isSelected: Bool, isToday: Bool, isWeekend: Bool) -> Color {
        if isSelected || isToday { return Color.brand }
        if isWeekend { return Color.brandAccent.opacity(0.85) }
        return .primary
    }

    // MARK: - 时间面板

    private var timePanel: some View {
        let setHour: (Int) -> Void = { h in
            let hc = Swift.min(Swift.max(h, 0), 23)
            let m = cal.component(.minute, from: selection)
            if let d = cal.date(bySettingHour: hc, minute: m, second: 0, of: selection) {
                selection = d
            }
        }
        let setMinute: (Int) -> Void = { m in
            let mc = Swift.min(Swift.max(m, 0), 59)
            let h = cal.component(.hour, from: selection)
            if let d = cal.date(bySettingHour: h, minute: mc, second: 0, of: selection) {
                selection = d
            }
        }
        return HStack(spacing: 14) {
            NeoStepperUnit(
                label: "时",
                value: cal.component(.hour, from: selection),
                lowerBound: 0,
                upperBound: 23,
                onInc: { setHour((cal.component(.hour, from: selection) + 1) % 24) },
                onDec: { setHour((cal.component(.hour, from: selection) + 23) % 24) },
                onSet: { h in setHour(h) }
            )
            Text(":")
                .font(.title.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.brand)
            NeoStepperUnit(
                label: "分",
                value: cal.component(.minute, from: selection),
                lowerBound: 0,
                upperBound: 59,
                onInc: { setMinute((cal.component(.minute, from: selection) + 1) % 60) },
                onDec: { setMinute((cal.component(.minute, from: selection) + 59) % 60) },
                onSet: { m in setMinute(m) }
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 步进箭头
struct RepeatButton: View {
    let system: String
    let action: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.brand.opacity(0.10))

            Image(systemName: system)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.brand)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { action() }
        }
        .frame(width: 30, height: 20)
    }
}

// MARK: - 单个时/分步进单元
struct NeoStepperUnit: View {
    let label: String
    let value: Int
    let lowerBound: Int
    let upperBound: Int
    let onInc: () -> Void
    let onDec: () -> Void
    let onSet: (Int) -> Void

    @State private var editing = false
    @State private var editText = ""
    @FocusState private var numberFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            RepeatButton(system: "chevron.up", action: onInc)
                .help("\(label) +1")
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.brand.opacity(0.08))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(editing ? Color.brand : Color.brand.opacity(0.35), lineWidth: 1)

                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.brand)
                    .multilineTextAlignment(.center)
                    .frame(width: 48, height: 30)
                    .focused($numberFocused)
                    .opacity(editing ? 1 : 0)
                    .allowsHitTesting(editing)
                    .onChange(of: editText) { oldValue, newValue in
                        let allDigits = newValue.filter(\.isNumber)

                        if allDigits.isEmpty {
                            if !newValue.isEmpty { editText = "" }
                            return
                        }

                        let limitedDigits = String(allDigits.suffix(2))
                        let lastDigitStr = String(limitedDigits.last ?? "0")

                        if limitedDigits.count == 1 {
                            if let num = Int(lastDigitStr) {
                                if num < lowerBound || num > upperBound {
                                    editText = oldValue
                                } else if newValue != lastDigitStr {
                                    editText = lastDigitStr
                                }
                            }
                            return
                        }

                        if let num = Int(limitedDigits) {
                            if num >= lowerBound && num <= upperBound {
                                if newValue != limitedDigits {
                                    editText = limitedDigits
                                }
                            } else {
                                if let lastNum = Int(lastDigitStr),
                                   lastNum >= lowerBound, lastNum <= upperBound {
                                    editText = lastDigitStr
                                } else {
                                    editText = oldValue
                                }
                            }
                        } else {
                            editText = oldValue
                        }
                    }
                    .onSubmit { commit() }
                    .onChange(of: numberFocused) { _, focused in
                        if !focused { commit() }
                    }

                if !editing {
                    Text(String(format: "%02d", value))
                        .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.brand)
                        .frame(width: 48, height: 30)
                }

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.clear)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        if !editing { beginEdit() }
                    }
            }
            .frame(width: 48, height: 30)
            .onDisappear { commit() }
            RepeatButton(system: "chevron.down", action: onDec)
                .help("\(label) -1")
        }
    }

    private func beginEdit() {
        editText = "\(value)"
        editing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            numberFocused = true
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let raw = Int(editText.filter(\.isNumber)) ?? value
        let clamped = Swift.min(Swift.max(raw, lowerBound), upperBound)
        if clamped != value { onSet(clamped) }
    }
}
