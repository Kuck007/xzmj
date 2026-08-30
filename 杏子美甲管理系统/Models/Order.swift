import Foundation
import SwiftData

// MARK: - 订单行项

struct OrderLineItem: Codable, Identifiable, Equatable {
    let id: UUID
    var serviceItemId: UUID
    var name: String
    var price: Double

    init(id: UUID = UUID(), serviceItemId: UUID, name: String, price: Double) {
        self.id = id
        self.serviceItemId = serviceItemId
        self.name = name
        self.price = price
    }
}

// MARK: - 收银订单

/// 收银订单
/// ⚠️ 所有非可选字段均有默认值，确保 SwiftData 轻量迁移安全
@Model
final class Order {
    @Attribute(.unique) var id: UUID = UUID()
    var recordId: UUID?
    var customerId: UUID = UUID()
    var technicianId: UUID?
    var lineItems: [OrderLineItem] = []
    var totalAmount: Double = 0
    var originalTotal: Double = 0
    var discountAmount: Double = 0
    var paymentMethod: String?
    var walletDeducted: Double = 0
    var topUpPaymentMethod: String?
    var paidAt: Date = Date()
    var notes: String?

    init(
        id: UUID = UUID(),
        recordId: UUID? = nil,
        customerId: UUID,
        technicianId: UUID? = nil,
        lineItems: [OrderLineItem] = [],
        totalAmount: Double = 0,
        originalTotal: Double = 0,
        discountAmount: Double = 0,
        paymentMethod: String? = nil,
        walletDeducted: Double = 0,
        topUpPaymentMethod: String? = nil,
        paidAt: Date = Date(),
        notes: String? = nil
    ) {
        self.id = id
        self.recordId = recordId
        self.customerId = customerId
        self.technicianId = technicianId
        self.lineItems = lineItems
        self.totalAmount = totalAmount
        self.originalTotal = originalTotal
        self.discountAmount = discountAmount
        self.paymentMethod = paymentMethod
        self.walletDeducted = walletDeducted
        self.topUpPaymentMethod = topUpPaymentMethod
        self.paidAt = paidAt
        self.notes = notes
    }
}
