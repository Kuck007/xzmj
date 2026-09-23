//
//  TestDataSeeder.swift
//  杏子美甲管理系统
//
//  测试数据（v5）：仅 Debug 构建且空库时执行一次。
//  时间基准：相对「今天」——过去 6 个月 + 未来 15 天，任何时候重置测试数据都能看到完整分块。
//  - 6 名技师、200 位客户（约 20% 金卡 / 30% 银卡 / 50% 普通）
//  - 营业时段 6:00 ~ 23:00（大量订单集中在 10:00 ~ 21:30，早晚少量），每月随机 2 天空数据
//  - 服务分类复用 ContentView 已插入的默认分类，不重复创建
//  - 每个客户的美睫种植周期 25~45 天一条（单条美睫项目，不含补睫项目）
//  - 美睫种植后 10~15 天生成补睫项目：90% 客户有补睫（其中 90% 走
//    「提醒→预约→记录→订单」完整 id 链路，10% 直接收银建单），2~4 个客户只种不补
//  - 美甲（手/脚）订单同样按 25~45 天周期穿插，同一天最多 1 手 + 1 脚（不出现同天 2 次手部）
//  - 同一技师当天时间段严格不重叠（每天每技师维护顺序排班的时间游标）
//  - 过去事件 → 已完成（预约 + 服务记录 + 订单 + 补睫提醒）；未来事件 → 已预约（仅预约）
//

import Foundation
import SwiftData

#if DEBUG
enum TestDataSeeder {

    static let flagKey = "didSeedTestData_v5"

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

    private static func dayStart(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.startOfDay(for: date(y, m, d, 12))
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return calendar.date(from: c) ?? Date()
    }

