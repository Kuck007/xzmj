//
//  APIManager.swift
//  杏子美甲管理系统
//
//  内置 HTTP API 服务器，用于微信小程序预约等外部接入。
//  架构分层：业务逻辑层（可复用） + HTTP 层（Vapor）
//

import Foundation
import SwiftData
import Vapor

// MARK: - 数据传输对象（DTO）

/// API 统一响应结构
struct APIResponseBody<T: Codable & Sendable>: Content, Sendable {
    let code: Int
    let message: String?
    let data: T?
}

/// 通用错误响应
struct APIErrorBody: Content, Sendable {
    let code: Int
    let message: String
}

/// 技师信息（API 返回用）
struct APITechnician: Content, Sendable {
    let id: UUID
    let name: String
    let isActive: Bool
}

/// 服务项目信息（API 返回用）
struct APIServiceItem: Content, Sendable {
    let id: UUID
    let name: String
    let categoryName: String
    let price: Double
    let duration: Int
}

/// 已预约时间段（API 返回用）
struct APIBookedSlot: Content, Sendable {
    let startTime: String
    let endTime: String
}

/// 创建预约请求
struct APICreateAppointmentRequest: Content, Sendable {
    let customerName: String
    let customerPhone: String
    let technicianId: UUID
    let serviceItemIds: [UUID]
    let startTime: String  // ISO 8601
    let endTime: String    // ISO 8601
    let notes: String?
}

/// 创建预约响应
struct APICreateAppointmentResponse: Content, Sendable {
    let appointmentId: UUID
    let customerId: UUID
}

/// 预约信息（查询返回用）
struct APIAppointment: Content, Sendable {
    let id: UUID
    let customerName: String
    let customerPhone: String
    let technicianName: String
    let serviceNames: [String]
    let startTime: String
    let endTime: String
    let status: String
    let notes: String?
}

/// 查询预约的请求参数
struct APIAppointmentQuery: Content, Sendable {
    let name: String
    let phone: String
}

/// 删除预约的请求参数
struct APIDeleteAppointmentQuery: Content, Sendable {
    let name: String
    let phone: String
}

/// POST 删除预约的请求体
struct APIDeleteAppointmentRequest: Content, Sendable {
    let id: UUID
    let name: String
    let phone: String
}

/// 查询可用时间的请求参数
struct APIAvailabilityQuery: Content, Sendable {
    let date: String
    let technicianId: UUID
}

// MARK: - 业务逻辑层（不依赖 HTTP 框架）

final class APIService {

    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - 健康检查

    func healthCheck() -> [String: String] {
        return ["status": "ok", "service": "杏子美甲管理系统 API"]
    }

    // MARK: - 获取技师列表

