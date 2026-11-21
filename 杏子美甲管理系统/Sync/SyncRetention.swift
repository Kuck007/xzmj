//
//  SyncRetention.swift
//  杏子美甲管理系统
//
//  云端保留策略（纯计算，不碰网络与数据库）。
//  目的：让云端 sync 目录的文件数有上限，避免 PROPFIND 列表随年月线性变慢。
//  正确性前提：被删除的包必须已被最新一份快照完整覆盖；快照才是全量恢复基础，
//  「保留最近若干包」只是让短期离线的机器少下载一次整份快照。
//

import Foundation

struct SyncRetentionPolicy {
    /// 保留最近 15 天产生的包
    static let keepDays: Double = 15
    /// 至少保留这么多最新包（低活跃时避免窗口太窄）
    static let minKeepPackages = 50
    /// 最多保留这么多包（高活跃时文件数硬上限）
    static let maxKeepPackages = 400
    /// 快照保留份数（最新一份用于自动恢复，其余为灾备副本）
    static let keepSnapshots = 3
    /// 云端包数超过该值时提示整理。
    /// 取 800 而不是保留上限 400：整理后仍会保留 400 个包，若按 400 提示会一直亮着；
    /// 800 意味着积压约两倍保留量，整理一次可回收约 400 个包。
    static let compactHintThreshold = 800
    /// 允许执行整理的最低包数（低于此值按钮置灰）。
    /// 整理后稳态约 400 包，放在 600 可以让每次整理至少回收约 200 包，避免无意义删除。
    static let compactMinPackages = 600
    /// 只有 enc 没有 meta 的孤儿文件，超过该天数可删（上传中断产物，消费方本就忽略）
    static let orphanMaxAgeDays: Double = 7
}

enum SyncRetention {

    struct PackageRef {
        var changeId: String
        var createdAt: Date
    }

    /// 计算保留窗口内的 changeId。
    /// 规则：按时间倒序，最多取 maxKeepPackages 个作为候选；候选里 keepDays 内的全部保留；
    /// 若不足 minKeepPackages，再从候选中补足。
    /// 注意：createdAt 来自各机时钟，仅用于「保留多久」这类性能策略，不参与正确性判断。
    static func keepChangeIds(_ packages: [PackageRef],
                              now: Date = Date()) -> Set<String> {
        let sorted = packages.sorted { $0.createdAt > $1.createdAt }
        let candidates = sorted.prefix(SyncRetentionPolicy.maxKeepPackages)
        let cutoff = now.addingTimeInterval(-SyncRetentionPolicy.keepDays * 86400)
        var keep = Set(candidates.filter { $0.createdAt >= cutoff }.map(\.changeId))
        if keep.count < SyncRetentionPolicy.minKeepPackages {
            keep.formUnion(sorted.prefix(SyncRetentionPolicy.minKeepPackages).map(\.changeId))
        }
        return keep
    }

    /// 可删除的包：已被快照覆盖（applied）且不在保留窗口内。
    static func prunableChangeIds(_ packages: [PackageRef],
                                  applied: Set<String>,
                                  now: Date = Date()) -> Set<String> {
        let keep = keepChangeIds(packages, now: now)
        return Set(packages.map(\.changeId).filter { applied.contains($0) && !keep.contains($0) })
    }
}