    private static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        calendar.range(of: .day, in: .month, for: date(y, m, 1, 12))?.count ?? 30
    }

    // MARK: - 主种子化逻辑

    private static func seed(_ ctx: ModelContext) {
        let now = Date()
        let historyStart = calendar.date(byAdding: .day, value: -180, to: now) ?? now
        let futureEnd = calendar.date(byAdding: .day, value: 15, to: now) ?? now

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

        // 12 个服务项目（手部 5 款 + 脚部 3 款 + 美睫 4 项，价格带层次）
        let n1 = item("纯色甲油胶", hand, 158, 60)
        let n2 = item("猫眼凝胶", hand, 238, 90)
        let n3 = item("法式白边", hand, 268, 90)
        let n4 = item("渐变晕染", hand, 288, 100)
        let n5 = item("手绘款式", hand, 358, 120)
        // 脚部同样是美甲款式（不是按摩项目），价格略低于手部
        let n6 = item("脚部纯色甲油胶", foot, 128, 60)
        let n7 = item("脚部猫眼凝胶", foot, 178, 75)
        let n8 = item("脚部彩绘款式", foot, 218, 90)
        let l1 = item("单根种植", meijie, 298, 90)
        let l2 = item("自然款种植", meijie, 268, 80)
        let l3 = item("浓密款种植", meijie, 328, 100)
        // 补睫属售后服务（isLashTouchUp=true）：不生成新补睫提醒、不计到店/复购
        let l4 = item("美睫补睫", meijie, 148, 45, isLashTouchUp: true)
        let lashPlants = [l1, l2, l3]
        let handItems = [n1, n2, n3, n4, n5]
        let footItems = [n6, n7, n8]

        // MARK: 2. 技师（5 人）
        let technicianData: [(String, String, String, Int, Double, Double)] = [
            ("李娜",   "13800001001", "首席美甲师，从业8年", 5, 3500, 0.15),
            ("王雪",   "13800001002", "资深美甲师，擅长款式设计", 4, 3000, 0.12),
            ("张博",   "13800001003", "资深美睫师，精通单根种植", 5, 3200, 0.18),
            ("刘芳",   "13800001004", "美甲美睫双修，足部护理专家", 4, 2800, 0.12),
            ("陈思",   "13800001005", "新晋技师，手艺精湛", 4, 2500, 0.10),
            ("赵敏",   "13800001006", "全能技师，擅长猫眼与法式", 5, 3200, 0.14),
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
        var usedNames = Set<String>()
        for i in 0..<200 {
            // 会员等级：约 20% 金卡 / 30% 银卡 / 50% 普通
            let level: String
            let baseSpent: Double
            let r = Double.random(in: 0...1)
            if r < 0.2 {
                level = "金卡"; baseSpent = Double.random(in: 4000...8000)
            } else if r < 0.5 {
                level = "银卡"; baseSpent = Double.random(in: 1500...3500)
            } else {
                level = "普通"; baseSpent = Double.random(in: 200...1200)
            }
            // 随机组合姓名并去重（30×30 组合空间足够 200 个不重复）
            var name = ""
            repeat { name = surnames.randomElement()! + givenNames.randomElement()! }
            while !usedNames.insert(name).inserted
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

        // MARK: 4. 预约 + 服务记录 + 订单 + 补睫提醒（相对今天：过去6个月 + 未来15天）
        let crafts = ["简约纯色", "猫眼渐变，建构加固", "法式白边", "自然单根种植",
                      "手绘款式", "微距单根", "脚部纯色，持久封层", "浓密款种植"]
        let paymentMethods = ["微信", "支付宝", "现金", "刷卡", "会员钱包"]

        // 营业时段 6:00 ~ 23:00（相对 0 点的分钟数）；大量订单集中在 10:00 ~ 21:30。
        // 注意：游标已是「相对 0 点的绝对分钟」，start/end 直接加 startMin，不能再叠加开门偏移（否则 +6 小时 → 下午 4 点/次日凌晨）。
        let workableMin = 23 * 60

        // 事件种类
        enum VisitKind { case lashPlant, lashTouchUp, manicure }

        /// 提醒持有者：种植事件创建提醒后写入，其补睫事件据此完成标记（模拟真实 id 传递链路）
        final class ReminderHolder {
            var reminder: LashReminder?
        }

        struct Visit {
            let customer: Customer
            let day: Date            // 当天 00:00
            let items: [ServiceItem]
            let kind: VisitKind
            let holder: ReminderHolder
            let viaLink: Bool        // 补睫是否走「提醒→预约→记录→订单」链路（90%）
        }

        var visits: [Visit] = []

        // 2~4 个客户只种美睫、不补睫（不需要或者忘了 → 产生待补睫/已过期存量）
        let noTouchUpCount = Int.random(in: 2...4)
        let noTouchUpCustomers = Set(customers.shuffled().prefix(noTouchUpCount).map { $0.id })

        for cust in customers {
            let needsTouchUp = !noTouchUpCustomers.contains(cust.id)

            // —— 美睫种植线：每 25~45 天一条（单条美睫项目，不含补睫项目）——
            var plantCursor = historyStart.addingTimeInterval(Double(Int.random(in: 0...20)) * 86400)
            while plantCursor <= futureEnd {
                let plantItem = lashPlants.randomElement()!
                let holder = ReminderHolder()
                visits.append(Visit(customer: cust,
                                    day: calendar.startOfDay(for: plantCursor),
                                    items: [plantItem],
                                    kind: .lashPlant,
                                    holder: holder,
                                    viaLink: false))

                // 种植后 10~15 天补睫（仅当落在未来 15 天窗口内）
                if needsTouchUp {
                    if let touchUpDay = calendar.date(byAdding: .day, value: Int.random(in: 10...15), to: plantCursor),
                       touchUpDay <= futureEnd {
                        // 90% 走提醒链路（带 reminderId 传递），10% 直接收银建单
                        let viaLink = Double.random(in: 0...1) < 0.9
                        visits.append(Visit(customer: cust,
                                            day: calendar.startOfDay(for: touchUpDay),
                                            items: [l4],
                                            kind: .lashTouchUp,
                                            holder: holder,
                                            viaLink: viaLink))
                    }
                }

                plantCursor = calendar.date(byAdding: .day, value: Int.random(in: 25...45), to: plantCursor) ?? plantCursor
            }

            // —— 美甲穿插线：同样按 25~45 天周期（独立节奏，与美睫错开）——
            // 同一天最多 1 个手部 + 1 个脚部（客人不会一天做 2 次手部美甲；可只手、只脚、或手+脚）
            var nailCursor = historyStart.addingTimeInterval(Double(Int.random(in: 5...30)) * 86400)
            while nailCursor <= futureEnd {
                var items: [ServiceItem] = []
                if Bool.random() { items.append(handItems.randomElement()!) }
                if Bool.random() { items.append(footItems.randomElement()!) }
                if items.isEmpty { items = [handItems.randomElement()!] }  // 至少做一个项目
                visits.append(Visit(customer: cust,
                                    day: calendar.startOfDay(for: nailCursor),
                                    items: items,
                                    kind: .manicure,
                                    holder: ReminderHolder(),
                                    viaLink: false))
                nailCursor = calendar.date(byAdding: .day, value: Int.random(in: 25...45), to: nailCursor) ?? nailCursor
            }
        }

        // 每月随机 2 天空数据（今天除外，保证任何时候打开都有数据可看）
        var emptyDays = Set<Date>()
        var monthIter = historyStart
        while monthIter <= futureEnd {
            let interval = calendar.dateInterval(of: .month, for: monthIter)!
            let start = max(interval.start, calendar.startOfDay(for: historyStart))
            let end = min(calendar.date(byAdding: .day, value: -1, to: interval.end)!, calendar.startOfDay(for: futureEnd))
            if start <= end {
                var days: [Date] = []
                var d = start
                while d <= end {
                    if !calendar.isDateInToday(d) { days.append(d) }
                    d = calendar.date(byAdding: .day, value: 1, to: d)!
                }
                days.shuffle()
                for pick in days.prefix(min(2, days.count)) { emptyDays.insert(pick) }
            }
            monthIter = calendar.date(byAdding: .month, value: 1, to: interval.start)!
        }

        // 按天分组（跳过空数据天）→ 每天用「技师游标」分配时刻，保证同一技师同一时段只有一个项目
        let grouped = Dictionary(grouping: visits, by: { $0.day }).filter { !emptyDays.contains($0.key) }

        var appointmentCount = 0
        var doneCount = 0
        var bookedCount = 0
        var reminderTotal = 0
        var reminderCompleted = 0

        for day in grouped.keys.sorted() {
            // 技师当天起始游标：90% 主窗口 10:00~13:00（大量数据铺开到 21:30 前），
            // 5% 早段 6:00~9:30、5% 晚段 21:30~21:40（最晚单可到 23:00）
            var cursors = techs.map { _ in
                let r = Double.random(in: 0...1)
                if r < 0.05 { return Int.random(in: 360...570) }
                else if r < 0.10 { return Int.random(in: 1290...1300) }
                else { return Int.random(in: 600...780) }
            }
            var slotFree = [Bool](repeating: true, count: techs.count)

            for visit in grouped[day]!.shuffled() {
                let mins = visit.items.reduce(0) { $0 + $1.durationMinutes }
                let gap = Int.random(in: 0...20)

                // 随机顺序尝试技师，找当天能排下的第一个（游标顺序追加，天然不重叠）
                var assignedTech: Technician?
                var startMin = 0
                for ti in techs.indices.shuffled() {
                    guard slotFree[ti] else { continue }
                    let s = cursors[ti] + gap
                    let e = s + mins
                    if e <= workableMin {
                        assignedTech = techs[ti]
                        startMin = s
                        cursors[ti] = e
                        break
                    } else {
                        slotFree[ti] = false  // 该技师今天已排满
                    }
                }
                guard let tech = assignedTech else { continue }  // 当天排不下（极少）：跳过

                let start = day.addingTimeInterval(TimeInterval(startMin * 60))
                let end = day.addingTimeInterval(TimeInterval((startMin + mins) * 60))
                let isPast = start < now
                let status: String = isPast ? "已完成" : "已预约"

                // 预约：种植/美甲都建；补睫只有走链路（过去）或未来预约时才建（直接收银补睫不建预约）
                let makeAppt = visit.kind != .lashTouchUp || visit.viaLink || !isPast
                var appt: Appointment?
                if makeAppt {
                    appt = Appointment(
                        customerId: visit.customer.id,
                        technicianId: tech.id,
                        serviceItemIds: visit.items.map(\.id),
                        startTime: start,
                        endTime: end,
                        status: status,
                        arrivedAt: isPast ? start : nil,
                        createdAt: start.addingTimeInterval(-300), // 预约提前 5 分钟创建
                        reminderId: visit.kind == .lashTouchUp && visit.viaLink ? visit.holder.reminder?.id : nil
                    )
                    ctx.insert(appt!)
                    appointmentCount += 1
                }

                if isPast {
                    doneCount += 1
                    // 服务记录
                    let rec = NailServiceRecord(
                        customerId: visit.customer.id,
                        technicianId: tech.id,
                        serviceDate: start,
                        serviceItemIds: visit.items.map(\.id),
                        craft: visit.kind == .lashPlant ? "自然单根种植" : visit.kind == .lashTouchUp ? "美睫补睫" : crafts.randomElement(),
                        isPaid: true,
                        reminderId: visit.kind == .lashTouchUp && visit.viaLink ? visit.holder.reminder?.id : nil,
                        appointmentId: appt?.id
                    )
                    ctx.insert(rec)

                    // 订单
                    let orig = visit.items.reduce(0) { $0 + $1.price }
                    let disc = Bool.random() ? Double([0, 10, 20, 30].randomElement()!) : 0
                    let useWallet = Bool.random() && visit.customer.membershipLevel != "普通"
                    let walletDeducted = useWallet ? min(orig * 0.3, Double.random(in: 50...200)) : 0
                    let afterWallet = orig - walletDeducted
                    let finalPaid = max(0, afterWallet - disc)

                    let primaryMethod = useWallet ? "会员钱包" : paymentMethods.randomElement()!
                    let topUpMethod = useWallet && finalPaid > 0 ? paymentMethods.randomElement() : nil

                    let order = Order(
                        recordId: rec.id,
                        customerId: visit.customer.id,
                        technicianId: tech.id,
                        lineItems: visit.items.map { OrderLineItem(serviceItemId: $0.id, name: $0.name, price: $0.price) },
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
                    visit.customer.totalSpent += finalPaid + walletDeducted
                    visit.customer.points += Int((finalPaid + walletDeducted) / 10)
                    visit.customer.lastVisitDate = end
                    visit.customer.updatedAt = end

                    // 更新技师统计
                    tech.totalServices += 1

                    // 美睫种植 → 创建补睫提醒（未完成），存进 holder 供补睫事件完成标记
                    if visit.kind == .lashPlant {
                        let reminder = LashReminder(
                            orderId: order.id,
                            customerId: visit.customer.id,
                            serviceItemIds: visit.items.map(\.id),
                            paidAt: order.paidAt,
                            dueDate: LashReminder.dueDate(from: order.paidAt, membershipLevel: visit.customer.membershipLevel)
                        )
                        ctx.insert(reminder)
                        visit.holder.reminder = reminder
                        reminderTotal += 1
                    }

                    // 补睫完成 → 把对应种植提醒标记为已补睫（90% 链路与 10% 直建都写 completedByOrderId）
                    if visit.kind == .lashTouchUp, let reminder = visit.holder.reminder {
                        reminder.isCompleted = true
                        reminder.completedAt = order.paidAt
                        reminder.completedByOrderId = order.id
                        reminderCompleted += 1
                    }
                } else {
                    bookedCount += 1
                }
            }
        }

        // MARK: 5. 会员充值记录（部分银卡/金卡客户，过去 6 个月窗口）
        let rechargeMethods = ["微信", "支付宝", "现金", "刷卡"]
        for cust in customers where cust.membershipLevel != "普通" {
            let rechargeCount = Int.random(in: 1...4)
            for _ in 0..<rechargeCount {
                let daysAgo = Int.random(in: 5...175)
                let rechargeDate = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
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
        print("[TestDataSeeder] v5 已生成 \(appointmentCount) 条预约（已完成 \(doneCount) / 已预约 \(bookedCount)），"
              + "补睫提醒 \(reminderTotal) 条（已补睫 \(reminderCompleted) / 待补 \(reminderTotal - reminderCompleted)），"
              + "时间基准：过去 180 天 ~ 未来 15 天")
    }
}
#endif
