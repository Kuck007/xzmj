//
//  TestDataSeeder.swift
//  杏子美甲管理系统
//
//  测试数据（v3）：仅 Debug 构建且空库时执行一次。
//  - 5 名技师（不同专长/级别）
//  - 30 位客户（普通 / 银牌 / 金牌 三级）
//  - 覆盖 2026-06-01 ~ 2026-08-31（3 个月），每天 1~5 条，周二休息
//  - 已过去的预约 → 服务记录 + 结账订单（含充值抵扣/混合支付）
//

import Foundation
import SwiftData

#if DEBUG
enum TestDataSeeder {

    static let flagKey = "didSeedTestData_v3"

    static func seedIfNeeded(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: flagKey) }

        let techCount = (try? context.fetch(FetchDescriptor<Technician>()))?.count ?? 0
        let custCount = (try? context.fetch(FetchDescriptor<Customer>()))?.count ?? 0
        guard techCount == 0 && custCount == 0 else { return }

        seed(context)
    }

    // MARK: - 日期工具

    private static var calendar: Calendar { Calendar.current }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return calendar.date(from: c) ?? Date()
    }

    private static func isTuesday(_ date: Date) -> Bool {
        calendar.component(.weekday, from: date) == 3 // Sunday=1 ... Tuesday=3
    }

    // MARK: - 主种子化逻辑

    private static func seed(_ ctx: ModelContext) {
        let now = Date()

        // MARK: 1. 服务分类
        let meijia = ServiceCategory(name: "美甲", sortOrder: 1)
        let hand = ServiceCategory(name: "手部", parentId: meijia.id, sortOrder: 1)
        let foot = ServiceCategory(name: "脚部", parentId: meijia.id, sortOrder: 2)
        let meijie = ServiceCategory(name: "美睫", sortOrder: 2)
        [meijia, hand, foot, meijie].forEach { ctx.insert($0) }

        func item(_ name: String, _ cat: ServiceCategory, _ price: Double, _ mins: Int) -> ServiceItem {
            let i = ServiceItem(name: name, categoryId: cat.id, price: price, durationMinutes: mins)
            ctx.insert(i)
            return i
        }

        // 12 个服务项目（覆盖手/脚/美睫，价格带层次）
        let n1 = item("纯色甲油胶", hand, 158, 60)
        let n2 = item("猫眼凝胶", hand, 238, 90)
        let n3 = item("法式白边", hand, 268, 90)
        let n4 = item("渐变晕染", hand, 288, 100)
        let n5 = item("手绘款式", hand, 358, 120)
        let n6 = item("足部基础护理", foot, 168, 70)
        let n7 = item("足部 SPA", foot, 258, 100)
        let l1 = item("单根种植", meijie, 298, 90)
        let l2 = item("自然款种植", meijie, 268, 80)
        let l3 = item("浓密款种植", meijie, 328, 100)
        let l4 = item("美睫补睫", meijie, 148, 45)
        let l5 = item("睫毛卸除+护理", meijie, 98, 30)
        let allItems: [ServiceItem] = [n1, n2, n3, n4, n5, n6, n7, l1, l2, l3, l4, l5]

        // MARK: 2. 技师（5 人）
        let technicianData: [(String, String, String, Int, Double, Double)] = [
            ("李娜",   "13800001001", "首席美甲师，从业8年", 5, 3500, 0.15),
            ("王雪",   "13800001002", "资深美甲师，擅长款式设计", 4, 3000, 0.12),
            ("张博",   "13800001003", "资深美睫师，精通单根种植", 5, 3200, 0.18),
            ("刘芳",   "13800001004", "美甲美睫双修，足部护理专家", 4, 2800, 0.12),
            ("陈思",   "13800001005", "新晋技师，手艺精湛", 4, 2500, 0.10),
        ]
        let techs: [Technician] = technicianData.map { name, phone, bio, rating, salary, rate in
            let t = Technician(name: name, phone: phone, bio: bio,
                               rating: rating, baseSalary: salary, commissionRate: rate)
            ctx.insert(t)
            return t
        }

        // MARK: 3. 客户（30 人：10 普通 + 10 银牌 + 10 金牌）
        let surnames = ["陈", "刘", "赵", "孙", "周", "吴", "郑", "王", "冯", "蒋",
                        "沈", "韩", "杨", "朱", "秦", "许", "何", "吕", "施", "张",
                        "孔", "曹", "严", "华", "金", "魏", "陶", "姜", "戚", "谢"]
        let givenNames = ["静", "雨桐", "敏", "丽", "颖", "雅琴", "雪", "倩", "璐", "欣怡",
                          "婷", "芳", "娜", "蕾", "佳", "悦", "萌", "琪", "瑶", "晗",
                          "婧", "晨", "菲", "梦琪", "思远", "雨萱", "紫涵", "可欣", "诗涵", "语桐"]

        var customers: [Customer] = []
        for i in 0..<30 {
            let level: String
            let baseSpent: Double
            switch i {
            case 0..<10:   level = "金牌";   baseSpent = Double.random(in: 4000...8000)
            case 10..<20:  level = "银牌";   baseSpent = Double.random(in: 1500...3500)
            default:       level = "普通";   baseSpent = Double.random(in: 200...1200)
            }
            let name = surnames[i] + givenNames[i]
            let phone = "139\(String(format: "%07d", 10000000 + i))"
            let c = Customer(
                name: name, phone: phone, gender: "女",
                membershipLevel: level,
                points: Int(baseSpent / 10),
                totalSpent: baseSpent
            )
            ctx.insert(c)
            customers.append(c)
        }

        // MARK: 4. 预约 + 服务记录 + 订单（2026-06-01 ~ 2026-08-31，跳过周二）
        let crafts = ["简约纯色", "猫眼渐变，建构加固", "法式白边", "自然单根种植",
                       "手绘款式", "微距单根", "足部深度SPA", "浓密款种植"]
        let paymentMethods = ["微信", "支付宝", "现金", "刷卡", "会员钱包"]

        let startDate = date(2026, 6, 1, 0, 0)
        let endDate = date(2026, 8, 31, 23, 59)
        var day = startDate
        var appointmentCount = 0

        while day <= endDate {
            if !isTuesday(day) {
                // 每天 1~5 条
                let count = Int.random(in: 1...5)
                for _ in 0..<count {
                    let cust = customers.randomElement()!
                    let tech = techs.randomElement()!
                    let itemCount = Int.random(in: 1...3)
                    let chosen = Array(allItems.shuffled().prefix(itemCount))

                    // 预约时间：10:00 ~ 20:00 之间
                    let hour = Int.random(in: 10...20)
                    let minute = [0, 15, 30, 45].randomElement()!
                    let start = date(2026,
                                     calendar.component(.month, from: day),
                                     calendar.component(.day, from: day),
                                     hour, minute)
                    let mins = chosen.reduce(0) { $0 + $1.durationMinutes }
                    let end = start.addingTimeInterval(TimeInterval(mins * 60))

                    // 约 70% 已完成，30% 仍为预约
                    let isPast = start < now
                    let status: String = isPast ? "已完成" : "已预约"

                    let appt = Appointment(
                        customerId: cust.id,
                        technicianId: tech.id,
                        serviceItemIds: chosen.map(\.id),
                        startTime: start,
                        endTime: end,
                        status: status,
                        arrivedAt: isPast ? start : nil,
                        createdAt: start.addingTimeInterval(-300) // 预约提前 5 分钟创建
                    )
                    ctx.insert(appt)
                    appointmentCount += 1

                    if isPast {
                        // 生成服务记录
                        let rec = NailServiceRecord(
                            customerId: cust.id,
                            technicianId: tech.id,
                            serviceDate: start,
                            serviceItemIds: chosen.map(\.id),
                            craft: crafts.randomElement(),
                            isPaid: true
                        )
                        ctx.insert(rec)

                        // 生成订单
                        let orig = chosen.reduce(0) { $0 + $1.price }
                        let disc = Bool.random() ? Double([0, 10, 20, 30].randomElement()!) : 0
                        let useWallet = Bool.random() && cust.membershipLevel != "普通"
                        let walletDeducted = useWallet ? min(orig * 0.3, Double.random(in: 50...200)) : 0
                        let afterWallet = orig - walletDeducted
                        let finalPaid = max(0, afterWallet - disc)

                        let primaryMethod = useWallet ? "会员钱包" : paymentMethods.randomElement()!
                        let topUpMethod = useWallet && finalPaid > 0 ? paymentMethods.randomElement() : nil

                        let order = Order(
                            recordId: rec.id,
                            customerId: cust.id,
                            technicianId: tech.id,
                            lineItems: chosen.map { OrderLineItem(
                                serviceItemId: $0.id, name: $0.name, price: $0.price
                            )},
                            totalAmount: finalPaid,
                            originalTotal: orig,
                            discountAmount: disc,
                            paymentMethod: primaryMethod,
                            walletDeducted: walletDeducted,
                            topUpPaymentMethod: topUpMethod,
                            paidAt: end
                        )
                        ctx.insert(order)

                        // 更新客户累计消费、最后到店
                        cust.totalSpent += finalPaid + walletDeducted
                        cust.points += Int((finalPaid + walletDeducted) / 10)
                        cust.lastVisitDate = end
                        cust.updatedAt = end

                        // 更新技师统计
                        tech.totalServices += 1
                    }
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }

        // MARK: 5. 会员充值记录（部分银牌/金牌客户有历史充值）
        let rechargeMethods = ["微信", "支付宝", "现金", "刷卡"]
        for cust in customers where cust.membershipLevel != "普通" {
            let rechargeCount = Int.random(in: 1...4)
            for j in 0..<rechargeCount {
                let rechargeDate = date(2026,
                                        Int.random(in: 6...8),
                                        Int.random(in: 1...28),
                                        Int.random(in: 10...19),
                                        [0, 15, 30, 45].randomElement()!)
                let amount = Double([100, 200, 300, 500, 1000].randomElement()!)
                let rec = RechargeRecord(
                    customerId: cust.id,
                    amount: amount,
                    paymentMethod: rechargeMethods.randomElement(),
                    bonus: 0,
                    rechargeAt: rechargeDate
                )
                ctx.insert(rec)
                cust.totalSpent += amount
            }
        }

        // MARK: 6. 库存
        let stockItems: [(String, String?, String?, String, Double, String, Double)] = [
            ("猫眼胶",   "AYAKO",  "C001", "色胶", 12, "瓶", 5),
            ("底胶",     "Lechat", nil,    "底胶", 8,  "瓶", 3),
            ("封层",     "Lechat", nil,    "封层", 6,  "瓶", 3),
            ("法式贴纸", nil,      nil,    "饰品", 60, "个", 20),
            ("卸甲水",   nil,      nil,    "消耗品", 2, "瓶", 5),
            ("橙花油",   nil,      nil,    "消耗品", 3, "瓶", 5),
            ("睫毛胶水", nil,      nil,    "消耗品", 4, "瓶", 5),
            ("色胶套装", "NailPro", nil,   "色胶", 15, "套", 3),
        ]
        for (name, brand, color, cat, qty, unit, threshold) in stockItems {
            let item = InventoryItem(name: name, brand: brand, colorCode: color,
                                     category: cat, quantity: qty, unit: unit,
                                     lowStockThreshold: threshold, updatedAt: Date())
            ctx.insert(item)
        }

        try? ctx.save()
        print("[TestDataSeeder] 已生成 \(appointmentCount) 条预约记录，覆盖 2026-06 ~ 2026-08（周二休息）")
    }
}
#endif