    func getTechnicians() -> [APITechnician] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Technician>(
            predicate: #Predicate { $0.isActive == true },
            sortBy: [SortDescriptor(\.name)]
        )
        guard let list = try? context.fetch(descriptor) else { return [] }
        return list.map { APITechnician(id: $0.id, name: $0.name, isActive: $0.isActive) }
    }

    // MARK: - 获取服务项目列表

    func getServiceItems() -> [APIServiceItem] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<ServiceItem>(
            predicate: #Predicate { $0.isActive == true },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        guard let list = try? context.fetch(descriptor) else { return [] }

        // 批量获取分类名称
        let categoryIds = Set(list.map { $0.categoryId })
        var categoryNameMap: [UUID: String] = [:]
        if !categoryIds.isEmpty {
            let catDescriptor = FetchDescriptor<ServiceCategory>(
                predicate: #Predicate { categoryIds.contains($0.id) }
            )
            if let categories = try? context.fetch(catDescriptor) {
                for cat in categories {
                    categoryNameMap[cat.id] = cat.name
                }
            }
        }

        return list.map { item in
            APIServiceItem(
                id: item.id,
                name: item.name,
                categoryName: categoryNameMap[item.categoryId] ?? "",
                price: item.price,
                duration: item.durationMinutes
            )
        }
    }

    // MARK: - 查询某日某技师的已预约时间段

    func getAvailability(date: String, technicianId: UUID) -> [APIBookedSlot] {
        let context = ModelContext(modelContainer)

        // 解析日期为本地时间的当天 00:00
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        guard let dayDate = dateFormatter.date(from: date) else { return [] }
        let dayStart = Calendar.current.startOfDay(for: dayDate)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!

        let descriptor = FetchDescriptor<Appointment>(
            predicate: #Predicate {
                $0.technicianId == technicianId &&
                $0.startTime >= dayStart &&
                $0.startTime < dayEnd &&
                $0.status != "已取消"
            },
            sortBy: [SortDescriptor(\.startTime)]
        )

        guard let list = try? context.fetch(descriptor) else { return [] }
        let outFormatter = ISO8601DateFormatter()
        outFormatter.formatOptions = [.withInternetDateTime]
        return list.map {
            APIBookedSlot(
                startTime: outFormatter.string(from: $0.startTime),
                endTime: outFormatter.string(from: $0.endTime)
            )
        }
    }

    // MARK: - 创建预约（含客户手机号去重）

    enum APIError: Error {
        case invalidPhone
        case invalidDate
        case technicianNotFound
        case serviceItemNotFound
    }

    /// 解析 ISO8601 时间，兼容带毫秒和不带毫秒
    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        // 先试带毫秒
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        // 再试不带毫秒
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    func createAppointment(_ req: APICreateAppointmentRequest) throws -> APICreateAppointmentResponse {
        let context = ModelContext(modelContainer)

        // 1. 校验手机号格式（11位数字）
        let phone = req.customerPhone.trimmingCharacters(in: .whitespaces)
        guard phone.count == 11, CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: phone)) else {
            throw APIError.invalidPhone
        }

        // 2. 校验技师存在
        let techDescriptor = FetchDescriptor<Technician>(
            predicate: #Predicate { $0.id == req.technicianId && $0.isActive == true }
        )
        guard (try? context.fetch(techDescriptor).first) != nil else {
            throw APIError.technicianNotFound
        }

        // 3. 校验服务项目存在
        for sid in req.serviceItemIds {
            let svcDescriptor = FetchDescriptor<ServiceItem>(
                predicate: #Predicate { $0.id == sid && $0.isActive == true }
            )
            guard (try? context.fetch(svcDescriptor).first) != nil else {
                throw APIError.serviceItemNotFound
            }
        }

        // 4. 解析时间（兼容带毫秒和不带毫秒的 ISO8601）
        guard let start = Self.parseISO8601(req.startTime),
              let end = Self.parseISO8601(req.endTime) else {
            throw APIError.invalidDate
        }

        // 5. 客户去重：按手机号查找，找到则更新名字，没找到则创建
        let customerId: UUID
        let custDescriptor = FetchDescriptor<Customer>(
            predicate: #Predicate { $0.phone == phone }
        )
        if let existing = try? context.fetch(custDescriptor).first {
            existing.name = req.customerName
            existing.updatedAt = Date()
            customerId = existing.id
        } else {
            let customer = Customer(name: req.customerName, phone: phone)
            context.insert(customer)
            customerId = customer.id
        }

        // 6. 创建预约
        let appointment = Appointment(
            customerId: customerId,
            technicianId: req.technicianId,
            serviceItemIds: req.serviceItemIds,
            startTime: start,
            endTime: end,
            status: "已预约",
            notes: req.notes
        )
        context.insert(appointment)

        try? context.save()

        return APICreateAppointmentResponse(appointmentId: appointment.id, customerId: customerId)
    }

    /// 查询客户的预约（只返回"已预约"状态的，即未到店的）
    func getAppointments(name: String, phone: String) -> [APIAppointment] {
        let context = modelContainer.mainContext
        // 1. 按姓名+电话查找客户
        let custDescriptor = FetchDescriptor<Customer>(
            predicate: #Predicate { $0.name == name && $0.phone == phone }
        )
        guard let customer = try? context.fetch(custDescriptor).first else {
            return []
        }
        let customerId = customer.id
        // 2. 查找该客户的预约（先按 customerId 查，再过滤状态）
        let apptDescriptor = FetchDescriptor<Appointment>(
            predicate: #Predicate { $0.customerId == customerId }
        )
        guard let appointments = try? context.fetch(apptDescriptor) else {
            return []
        }
        let filtered = appointments.filter { $0.status == "已预约" }
        // 3. 转换为 API 格式
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return filtered.compactMap { appt in
            // 技师名
            let techId = appt.technicianId
            let techDescriptor = FetchDescriptor<Technician>(
                predicate: #Predicate { $0.id == techId }
            )
            let techName = (try? context.fetch(techDescriptor).first?.name) ?? "未知"
            // 服务项目名
            let serviceNames = appt.serviceItemIds.compactMap { sid in
                let svcDescriptor = FetchDescriptor<ServiceItem>(
                    predicate: #Predicate { $0.id == sid }
                )
                return try? context.fetch(svcDescriptor).first?.name
            }
            return APIAppointment(
                id: appt.id,
                customerName: customer.name,
                customerPhone: customer.phone,
                technicianName: techName,
                serviceNames: serviceNames,
                startTime: formatter.string(from: appt.startTime),
                endTime: formatter.string(from: appt.endTime),
                status: appt.status,
                notes: appt.notes
            )
        }
    }

    /// 删除预约（需验证姓名+电话匹配）
    func deleteAppointment(id: UUID, name: String, phone: String) -> Bool {
        let context = modelContainer.mainContext
        // 1. 查找预约
        let apptDescriptor = FetchDescriptor<Appointment>(
            predicate: #Predicate { $0.id == id }
        )
        guard let appointment = try? context.fetch(apptDescriptor).first else {
            return false
        }
        let apptCustomerId = appointment.customerId
        // 2. 验证客户姓名+电话（先按 customerId 查，再验证姓名电话）
        let custDescriptor = FetchDescriptor<Customer>(
            predicate: #Predicate { $0.id == apptCustomerId }
        )
        guard let customer = try? context.fetch(custDescriptor).first,
              customer.name == name, customer.phone == phone else {
            return false
        }
        // 3. 只能删除"已预约"状态的
        guard appointment.status == "已预约" else {
            return false
        }
        // 4. 删除
        context.delete(appointment)
        try? context.save()
        return true
    }
}

