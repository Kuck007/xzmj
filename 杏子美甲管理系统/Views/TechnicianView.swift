//
//  TechnicianView.swift
//  杏子美甲管理系统
//

import SwiftUI
import SwiftData

// MARK: - 星标评分组件
struct StarRating: View {
    @Binding var rating: Int
    var maxStars: Int = 5
    var size: Font = .system(size: 14)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...maxStars, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(size)
                    .foregroundStyle(star <= rating ? .orange : .secondary.opacity(0.4))
                    .symbolRenderingMode(.hierarchical)
                    .onTapGesture {
                        rating = star
                    }
            }
        }
    }
}

// MARK: - 技师行
struct TechnicianRow: View {
    let technician: Technician
    let serviceCount: Int
    var onTap: () -> Void
    var onShowActions: () -> Void

    var body: some View {
        HoverHighlightRow {
            HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(technician.name).font(.headline).foregroundStyle(.primary)
                    if !technician.isActive {
                        Text("已离职")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.red.opacity(0.1), in: Capsule())
                    }
                }
                Text(technician.phone).font(.subheadline).foregroundStyle(.secondary)
                if let bio = technician.bio, !bio.isEmpty {
                    Text(bio).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                StarRating(rating: .constant(technician.rating))
                Text("已服务 \(serviceCount) 次")
                    .font(.caption).foregroundStyle(.secondary)
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
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - 技师列表
struct TechnicianView: View {
    @Query(sort: \Technician.name) private var technicians: [Technician]
    @Query private var records: [NailServiceRecord]
    @Environment(\.modelContext) private var context
    @State private var showingAdd = false
    @State private var pendingDelete: Technician?
    @State private var actionsForTechnician: Technician?
    @State private var editingTechnician: Technician?
    @State private var selectedTechnician: Technician?

    private func serviceCount(for techId: UUID) -> Int {
        records.filter { $0.technicianId == techId }.count
    }

    var body: some View {
        // macOS NavigationSplitView 的 detail column 会自动处理 .navigationTitle/.toolbar/.searchable，NavigationStack 在 detail 里是冗余的，且会吃掉 sheet 首次 present 的进入动画
        VStack(spacing: 0) {
            Group {
                if technicians.isEmpty {
                    EmptyStateView(
                        systemImage: "person.crop.square",
                        title: "暂无技师",
                        message: "点击右上角「添加技师」添加店内的美甲师"
                    )
                } else {
                    List {
                        ForEach(technicians) { t in
                            TechnicianRow(
                                technician: t,
                                serviceCount: serviceCount(for: t.id),
                                onTap: { selectedTechnician = t },
                                onShowActions: { actionsForTechnician = t }
                            )
                            .swipeActions {
                                Button("删除", role: .destructive) { pendingDelete = t }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("技师管理")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Text("添加技师")
                    }
                    .buttonStyle(BrandPrimaryButtonStyle())
                }
            }
            .sheet(isPresented: Binding(get: { selectedTechnician != nil }, set: { if !$0 { selectedTechnician = nil } })) {
                if let t = selectedTechnician {
                    TechnicianDetailSheet(technician: t, serviceCount: serviceCount(for: t.id))
                }
                
            }
            .sheet(isPresented: Binding(get: { actionsForTechnician != nil }, set: { if !$0 { actionsForTechnician = nil } })) {
                if let t = actionsForTechnician {
                    TechnicianActionsSheet(
                        technician: t,
                        onEdit: {
                            actionsForTechnician = nil
                            editingTechnician = t
                        },
                        onDelete: {
                            actionsForTechnician = nil
                            pendingDelete = t
                        }
                    )
                }
                
            }
            .sheet(isPresented: Binding(get: { editingTechnician != nil }, set: { if !$0 { editingTechnician = nil } })) {
                if let t = editingTechnician {
                    TechnicianFormView(technician: t) { _ in }
                }
                
            }
            .sheet(isPresented: $showingAdd) {
                TechnicianFormView { context.insert($0) }
                
            }
            .alert("删除技师？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let t = pendingDelete { context.delete(t) }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("该技师将被永久删除，无法恢复。")
            }
        }
    }
}

// MARK: - 三点操作菜单
struct TechnicianActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let technician: Technician
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("技师操作").font(.headline)
                    Text(technician.name).font(.caption).foregroundStyle(.secondary)
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
                HStack { Text("修改技师"); Spacer(); Image(systemName: "pencil") }
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
                HStack { Text("删除技师"); Spacer(); Image(systemName: "trash") }
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

// MARK: - 技师详情（Sheet 弹出）
struct TechnicianDetailSheet: View {
    let technician: Technician
    let serviceCount: Int
    @Environment(\.dismiss) private var dismiss
    @State private var showingEdit = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("技师详情").font(.headline)
                    Text(technician.name + " · " + technician.phone)
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
                    LabeledContent("姓名", value: technician.name)
                    LabeledContent("电话", value: technician.phone)
                    LabeledContent("评分") {
                        StarRating(rating: .constant(technician.rating), size: .system(size: 16))
                    }
                    LabeledContent("累计服务", value: "\(serviceCount) 次")
                    LabeledContent("状态", value: technician.isActive ? "在职" : "已离职")
                }
                Section("技师简介") {
                    if let bio = technician.bio, !bio.isEmpty {
                        Text(bio).font(.body)
                    } else {
                        Text("暂无简介").foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("编辑") { showingEdit = true }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 440, idealHeight: 520, maxHeight: 700)
        .sheet(isPresented: $showingEdit) {
            TechnicianFormView(technician: technician) { _ in }
            
        }
    }
}

// MARK: - 技师表单（新建/编辑）
struct TechnicianFormView: View {
    @Environment(\.dismiss) private var dismiss
    var technician: Technician?
    var onSave: (Technician) -> Void

    @State private var name = ""
    @State private var phone = ""
    @State private var bio = ""
    @State private var rating: Int = 5
    @State private var isActive = true
    @State private var baseSalary = 0.0
    @State private var commissionPercent = 10.0

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("姓名", text: $name)
                TextField("电话", text: $phone)
                TextField("技师简介", text: $bio, axis: .vertical)
                    .lineLimit(3...5)
                LabeledContent("评分") {
                    StarRating(rating: $rating, size: .system(size: 18))
                }
                Section("薪资") {
                    TextField("底薪（元/月）", value: $baseSalary, format: .number)
                    LabeledContent("提成比例") {
                        HStack(spacing: 4) {
                            TextField("比例", value: $commissionPercent, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Text("%").foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("在职", isOn: $isActive)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || phone.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 420, minHeight: 360, idealHeight: 420, maxHeight: 600)
        .onAppear { load() }
    }

    private func load() {
        guard let t = technician else { return }
        name = t.name; phone = t.phone
        bio = t.bio ?? ""
        rating = t.rating; isActive = t.isActive
        baseSalary = t.baseSalary
        commissionPercent = t.commissionRate * 100
    }

    private func save() {
        let bioValue = bio.isEmpty ? nil : bio
        if let t = technician {
            t.name = name; t.phone = phone
            t.bio = bioValue; t.rating = rating; t.isActive = isActive
            t.baseSalary = baseSalary
            t.commissionRate = max(0, min(100, commissionPercent)) / 100
            onSave(t)
        } else {
            let t = Technician(
                name: name, phone: phone, bio: bioValue, rating: rating,
                totalServices: 0, baseSalary: baseSalary,
                commissionRate: max(0, min(100, commissionPercent)) / 100,
                isActive: isActive
            )
            onSave(t)
        }
        dismiss()
    }
}
