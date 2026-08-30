//
//  ServiceView.swift
//  杏子美甲管理系统
//

import SwiftUI
import SwiftData

// MARK: - 主视图
struct ServiceView: View {
    @Query(sort: \ServiceCategory.sortOrder) private var categories: [ServiceCategory]
    @Query(sort: \ServiceItem.sortOrder) private var items: [ServiceItem]
    @Query private var reminders: [LashReminder]
    @Environment(\.modelContext) private var context
    @State private var showingAddCategory = false
    @State private var showingAddItem = false
    @State private var editingItem: ServiceItem?
    @State private var editingCategory: ServiceCategory?
    @State private var selectedItemId: UUID?
    @State private var expandedIDs: Set<UUID> = []
    @State private var pendingDeleteItem: ServiceItem?
    @State private var pendingDeleteCategory: ServiceCategory?
    @State private var actionsForCategory: ServiceCategory?
    @State private var actionsForItem: ServiceItem?

    private var roots: [ServiceCategory] { categories.filter { $0.parentId == nil } }

    // MARK: 美睫分类/项目被补睫提醒引用的检测

    /// 递归收集某分类下所有子分类ID（包含自身）
    private func allDescendantCategoryIds(_ cat: ServiceCategory) -> Set<UUID> {
        var result: Set<UUID> = [cat.id]
        var changed = true
        while changed {
            changed = false
            for c in categories {
                if let pid = c.parentId, result.contains(pid), !result.contains(c.id) {
                    result.insert(c.id)
                    changed = true
                }
            }
        }
        return result
    }

    /// 收集某分类（含子分类）下所有项目ID
    private func allItemIds(in category: ServiceCategory) -> Set<UUID> {
        let catIds = allDescendantCategoryIds(category)
        return Set(items.filter { catIds.contains($0.categoryId) }.map { $0.id })
    }

    /// 删除分类时，有多少条未完成的补睫提醒会受影响
    private func pendingReminderImpact(for category: ServiceCategory) -> Int {
        let affectedItemIds = allItemIds(in: category)
        guard !affectedItemIds.isEmpty else { return 0 }
        return reminders.filter { !$0.isCompleted && !$0.serviceItemIds.filter { affectedItemIds.contains($0) }.isEmpty }.count
    }

    /// 删除项目时，有多少条未完成的补睫提醒会受影响
    private func pendingReminderImpact(for item: ServiceItem) -> Int {
        reminders.filter { !$0.isCompleted && $0.serviceItemIds.contains(item.id) }.count
    }

    /// 判断某分类是否是美睫相关（名称含"美睫"或属于美睫根分类下）
    private func isLashRelated(_ cat: ServiceCategory) -> Bool {
        if cat.name == "美睫" && cat.parentId == nil { return true }
        var parentId: UUID? = cat.parentId
        while let pid = parentId {
            if let parent = categories.first(where: { $0.id == pid }) {
                if parent.name == "美睫" && parent.parentId == nil { return true }
                parentId = parent.parentId
            } else {
                break
            }
        }
        return false
    }

