//
//  AppointmentView.swift
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

struct AppointmentView: View {
    @Query(sort: \Appointment.startTime, order: .reverse) private var appointments: [Appointment]
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @Query private var services: [ServiceItem]
    @Query private var categories: [ServiceCategory]
    @Environment(\.modelContext) private var context
    @State private var selectedDay = Date()
    @State private var showingAdd = false
    @State private var pendingDelete: Appointment?
    @State private var deletePasswordAppt: Appointment?        // 已到店需密码删除
    @State private var showingDeletePassword = false
    @State private var needsSetupPassword = false
    @State private var editingAppointment: Appointment?       // 编辑（三点菜单触发）
    @State private var detailAppointment: Appointment?        // 详情（点击行触发）
    @State private var actionsForAppointment: Appointment?    // 三点菜单 sheet
    @State private var pendingArrive: Appointment?            // 到店确认弹窗
    @State private var arrivedToast: String?                  // 到店成功反馈

    private var dayAppointments: [Appointment] {
        let cal = Calendar.current
        return appointments.filter { cal.isDate($0.startTime, inSameDayAs: selectedDay) }
            .sorted { $0.startTime < $1.startTime }
    }
    private var customerMap: [UUID: Customer] { Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) }) }
    private var techMap: [UUID: Technician] { Dictionary(uniqueKeysWithValues: technicians.map { ($0.id, $0) }) }
    private var serviceMap: [UUID: ServiceItem] { Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) }) }
    private var categoryMap: [UUID: ServiceCategory] { Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) }) }

    private func serviceNames(for ids: [UUID]) -> [String] {
        ids.map { fullServiceName(for: $0, serviceMap: serviceMap, categoryMap: categoryMap) }
    }

    private var allAppointmentDays: [Date] {
        let cal = Calendar.current
        let daySet = Set(appointments.map { cal.startOfDay(for: $0.startTime) })
        return daySet.sorted()
    }

    private func shiftDay(_ delta: Int) {
        let cal = Calendar.current
        let currentDay = cal.startOfDay(for: selectedDay)
        if delta < 0 {
            // 上一个有记录的日子
            if let target = allAppointmentDays.last(where: { $0 < currentDay }) {
                selectedDay = target
            }
        } else {
            // 下一个有记录的日子
            if let target = allAppointmentDays.first(where: { $0 > currentDay }) {
                selectedDay = target
            }
        }
    }

    private var hasPrevAppointmentDay: Bool {
        let cal = Calendar.current
        let currentDay = cal.startOfDay(for: selectedDay)
        return allAppointmentDays.contains(where: { $0 < currentDay })
    }

    private var hasNextAppointmentDay: Bool {
        let cal = Calendar.current
        let currentDay = cal.startOfDay(for: selectedDay)
        return allAppointmentDays.contains(where: { $0 > currentDay })
    }

    var body: some View {
        // macOS NavigationSplitView 的 detail column 会自动处理 .navigationTitle/.toolbar/.searchable，NavigationStack 在 detail 里是冗余的，且会吃掉 sheet 首次 present 的进入动画
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TechCalendarPicker("选择日期", selection: $selectedDay, displayedComponents: .date, markedDays: Set(allAppointmentDays))
                    Spacer()
                    Text("\(dayAppointments.count) 个预约")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider().frame(height: 18)
                    Button {
                        shiftDay(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .help(hasPrevAppointmentDay ? "上一个有预约的日期" : "已是最早的预约日期")
                    .disabled(!hasPrevAppointmentDay)
                    Button {
                        shiftDay(1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .help(hasNextAppointmentDay ? "下一个有预约的日期" : "已是最晚的预约日期")
                    .disabled(!hasNextAppointmentDay)
                    Button {
                        selectedDay = Date()
                    } label: {
                        Text("今天")
                            .font(.caption.weight(.medium))
                            .help("返回今天")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
                if dayAppointments.isEmpty {
                    EmptyStateView(
                        systemImage: "calendar.badge.exclamationmark",
                        title: "当日无预约",
                        message: "点击右上角「新增预约」为客户安排时间"
                    )
                } else {
                    List {
                        ForEach(dayAppointments) { appt in
                            AppointmentRow(
                                appt: appt,
                                customerName: customerMap[appt.customerId]?.name ?? "未知客户",
                                techName: techMap[appt.technicianId]?.name ?? "未知技师",
                                serviceNames: serviceNames(for: appt.serviceItemIds),
                                onTap: { detailAppointment = appt },
                                onArrive: { pendingArrive = appt },
                                onShowActions: { actionsForAppointment = appt }
                            )
                            .swipeActions {
                                Button("删除", role: .destructive) { requestDelete(appt) }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("预约排班")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Text("添加预约")
                    }
                    .buttonStyle(BrandPrimaryButtonStyle())
                    .disabled(customers.isEmpty || technicians.isEmpty || services.isEmpty)
                }
            }
            .sheet(isPresented: $showingAdd) {
                AppointmentFormView { context.insert($0) }
                    
            }
            // 详情 sheet（点击行触发）
            .sheet(isPresented: Binding(
                get: { detailAppointment != nil },
                set: { if !$0 { detailAppointment = nil } }
            )) {
                if let appt = detailAppointment {
                    AppointmentDetailView(appt: appt, onEdit: {
                        detailAppointment = nil
                        editingAppointment = appt
                    })
                }
                
            }
            // 编辑 sheet
            .sheet(isPresented: Binding(
                get: { editingAppointment != nil },
                set: { if !$0 { editingAppointment = nil } }
            )) {
                if let appt = editingAppointment {
                    AppointmentFormView(appt: appt) { _ in }
                }
                
            }
            // 三点菜单 sheet
            .sheet(isPresented: Binding(
                get: { actionsForAppointment != nil },
                set: { if !$0 { actionsForAppointment = nil } }
            )) {
                if let appt = actionsForAppointment {
                    AppointmentActionsSheet(
                        appt: appt,
                        onEdit: {
                            actionsForAppointment = nil
                            editingAppointment = appt
                        },
                        onDelete: {
                            actionsForAppointment = nil
                            requestDelete(appt)
                        }
                    )
                }
                
            }
            .alert("删除预约？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let appt = pendingDelete { context.delete(appt) }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("该预约将被永久删除，无法恢复。")
            }
            .alert("需要设置密码", isPresented: $needsSetupPassword) {
                Button("确定", role: .cancel) { }
            } message: {
                Text("删除已到店的预约需要先在「设置」中设置密码。")
            }
            .sheet(isPresented: $showingDeletePassword) {
                PasswordConfirmSheet(
                    title: "确认删除已到店预约？",
                    message: "该预约已到店。删除后此操作不可撤销。",
                    confirmTitle: "删除",
                    destructive: true
                ) {
                    if let appt = deletePasswordAppt { context.delete(appt) }
                    deletePasswordAppt = nil
                }
                
            }
            .alert("确认到店？", isPresented: Binding(
                get: { pendingArrive != nil },
                set: { if !$0 { pendingArrive = nil } }
            )) {
                Button("确认到店", role: .destructive) {
                    if let appt = pendingArrive { confirmArrival(appt) }
                }
                Button("取消", role: .cancel) { pendingArrive = nil }
            } message: {
                if let appt = pendingArrive {
                    let name = customerMap[appt.customerId]?.name ?? "未知客户"
                    return Text("将记录「\(name)」的实际到店时间，并自动创建一条服务记录以便继续填写服务内容。")
                }
                return Text("将记录实际到店时间，并自动创建一条服务记录。")
            }
            // 到店成功反馈
            .overlay(alignment: .top) {
                if let msg = arrivedToast {
                    Text(msg)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.green, in: Capsule())
                        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                withAnimation { arrivedToast = nil }
                            }
                        }
                }
            }
        }
    }

    // MARK: - 删除请求（已到店的预约需密码验证）
    private func requestDelete(_ appt: Appointment) {
        guard appt.arrivedAt != nil else {
            pendingDelete = appt   // 未到店，普通确认删除
            return
        }
        if SecurityManager.shared.hasPassword {
            deletePasswordAppt = appt
            showingDeletePassword = true
        } else {
            needsSetupPassword = true
        }
    }

    // MARK: - 到店确认逻辑
    private func confirmArrival(_ appt: Appointment) {
        appt.arrivedAt = Date()
        appt.status = "已到店"
        // 自动创建一条服务记录，把预约信息转过去
        let record = NailServiceRecord(
            customerId: appt.customerId,
            technicianId: appt.technicianId,
            serviceDate: appt.arrivedAt!,
            serviceItemIds: appt.serviceItemIds,
            reminderId: appt.reminderId
        )
        context.insert(record)
        let name = customerMap[appt.customerId]?.name ?? "客户"
        arrivedToast = "「\(name)」已到店，已创建服务记录"
        pendingArrive = nil
    }
}

// MARK: - 预约行
struct AppointmentRow: View {
    let appt: Appointment
    let customerName: String
    let techName: String
    let serviceNames: [String]
    var onTap: () -> Void
    var onArrive: () -> Void
    var onShowActions: () -> Void

    private var statusColor: Color {
        switch appt.status {
        case "已完成": return .green
        case "已取消": return .red
        case "已到店": return .blue
        default: return .orange        // "已预约"
        }
    }

    var body: some View {
        HoverHighlightRow {
            HStack(spacing: 0) {
            // 左侧主信息（点击查看详情）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(timeStr(appt.startTime) + " – " + timeStr(appt.endTime))
                        .font(.headline).foregroundStyle(.primary)
                    Text(appt.status)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(statusColor.opacity(0.12), in: Capsule())
                    if let arrived = appt.arrivedAt {
                        Text("到店 " + timeStr(arrived))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Label(customerName, systemImage: "person")
                        .foregroundStyle(.primary)
                    Spacer()
                    Label(techName, systemImage: "person.crop.square")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                if !serviceNames.isEmpty {
                    Text(serviceNames.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            // 右侧操作区：到店按钮 + 三点
            HStack(spacing: 6) {
                if appt.status == "已预约" {
                    Button {
                        onArrive()
                    } label: {
                        Label("到店", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
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
        }
            .padding(.vertical, 6)
        }
    }

    private func timeStr(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - 三点操作菜单 Sheet
struct AppointmentActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let appt: Appointment
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("预约操作").font(.headline)
                    Text(appt.startTime.cnDateTime)
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
            }
            .padding(.bottom, 8)
            Divider()

            Button {
                dismiss()
                onEdit()
            } label: {
                HStack { Text("修改预约"); Spacer(); Image(systemName: "pencil") }
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
                HStack { Text("删除预约"); Spacer(); Image(systemName: "trash") }
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

// MARK: - 预约详情（可编辑每个字段）
struct AppointmentDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @Query private var services: [ServiceItem]
    @Query private var categories: [ServiceCategory]
    let appt: Appointment
    var onEdit: () -> Void

    @State private var showingDeletePassword = false
    @State private var needsSetupPassword = false

    private var customerMap: [UUID: Customer] { Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) }) }
    private var techMap: [UUID: Technician] { Dictionary(uniqueKeysWithValues: technicians.map { ($0.id, $0) }) }
    private var serviceMap: [UUID: ServiceItem] { Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) }) }
    private var categoryMap: [UUID: ServiceCategory] { Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) }) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("基本信息") {
                    LabeledContent("客户", value: customerMap[appt.customerId]?.name ?? "未知")
                    LabeledContent("技师", value: techMap[appt.technicianId]?.name ?? "未知")
                    LabeledContent("状态", value: appt.status)
                    LabeledContent("预约到店时间", value: appt.startTime.cnDateTime)
                    LabeledContent("预计结束", value: appt.endTime.cnDateTime)
                    if appt.arrivedAt != nil {
                        LabeledContent("实际到店时间", value: appt.arrivedAt!.cnDateTime)
                    }
                }

                Section("服务项目（\(appt.serviceItemIds.count)）") {
                    if appt.serviceItemIds.isEmpty {
                        Text("无项目").foregroundStyle(.secondary).font(.caption)
                    } else {
                        ForEach(appt.serviceItemIds, id: \.self) { sid in
                            HStack {
                                if let s = serviceMap[sid] {
                                    Text(fullServiceName(for: sid, serviceMap: serviceMap, categoryMap: categoryMap))
                                    Spacer()
                                    Text("¥" + String(format: "%.0f", s.price) + " · \(s.durationMinutes)分")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("已删除项目").foregroundStyle(.secondary).font(.caption)
                                }
                            }
                        }
                    }
                }

                Section("备注") {
                    if let n = appt.notes, !n.isEmpty {
                        Text(n)
                    } else {
                        Text("无").foregroundStyle(.secondary).font(.caption)
                    }
                }

                Section("创建时间") {
                    LabeledContent("创建于", value: appt.createdAt.cnDateTime)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("删除预约", role: .destructive) {
                    if appt.arrivedAt != nil {
                        if SecurityManager.shared.hasPassword {
                            showingDeletePassword = true
                        } else {
                            needsSetupPassword = true
                        }
                    } else {
                        dismiss()
                        context.delete(appt)
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("编辑") { onEdit() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 480, idealHeight: 560, maxHeight: 750)
        .alert("需要设置密码", isPresented: $needsSetupPassword) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("删除已到店的预约需要先在「设置」中设置密码。")
        }
        .sheet(isPresented: $showingDeletePassword) {
            PasswordConfirmSheet(
                title: "确认删除已到店预约？",
                message: "该预约已到店。删除后此操作不可撤销。",
                confirmTitle: "删除",
                destructive: true
            ) {
                dismiss()
                context.delete(appt)
            }
            
        }
    }
}

// MARK: - 密码输入确认弹窗（内容可实时刷新，用于删除校验）
struct PasswordConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    var message: String
    var confirmTitle: String = "确认"
    var destructive: Bool = true
    var onConfirm: () -> Void
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SecureField("输入密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(destructive ? .red : .accentColor)
            }
        }
        .padding(22)
        .frame(width: 340)
    }

    private func submit() {
        guard SecurityManager.shared.verifyPassword(password) else {
            error = "密码错误"
            return
        }
        dismiss()
        onConfirm()
    }
}

