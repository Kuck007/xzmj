import SwiftUI
import SwiftData

/// 首次启动初始化界面：创建超级管理员账号
/// 当系统中没有任何 User 时显示
struct InitialSetupView: View {
    @Environment(\.modelContext) private var context

    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var securityCode = ""
    @State private var confirmSecurityCode = ""
    @State private var error: String?
    @State private var isCreating = false
    @State private var showPassword = false
    @State private var showConfirmPassword = false
    @State private var showSecurityCode = false
    @State private var showConfirmSecurityCode = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.brand)
                Text("初始化系统")
                    .font(.title2.bold())
                Text("创建超级管理员账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 32)

            VStack(spacing: 14) {
                TextField("用户名（登录用）", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .disabled(isCreating)

                TextField("显示名称", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .disabled(isCreating)

                PasswordInputRow(title: "登录密码", text: $password, isRevealed: $showPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .disabled(isCreating)

                PasswordInputRow(title: "确认登录密码", text: $confirmPassword, isRevealed: $showConfirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .disabled(isCreating)

                Divider().frame(width: 300)

                PasswordInputRow(title: "安全码（找回密码用）", text: $securityCode, isRevealed: $showSecurityCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .disabled(isCreating)

                PasswordInputRow(title: "确认安全码", text: $confirmSecurityCode, isRevealed: $showConfirmSecurityCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .disabled(isCreating)
                    .onSubmit { create() }

                Text("密码至少 6 位，安全码用于忘记密码时验证身份，请妥善保管")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 300, alignment: .leading)

                if let error = error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(width: 300)
                }

                Button {
                    create()
                } label: {
                    HStack(spacing: 8) {
                        if isCreating {
                            ProgressView().controlSize(.small)
                        }
                        Text("创建并登录")
                            .frame(maxWidth: .infinity)
                    }
                    .frame(width: 300)
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.isEmpty || displayName.isEmpty || password.isEmpty || confirmPassword.isEmpty || securityCode.isEmpty || confirmSecurityCode.isEmpty || isCreating)
                .keyboardShortcut(.defaultAction)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func create() {
        guard password == confirmPassword else {
            error = "两次输入的密码不一致"
            return
        }
        guard password.count >= 6 else {
            error = "密码至少6位"
            return
        }
        guard securityCode == confirmSecurityCode else {
            error = "两次输入的安全码不一致"
            return
        }
        guard securityCode.count >= 4 else {
            error = "安全码至少4位"
            return
        }
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmedUser.isEmpty else {
            error = "用户名不能为空"
            return
        }
        guard !trimmedName.isEmpty else {
            error = "显示名称不能为空"
            return
        }
        guard trimmedUser != trimmedName else {
            error = "用户名和显示名称不能相同"
            return
        }

        isCreating = true
        error = nil

        let user = User(
            username: trimmedUser,
            passwordHash: SessionManager.hash(password),
            securityCodeHash: SessionManager.hash(securityCode),
            displayName: trimmedName,
            role: .superAdmin
        )
        context.insert(user)

        do {
            try context.save()
            // 创建成功后自动登录
            SessionManager.shared.login(username: user.username, password: password)
        } catch {
            self.error = "创建失败：\(error.localizedDescription)"
            isCreating = false
        }
    }
}
