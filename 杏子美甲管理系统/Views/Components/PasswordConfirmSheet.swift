import SwiftUI

// MARK: - 密码输入确认弹窗（内容可实时刷新，用于删除校验）
/// 通用密码确认弹窗：用于需要系统安全密码验证的操作（删除、修改等）
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