// MARK: - 预约表单预填数据（从补睫提醒发起预约时使用）
struct AppointmentPrefillData {
    var customerId: UUID
    var startTime: Date
    var defaultServiceItemIds: [UUID] = []
    var reminderId: UUID? = nil
}

// MARK: - 预约表单（新增 / 编辑共用）
struct AppointmentFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @Query private var services: [ServiceItem]
    @Query private var categories: [ServiceCategory]
    var appt: Appointment?
    var prefill: AppointmentPrefillData?
    var onSave: (Appointment) -> Void

    @State private var customerId: UUID?
    @State private var technicianId: UUID?
    @State private var selectedServices: Set<UUID> = []
    @State private var startTime = Date()
    @State private var notes: String = ""
    @State private var didPrefill = false
    @State private var reminderId: UUID? = nil
    @State private var arrivedDraft: Date? = nil
    // 快速新增客户
    @State private var quickName = ""
    @State private var quickPhone = ""
    @State private var showingQuickAddConfirm = false

    private var totalMinutes: Int {
        services.filter { selectedServices.contains($0.id) }.reduce(0) { $0 + $1.durationMinutes }
    }
    private var endTime: Date {
        Calendar.current.date(byAdding: .minute, value: totalMinutes, to: startTime) ?? startTime
    }
    private var serviceMap: [UUID: ServiceItem] { Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) }) }
    private var categoryMap: [UUID: ServiceCategory] { Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) }) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("客户") {
                    CustomerField(customerId: $customerId, customers: customers)
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
                Picker("技师", selection: $technicianId) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(technicians.filter(\.isActive)) { Text($0.name).tag(Optional($0.id)) }
                }
                LabeledContent("预约到店时间") {
                    TechCalendarPicker(
                        "", 
                        selection: $startTime, 
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                
                // 仅在编辑模式下显示“实际到店时间”
                if appt != nil {
                    LabeledContent("实际到店时间") {
                        if arrivedDraft != nil {
                            TechCalendarPicker(
                                "", 
                                selection: Binding(
                                    get: { arrivedDraft ?? Date() },
                                    set: { arrivedDraft = $0 }
                                ), 
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        } else {
                            Button {
                                arrivedDraft = Date()
                            } label: {
                                Text("设置到店时间")
                                    .foregroundStyle(Color.brand)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("服务项目（多选）") {
                    if services.isEmpty {
                        Text("请先在服务项目模块添加项目").foregroundStyle(.secondary).font(.caption)
                    } else {
                        CollapsibleServiceMultiSelect(
                            services: services,
                            categories: categories,
                            selectedIds: $selectedServices
                        ) { s in
                            Text("¥" + String(format: "%.0f", s.price) + " · \(s.durationMinutes)分")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if totalMinutes > 0 {
                    LabeledContent("预计结束", value: endTime.formatted(date: .omitted, time: .shortened))
                }
                Section("备注") {
                    TextField("预约备注", text: $notes, axis: .vertical).lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button(appt == nil ? "保存" : "更新") { save() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(customerId == nil || technicianId == nil || selectedServices.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 500, minHeight: 480, idealHeight: 560, maxHeight: 750)
        .alert("确认新增客户？", isPresented: $showingQuickAddConfirm) {
            Button("取消", role: .cancel) { }
            Button("确认") {
                createQuickCustomer()
            }
        } message: {
            Text("将创建客户「\(quickName)」\(quickPhone.isEmpty ? "" : " · \(quickPhone)")")
        }
        .onAppear { load() }
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

    private func load() {
        if let a = appt {
            customerId = a.customerId
            technicianId = a.technicianId
            selectedServices = Set(a.serviceItemIds)
            startTime = a.startTime
            notes = a.notes ?? ""
            arrivedDraft = a.arrivedAt
            didPrefill = true
            return
        }
        guard !didPrefill, let p = prefill else { return }
        didPrefill = true
        customerId = p.customerId
        startTime = p.startTime
        selectedServices = Set(p.defaultServiceItemIds)
        reminderId = p.reminderId
    }

    private func save() {
        guard let cid = customerId, let tid = technicianId else { return }
        if let a = appt {
            a.customerId = cid
            a.technicianId = tid
            a.serviceItemIds = Array(selectedServices)
            a.startTime = startTime
            a.endTime = endTime
            a.notes = notes.isEmpty ? nil : notes
            a.arrivedAt = arrivedDraft
            onSave(a)
        } else {
            let a = Appointment(customerId: cid, technicianId: tid,
                                serviceItemIds: Array(selectedServices),
                                startTime: startTime, endTime: endTime,
                                notes: notes.isEmpty ? nil : notes,
                                reminderId: reminderId)
            onSave(a)
        }
        dismiss()
    }
}
