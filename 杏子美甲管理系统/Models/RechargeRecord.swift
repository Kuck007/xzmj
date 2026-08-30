//
//  RechargeRecord.swift
//  杏子美甲管理系统
//
//  Created by AI Assistant on 2026/8/7.
//
//  会员充值记录：充值当时即计入店铺收入 + 客人累积消费

import Foundation
import SwiftData

@Model
final class RechargeRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var customerId: UUID = UUID()
    var amount: Double = 0
    var paymentMethod: String?
    var bonus: Double = 0
    var operatorNote: String?
    var rechargeAt: Date = Date()
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        customerId: UUID,
        amount: Double,
        paymentMethod: String? = nil,
        bonus: Double = 0,
        operatorNote: String? = nil,
        rechargeAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.customerId = customerId
        self.amount = amount
        self.paymentMethod = paymentMethod
        self.bonus = bonus
        self.operatorNote = operatorNote
        self.rechargeAt = rechargeAt
        self.createdAt = createdAt
    }
}