    var body: some View {
        // macOS NavigationSplitView 的 detail column 会自动处理 .navigationTitle/.toolbar/.searchable，NavigationStack 在 detail 里是冗余的，且会吃掉 sheet 首次 present 的进入动画
        VStack(spacing: 0) {
            Group {
                if categories.isEmpty {
                    EmptyStateView(
                        systemImage: "list.bullet.rectangle",
                        title: "暂无分类",
                        message: "点击右上角「新增分类」开始建立服务项目目录"
                    )
                } else {
                    List {
                        ForEach(roots) { root in
                            CategoryNode(
                                category: root,
                                categories: categories,
                                items: items,
                                expandedIDs: $expandedIDs,
                                selectedItemId: $selectedItemId,
                                onEditItem: { editingItem = $0 },
                                onDeleteItem: { pendingDeleteItem = $0 },
                                onMoveUp: moveUp,
                                onMoveDown: moveDown,
                                onShowCategoryActions: { actionsForCategory = $0 },
                                onShowItemActions: { actionsForItem = $0 },
                                onEditCategory: { editingCategory = $0 }
                            )
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("服务项目")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 8) {
                        Button {
                            showingAddCategory = true
                        } label: {
                            Text("新增分类")
                        }
                        .buttonStyle(BrandPrimaryButtonStyle())
                        Button {
                            showingAddItem = true
                        } label: {
                            Text("新增项目")
                        }
                        .buttonStyle(BrandPrimaryButtonStyle())
                    }
                }
            }
            .sheet(isPresented: $showingAddCategory) {
                CategoryFormView { context.insert($0) }
                
            }
            .sheet(isPresented: $showingAddItem) {
                ItemFormView(categories: categories) { context.insert($0) }
                
            }
            .sheet(isPresented: Binding(get: { editingItem != nil }, set: { if !$0 { editingItem = nil } })) {
                if let item = editingItem {
                    ItemFormView(categories: categories, item: item) { _ in }
                }
                
            }
            .sheet(isPresented: Binding(get: { editingCategory != nil }, set: { if !$0 { editingCategory = nil } })) {
                if let cat = editingCategory {
                    CategoryFormView(category: cat) { _ in }
                }
                
            }
            .alert("删除项目？", isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteItem = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let item = pendingDeleteItem {
                        context.delete(item)
                        selectedItemId = nil
                    }
                }
                Button("取消", role: .cancel) { pendingDeleteItem = nil }
            } message: {
                if let item = pendingDeleteItem {
                    let impact = pendingReminderImpact(for: item)
                    if impact > 0 {
                        Text("⚠️ 该服务项目正在被 \(impact) 条未完成的补睫提醒引用。\n删除后这些提醒中的项目名将显示为「未知项目（已删除）」。\n此操作不可恢复。")
                    } else {
                        Text("该项目将被永久删除，无法恢复。")
                    }
                } else {
                    Text("该项目将被永久删除，无法恢复。")
                }
            }
            .alert("删除分类？", isPresented: Binding(
                get: { pendingDeleteCategory != nil },
                set: { if !$0 { pendingDeleteCategory = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let cat = pendingDeleteCategory {
                        for child in categories.filter({ $0.parentId == cat.id }) {
                            context.delete(child)
                        }
                        for item in items.filter({ $0.categoryId == cat.id }) {
                            context.delete(item)
                        }
                        context.delete(cat)
                        selectedItemId = nil
                    }
                }
                Button("取消", role: .cancel) { pendingDeleteCategory = nil }
            } message: {
                if let cat = pendingDeleteCategory {
                    let impact = pendingReminderImpact(for: cat)
                    let lashRelated = isLashRelated(cat)
                    var parts: [String] = []
                    parts.append("该分类及其所有子分类、项目将被永久删除。")
                    if lashRelated {
                        parts.append("\n⚠️ 此为【美睫】相关分类，删除后收银结账时将无法自动生成补睫提醒。")
                    }
                    if impact > 0 {
                        parts.append("\n⚠️ 另有 \(impact) 条未完成的补睫提醒引用此分类下的项目，删除后会显示为「未知项目（已删除）」。")
                    }
                    return Text(parts.joined())
                } else {
                    return Text("该分类及其所有子分类、项目将被永久删除。")
                }
            }
            .sheet(isPresented: Binding(get: { actionsForCategory != nil }, set: { if !$0 { actionsForCategory = nil } })) {
                if let cat = actionsForCategory {
                    CategoryActionsSheet(
                        category: cat,
                        canMoveUp: canCategoryMoveUp(cat),
                        canMoveDown: canCategoryMoveDown(cat),
                        onEdit: {
                            actionsForCategory = nil
                            editingCategory = cat
                        },
                        onDelete: {
                            actionsForCategory = nil
                            pendingDeleteCategory = cat
                        },
                        onMoveUp: {
                            actionsForCategory = nil
                            moveCategoryUp(cat)
                        },
                        onMoveDown: {
                            actionsForCategory = nil
                            moveCategoryDown(cat)
                        }
                    )
                }
                
            }
            .sheet(isPresented: Binding(get: { actionsForItem != nil }, set: { if !$0 { actionsForItem = nil } })) {
                if let item = actionsForItem {
                    ItemActionsSheet(
                        item: item,
                        canMoveUp: canMoveUp(item),
                        canMoveDown: canMoveDown(item),
                        onEdit: {
                            actionsForItem = nil
                            editingItem = item
                        },
                        onDelete: {
                            actionsForItem = nil
                            pendingDeleteItem = item
                        },
                        onMoveUp: {
                            actionsForItem = nil
                            moveUp(item)
                        },
                        onMoveDown: {
                            actionsForItem = nil
                            moveDown(item)
                        }
                    )
                }
                
            }
        }
    }

    private func canMoveUp(_ item: ServiceItem) -> Bool {
        let siblings = items.filter { $0.categoryId == item.categoryId }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let idx = siblings.firstIndex(where: { $0.id == item.id }) else { return false }
        return idx > 0
    }

    private func canMoveDown(_ item: ServiceItem) -> Bool {
        let siblings = items.filter { $0.categoryId == item.categoryId }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let idx = siblings.firstIndex(where: { $0.id == item.id }) else { return false }
        return idx < siblings.count - 1
    }

    private func moveUp(_ item: ServiceItem) {
        let siblings = items.filter { $0.categoryId == item.categoryId }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let idx = siblings.firstIndex(where: { $0.id == item.id }), idx > 0 else { return }
        let prev = siblings[idx - 1]
        let tmp = item.sortOrder
        item.sortOrder = prev.sortOrder
        prev.sortOrder = tmp
    }

    private func moveDown(_ item: ServiceItem) {
        let siblings = items.filter { $0.categoryId == item.categoryId }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let idx = siblings.firstIndex(where: { $0.id == item.id }), idx < siblings.count - 1 else { return }
        let next = siblings[idx + 1]
        let tmp = item.sortOrder
        item.sortOrder = next.sortOrder
        next.sortOrder = tmp
    }

    // MARK: 分类移动（同级兄弟间排序）
    private func canCategoryMoveUp(_ cat: ServiceCategory) -> Bool {
        let siblings = categories.filter { $0.parentId == cat.parentId }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let idx = siblings.firstIndex(where: { $0.id == cat.id }) else { return false }
        return idx > 0
    }

    private func canCategoryMoveDown(_ cat: ServiceCategory) -> Bool {
        let siblings = categories.filter { $0.parentId == cat.parentId }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let idx = siblings.firstIndex(where: { $0.id == cat.id }) else { return false }
        return idx < siblings.count - 1
    }

    private func moveCategoryUp(_ cat: ServiceCategory) {
        let siblings = categories.filter { $0.parentId == cat.parentId }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let idx = siblings.firstIndex(where: { $0.id == cat.id }), idx > 0 else { return }
        let prev = siblings[idx - 1]
        let tmp = cat.sortOrder
        cat.sortOrder = prev.sortOrder
        prev.sortOrder = tmp
    }

    private func moveCategoryDown(_ cat: ServiceCategory) {
        let siblings = categories.filter { $0.parentId == cat.parentId }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let idx = siblings.firstIndex(where: { $0.id == cat.id }), idx < siblings.count - 1 else { return }
        let next = siblings[idx + 1]
        let tmp = cat.sortOrder
        cat.sortOrder = next.sortOrder
        next.sortOrder = tmp
    }
}

// MARK: - 分类操作 Sheet
struct CategoryActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let category: ServiceCategory
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(category.name).font(.headline)
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
                HStack { Text("修改"); Spacer(); Image(systemName: "pencil") }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Divider()

            Button {
                dismiss()
                onMoveUp()
            } label: {
                HStack { Text("上移"); Spacer(); Image(systemName: "chevron.up") }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(!canMoveUp)

            Divider()

            Button {
                dismiss()
                onMoveDown()
            } label: {
                HStack { Text("下移"); Spacer(); Image(systemName: "chevron.down") }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(!canMoveDown)

            Divider()

            Button(role: .destructive) {
                dismiss()
                onDelete()
            } label: {
                HStack { Text("删除"); Spacer(); Image(systemName: "trash") }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding()
        .frame(width: 260)
    }
}

// MARK: - 项目操作 Sheet
struct ItemActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: ServiceItem
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.headline)
                    Text("¥" + String(format: "%.0f", item.price) + " · \(item.durationMinutes)分")
                        .foregroundStyle(.secondary).font(.caption)
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
                HStack { Text("修改"); Spacer(); Image(systemName: "pencil") }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Divider()

            Button {
                dismiss()
                onMoveUp()
            } label: {
                HStack { Text("上移"); Spacer(); Image(systemName: "chevron.up") }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(!canMoveUp)

            Divider()

            Button {
                dismiss()
                onMoveDown()
            } label: {
                HStack { Text("下移"); Spacer(); Image(systemName: "chevron.down") }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(!canMoveDown)

            Divider()

            Button(role: .destructive) {
                dismiss()
                onDelete()
            } label: {
                HStack { Text("删除"); Spacer(); Image(systemName: "trash") }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding()
        .frame(width: 260)
    }
}

// MARK: - 递归分类节点
struct CategoryNode: View {
    let category: ServiceCategory
    let categories: [ServiceCategory]
    let items: [ServiceItem]
    @Binding var expandedIDs: Set<UUID>
    @Binding var selectedItemId: UUID?
    let onEditItem: (ServiceItem) -> Void
    let onDeleteItem: (ServiceItem) -> Void
    let onMoveUp: (ServiceItem) -> Void
    let onMoveDown: (ServiceItem) -> Void
    let onShowCategoryActions: (ServiceCategory) -> Void
    let onShowItemActions: (ServiceItem) -> Void
    let onEditCategory: (ServiceCategory) -> Void

    private var kids: [ServiceCategory] { categories.filter { $0.parentId == category.id } }
    private var its: [ServiceItem] { items.filter { $0.categoryId == category.id }
        .sorted { $0.sortOrder < $1.sortOrder } }

    private var isExpanded: Bool { expandedIDs.contains(category.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(category.name).font(.headline)
                Spacer()
                Button {
                    onShowCategoryActions(category)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { toggleExpand() }

            if isExpanded {
                ForEach(kids) { kid in
                    CategoryNode(
                        category: kid,
                        categories: categories,
                        items: items,
                        expandedIDs: $expandedIDs,
                        selectedItemId: $selectedItemId,
                        onEditItem: onEditItem,
                        onDeleteItem: onDeleteItem,
                        onMoveUp: onMoveUp,
                        onMoveDown: onMoveDown,
                        onShowCategoryActions: onShowCategoryActions,
                        onShowItemActions: onShowItemActions,
                        onEditCategory: onEditCategory
                    )
                    .padding(.leading, 16)
                }
                ForEach(its) { item in
                    ItemRow(
                        item: item,
                        isSelected: selectedItemId == item.id,
                        siblings: its,
                        onSelect: { selectedItemId = item.id },
                        onShowActions: { onShowItemActions(item) },
                        onEdit: { onEditItem(item) },
                        onDelete: { onDeleteItem(item) },
                        onMoveUp: { onMoveUp(item) },
                        onMoveDown: { onMoveDown(item) }
                    )
                }
            }
        }
    }

    private func toggleExpand() {
        if isExpanded {
            expandedIDs.remove(category.id)
        } else {
            expandedIDs.insert(category.id)
        }
    }
}

// MARK: - 项目行
struct ItemRow: View {
    let item: ServiceItem
    let isSelected: Bool
    let siblings: [ServiceItem]
    let onSelect: () -> Void
    let onShowActions: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    private var canMoveUp: Bool {
        guard let idx = siblings.firstIndex(where: { $0.id == item.id }) else { return false }
        return idx > 0
    }

    private var canMoveDown: Bool {
        guard let idx = siblings.firstIndex(where: { $0.id == item.id }) else { return false }
        return idx < siblings.count - 1
    }

    var body: some View {
        HoverHighlightRow {
            HStack {
            Text(item.name)
            Spacer()
            Text("¥" + String(format: "%.0f", item.price) + " · \(item.durationMinutes)分")
                .foregroundStyle(.secondary)
            Button {
                onShowActions()
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(4)
        }
    }
}

// MARK: - 可折叠多级多选服务项目（用于表单/选择器）
struct CollapsibleServiceMultiSelect<Trailing: View>: View {
    let services: [ServiceItem]
    let categories: [ServiceCategory]
    @Binding var selectedIds: Set<UUID>
    let rowTrailing: (ServiceItem) -> Trailing

    private var roots: [ServiceCategory] {
        categories.filter { $0.parentId == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        ForEach(roots) { root in
            MultiSelectCategoryNode(
                category: root,
                services: services,
                categories: categories,
                selectedIds: $selectedIds,
                depth: 0,
                rowTrailing: rowTrailing
            )
        }
    }
}

// MARK: - 多选分类递归节点
struct MultiSelectCategoryNode<Trailing: View>: View {
    let category: ServiceCategory
    let services: [ServiceItem]
    let categories: [ServiceCategory]
    @Binding var selectedIds: Set<UUID>
    let depth: Int
    let rowTrailing: (ServiceItem) -> Trailing
    @State private var isExpanded = false

    private var kids: [ServiceCategory] {
        categories.filter { $0.parentId == category.id }.sorted { $0.sortOrder < $1.sortOrder }
    }
    private var its: [ServiceItem] {
        services.filter { $0.categoryId == category.id }.sorted { $0.sortOrder < $1.sortOrder }
    }
    private var selectedInSubtree: Int {
        let direct = its.filter { selectedIds.contains($0.id) }.count
        let childCount = kids.reduce(0) { acc, k in
            acc + MultiSelectCategoryNode.subtreeSelectedCount(
                id: k.id, services: services, categories: categories, selectedIds: selectedIds)
        }
        return direct + childCount
    }

    static func subtreeSelectedCount(id: UUID, services: [ServiceItem],
                                     categories: [ServiceCategory], selectedIds: Set<UUID>) -> Int {
        let direct = services.filter { $0.categoryId == id && selectedIds.contains($0.id) }.count
        let kids = categories.filter { $0.parentId == id }
        return direct + kids.reduce(0) { $0 + subtreeSelectedCount(id: $1.id, services: services, categories: categories, selectedIds: selectedIds) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(category.name)
                    .font(.body.weight(.medium))
                if selectedInSubtree > 0 {
                    Text("\(selectedInSubtree)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.leading, CGFloat(depth) * 16)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            if isExpanded {
                ForEach(kids) { kid in
                    MultiSelectCategoryNode(
                        category: kid,
                        services: services,
                        categories: categories,
                        selectedIds: $selectedIds,
                        depth: depth + 1,
                        rowTrailing: rowTrailing
                    )
                }
                ForEach(its) { s in
                    HStack(spacing: 8) {
                        Image(systemName: selectedIds.contains(s.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedIds.contains(s.id) ? Color.accentColor : .secondary)
                            .font(.system(size: 16))
                        Text(s.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        rowTrailing(s)
                    }
                    .padding(.vertical, 6)
                    .padding(.leading, CGFloat(depth + 1) * 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedIds.contains(s.id) { selectedIds.remove(s.id) } else { selectedIds.insert(s.id) }
                    }
                }
            }
        }
        .onAppear {
            if selectedInSubtree > 0 { isExpanded = true }
        }
    }
}

// MARK: - 分类表单（新建/编辑）
struct CategoryFormView: View {
    @Environment(\.dismiss) private var dismiss
    var category: ServiceCategory?
    var onSave: (ServiceCategory) -> Void
    @Query private var categories: [ServiceCategory]

    @State private var name = ""
    @State private var parentId: UUID?
    @State private var sortOrder: Int = 0

    init(category: ServiceCategory? = nil, onSave: @escaping (ServiceCategory) -> Void) {
        self.category = category
        self.onSave = onSave
    }

    var body: some View {
        VStack {
            Form {
                TextField("分类名称", text: $name)
                Picker("父分类（空为根）", selection: $parentId) {
                    Text("（顶级分类）").tag(UUID?.none)
                    ForEach(categories.sorted(by: { $0.sortOrder < $1.sortOrder })) { c in
                        Text(c.name).tag(Optional(c.id))
                    }
                }
                Stepper("排序 \(sortOrder)", value: $sortOrder, in: 0...999)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 380, minHeight: 240, idealHeight: 300, maxHeight: 500)
        .onAppear {
            if let c = category {
                name = c.name
                parentId = c.parentId
                sortOrder = c.sortOrder
            } else {
                // 新建：默认排序从1开始（同级兄弟数+1）
                let siblings = categories.filter { $0.parentId == parentId }
                sortOrder = (siblings.map(\.sortOrder).max() ?? 0) + 1
            }
        }
        .onChange(of: parentId) { _, newParent in
            // 父分类变化时重新计算默认排序
            if category == nil {
                let siblings = categories.filter { $0.parentId == newParent }
                sortOrder = (siblings.map(\.sortOrder).max() ?? 0) + 1
            }
        }
    }

    private func save() {
        if let c = category {
            c.name = name; c.parentId = parentId; c.sortOrder = sortOrder
            onSave(c)
        } else {
            let c = ServiceCategory(name: name, parentId: parentId, sortOrder: sortOrder)
            onSave(c)
        }
        dismiss()
    }
}

// MARK: - 项目表单（新建/编辑）
struct ItemFormView: View {
    @Environment(\.dismiss) private var dismiss
    var categories: [ServiceCategory]
    var item: ServiceItem?
    var onSave: (ServiceItem) -> Void
    @Query private var allItems: [ServiceItem]

    @State private var name = ""
    @State private var categoryId: UUID?
    @State private var price: Double = 0
    @State private var durationMinutes: Int = 60
    @State private var desc = ""
    @State private var sortOrder: Int = 0
    @State private var isLashTouchUp = false

    init(categories: [ServiceCategory], item: ServiceItem? = nil, onSave: @escaping (ServiceItem) -> Void) {
        self.categories = categories
        self.item = item
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Row 1: 项目名称 - half width
            HStack(alignment: .center, spacing: 12) {
                Text("项目名称")
                    .frame(width: 72, alignment: .trailing)
                TextField("", text: $name)
                    .frame(width: 140)
            }
            .padding(.vertical, 6)

            // Row 2: 所属分类 - half width
            HStack(alignment: .center, spacing: 12) {
                Text("所属分类")
                    .frame(width: 72, alignment: .trailing)
                Picker("", selection: $categoryId) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(categories.sorted(by: { $0.sortOrder < $1.sortOrder })) { c in
                        Text(c.name).tag(Optional(c.id))
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            .padding(.vertical, 6)

            // Row 3: 价格 - base width
            HStack(alignment: .center, spacing: 12) {
                Text("价格")
                    .frame(width: 72, alignment: .trailing)
                HStack(spacing: 4) {
                    TextField("", value: $price, format: .number)
                        .frame(width: 80)
                    Text("元").foregroundStyle(.secondary)
                }
                .frame(width: 190, alignment: .leading)
            }
            .padding(.vertical, 6)

            // Row 4: 预计耗时 - same width as row 3
            HStack(alignment: .center, spacing: 12) {
                Text("预计耗时")
                    .frame(width: 72, alignment: .trailing)
                HStack(spacing: 6) {
                    TextField("", value: $durationMinutes, format: .number)
                        .frame(width: 60)
                    Text("分钟").foregroundStyle(.secondary)
                    Stepper(value: $durationMinutes, in: 5...600, step: 10) {}
                        .fixedSize()
                }
                .frame(width: 190, alignment: .leading)
            }
            .padding(.vertical, 6)

            // Row 5: 排序 - same width as row 3
            HStack(alignment: .center, spacing: 12) {
                Text("排序")
                    .frame(width: 72, alignment: .trailing)
                HStack(spacing: 6) {
                    TextField("", value: $sortOrder, format: .number)
                        .frame(width: 60)
                    Stepper(value: $sortOrder, in: 0...999, step: 1) {}
                        .fixedSize()
                }
                .frame(width: 190, alignment: .leading)
            }
            .padding(.vertical, 6)

            // Row 5.5: 补睫类项目开关
            HStack(alignment: .center, spacing: 12) {
                Text("补睫项目")
                    .frame(width: 72, alignment: .trailing)
                Toggle("", isOn: $isLashTouchUp)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help("开启后，该项目收银后不会生成新的补睫提醒（适用于「补睫毛」等后续维护项目）")
                if isLashTouchUp {
                    Text("收银后不生成补睫提醒")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 6)

            // Row 6: 描述 - reduced by 1/5 from full
            HStack(alignment: .top, spacing: 12) {
                Text("描述")
                    .frame(width: 72, alignment: .trailing)
                TextField("", text: $desc, axis: .vertical)
                    .frame(width: 320)
                    .lineLimit(3...5)
            }
            .padding(.vertical, 6)

            Divider().padding(.vertical, 8)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || categoryId == nil)
            }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 380, idealHeight: 440, maxHeight: 600)
        .onAppear {
            if let it = item {
                name = it.name; categoryId = it.categoryId
                price = it.price; durationMinutes = it.durationMinutes
                desc = it.itemDescription ?? ""
                sortOrder = it.sortOrder
                isLashTouchUp = it.isLashTouchUp
            } else {
                // 新建：默认排序从1开始（同分类兄弟数+1）
                sortOrder = defaultSortForCategory(categoryId)
            }
        }
        .onChange(of: categoryId) { _, newCat in
            if item == nil {
                sortOrder = defaultSortForCategory(newCat)
            }
        }
    }

    private func defaultSortForCategory(_ cid: UUID?) -> Int {
        guard let cid = cid else { return 1 }
        let siblings = allItems.filter { $0.categoryId == cid }
        return (siblings.map(\.sortOrder).max() ?? 0) + 1
    }

    private func save() {
        guard let cid = categoryId else { return }
        if let it = item {
            it.name = name; it.categoryId = cid; it.price = price
            it.durationMinutes = durationMinutes
            it.itemDescription = desc.isEmpty ? nil : desc
            it.sortOrder = sortOrder
            it.isLashTouchUp = isLashTouchUp
            onSave(it)
        } else {
            let it = ServiceItem(name: name, categoryId: cid, price: price,
                                 durationMinutes: durationMinutes,
                                 itemDescription: desc.isEmpty ? nil : desc,
                                 sortOrder: sortOrder,
                                 isLashTouchUp: isLashTouchUp)
            onSave(it)
        }
        dismiss()
    }
}
