//
//  DateField.swift
//  杏子美甲管理系统
//
//  一体式日期时间输入组件。
//  点击整个组件弹出 popover：
//    - 日期部分：系统 graphical 日历点选
//    - 时间部分：系统 wheel 滚轮选择
//  完全避免文本框与按钮对齐问题。
//

import SwiftUI

// MARK: - 主组件

struct DateField: View {
    @Binding var selection: Date
    var displayedComponents: DatePickerComponents = [.date, .hourAndMinute]
    var label: String

    @State private var showPopover = false

    init(_ label: String = "", selection: Binding<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.label = label
        _selection = selection
        self.displayedComponents = displayedComponents
    }

    private static let dateTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    private var displayText: String {
        if displayedComponents.contains(.hourAndMinute) {
            return Self.dateTimeFmt.string(from: selection)
        }
        return Self.dateFmt.string(from: selection)
    }

    var body: some View {
        Button {
            showPopover = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(displayText)
                    .font(.body)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                if displayedComponents.contains(.date) {
                    DatePicker(
                        "",
                        selection: $selection,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .labelsHidden()
                    .padding(8)
                }
                if displayedComponents.contains(.hourAndMinute) {
                    Divider()
                    HStack {
                        Text("时间")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DatePicker(
                            "",
                            selection: $selection,
                            displayedComponents: .hourAndMinute
                        )
                        .datePickerStyle(.stepperField)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                        .labelsHidden()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            
        }
    }
}
