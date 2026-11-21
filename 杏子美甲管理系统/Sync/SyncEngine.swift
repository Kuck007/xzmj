//
//  SyncEngine.swift
//  杏子美甲管理系统
//
//  增量同步引擎（阶段 2B）：静默加密上传。
//  上传不提供手动按钮（Debug 例外）；触发点：保存后 3 分钟防抖 + 启动后 30 秒补传 + 失败退避重试。
//  合并/下载不在此文件（阶段 3）。
//

import CryptoKit
import Foundation
import Observation

// MARK: - 云端检查 / 合并结果

struct SyncCloudItem: Identifiable {
    var meta: SyncChangeSetMeta
    var id: String { meta.changeId }
}

struct SyncCloudSummary {
    var items: [SyncCloudItem] = []
    var orphanEncNames: [String] = []
    var totalBytes: Int = 0
    /// 本次检查列到的全部云端文件名；下载时复用，避免每个文件都重复 PROPFIND。
    var knownFileNames: Set<String> = []

    var isEmpty: Bool { items.isEmpty }
}

struct SyncMergeReport {
    var appliedPackages = 0
    var inserted = 0
    var updated = 0
    var deleted = 0
    var skipped = 0
    var conflicts = 0
    var failedPackages: [String] = []
    var bcomFileName: String?
}

@MainActor
@Observable
final class SyncEngine {
    static let shared = SyncEngine()

    enum Phase: Equatable {
        case disabled
        case idle
        case uploading
        case failed(String)
    }

    // MARK: - 对外状态（设置页只读）

    private(set) var phase: Phase = .disabled
    private(set) var pendingChangeCount = 0
    private(set) var lastUploadAt: Date?
    private(set) var syncRoot = ""
    private(set) var storeIdShort = ""
    /// 启动自动检查得到的云端待合并结果；非空时由界面提示合并。
    private(set) var pendingRemoteSummary: SyncCloudSummary?
    /// 设置图标红点 / 「待同步」胶囊：跨启动保留，合并成功或检查为空时清除。
    private(set) var hasPendingRemoteBadge: Bool = UserDefaults.standard.bool(forKey: SyncEngine.badgeKey)

    var isEnabled: Bool { state != nil && storeKey != nil }

    // MARK: - 内部

    private static let badgeKey = "sync.pendingMergeBadge"
    private let store = SyncStateStore.shared
    private var state: SyncState?
    private var storeKey: SymmetricKey?
    private var debounceTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var launchCheckTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var isBusy = false
    /// 每个登录会话只做一次启动云端检查
    private var sessionCheckToken = UUID()
    private var sessionCheckDone = false

    private init() {}

    // MARK: - 启动

    /// AppCore 就绪后调用：恢复已启用的同步，安排启动补传与一次云端检查。
    func startAfterBootstrap() {
        guard let saved = try? store.loadState(),
              let key = SyncKeychain.storeKey(storeId: saved.storeId) else { return }
        state = saved
        storeKey = key
        syncRoot = saved.syncRoot
        storeIdShort = String(saved.storeId.suffix(8))
        lastUploadAt = saved.lastUploadAt.map { Date(timeIntervalSince1970: $0) }
        phase = .idle
        refreshPendingCount()

        startupTask?.cancel()
        startupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.uploadNow()
        }

