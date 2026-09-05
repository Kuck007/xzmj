//
//  SecurityManager.swift
//  杏子美甲管理系统
//

import Foundation
import CryptoKit

/// 密码与安全问题管理（本地存储，SHA256 哈希）
final class SecurityManager {
    static let shared = SecurityManager()
    private let defaults = UserDefaults.standard

    private let passwordKey = "security.passwordHash"
    private let questionsKey = "security.questions"      // [[String]] 3个问题的文本
    private let answersKey = "security.answersHash"      // [String] 3个答案的哈希
    private let lastBackupKey = "backup.lastDate"        // 上次成功备份时间（主动备份）
    private let lastAutoBackupKey = "backup.lastAutoDate" // 上次自动兜底备份时间
    private let autoBackupDaysKey = "backup.autoDays"     // 自动备份周期（天），默认 15
    private let appNameKey = "app.displayName"            // 应用显示名称，默认 "杏子美甲管理系统"

    /// 备份提醒阈值：超过这个天数没备份就提醒（15 天一次，既防止忘记手动备份、也不会过于频繁）
    let backupReminderDays: TimeInterval = 15 * 24 * 3600

    /// 自动兜底备份间隔（秒），用户可配置 1-99 天，默认 15 天
    var autoBackupInterval: TimeInterval {
        let days = defaults.object(forKey: autoBackupDaysKey) as? Int ?? 15
        return TimeInterval(days) * 24 * 3600
    }

    /// 自动备份周期（天），用于设置界面显示
    var autoBackupDays: Int {
        get { defaults.object(forKey: autoBackupDaysKey) as? Int ?? 15 }
        set {
            let clamped = max(1, min(99, newValue))
            defaults.set(clamped, forKey: autoBackupDaysKey)
        }
    }

    /// 应用显示名称（登录页大标题）
    var appDisplayName: String {
        get { defaults.string(forKey: appNameKey) ?? "杏子美甲管理系统" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? "杏子美甲管理系统" : trimmed, forKey: appNameKey)
        }
    }

    /// 侧边栏主标题（短名称）
    var appSidebarTitle: String {
        get { defaults.string(forKey: "app.sidebarTitle") ?? "杏子美甲" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? "杏子美甲" : trimmed, forKey: "app.sidebarTitle")
        }
    }

    /// 侧边栏副标题
    var appSidebarSubtitle: String {
        get { defaults.string(forKey: "app.sidebarSubtitle") ?? "店铺管理系统" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? "店铺管理系统" : trimmed, forKey: "app.sidebarSubtitle")
        }
    }

    private init() {}

    // MARK: - 备份时间记录
    /// 上次成功备份时间（nil 表示从未备份）
    var lastBackupDate: Date? {
        defaults.object(forKey: lastBackupKey) as? Date
    }

    /// 标记备份成功（导出 / 导入都算"刚做完备份"）
    func markBackupDone() {
        defaults.set(Date(), forKey: lastBackupKey)
    }

    // MARK: - 自动兜底备份时间记录（不影响主动备份提醒）

    /// 上次自动兜底备份时间（nil 表示从未自动备份）
    var lastAutoBackupDate: Date? {
        defaults.object(forKey: lastAutoBackupKey) as? Date
    }

    /// 标记自动兜底备份完成
    func markAutoBackupDone() {
        defaults.set(Date(), forKey: lastAutoBackupKey)
    }

    /// 是否需要自动兜底备份（从未自动备份 或 距离上次自动备份超过间隔）
    var needsAutoBackup: Bool {
        guard let last = lastAutoBackupDate else { return true }
        return Date().timeIntervalSince(last) >= autoBackupInterval
    }

    /// 是否需要提醒备份（从未备份 或 超过阈值）
    var needsBackupReminder: Bool {
        guard let last = lastBackupDate else { return true }
        return Date().timeIntervalSince(last) >= backupReminderDays
    }

    /// 距离上次备份的天数（用于提醒文案，nil 表示从未备份）
    var daysSinceLastBackup: Int? {
        guard let last = lastBackupDate else { return nil }
        return Int(Date().timeIntervalSince(last) / 86400)
    }

    // MARK: - 密码
    var hasPassword: Bool {
        defaults.string(forKey: passwordKey) != nil
    }

    func setPassword(_ password: String) {
        defaults.set(hash(password), forKey: passwordKey)
    }

    func verifyPassword(_ password: String) -> Bool {
        guard let stored = defaults.string(forKey: passwordKey) else { return false }
        return stored == hash(password)
    }

    func changePassword(oldPassword: String, newPassword: String) -> Bool {
        guard verifyPassword(oldPassword) else { return false }
        setPassword(newPassword)
        return true
    }

    // MARK: - 安全问题
    var hasSecurityQuestions: Bool {
        defaults.array(forKey: questionsKey) != nil
    }

    func setSecurityQuestions(_ questions: [String], answers: [String]) {
        defaults.set(questions, forKey: questionsKey)
        defaults.set(answers.map { hash($0.lowercased().trimmingCharacters(in: .whitespaces)) }, forKey: answersKey)
    }

    var securityQuestions: [String] {
        defaults.stringArray(forKey: questionsKey) ?? []
    }

    func verifySecurityAnswers(_ answers: [String]) -> Bool {
        guard let storedHashes = defaults.stringArray(forKey: answersKey) else { return false }
        for i in 0..<min(answers.count, storedHashes.count) {
            if hash(answers[i].lowercased().trimmingCharacters(in: .whitespaces)) != storedHashes[i] {
                return false
            }
        }
        return true
    }

    /// 用安全问题重置密码
    func resetPassword(answers: [String], newPassword: String) -> Bool {
        guard verifySecurityAnswers(answers) else { return false }
        setPassword(newPassword)
        return true
    }

    // MARK: - 哈希
    private func hash(_ text: String) -> String {
        let data = Data(text.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 自动备份加密密钥派生
    /// 自动备份使用的固定盐值（与密码哈希混合派生密钥，防止彩虹表）
    private static let autoBackupSalt = "XingziNailAutoBackup_v1"

    /// 派生自动备份加密密钥。设置了密码才返回密钥，没设置密码返回 nil（此时自动备份为明文）。
    /// 密钥 = SHA256(密码哈希 + 盐)，32 字节 = AES-256。
    /// 使用当前存储的密码派生（用于自动备份时加密）。
    func autoBackupEncryptionKey() -> SymmetricKey? {
        guard let storedHash = defaults.string(forKey: passwordKey) else { return nil }
        let combined = (storedHash + Self.autoBackupSalt).data(using: .utf8)!
        let digest = SHA256.hash(data: combined)
        return SymmetricKey(data: digest)
    }

    /// 用指定明文密码派生自动备份解密密钥（用于导入加密备份时，可能是旧密码）。
    /// 密钥 = SHA256(SHA256(密码) + 盐)，与加密时的派生方式一致。
    func autoBackupEncryptionKey(for password: String) -> SymmetricKey {
        let combined = (hash(password) + Self.autoBackupSalt).data(using: .utf8)!
        let digest = SHA256.hash(data: combined)
        return SymmetricKey(data: digest)
    }
}
