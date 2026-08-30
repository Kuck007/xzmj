import SwiftUI
import SwiftData

/// 忘记密码界面：验证账号+安全码，重置登录密码
/// 标准流程：输入用户名 → 输入安全码 → 输入新密码 → 确认重置
struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var username = ""
    @State private var securityCode = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var resetError: String?
    @State private var isResetting = false
    @State private var showSecurityCode = false
    @State private var showNewPassword = false
    @State private var showConfirmPassword = false
    @State private var resetSuccess = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题
            HStack {
                Text("找回密码")
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

            if resetSuccess {
                // 重置成功视图
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("密码重置成功")
                        .font(.title3.bold())
                    Text("请使用新密码重新登录")
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
                // 重置表单
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.rotation")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.brand)
                        Text("重置登录密码")
                            .font(.title3.bold())
                        Text("请输入您的账号和安全码来验证身份")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 20)

                    VStack(spacing: 14) {
                        TextField("登录用户名", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                            .disabled(isResetting)

                        PasswordInputRow(title: "安全码", text: $securityCode, isRevealed: $showSecurityCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                            .disabled(isResetting)

                        Divider().frame(width: 300)

                        PasswordInputRow(title: "新登录密码", text: $newPassword, isRevealed: $showNewPassword)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                            .disabled(isResetting)

                        PasswordInputRow(title: "确认新密码", text: $confirmPassword, isRevealed: $showConfirmPassword)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                            .disabled(isResetting)
                            .onSubmit { doReset() }

                        Text("新密码至少 6 位")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 300, alignment: .leading)

                        if let error = resetError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(width: 300)
                        }

                        Button {
                            doReset()
                        } label: {
                            HStack(spacing: 8) {
                                if isResetting {
                                    ProgressView().controlSize(.small)
                                }
                                Text("重置密码")
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(width: 300)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(username.isEmpty || securityCode.isEmpty || newPassword.isEmpty || confirmPassword.isEmpty || isResetting)
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
        .frame(minWidth: 380, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func doReset() {
        guard newPassword == confirmPassword else {
            resetError = "两次输入的密码不一致"
            return
        }
        guard newPassword.count >= 6 else {
            resetError = "密码至少6位"
            return
        }

        isResetting = true
        resetError = nil

        // 验证安全码并重置密码
        let success = SessionManager.shared.resetPassword(
            username: username.trimmingCharacters(in: .whitespaces),
            securityCode: securityCode,
            newPassword: newPassword
        )

        isResetting = false

        if success {
            resetSuccess = true
        } else {
            resetError = "用户名或安全码错误"
        }
    }
}
