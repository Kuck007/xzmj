//
//  SyncSettingsView.swift
//  杏子美甲管理系统
//
//  设置页「增量同步」区块（仅超管可见，由 SettingsView 控制）。
//  只负责输入同步口令与展示状态；所有网络与密钥操作都在 SyncEngine 里。
//

import SwiftUI

struct SyncSettingsSection: View {
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var systemPassword = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var isError = false
    @State private var cloudSummary: SyncCloudSummary?
    @State private var mergePassword = ""
    @State private var mergeReport: SyncMergeReport?
    @State private var showingCompactSheet = false
    /// 前台自动检查间隔（分钟，0 = 关闭）
    @AppStorage(SyncAutoCheckSettings.key) private var checkIntervalMinutes = SyncAutoCheckSettings.defaultValue

    private var engine: SyncEngine { SyncEngine.shared }

    var body: some View {
        Group {
            if engine.isEnabled {
                enabledRows
            } else {
                setupRows
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showingCompactSheet) {
            CompactCloudSheet()
        }
    }

    // MARK: - 已启用

    @ViewBuilder
    private var enabledRows: some View {
        HStack {
            Text("同步空间")
                .foregroundStyle(.secondary)
            Spacer()
            Text(engine.syncRoot)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }

        HStack {
            Text("状态")
                .foregroundStyle(.secondary)
            Spacer()
            statusBadge
        }

        HStack {
            Text("待上传")
                .foregroundStyle(.secondary)
            Spacer()
            Text(engine.pendingChangeCount == 0 ? "无" : "\(engine.pendingChangeCount) 包")
                .font(.caption)
                .foregroundStyle(engine.pendingChangeCount == 0 ? .secondary : Color.brand)
        }

        HStack {
            Text("云端包数")
                .foregroundStyle(.secondary)
            Spacer()
            Text(engine.cloudPackageCount == 0 ? "—" : "\(engine.cloudPackageCount) 包")
                .font(.caption)
                .foregroundStyle(engine.shouldSuggestCompact ? .orange : .secondary)
        }

        HStack {
            Text("上次上传")
                .foregroundStyle(.secondary)
            Spacer()
            if let last = engine.lastUploadAt {
                Text(Self.formatter.string(from: last))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("尚未上传")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Picker("前台自动检查", selection: $checkIntervalMinutes) {
            Text("关闭").tag(0)
            Text("30 分钟").tag(30)
            Text("1 小时").tag(60)
            Text("2 小时").tag(120)
            Text("4 小时").tag(240)
            Text("6 小时").tag(360)
            Text("8 小时").tag(480)
            Text("12 小时").tag(720)
            Text("24 小时").tag(1440)
        }
        .pickerStyle(.menu)
        .help("App 回到前台且距上次检查超过该间隔时，才查询云端是否有新数据")

        HStack(spacing: 8) {
            Button("检查云端") { checkCloud() }
                .disabled(isWorking)

            Button("合并云端") { mergeCloud() }
                .disabled(isWorking || mergePassword.isEmpty || !(cloudSummary?.hasWork ?? false))

            if SessionManager.shared.currentUser?.role == .superAdmin {
                Button("整理云端") { showingCompactSheet = true }
                    .disabled(isWorking || !engine.canCompact)
                    .help("云端超过 \(SyncRetentionPolicy.compactMinPackages) 个包后才允许整理")
            }

            #if DEBUG
            Button("立即上传") {
                Task { await SyncEngine.shared.uploadNow() }
            }
            .disabled(isWorking)
            #else
            // Release 也放开给超管：不用等 1 分钟防抖，可手动补传一次
            if SessionManager.shared.currentUser?.role == .superAdmin {
                Button("立即上传") {
                    Task { await SyncEngine.shared.uploadNow() }
                }
                .disabled(isWorking)
            }
            #endif

            Spacer()

            Button("停用同步") {
                SyncEngine.shared.disable()
                cloudSummary = nil
                mergeReport = nil
                message = "已停用本机上传（云端数据与密钥都保留，可随时重新启用）"
                isError = false
            }
        }
        .font(.caption)

        if let summary = cloudSummary {
            if summary.requiresSnapshot {
                Text(summary.items.isEmpty
                     ? "云端快照比本机新，合并时会先补齐快照"
                     : "云端 \(summary.items.count) 包待合并，并会先补齐一份新快照")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(summary.isEmpty
                     ? "云端没有待合并的更新"
                     : "云端 \(summary.items.count) 包待合并，共 \(ByteCountFormatter.string(fromByteCount: Int64(summary.totalBytes), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if cloudSummary?.hasWork == true {
            SecureField("系统密码（合并授权）", text: $mergePassword)
        }

        if let report = mergeReport {
            Text(mergeSummary(report))
                .font(.caption)
                .foregroundStyle(report.failedPackages.isEmpty ? .green : .orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if engine.shouldSuggestCompact {
            Text("云端已有 \(engine.cloudPackageCount) 个包，建议「整理云端」：会先合并数据，再只保留最近 15 天 / 至少 50 / 最多 400 个包。")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 未启用

    @ViewBuilder
    private var setupRows: some View {
        Text("使用「数据备份」中配置的第一台 WebDAV 服务器。同步口令独立于系统密码，至少 8 位，请自行妥善保管——丢失后云端数据无法解密。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        SecureField("同步口令（至少 8 位）", text: $passphrase)
        SecureField("再次输入同步口令", text: $confirmPassphrase)
        SecureField("系统密码（接入已有同步空间时必填）", text: $systemPassword)

        HStack {
            Button(action: enable) {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("启用同步")
                }
            }
            .disabled(isWorking || passphrase.isEmpty || confirmPassphrase.isEmpty)

            Spacer()
        }
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch engine.phase {
            case .disabled: return ("未启用", .secondary)
            case .idle: return ("空闲", .green)
            case .uploading: return ("上传中", Color.brand)
            case .failed: return ("上传失败", .red)
            }
        }()
        return Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func enable() {
        guard passphrase == confirmPassphrase else {
            message = "两次输入的同步口令不一致"
            isError = true
            return
        }
        isWorking = true
        message = nil
        let title = Self.displayTitle
        Task {
            do {
                try await SyncEngine.shared.enable(passphrase: passphrase,
                                                   systemPassword: systemPassword,
                                                   displayTitle: title)
                message = "同步已启用，后续改动会在 1 分钟内静默加密上传"
                isError = false
                passphrase = ""
                confirmPassphrase = ""
                systemPassword = ""
            } catch {
                message = error.localizedDescription
                isError = true
            }
            isWorking = false
        }
    }

    private func checkCloud() {
        isWorking = true
        message = nil
        Task {
            do {
                let summary = try await SyncEngine.shared.checkCloud()
                cloudSummary = summary
                message = nil
                isError = false
            } catch {
                message = error.localizedDescription
                isError = true
            }
            isWorking = false
        }
    }

    private func mergeCloud() {
        isWorking = true
        message = nil
        mergeReport = nil
        let title = Self.displayTitle
        Task {
            do {
                let report = try await SyncEngine.shared.mergeCloud(password: mergePassword,
                                                                    displayTitle: title,
                                                                    prefetched: cloudSummary)
                mergeReport = report
                mergePassword = ""
                cloudSummary = try? await SyncEngine.shared.checkCloud()
                isError = false
            } catch {
                message = error.localizedDescription
                isError = true
            }
            isWorking = false
        }
    }

    private func mergeSummary(_ report: SyncMergeReport) -> String {
        var text = report.appliedSnapshot ? "已先应用快照；" : ""
        text += "合并完成：\(report.appliedPackages) 包，新增 \(report.inserted)，更新 \(report.updated)，删除 \(report.deleted)，跳过 \(report.skipped)，冲突 \(report.conflicts)"
        if let bcom = report.bcomFileName {
            text += "；合并前备份：\(bcom)"
        }
        if !report.failedPackages.isEmpty {
            text += "；失败 \(report.failedPackages.count) 包"
        }
        return text
    }

    static var displayTitle: String {
        let name = UserDefaults.standard.string(forKey: "app.displayName") ?? ""
        return name.isEmpty ? "杏子美甲管理系统" : name
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
