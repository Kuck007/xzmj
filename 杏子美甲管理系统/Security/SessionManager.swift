import Foundation
import SwiftData
import CryptoKit

/// 登录用户的轻量级会话信息（不持有 SwiftData 对象，避免跨 context 问题）
struct SessionUser: Equatable {
    let username: String
    let displayName: String
    let role: UserRole
    let allowedModules: [String]
}

/// 全局会话管理器：持有当前登录用户，提供登录/登出/权限判断
@Observable
final class SessionManager {
    static let shared = SessionManager()

    /// 当前登录用户（nil 表示未登录）
    private(set) var currentUser: SessionUser?

    /// 应用的 ModelContainer，登录时用于查询用户
    private var modelContainer: ModelContainer?

    /// 自动登录有效期：7 天
    private static let autoLoginDuration: TimeInterval = 7 * 24 * 60 * 60
    /// UserDefaults keys：记住的用户名与记住时间（不存密码）
    private static let rememberedUsernameKey = "session.rememberedUsername"
    private static let rememberedAtKey = "session.rememberedAt"

    private init() {}

    /// App 启动时注入 ModelContainer
    func configure(container: ModelContainer) {
        self.modelContainer = modelContainer ?? container
    }

    // MARK: - 登录 / 登出

    /// 登录验证。成功则设置 currentUser 并更新最后登录时间，返回 true。
    @discardableResult
    func login(username: String, password: String, remember: Bool = false) throws -> Bool {
        guard let container = modelContainer else { return false }
        let context = ModelContext(container)
        let predicate = #Predicate<User> { $0.username == username }
        let users = try fetchUsers(context: context, predicate: predicate)
        guard let user = users.first else { return false }
        guard user.isActive else { return false }
        guard user.passwordHash == Self.hash(password) else { return false }

        // 更新最后登录时间
        user.lastLoginAt = Date()
        do {
            try context.save()
        } catch {
            context.rollback()
            print("[Session] 最后登录时间保存失败：\(error)")
            return false
        }

        // 转为轻量级会话对象
        currentUser = SessionUser(
            username: user.username,
            displayName: user.displayName,
            role: user.role,
            allowedModules: user.allowedModules
        )

        // 勾选「自动登录」→ 记住用户名与时间；未勾选 → 清掉旧记录
        if remember {
            UserDefaults.standard.set(username, forKey: Self.rememberedUsernameKey)
            UserDefaults.standard.set(Date(), forKey: Self.rememberedAtKey)
        } else {
            Self.clearRememberedLogin()
        }
        return true
    }

    /// App 启动时调用：若之前勾选过自动登录、未过 7 天且账号仍启用，则直接恢复会话。
    func restoreSessionIfValid() {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: Self.rememberedUsernameKey),
              let at = defaults.object(forKey: Self.rememberedAtKey) as? Date,
              Date().timeIntervalSince(at) <= Self.autoLoginDuration else {
            Self.clearRememberedLogin()
            return
        }
        do {
            guard let user = try findUser(username: name), user.isActive else {
                Self.clearRememberedLogin()
                return
            }
            currentUser = SessionUser(
                username: user.username,
                displayName: user.displayName,
                role: user.role,
                allowedModules: user.allowedModules
            )
        } catch {
            // 读取失败不等于“用户不存在”：保留自动登录记录，下次启动再试。
            print("[Session] 自动登录读取用户失败，保留登录记录：\(error)")
        }
    }

    /// 清除自动登录记录
    private static func clearRememberedLogin() {
        UserDefaults.standard.removeObject(forKey: rememberedUsernameKey)
        UserDefaults.standard.removeObject(forKey: rememberedAtKey)
    }

    /// 登出（主动退出时同时清除自动登录，否则下次启动又会自动进入）
    func logout() {
        currentUser = nil
        Self.clearRememberedLogin()
    }

    // MARK: - 权限判断

    /// 判断当前用户是否有权使用指定模块
    /// - 仪表盘：所有角色始终可见（固定模块）
    /// - 超管：全部有权
    /// - 管理员/员工：检查 allowedModules 列表
    func hasPermission(moduleId: String) -> Bool {
        guard let user = currentUser else { return false }
        if moduleId == "dashboard" { return true }
        switch user.role {
        case .superAdmin:
            return true
        case .admin, .staff:
            return user.allowedModules.contains(moduleId)
        }
    }

    /// 当前用户是否为超管
    var isSuperAdmin: Bool {
        currentUser?.role == .superAdmin
    }

    /// 当前用户角色名称
    var roleLabel: String {
        currentUser?.role.label ?? "未登录"
    }

    // MARK: - 工具

    /// SHA256 哈希（与 SecurityManager 一致）
    static func hash(_ text: String) -> String {
        let data = Data(text.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 统一从 User 表读取。Debug 下可被 debug-fail-fetch 开关拦截，用于验证
    /// “读库失败”不会被误判成“用户不存在/密码错误”。
    private func fetchUsers(context: ModelContext, predicate: Predicate<User>) throws -> [User] {
#if DEBUG
        if DebugFaultInjection.shouldFailUserFetch {
            throw DebugInjectedFetchError(table: "User", flagName: "debug-fail-user-fetch")
        }
#endif
        return try context.fetch(FetchDescriptor<User>(predicate: predicate))
    }

    // MARK: - 安全码验证与密码重置

    /// 通过用户名查询用户
    func findUser(username: String) throws -> User? {
        guard let container = modelContainer else { return nil }
        let context = ModelContext(container)
        let predicate = #Predicate<User> { $0.username == username }
        let users = try fetchUsers(context: context, predicate: predicate)
        return users.first
    }

    /// 验证用户名和安全码是否匹配
    @discardableResult
    func verifySecurityCode(username: String, securityCode: String) throws -> Bool {
        guard let user = try findUser(username: username) else { return false }
        guard user.isActive else { return false }
        return user.securityCodeHash == Self.hash(securityCode)
    }

    /// 使用安全码重置密码
    @discardableResult
    func resetPassword(username: String, securityCode: String, newPassword: String) throws -> Bool {
        guard try verifySecurityCode(username: username, securityCode: securityCode) else { return false }
        guard let container = modelContainer else { return false }
        let context = ModelContext(container)
        let predicate = #Predicate<User> { $0.username == username }
        let users = try fetchUsers(context: context, predicate: predicate)
        guard let user = users.first else { return false }
        user.passwordHash = Self.hash(newPassword)
        do {
            try context.save()
        } catch {
            context.rollback()
            print("[Session] 安全设置保存失败：\(error)")
            return false
        }
        return true
    }

    /// 修改安全码（需验证当前密码）
    @discardableResult
    func changeSecurityCode(username: String, currentPassword: String, newSecurityCode: String) throws -> Bool {
        guard let container = modelContainer else { return false }
        let context = ModelContext(container)
        let predicate = #Predicate<User> { $0.username == username }
        let users = try fetchUsers(context: context, predicate: predicate)
        guard let user = users.first else { return false }
        guard user.passwordHash == Self.hash(currentPassword) else { return false }
        user.securityCodeHash = Self.hash(newSecurityCode)
        do {
            try context.save()
        } catch {
            context.rollback()
            print("[Session] 安全设置保存失败：\(error)")
            return false
        }
        return true
    }
}
