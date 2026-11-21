//
//  CompactCloudSheet.swift
//  杏子美甲管理系统
//
//  「整理云端」确认面板：输入系统密码 → 合并全部待处理包 → 生成并校验快照 → 删除保留窗口外的旧包。
//  网络与删除逻辑都在 SyncEngine.compactCloud；这里只负责交互与结果展示。
//

import SwiftUI

struct CompactCloudSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var report: SyncCompactReport?

    private var engine: SyncEngine { SyncEngine.shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let report {
                        successBlock(report)
                    } else {
                        form
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(width: 460, height: 400)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("整理云端").font(.headline)
                Text("将合并云端数据并删除多余旧包").font(.caption).foregroundStyle(.secondary)
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
            .keyboardShortcut(.cancelAction)
            .disabled(isWorking)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var form: some View {
        LabeledContent("云端包数", value: "\(engine.cloudPackageCount) 个")
        LabeledContent("保留规则", value: "最近 15 天 / 至少 50 / 最多 400 个包")
        LabeledContent("快照", value: "保留 3 份")
        LabeledContent("同步空间", value: engine.syncRoot)

        Text("整理会先合并全部待处理包（有任何包失败即中止），再生成新快照并回读校验；校验通过后才删除保留窗口外的旧包。删除不可撤销，但数据已包含在快照与合并前备份中。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        SecureField("系统密码（整理授权）", text: $password)
            .disabled(isWorking)

        HStack(spacing: 8) {
            Button(action: compact) {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("开始整理")
                }
            }
            .disabled(isWorking || password.isEmpty)

            Button("取消") { dismiss() }
                .disabled(isWorking)

            Spacer()
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func successBlock(_ report: SyncCompactReport) -> some View {
        Label("整理完成", systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.green)
        Text(summary(report))
            .font(.caption)
            .foregroundStyle(report.failures.isEmpty ? Color.secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("完成") { dismiss() }
            Spacer()
        }
    }

    private func compact() {
        isWorking = true
        errorMessage = nil
        let title = SyncSettingsSection.displayTitle
        Task {
            do {
                report = try await engine.compactCloud(password: password, displayTitle: title)
                password = ""
                _ = try? await engine.checkCloud()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func summary(_ report: SyncCompactReport) -> String {
        var text = "保留 \(report.keptPackages) 包，删除 \(report.deletedPackages) 包（\(report.deletedFiles) 个文件）"
        if report.deletedSnapshots > 0 { text += "，清理旧快照 \(report.deletedSnapshots) 份" }
        if report.deletedOrphans > 0 { text += "，清理孤儿文件 \(report.deletedOrphans) 个" }
        if !report.failures.isEmpty { text += "；\(report.failures.count) 项失败" }
        return text
    }
}
