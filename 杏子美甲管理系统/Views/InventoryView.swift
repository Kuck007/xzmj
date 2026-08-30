//
//  InventoryView.swift
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

// MARK: - 分类颜色映射
private func categoryColor(_ cat: String) -> Color {
    switch cat {
    case "色胶": return .red
    case "消耗品": return .blue
    case "工具": return .green
    case "功能胶": return .yellow
    default: return .secondary
    }
}

// MARK: - 库存行
struct InventoryRow: View {
    let item: InventoryItem
    var onTap: () -> Void
    var onShowActions: () -> Void
    var onCategoryTap: (String) -> Void

    var body: some View {
        HoverHighlightRow {
            HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.name).font(.headline).foregroundStyle(item.isLowStock ? .red : .primary)
                    Text(item.category)
                        .font(.caption)
                        .foregroundStyle(categoryColor(item.category))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(categoryColor(item.category).opacity(0.12), in: Capsule())
                        .contentShape(Rectangle())
                        .onTapGesture { onCategoryTap(item.category) }
                }
                if let b = item.brand, let c = item.colorCode {
                    Text("\(b) · \(c)").font(.caption).foregroundStyle(.secondary)
                } else if let b = item.brand {
                    Text(b).font(.caption).foregroundStyle(.secondary)
                } else if let c = item.colorCode {
                    Text(c).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "%.0f", item.quantity) + " " + item.unit)
                        .font(.body.bold())
                        .foregroundStyle(item.isLowStock ? .red : .primary)
                    if item.isLowStock {
                        Text("低库存")
                            .font(.caption).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                    }
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
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - 库存管理视图
struct InventoryView: View {
    @Query(sort: \InventoryItem.name) private var items: [InventoryItem]
    @Environment(\.modelContext) private var context
    @State private var searchText = ""
    @State private var showingAdd = false
    @State private var pendingDelete: InventoryItem?
    @State private var actionsForItem: InventoryItem?
    @State private var editingItem: InventoryItem?
    @State private var selectedItem: InventoryItem?
    @State private var filterCategory: String?

    private func toggleCategoryFilter(_ cat: String) {
        if filterCategory == cat {
            filterCategory = nil
        } else {
            filterCategory = cat
        }
    }

