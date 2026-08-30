//
//  SettingsView.swift
//  杏子美甲管理系统
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit // for NSWorkspace

let presetQuestions = [
    "您的生日是几月几号？",
    "您的宠物名字是什么？",
    "您母亲的姓名是什么？",
    "您的小学名称是什么？",
    "您的家乡在哪里？",
    "您最喜欢的颜色是什么？",
    "您的身份证后四位是什么？",
    "您配偶的姓名是什么？"
]

/// 当前版本号：从 Info.plist 读取（对应工程中的 MARKETING_VERSION），
/// 发布新版本时自动跟随，无需手动维护。
private let currentAppVersion: String = {
    let bundle = Bundle.main
    guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
        return "1.0"
    }
    // 附加构建号（CURRENT_PROJECT_VERSION），如 "1.1 (1)"
    if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
        return "\(version) (\(build))"
    }
    return version
}()


struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var session = SessionManager.shared
    @Query private var customers: [Customer]
    @Query private var technicians: [Technician]
    @Query private var categories: [ServiceCategory]
    @Query private var serviceItems: [ServiceItem]
    @Query private var records: [NailServiceRecord]
    @Query private var appointments: [Appointment]
    @Query private var orders: [Order]
    @Query private var inventoryItems: [InventoryItem]
    @Query private var users: [User]

    @State private var viewMode: SettingsMode = SecurityManager.shared.hasPassword ? .menu : .setInitial
    /// 侧边栏自定义中当前的可排序项（按权限过滤后的当前顺序）
    @State private var sidebarEditableItems: [SidebarItem] = []
    /// 自动备份周期（天），1-99，默认 15
    @State private var autoBackupDays: Int = SecurityManager.shared.autoBackupDays
    /// 自动备份周期是否处于编辑模式
    @State private var autoBackupDaysEditing: Bool = false
    /// 自动备份周期编辑时的临时文本（支持两位数输入）
    @State private var autoBackupDaysInput: String = ""
    /// 外观主题偏好（与 App 根共享同一 UserDefaults 键）
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.dark.rawValue

    enum SettingsMode {
        case menu              // 主菜单（已有密码时）
        case setInitial        // 首次设置密码
        case changePassword    // 修改系统密码（敏感操作验证）
        case recoverPassword   // 找回系统密码
        case exportVerify      // 导出：密码验证
        case importVerify      // 导入：密码验证
        case sidebarSettings   // 侧边栏自定义
        case accountChangePassword  // 修改登录密码
        case accountRecoverPassword // 找回登录密码
        case accountChangeSecurityCode // 修改安全码
    }

    // 导出/导入提示
    @State private var toast: String?
    @State private var importSummary: BackupPackage?

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("设置").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
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
                .contentShape(Rectangle())
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            Group {
                switch viewMode {
                case .menu:
                    settingsMenu
                case .setInitial:
                    setInitialPasswordView
                case .changePassword:
                    changePasswordView
                case .recoverPassword:
                    recoverPasswordView
                case .exportVerify:
                    exportVerifyView
                case .importVerify:
                    importVerifyView
                case .sidebarSettings:
                    sidebarSettingsView
                case .accountChangePassword:
                    accountChangePasswordView
                case .accountRecoverPassword:
                    accountRecoverPasswordView
                case .accountChangeSecurityCode:
                    accountChangeSecurityCodeView
                }
            }

            if let toast = toast {
                Divider()
                Text(toast)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.vertical, 8).padding(.horizontal, 16)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            self.toast = nil
                        }
                    }
            }
        }
        .frame(minWidth: 520, minHeight: 480, idealHeight: 600, maxHeight: 750)
        // 注意：target 当前 entitlement 仅开启「User Selected File Read」，
        // NSSavePanel（包括 SwiftUI .fileExporter）都需要 Read/Write，否则触发 EXC_BREAKPOINT 断言卡死。
        // 导出流程：写入 app 自己的 Application Support/Backups/ 目录（沙箱内可写，不需要 entitlement），
        // 然后用 Finder 打开定位到文件，用户可直接拖走。
        .fileImporter(
            isPresented: $showImportFilePicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // 主线程先把文件读进内存（JSON 通常只有几百 KB 到几 MB，主线程完全扛得住）
                // 避开 security-scoped 资源跨线程失效问题
                let didStartAccess = url.startAccessingSecurityScopedResource()
                let data: Data? = try? Data(contentsOf: url)
                if didStartAccess { url.stopAccessingSecurityScopedResource() }
                guard let data = data else {
                    importError = "无法读取文件：\(url.lastPathComponent)"
                    importFileURL = nil; importFileData = nil; importSummary = nil
                    isEncryptedImport = false
                    return
                }
                // 判断是否为加密备份（自动备份在设置密码时会加密）
                let isEncrypted = BackupManager.shared.isEncryptedBackup(data)
                if isEncrypted {
                    // 加密文件暂不解码概要，等用户输入密码后再解密查看
                    DispatchQueue.main.async {
                        importFileURL = url
                        importFileData = data
                        importSummary = nil
                        importError = nil
                        isEncryptedImport = true
                    }
                    return
                }
                isEncryptedImport = false
                // 后台：解码摘要（纯数据，不触碰文件系统）
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let summary = try BackupManager.shared.decodeSummary(from: data)
                        DispatchQueue.main.async {
                            importFileURL = url
                            importFileData = data
                            importSummary = summary
                            importError = nil
                        }
                    } catch {
                        DispatchQueue.main.async {
                            importError = "无法解析文件：\(error.localizedDescription)"
                            importFileURL = nil; importFileData = nil; importSummary = nil
                        }
                    }
                }
            case .failure:
                break
            }
        }
    }

    private var subtitle: String {
        switch viewMode {
        case .menu: return "账户安全与数据备份"
        case .setInitial: return "首次设置密码"
        case .changePassword: return "修改系统密码"
        case .recoverPassword: return "找回系统密码"
        case .exportVerify: return "导出数据（需验证密码）"
        case .importVerify: return "导入数据（需验证密码）"
        case .sidebarSettings: return "侧边栏自定义"
        case .accountChangePassword: return "修改登录密码"
        case .accountRecoverPassword: return "找回登录密码"
        case .accountChangeSecurityCode: return "修改安全码"
        }
    }

    // MARK: - 主菜单
    private var settingsMenu: some View {
        let isStaff = session.currentUser?.role == .staff
        return VStack(spacing: 0) {
            Form {
                Section("当前账户") {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.brand.opacity(0.15))
                                .frame(width: 40, height: 40)
                            Image(systemName: "person.fill")
                                .foregroundStyle(Color.brand)
                                .font(.system(size: 16, weight: .bold))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.currentUser?.displayName ?? "未登录")
                                .font(.body.weight(.semibold))
                            HStack(spacing: 6) {
                                Text(session.roleLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(session.currentUser?.username ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }

                Section("账号设置") {
                    Button {
                        viewMode = .accountChangePassword
                    } label: {
                        HStack {
                            Image(systemName: "lock.rotation")
                            Text("修改登录密码")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())

                    Button {
                        viewMode = .accountChangeSecurityCode
                    } label: {
                        HStack {
                            Image(systemName: "key.horizontal")
                            Text("修改安全码")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())

                    Button {
                        viewMode = .accountRecoverPassword
                    } label: {
                        HStack {
                            Image(systemName: "questionmark.circle")
                            Text("找回登录密码")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }

                if !isStaff {
                    Section("系统安全") {
                        Button {
                            viewMode = .changePassword
                        } label: {
                            HStack {
                                Image(systemName: "lock.rotation")
                                Text("修改系统密码")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        Button {
                            viewMode = .recoverPassword
                        } label: {
                            HStack {
                                Image(systemName: "questionmark.circle")
                                Text("找回密码")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }

                    Section("数据备份") {
                        // 上次主动备份时间 + 状态指示（HIG：用语义化颜色和 Capsule 状态标签）
                        HStack {
                            Text("上次备份")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let last = SecurityManager.shared.lastBackupDate {
                                Text(backupDateFormatter.string(from: last))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("从未备份")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            // 状态胶囊
                            if SecurityManager.shared.needsBackupReminder {
                                Text("待备份")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.red.opacity(0.12)))
                            } else {
                                Text("已备份")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.green.opacity(0.12)))
                            }
                        }

                        // 自动备份状态（根据用户配置的周期显示）
                        HStack {
                            Text("自动备份")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let lastAuto = SecurityManager.shared.lastAutoBackupDate {
                                Text(backupDateFormatter.string(from: lastAuto))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("启动后自动执行")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("每\(SecurityManager.shared.autoBackupDays)天")
                                .font(.caption2)
                                .foregroundStyle(Color.brand)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.brand.opacity(0.12)))
                        }

                        // 自动备份周期设置（1-99天）—— 输入框 + 修改/确定
                        HStack(spacing: 12) {
                            Text("备份周期")
                                .foregroundStyle(.secondary)
                            Spacer()

                            // 值显示区：ZStack 叠两个层，用 opacity 切换避免 disabled 导致的移位
                            ZStack {
                                // 锁定层：纯文本显示
                                Text("\(autoBackupDays)")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, height: 26)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.8)
                                    )
                                    .opacity(autoBackupDaysEditing ? 0 : 1)

                                // 编辑层：CenteredTextField（macOS 原生，文字居中）
                                CenteredTextField(
                                    text: $autoBackupDaysInput,
                                    font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                                    textColor: .labelColor,
                                    isEditable: autoBackupDaysEditing
                                )
                                .frame(width: 48, height: 26)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.brand.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.brand.opacity(0.9), lineWidth: 1.2)
                                )
                                .opacity(autoBackupDaysEditing ? 1 : 0)
                                .allowsHitTesting(autoBackupDaysEditing)
                                .onChange(of: autoBackupDaysInput) { _, newValue in
                                    // 只允许数字，最多 2 位
                                    let filtered = newValue.filter { $0.isNumber }
                                    if filtered.count > 2 {
                                        autoBackupDaysInput = String(filtered.prefix(2))
                                    } else {
                                        autoBackupDaysInput = filtered
                                    }
                                }
                            }
                            .fixedSize()

                            Text("天")
                                .foregroundStyle(.secondary)

                            // 修改/取消按钮
                            Button {
                                if autoBackupDaysEditing {
                                    // 取消编辑
                                    autoBackupDaysEditing = false
                                    autoBackupDaysInput = ""
                                } else {
                                    // 开始编辑
                                    autoBackupDaysInput = "\(autoBackupDays)"
                                    autoBackupDaysEditing = true
                                }
                            } label: {
                                Text(autoBackupDaysEditing ? "取消" : "修改")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(autoBackupDaysEditing ? .secondary : Color.brand)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(autoBackupDaysEditing
                                                  ? Color.secondary.opacity(0.08)
                                                  : Color.brand.opacity(0.1))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(
                                                autoBackupDaysEditing
                                                    ? Color.secondary.opacity(0.25)
                                                    : Color.brand.opacity(0.5),
                                                lineWidth: 0.8
                                            )
                                    )
                            }
                            .buttonStyle(.plain)

                            // 确定按钮（仅编辑模式显示，输入值合法时才高亮）
                            if autoBackupDaysEditing {
                                let isValid = Int(autoBackupDaysInput) != nil
                                    && Int(autoBackupDaysInput)! >= 1
                                    && Int(autoBackupDaysInput)! <= 99
                                Button {
                                    guard let newValue = Int(autoBackupDaysInput),
                                          newValue >= 1 && newValue <= 99 else { return }
                                    autoBackupDays = newValue
                                    SecurityManager.shared.autoBackupDays = newValue
                                    autoBackupDaysEditing = false
                                    autoBackupDaysInput = ""
                                } label: {
                                    Text("确定")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(isValid ? .black : Color.secondary.opacity(0.5))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(isValid ? Color.brand : Color.secondary.opacity(0.15))
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(!isValid)
                            }
                        }

                        Button {
                            viewMode = .exportVerify
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("导出数据备份")
                                Spacer()
                                Text("\(totalCount) 条数据").font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        Button {
                            viewMode = .importVerify
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                Text("导入数据备份")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }

                Section("界面设置") {
                    Picker("主题", selection: $appThemeRawValue) {
                        ForEach(AppTheme.allCases) { theme in
                            Label(theme.label, systemImage: theme.icon)
                                .tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Button {
                        // 进入侧边栏设置时，用当前权限过滤后的实际顺序初始化
                        let isSuperAdmin = session.currentUser?.role == .superAdmin
                        sidebarEditableItems = SidebarPreferences.visibleItems()
                            .filter { $0 != .dashboard }
                            .filter { item in
                                if isSuperAdmin { return true }
                                return session.hasPermission(moduleId: item.moduleId)
                            }
                        viewMode = .sidebarSettings
                    } label: {
                        HStack {
                            Image(systemName: "sidebar.left")
                            Text("侧边栏自定义")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }

                Section("关于") {
                    LabeledContent("应用名称", value: "杏子美甲管理系统")
                    LabeledContent("版本号", value: currentAppVersion)
                    LabeledContent("密码状态", value: SecurityManager.shared.hasPassword ? "已设置" : "未设置")
                    LabeledContent("客户数量", value: "\(customers.count)")
                    LabeledContent("订单数量", value: "\(orders.count)")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
            }
            .padding(16)
        }
    }

    private var totalCount: Int {
        customers.count + technicians.count + categories.count + serviceItems.count
            + records.count + appointments.count + orders.count + inventoryItems.count
    }

    // MARK: - 首次设置密码
    @State private var initPassword = ""
    @State private var initConfirm = ""
    @State private var q1 = presetQuestions[0]
    @State private var q2 = presetQuestions[1]
    @State private var q3 = presetQuestions[2]
    @State private var a1 = ""
    @State private var a2 = ""
    @State private var a3 = ""
    @State private var initError: String?

    private var setInitialPasswordView: some View {
        VStack(spacing: 0) {
            Form {
                Section("设置密码") {
                    SecureField("密码", text: $initPassword)
                    SecureField("确认密码", text: $initConfirm)
                }
                Section("安全问题（用于找回密码）") {
                    Picker("问题一", selection: $q1) {
                        ForEach(presetQuestions, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("答案", text: $a1)
                    Picker("问题二", selection: $q2) {
                        ForEach(presetQuestions, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("答案", text: $a2)
                    Picker("问题三", selection: $q3) {
                        ForEach(presetQuestions, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("答案", text: $a3)
                }
                if let err = initError {
                    Section { Text(err).foregroundStyle(.red).font(.caption) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("保存") { saveInitial() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(initPassword.isEmpty || a1.isEmpty || a2.isEmpty || a3.isEmpty)
            }
            .padding(16)
        }
    }

    private func saveInitial() {
        guard initPassword == initConfirm else {
            initError = "两次输入的密码不一致"
            return
        }
        guard initPassword.count >= 4 else {
            initError = "密码至少4位"
            return
        }
        SecurityManager.shared.setPassword(initPassword)
        SecurityManager.shared.setSecurityQuestions([q1, q2, q3], answers: [a1, a2, a3])
        viewMode = .menu
    }

    // MARK: - 修改密码
    @State private var oldPwd = ""
    @State private var newPwd = ""
    @State private var confirmPwd = ""
    @State private var showOldPwd = false
    @State private var showNewPwd = false
    @State private var showConfirmPwd = false
    @State private var changeError: String?
    @State private var changeSuccess = false

    private var changePasswordView: some View {
        VStack(spacing: 0) {
            Form {
                Section("验证身份") {
                    PasswordInputRow(title: "原密码", text: $oldPwd, isRevealed: $showOldPwd)
                }
                Section("设置新密码") {
                    PasswordInputRow(title: "新密码", text: $newPwd, isRevealed: $showNewPwd)
                    PasswordInputRow(title: "确认新密码", text: $confirmPwd, isRevealed: $showConfirmPwd)
                }
                if let err = changeError {
                    Section { Text(err).foregroundStyle(.red).font(.caption) }
                }
                if changeSuccess {
                    Section { Text("密码修改成功").foregroundStyle(.green).font(.caption) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button {
                    viewMode = .menu
                } label: {
                    Text("返回")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("确认修改") { doChangePassword() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(oldPwd.isEmpty || newPwd.isEmpty || confirmPwd.isEmpty)
            }
            .padding(16)
        }
    }

    private func doChangePassword() {
        changeSuccess = false
        guard newPwd == confirmPwd else {
            changeError = "两次输入的新密码不一致"
            return
        }
        guard newPwd.count >= 4 else {
            changeError = "密码至少4位"
            return
        }
        guard SecurityManager.shared.changePassword(oldPassword: oldPwd, newPassword: newPwd) else {
            changeError = "原密码不正确"
            return
        }
        changeError = nil
        changeSuccess = true
        oldPwd = ""; newPwd = ""; confirmPwd = ""
    }

    // MARK: - 找回密码
    @State private var recoverAnswers: [String] = ["", "", ""]
    @State private var recoverNewPwd = ""
    @State private var recoverConfirm = ""
    @State private var recoverError: String?
    @State private var recoverVerified = false

    private var recoverPasswordView: some View {
        VStack(spacing: 0) {
            Form {
                Section("回答安全问题") {
                    ForEach(Array(SecurityManager.shared.securityQuestions.enumerated()), id: \.offset) { idx, q in
                        Text(q).font(.subheadline).foregroundStyle(.secondary)
                        if idx < recoverAnswers.count {
                            TextField("答案", text: Binding(
                                get: { recoverAnswers[idx] },
                                set: { recoverAnswers[idx] = $0 }
                            ))
                        }
                    }
                }
                if recoverVerified {
                    Section("设置新密码") {
                        SecureField("新密码", text: $recoverNewPwd)
                        SecureField("确认新密码", text: $recoverConfirm)
                    }
                }
                if let err = recoverError {
                    Section { Text(err).foregroundStyle(.red).font(.caption) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button {
                    viewMode = .menu
                } label: {
                    Text("返回")
                }
                .buttonStyle(.bordered)
                Spacer()
                if !recoverVerified {
                    Button("验证答案") { verifyRecoverAnswers() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button("重置密码") { doRecoverPassword() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(recoverNewPwd.isEmpty || recoverConfirm.isEmpty)
                }
            }
            .padding(16)
        }
    }

    private func verifyRecoverAnswers() {
        if SecurityManager.shared.verifySecurityAnswers(recoverAnswers) {
            recoverVerified = true
            recoverError = nil
        } else {
            recoverError = "安全问题答案不正确"
        }
    }

    private func doRecoverPassword() {
        guard recoverNewPwd == recoverConfirm else {
            recoverError = "两次输入的新密码不一致"
            return
        }
        guard recoverNewPwd.count >= 4 else {
            recoverError = "密码至少4位"
            return
        }
        if SecurityManager.shared.resetPassword(answers: recoverAnswers, newPassword: recoverNewPwd) {
            recoverError = nil
            viewMode = .menu
        } else {
            recoverError = "重置失败，请重试"
        }
    }

    // MARK: - 导出数据（密码验证）
    @State private var exportPwd = ""
    @State private var exportError: String?
    @State private var showingExportSuccess = false
    @State private var isExporting = false        // 打包中，显示进度条+禁用按钮

    // MARK: - 导入数据（密码验证）
    @State private var importPwd = ""
    @State private var importError: String?
    @State private var importFileURL: URL?
    @State private var importFileData: Data?
    @State private var isImporting = false       // 导入恢复中，显示进度条+禁用按钮
    @State private var showImportFilePicker = false
    @State private var isEncryptedImport = false // 当前选择的导入文件是否为加密备份

    private var exportVerifyView: some View {
        VStack(spacing: 0) {
            Form {
                Section("导出预览") {
                    LabeledContent("客户", value: "\(customers.count) 条")
                    LabeledContent("技师", value: "\(technicians.count) 条")
                    LabeledContent("服务分类", value: "\(categories.count) 条")
                    LabeledContent("服务项目", value: "\(serviceItems.count) 条")
                    LabeledContent("服务记录", value: "\(records.count) 条")
                    LabeledContent("预约", value: "\(appointments.count) 条")
                    LabeledContent("收银订单", value: "\(orders.count) 条")
                    LabeledContent("库存", value: "\(inventoryItems.count) 条")
                    LabeledContent("合计", value: "\(totalCount) 条数据")
                }
                Section("请输入密码以验证身份") {
                    SecureField("密码", text: $exportPwd)
                        .disabled(isExporting)
                }
                if isExporting {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在打包数据，请稍候…").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                if let err = exportError {
                    Section { Text(err).foregroundStyle(.red).font(.caption) }
                }
                if showingExportSuccess {
                    Section { Text("备份成功，文件已保存。").foregroundStyle(.green).font(.caption) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("返回") {
                    guard !isExporting else { return }
                    viewMode = .menu
                    exportPwd = ""; exportError = nil
                }
                .buttonStyle(.bordered)
                .disabled(isExporting)
                Spacer()
                Button("确认导出") { doExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(exportPwd.isEmpty || isExporting)
            }
            .padding(16)
        }
    }

    private func doExport() {
        guard !isExporting else { return }
        guard SecurityManager.shared.verifyPassword(exportPwd) else {
            exportError = "密码不正确"
            return
        }
        exportError = nil
        exportPwd = ""
        isExporting = true

        Task { @MainActor in
            do {
                let backupData = try BackupManager.shared.exportFromSharedContainer()

                // 写入沙箱容器的 Application Support/Backups/ 目录（不需要任何 entitlement）
                let fm = FileManager.default
                guard let appSupport = try? fm.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true
                ) else {
                    throw NSError(domain: "BackupExport", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "无法定位 Application Support 目录"])
                }
                let backupsDir = appSupport.appendingPathComponent("Backups", isDirectory: true)
                if !fm.fileExists(atPath: backupsDir.path) {
                    try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
                }
                let fileURL = backupsDir.appendingPathComponent(BackupManager.defaultFileName())
                try backupData.write(to: fileURL, options: .atomic)

                isExporting = false
                showingExportSuccess = true
                toast = "✅ 备份已生成，已在 Finder 中打开"
                // 记录备份时间，用于"超过 15 天未备份"提醒
                SecurityManager.shared.markBackupDone()
                // 用 Finder 打开并选中该文件 → 用户可直接拖拽出去
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                try? await Task.sleep(nanoseconds: 600_000_000)
                viewMode = .menu
                showingExportSuccess = false
            } catch {
                isExporting = false
                exportError = error.localizedDescription
            }
        }
    }

    private let backupDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 HH:mm"
        return df
    }()

    private var importVerifyView: some View {
        VStack(spacing: 0) {
            Form {
                Section("导入文件") {
                    HStack {
                        if let url = importFileURL {
                            Text(url.lastPathComponent).foregroundStyle(.primary)
                        } else {
                            Text("未选择文件").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("选择文件") {
                            showImportFilePicker = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(isImporting)
                    }

                    if isEncryptedImport {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(Color.brand)
                            Text("该备份已加密，输入密码后将自动解密并显示概要")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let pkg = importSummary {
                        Text("备份时间：\(backupDateFormatter.string(from: pkg.exportedAt))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("备份版本：v\(pkg.version)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("包含数据：\(pkg.customers.count) 客户 / \(pkg.technicians.count) 技师 / \(pkg.serviceItems.count) 项目 / \(pkg.records.count) 服务记录 / \(pkg.appointments.count) 预约 / \(pkg.orders.count) 订单 / \(pkg.inventoryItems.count) 库存")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("⚠️ 警告") {
                    Text("导入备份会清空当前所有数据并恢复为备份内容，此操作不可撤销。请确认已做好当前数据的备份。")
                        .font(.caption).foregroundStyle(.red)
                }
                Section("请输入密码以验证身份") {
                    SecureField("密码", text: $importPwd).disabled(isImporting)
                }
                if isImporting {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在恢复数据，请稍候…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                if let err = importError {
                    Section { Text(err).foregroundStyle(.red).font(.caption) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("返回") {
                    guard !isImporting else { return }
                    viewMode = .menu
                    importPwd = ""; importError = nil
                    importFileURL = nil; importFileData = nil; importSummary = nil
                    isEncryptedImport = false
                }
                .buttonStyle(.bordered)
                .disabled(isImporting)
                Spacer()
                Button("确认导入") { doImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(importPwd.isEmpty || importFileData == nil || isImporting)
            }
            .padding(16)
        }
    }

    private func doImport() {
        guard !isImporting else { return }
        guard let data = importFileData else {
            importError = "请先选择备份文件"
            return
        }
        let pwd = importPwd
        let encrypted = isEncryptedImport

        // 明文备份：验证当前密码（操作者身份验证）
        // 加密备份：不验证当前密码，直接用输入密码解密（可能是旧密码，解密成功即证明身份）
        if !encrypted {
            guard SecurityManager.shared.verifyPassword(pwd) else {
                importError = "密码不正确"
                return
            }
        } else if pwd.isEmpty {
            importError = "加密备份需要输入密码"
            return
        }

        importError = nil
        importPwd = ""
        isImporting = true
        let ctx = context

        // 后台：解密（如需要）→ 解码 JSON → BackupPackage（纯数据，可能含大图）
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 加密备份：用输入的密码派生密钥解密（支持旧密码解密旧备份）
                var packageData = data
                if encrypted {
                    let key = SecurityManager.shared.autoBackupEncryptionKey(for: pwd)
                    do {
                        packageData = try BackupManager.shared.decryptBackup(data, key: key)
                    } catch {
                        DispatchQueue.main.async {
                            isImporting = false
                            importError = "解密失败：密码不正确或文件已损坏"
                        }
                        return
                    }
                    // 解密成功后更新概要显示
                    if let summary = try? BackupManager.shared.decodeSummary(from: packageData) {
                        DispatchQueue.main.async {
                            importSummary = summary
                        }
                    }
                }

                let pkg = try BackupManager.shared.decodePackage(from: packageData)
                // 主线程：SwiftData 删除+插入+保存（ModelContext 必须主线程）
                DispatchQueue.main.async {
                    do {
                        try BackupManager.shared.apply(package: pkg, to: ctx)
                        isImporting = false
                        importFileURL = nil; importFileData = nil; importSummary = nil
                        isEncryptedImport = false
                        toast = "✅ 数据已恢复"
                        // 导入也视为一次完整数据备份动作，刷新提醒计时
                        SecurityManager.shared.markBackupDone()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            viewMode = .menu
                        }
                    } catch {
                        isImporting = false
                        importError = "写入数据库失败：\(error.localizedDescription)"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isImporting = false
                    importError = "解码备份文件失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 侧边栏自定义
    private var sidebarSettingsView: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("勾选要在侧边栏中显示的模块，使用右侧箭头调整顺序。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Image(systemName: SidebarItem.dashboard.icon)
                            .foregroundStyle(Color.brand)
                            .font(.system(size: 14))
                            .frame(width: 20)
                        Text(SidebarItem.dashboard.rawValue)
                        Spacer()
                        Text("始终显示")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("可自定义模块") {
                    ForEach(Array(sidebarEditableItems.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .foregroundStyle(Color.brand)
                                .font(.system(size: 14))
                                .frame(width: 20)
                            Text(item.rawValue)
                            Spacer()
                            Button {
                                moveSidebarItem(item, -1)
                            } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                            Button {
                                moveSidebarItem(item, 1)
                            } label: { Image(systemName: "arrow.down") }
                                .buttonStyle(.borderless)
                                .disabled(index == sidebarEditableItems.count - 1)
                            Toggle("", isOn: Binding(
                                get: { !SidebarPreferences.isHidden(item) },
                                set: { newVal in
                                    SidebarPreferences.setHidden(!newVal, for: item)
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("恢复默认") {
                    SidebarPreferences.resetOrder()
                    let isSuperAdmin = session.currentUser?.role == .superAdmin
                    sidebarEditableItems = SidebarPreferences.sortableItems.filter { item in
                        if isSuperAdmin { return true }
                        return session.hasPermission(moduleId: item.moduleId)
                    }
                }
                Spacer()
                Button("完成") { viewMode = .menu }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
    }

    private func moveSidebarItem(_ item: SidebarItem, _ delta: Int) {
        guard let i = sidebarEditableItems.firstIndex(of: item) else { return }
        let j = i + delta
        guard j >= 0 && j < sidebarEditableItems.count else { return }
        sidebarEditableItems.swapAt(i, j)
        // 同步到 UserDefaults
        SidebarPreferences.saveOrder(sidebarEditableItems)
    }

    // MARK: - 修改登录密码
    @State private var accOldPwd = ""
    @State private var accNewPwd = ""
    @State private var accConfirmPwd = ""
    @State private var accShowOldPwd = false
    @State private var accShowNewPwd = false
    @State private var accShowConfirmPwd = false
    @State private var accChangeError: String?
    @State private var accChangeSuccess = false

    private var currentUserRecord: User? {
        guard let username = session.currentUser?.username else { return nil }
        return users.first(where: { $0.username == username })
    }

    private var accountChangePasswordView: some View {
        VStack(spacing: 0) {
            Form {
                Section("验证身份") {
                    PasswordInputRow(title: "当前登录密码", text: $accOldPwd, isRevealed: $accShowOldPwd)
                }
                Section("设置新密码") {
                    PasswordInputRow(title: "新密码", text: $accNewPwd, isRevealed: $accShowNewPwd)
                    PasswordInputRow(title: "确认新密码", text: $accConfirmPwd, isRevealed: $accShowConfirmPwd)
                }
                if let err = accChangeError {
                    Section { Text(err).foregroundStyle(.red).font(.caption) }
                }
                if accChangeSuccess {
                    Section { Text("登录密码修改成功").foregroundStyle(.green).font(.caption) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button {
                    accOldPwd = ""; accNewPwd = ""; accConfirmPwd = ""
                    accChangeError = nil; accChangeSuccess = false
                    accShowOldPwd = false; accShowNewPwd = false; accShowConfirmPwd = false
                    viewMode = .menu
                } label: { Text("返回") }
                .buttonStyle(.bordered)
                Spacer()
                Button("确认修改") { doAccountChangePassword() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(accOldPwd.isEmpty || accNewPwd.isEmpty || accConfirmPwd.isEmpty)
            }
            .padding(16)
        }
    }

    private func doAccountChangePassword() {
        accChangeSuccess = false
        accChangeError = nil
        guard accNewPwd == accConfirmPwd else {
            accChangeError = "两次输入的新密码不一致"
            return
        }
        guard accNewPwd.count >= 6 else {
            accChangeError = "密码至少6位"
            return
        }
        guard let user = currentUserRecord else {
            accChangeError = "未找到当前用户记录"
            return
        }
        guard user.passwordHash == SessionManager.hash(accOldPwd) else {
            accChangeError = "原密码不正确"
            return
        }
        user.passwordHash = SessionManager.hash(accNewPwd)
        try? context.save()
        accChangeError = nil
        accChangeSuccess = true
        accOldPwd = ""; accNewPwd = ""; accConfirmPwd = ""
    }

    // MARK: - 找回登录密码（使用安全码）
    @State private var accRecoverSecurityCode = ""
    @State private var accRecoverNewPwd = ""
    @State private var accRecoverConfirm = ""
    @State private var accRecoverError: String?
    @State private var accRecoverVerified = false
    @State private var accRecoverShowSecurityCode = false
    @State private var accRecoverShowNewPwd = false
    @State private var accRecoverShowConfirmPwd = false

    private var accountRecoverPasswordView: some View {
        VStack(spacing: 0) {
            Form {
                Section("验证安全码") {
                    Text("请输入您注册时设置的安全码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                    PasswordInputRow(title: "安全码", text: $accRecoverSecurityCode, isRevealed: $accRecoverShowSecurityCode)
                }
                if accRecoverVerified {
                    Section("设置新登录密码") {
                        PasswordInputRow(title: "新密码", text: $accRecoverNewPwd, isRevealed: $accRecoverShowNewPwd)
                        PasswordInputRow(title: "确认新密码", text: $accRecoverConfirm, isRevealed: $accRecoverShowConfirmPwd)
                    }
                }
                if let err = accRecoverError {
                    Section { Text(err).foregroundStyle(.red).font(.caption) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button {
                    viewMode = .menu
                } label: { Text("返回") }
                .buttonStyle(.bordered)
                Spacer()
                if !accRecoverVerified {
                    Button("验证安全码") { verifyAccountSecurityCode() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("重置密码") { doAccountRecoverPassword() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(accRecoverNewPwd.isEmpty || accRecoverConfirm.isEmpty)
                }
            }
            .padding(16)
        }
    }

    private func verifyAccountSecurityCode() {
        guard let user = currentUserRecord else {
            accRecoverError = "未找到当前用户记录"
            return
        }
        if user.securityCodeHash == SessionManager.hash(accRecoverSecurityCode) {
            accRecoverVerified = true
            accRecoverError = nil
        } else {
            accRecoverError = "安全码不正确"
        }
    }

    private func doAccountRecoverPassword() {
        guard accRecoverNewPwd == accRecoverConfirm else {
            accRecoverError = "两次输入的新密码不一致"
            return
        }
        guard accRecoverNewPwd.count >= 6 else {
            accRecoverError = "密码至少6位"
            return
        }
        guard let user = currentUserRecord else {
            accRecoverError = "未找到当前用户记录"
            return
        }
        user.passwordHash = SessionManager.hash(accRecoverNewPwd)
        try? context.save()
        accRecoverError = nil
        accRecoverNewPwd = ""; accRecoverConfirm = ""
        accRecoverSecurityCode = ""
        accRecoverVerified = false
        viewMode = .menu
    }

    // MARK: - 修改安全码
    @State private var accOldSecurityCode = ""
    @State private var accNewSecurityCode = ""
    @State private var accConfirmSecurityCode = ""
    @State private var accShowOldSecurityCode = false
    @State private var accShowNewSecurityCode = false
    @State private var accShowConfirmSecurityCode = false
    @State private var accChangeSecurityCodeError: String?
    @State private var accChangeSecurityCodeSuccess = false

    private var accountChangeSecurityCodeView: some View {
        VStack(spacing: 0) {
            Form {
                Section("验证当前安全码") {
                    PasswordInputRow(title: "当前安全码", text: $accOldSecurityCode, isRevealed: $accShowOldSecurityCode)
                }
                Section("设置新安全码") {
                    PasswordInputRow(title: "新安全码", text: $accNewSecurityCode, isRevealed: $accShowNewSecurityCode)
                    PasswordInputRow(title: "确认新安全码", text: $accConfirmSecurityCode, isRevealed: $accShowConfirmSecurityCode)
                }
                if let err = accChangeSecurityCodeError {
                    Section { Text(err).foregroundStyle(.red).font(.caption) }
                }
                if accChangeSecurityCodeSuccess {
                    Section { Text("安全码修改成功").foregroundStyle(.green).font(.caption) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button {
                    accOldSecurityCode = ""; accNewSecurityCode = ""; accConfirmSecurityCode = ""
                    accChangeSecurityCodeError = nil; accChangeSecurityCodeSuccess = false
                    accShowOldSecurityCode = false; accShowNewSecurityCode = false; accShowConfirmSecurityCode = false
                    viewMode = .menu
                } label: { Text("返回") }
                .buttonStyle(.bordered)
                Spacer()
                Button("确认修改") { doAccountChangeSecurityCode() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(accOldSecurityCode.isEmpty || accNewSecurityCode.isEmpty || accConfirmSecurityCode.isEmpty)
            }
            .padding(16)
        }
    }

    private func doAccountChangeSecurityCode() {
        accChangeSecurityCodeSuccess = false
        accChangeSecurityCodeError = nil
        guard accNewSecurityCode == accConfirmSecurityCode else {
            accChangeSecurityCodeError = "两次输入的新安全码不一致"
            return
        }
        guard accNewSecurityCode.count >= 4 else {
            accChangeSecurityCodeError = "安全码至少4位"
            return
        }
        guard let user = currentUserRecord else {
            accChangeSecurityCodeError = "未找到当前用户记录"
            return
        }
        guard user.securityCodeHash == SessionManager.hash(accOldSecurityCode) else {
            accChangeSecurityCodeError = "原安全码不正确"
            return
        }
        user.securityCodeHash = SessionManager.hash(accNewSecurityCode)
        try? context.save()
        accChangeSecurityCodeError = nil
        accChangeSecurityCodeSuccess = true
        accOldSecurityCode = ""; accNewSecurityCode = ""; accConfirmSecurityCode = ""
    }
}


// MARK: - CenteredTextField（macOS 原生 NSTextField，文字居中对齐）
struct CenteredTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var textColor: NSColor = .labelColor
    var isEditable: Bool = true
    var onTextChange: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.placeholderString = placeholder
        tf.font = font
        tf.textColor = textColor
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.alignment = .center
        tf.isEditable = isEditable
        tf.isSelectable = true
        tf.delegate = context.coordinator
        tf.lineBreakMode = .byClipping
        tf.maximumNumberOfLines = 1
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.font = font
        nsView.textColor = textColor
        nsView.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTextChange: onTextChange)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onTextChange: ((String) -> Void)?

        init(text: Binding<String>, onTextChange: ((String) -> Void)?) {
            self._text = text
            self.onTextChange = onTextChange
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            let newValue = tf.stringValue
            text = newValue
            onTextChange?(newValue)
        }
    }
}
