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

    private init() {}

    /// App 启动时注入 ModelContainer
    func configure(container: ModelContainer) {
        self.modelContainer = modelContainer ?? container
    }

    // MARK: - 登录 / 登出

    /// 登录验证。成功则设置 currentUser 并更新最后登录时间，返回 true。
    @discardableResult
    func login(username: String, password: String) -> Bool {
        guard let container = modelContainer else { return false }
        let context = ModelContext(container)
        let predicate = #Predicate<User> { $0.username == username }
        let users = (try? context.fetch(FetchDescriptor<User>(predicate: predicate))) ?? []
        guard let user = users.first else { return false }
        guard user.isActive else { return false }
        guard user.passwordHash == Self.hash(password) else { return false }

        // 更新最后登录时间
        user.lastLoginAt = Date()
        try? context.save()

        // 转为轻量级会话对象
        currentUser = SessionUser(
            username: user.username,
            displayName: user.displayName,
            role: user.role,
            allowedModules: user.allowedModules
        )
        return true
    }

    /// 登出
    func logout() {
        currentUser = nil
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

    // MARK: - 安全码验证与密码重置

    /// 通过用户名查询用户
    func findUser(username: String) -> User? {
        guard let container = modelContainer else { return nil }
        let context = ModelContext(container)
        let predicate = #Predicate<User> { $0.username == username }
        let users = (try? context.fetch(FetchDescriptor<User>(predicate: predicate))) ?? []
        return users.first
    }

    /// 验证用户名和安全码是否匹配
    @discardableResult
    func verifySecurityCode(username: String, securityCode: String) -> Bool {
        guard let user = findUser(username: username) else { return false }
        guard user.isActive else { return false }
        return user.securityCodeHash == Self.hash(securityCode)
    }

    /// 使用安全码重置密码
    @discardableResult
    func resetPassword(username: String, securityCode: String, newPassword: String) -> Bool {
        guard verifySecurityCode(username: username, securityCode: securityCode) else { return false }
        guard let container = modelContainer else { return false }
        let context = ModelContext(container)
        let predicate = #Predicate<User> { $0.username == username }
        let users = (try? context.fetch(FetchDescriptor<User>(predicate: predicate))) ?? []
        guard let user = users.first else { return false }
        user.passwordHash = Self.hash(newPassword)
        try? context.save()
        return true
    }

    /// 修改安全码（需验证当前密码）
    @discardableResult
    func changeSecurityCode(username: String, currentPassword: String, newSecurityCode: String) -> Bool {
        guard let container = modelContainer else { return false }
        let context = ModelContext(container)
        let predicate = #Predicate<User> { $0.username == username }
        let users = (try? context.fetch(FetchDescriptor<User>(predicate: predicate))) ?? []
        guard let user = users.first else { return false }
        guard user.passwordHash == Self.hash(currentPassword) else { return false }
        user.securityCodeHash = Self.hash(newSecurityCode)
        try? context.save()
        return true
    }
}
