//
//  ServiceRecordView.swift
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

// MARK: - 服务记录行
struct ServiceRecordRow: View {
    let record: NailServiceRecord
    let customerName: String
    let techName: String
    let serviceNames: [String]
    var onTap: () -> Void
    var onShowActions: () -> Void

    var body: some View {
        HoverHighlightRow {
            HStack(spacing: 0) {
            // 左侧主信息（全行点击查看详情）
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(customerName + " · " + techName)
                        .font(.title3).foregroundStyle(.primary)
                    Spacer()
                    if record.isPaid {
                        Text("已付款")
                            .font(.caption).foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    } else {
                        Text("未付款")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if record.hasConstruction {
                        Text("建构")
                            .font(.caption).foregroundStyle(Color.brand)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.brand.opacity(0.1), in: Capsule())
                    }
                    if record.isArchived {
                        Text("已归档")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(record.serviceDate.cnDateTime)
                    .font(.subheadline).foregroundStyle(.secondary)
                if !serviceNames.isEmpty {
                    Text(serviceNames.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            // 右侧三点按钮
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

// MARK: - 服务记录视图
struct ServiceRecordView: View {
    @Query(sort: \NailServiceRecord.serviceDate, order: .reverse) private var records: [NailServiceRecord]
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @Query private var services: [ServiceItem]
    @Query private var categories: [ServiceCategory]
    @Environment(\.modelContext) private var context
    @State private var selectedDay = Date()
    @State private var showingAdd = false
    @State private var selectedRecord: NailServiceRecord?
    @State private var pendingDelete: NailServiceRecord?
    @State private var actionsForRecord: NailServiceRecord?
    @State private var editingRecord: NailServiceRecord?
    // 跨模块跳转：跳转收银
    var onCheckout: ((NailServiceRecord) -> Void)?

    private var dayRecords: [NailServiceRecord] {
        let cal = Calendar.current
        return records.filter { cal.isDate($0.serviceDate, inSameDayAs: selectedDay) }
            .sorted { $0.serviceDate < $1.serviceDate }
    }

    private var customerMap: [UUID: Customer] { Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) }) }
    private var techMap: [UUID: Technician] { Dictionary(uniqueKeysWithValues: technicians.map { ($0.id, $0) }) }
    private var serviceMap: [UUID: ServiceItem] { Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) }) }
    private var categoryMap: [UUID: ServiceCategory] { Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) }) }

    private func serviceNames(for ids: [UUID]) -> [String] {
        ids.map { fullServiceName(for: $0, serviceMap: serviceMap, categoryMap: categoryMap) }
    }

    private var allRecordDays: [Date] {
        let cal = Calendar.current
        let daySet = Set(records.map { cal.startOfDay(for: $0.serviceDate) })
        return daySet.sorted()
    }

    private func shiftDay(_ delta: Int) {
        let cal = Calendar.current
        let currentDay = cal.startOfDay(for: selectedDay)
        if delta < 0 {
            // 上一个有记录的日子
            if let target = allRecordDays.last(where: { $0 < currentDay }) {
                selectedDay = target
            }
        } else {
            // 下一个有记录的日子
            if let target = allRecordDays.first(where: { $0 > currentDay }) {
                selectedDay = target
            }
        }
    }

    private var hasPrevRecordDay: Bool {
        let cal = Calendar.current
        let currentDay = cal.startOfDay(for: selectedDay)
        return allRecordDays.contains(where: { $0 < currentDay })
    }

    private var hasNextRecordDay: Bool {
        let cal = Calendar.current
        let currentDay = cal.startOfDay(for: selectedDay)
        return allRecordDays.contains(where: { $0 > currentDay })
    }

    var body: some View {
        // macOS NavigationSplitView 的 detail column 会自动处理 .navigationTitle/.toolbar/.searchable，NavigationStack 在 detail 里是冗余的，且会吃掉 sheet 首次 present 的进入动画
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TechCalendarPicker("选择日期", selection: $selectedDay, displayedComponents: .date)
                    Spacer()
                    Text("\(dayRecords.count) 条记录")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider().frame(height: 18)
                    Button {
                        shiftDay(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .help(hasPrevRecordDay ? "上一个有记录的日期" : "已是最早的记录日期")
                    .disabled(!hasPrevRecordDay)
                    Button {
                        shiftDay(1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .help(hasNextRecordDay ? "下一个有记录的日期" : "已是最晚的记录日期")
                    .disabled(!hasNextRecordDay)
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
                if dayRecords.isEmpty {
                    EmptyStateView(
                        systemImage: "photo.on.rectangle",
                        title: "当日无服务记录",
                        message: "点击右上角「新增记录」为客户创建美甲档案"
                    )
                } else {
                    List {
                        ForEach(dayRecords) { r in
                            ServiceRecordRow(
                                record: r,
                                customerName: customerMap[r.customerId]?.name ?? "未知客户",
                                techName: techMap[r.technicianId]?.name ?? "未知技师",
                                serviceNames: serviceNames(for: r.serviceItemIds),
                                onTap: { selectedRecord = r },
                                onShowActions: { actionsForRecord = r }
                            )
                            .swipeActions { Button("删除", role: .destructive) { pendingDelete = r } }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("服务记录")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Text("新增记录")
                    }
                    .buttonStyle(BrandPrimaryButtonStyle())
                    .disabled(customers.isEmpty || technicians.isEmpty || services.isEmpty)
                }
            }
            .sheet(isPresented: $showingAdd) {
                ServiceRecordFormView { context.insert($0) }
                    
            }
            .sheet(isPresented: Binding(get: { selectedRecord != nil }, set: { if !$0 { selectedRecord = nil } })) {
                if let record = selectedRecord {
                    ServiceRecordDetailView(record: record, onCheckout: { rec in
                        selectedRecord = nil
                        onCheckout?(rec)
                    })
                }
                
            }
            // 三点菜单
            .sheet(isPresented: Binding(get: { actionsForRecord != nil }, set: { if !$0 { actionsForRecord = nil } })) {
                if let record = actionsForRecord {
                    ServiceRecordActionsSheet(
                        record: record,
                        onEdit: {
                            actionsForRecord = nil
                            editingRecord = record
                        },
                        onDelete: {
                            actionsForRecord = nil
                            pendingDelete = record
                        }
                    )
                }
                
            }
            // 编辑
            .sheet(isPresented: Binding(get: { editingRecord != nil }, set: { if !$0 { editingRecord = nil } })) {
                if let record = editingRecord {
                    ServiceRecordFormView(record: record) { _ in }
                }
                    
            }
            .alert("删除服务记录？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let r = pendingDelete { context.delete(r) }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("该服务记录将被永久删除，无法恢复。")
            }
        }
    }
}

// MARK: - 三点操作菜单
struct ServiceRecordActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: NailServiceRecord
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("记录操作").font(.headline)
                    Text(record.serviceDate.cnDateTime)
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

            if !record.isPaid {
                Button {
                    dismiss()
                    onEdit()
                } label: {
                    HStack { Text("修改记录"); Spacer(); Image(systemName: "pencil") }
                        .padding(.vertical, 12).padding(.horizontal, 12)
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                Divider()
            }

            Button(role: .destructive) {
                dismiss()
                onDelete()
            } label: {
                HStack { Text("删除记录"); Spacer(); Image(systemName: "trash") }
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

struct ServiceRecordDetailView: View {
    let record: NailServiceRecord
    var onCheckout: ((NailServiceRecord) -> Void)?
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @Query private var services: [ServiceItem]
    @Query private var categories: [ServiceCategory]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var showingEdit = false
    @State private var viewingPhotoIndex: Int?
    @State private var showingDeletePassword = false
    @State private var needsSetupPassword = false

    private var customerMap: [UUID: Customer] { Dictionary(uniqueKeysWithValues: customers.map { ($0.id, $0) }) }
    private var techMap: [UUID: Technician] { Dictionary(uniqueKeysWithValues: technicians.map { ($0.id, $0) }) }
    private var serviceMap: [UUID: ServiceItem] { Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) }) }
    private var categoryMap: [UUID: ServiceCategory] { Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) }) }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏：标题 + 右上角 ×
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("服务记录详情").font(.headline)
                    Text((customerMap[record.customerId]?.name ?? "未知客户") + " · " + record.serviceDate.cnDateTime)
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
                    LabeledContent("客户", value: customerMap[record.customerId]?.name ?? "未知")
                    LabeledContent("技师", value: techMap[record.technicianId]?.name ?? "未知")
                    LabeledContent("日期", value: record.serviceDate.cnDateTime)
                }
                Section("服务项目") {
                    let names = record.serviceItemIds
                        .map { fullServiceName(for: $0, serviceMap: serviceMap, categoryMap: categoryMap) }
                    if names.isEmpty { Text("无").foregroundStyle(.secondary).font(.caption) }
                    else { Text(names.joined(separator: " · ")) }
                }
                Section("制作工艺") {
                    LabeledContent("工艺描述", value: record.craft?.isEmpty ?? true ? "无" : record.craft!)
                    LabeledContent("客人喜好", value: record.preferences?.isEmpty ?? true ? "无" : record.preferences!)
                }
                Section("照片留档（\(record.photos.count)）") {
                    if record.photos.isEmpty {
                        Text("暂无照片").foregroundStyle(.secondary).font(.caption)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(Array(record.photos.enumerated()), id: \.element.id) { idx, p in
                                    PhotoThumbnail(imageData: p.imageData, size: 100)
                                        .onTapGesture {
                                            PhotoWindowController.show(
                                                photos: record.photos,
                                                initialIndex: idx,
                                                onIndexChange: { _ in }
                                            )
                                        }
                                        .contentShape(Rectangle())
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                Section("用料（\(record.materialsUsed.count)）") {
                    if record.materialsUsed.isEmpty {
                        Text("无").foregroundStyle(.secondary).font(.caption)
                    } else {
                        // 表头
                        HStack(spacing: 6) {
                            Text("品牌").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Text("位置").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Text("色号").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Text("类别").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(record.materialsUsed) { m in
                            HStack(spacing: 6) {
                                Text(m.brand.isEmpty ? "—" : m.brand)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(m.location.isEmpty ? "—" : m.location)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(m.colorCode.isEmpty ? "—" : m.colorCode)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(m.category.isEmpty ? "—" : m.category)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                Section("饰品（\(record.accessories.count)）") {
                    if record.accessories.isEmpty {
                        Text("无").foregroundStyle(.secondary).font(.caption)
                    } else {
                        ForEach(record.accessories) { a in
                            HStack {
                                Text(a.name.isEmpty ? "未命名饰品" : a.name)
                                Spacer()
                                Text("×\(a.quantity)").foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                }
                if let n = record.notes {
                    Section("备注") { Text(n) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                if record.isPaid {
                    Button("删除", role: .destructive) {
                        if SecurityManager.shared.hasPassword {
                            showingDeletePassword = true
                        } else {
                            needsSetupPassword = true
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button("编辑") { showingEdit = true }
                        .buttonStyle(.bordered)
                    Button("跳转收银") {
                        dismiss()
                        onCheckout?(record)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 480, idealHeight: 600, maxHeight: 800)
        .sheet(isPresented: $showingEdit) {
            ServiceRecordFormView(record: record) { _ in }
        }
        .alert("需要设置密码", isPresented: $needsSetupPassword) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("删除已收银的服务记录需要先在「设置」中设置密码。")
        }
        .sheet(isPresented: $showingDeletePassword) {
            PasswordConfirmSheet(
                title: "确认删除已收银服务记录？",
                message: "该服务记录已收款。删除后此操作不可撤销。",
                confirmTitle: "删除",
                destructive: true
            ) {
                dismiss()
                context.delete(record)
            }
            
        }
    }
}

// PhotoViewer 的 sheet item 包装器
private struct PhotoViewerWrapper: Identifiable {
    let id = UUID()
    let index: Int
}

struct ServiceRecordFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @Query private var services: [ServiceItem]
    @Query private var categories: [ServiceCategory]
    var record: NailServiceRecord?
    var onSave: (NailServiceRecord) -> Void

    @State private var customerId: UUID?
    @State private var technicianId: UUID?
    @State private var serviceDate = Date()
    @State private var selectedServices: Set<UUID> = []
    @State private var craft = ""
    @State private var hasConstruction = false
    @State private var preferences = ""
    @State private var notes = ""
    @State private var photos: [PhotoRecord] = []
    @State private var materials: [MaterialItem] = []
    @State private var accessories: [AccessoryItem] = []

    private var serviceMap: [UUID: ServiceItem] { Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) }) }
    private var categoryMap: [UUID: ServiceCategory] { Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) }) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Form {
                    LabeledContent("客户") {
                        CustomerField(customerId: $customerId, customers: customers)
                    }
                    Picker("技师", selection: $technicianId) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(technicians) { Text($0.name).tag(Optional($0.id)) }
                    }
                    LabeledContent("服务日期") {
                        TechCalendarPicker("", selection: $serviceDate)
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
                                Text("¥" + String(format: "%.0f", s.price))
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    Section("制作工艺") {
                        TextField("工艺描述", text: $craft)
                        ZStack(alignment: .topLeading) {
                            if preferences.isEmpty {
                                Text("请输入客人喜好...")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8).padding(.leading, 4)
                            }
                            TextEditor(text: $preferences)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 60)
                                .padding(2)
                        }
                    }
                    Section("照片留档") {
                        EditablePhotoGrid(photos: $photos)
                    }
                    Section("用料") {
                        if materials.isEmpty {
                            Text("暂无用料，点击下方按钮添加").foregroundStyle(.secondary).font(.caption)
                        } else {
                            // 表头 + 数据行 统一列宽
                            VStack(spacing: 6) {
                                HStack(spacing: 8) {
                                    Text("品牌").font(.headline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("位置").font(.headline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("色号").font(.headline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("类别").font(.headline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                    Color.clear.frame(width: 28)
                                }
                                ForEach(Array(materials.enumerated()), id: \.element.id) { idx, _ in
                                    MaterialItemRow(
                                        material: $materials[idx],
                                        onDelete: { materials.remove(at: idx) }
                                    )
                                }
                            }
                        }
                        Button {
                            materials.append(MaterialItem(brand: "", location: "", colorCode: "", category: "色胶"))
                        } label: {
                            Label("添加用料", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                    Section("饰品") {
                        if accessories.isEmpty {
                            Text("暂无饰品，点击下方按钮添加").foregroundStyle(.secondary).font(.caption)
                        } else {
                            ForEach(Array(accessories.enumerated()), id: \.element.id) { idx, _ in
                                HStack(spacing: 8) {
                                    TextField("饰品名称", text: $accessories[idx].name)
                                        .textFieldStyle(.roundedBorder)
                                    Stepper("×\(accessories[idx].quantity)", value: $accessories[idx].quantity, in: 1...999)
                                    Button {
                                        accessories.remove(at: idx)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 22))
                                            .foregroundStyle(.red)
                                            .symbolRenderingMode(.hierarchical)
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Rectangle())
                                    .frame(width: 28, height: 28)
                                    .help("删除此饰品")
                                }
                            }
                        }
                        Button {
                            accessories.append(AccessoryItem(name: ""))
                        } label: {
                            Label("添加饰品", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                    Section("备注") {
                        TextField("备注", text: $notes, axis: .vertical)
                            .lineLimit(2...4)
                    }
                }
                .formStyle(.grouped)
                Divider()
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                    Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(customerId == nil || technicianId == nil)
                }
                .padding(16)
            }
        }
        .frame(minWidth: 600, minHeight: 480, idealHeight: 660, maxHeight: 800)
        .onAppear { load() }
    }

    private func load() {
        guard let r = record else { return }
        customerId = r.customerId
        technicianId = r.technicianId
        serviceDate = r.serviceDate
        selectedServices = Set(r.serviceItemIds)
        craft = r.craft ?? ""
        hasConstruction = r.hasConstruction
        preferences = r.preferences ?? ""
        notes = r.notes ?? ""
        photos = r.photos
        materials = r.materialsUsed
        accessories = r.accessories
    }

    private func save() {
        guard let cid = customerId, let tid = technicianId else { return }
        let photoData = photos
        // 过滤掉「只点了添加但没实际输入内容」的空行
        // 用料：品牌 / 位置 / 色号 三者全空，或 category 选了「自定义」但没填内容 → 视为空
        let matData = materials.filter { m in
            let hasCoreInput = !(m.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && m.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && m.colorCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let customCatOk = MaterialItem.presetCategories.contains(m.category)
                || m.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            return hasCoreInput && customCatOk
        }
        // 饰品：name 为空 → 视为空
        let accData = accessories.filter { a in
            !a.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let r = record {
            r.customerId = cid
            r.technicianId = tid
            r.serviceDate = serviceDate
            r.serviceItemIds = Array(selectedServices)
            r.craft = craft.isEmpty ? nil : craft
            r.hasConstruction = hasConstruction
            r.preferences = preferences.isEmpty ? nil : preferences
            r.notes = notes.isEmpty ? nil : notes
            r.photos = photoData
            r.materialsUsed = matData
            r.accessories = accData
            onSave(r)
        } else {
            let r = NailServiceRecord(
                customerId: cid, technicianId: tid, serviceDate: serviceDate,
                serviceItemIds: Array(selectedServices), photos: photoData,
                materialsUsed: matData, accessories: accData,
                craft: craft.isEmpty ? nil : craft, hasConstruction: hasConstruction,
                preferences: preferences.isEmpty ? nil : preferences,
                notes: notes.isEmpty ? nil : notes
            )
            onSave(r)
        }
        dismiss()
    }
}

// MARK: - 用料行编辑组件（品牌 / 位置 / 色号 / 类别 + 自定义类别 + 删除）

private struct MaterialItemRow: View {
    @Binding var material: MaterialItem
    var onDelete: () -> Void

    /// 当前选中的 picker 值；如果 material.category 属于预设列表则直接用，否则显示「自定义」
    private var pickerSelection: Binding<String> {
        Binding<String>(
            get: {
                if MaterialItem.presetCategories.contains(material.category) {
                    return material.category
                } else {
                    return MaterialItem.customSentinel
                }
            },
            set: { newValue in
                if newValue != MaterialItem.customSentinel {
                    material.category = newValue
                } else if !MaterialItem.presetCategories.contains(material.category) {
                    // 已经是自定义文字，保持不变
                } else {
                    // 从预设切到自定义：先置空等待输入
                    material.category = ""
                }
            }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            materialField($material.brand, prompt: "品牌")
            materialField($material.location, prompt: "位置")
            materialField($material.colorCode, prompt: "色号")
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: pickerSelection) {
                    ForEach(MaterialItem.presetCategories, id: \.self) {
                        Text($0).tag($0)
                    }
                    Text(MaterialItem.customSentinel).tag(MaterialItem.customSentinel)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                if pickerSelection.wrappedValue == MaterialItem.customSentinel {
                    materialField($material.category, prompt: "自定义类别")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.red)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .frame(width: 28, height: 28)
            .help("删除此条用料")
        }
    }

    /// 统一的用料输入框：文字与表头左对齐，外框使用 overlay 绘制
    @ViewBuilder
    private func materialField(_ text: Binding<String>, prompt: String) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .textFieldStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
    }
}
