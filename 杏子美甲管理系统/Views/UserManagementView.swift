//
//  UserManagementView.swift
//  杏子美甲管理系统
//
//  用户管理界面（超管专属）：用户列表、新增、编辑、禁用/启用、配置员工模块权限。
//

import SwiftUI
import SwiftData

struct UserManagementView: View {
    @Query(sort: \User.username) private var users: [User]
    @Environment(\.modelContext) private var context
    @State private var session = SessionManager.shared

    @State private var showingAddUser = false
    @State private var editingUser: User?
    @State private var pendingDelete: User?
    @State private var actionUser: User?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("用户管理")
                        .font(.title2.weight(.bold))
                    Text("管理系统账号和权限")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingAddUser = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text("新增用户")
                    }
                    .frame(width: 100)
                }
                .buttonStyle(BrandPrimaryButtonStyle())
                .disabled(session.currentUser?.role != .superAdmin)
            }
            .padding(16)
            Divider()

            if users.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "暂无用户",
                    systemImage: "person.2.slash",
                    description: Text("点击右上角「新增用户」添加账号")
                )
                Spacer()
            } else {
                List {
                    ForEach(users) { user in
                        userRow(user)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                actionUser = user
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("删除", role: .destructive) {
                                    if user.username != session.currentUser?.username {
                                        pendingDelete = user
                                    }
                                }
                                .disabled(user.username == session.currentUser?.username)
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showingAddUser) {
            UserFormView(
                mode: .newUser,
                onSave: { userData in
                    createUser(userData)
                    showingAddUser = false
                }
            )
        }
        .sheet(isPresented: Binding(get: { editingUser != nil }, set: { if !$0 { editingUser = nil } })) {
            if let user = editingUser {
                UserFormView(
                    mode: .existing(user),
                    onSave: { userData in
                        updateUser(user, data: userData)
                        editingUser = nil
                    }
                )
            }
        }
        .sheet(isPresented: Binding(get: { actionUser != nil }, set: { if !$0 { actionUser = nil } })) {
            if let user = actionUser {
                userActionSheet(user)
            }
        }
        .alert("确认删除", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let user = pendingDelete {
                    context.delete(user)
                    try? context.save()
                    pendingDelete = nil
                }
            }
        } message: {
            Text("确定要删除用户「\(pendingDelete?.displayName ?? "")」吗？此操作不可撤销。")
        }
    }

    @ViewBuilder
    private func userRow(_ user: User) -> some View {
        HoverHighlightRow {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(user.isActive ? Color.brand.opacity(0.15) : Color.brandMono.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.fill")
                        .foregroundStyle(user.isActive ? Color.brand : Color.brandMono)
                        .font(.system(size: 14, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(user.displayName)
                            .font(.body.weight(.medium))
                        if !user.isActive {
                            Text("已禁用")
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.red.opacity(0.12)))
                        }
                        if user.username == session.currentUser?.username {
                            Text("当前")
                                .font(.caption2)
                                .foregroundStyle(Color.brand)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.brand.opacity(0.12)))
                        }
                    }
                    HStack(spacing: 6) {
                        Text(user.role.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(user.username)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if user.role == .staff {
                            Text("· \(user.allowedModules.count) 个模块")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                // 右侧操作区：启用/禁用按钮 + 三点
                HStack(spacing: 6) {
                    if user.username != session.currentUser?.username {
                        Button {
                            user.isActive.toggle()
                            try? context.save()
                        } label: {
                            if user.isActive {
                                Label("禁用", systemImage: "person.slash")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.orange.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.orange)
                            } else {
                                Label("启用", systemImage: "person.fill.checkmark")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.green.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                    Button {
                        actionUser = user
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
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func userActionSheet(_ user: User) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(user.displayName)
                    .font(.headline)
                Spacer()
                Button {
                    actionUser = nil
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            VStack(spacing: 0) {
                Button {
                    actionUser = nil
                    editingUser = user
                } label: {
                    HStack {
                        Image(systemName: "pencil")
                            .foregroundStyle(Color.brand)
                            .frame(width: 24)
                        Text("编辑用户")
                        Spacer()
                        Text("修改信息、权限")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 40)

                Button {
                    actionUser = nil
                    pendingDelete = user
                } label: {
                    HStack {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                            .frame(width: 24)
                        Text("删除用户")
                        Spacer()
                        Text("不可恢复")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(user.username == session.currentUser?.username)
            }
        }
        .frame(minWidth: 360)
    }

    private func createUser(_ data: UserFormData) {
        let user = User(
            username: data.username,
            passwordHash: SessionManager.hash(data.password),
            securityCodeHash: SessionManager.hash(data.securityCode),
            displayName: data.displayName,
            role: data.role,
            isActive: data.isActive,
            allowedModules: data.role == .superAdmin ? [] : data.allowedModules
        )
        context.insert(user)
        try? context.save()
    }

    private func updateUser(_ user: User, data: UserFormData) {
        user.displayName = data.displayName
        user.role = data.role
        user.isActive = data.isActive
        if data.role == .superAdmin {
            user.allowedModules = []
        } else {
            user.allowedModules = data.allowedModules
        }
        if !data.password.isEmpty {
            user.passwordHash = SessionManager.hash(data.password)
        }
        if !data.securityCode.isEmpty {
            user.securityCodeHash = SessionManager.hash(data.securityCode)
        }
        try? context.save()
    }
}

// MARK: - 表单数据模型
private struct UserFormData {
    var username: String
    var displayName: String
    var password: String
    var securityCode: String
    var role: UserRole
    var isActive: Bool
    var allowedModules: [String]

    /// 从 SidebarItem 枚举动态生成可配置模块列表（仪表盘不在此列表中）
    /// 新增模块时自动出现在此处
    static var allModules: [(id: String, name: String, icon: String)] {
        SidebarItem.allCases.filter { $0 != .dashboard }.map {
            (id: $0.moduleId, name: $0.rawValue, icon: $0.icon)
        }
    }

    /// 员工默认权限：7 个基础业务模块
    static let staffDefault: [String] = [
        "dashboard", "appointments", "records", "orders",
        "customers", "inventory", "lashReminder"
    ]

    /// 管理员默认权限：全部模块（不含用户管理）
    static var adminDefault: [String] {
        allModules.filter { $0.id != "userManagement" }.map { $0.id }
    }
}

// MARK: - 用户表单视图
private struct UserFormView: View {
    enum Mode: Equatable {
        case newUser
        case existing(User)
    }

    let mode: Mode
    let onSave: (UserFormData) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var data: UserFormData
    @State private var confirmPassword = ""
    @State private var confirmSecurityCode = ""
    @State private var showPassword = false
    @State private var showConfirmPassword = false
    @State private var showSecurityCode = false
    @State private var showConfirmSecurityCode = false
    @State private var error: String?

    private var existingUser: User? {
        if case .existing(let user) = mode { return user }
        return nil
    }

    private var isEditMode: Bool {
        if case .existing = mode { return true }
        return false
    }

    init(mode: Mode, onSave: @escaping (UserFormData) -> Void) {
        self.mode = mode
        self.onSave = onSave
        if case .existing(let user) = mode {
            _data = State(initialValue: UserFormData(
                username: user.username,
                displayName: user.displayName,
                password: "",
                securityCode: "",
                role: user.role,
                isActive: user.isActive,
                allowedModules: user.allowedModules
            ))
        } else {
            _data = State(initialValue: UserFormData(
                username: "",
                displayName: "",
                password: "",
                securityCode: "",
                role: .staff,
                isActive: true,
                allowedModules: UserFormData.staffDefault
            ))
        }
    }

    /// 角色切换时更新默认权限
    private func updateDefaultModules(for newRole: UserRole) {
        if newRole == .superAdmin {
            data.allowedModules = []
        } else if newRole == .admin {
            data.allowedModules = UserFormData.adminDefault
        } else {
            data.allowedModules = UserFormData.staffDefault
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(mode == .newUser ? "新增用户" : "编辑用户")
                    .font(.headline)
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
                    TextField("登录用户名", text: $data.username)
                        .disabled(isEditMode)
                        .foregroundStyle(isEditMode ? .secondary : .primary)
                    TextField("显示名称", text: $data.displayName)
                }

                Section("角色") {
                    Picker("角色", selection: $data.role) {
                        Text("员工").tag(UserRole.staff)
                        Text("管理员").tag(UserRole.admin)
                        Text("超级管理员").tag(UserRole.superAdmin)
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: data.role) { _, newRole in
                        updateDefaultModules(for: newRole)
                    }
                }

                Section("账号状态") {
                    Toggle("启用账号", isOn: $data.isActive)
                }

                if data.role != .superAdmin {
                    Section("模块权限") {
                        Text(data.role == .admin ? "勾选该管理员可访问的功能模块" : "勾选该员工可访问的功能模块")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                        ForEach(UserFormData.allModules, id: \.id) { module in
                            Toggle(isOn: Binding(
                                get: { data.allowedModules.contains(module.id) },
                                set: { enabled in
                                    if enabled {
                                        if !data.allowedModules.contains(module.id) {
                                            data.allowedModules.append(module.id)
                                        }
                                    } else {
                                        data.allowedModules.removeAll { $0 == module.id }
                                    }
                                }
                            )) {
                                Label(module.name, systemImage: module.icon)
                            }
                        }
                    }
                }

                Section(mode == .newUser ? "设置登录密码" : "重置登录密码（可选）") {
                    PasswordInputRow(title: "登录密码", text: $data.password, isRevealed: $showPassword)
                    if mode == .newUser || !data.password.isEmpty {
                        PasswordInputRow(title: "确认密码", text: $confirmPassword, isRevealed: $showConfirmPassword)
                    }
                    if isEditMode {
                        Text("留空则不修改密码")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(mode == .newUser ? "设置安全码" : "重置安全码（可选）") {
                    PasswordInputRow(title: "安全码", text: $data.securityCode, isRevealed: $showSecurityCode)
                    if mode == .newUser || !data.securityCode.isEmpty {
                        PasswordInputRow(title: "确认安全码", text: $confirmSecurityCode, isRevealed: $showConfirmSecurityCode)
                    }
                    if isEditMode {
                        Text("留空则不修改安全码，安全码用于忘记密码时验证身份")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("安全码用于忘记密码时验证身份，请妥善保管")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(mode == .newUser ? "创建用户" : "保存修改") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: data.role == .staff ? 580 : 380)
    }

    private var isValid: Bool {
        if data.username.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if data.displayName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if mode == .newUser {
            if data.password.count < 6 { return false }
            if data.securityCode.count < 4 { return false }
        } else {
            if !data.password.isEmpty && data.password.count < 6 { return false }
            if !data.securityCode.isEmpty && data.securityCode.count < 4 { return false }
        }
        if !data.password.isEmpty && data.password != confirmPassword { return false }
        if !data.securityCode.isEmpty && data.securityCode != confirmSecurityCode { return false }
        return true
    }

    private func save() {
        let trimmedUser = data.username.trimmingCharacters(in: .whitespaces)
        let trimmedName = data.displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmedUser.isEmpty else { error = "用户名不能为空"; return }
        guard !trimmedName.isEmpty else { error = "显示名称不能为空"; return }
        guard trimmedUser != trimmedName else { error = "用户名和显示名称不能相同"; return }

        if mode == .newUser || !data.password.isEmpty {
            guard data.password.count >= 6 else { error = "密码至少6位"; return }
            guard data.password == confirmPassword else { error = "两次输入的密码不一致"; return }
        }

        if mode == .newUser || !data.securityCode.isEmpty {
            guard data.securityCode.count >= 4 else { error = "安全码至少4位"; return }
            guard data.securityCode == confirmSecurityCode else { error = "两次输入的安全码不一致"; return }
        }

        data.username = trimmedUser
        data.displayName = trimmedName
        onSave(data)
    }
}
