//
//  QuickMergeSheet.swift
//  杏子美甲管理系统
//
//  超管 / 管理员的云端快速合并入口：不进入设置，输入系统密码后直接合并。
//  合并逻辑仍复用 SyncEngine.mergeCloud（含合并前 bcom 加密备份）。
//

import SwiftUI

struct QuickMergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var isWorking = false
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var report: SyncMergeReport?

    private var engine: SyncEngine { SyncEngine.shared }
    private var summary: SyncCloudSummary? { engine.pendingRemoteSummary }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("合并云端数据").font(.headline)
                    Text("合并前会自动生成一份加密备份").font(.caption).foregroundStyle(.secondary)
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
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let report {
                        successBlock(report)
                    } else if isRefreshing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在检查云端…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let summary, !summary.isEmpty {
                        mergeForm(summary)
                    } else {
                        Text(engine.isEnabled ? "云端没有待合并的更新" : "本机尚未启用增量同步")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(width: 460, height: 360)
        .task { await refreshIfNeeded() }
    }

    // MARK: - 子视图

    @ViewBuilder
    private func mergeForm(_ summary: SyncCloudSummary) -> some View {
        LabeledContent("待合并", value: "\(summary.items.count) 个更新包")
        LabeledContent("总大小", value: ByteCountFormatter.string(fromByteCount: Int64(summary.totalBytes), countStyle: .file))
        LabeledContent("同步空间", value: engine.syncRoot)

        SecureField("系统密码（合并授权）", text: $password)
            .disabled(isWorking)

        HStack(spacing: 8) {
            Button(action: merge) {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("开始合并")
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
    private func successBlock(_ report: SyncMergeReport) -> some View {
        Label("合并完成", systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.green)
        Text(mergeSummary(report))
            .font(.caption)
            .foregroundStyle(report.failedPackages.isEmpty ? Color.secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("完成") { dismiss() }
            Spacer()
        }
    }

    // MARK: - 动作

    private func refreshIfNeeded() async {
        guard report == nil, engine.pendingRemoteSummary == nil, engine.isEnabled else { return }
        isRefreshing = true
        await engine.refreshPendingSummary()
        isRefreshing = false
    }

    private func merge() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                report = try await engine.mergeCloud(password: password,
                                                     displayTitle: SyncSettingsSection.displayTitle,
                                                     prefetched: engine.pendingRemoteSummary)
                password = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func mergeSummary(_ report: SyncMergeReport) -> String {
        var text = "应用 \(report.appliedPackages) 包，新增 \(report.inserted)，更新 \(report.updated)，删除 \(report.deleted)，跳过 \(report.skipped)，冲突 \(report.conflicts)"
        if let bcom = report.bcomFileName {
            text += "；合并前备份：\(bcom)"
        }
        if !report.failedPackages.isEmpty {
            text += "；失败 \(report.failedPackages.count) 包"
        }
        return text
    }
}
