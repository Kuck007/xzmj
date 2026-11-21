//
//  SyncSelfTest.swift
//  杏子美甲管理系统
//
//  DEBUG 专用：阶段 1 同步内核自检。
//  只做纯逻辑与只读校验，不写业务数据、不联网、不碰正式同步状态。
//  结果同时输出到控制台和 ~/Library/Application Support/xzmj/sync/Debug/selftest.log。
//

#if DEBUG
import CryptoKit
import Foundation

@MainActor
enum SyncSelfTest {

    private final class Recorder {
        var lines: [String] = []
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                passed += 1
                lines.append("✅ \(name)")
            } else {
                failed += 1
                lines.append("❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            }
        }

        var text: String {
            lines.joined(separator: "\n")
        }
    }

    /// 在 AppCore 就绪后调用（每次 Debug 启动跑一次，毫秒级）。
    static func runIfNeeded() {
        run()
    }

    @discardableResult
    static func run() -> (passed: Int, failed: Int) {
        let r = Recorder()
        let startedAt = Date()
        r.lines.append("===== 增量同步阶段 1 自检 \(timestamp(startedAt)) =====")

        runPureLogicTests(r)

        // 真实数据只读校验：必须放在最后，依赖 AppCore 已就绪
        runRealSnapshotTests(r)

        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        r.lines.append("----- 通过 \(r.passed)，失败 \(r.failed)，耗时 \(ms)ms -----")

        let text = r.text
        print("[SyncSelfTest]\n\(text)")
        writeLog(text)
        return (r.passed, r.failed)
    }

    // MARK: - 纯逻辑测试