        scheduleLaunchCloudCheck()
    }

    /// 启动云端检查：等 Sparkle 更新周期结束后立即执行，30 秒内没结束则兜底执行；
    /// 每个登录会话只执行一次（重登会重新计时）。
    private func scheduleLaunchCloudCheck() {
        launchCheckTask?.cancel()
        let token = UUID()
        sessionCheckToken = token
        sessionCheckDone = false

        launchCheckTask = Task { [weak self] in
            if AppDelegate.updateCycleFinishedThisLaunch {
                // 更新检查已完成（已是最新 / 取消 / 失败），留 2 秒让界面稳定
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            } else {
                // 等待更新周期结束，最多 30 秒（跳过版本 / 离线时走兜底）
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    if AppDelegate.updateCycleFinishedThisLaunch { break }
                }
            }
            guard !Task.isCancelled else { return }
            await self?.runLaunchCloudCheck(token: token)
        }
    }

    private func runLaunchCloudCheck(token: UUID) async {
        guard token == sessionCheckToken, !sessionCheckDone else { return }
        guard state != nil, storeKey != nil, state?.recoveryRequired == false else { return }
        sessionCheckDone = true
        await refreshPendingSummary()
    }

    /// 重新检查云端并刷新待合并结果 / 红点（只读，不下载正文、不改数据）。
    func refreshPendingSummary() async {
        guard state != nil, storeKey != nil, state?.recoveryRequired == false else { return }
        do {
            let summary = try await checkCloud()
            pendingRemoteSummary = summary.isEmpty ? nil : summary
            updatePendingBadge(!summary.isEmpty)
        } catch {
            // 断网 / NAS 未开：静默，保留原有红点状态
        }
    }

    private func updatePendingBadge(_ value: Bool) {
        guard hasPendingRemoteBadge != value else { return }
        hasPendingRemoteBadge = value
        UserDefaults.standard.set(value, forKey: Self.badgeKey)
    }

    /// 弹窗处理完后清除内存结果，避免同一次检查重复弹出；红点与胶囊保留。
    func dismissPendingRemoteSummary() {
        pendingRemoteSummary = nil
    }

    // MARK: - 启用 / 停用

    /// 启用同步（首台）或接入已有同步空间（新机/恢复后对账）。
    /// - 首台：创建 store.json、storeKey、钥匙信封与首份 Snapshot。
    /// - 新机（本机为空，云端已有数据）：采用云端 storeId、生成新 writerId、用口令解封云端 storeKey、
    ///   下载最新 Snapshot + 未应用包完成初始化（方案 §10.2）。
    /// - 恢复后（recoveryRequired）：先与云端对账，再允许上传（方案 §10.4）。
    func enable(passphrase: String, systemPassword: String, displayTitle: String) async throws {
        try SyncCrypto.validatePassphrase(passphrase)
        guard let credentials = firstCredentials() else {
            throw SyncError.cryptoFailed("请先在「数据备份」中配置一台可用的 WebDAV 服务器")
        }

        var (loaded, _) = try SyncIdentity.loadOrCreateState(store: store,
                                                             displayTitle: displayTitle,
                                                             syncRoot: SyncIdentity.syncRoot(title: displayTitle))
        var s = loaded
        let ctx = CloudContext(url: credentials.url,
                               username: credentials.username,
                               password: credentials.password,
                               remoteDir: s.syncRoot)

        // 目录：先 PROPFIND，缺失则逐级 MKCOL（顶层共享文件夹需用户事先建好）
        do {
            _ = try await WebDAVBackup.shared.listBackups(url: ctx.url,
                                                          username: ctx.username,
                                                          password: ctx.password,
                                                          remoteDir: ctx.remoteDir)
        } catch {
            do {
                try await WebDAVBackup.shared.ensureRemoteDir(url: ctx.url,
                                                               username: ctx.username,
                                                               password: ctx.password,
                                                               remoteDir: ctx.remoteDir)
                _ = try await WebDAVBackup.shared.listBackups(url: ctx.url,
                                                              username: ctx.username,
                                                              password: ctx.password,
                                                              remoteDir: ctx.remoteDir)
            } catch let createError {
                let parent = ctx.remoteDir.split(separator: "/").dropLast().joined(separator: "/")
                throw SyncError.cryptoFailed("同步目录「\(ctx.remoteDir)」不可用：\(createError.localizedDescription)。请确认上一级目录「\(parent)」已在服务器上手动创建，且账号有写权限")
            }
        }

        // 读取云端 store.json
        var remoteDescriptor: SyncStoreDescriptor?
        if let remoteData = try await downloadFile(name: SyncCodec.storeFileName, ctx: ctx) {
            remoteDescriptor = try SyncCodec.decode(SyncStoreDescriptor.self, from: remoteData)
        }
        let remoteInitialized = remoteDescriptor != nil

        // 新机接入：本机没有任何业务数据时，采用云端 storeId 与新 writerId
        var adoptedRemoteStore = false
        if let remote = remoteDescriptor, remote.storeId != s.storeId {
            let rows = try AppCore.shared.syncSnapshotRows()
            guard rows.totalRowCount == 0 || AppCore.shared.isPristineDefaultInstall() else {
                throw SyncError.cryptoFailed("云端已存在另一套数据，且本机已有真实业务数据。为避免误合并已停止。若确认以云端为准，请先导出备份，清空本机数据后再启用。")
            }
            // 全新安装自带 5 分类 + 4 占位项目：接入云端前先清掉，避免与云端数据重复
            if rows.totalRowCount > 0 {
                try AppCore.shared.clearDefaultSeed()
                try await AppCore.shared.reloadAfterRemotePackage()
            }
            s.storeId = remote.storeId
            s.writerId = SyncCodec.newWriterId()
            s.writerSeq = 0
            s.records.removeAll()
            s.appliedChangeIds.removeAll()
            s.latestSnapshotId = nil
            adoptedRemoteStore = true
            try store.saveState(s)
        } else if let remote = remoteDescriptor {
            try SyncIdentity.verify(remote: remote, matches: s)
        }

        // 接入/恢复已有云端空间需要超管系统密码授权（首台不要求）
        if remoteInitialized || s.recoveryRequired {
            guard SecurityManager.shared.verifyPassword(systemPassword) else {
                throw SyncError.cryptoFailed("系统密码不正确（接入已有同步空间需要超管授权）")
            }
        }

        // storeKey：Keychain 有则复用；云端已初始化但本机没有则用口令解封；否则新建
        let key: SymmetricKey
        if let existing = SyncKeychain.storeKey(storeId: s.storeId) {
            key = existing
        } else if remoteInitialized {
            key = try await adoptRemoteStoreKey(passphrase: passphrase,
                                                storeId: s.storeId,
                                                ctx: ctx)
        } else {
            key = SyncKeychain.randomStoreKey()
            guard SyncKeychain.saveStoreKey(key, storeId: s.storeId) else {
                throw SyncError.cryptoFailed("无法把 storeKey 写入钥匙串")
            }
        }

        // store.json：新空间才创建
        if !remoteInitialized {
            let descriptor = SyncIdentity.descriptor(for: s, displayTitle: displayTitle)
            try await uploadFile(try SyncCodec.encode(descriptor),
                                 name: SyncCodec.storeFileName,
                                 ctx: ctx)
        }

        // 本机钥匙信封（可覆盖）
        let envelope = try SyncCrypto.makeEnvelope(storeKey: key,
                                                   passphrase: passphrase,
                                                   storeId: s.storeId,
                                                   writerId: s.writerId)
        try await uploadFile(try SyncCodec.encode(envelope),
                             name: SyncKeyEnvelope.fileName(writerId: s.writerId),
                             ctx: ctx)

        // 新机初始化 / 恢复后对账：先拉 Snapshot，再拉未应用包
        if adoptedRemoteStore || s.recoveryRequired {
            if remoteInitialized {
                try await downloadAndApplyRemote(state: &s, key: key, ctx: ctx)
            }
            s.recoveryRequired = false
        }

        // 首台种子：只在「全新云端空间 + 本机从未建立基线」时发 Snapshot
        if !remoteInitialized, s.records.isEmpty {
            let rows = try AppCore.shared.syncSnapshotRows()
            if rows.totalRowCount > 0 {
                let snapshot = try SyncJournal.makeSnapshot(snapshot: rows, state: &s)
                try await uploadSnapshot(snapshot, storeKey: key, ctx: ctx, writerId: s.writerId)
            }
        }

        s.lastUploadAt = Date().timeIntervalSince1970
        try store.saveState(s)

        state = s
        storeKey = key
        syncRoot = s.syncRoot
        storeIdShort = String(s.storeId.suffix(8))
        lastUploadAt = Date()
        retryAttempt = 0
        phase = .idle
        refreshPendingCount()
    }

    /// 全量备份恢复后调用（方案 §10.4）：新 writer、清空基线、标记待对账，对账完成前禁止上传。
    /// 用户需重新输入同步口令启用（复用 Keychain 中同 storeId 的 storeKey，不会覆盖云端）。
    func handleFullRestore() {
        guard var s = state else { return }
        debounceTask?.cancel()
        startupTask?.cancel()
        launchCheckTask?.cancel()
        retryTask?.cancel()
        try? store.clearOutbox()

        s.writerId = SyncCodec.newWriterId()
        s.writerSeq = 0
        s.records.removeAll()
        s.appliedChangeIds.removeAll()
        s.latestSnapshotId = nil
        s.recoveryRequired = true
        try? store.saveState(s)

        state = s
        storeKey = nil
        phase = .failed("已从备份恢复，请重新输入同步口令完成云端对账")
        pendingChangeCount = 0
        pendingRemoteSummary = nil
        updatePendingBadge(false)
    }

    /// 停用同步：只停止本机上传，不删除云端、不删 Keychain，重新启用可原样接回。
    func disable() {
        debounceTask?.cancel()
        startupTask?.cancel()
        launchCheckTask?.cancel()
        retryTask?.cancel()
        debounceTask = nil
        startupTask = nil
        launchCheckTask = nil
        retryTask = nil
        state = nil
        storeKey = nil
        phase = .disabled
        pendingChangeCount = 0
        pendingRemoteSummary = nil
        updatePendingBadge(false)
    }

    // MARK: - 触发

    /// 任意一次本地 save 成功后调用；连续录入会合并成一批。
    /// 3 分钟 trailing 防抖：减少碎片包，避免一次连续操作产生多个变更包。
    func notifyLocalSaveSucceeded() {
        guard isEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.uploadNow()
        }
    }

    /// 立即尝试上传（Debug 设置页有入口；Release 仅内部调用）。
    func uploadNow() async {
        guard let saved = state, let key = storeKey, !isBusy, !saved.recoveryRequired else { return }
        guard let credentials = firstCredentials() else {
            phase = .failed("未配置 WebDAV 服务器")
            return
        }

        isBusy = true
        phase = .uploading
        defer { isBusy = false }

        let ctx = CloudContext(url: credentials.url,
                               username: credentials.username,
                               password: credentials.password,
                               remoteDir: saved.syncRoot)
        // 本次尝试写到 outbox 的包 id：失败时清理，避免下次重试又生成新包造成残留
        var attemptOutboxId: String?
        do {
            let rows = try AppCore.shared.syncSnapshotRows()
            var s = saved
            let plan = try SyncJournal.plan(snapshot: rows, state: &s)

            guard let changeSet = plan.changeSet else {
                // 无变化：只落盘时钟推进（若有），不产包
                try store.saveState(s)
                state = s
                phase = .idle
                refreshPendingCount()
                return
            }

            let encName = SyncCodec.changeFileName(writerId: changeSet.writerId,
                                                   writerSeq: changeSet.writerSeq,
                                                   changeId: changeSet.changeId)
            // 包先落盘，再上传（崩溃后可用同一 changeId 重试）
            _ = try store.writeOutbox(changeSet)
            attemptOutboxId = changeSet.changeId

            let plain = try SyncCodec.encode(changeSet)
            let cipher = try SyncCrypto.encrypt(plain, storeKey: key)

            try await uploadFile(cipher, name: encName, ctx: ctx)
            try await verifyRemoteSize(name: encName, expected: cipher.count, ctx: ctx)

            let meta = SyncChangeSetMeta(formatVersion: changeSet.formatVersion,
                                          storeId: changeSet.storeId,
                                          changeId: changeSet.changeId,
                                          writerId: changeSet.writerId,
                                          writerName: s.writerName,
                                          writerSeq: changeSet.writerSeq,
                                          createdAt: changeSet.createdAt,
                                          upsertCount: changeSet.upsertCount,
                                          deleteCount: changeSet.deletes.count,
                                          sha256: SyncCodec.sha256Hex(cipher),
                                          size: cipher.count,
                                          keyId: SyncKeychain.keyId(key),
                                          fileName: encName)
            try await uploadFile(try SyncCodec.encode(meta),
                                 name: SyncCodec.metaFileName(encFileName: encName),
                                 ctx: ctx)

            s.confirmUpload(changeId: changeSet.changeId)
            s.appliedChangeIds.append(changeSet.changeId)
            s.lastUploadAt = Date().timeIntervalSince1970
            try store.saveState(s)
            try? store.removeOutbox(changeId: changeSet.changeId)

            state = s
            lastUploadAt = Date()
            retryAttempt = 0
            phase = .idle
            refreshPendingCount()
        } catch {
            // 失败的包不保留：状态未推进，下次会重新差分生成新包；
            // 保留会在 outbox 里堆积孤儿文件，并在设置页误显示“待上传”。
            if let id = attemptOutboxId {
                try? store.removeOutbox(changeId: id)
            }
            phase = .failed(error.localizedDescription)
            scheduleRetry()
        }
    }

    // MARK: - 检查云端

    /// 列出云端尚未应用的 ChangeSet（只读，不下载正文）。
    func checkCloud() async throws -> SyncCloudSummary {
        guard let s = state else { throw SyncError.cryptoFailed("同步尚未启用") }
        guard let ctx = cloudContext(for: s) else {
            throw SyncError.cryptoFailed("未配置 WebDAV 服务器")
        }
        return try await listPendingChangeSets(for: s, ctx: ctx)
    }

    private func listPendingChangeSets(for s: SyncState,
                                       ctx: CloudContext,
                                       files listedFiles: [CloudBackupItem]? = nil) async throws -> SyncCloudSummary {
        let files: [CloudBackupItem]
        if let listedFiles {
            files = listedFiles
        } else {
            files = try await WebDAVBackup.shared.listBackups(url: ctx.url,
                                                             username: ctx.username,
                                                             password: ctx.password,
                                                             remoteDir: ctx.remoteDir)
        }
        let applied = s.appliedChangeIdSet
        let knownNames = Set(files.map { $0.name })
        var summary = SyncCloudSummary()
        summary.knownFileNames = knownNames
        var metaNames = Set<String>()

        for file in files where file.name.hasSuffix(".meta.json") {
            metaNames.insert(file.name)
        }

        // 文件名里带 changeId：已应用的包直接跳过下载（日常无更新时只需一次 PROPFIND）
        let pendingMetaFiles = files.filter { file in
            guard file.name.hasPrefix("change-"), file.name.hasSuffix(".meta.json") else { return false }
            if let changeId = Self.changeId(fromMetaFileName: file.name), applied.contains(changeId) {
                return false
            }
            return true
        }
        let fetched = await fetchPendingMetas(pendingMetaFiles,
                                              knownNames: knownNames,
                                              ctx: ctx,
                                              storeId: s.storeId,
                                              applied: applied)
        for name in fetched.failures {
            SyncConflictLogger.packageFailure(changeId: name, detail: "读取 meta 失败，已跳过")
        }
        summary.items = fetched.metas.map { SyncCloudItem(meta: $0) }
        summary.totalBytes = fetched.metas.reduce(0) { $0 + $1.size }
        summary.items.sort { $0.meta.createdAt < $1.meta.createdAt }

        // 有 enc 没有 meta：未完成上传，消费端忽略，仅在状态里报告
        for file in files where file.name.hasPrefix("change-") && file.name.hasSuffix(".enc") {
            let expectedMeta = SyncCodec.metaFileName(encFileName: file.name)
            if !metaNames.contains(expectedMeta) {
                summary.orphanEncNames.append(file.name)
            }
        }
        return summary
    }

    /// 从 change-{writer}-{seq}-{changeId}.meta.json 中解析 changeId。
    private static func changeId(fromMetaFileName name: String) -> String? {
        guard name.hasPrefix("change-"), name.hasSuffix(".meta.json") else { return nil }
        let base = name.dropFirst("change-".count).dropLast(".meta.json".count)
        return base.split(separator: "-").last.map(String.init)
    }

    /// 并发下载未应用的 meta（3 并发，已实测 NAS 接受）；单包失败只记录，不中断整次检查。
    private func fetchPendingMetas(_ files: [CloudBackupItem],
                                   knownNames: Set<String>,
                                   ctx: CloudContext,
                                   storeId: String,
                                   applied: Set<String>) async -> (metas: [SyncChangeSetMeta], failures: [String]) {
        var metas: [SyncChangeSetMeta] = []
        var failures: [String] = []
        let limit = 3

        await withTaskGroup(of: (String, Data?).self) { group in
            var iterator = files.makeIterator()

            func enqueueNext() {
                guard let file = iterator.next() else { return }
                let name = file.name
                group.addTask { [weak self] in
                    guard let self else { return (name, nil) }
                    let data = try? await self.downloadFile(name: name, ctx: ctx, knownNames: knownNames)
                    return (name, data)
                }
            }

            for _ in 0..<limit { enqueueNext() }

            while let (name, data) = await group.next() {
                if let data {
                    if let meta = try? SyncCodec.decode(SyncChangeSetMeta.self, from: data),
                       meta.storeId == storeId,
                       !applied.contains(meta.changeId) {
                        metas.append(meta)
                    }
                } else {
                    failures.append(name)
                }
                enqueueNext()
            }
        }
        return (metas, failures)
    }

    // MARK: - 合并云端

    /// 合并云端待应用包：系统密码授权 → bcom 全量备份 → 逐包校验/解密/应用 → 统一 repair。
    /// - Parameter prefetched: 刚检查得到的待合并结果；传入时不再重复下载 meta。
    func mergeCloud(password: String, displayTitle: String,
                    prefetched: SyncCloudSummary? = nil) async throws -> SyncMergeReport {
        guard SessionManager.shared.canMergeCloud else {
            throw SyncError.cryptoFailed("当前账号无权合并云端数据")
        }
        guard let saved = state, let key = storeKey else {
            throw SyncError.cryptoFailed("同步尚未启用")
        }
        guard SecurityManager.shared.verifyPassword(password) else {
            throw SyncError.cryptoFailed("系统密码不正确")
        }
        guard let ctx = cloudContext(for: saved) else {
            throw SyncError.cryptoFailed("未配置 WebDAV 服务器")
        }

        // 复用刚检查过的结果，避免合并前再完整下载一遍 meta；为空或未传则现场检查
        let summary: SyncCloudSummary
        if let prefetched, !prefetched.isEmpty {
            summary = prefetched
        } else {
            summary = try await checkCloud()
        }
        var report = SyncMergeReport()
        guard !summary.isEmpty else { return report }

        // 合并前强制全量备份（失败即中止，不改任何业务数据）
        let bcomURL = try makeBcomBackup(password: password, displayTitle: displayTitle)
        report.bcomFileName = bcomURL.lastPathComponent

        // 先逐包下载/校验/解密（单包失败只跳过），再整批一次应用：
        // 避免每个包都 save + 全量 reload 12 张表（50 包曾耗时约 4 分钟）。
        var s = saved
        let decoded = await decodePackages(summary.items, state: &s, key: key, ctx: ctx,
                                           knownNames: summary.knownFileNames)
        report.failedPackages.append(contentsOf: decoded.failures)
        if !decoded.sets.isEmpty {
            let applied = try await AppCore.shared.syncApplyBatch(decoded.sets, state: &s)
            report.appliedPackages = decoded.sets.count
            report.inserted += applied.inserted
            report.updated += applied.updated
            report.deleted += applied.deleted
            report.skipped += applied.skipped
            report.conflicts += applied.conflicts
            for set in decoded.sets { s.appliedChangeIds.append(set.changeId) }
            try store.saveState(s)
        }

        // 全部包结束后统一修复与重算（一次，不逐包做）
        try await AppCore.shared.repairAfterRemoteMerge()

        s.lastMergeAt = Date().timeIntervalSince1970
        try store.saveState(s)
        state = s
        retryAttempt = 0
        phase = .idle
        pendingRemoteSummary = nil
        updatePendingBadge(false)
        refreshPendingCount()
        return report
    }

    // MARK: - 单包解码 / 批量应用 / 新机初始化

    /// 下载 → size/SHA256 → 解密 → 身份与版本校验，返回可批量应用的 ChangeSet。
    private func decodePackage(_ item: SyncCloudItem,
                               expectedStoreId: String,
                               key: SymmetricKey,
                               ctx: CloudContext,
                               knownNames: Set<String>?) async throws -> SyncChangeSet {
        guard let cipher = try await downloadFile(name: item.meta.fileName, ctx: ctx, knownNames: knownNames) else {
            throw SyncError.cryptoFailed("云端缺少 \(item.meta.fileName)")
        }
        guard cipher.count == item.meta.size else {
            throw SyncError.cryptoFailed("包大小不一致（\(cipher.count) ≠ \(item.meta.size)）")
        }
        guard SyncCodec.sha256Hex(cipher) == item.meta.sha256 else {
            throw SyncError.cryptoFailed("包 SHA256 校验失败")
        }
        let plain = try SyncCrypto.decrypt(cipher, storeKey: key)
        let changeSet = try SyncCodec.decode(SyncChangeSet.self, from: plain)
        guard changeSet.storeId == expectedStoreId,
              changeSet.changeId == item.meta.changeId else {
            throw SyncError.cryptoFailed("包身份与 meta 不一致")
        }
        guard changeSet.formatVersion <= SyncChangeSet.currentFormatVersion,
              changeSet.rulesVersion <= SyncChangeSet.currentRulesVersion else {
            throw SyncError.cryptoFailed("云端格式/规则版本高于本机，请升级 App")
        }
        return changeSet
    }

    /// 逐包下载/校验/解密；单包失败只记录，不影响其他包。
    private func decodePackages(_ items: [SyncCloudItem],
                                state: inout SyncState,
                                key: SymmetricKey,
                                ctx: CloudContext,
                                knownNames: Set<String>?) async -> (sets: [SyncChangeSet], failures: [String]) {
        var sets: [SyncChangeSet] = []
        var failures: [String] = []
        for item in items {
            guard !state.appliedChangeIdSet.contains(item.meta.changeId) else { continue }
            do {
                let set = try await decodePackage(item, expectedStoreId: state.storeId,
                                                  key: key, ctx: ctx, knownNames: knownNames)
                sets.append(set)
            } catch {
                failures.append("\(item.meta.changeId)：\(error.localizedDescription)")
                SyncConflictLogger.packageFailure(changeId: item.meta.changeId,
                                                  detail: error.localizedDescription)
            }
        }
        return (sets, failures)
    }

    /// 新机接入 / 恢复对账：应用最新 Snapshot，再补齐其后的 ChangeSet，最后统一 repair。
    private func downloadAndApplyRemote(state: inout SyncState,
                                        key: SymmetricKey,
                                        ctx: CloudContext) async throws {
        let files = try await WebDAVBackup.shared.listBackups(url: ctx.url,
                                                              username: ctx.username,
                                                              password: ctx.password,
                                                              remoteDir: ctx.remoteDir)
        let knownNames = Set(files.map { $0.name })

        // 1) 最新快照
        var snapshotMetas: [SyncSnapshotMeta] = []
        for file in files where file.name.hasPrefix("snapshot-") && file.name.hasSuffix(".meta.json") {
            guard let data = try await downloadFile(name: file.name, ctx: ctx, knownNames: knownNames),
                  let meta = try? SyncCodec.decode(SyncSnapshotMeta.self, from: data),
                  meta.storeId == state.storeId else { continue }
            snapshotMetas.append(meta)
        }
        if let latest = snapshotMetas.max(by: { $0.createdAt < $1.createdAt }) {
            guard let cipher = try await downloadFile(name: latest.fileName, ctx: ctx, knownNames: knownNames) else {
                throw SyncError.cryptoFailed("云端缺少快照 \(latest.fileName)")
            }
            guard cipher.count == latest.size,
                  SyncCodec.sha256Hex(cipher) == latest.sha256 else {
                throw SyncError.cryptoFailed("快照校验失败（大小或 SHA256 不一致）")
            }
            let plain = try SyncCrypto.decrypt(cipher, storeKey: key)
            let snapshot = try SyncCodec.decode(SyncSnapshot.self, from: plain)
            guard snapshot.storeId == state.storeId else {
                throw SyncError.cryptoFailed("快照属于另一套数据")
            }
            _ = try await AppCore.shared.syncApply(snapshot.asChangeSet(), state: &state)
            state.latestSnapshotId = snapshot.snapshotId
            state.appliedChangeIds.append(contentsOf: snapshot.includedChangeIds)
            try store.saveState(state)
        }

        // 2) 快照之后的包：逐包解密校验，整批一次应用
        let pending = try await listPendingChangeSets(for: state, ctx: ctx, files: files)
        let decoded = await decodePackages(pending.items, state: &state, key: key, ctx: ctx,
                                           knownNames: pending.knownFileNames)
        if !decoded.sets.isEmpty {
            _ = try await AppCore.shared.syncApplyBatch(decoded.sets, state: &state)
            for set in decoded.sets { state.appliedChangeIds.append(set.changeId) }
            try store.saveState(state)
        }

        // 3) 一次收尾修复
        try await AppCore.shared.repairAfterRemoteMerge()
    }

    // MARK: - bcom 合并前备份

    private func makeBcomBackup(password: String, displayTitle: String) throws -> URL {
        guard let dir = BackupManager.shared.resolveBackupDir(subpath: "bcom") else {
            throw SyncError.cryptoFailed("无法定位备份目录")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try BackupManager.shared.exportFromSharedContainer(includeUsers: true)
        let key = SecurityManager.shared.autoBackupEncryptionKey(for: password)
        let cipher = try BackupManager.shared.encryptBackup(data, key: key)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let title = SyncIdentity.sanitizedTitle(displayTitle)
        let url = dir.appendingPathComponent("\(title)-合并前-\(formatter.string(from: Date())).json")
        try cipher.write(to: url, options: .atomic)

        trimBcomBackups(in: dir, keep: 15)
        return url
    }

    /// bcom 只保留最近 15 份，不占用 Auto 的 10 份配额。
    private func trimBcomBackups(in dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let files = names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> (URL, Date)? in
                let url = dir.appendingPathComponent(name)
                let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                return date.map { (url, $0) }
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in files.dropFirst(keep) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - 重试

    private func scheduleRetry() {
        retryTask?.cancel()
        retryAttempt = min(retryAttempt + 1, 3)
        let delays: [UInt64] = [60, 300, 900]
        let delay = delays[min(retryAttempt - 1, delays.count - 1)]
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.uploadNow()
        }
    }

    // MARK: - 云端辅助

    private struct CloudContext {
        var url: String
        var username: String
        var password: String
        var remoteDir: String
    }

    private func firstCredentials() -> CloudContext? {
        guard let server = SecurityManager.shared.webDAVServers.first,
              let credentials = SecurityManager.webDAVCredentials(for: server) else { return nil }
        return CloudContext(url: credentials.url,
                            username: credentials.username,
                            password: credentials.password,
                            remoteDir: credentials.remoteDir)
    }

    private func cloudContext(for state: SyncState) -> CloudContext? {
        guard let base = firstCredentials() else { return nil }
        return CloudContext(url: base.url,
                            username: base.username,
                            password: base.password,
                            remoteDir: state.syncRoot)
    }

    private func uploadFile(_ data: Data, name: String, ctx: CloudContext) async throws {
        _ = try await WebDAVBackup.shared.upload(data: data,
                                                 fileName: name,
                                                 url: ctx.url,
                                                 username: ctx.username,
                                                 password: ctx.password,
                                                 remoteDir: ctx.remoteDir,
                                                 ensureDirectory: false)
    }

    private func verifyRemoteSize(name: String, expected: Int, ctx: CloudContext) async throws {
        let items = try await WebDAVBackup.shared.listBackups(url: ctx.url,
                                                              username: ctx.username,
                                                              password: ctx.password,
                                                              remoteDir: ctx.remoteDir)
        guard let item = items.first(where: { $0.name == name }) else {
            throw SyncError.cryptoFailed("上传后云端未找到 \(name)")
        }
        guard item.size == expected else {
            throw SyncError.cryptoFailed("云端文件大小不一致（\(item.size) ≠ \(expected)）")
        }
    }

    private func downloadFile(name: String, ctx: CloudContext, knownNames: Set<String>? = nil) async throws -> Data? {
        // knownNames 来自调用方已有的目录列表，避免每个文件都重复 PROPFIND
        if let knownNames {
            guard knownNames.contains(name) else { return nil }
        } else {
            let items = try await WebDAVBackup.shared.listBackups(url: ctx.url,
                                                                  username: ctx.username,
                                                                  password: ctx.password,
                                                                  remoteDir: ctx.remoteDir)
            guard items.contains(where: { $0.name == name }) else { return nil }
        }
        try store.ensureDirectories()
        let target = store.incomingDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
        try await WebDAVBackup.shared.downloadToFile(name: name,
                                                     url: ctx.url,
                                                     username: ctx.username,
                                                     password: ctx.password,
                                                     remoteDir: ctx.remoteDir,
                                                     to: target)
        // 内容是调用方要的 Data，读入后即删临时文件，避免 incoming/ 无限堆积
        defer { try? FileManager.default.removeItem(at: target) }
        return try Data(contentsOf: target)
    }

    /// 本机 Keychain 没有 storeKey、但云端已有数据：用同步口令解封任一云端信封接入。
    /// 绝不允许新生成密钥覆盖信封——那会让云端历史包永久无法解密。
    private func adoptRemoteStoreKey(passphrase: String,
                                     storeId: String,
                                     ctx: CloudContext) async throws -> SymmetricKey {
        let items = try await WebDAVBackup.shared.listBackups(url: ctx.url,
                                                              username: ctx.username,
                                                              password: ctx.password,
                                                              remoteDir: ctx.remoteDir)
        let envelopes = items.filter {
            $0.name.hasPrefix("key-") && $0.name.hasSuffix(".json")
        }
        guard !envelopes.isEmpty else {
            throw SyncError.cryptoFailed("云端已有同步数据，但找不到钥匙信封；请先在另一台已接入的设备上启用同步")
        }
        for item in envelopes {
            guard let data = try await downloadFile(name: item.name, ctx: ctx),
                  let envelope = try? SyncCodec.decode(SyncKeyEnvelope.self, from: data),
                  envelope.storeId == storeId else { continue }
            if let key = try? SyncCrypto.unwrap(envelope.wrappedStoreKey,
                                                passphrase: passphrase,
                                                storeId: storeId) {
                guard SyncKeychain.saveStoreKey(key, storeId: storeId) else {
                    throw SyncError.cryptoFailed("已解封 storeKey，但无法写入钥匙串")
                }
                return key
            }
        }
        throw SyncError.cryptoFailed("同步口令不正确，无法解封云端钥匙信封")
    }

    private func uploadSnapshot(_ snapshot: SyncSnapshot,
                                storeKey: SymmetricKey,
                                ctx: CloudContext,
                                writerId: String) async throws {
        let plain = try SyncCodec.encode(snapshot)
        let cipher = try SyncCrypto.encrypt(plain, storeKey: storeKey)
        let encName = SyncSnapshot.fileName(snapshotId: snapshot.snapshotId)
        try await uploadFile(cipher, name: encName, ctx: ctx)
        try await verifyRemoteSize(name: encName, expected: cipher.count, ctx: ctx)

        let meta = SyncSnapshotMeta(formatVersion: snapshot.formatVersion,
                                    storeId: snapshot.storeId,
                                    snapshotId: snapshot.snapshotId,
                                    writerId: writerId,
                                    createdAt: snapshot.createdAt,
                                    rowCount: snapshot.rows.totalRowCount,
                                    sha256: SyncCodec.sha256Hex(cipher),
                                    size: cipher.count,
                                    keyId: SyncKeychain.keyId(storeKey),
                                    fileName: encName)
        try await uploadFile(try SyncCodec.encode(meta),
                             name: SyncSnapshot.metaFileName(snapshotId: snapshot.snapshotId),
                             ctx: ctx)
    }

    /// 待上传计数 = 本机状态里仍标记 pending 的包；同时清掉没有状态引用的孤儿 outbox。
    private func refreshPendingCount() {
        let tables: [String: [String: SyncRecordState]] = state?.records ?? [:]
        let referenced = Set(tables.values.flatMap { $0.values }.compactMap { $0.pendingChangeId })
        let ids = (try? store.listOutboxChangeIds()) ?? []
        for id in ids where !referenced.contains(id) {
            try? store.removeOutbox(changeId: id)
        }
        pendingChangeCount = ids.filter { referenced.contains($0) }.count
    }
}
