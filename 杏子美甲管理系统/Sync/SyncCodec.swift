//
//  SyncCodec.swift
//  杏子美甲管理系统
//
//  增量同步的编解码与哈希。纯值计算，不触碰 SwiftData / UI。
//  行哈希必须稳定：同一内容在任何机器、任何次数编码后哈希一致。
//

import CryptoKit
import Foundation

enum SyncCodec {

    // MARK: - 编解码器

    /// 同步专用编码器：键排序 + 秒级时间戳，保证同一内容编码结果稳定。
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try makeEncoder().encode(value)
        } catch {
            throw SyncError.encodeFailed(String(describing: error))
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw SyncError.stateCorrupted(String(describing: error))
        }
    }

    // MARK: - 哈希

    static func sha256Hex(_ data: Data) -> String {
        // 注意：不要用 String(format: "%02x", byte)。每字节一次 String(format:)
        // 在 6000+ 行差分时会额外消耗约 300ms（实测），这里用查表直接拼 UTF8。
        let digest = SHA256.hash(data: data)
        var bytes = [UInt8]()
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(Self.hexDigits[Int(byte >> 4)])
            bytes.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    /// 行内容哈希：只编码业务行本身，不混入 HLC / writerId / changeId。
    static func rowHash<T: Encodable>(_ row: T) throws -> String {
        try rowHash(row, using: makeEncoder())
    }

    /// 批量差分时复用同一个 encoder。
    /// 实测：每行新建 JSONEncoder 的开销远大于编码本身（6332 行曾达 308ms）。
    static func rowHash<T: Encodable>(_ row: T, using encoder: JSONEncoder) throws -> String {
        do {
            return sha256Hex(try encoder.encode(row))
        } catch {
            throw SyncError.encodeFailed(String(describing: error))
        }
    }

    // MARK: - 命名

    /// 云端文件名遵循方案 §6.1：同目录平铺，不加前缀。
    /// 目录本身是 `{应用标题}/sync`，与备份目录天然分开。
    static var storeFileName: String { "store.json" }

    /// 云端文件名：change-{writerId}-{seq6}-{changeId}.enc
    static func changeFileName(writerId: String, writerSeq: Int, changeId: String) -> String {
        "change-\(writerId)-\(String(format: "%06d", writerSeq))-\(changeId).enc"
    }

    /// enc 对应的明文 meta 文件名。
    static func metaFileName(encFileName: String) -> String {
        if encFileName.hasSuffix(".enc") {
            return String(encFileName.dropLast(4)) + ".meta.json"
        }
        return encFileName + ".meta.json"
    }

    /// meta 文件名反推 enc 文件名（删除旧包/旧快照时用）。
    /// 注意必须补回 `.enc`：只去掉 `.meta.json` 得到的是去掉后缀的名字，不是 enc 文件名。
    static func encFileName(fromMetaFileName name: String) -> String? {
        guard name.hasSuffix(".meta.json") else { return nil }
        return String(name.dropLast(".meta.json".count)) + ".enc"
    }

    static func keyEnvelopeFileName(writerId: String) -> String {
        "key-\(writerId).json"
    }

    static func snapshotFileName(snapshotId: String) -> String {
        "snapshot-\(snapshotId).enc"
    }

    static func snapshotMetaFileName(snapshotId: String) -> String {
        "snapshot-\(snapshotId).meta.json"
    }

    /// 随机 changeId：UUID 去横线小写，只要求唯一、不要求有序。
    static func newChangeId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// 随机 writerId：10 位 base36，只用于标识写入者与打破版本平局。
    static func newWriterId() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<10).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}
