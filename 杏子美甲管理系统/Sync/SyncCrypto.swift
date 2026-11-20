//
//  SyncCrypto.swift
//  杏子美甲管理系统
//
//  增量同步密钥层（阶段 2）：storeKey、Keychain、同步口令 → KEK、钥匙信封、ChangeSet 加解密。
//  不触碰 SwiftData / UI；只做纯密钥与字节运算，可安全在后台线程调用。
//
//  与全量备份共用同一套 AES-256-GCM 容器格式（魔数 "ENCR"），
//  但密钥来源不同：备份用系统密码派生，同步用每套店随机生成的 storeKey。
//

import CryptoKit
import Foundation
import Security

// MARK: - storeKey 钥匙串

enum SyncKeychain {
    /// 独立前缀，避免与 WebDAV 密码（com.kuck.nail.webdav）冲突。
    static let service = "com.kuck.nail.sync"

    /// 生成 32 字节随机 storeKey（AES-256）。
    static func randomStoreKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    static func storeKey(storeId: String) -> SymmetricKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: storeId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    @discardableResult
    static func saveStoreKey(_ key: SymmetricKey, storeId: String) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: storeId
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func deleteStoreKey(storeId: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: storeId
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 稳定的密钥标识：只用于 meta.keyId 与钥匙信封展示，不能据此推导密钥。
    static func keyId(_ key: SymmetricKey) -> String {
        let data = key.withUnsafeBytes { Data($0) }
        return String(SyncCodec.sha256Hex(data).prefix(8))
    }
}

// MARK: - 钥匙信封

/// 云端每个 writer 一个可覆盖的钥匙信封（不是 ChangeSet，不受不可变规则限制）。
struct SyncKeyEnvelope: Codable, Equatable {
    var formatVersion: Int
    var storeId: String
    var writerId: String
    var keyId: String
    var wrapKeyId: String
    var wrappedStoreKey: String
    var updatedAt: Double

    static let currentFormatVersion = 3

    static func fileName(writerId: String) -> String {
        SyncCodec.keyEnvelopeFileName(writerId: writerId)
    }
}

// MARK: - 口令与加解密

enum SyncCrypto {
    /// 同步口令最短长度。口令独立于系统密码，只用于封装 storeKey。
    static let minPassphraseLength = 8

    private static let magic = Data("ENCR".utf8)
    private static let kekContext = "xzmj-sync-kek-v1"

    static func validatePassphrase(_ passphrase: String) throws {
        guard passphrase.count >= minPassphraseLength else {
            throw SyncError.passphraseTooShort(minPassphraseLength)
        }
    }

    /// KEK = SHA256(固定上下文 + storeId + 口令)。
    /// storeId 参与派生，保证不同店即使口令相同也得到不同密钥。
    static func deriveKEK(passphrase: String, storeId: String) -> SymmetricKey {
        let input = Data("\(kekContext):\(storeId):\(passphrase)".utf8)
        return SymmetricKey(data: SHA256.hash(data: input))
    }

    /// 口令标识：只用于信封展示与判断“是不是同一口令”，不可反推口令。
    static func wrapKeyId(passphrase: String, storeId: String) -> String {
        let input = Data("\(kekContext):wrap-id:\(storeId):\(passphrase)".utf8)
        return String(SyncCodec.sha256Hex(input).prefix(8))
    }

    // MARK: 钥匙封装

    static func wrap(storeKey: SymmetricKey, passphrase: String, storeId: String) throws -> String {
        try validatePassphrase(passphrase)
        let kek = deriveKEK(passphrase: passphrase, storeId: storeId)
        let raw = storeKey.withUnsafeBytes { Data($0) }
        do {
            let sealed = try AES.GCM.seal(raw, using: kek, authenticating: Data(storeId.utf8))
            guard let combined = sealed.combined else {
                throw SyncError.cryptoFailed("无法生成钥匙密文")
            }
            return combined.base64EncodedString()
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.cryptoFailed("封装 storeKey 失败：\(error.localizedDescription)")
        }
    }

    static func unwrap(_ wrapped: String, passphrase: String, storeId: String) throws -> SymmetricKey {
        try validatePassphrase(passphrase)
        guard let combined = Data(base64Encoded: wrapped) else {
            throw SyncError.cryptoFailed("钥匙信封内容不是合法 base64")
        }
        let kek = deriveKEK(passphrase: passphrase, storeId: storeId)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let raw = try AES.GCM.open(box, using: kek, authenticating: Data(storeId.utf8))
            guard raw.count == 32 else {
                throw SyncError.cryptoFailed("解封出的 storeKey 长度异常")
            }
            return SymmetricKey(data: raw)
        } catch let error as SyncError {
            throw error
        } catch {
            // 口令错误时 AES-GCM 认证失败会走到这里
            throw SyncError.cryptoFailed("同步口令不正确，或信封不属于这套数据")
        }
    }

    static func makeEnvelope(storeKey: SymmetricKey,
                             passphrase: String,
                             storeId: String,
                             writerId: String,
                             now: Date = Date()) throws -> SyncKeyEnvelope {
        SyncKeyEnvelope(formatVersion: SyncKeyEnvelope.currentFormatVersion,
                        storeId: storeId,
                        writerId: writerId,
                        keyId: SyncKeychain.keyId(storeKey),
                        wrapKeyId: wrapKeyId(passphrase: passphrase, storeId: storeId),
                        wrappedStoreKey: try wrap(storeKey: storeKey, passphrase: passphrase, storeId: storeId),
                        updatedAt: now.timeIntervalSince1970)
    }

    // MARK: ChangeSet / Snapshot 加解密（复用备份容器格式）

    static func encrypt(_ data: Data, storeKey: SymmetricKey) throws -> Data {
        do {
            let sealed = try AES.GCM.seal(data, using: storeKey)
            guard let combined = sealed.combined else {
                throw SyncError.cryptoFailed("无法生成同步包密文")
            }
            return magic + combined
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.cryptoFailed("加密同步包失败：\(error.localizedDescription)")
        }
    }

    static func decrypt(_ data: Data, storeKey: SymmetricKey) throws -> Data {
        guard data.starts(with: magic) else {
            throw SyncError.cryptoFailed("不是加密的同步包")
        }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
            return try AES.GCM.open(box, using: storeKey)
        } catch {
            throw SyncError.cryptoFailed("解密同步包失败：密钥不匹配或内容损坏")
        }
    }
}
