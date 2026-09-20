//
//  TestDataSeeder.swift
//  杏子美甲管理系统
//
//  测试数据（v4）：仅 Debug 构建且空库时执行一次。
//  - 5 名技师（不同专长/级别）
//  - 30 位客户（普通 / 银卡 / 金卡 三级）
//  - 服务分类复用 ContentView 已插入的默认分类，不重复创建
//  - 覆盖 2026-09-01 ~ 2026-10-31，每天 5~15 单，每月随机休 2~3 天
//  - 同一技师当天时间段严格不重叠（每个技师维护顺序排班的时间游标）
//  - 已过去的预约 → 已完成（服务记录 + 结账订单），未来的 → 已预约
//

import Foundation
import SwiftData

#if DEBUG
enum TestDataSeeder {

    static let flagKey = "didSeedTestData_v4"

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

    private static func dayStart(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.startOfDay(for: date(y, m, d, 12))
    }

    private static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        calendar.range(of: .day, in: .month, for: date(y, m, 1, 12))?.count ?? 30
    }

    // MARK: - 主种子化逻辑

    private static func seed(_ ctx: ModelContext) {
        let now = Date()

        // MARK: 1. 服务分类（复用 ContentView 已插入的默认分类，避免重复）
        let existingCats = (try? ctx.fetch(FetchDescriptor<ServiceCategory>())) ?? []

        func makeOrReuseCategory(_ name: String, parent: ServiceCategory? = nil, sortOrder: Int = 0) -> ServiceCategory {
            // 按名字 + 父级匹配；默认分类已存在则直接复用，不再新建
            if let found = existingCats.first(where: { $0.name == name && $0.parentId == parent?.id }) {
                return found
            }
            let c = ServiceCategory(name: name, parentId: parent?.id, sortOrder: sortOrder)
            ctx.insert(c)
            return c
        }

        let meijia = makeOrReuseCategory("美甲", sortOrder: 1)
        let hand = makeOrReuseCategory("手部", parent: meijia, sortOrder: 1)
        let foot = makeOrReuseCategory("脚部", parent: meijia, sortOrder: 2)
        let meijie = makeOrReuseCategory("美睫", sortOrder: 2)

        func item(_ name: String, _ cat: ServiceCategory, _ price: Double, _ mins: Int, isLashTouchUp: Bool = false) -> ServiceItem {
            let i = ServiceItem(name: name, categoryId: cat.id, price: price, durationMinutes: mins, isLashTouchUp: isLashTouchUp)
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
        // 补睫/卸除属售后服务（isLashTouchUp=true）：不生成新补睫提醒、关闭旧提醒、不计到店/复购
        let l4 = item("美睫补睫", meijie, 148, 45, isLashTouchUp: true)
        let l5 = item("睫毛卸除+护理", meijie, 98, 30, isLashTouchUp: true)
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

        // MARK: 3. 客户（30 人：10 金卡 + 10 银卡 + 10 普通）
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
            case 0..<10:   level = "金卡";   baseSpent = Double.random(in: 4000...8000)
            case 10..<20:  level = "银卡";   baseSpent = Double.random(in: 1500...3500)
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

        // MARK: 4. 预约 + 服务记录 + 订单（2026-09 ~ 2026-10）
        let crafts = ["简约纯色", "猫眼渐变，建构加固", "法式白边", "自然单根种植",
                       "手绘款式", "微距单根", "足部深度SPA", "浓密款种植"]
        let paymentMethods = ["微信", "支付宝", "现金", "刷卡", "会员钱包"]

        // 营业时段 10:00 ~ 20:00（相对开门的分钟数）
        let openMin = 10 * 60
        let workableMin = 10 * 60

        var appointmentCount = 0
        var doneCount = 0
        var bookedCount = 0

        for (y, m) in [(2026, 9), (2026, 10)] {
            let dim = daysInMonth(y, m)
            // 每月随机休 2~3 天（不插任何数据）
            let restSet = Set((1...dim).shuffled().prefix(Int.random(in: 2...3)))

            for d in 1...dim where !restSet.contains(d) {
                let day = dayStart(y, m, d)
                // 当天目标单量 5~15
                let target = Int.random(in: 5...15)

                // 每个技师当天的时间游标（相对开门的分钟数），初始随机 0~20 分钟到店
                var cursor = (0..<techs.count).map { _ in Int.random(in: 0...20) }
                // 该技师当天是否还排得下（超过下班时间则置 false）
                var slotFree = [Bool](repeating: true, count: techs.count)

                var made = 0
                var safety = 0
                while made < target && slotFree.contains(true) && safety < 200 {
                    safety += 1
                    let candidates = slotFree.indices.filter { slotFree[$0] }
                    guard let ti = candidates.randomElement() else { break }
                    let tech = techs[ti]

                    // 随机 1~3 个项目，算总时长
                    let itemCount = Int.random(in: 1...3)
                    let chosen = Array(allItems.shuffled().prefix(itemCount))
                    let mins = chosen.reduce(0) { $0 + $1.durationMinutes }

                    // 上一单结束后留 0~20 分钟空隙
                    let gap = Int.random(in: 0...20)
                    let startMin = cursor[ti] + gap
                    let endMin = startMin + mins
                    // 超出营业时段：该技师今天不再排单
                    if endMin > workableMin {
                        slotFree[ti] = false
                        continue
                    }

                    let start = day.addingTimeInterval(TimeInterval((openMin + startMin) * 60))
                    let end = day.addingTimeInterval(TimeInterval((openMin + endMin) * 60))
                    // 游标推进到本单结束，保证同一技师时间段不重叠
                    cursor[ti] = endMin

                    let cust = customers.randomElement()!
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
                        doneCount += 1
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
                    } else {
                        bookedCount += 1
                    }

                    made += 1
                }
            }
        }

        // MARK: 5. 会员充值记录（部分银卡/金卡客户，9~10 月）
        let rechargeMethods = ["微信", "支付宝", "现金", "刷卡"]
        for cust in customers where cust.membershipLevel != "普通" {
            let rechargeCount = Int.random(in: 1...4)
            for _ in 0..<rechargeCount {
                let rechargeDate = date(2026,
                                        Int.random(in: 9...10),
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
        print("[TestDataSeeder] v4 已生成 \(appointmentCount) 条预约（已完成 \(doneCount) / 已预约 \(bookedCount)），覆盖 2026-09 ~ 2026-10")
    }
}
#endif
