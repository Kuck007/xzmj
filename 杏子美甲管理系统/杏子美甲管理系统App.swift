//
//  杏子美甲管理系统App.swift
//  杏子美甲管理系统
//

import SwiftUI
import SwiftData
import AppKit
import Sparkle

/// 仅保留用户要求的功能：禁用标题栏/工具栏区域的右键菜单。
/// （其余窗口样式全部还原为 macOS 系统默认：圆角窗口、胶囊按钮、原生弹窗。）
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var eventMonitor: Any?
    private var windowDelegates: [WindowMenuBlockingDelegate] = []
    /// Sparkle 自动更新控制器（在 applicationDidFinishLaunching 中初始化）
    var updaterController: SPUStandardUpdaterController!
    /// 静态引用，方便外部访问
    static var shared: AppDelegate!
    /// 本次启动是否已检查过更新（app 完全退出前只检查一次）
    static var hasCheckedUpdateThisLaunch = false

    /// 外部调用入口：检查更新
    static func checkForUpdates() {
        shared?.updaterController?.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    /// 更新源选择（gitee / github），默认 github
    static var updateSource: String {
        get { UserDefaults.standard.string(forKey: "update.source") ?? "github" }
        set { UserDefaults.standard.set(newValue, forKey: "update.source") }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        if Self.updateSource == "gitee" {
            return "https://gitee.com/kuck007/xzmj/raw/main/appcast-gitee.xml"
        }
        return "https://raw.githubusercontent.com/Kuck007/xzmj/main/appcast.xml"
    }

    /// 确保应用可以正常退出（Sparkle 更新后需要退出并重启）
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }

    /// Sparkle 即将重启应用时调用
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // 确保所有窗口关闭，应用可以正常退出
        NSApp.windows.forEach { $0.close() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // 初始化 Sparkle 自动更新
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

        // 1. 现有窗口立即处理
        DispatchQueue.main.async {
            for window in NSApp.windows {
                Self.disableTitlebarContextMenu(in: window)
            }
        }

        // 2. 监听窗口变为 Main，处理后续新建的窗口
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            Self.disableTitlebarContextMenu(in: window)
        }

        // 3. 全局右键拦截：在标题栏/工具栏区域（contentView 上方）按下右键时直接吞掉事件，
        //    让系统没有机会合成并弹出 NSToolbar 的菜单。
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp]) { event in
            guard let window = event.window else { return event }
            // 若点击区域不在 contentView 内（即标题栏/工具栏/交通灯区），则吃掉事件
            if let contentView = window.contentView {
                let locationInWindow = event.locationInWindow
                let locationInContent = contentView.convert(locationInWindow, from: nil)
                if !contentView.bounds.contains(locationInContent) {
                    return nil // 吞掉事件，不弹出任何菜单
                }
            }
            return event
        }
    }

    private static func disableTitlebarContextMenu(in window: NSWindow) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        // 禁用 Toolbar 用户自定义
        window.toolbar?.allowsUserCustomization = false
        if #available(macOS 15, *) {
            // showsBaselineSeparator deprecated on macOS 15, no longer needed
        } else {
            window.toolbar?.showsBaselineSeparator = true
        }

        // 递归清空所有 NSView.menu，防止 SwiftUI / AppKit 视图级的菜单
        func clearMenuRecursively(in view: NSView?) {
            guard let view = view else { return }
            view.menu = nil
            for subview in view.subviews {
                clearMenuRecursively(in: subview)
            }
        }
        if let contentView = window.contentView {
            var topView: NSView = contentView
            while let parent = topView.superview { topView = parent }
            clearMenuRecursively(in: topView)
        }

        // 包装 window delegate（保持原有 delegate 功能，强引用保活）
        if !(window.delegate is WindowMenuBlockingDelegate) {
            let wrapper = WindowMenuBlockingDelegate(original: window.delegate)
            window.delegate = wrapper
            appDelegate.windowDelegates.append(wrapper)
        }
    }
}

/// 窗口 delegate 包装器，保持原有 delegate 转发的同时不丢失功能
final class WindowMenuBlockingDelegate: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    init(original: NSWindowDelegate?) {
        self.original = original
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) { return self }
        return original
    }
}

