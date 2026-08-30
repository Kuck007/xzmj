//
//  杏子美甲管理系统App.swift
//  杏子美甲管理系统
//

import SwiftUI
import SwiftData
import AppKit

/// 仅保留用户要求的功能：禁用标题栏/工具栏区域的右键菜单。
/// （其余窗口样式全部还原为 macOS 系统默认：圆角窗口、胶囊按钮、原生弹窗。）
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var eventMonitor: Any?
    private var windowDelegates: [WindowMenuBlockingDelegate] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            User.self
        ])

        // 轻量迁移配置：允许新增带默认值的字段自动迁移，不删 store
        let config = ModelConfiguration(isStoredInMemoryOnly: false, allowsSave: true)
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

    /// 迁移/初始化失败时：把 default.store（及 wal/shm）备份到 Application Support 下的抢救目录，
    /// 文件名带时间戳。返回是否备份成功。
    private static func archivePersistentStoreBeforeReset() -> Bool {
        let fm = FileManager.default
        guard let supportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }

        let storeFiles = [
            supportURL.appendingPathComponent("default.store"),
            supportURL.appendingPathComponent("default.store-wal"),
            supportURL.appendingPathComponent("default.store-shm")
        ]

        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        // 备份到 Application Support 下的抢救目录（容器内一定可写，避免沙盒 Desktop 权限问题）
        let destDir = supportURL.appendingPathComponent("SwiftData抢救-\(stamp)", isDirectory: true)

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
        guard let url = fm.urls(for: .applicationSupportDirectory,
                                in: .userDomainMask).first else { return }
        let storeURL = url.appendingPathComponent("default.store")
        if fm.fileExists(atPath: storeURL.path) {
            try? fm.removeItem(at: storeURL)
        }
        for ext in ["wal", "shm"] {
            let aux = url.appendingPathComponent("default.store.\(ext)")
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
