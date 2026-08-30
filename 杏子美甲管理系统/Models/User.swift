import Foundation
import SwiftData

// MARK: - 用户角色

/// 用户角色
enum UserRole: String, Codable, CaseIterable, Equatable {
    case superAdmin
    case admin
    case staff

    var label: String {
        switch self {
        case .superAdmin: return "超级管理员"
        case .admin: return "管理员"
        case .staff: return "员工"
        }
    }
}

// MARK: - 用户模型

/// 系统用户（登录账号 + 角色 + 模块权限）
///
/// ⚠️ 迁移规则：所有非可选字段必须有默认值，新增字段必须带默认值，
/// 这样 SwiftData 轻量迁移才能自动为旧记录填充默认值，绝无删库风险。
@Model
final class User {
    @Attribute(.unique) var username: String = ""
    var passwordHash: String = ""
    var securityCodeHash: String = ""
    var displayName: String = ""
    var roleRaw: String = "staff"
    var isActive: Bool = true
    var allowedModules: [String] = []
    var createdAt: Date = Date()
    var lastLoginAt: Date?

    var role: UserRole {
        get { UserRole(rawValue: roleRaw) ?? .staff }
        set { roleRaw = newValue.rawValue }
    }

    init(
        username: String,
        passwordHash: String,
        securityCodeHash: String = "",
        displayName: String,
        role: UserRole,
        isActive: Bool = true,
        allowedModules: [String] = [],
        createdAt: Date = Date(),
        lastLoginAt: Date? = nil
    ) {
        self.username = username
        self.passwordHash = passwordHash
        self.securityCodeHash = securityCodeHash
        self.displayName = displayName
        self.roleRaw = role.rawValue
        self.isActive = isActive
        self.allowedModules = allowedModules
        self.createdAt = createdAt
        self.lastLoginAt = lastLoginAt
    }
}

extension User: Equatable {
    static func == (lhs: User, rhs: User) -> Bool {
        lhs.id == rhs.id
    }
}
