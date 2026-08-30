import SwiftUI

/// 登录界面
struct LoginView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var error: String?
    @State private var isLoggingIn = false
    @State private var showingForgotPassword = false
    @State private var showingRegister = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo / 标题
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.brand)
                Text("杏子美甲管理系统")
                    .font(.title2.bold())
                Text("请登录以继续")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 40)

            // 登录表单
            VStack(spacing: 16) {
                TextField("用户名", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .disabled(isLoggingIn)

                PasswordInputRow(title: "密码", text: $password, isRevealed: $showPassword)
                    .frame(width: 280)
                    .disabled(isLoggingIn)
                    .onSubmit { doLogin() }

                if let error = error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    doLogin()
                } label: {
                    HStack(spacing: 8) {
                        if isLoggingIn {
                            ProgressView().controlSize(.small)
                        }
                        Text("登录")
                            .frame(maxWidth: .infinity)
                    }
                    .frame(width: 280)
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.isEmpty || password.isEmpty || isLoggingIn)
                .keyboardShortcut(.defaultAction)

                // 辅助链接
                HStack(spacing: 20) {
                    Button {
                        showingForgotPassword = true
                    } label: {
                        Text("忘记密码")
                            .font(.caption)
                            .foregroundStyle(Color.brand)
                    }
                    .buttonStyle(.plain)

                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Button {
                        showingRegister = true
                    } label: {
                        Text("注册账号")
                            .font(.caption)
                            .foregroundStyle(Color.brand)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // 底部版本信息
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingForgotPassword) {
            ForgotPasswordView()
                .frame(minWidth: 400, minHeight: 500)
        }
        .sheet(isPresented: $showingRegister) {
            RegisterView()
                .frame(minWidth: 400, minHeight: 550)
        }
    }

    private func doLogin() {
        isLoggingIn = true
        error = nil

        // 登录在主线程同步执行（用户表数据量极小，无性能问题）
        let success = SessionManager.shared.login(username: username, password: password)

        isLoggingIn = false
        if !success {
            error = "用户名或密码错误，或账号已被禁用"
            password = ""
        }
    }
}