@main
struct 杏子美甲管理系统App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// 外观主题偏好（浅色/深色/跟随系统），写入 UserDefaults 由设置页切换
    @AppStorage(AppTheme.storageKey) private var themeRawValue = AppTheme.dark.rawValue
    let modelContainer: ModelContainer

    init() {
        let schema = Schema([
            Customer.self,
            Technician.self,
            ServiceCategory.self,
            ServiceItem.self,
            NailServiceRecord.self,
            Appointment.self,
            Order.self,
            InventoryItem.self,
            CommissionRule.self,
            LashReminder.self,
            RechargeRecord.self,
            DailyReconciliation.self,
            User.self
        ])

        // 迁移到 xzmj 子目录（如果需要）
        Self.migrateToXzmjDirectoryIfNeeded()

        // 轻量迁移配置：允许新增带默认值的字段自动迁移，不删 store
        // 数据库放在 ~/Library/Application Support/xzmj/ 下
        // Debug 版本使用独立数据库文件，与 Release 完全隔离
        let fm = FileManager.default
        let xzmjDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("xzmj", isDirectory: true)
        if !fm.fileExists(atPath: xzmjDir.path) {
            try? fm.createDirectory(at: xzmjDir, withIntermediateDirectories: true)
        }
        #if DEBUG
        let storeURL = xzmjDir.appendingPathComponent("debug.default.store")
        #else
        let storeURL = xzmjDir.appendingPathComponent("default.store")
        #endif
        let config = ModelConfiguration(url: storeURL, allowsSave: true)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // 轻量迁移失败：绝不直接删库！
            // 先把旧 store 备份到 Application Support 下的抢救目录（容器内一定可写），
            // 确认备份成功后才删除旧库、新建空库。
            print("""
            [ERROR] SwiftData 轻量迁移失败，为保护数据不做自动删除：
            \(error.localizedDescription)
            """)
            let archived = Self.archivePersistentStoreBeforeReset()
            if archived {
                // 备份成功 → 删除旧库、新建空库
                Self.deletePersistentStore()
                do {
                    container = try ModelContainer(for: schema, configurations: [config])
                } catch {
                    // 再次失败：用内存兜底
                    let memConfig = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
                    container = try! ModelContainer(for: schema, configurations: [memConfig])
                }
            } else {
                // 备份也失败 → 用内存模式启动，绝不删库
                print("[FATAL] 备份也失败，用内存模式启动以防数据被删。请手动备份数据后重启。")
                let memConfig = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
                container = try! ModelContainer(for: schema, configurations: [memConfig])
            }
        }
        modelContainer = container

        // 将容器注入备份管理器，供后台线程创建独立 ModelContext 时使用（线程安全）
        BackupManager.shared.modelContainer = modelContainer

        // 将容器注入会话管理器，供登录时查询用户
        SessionManager.shared.configure(container: modelContainer)

        // 启动时修复数据库中不规范的数据（如"付宝"→"支付宝"）
        fixPaymentMethodData()

        // 启动后后台检查自动兜底备份（每 15 天一次，不阻塞首屏、不影响主动备份提醒）
        DispatchQueue.global(qos: .utility).async {
            BackupManager.shared.autoBackupIfNeeded()
        }
    }

    /// xzmj 数据目录：~/Library/Application Support/xzmj/
    private static var xzmjDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("xzmj", isDirectory: true)
    }

    /// 当前使用的 store 文件名（Debug 用 debug.default.store，Release 用 default.store）
    private static var currentStoreName: String {
        #if DEBUG
        return "debug.default.store"
        #else
        return "default.store"
        #endif
    }

    /// 当前数据库完整路径
    private static var currentStoreURL: URL {
        xzmjDirectory.appendingPathComponent(currentStoreName)
    }

    /// 从旧路径（Application Support 根目录）迁移到 xzmj 子目录
    /// 旧路径：~/Library/Application Support/default.store
    /// 新路径：~/Library/Application Support/xzmj/default.store
    private static func migrateToXzmjDirectoryIfNeeded() {
        let fm = FileManager.default
        let supportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let xzmjDir = xzmjDirectory
        let storeName = currentStoreName

        // 新路径已存在数据库 → 不需要迁移
        let newStoreURL = xzmjDir.appendingPathComponent(storeName)
        if fm.fileExists(atPath: newStoreURL.path) {
            return
        }

        // 旧路径不存在数据库 → 不需要迁移
        let oldStoreURL = supportURL.appendingPathComponent(storeName)
        guard fm.fileExists(atPath: oldStoreURL.path) else {
            return
        }

        print("[Migration] 检测到旧路径数据库，开始迁移到 xzmj 子目录...")

        // 创建 xzmj 目录
        do {
            try fm.createDirectory(at: xzmjDir, withIntermediateDirectories: true)
        } catch {
            print("[Migration] 创建 xzmj 目录失败: \(error)")
            return
        }

        // 迁移数据库三件套
        let storeFiles = [storeName, "\(storeName)-wal", "\(storeName)-shm"]
        var allCopied = true
        for fileName in storeFiles {
            let src = supportURL.appendingPathComponent(fileName)
            let dst = xzmjDir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: src.path) {
                do {
                    try fm.copyItem(at: src, to: dst)
                    print("[Migration] 已复制: \(fileName)")
                } catch {
                    print("[Migration] 复制 \(fileName) 失败: \(error)")
                    allCopied = false
                }
            }
        }

        // 迁移 Backups 文件夹
        let oldBackupsDir = supportURL.appendingPathComponent("Backups", isDirectory: true)
        let newBackupsDir = xzmjDir.appendingPathComponent("Backups", isDirectory: true)
        if fm.fileExists(atPath: oldBackupsDir.path) && !fm.fileExists(atPath: newBackupsDir.path) {
            do {
                try fm.copyItem(at: oldBackupsDir, to: newBackupsDir)
                print("[Migration] 已复制 Backups 文件夹")
            } catch {
                print("[Migration] 复制 Backups 文件夹失败: \(error)")
            }
        }

        // 验证迁移成功
        if allCopied && fm.fileExists(atPath: newStoreURL.path) {
            // 迁移成功，重命名旧文件为 .migrated（保留7天，不立即删除）
            for fileName in storeFiles {
                let oldURL = supportURL.appendingPathComponent(fileName)
                let backupURL = supportURL.appendingPathComponent("\(fileName).migrated")
                if fm.fileExists(atPath: oldURL.path) {
                    try? fm.moveItem(at: oldURL, to: backupURL)
                }
            }
            // 重命名旧 Backups 文件夹
            if fm.fileExists(atPath: oldBackupsDir.path) {
                let oldBackupsMigrated = supportURL.appendingPathComponent("Backups.migrated", isDirectory: true)
                try? fm.moveItem(at: oldBackupsDir, to: oldBackupsMigrated)
            }
            print("[Migration] 迁移完成，旧文件已重命名为 .migrated")
        } else {
            print("[Migration] 迁移失败，保留旧路径，使用旧路径启动")
            // 迁移失败，删除可能复制了一半的新文件
            for fileName in storeFiles {
                let dst = xzmjDir.appendingPathComponent(fileName)
                if fm.fileExists(atPath: dst.path) {
                    try? fm.removeItem(at: dst)
                }
            }
        }
    }

    /// 迁移/初始化失败时：把 default.store（及 wal/shm）备份到 Application Support 下的抢救目录，
    /// 文件名带时间戳。返回是否备份成功。
    private static func archivePersistentStoreBeforeReset() -> Bool {
        let fm = FileManager.default
        guard let supportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }

        let storeURL = currentStoreURL
        let storeFiles = [
            storeURL,
            storeURL.appendingPathExtension("wal"),
            storeURL.appendingPathExtension("shm")
        ]

        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        // 备份到 xzmj 目录下的抢救目录
        let destDir = xzmjDirectory.appendingPathComponent("SwiftData抢救-\(stamp)", isDirectory: true)

        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            for src in storeFiles {
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = destDir.appendingPathComponent(src.lastPathComponent)
                try fm.copyItem(at: src, to: dst)
            }
            print("[SAVED] 旧 SwiftData store 已抢救复制到: \(destDir.path)")
            return true
        } catch {
            print("[WARN] 抢救备份失败：\(error)")
            return false
        }
    }

    private static func deletePersistentStore() {
        let fm = FileManager.default
        let storeURL = currentStoreURL
        if fm.fileExists(atPath: storeURL.path) {
            try? fm.removeItem(at: storeURL)
        }
        for ext in ["wal", "shm"] {
            let aux = storeURL.appendingPathExtension(ext)
            if fm.fileExists(atPath: aux.path) {
                try? fm.removeItem(at: aux)
            }
        }
    }

    /// 修复数据库中不规范的数据：统一 paymentMethod 中的"付宝"为"支付宝"
    private func fixPaymentMethodData() {
        let context = ModelContext(modelContainer)
        // 修复 Order
        let orderPredicate = #Predicate<Order> { $0.paymentMethod == "付宝" }
        let fetchDesc = FetchDescriptor<Order>(predicate: orderPredicate)
        if let orders = try? context.fetch(fetchDesc), !orders.isEmpty {
            for o in orders { o.paymentMethod = "支付宝" }
            try? context.save()
            print("[修复] 已将 \(orders.count) 条订单的支付方式从「付宝」改为「支付宝」")
        }
        // 修复 RechargeRecord
        let rechargePredicate = #Predicate<RechargeRecord> { $0.paymentMethod == "付宝" }
        let rechargeFetch = FetchDescriptor<RechargeRecord>(predicate: rechargePredicate)
        if let recharges = try? context.fetch(rechargeFetch), !recharges.isEmpty {
            for r in recharges { r.paymentMethod = "支付宝" }
            try? context.save()
            print("[修复] 已将 \(recharges.count) 条充值记录的支付方式从「付宝」改为「支付宝」")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // 全局注入 SessionManager，供所有视图通过 @Environment 读取
                .environment(SessionManager.shared)
                // 全局注入品牌强调色：侧边栏选中态、按钮、开关、分段选择器、
                // 表单、弹窗、日历、图表等原生控件统一使用品牌主色
                .tint(.brandDeep)
                // 根据用户偏好应用外观：浅色（白底荧光粉） / 深色（黑底霓虹青） / 跟随系统
                .preferredColorScheme(AppTheme(rawValue: themeRawValue)?.colorSchemeOverride)
        }
        .modelContainer(modelContainer)
    }
}