// MARK: - HTTP 层（Vapor 实现）

/// 获取 API Token（非隔离，避免 Swift 6 MainActor 推断问题）
nonisolated func APIGetToken() -> String {
    if let token = UserDefaults.standard.string(forKey: "api.token"), !token.isEmpty {
        return token
    }
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    UserDefaults.standard.set(token, forKey: "api.token")
    return token
}

final class APIManager {

    static let shared = APIManager()
    private var app: Application?
    private var service: APIService?

    /// 启动 API 服务器（后台线程，不阻塞首屏）
    nonisolated func start(modelContainer: ModelContainer, port: Int = 23666) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let service = APIService(modelContainer: modelContainer)
            DispatchQueue.main.async {
                self.service = service
            }

            // 用自定义 Environment，避免 Xcode 传入的 --NSDocumentRevisionsDebugMode 等参数被 Vapor 当成命令解析
            let env = Environment(name: "production", arguments: ["xzmj"])
            let app = Application(env)
            app.http.server.configuration.port = port
            app.http.server.configuration.hostname = "::"

            // CORS 中间件
            app.middleware.use(CORSMiddleware())
            // 错误处理中间件（统一返回 JSON）
            app.middleware.use(APIErrorMiddleware())

            // 注册路由
            self.registerRoutes(app)

