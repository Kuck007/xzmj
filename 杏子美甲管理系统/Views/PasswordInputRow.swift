//
//  PasswordInputRow.swift
//  杏子美甲管理系统
//
//  通用密码输入行组件：带小眼睛切换显示/隐藏密码。
//  所有涉及密码输入的地方统一使用此组件。
//

import SwiftUI

/// 通用密码输入行（带显示/隐藏切换）
struct PasswordInputRow: View {
    let title: String
    @Binding var text: String
    @Binding var isRevealed: Bool
    var placeholder: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if isRevealed {
                TextField(placeholder ?? title, text: $text)
                    .textFieldStyle(.roundedBorder)
            } else {
                SecureField(placeholder ?? title, text: $text)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
