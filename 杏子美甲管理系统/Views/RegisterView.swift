import SwiftUI
import SwiftData

/// 注册界面：创建新员工账号
/// 默认注册为员工（staff）角色，由管理员/超管在用户管理中分配权限
struct RegisterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var securityCode = ""
    @State private var confirmSecurityCode = ""
    @State private var registerError: String?
    @State private var isRegistering = false
    @State private var showPassword = false
    @State private var showConfirmPassword = false
    @State private var showSecurityCode = false
    @State private var showConfirmSecurityCode = false
    @State private var registerSuccess = false

    /// 员工默认权限：7 个基础业务模块
    private static let staffDefaultModules = [
        "dashboard", "appointments", "records", "orders",
        "customers", "inventory", "lashReminder"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题
            HStack {
                Text("注册账号")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            if registerSuccess {
                // 注册成功视图
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("注册成功")
                        .font(.title3.bold())
                    Text("请等待管理员分配权限后登录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        dismiss()
                    } label: {
                        Text("返回登录")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(width: 200)
                    .keyboardShortcut(.defaultAction)
                    Spacer()
                }
                .padding()
            } else {
                // 注册表单
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.brand)
                        Text("创建员工账号")
                            .font(.title3.bold())
                        Text("注册后默认为员工角色，需管理员分配模块权限")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)

                    VStack(spacing: 14) {
                        TextField("登录用户名", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                            .disabled(isRegistering)

                        TextField("显示名称", text: $displayName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                            .disabled(isRegistering)

                        PasswordInputRow(title: "登录密码", text: $password, isRevealed: $showPassword)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                            .disabled(isRegistering)

                        PasswordInputRow(title: "确认登录密码", text: $confirmPassword, isRevealed: $showConfirmPassword)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                            .disabled(isRegistering)

                        Divider().frame(width: 300)

                        PasswordInputRow(title: "安全码（找回密码用）", text: $securityCode, isRevealed: $showSecurityCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                            .disabled(isRegistering)

                        PasswordInputRow(title: "确认安全码", text: $confirmSecurityCode, isRevealed: $showConfirmSecurityCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                            .disabled(isRegistering)
                            .onSubmit { doRegister() }

                        Text("密码至少 6 位，安全码至少 4 位，用于忘记密码时验证身份")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 300, alignment: .leading)

                        if let error = registerError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(width: 300)
                        }

                        Button {
                            doRegister()
                        } label: {
                            HStack(spacing: 8) {
                                if isRegistering {
                                    ProgressView().controlSize(.small)
                                }
                                Text("注册账号")
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(width: 300)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(username.isEmpty || displayName.isEmpty || password.isEmpty || confirmPassword.isEmpty || securityCode.isEmpty || confirmSecurityCode.isEmpty || isRegistering)
                        .keyboardShortcut(.defaultAction)
                    }

                    Spacer()

                    // 返回登录链接
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.left")
                            Text("返回登录")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
        }
        .frame(minWidth: 380, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func doRegister() {
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)

        guard !trimmedUser.isEmpty else {
            registerError = "用户名不能为空"
            return
        }
        guard !trimmedName.isEmpty else {
            registerError = "显示名称不能为空"
            return
        }
        guard trimmedUser != trimmedName else {
            registerError = "用户名和显示名称不能相同"
            return
        }
        guard password == confirmPassword else {
            registerError = "两次输入的密码不一致"
            return
        }
        guard password.count >= 6 else {
            registerError = "密码至少6位"
            return
        }
        guard securityCode == confirmSecurityCode else {
            registerError = "两次输入的安全码不一致"
            return
        }
        guard securityCode.count >= 4 else {
            registerError = "安全码至少4位"
            return
        }

        isRegistering = true
        registerError = nil

        // 检查用户名是否已存在
        let existingUser = SessionManager.shared.findUser(username: trimmedUser)
        if existingUser != nil {
            registerError = "用户名已存在，请更换"
            isRegistering = false
            return
        }

        // 创建员工账号
        let user = User(
            username: trimmedUser,
            passwordHash: SessionManager.hash(password),
            securityCodeHash: SessionManager.hash(securityCode),
            displayName: trimmedName,
            role: .staff,
            allowedModules: Self.staffDefaultModules
        )
        context.insert(user)

        do {
            try context.save()
            registerSuccess = true
        } catch {
            registerError = "注册失败：\(error.localizedDescription)"
            isRegistering = false
        }
    }
}