            do {
                try app.start()
                DispatchQueue.main.async {
                    self.app = app
                }
                print("[API] 服务器已启动: http://127.0.0.1:\(port)")
                print("[API] Token: \(APIGetToken())")
            } catch {
                print("[API] 启动失败: \(error)")
            }
        }
    }

    /// 停止 API 服务器
    nonisolated func stop() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.app?.shutdown()
            DispatchQueue.main.async {
                self?.app = nil
                print("[API] 服务器已停止")
            }
        }
    }

    // MARK: - 路由注册

    nonisolated private func registerRoutes(_ app: Application) {
        // 健康检查（无需 Token）
        app.get("health") { _ in
            APIResponseBody(code: 0, message: nil, data: APIManager.shared.service?.healthCheck())
        }

        // 需要 Token 认证的路由组
        let api = app.grouped("api").grouped(TokenAuthMiddleware())

        // GET /api/technicians - 技师列表
        api.get("technicians") { _ in
            let list = APIManager.shared.service?.getTechnicians() ?? []
            return APIResponseBody(code: 0, message: nil, data: list)
        }

        // GET /api/services - 服务项目列表
        api.get("services") { _ in
            let list = APIManager.shared.service?.getServiceItems() ?? []
            return APIResponseBody(code: 0, message: nil, data: list)
        }

        // GET /api/availability?date=2026-09-17&technicianId=xxx - 已预约时间段
        api.get("availability") { req in
            let query = try req.query.decode(APIAvailabilityQuery.self)
            let list = APIManager.shared.service?.getAvailability(date: query.date, technicianId: query.technicianId) ?? []
            return APIResponseBody(code: 0, message: nil, data: list)
        }

        // POST /api/appointments - 创建预约
        api.post("appointments") { req in
            let body = try req.content.decode(APICreateAppointmentRequest.self)
            do {
                let result = try APIManager.shared.service?.createAppointment(body)
                return APIResponseBody(code: 0, message: "预约成功", data: result)
            } catch let error as APIService.APIError {
                let msg: String
                switch error {
                case .invalidPhone: msg = "手机号格式不正确"
                case .invalidDate: msg = "时间格式不正确"
                case .technicianNotFound: msg = "技师不存在"
                case .serviceItemNotFound: msg = "服务项目不存在"
                }
                throw Abort(.badRequest, reason: msg)
            }
        }

        // GET /api/appointments?name=xxx&phone=xxx - 查询客户预约（只返回未到店的）
        api.get("appointments") { req in
            let query = try req.query.decode(APIAppointmentQuery.self)
            let list = APIManager.shared.service?.getAppointments(name: query.name, phone: query.phone) ?? []
            return APIResponseBody(code: 0, message: nil, data: list)
        }

        // DELETE /api/appointments/:id?name=xxx&phone=xxx - 删除预约
        api.delete("appointments", ":id") { req in
            guard let idString = req.parameters.get("id"),
                  let id = UUID(uuidString: idString) else {
                throw Abort(.badRequest, reason: "预约ID无效")
            }
            let query = try req.query.decode(APIDeleteAppointmentQuery.self)
            let success = APIManager.shared.service?.deleteAppointment(id: id, name: query.name, phone: query.phone) ?? false
            if success {
                return APIResponseBody<String>(code: 0, message: "删除成功", data: nil)
            } else {
                throw Abort(.badRequest, reason: "删除失败，信息不匹配或预约状态不允许删除")
            }
        }

        // POST /api/appointments/delete - 删除预约（POST方式，兼容性更好）
        api.post("appointments", "delete") { req in
            let body = try req.content.decode(APIDeleteAppointmentRequest.self)
            let success = APIManager.shared.service?.deleteAppointment(id: body.id, name: body.name, phone: body.phone) ?? false
            if success {
                return APIResponseBody<String>(code: 0, message: "删除成功", data: nil)
            } else {
                throw Abort(.badRequest, reason: "删除失败，信息不匹配或预约状态不允许删除")
            }
        }
    }
}

// MARK: - Token 认证中间件

struct TokenAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // OPTIONS 请求直接放行（CORS 预检）
        if request.method == .OPTIONS {
            return try await next.respond(to: request)
        }

        let expected = "Bearer \(APIGetToken())"
        guard let auth = request.headers.first(name: .authorization), auth == expected else {
            let body = (try? JSONEncoder().encode(APIErrorBody(code: 401, message: "未授权"))) ?? Data()
            let response = Response(status: .unauthorized, body: .init(data: body))
            response.headers.contentType = .json
            return response
        }

        return try await next.respond(to: request)
    }
}

// MARK: - 错误处理中间件（统一返回 JSON）

struct APIErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let abort as Abort {
            let body = (try? JSONEncoder().encode(APIErrorBody(code: Int(abort.status.code), message: abort.reason))) ?? Data()
            let response = Response(status: abort.status, body: .init(data: body))
            response.headers.contentType = .json
            return response
        } catch {
            let body = (try? JSONEncoder().encode(APIErrorBody(code: 500, message: "服务器错误"))) ?? Data()
            let response = Response(status: .internalServerError, body: .init(data: body))
            response.headers.contentType = .json
            return response
        }
    }
}

// MARK: - CORS 中间件

struct CORSMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        let response = next.respond(to: request)
        return response.map { res in
            res.headers.replaceOrAdd(name: .accessControlAllowOrigin, value: "*")
            res.headers.replaceOrAdd(name: .accessControlAllowHeaders, value: "Authorization, Content-Type")
            res.headers.replaceOrAdd(name: .accessControlAllowMethods, value: "GET, POST, OPTIONS")
            return res
        }
    }
}