    private static func runPureLogicTests(_ r: Recorder) {
        // 1) HLC：单调、同毫秒递增、时钟回拨仍递增
        var clock = SyncHLCGenerator(writerId: "w1", lastWallMs: 0, lastLogical: 0)
        let t = Date(timeIntervalSince1970: 1_760_000_000)
        let v1 = clock.next(now: t)
        let v2 = clock.next(now: t)
        let v3 = clock.next(now: t.addingTimeInterval(-60))
        r.check("HLC 同毫秒严格递增", v1 < v2 && v2 < v3)
        r.check("HLC 时钟回拨不倒退", v3.wallMs == v1.wallMs)

        var clockA = SyncHLCGenerator(writerId: "aaa")
        let sa = clockA.next(now: t)
        var clockB = SyncHLCGenerator(writerId: "bbb")
        let sb = clockB.next(now: t)
        clockB.observe(sa, now: t)
        let sb2 = SyncBumpedVersion.make(clockB, now: t)
        r.check("HLC 收到远端后不低于远端", sb2 > sa && sb > sa)

        // 2) 新增 → 修改 → 删除 → 幂等
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("xzmj-sync-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let store = SyncStateStore(root: tmpRoot)

        var state = SyncState(storeId: "store-selftest",
                              syncRoot: "selftest/sync",
                              writerId: "wselftest",
                              writerName: "自检机")

        let itemA = makeItem(name: "甲油胶 A", quantity: 10)
        let itemB = makeItem(name: "甲油胶 B", quantity: 5)
        var snapshot = SyncRowsSnapshot()
        snapshot.inventoryItems = [itemA, itemB]

        do {
            try store.ensureDirectories()

            // 新增
            let plan1 = try SyncJournal.plan(snapshot: snapshot, state: &state)
            r.check("新增 2 行 → 产出 1 个包（2 upsert）",
                    plan1.changeSet != nil && plan1.stats.totalUpserts == 2 && plan1.stats.totalDeletes == 0,
                    "实际 \(plan1.stats.summary)")
            r.check("首次产包后 writerSeq = 1", state.writerSeq == 1, "实际 \(state.writerSeq)")

            // 幂等：同样的快照再跑一次
            let plan2 = try SyncJournal.plan(snapshot: snapshot, state: &state)
            r.check("无变化 → 不产包（幂等）", plan2.changeSet == nil && plan2.stats.isEmpty,
                    "实际 \(plan2.stats.summary)")

            // 修改
            var modified = itemA
            modified = BackupInventoryItem(id: itemA.id, name: "甲油胶 A（改）",
                                           brand: itemA.brand, colorCode: itemA.colorCode,
                                           category: itemA.category, quantity: 12,
                                           unit: itemA.unit,
                                           lowStockThreshold: itemA.lowStockThreshold,
                                           notes: itemA.notes, updatedAt: itemA.updatedAt)
            snapshot.inventoryItems = [modified, itemB]
            let plan3 = try SyncJournal.plan(snapshot: snapshot, state: &state)
            r.check("改 1 行 → 只传 1 条", plan3.changeSet?.upsertCount == 1 && plan3.stats.totalDeletes == 0,
                    "实际 \(plan3.stats.summary)")
            r.check("第二次产包 writerSeq = 2", state.writerSeq == 2, "实际 \(state.writerSeq)")

            // 删除
            snapshot.inventoryItems = [modified]
            let plan4 = try SyncJournal.plan(snapshot: snapshot, state: &state)
            let tomb = plan4.changeSet?.deletes.first
            r.check("删 1 行 → 生成墓碑",
                    plan4.changeSet?.upsertCount == 0 && plan4.changeSet?.deletes.count == 1,
                    "实际 \(plan4.stats.summary)")
            r.check("墓碑实体与 UUID 正确",
                    tomb?.entity == .inventoryItems && tomb?.uuid == itemB.id)

            // 3) 变更包编解码往返
            if let cs = plan1.changeSet {
                let data = try SyncCodec.encode(cs)
                let back = try SyncCodec.decode(SyncChangeSet.self, from: data)
                r.check("ChangeSet 编解码往返一致",
                        back.changeId == cs.changeId
                            && back.storeId == cs.storeId
                            && back.upsertCount == cs.upsertCount
                            && back.deletes.count == cs.deletes.count)
                r.check("缺失数组按空处理",
                        (try SyncCodec.decode(SyncChangeSet.self,
                                              from: minimalChangeSetJSON()).customers.isEmpty))

                // 4) outbox 落盘 / 列举 / 删除
                _ = try store.writeOutbox(cs)
                let ids = try store.listOutboxChangeIds()
                r.check("outbox 写入并列举", ids == [cs.changeId], "实际 \(ids)")
                let loaded = try store.loadOutbox(changeId: cs.changeId)
                r.check("outbox 回读一致", loaded.changeId == cs.changeId)
                try store.removeOutbox(changeId: cs.changeId)
                r.check("outbox 删除后为空", (try store.listOutboxChangeIds()).isEmpty)
            } else {
                r.check("ChangeSet 存在", false, "plan1 未产包")
            }

            // 5) 状态原子写 / 读回
            try store.saveState(state)
            let reloaded = try store.loadState()
            r.check("状态文件读写一致",
                    reloaded?.writerSeq == state.writerSeq
                        && reloaded?.records.count == state.records.count
                        && reloaded?.writerId == state.writerId)

            // 6) 行哈希稳定性
            let h1 = try SyncCodec.rowHash(itemA)
            let h2 = try SyncCodec.rowHash(itemA)
            let h3 = try SyncCodec.rowHash(modified)
            r.check("同一行哈希稳定", h1 == h2 && h1.count == 64)
            r.check("内容变化 → 哈希变化", h1 != h3)

            // 7) 补睫派生 ID
            let oid = UUID()
            let did1 = LashReminder.derivedID(orderId: oid)
            let did2 = LashReminder.derivedID(orderId: oid)
            let did3 = LashReminder.derivedID(orderId: UUID())
            r.check("补睫派生 ID 稳定且唯一", did1 == did2 && did1 != did3)

            // 8) storeKey 钥匙串往返
            let testStoreId = "selftest-\(UUID().uuidString)"
            let storeKey = SyncKeychain.randomStoreKey()
            let saved = SyncKeychain.saveStoreKey(storeKey, storeId: testStoreId)
            r.check("storeKey 写入钥匙串", saved)
            if let loadedKey = SyncKeychain.storeKey(storeId: testStoreId) {
                r.check("storeKey 读回一致", keyData(loadedKey) == keyData(storeKey))
            } else {
                r.check("storeKey 读回一致", false, "钥匙串读不到刚写入的 storeKey")
            }
            SyncKeychain.deleteStoreKey(storeId: testStoreId)
            r.check("storeKey 删除后为空", SyncKeychain.storeKey(storeId: testStoreId) == nil)

            // 9) 同步口令封装 / 解封
            let passphrase = "selftest-pass-123"
            let wrapped = try SyncCrypto.wrap(storeKey: storeKey, passphrase: passphrase, storeId: testStoreId)
            let unwrapped = try SyncCrypto.unwrap(wrapped, passphrase: passphrase, storeId: testStoreId)
            r.check("口令封装/解封一致", keyData(unwrapped) == keyData(storeKey))
            r.check("错误口令解封失败",
                    (try? SyncCrypto.unwrap(wrapped, passphrase: "wrong-pass-999", storeId: testStoreId)) == nil)
            r.check("口令过短被拒绝", (try? SyncCrypto.validatePassphrase("1234567")) == nil)
            r.check("keyId 稳定", SyncKeychain.keyId(storeKey) == SyncKeychain.keyId(unwrapped))
            r.check("口令标识区分不同口令",
                    SyncCrypto.wrapKeyId(passphrase: passphrase, storeId: testStoreId)
                        != SyncCrypto.wrapKeyId(passphrase: "another-pass", storeId: testStoreId))

            // 10) 钥匙信封编解码
            let envelope = try SyncCrypto.makeEnvelope(storeKey: storeKey,
                                                       passphrase: passphrase,
                                                       storeId: testStoreId,
                                                       writerId: "wselftest")
            let envelopeBack = try SyncCodec.decode(SyncKeyEnvelope.self,
                                                    from: SyncCodec.encode(envelope))
            r.check("钥匙信封编解码一致", envelopeBack == envelope)
            r.check("信封命名符合契约",
                    SyncKeyEnvelope.fileName(writerId: "wselftest") == "key-wselftest.json")

            // 11) ChangeSet 加密 / 解密
            if let cs = plan1.changeSet {
                let plain = try SyncCodec.encode(cs)
                let cipher = try SyncCrypto.encrypt(plain, storeKey: storeKey)
                let decrypted = try SyncCrypto.decrypt(cipher, storeKey: storeKey)
                r.check("ChangeSet 加解密一致",
                        decrypted == plain && cipher.prefix(4) == Data("ENCR".utf8))
                r.check("错误密钥解密失败",
                        (try? SyncCrypto.decrypt(cipher, storeKey: SyncKeychain.randomStoreKey())) == nil)
            }

            // 12) 身份创建与重载
            let identityStore = SyncStateStore(root: tmpRoot.appendingPathComponent("identity", isDirectory: true))
            let configuredDir = SyncIdentity.syncRoot(title: "自检店")
            let (state1, created1) = try SyncIdentity.loadOrCreateState(store: identityStore,
                                                                        displayTitle: "自检店",
                                                                        syncRoot: configuredDir)
            let (state2, created2) = try SyncIdentity.loadOrCreateState(store: identityStore,
                                                                        displayTitle: "自检店",
                                                                        syncRoot: configuredDir)
            r.check("首次创建同步身份",
                    created1 && state1.writerId.count == 10 && !state1.storeId.isEmpty)
            r.check("重载身份保持一致",
                    !created2 && state2.writerId == state1.writerId && state2.storeId == state1.storeId)
            r.check("同步目录 = {应用标题}/sync", state1.syncRoot == "自检店/sync")
            r.check("云端文件命名符合契约",
                    SyncCodec.storeFileName == "store.json"
                        && SyncCodec.changeFileName(writerId: "w", writerSeq: 1, changeId: "c")
                            == "change-w-000001-c.enc"
                        && SyncCodec.metaFileName(encFileName: "change-w-000001-c.enc")
                            == "change-w-000001-c.meta.json")
            r.check("meta 文件名可反推 enc（删旧包用）",
                    SyncCodec.encFileName(fromMetaFileName: "change-w-000001-c.meta.json")
                        == "change-w-000001-c.enc"
                        && SyncCodec.encFileName(fromMetaFileName: "snapshot-abc.meta.json")
                        == "snapshot-abc.enc")

            // 13) storeId 不一致必须拦截
            let wrongRemote = SyncStoreDescriptor(formatVersion: 3, rulesVersion: 1,
                                                  storeId: "another-store", displayTitle: "别人家",
                                                  createdAt: 0)
            r.check("storeId 不一致被拦截",
                    (try? SyncIdentity.verify(remote: wrongRemote, matches: state1)) == nil)

            // 14) 上传确认与快照基线
            var baselineState = SyncState(storeId: "store-selftest", syncRoot: "selftest/sync",
                                          writerId: "wselftest", writerName: "自检机")
            var baselineRows = SyncRowsSnapshot()
            baselineRows.inventoryItems = [itemA]
            let baselinePlan = try SyncJournal.plan(snapshot: baselineRows, state: &baselineState)
            if let baselineCS = baselinePlan.changeSet {
                baselineState.confirmUpload(changeId: baselineCS.changeId)
                let record = baselineState.record(entity: .inventoryItems, id: itemA.id)
                r.check("确认上传后 pending 清空、baseline 生效",
                        record?.pendingChangeId == nil && record?.syncedHash != nil)
                let noChange = try SyncJournal.plan(snapshot: baselineRows, state: &baselineState)
                r.check("确认上传后差分为空", noChange.changeSet == nil)
            } else {
                r.check("确认上传测试产包", false, "baseline 未产包")
            }

            var snapState = SyncState(storeId: "store-selftest", syncRoot: "selftest/sync",
                                      writerId: "wselftest", writerName: "自检机")
            var snapRows = SyncRowsSnapshot()
            snapRows.inventoryItems = [itemA, itemB]
            let madeSnapshot = try SyncJournal.makeSnapshot(snapshot: snapRows, state: &snapState)
            r.check("快照包含全部行与版本",
                    madeSnapshot.records[SyncEntity.inventoryItems.rawValue]?.count == 2)
            r.check("快照后基线已建立",
                    snapState.record(entity: .inventoryItems, id: itemA.id)?.syncedHash != nil)
            let snapDecoded = try SyncCodec.decode(SyncSnapshot.self,
                                                   from: SyncCodec.encode(madeSnapshot))
            r.check("快照编解码一致",
                    snapDecoded.rows.totalRowCount == 2
                        && snapDecoded.snapshotId == madeSnapshot.snapshotId)

            // 15) 云端保留窗口（整理云端）
            let nowT = Date(timeIntervalSince1970: 1_800_000_000)
            func pkg(_ index: Int, daysAgo: Double) -> SyncRetention.PackageRef {
                SyncRetention.PackageRef(changeId: "c\(index)",
                                         createdAt: nowT.addingTimeInterval(-daysAgo * 86400))
            }
            let fewRecent = (1...10).map { pkg($0, daysAgo: 1) }
            r.check("保留窗口：低活跃时全部保留",
                    SyncRetention.keepChangeIds(fewRecent, now: nowT).count == 10)

            let manyDays = (1...500).map { pkg($0, daysAgo: Double($0) * 0.02) }
            let keepMany = SyncRetention.keepChangeIds(manyDays, now: nowT)
            r.check("保留窗口：最多 400 包", keepMany.count == 400)
            r.check("保留窗口：优先保留最新的包",
                    keepMany.contains("c1") && !keepMany.contains("c500"))

            let hundredDays = (1...100).map { pkg($0, daysAgo: Double($0)) }
            let prunable = SyncRetention.prunableChangeIds(hundredDays,
                                                           applied: Set(hundredDays.map(\.changeId)),
                                                           now: nowT)
            r.check("整理只删保留窗口外且已应用的包",
                    !prunable.contains("c1") && prunable.contains("c99") && prunable.count == 50)
            r.check("未应用的包绝不删除",
                    SyncRetention.prunableChangeIds(hundredDays, applied: ["c1"], now: nowT).isEmpty)

            // 16) 快照覆盖集合（只增不减）与漏包判定
            var coverState = SyncState(storeId: "store-selftest", syncRoot: "selftest/sync",
                                       writerId: "wselftest", writerName: "自检机")
            coverState.absorbCoverage(["a", "b"])
            coverState.absorbCoverage(["b", "c"])
            r.check("快照覆盖集合只增不减",
                    coverState.coveredChangeIdSet == ["a", "b", "c"])
            coverState.appliedChangeIds = ["d"]
            r.check("已知集合 = 已应用 + 已覆盖",
                    coverState.knownChangeIdSet == ["a", "b", "c", "d"])

            let oldMetaJSON = Data("""
            {"formatVersion":3,"storeId":"s","snapshotId":"x","writerId":"w","createdAt":1,\
            "rowCount":0,"sha256":"h","size":0,"keyId":"k","fileName":"f"}
            """.utf8)
            r.check("旧快照 meta 无覆盖字段可解码",
                    (try? SyncCodec.decode(SyncSnapshotMeta.self, from: oldMetaJSON))?
                        .includedChangeIds == nil)

            let newMeta = SyncSnapshotMeta(formatVersion: 3, storeId: "s", snapshotId: "y",
                                           writerId: "w", createdAt: 2, rowCount: 0,
                                           sha256: "h", size: 0, keyId: "k", fileName: "f",
                                           includedChangeIds: ["a", "c"])
            let decodedMeta = try SyncCodec.decode(SyncSnapshotMeta.self,
                                                   from: SyncCodec.encode(newMeta))
            r.check("新快照 meta 覆盖集合编解码一致",
                    decodedMeta.includedChangeIds == ["a", "c"])

        } catch {
            r.check("纯逻辑测试无异常", false, error.localizedDescription)
        }
    }

    // MARK: - 真实数据只读校验

    private static func runRealSnapshotTests(_ r: Recorder) {
        let core = AppCore.shared
        guard core.isReady else {
            r.check("真实快照校验", false, "AppCore 未就绪")
            return
        }
        do {
            let rows = try core.syncSnapshotRows()
            r.check("快照行数与内核一致",
                    rows.totalRowCount == core.customers.count + core.technicians.count
                        + core.categories.count + core.serviceItems.count
                        + core.records.count + core.appointments.count
                        + core.orders.count + core.inventoryItems.count
                        + core.commissionRules.count + core.lashReminders.count
                        + core.recharges.count + core.reconciliations.count,
                    "快照 \(rows.totalRowCount) 行")

            // 全库差分：验证 773 行全部可哈希、且不会误判删除
            var freshState = SyncState(storeId: "store-selftest",
                                       syncRoot: "selftest/sync",
                                       writerId: "wselftest",
                                       writerName: "自检机")
            let t0 = Date()
            let plan = try SyncJournal.plan(snapshot: rows, state: &freshState)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            r.check("全库差分产包（\(rows.totalRowCount) 行 / \(ms)ms）",
                    plan.changeSet?.upsertCount == rows.totalRowCount,
                    "实际 upsert \(plan.changeSet?.upsertCount ?? -1)")
            r.check("全库差分无删除误判", plan.stats.totalDeletes == 0,
                    "实际 delete \(plan.stats.totalDeletes)")

            // 第二次差分必须为空（幂等）
            let plan2 = try SyncJournal.plan(snapshot: rows, state: &freshState)
            r.check("全库第二次差分无变化", plan2.changeSet == nil)
        } catch {
            r.check("真实快照校验无异常", false, error.localizedDescription)
        }
    }

    // MARK: - 辅助

    private static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private static func makeItem(name: String, quantity: Double) -> BackupInventoryItem {
        BackupInventoryItem(id: UUID(),
                            name: name,
                            brand: "自检品牌",
                            colorCode: "#000000",
                            category: "消耗品",
                            quantity: quantity,
                            unit: "瓶",
                            lowStockThreshold: 1,
                            notes: nil,
                            updatedAt: Date(timeIntervalSince1970: 1_760_000_000))
    }

    private static func minimalChangeSetJSON() -> Data {
        Data("""
        {"formatVersion":3,"rulesVersion":1,"storeId":"s","changeId":"c","writerId":"w"}
        """.utf8)
    }

    private static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private static func writeLog(_ text: String) {
        let root = SyncStateStore.defaultRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? text.write(to: root.appendingPathComponent("selftest.log"),
                        atomically: true,
                        encoding: .utf8)
    }
}

/// 仅用于自检的可变时钟包装（避免在 `let` 上调用 mutating 方法）。
private enum SyncBumpedVersion {
    static func make(_ clock: SyncHLCGenerator, now: Date) -> SyncVersion {
        var c = clock
        return c.next(now: now)
    }
}
#endif