    private var filtered: [InventoryItem] {
        var result = items
        if let cat = filterCategory {
            result = result.filter { $0.category == cat }
        }
        guard !searchText.isEmpty else { return result }
        return result.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || ($0.colorCode?.contains(searchText) ?? false)
            || ($0.brand?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    private var lowStock: [InventoryItem] { filtered.filter { $0.isLowStock } }

    var body: some View {
        // macOS NavigationSplitView 的 detail column 会自动处理 .navigationTitle/.toolbar/.searchable，NavigationStack 在 detail 里是冗余的，且会吃掉 sheet 首次 present 的进入动画
        VStack(spacing: 0) {
            Group {
                if filtered.isEmpty {
                    EmptyStateView(
                        systemImage: "shippingbox",
                        title: searchText.isEmpty ? "暂无库存" : "无匹配库存",
                        message: searchText.isEmpty ? "点击右上角「增加库存」记录物料信息" : "尝试更换搜索关键词"
                    )
                } else {
                    List {
                        if let cat = filterCategory {
                            Section {
                                HStack(spacing: 8) {
                                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                        .foregroundStyle(categoryColor(cat))
                                    Text("筛选分类：" + cat)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Button {
                                        filterCategory = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 28, height: 28)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Rectangle())
                                    .help("清除筛选")
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .onTapGesture { filterCategory = nil }
                            }
                        }
                        if !lowStock.isEmpty {
                            Section {
                                ForEach(lowStock) { item in
                                    InventoryRow(
                                        item: item,
                                        onTap: { selectedItem = item },
                                        onShowActions: { actionsForItem = item },
                                        onCategoryTap: { toggleCategoryFilter($0) }
                                    )
                                    .swipeActions { Button("删除", role: .destructive) { pendingDelete = item } }
                                }
                            } header: {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("低库存提醒（\(lowStock.count)）")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        Section("全部库存（\(filtered.count)）") {
                            ForEach(filtered.filter { !$0.isLowStock }) { item in
                                InventoryRow(
                                    item: item,
                                    onTap: { selectedItem = item },
                                    onShowActions: { actionsForItem = item },
                                    onCategoryTap: { toggleCategoryFilter($0) }
                                )
                                .swipeActions { Button("删除", role: .destructive) { pendingDelete = item } }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("库存管理")
            .searchable(text: $searchText)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Text("增加库存")
                    }
                    .buttonStyle(BrandPrimaryButtonStyle())
                }
            }
            .sheet(isPresented: $showingAdd) {
                InventoryFormView { context.insert($0) }
                    
            }
            .sheet(isPresented: Binding(get: { selectedItem != nil }, set: { if !$0 { selectedItem = nil } })) {
                if let item = selectedItem {
                    InventoryDetailSheet(
                        item: item,
                        onEdit: {
                            selectedItem = nil
                            editingItem = item
                        }
                    )
                }
                
            }
            .sheet(isPresented: Binding(get: { actionsForItem != nil }, set: { if !$0 { actionsForItem = nil } })) {
                if let item = actionsForItem {
                    InventoryActionsSheet(
                        item: item,
                        onEdit: {
                            actionsForItem = nil
                            editingItem = item
                        },
                        onDelete: {
                            actionsForItem = nil
                            pendingDelete = item
                        }
                    )
                }
                
            }
            .sheet(isPresented: Binding(get: { editingItem != nil }, set: { if !$0 { editingItem = nil } })) {
                if let item = editingItem {
                    InventoryFormView(item: item) { _ in }
                }
                    
            }
            .alert("删除库存？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let item = pendingDelete { context.delete(item) }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("该库存将被永久删除，无法恢复。")
            }
        }
    }
}

// MARK: - 三点操作菜单
struct InventoryActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: InventoryItem
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("库存操作").font(.headline)
                    Text(item.name).font(.caption).foregroundStyle(.secondary)
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
                HStack { Text("修改库存"); Spacer(); Image(systemName: "pencil") }
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
                HStack { Text("删除库存"); Spacer(); Image(systemName: "trash") }
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

// MARK: - 库存详情（Sheet 弹出）
struct InventoryDetailSheet: View {
    let item: InventoryItem
    @Environment(\.dismiss) private var dismiss
    let onEdit: () -> Void
    @State private var showingSaveConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("库存详情").font(.headline)
                    Text(item.name + " · " + item.category)
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
                    LabeledContent("名称", value: item.name)
                    if let b = item.brand { LabeledContent("品牌", value: b) }
                    if let c = item.colorCode { LabeledContent("色号", value: c) }
                    LabeledContent("类别", value: item.category)
                }
                Section("库存数量") {
                    LabeledContent("当前库存", value: String(format: "%.0f", item.quantity) + " " + item.unit)
                    LabeledContent("低库存阈值", value: String(format: "%.0f", item.lowStockThreshold) + " " + item.unit)
                    LabeledContent("库存状态", value: item.isLowStock ? "低库存" : "正常")
                }
                Section("更新时间") {
                    LabeledContent("最后更新", value: item.updatedAt.cnDateTime)
                }
                if let n = item.notes {
                    Section("备注") { Text(n) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("修改") { showingSaveConfirm = true }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 440, idealHeight: 520, maxHeight: 700)
        .alert("确认修改此库存？", isPresented: $showingSaveConfirm) {
            Button("取消", role: .cancel) { }
            Button("确认修改") {
                onEdit()
            }
        } message: {
            Text("将进入「\(item.name)」的修改界面，修改后请确认保存。")
        }
    }
}

// MARK: - 库存表单（新建/编辑共用）
struct InventoryFormView: View {
    @Environment(\.dismiss) private var dismiss
    var item: InventoryItem?
    var onSave: (InventoryItem) -> Void

    @State private var name = ""
    @State private var brand = ""
    @State private var colorCode = ""
    @State private var category = "色胶"
    @State private var quantity: Double = 1
    @State private var unit = "瓶"
    @State private var lowStockThreshold: Double = 1
    @State private var notes = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("名称", text: $name)
                TextField("品牌", text: $brand)
                TextField("色号", text: $colorCode)
                Picker("类别", selection: $category) {
                    Text("色胶").tag("色胶")
                    Text("功能胶").tag("功能胶")
                    Text("消耗品").tag("消耗品")
                    Text("工具").tag("工具")
                }
                LabeledContent("库存数量") {
                    HStack {
                        TextField("", value: $quantity, format: .number).frame(width: 80)
                        TextField("单位", text: $unit).frame(width: 60)
                    }
                }
                LabeledContent("低库存阈值") {
                    TextField("", value: $lowStockThreshold, format: .number).frame(width: 80)
                }
                TextField("备注", text: $notes, axis: .vertical).lineLimit(2...4)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 440, minHeight: 420, idealHeight: 460, maxHeight: 650)
        .onAppear { load() }
    }

    private func load() {
        guard let i = item else { return }
        name = i.name; brand = i.brand ?? ""; colorCode = i.colorCode ?? ""
        category = i.category; quantity = i.quantity; unit = i.unit
        lowStockThreshold = i.lowStockThreshold; notes = i.notes ?? ""
    }

    private func save() {
        if let i = item {
            i.name = name
            i.brand = brand.isEmpty ? nil : brand
            i.colorCode = colorCode.isEmpty ? nil : colorCode
            i.category = category; i.quantity = quantity; i.unit = unit
            i.lowStockThreshold = lowStockThreshold
            i.notes = notes.isEmpty ? nil : notes
            i.updatedAt = Date()
            onSave(i)
        } else {
            let i = InventoryItem(name: name,
                                  brand: brand.isEmpty ? nil : brand,
                                  colorCode: colorCode.isEmpty ? nil : colorCode,
                                  category: category, quantity: quantity, unit: unit,
                                  lowStockThreshold: lowStockThreshold,
                                  notes: notes.isEmpty ? nil : notes)
            onSave(i)
        }
        dismiss()
    }
}
