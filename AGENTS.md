# AGENTS.md — 杏子美甲管理系统

> 本文件是所有 AI Agent（Trae / Codex / Cursor / Claude Code / ...）在本项目上工作前必须阅读的开发规范。
> 目标：让任何一个新 agent 拿到仓库就能立即按正确的方式开发，不踩历史上踩过的坑。

---

## 项目概述

macOS 原生应用（SwiftUI + SwiftData），美甲店铺管理系统。功能涵盖：Dashboard 概览、客户管理、技师管理、服务项目、预约/服务记录/订单结账、会员充值、库存、技师排班/薪资、收入统计、美睫提醒、用户权限（超管/管理员/技师）、自动备份/手动备份/加密备份、安全密码与找回。

- **项目路径**：`/Users/kuck/Documents/杏子美甲管理系统`
- **Xcode 工程**：`杏子美甲管理系统.xcodeproj`
- **最低系统版本**：macOS 15.7

---

## 技术栈

| 层 | 选型 |
|---|---|
| UI | SwiftUI（NavigationSplitView 为主框架） |
| 数据持久化 | SwiftData（选它而不是 JSON 文件） |
| 密码/密钥 | CryptoKit（SHA256 哈希 + AES 加密备份） |
| 架构 | 灵活树结构数据模型（如服务分类自引用 parentId） |

### 目录结构

```
杏子美甲管理系统/
├── 杏子美甲管理系统App.swift       // App 入口，必须注入 SessionManager.shared
├── RootView.swift                  // 登录态路由
├── ContentView.swift               // NavigationSplitView + 侧边栏主体
├── DesignSystem.swift              // 品牌色、主题、通用 style
├── TestDataSeeder.swift            // DEBUG 下首次启动自动填充测试数据
├── Models/                         // SwiftData @Model 类
├── Security/
│   ├── SessionManager.swift        // 登录态、角色权限
│   ├── SecurityManager.swift       // 密码、安全问题、备份时间、应用名称配置
│   ├── BackupManager.swift         // 备份导出/导入（支持加密）
│   └── ImageCompressor.swift
└── Views/                          // 各功能模块 UI
```

## 数据模型速查

> 13 个 @Model 类，通过 UUID 外键关联（不使用 SwiftData 原生关系，全部用 UUID + 手动查询）。

| 模型 | 用途 | 关键字段 | 关联 |
|---|---|---|---|
| `Customer` | 客户 | `name`, `phone`, `membershipLevel`(普通/银卡/金卡), `isActive`, `tags: [String]` | → Order, Appointment, RechargeRecord |
| `Technician` | 技师 | `name`, `isActive` | → Order, Appointment, NailServiceRecord |
| `ServiceCategory` | 服务分类 | `name`, `parentId`（自引用树结构） | → ServiceItem |
| `ServiceItem` | 服务项目 | `name`, `price`, `durationMinutes`, `isLashTouchUp` | → ServiceCategory |
| `Order` | 订单（收银结账） | `customerId`, `technicianId`, `lineItems: [OrderLineItem]`, `totalAmount`, `walletDeducted`, `paidAt`, `paymentMethod` | → Customer, Technician |
| `NailServiceRecord` | 服务记录（预约到店记录） | `customerId`, `technicianId`, `serviceDate` | → Customer, Technician, ServiceItem |
| `Appointment` | 预约 | `customerId`, `technicianId`, `startTime`, `status` | → Customer, Technician |
| `RechargeRecord` | 充值记录 | `customerId`, `amount`, `bonus`, `rechargeAt` | → Customer |
| `InventoryItem` | 库存 | `name`, `quantity`, `unit` | — |
| `CommissionRule` | 提成规则 | `technicianId`, `serviceItemId`, `rate` | → Technician, ServiceItem |
| `LashReminder` | 补睫提醒 | `customerId`, `dueDate`, `completed` | → Customer |
| `DailyReconciliation` | 技师日结对账 | `technicianId`, `date`, `confirmed` | → Technician |
| `User` | 登录账号 | `username`(unique), `passwordHash`, `role`, `linkedTechnicianId` | → Technician |

**查询模式**：不用 @Query 关系遍历，而是 `@Query private var allOrders: [Order]` 然后 `filter { $0.customerId == cid }` 或 `Dictionary(grouping:by:)` 分组。新代码遵循此模式。

---

## 环境与依赖

| 项 | 值 |
|---|---|
| macOS 部署目标 | 15.5 |
| Swift 版本 | 5.0 |
| 默认 Actor 隔离 | `MainActor`（Release/Debug 均设） |
| Release 架构 | arm64 only（2026-09-19 起，砍掉 x86_64） |
| SPM 主依赖 | Vapor 4（HTTP API 服务器）、Sparkle（自动更新） |
| 数据库路径 | `/Users/kuck/Library/Application Support/xzmj/`（沙箱已关闭） |
| Debug bundle ID | `com.kuck.nail.Debug`（数据与 Release 隔离） |
| Release bundle ID | `com.kuck.nail.--------` |
| 签名证书 | Apple Development: ligaoxiang_1@163.com (Team 6D7L3A4757) |

---

## 编码规范

- **类名/文件名**：英文 PascalCase（如 `CustomerView.swift`）；目录名保留中文（`杏子美甲管理系统/`）
- **新增文件位置**：模型放 `Models/`，视图放 `Views/`，安全/工具放 `Security/`，API 相关放 `Views/API/`
- **魔法数字**：禁止硬编码。时间阈值（如沉睡 3 个月）、金额阈值（如金卡 5000）、分页大小（20）等用局部 `let` 或注释说明
- **注释**：复杂业务逻辑必须注释"为什么"，不只注释"做什么"。踩坑原因必须记录（参考本文档风格）
- **删除死代码**：重构时发现无用代码直接删，不保留注释掉的代码块
- **不引入新第三方库**：除非用户明确要求。现有 Vapor + Sparkle 已满足需求

---
## 编译与运行

```bash
# ✅ 唯一需要的编译验证方式（快）
xcodebuild build -project "杏子美甲管理系统.xcodeproj" -scheme "杏子美甲管理系统" -destination 'platform=macOS'

# ❌ 不要用 archive（太慢）。除非用户明确要求。
```

---

## ⛔ 红线：每次改动必须过这三关（过不了就不能合并）

> 历史上多次因为忽视这三条导致删库或升级崩溃，**任何改动都要对照检查**。

### 1. 备份功能 + 旧备份恢复

- 改动后，当前版本能正常导出备份（含加密备份）
- 用旧版本（或 git stash 到上一个 commit）生成的备份文件，在新版本上能正常导入恢复
- 导入后数据完整、App 能正常打开

### 2. 旧版 → 新版升级不崩（SwiftData 迁移零容忍）

> **最高优先级红线**：任何 @Model 改动必须保证轻量迁移成功，绝对不允许出现数据库被清空的情况。历史上已发生过因迁移失败导致全部数据丢失的事故。

- 在旧版上跑一遍，产生真实数据
- 覆盖安装新版，App 能正常打开、数据不丢失、不报 SwiftData migration error
- **新增 SwiftData @Model 字段必须在声明处有默认值**，禁止裸声明：
  ```swift
  // ✅ 正确
  var newField: String = ""
  var newCount: Int = 0
  var optionalField: String? = nil

  // ❌ 禁止（SwiftData 迁移会崩，所有已有数据丢失）
  var newField: String
  ```
- **绝对禁止使用 `id` 作为 @Model 存储属性名**：SwiftData @Model 自动生成 `id`（PersistentIdentifier 类型），新增同名存储属性会触发迁移冲突，直接清空数据库。需要唯一标识时用 `uuid`、`userId` 等其他名字，或用已有的 `@Attribute(.unique)` 字段（如 `username`）
- **禁止删除或重命名 @Model 字段**：旧用户升级后该字段数据丢失，且可能触发复杂迁移。如需废弃字段，保留字段并标记 `// deprecated`，不要删除
- **禁止修改 @Model 字段类型**：如 `String` 改 `Int`、`UUID` 改 `String`，会触发复杂迁移导致崩溃
- **禁止修改 @Attribute(.unique) 约束**：新增或移除 unique 约束可能触发复杂迁移
- **新增 @Model 类是安全的**：全新模型不影响已有数据迁移
- **新增 @Model 类必须同时加入 Schema 列表**：在 `杏子美甲管理系统App.swift` 的 `Schema([...])` 中添加新模型类，否则 Core Data 找不到实体，导入备份时会崩溃
- **改动 @Model 后必须手动验证迁移**：用旧版产生数据 → 覆盖安装新版 → 确认数据完整。不能只靠编译通过就认为迁移安全

### 2.5 沙箱开关零容忍（会导致数据路径变化，等效清库）

> **2026-09-09 事故记录**：关闭沙箱后，App 数据路径从 `~/Library/Containers/<bundle-id>/Data/` 变为 `~/Library/Application Support/`，App 找不到旧数据库就创建空库，等效清库。UserDefaults 同理。

- **绝对禁止随意开启或关闭沙箱**（修改 entitlements 中的 `com.apple.security.app-sandbox`）
- 如果必须切换沙箱状态，必须先手动迁移数据：
  ```bash
  # 沙箱 → 非沙箱：迁移数据库
  cp ~/Library/Containers/<bundle-id>/Data/Library/Application\ Support/default.store* ~/Library/Application\ Support/
  # 迁移 UserDefaults
  cp ~/Library/Containers/<bundle-id>/Data/Library/Preferences/<bundle-id>.plist ~/Library/Preferences/
  ```
- 当前状态：**沙箱已关闭**（2026-09-09，为解决 Sparkle 自动更新安装失败问题）

### 3. UserDefaults key 和 SwiftData schema 的兼容性

- 新增 UserDefaults key：用带前缀的命名（如 `app.displayName`、`backup.autoDays`），避免和已有 key 冲突
- 不要随意删除或重命名已有的 UserDefaults key——旧用户升级后会丢失该配置

---

## SwiftUI 开发铁律（NavigationSplitView + Sheet）

> 2026-08-28 调试确认，违反会导致 sheet "弹关弹" 或丢失进入动画。

1. **detail column 里禁止 NavigationStack**：NavigationSplitView 自动处理 `.navigationTitle` / `.toolbar` / `.searchable`，NavigationStack 是冗余的，且会吃掉 sheet 首次 present 的进入动画
2. **sheet / alert 必须挂在 body 根级别**：不能嵌套在任何 NavigationStack 或子视图内，否则首次 mount 时内部 @Query 重发布 → body 重评估 → sheet 被误 dismiss
3. **onAppear / onChange 里写数据库要延迟 runloop**：`context.insert` / `context.save` 会触发 @Query 重发布，必须用 `DispatchQueue.main.async` 延迟到下一个 runloop
4. **detail column 可以保留 `.transition` + `.animation`**（淡入 + 轻微缩放 + 上滑），只要 sheet 已外移到 body 根级别就不会冲突
5. **Row 回调直接调用**：不需要额外 DispatchQueue 包装


## 并发规则（MainActor 默认隔离）

> project.pbxproj 设置了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，所有类型默认 @MainActor。

1. **后台线程方法必须加 `nonisolated`**：如果方法需要在后台线程调用（如备份导出），加 `nonisolated` 关键字
2. **nonisolated 方法内禁止触碰**：SwiftData context（`context`）、UI 状态、任何 @MainActor 隔离的共享状态
3. **nonisolated 方法可以做**：纯数据映射、JSON 编解码、文件 I/O、网络请求
4. **onAppear / onChange 写数据库**：必须 `DispatchQueue.main.async` 延迟到下一个 runloop，否则 @Query 重发布会导致 sheet 被 dismiss（见 SwiftUI 铁律第 3 条）
5. **不要混用 Task 嵌套**：SwiftUI 视图的 `Task { }` 已在 MainActor 上下文，不需要额外 `@MainActor` 标注

---
## 权限模型

| 角色 | 可见模块 |
|---|---|
| superAdmin（超管） | 全部模块 + 用户管理 + 自动备份设置 + 应用名称设置 |
| admin（管理员） | 除用户管理外的全部 + 自动备份设置 |
| staff（技师） | 仅 Dashboard + 与自身相关的模块 |

- `SessionManager` 必须在 App 入口注入：`.environment(SessionManager.shared)`
- 模块权限列表从 `SidebarItem.allCases` 动态生成，新增模块自动出现在权限设置里


## 新增功能模块指南

> 加一个全新功能模块（如"会员卡"、"短信营销"）需要动以下 6 处：

1. **新建 @Model 类**（`Models/YourModel.swift`）
   - 所有字段必须有默认值（红线规则）
   - 用 `var id: UUID = UUID()` 作为唯一标识（**禁止用 `id` 作为 @Attribute 名以外的冲突名**——SwiftData 自动生成 PersistentIdentifier id，见红线）
   - 关联其他模型用 UUID 外键，不用 SwiftData Relationship

2. **加入 Schema 列表**（`杏子美甲管理系统App.swift`）
   - 在 `Schema([...])` 数组里加 `YourModel.self`
   - 不加会导致 Core Data 找不到实体，导入备份崩溃

3. **注册侧边栏入口**（`ContentView.swift`）
   - 在 `SidebarItem` 枚举加 case（如 `case memberCard = "会员卡"`）
   - 在 `side` 计算属性加 SF Symbol 名
   - 在 detail 视图 switch 里加 case 跳转到新 View

4. **创建 View**（`Views/YourView.swift`）
   - 遵循 SwiftUI 铁律：sheet 挂 body 根级别、不用 NavigationStack、用 HoverHighlightRow
   - 列表行用 `HoverHighlightRow`，主按钮用 `BrandPrimaryButtonStyle()`

5. **权限接入**
   - `SidebarItem.allCases` 自动出现在权限设置里
   - staff 角色默认只能看 Dashboard + 自身相关模块，如需限制在 `SessionManager` 权限判断里加规则

6. **备份兼容**
   - 新 @Model 自动被备份包含（BackupManager 遍历 Schema）
   - 但如果备份格式有关键变更，需要更新 BackupManager 的 encode/decode 逻辑

---
## UI 规范

### 主题风格

赛博朋克霓虹风：深色（黑底霓虹青）为主，品牌强调色 `.brand`（霓虹青）和 `.brandMagenta`（荧光粉）。TechCalendarPicker 已实现此风格。

### Hover 高亮（所有可交互列表行必须实现）

- 鼠标进入：0.02s 快速高亮 + 霓虹描边 + 外发光
- 鼠标退出：0.6s 缓慢淡出
- 侧边栏选中态：0.32 透明度填充 + 0.95 透明度青色霓虹描边 + 8pt 外发光 + icon 从灰色切换为亮青色
- 侧边栏 hover 描边向内缩进（左右 8pt、底部 10pt），避免被圆角遮挡

### 可复用组件

| 组件 | 用途 | 关键实现 |
|---|---|---|
| `HoverHighlightRow` | 所有列表行统一 hover 效果 | 封装上述 hover 动画 |
| `BrandPrimaryButtonStyle()` | 主操作按钮（新增、确定等） | 霓虹描边 + 胶囊 + 品牌色发光 + 按压反馈 |
| `PasswordInputRow` | 所有密码输入 | 眼睛图标切换显示/隐藏 |
| `CenteredTextField` | 需要居中的文本输入 | NSViewRepresentable + `.center` 对齐 + 无边框无背景 |
| `ScrollableTextField` | 固定高度、超长水平滚动 | NSViewRepresentable + `lineBreakMode = .byClipping` |
| `EditableSettingRow` | 设置项的"锁定态 ↔ 编辑态" | 修改/取消/确定按钮 + 长度限制 + 本地 @State 实时刷新 |
| `TechCalendarPicker` | 赛博朋克风日历 | 顶部霓虹渐变条 + 周末高亮 + today 霓虹描边 + 选中发光 |

### Sheet 呈现方式

```swift
// ✅ 正确
.sheet(isPresented: Binding(get:set:)) {
    if let item = item { SomeSheet(item: item) }
}

// ❌ 禁止（会自动 nil-setting 导致意外 dismiss）
.sheet(item: $item) { ... }
```

### 按钮间距

toolbar 里多个按钮用 `HStack(spacing: 8)`，与客户信息模块保持一致。

### 日期时间编辑

- 日历选择器和时间选择器**不联动**：调时间不改日期，选日期保留原有时间
- 编辑用本地 draft state，popover 关闭时才提交到 model

---

## 用户偏好（Agent 必须遵守）

- 沟通语言：**中文**
- 倾向**修改和扩展**现有代码，而不是推倒重来
- 倾向**保持已知可靠的现有方案**（如 Finder 拖拽导出），而非改 Xcode entitlements 等配置
- 偏好**根治问题**而非绕开（如修复数据源防止出现"付宝"条目，而非只改统计逻辑）
- UI 追求**对齐一致**和**组件高度统一**
- 自定义 UI 出功能性问题时，回退到 macOS 原生方案（如圆角按钮）
- 版本控制：**发布相关变更**（版本号、appcast、workflow、发布脚本、AGENTS.md 等）由 agent 直接用 gh/git commit 并 push 到 origin/main；日常功能代码仍由用户在 GitHub Desktop 自行提交，agent 不主动提交业务代码，除非用户明确要求

---

## Bug 修复工作流（必须严格遵守）

> 用户描述 bug 后，**禁止立即修改代码**。必须按以下流程执行：

1. **查阅代码**：用户描述 bug 后，agent 只负责查阅代码、定位 bug 原因，**不修改任何代码**
2. **给出方案**：向用户说明 bug 原因和修改方案，等待用户确认
3. **用户确认**：用户明确说"改"或"可以"后，才能修改代码
4. **编译验证**：修改后必须编译通过
5. **用户测试**：用户安装测试
6. **结果处理**：
   - bug 消失 → 总结经验，记录到 AGENTS.md（如适用）
   - bug 仍存在 → 重新查阅代码，给出新方案，等待用户确认后再改

**绝对禁止**：用户描述 bug 后立即修改代码，或在用户未确认的情况下反复尝试不同方案。

---

## 调试经验（踩坑记录）

### UserDefaults 缓存问题（2026-09-09）

> **现象**：用 PlistBuddy 删除 plist 文件中的 `SUSkippedVersion` 键后，app 重启后仍然读取到旧值，导致跳过版本状态无法清除。

> **原因**：macOS 的 UserDefaults 由 `cfprefsd` 守护进程管理，有内存缓存。直接修改 plist 文件不会通知 cfprefsd 刷新缓存，app 读取到的还是旧值。

> **正确做法**：
> - 用 `defaults delete <bundle-id> <key>` 命令删除（会通知 cfprefsd）
> - 或者修改后执行 `killall cfprefsd` 刷新缓存
> - 不要只用 PlistBuddy 直接修改 plist 文件

> **适用场景**：测试 Sparkle 跳过版本、清除 UserDefaults 配置等所有涉及 UserDefaults 直接修改的场景。

### 拼音排序 ICU 转换卡顿（2026-09-24）

> **现象**：200 客户列表每次切换视图 body 求值 530ms（实测 `body first eval`），服务项目/库存（几十条）丝滑。
> **原因**：`pinyinLess` 排序每次比较调 2 次 `pinyinSortKey` → ICU `applyingTransform(.toLatin)` 昂贵（~0.5ms/次），200 条排序 ≈ 3200 次转换 ≈ 500ms。
> **解决**：`pinyinSortKey` 加全局内存缓存（名字不变零转换），首帧 105ms → 之后 44ms（10 倍提速）。
> **经验**：任何"数据量大就慢、数据量小就快"的列表，先查比较器里有没有每次比较都执行的昂贵计算（拼音转换/日期格式化等），优先缓存中间结果；用日志插桩（`body first eval` 计时）定位而非猜测。

### ⚠️ Debug/Release 数据库文件隔离（2026-09-20）

> **坑**：Debug 和 Release 在同一个 `/Users/kuck/Library/Application Support/xzmj/` 目录下，但数据库文件名不同：
> - Debug：`debug.default.store`
> - Release：`default.store`
>
> **错误做法**：`rm -rf /Users/kuck/Library/Application Support/xzmj/` —— 会把正式版数据库一起删掉！
>
> **正确做法**：只删 Debug 相关文件：`rm -f /Users/kuck/Library/Application Support/xzmj/debug.default.store*`
>
> 同理，清理测试数据时只删 Debug 的 store 文件，不碰 `default.store`。

### 状态回退必须清所有关联字段（2026-09-26）

> **现象**：删除服务记录后，预约状态从"已到店"回退为"已预约"，但编辑按钮仍不显示。
> **原因**：编辑按钮的显示判断是 `appt.arrivedAt == nil`，而回退时只改了 `appt.status = "已预约"`，没清空 `appt.arrivedAt`，导致状态显示正确但 UI 行为不对。
> **解决**：状态回退时，必须把所有关联字段一起恢复：
> ```swift
> appt.status = "已预约"
> appt.arrivedAt = nil  // 不能漏
> ```
> **经验**：任何"状态回退"操作，要检查该状态下所有非默认字段是否都需要清空，不能只改 status 字段。UI 判断条件用的哪个字段，就必须恢复哪个字段。

### 列表翻页/搜索后需手动回顶（2026-09-26）

> **现象**：列表分页翻页或搜索过滤后，内容显示错位（后几项跑到顶部），需要手动滚动才恢复。
> **原因**：SwiftUI List 在数据源变化时不会自动重置滚动位置，残留的滚动偏移导致新内容从中间开始显示。
> **解决**：用 `ScrollViewReader` 包裹 List，在 `currentPage` 或 `searchText` 变化时 `scrollTo` 第一行顶部：
> ```swift
> ScrollViewReader { proxy in
>     List { ForEach(items) { $0.id($0.id) } }
>     .onChange(of: currentPage) { _, _ in
>         if let first = items.first { proxy.scrollTo(first.id, anchor: .top) }
>     }
> }
> ```
> **经验**：所有分页列表（客户/收银/补睫）和搜索列表（客户选择器）都要加这个处理，不能依赖 List 的默认行为（不可靠）。

### 编辑已有模型必须显式 save（2026-09-26）

> **现象**：编辑客户/技师/服务记录/库存后，App 重启修改丢失。
> **原因**：AppCore 的 `insert()`/`delete()` 内置 `context.save()`，但直接修改已有模型属性（如 `customer.name = "新名"`）不会自动 save，修改停留在内存。
> **解决**：所有编辑表单的 onSave closure 必须显式调 `appCore.save()`：
> ```swift
> CustomerFormView(customer: c) { _ in appCore.save() }  // ✅
> CustomerFormView(customer: c) { _ in }  // ❌ 修改丢失
> ```
> **经验**：写操作分两类——① insert/delete（内置 save，不用手动调）；② 直接改属性（必须显式 save）。写代码时先判断是哪类。

### 电话搜索匹配规则（2026-09-26）

> **规则**：
> - 电话号码强制 11 位纯数字（可选，不填也能保存）
> - 搜索：输入 2 位及以上纯数字时，匹配电话任意位置的连续数字
> - 1 位数字不匹配电话（太宽泛），走姓名/拼音匹配
> - 非纯数字输入不走电话匹配
> **经验**：先在数据入口做格式校验，搜索逻辑就可以简化（不用处理各种分隔符）。


## 常见问题速查（FAQ）

### 编译/运行

| 问题 | 原因 | 解决 |
|---|---|---|
| `Address already in use (errno: 48)` | 正式版和 Debug 同时运行，API 端口冲突 | 关掉正式版再跑 Debug |
| `send failed: Invalid argument` | 端口被占用的连锁报错 | 同上，关正式版 |
| 部署目标警告 15.7 | Xcode 版本支持的最高 macOS SDK 低于 15.7 | project.pbxproj 里已改为 15.5，不用管 |
| 编译报 `SWIFT_DEFAULT_ACTOR_ISOLATION` 相关并发错误 | 非隔离上下文调用 @MainActor 方法 | 给方法加 `nonisolated`，前提是方法内不碰 UI/数据库 |

### 控制台噪音日志（无害，不用管）

| 日志 | 说明 |
|---|---|
| `CoreData: fault: Could not materialize Objective-C class named "Array"` | SwiftData 对 `[String]`/`[UUID]` 原生数组类型的已知日志噪音，功能正常 |
| `ViewBridge to RemoteViewService Terminated: Code=18` | macOS 系统级通知，benign |
| `os_unix.c:49455: open(/private/var/db/DetachedSignatures)` | macOS 签名检查噪音 |
| `PostSaveMaintenance: incremental_vacuum` | SQLite 自动维护，正常 |
| `NSSecureCoding allowed classes list contains NSObject` | Sparkle 框架的安全警告，不影响功能 |

### 数据相关

| 问题 | 解决 |
|---|---|
| Debug 和 Release 数据不一样 | 正常，bundle ID 不同数据隔离（Debug: `com.kuck.nail.Debug`，Release: `com.kuck.nail.--------`） |
| 备份后数据路径 | `/Users/kuck/Library/Application Support/xzmj/`（非沙箱模式） |
| UserDefaults 改了不生效 | 用 `defaults delete <bundle-id> <key>` 或 `killall cfprefsd`，不要直接改 plist 文件 |
| **重置 Debug 测试数据** | 两步缺一不可：① `rm -f /Users/kuck/Library/Application\ Support/xzmj/debug.default.store*` 删数据库；② `defaults delete com.kuck.nail.Debug didSeedTestData_v4` 清 seed flag。**绝不能删整个 xzmj 目录**，否则正式版 `default.store` 也会丢 |
| TestDataSeeder 版本 | 每次改测试数据生成逻辑必须 bump `flagKey`（当前 v4），否则已生成过数据的 Debug 不会重新生成 |

### 更新相关

| 问题 | 解决 |
|---|---|
| 检查更新提示"已是最新版" | appcast 未 push 到 GitHub，等 1-2 分钟再试 |
| Gitee 源下载慢 | 确认 appcast-gitee.xml 的 enclosure URL 指向 gitee.com 而非 github.com |
| 更新后 Sparkle 安装失败 | 确认 Sparkle.framework 的 Installer.xpc 签名是 Apple Development 而非 adhoc |

---
## 版本控制与发布

- **发布相关变更**（版本号、appcast、workflow、发布脚本、AGENTS.md 等）由 agent 直接用 `gh`/`git` commit 并 push 到 `origin/main`，无需用户手动操作
- **日常功能代码**：由用户在 GitHub Desktop 自行 commit/push；agent 不主动提交业务代码，除非用户明确要求
- **commit 后自动 push**：用户明确要求 commit 后，agent 完成 commit 应直接 push 到 origin/main，不必再询问（2026-09-24 用户确认）
- **Gitee 同步（重要限制）**：代码与 tag 由 `.github/workflows/sync-to-gitee.yml` 在 push main 时自动同步；Release 元数据（壳）由 `.github/workflows/sync-release-to-gitee.yml` 在 release published 时自动创建。**但安装包 zip 无法由 GitHub Actions 自动上传**——海外 runner 往国内 Gitee 传大文件会跨境卡死（2026-09-20 实测：1KB 小文件成功、11MB 跑满 240s 超时零进展，而同机下载 GitHub 21MB/s；国内本机直连 Gitee 建连仅 0.25s）。**zip 由 agent 在本机用 `scripts/upload-gitee.sh` 上传**（令牌存 `~/.config/gitee-token`，见发布 SOP Step 8）；脚本不可用时退化为网页手动上传。
- commit message 简洁描述（如 `1.7.4 发布`），直接提交到 main 分支

---

## 备份格式说明

- **明文备份**：JSON 文件，密码仅用于操作者身份验证
- **加密备份**：AES-256 加密，密钥 = SHA256(密码哈希 + 固定盐)，支持旧密码解密旧备份
- 加密盐值硬编码在 `SecurityManager.autoBackupSalt`

---

## 修改前 Checklist（自问自答）

- [ ] 新增 @Model 字段是否带默认值？
- [ ] 新增 @Model 字段是否避免使用 `id` 作为属性名？（会和 SwiftData 自动生成的 id 冲突，导致清库）
- [ ] 是否删除/重命名/改类型了 @Model 字段？（禁止，会触发复杂迁移）
- [ ] 新增 @Model 类是否已加入 `杏子美甲管理系统App.swift` 的 Schema 列表？（不加入会导致 Core Data 找不到实体）
- [ ] 改动是否影响备份导出/导入？加密备份密钥派生逻辑有没有被改？
- [ ] 旧版升级到新版是否安全？（加字段带默认值就安全）
- [ ] @Model 改动后是否手动验证了迁移？（旧版数据 → 覆盖安装新版 → 数据完整）
- [ ] onAppear/onChange 里写 SwiftData 有没有用 DispatchQueue.main.async 延迟？
- [ ] sheet 是不是挂在 body 根级别？有没有嵌套在 NavigationStack 里？
- [ ] 新增 UserDefaults key 有没有用前缀命名避免冲突？
- [ ] 是否需要清理 TestDataSeeder 的测试数据逻辑？（DEBUG only，一般不需要动）

---

## 📤 发布流程（完整 SOP，2026-09-20 改为全自动）

> 本流程覆盖：版本号 → archive 构建 → zip 打包 → Sparkle 签名 → 双 appcast 更新 → **commit/push** → GitHub Release（打 tag + 传 zip）→ Actions 自动同步 Gitee 代码/Release 元数据 → **本机脚本上传 Gitee zip**（Step 8）。
>
> **顺序铁律**：必须先 `git push` 把版本号和 appcast 推到远程，**再** `gh release create` 打 tag。这样 release tag 才精确指向含新版本号的 commit（历史上先打 tag 后 push，导致 tag 指向旧版本号 commit）。
>
> 发布相关变更（版本号、appcast、workflow、发布脚本、AGENTS.md）由 agent 用 gh/git 直接 push。GitHub Actions 自动同步代码、tag 和 Gitee Release 元数据。**Gitee 安装包 zip 不能在海外 runner 传，由 agent 在本机用 `scripts/upload-gitee.sh` 上传**（国内直连，详见 Step 8）。每次发版严格按此执行，不得跳步。

### 版本号规则（语义化展示版本 + 永不重置的构建号）

> **铁律：构建号 `CURRENT_PROJECT_VERSION`（= `CFBundleVersion` = appcast 的 `sparkle:version`）永远单调 +1，跨任何大版本都不重置为 1。**
> 原因：① macOS 与 iOS 不同——Apple TN2420 明确 macOS app 的构建号必须**跨版本**单调递增，不能在不同 release train 重用（iOS 才允许每个版本从 1 开始）；② Sparkle 用 `CFBundleVersion`（不是 marketing 版本号）比较判断是否有更新（见 `SUAppcastItem.versionString`），一旦构建号回退（如 36→1），已装用户会因 1 < 36 而**收不到更新**。项目历史构建号 32→33→34→35→36→37 连续递增即为佐证。

| 改动类型 | MARKETING_VERSION（展示版本，语义化） | CURRENT_PROJECT_VERSION（构建号） | 示例 |
|---|---|---|---|
| 修复 bug / 内部优化 / 小 UI 调整 | PATCH +1 | 永远 +1 | 1.7.1-33 → 1.7.2-34 |
| 新功能 / 功能增强 | MINOR +1 | 永远 +1（**不回到 1**） | 1.7.4-36 → 1.8.0-37 |
| 架构大改 / 破坏性变更 | MAJOR +1 | 永远 +1（**不回到 1**） | 1.7.4-36 → 2.0.0-38 |

### 关键文件与地址

| 项目 | 值 |
|---|---|
| GitHub 仓库 | `Kuck007/xzmj` |
| Gitee 仓库 | `kuck007/xzmj`（代码、tag、Release 元数据由 Actions 自动同步；**安装包 zip 由本机 `scripts/upload-gitee.sh` 上传**） |
| 代码同步 workflow | `.github/workflows/sync-to-gitee.yml`（push main 时同步代码与 tag） |
| Release 同步 workflow | `.github/workflows/sync-release-to-gitee.yml`（release published 时只建 Gitee release 元数据，**不含 zip 附件**） |
| Gitee API Token（CI） | GitHub Secrets 的 `GITEE_XZMJ_TOKEN`（两个 workflow 共用，只写不可读） |
| Gitee API Token（本机） | `~/.config/gitee-token`（chmod 600，`projects` 权限，供 `scripts/upload-gitee.sh` 读取；**不进仓库**） |
| Gitee 上传脚本 | `scripts/upload-gitee.sh`（用法：`./scripts/upload-gitee.sh {tag} {zip} [--force]`，必须在国内本机跑） |
| 版本号文件 | `杏子美甲管理系统.xcodeproj/project.pbxproj`（`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`，各 2 处） |
| Sparkle 公钥 | `Info.plist` 中 `SUPublicEDKey` |
| Sparkle 私钥 | `sparkle_ed25519_private.pem`（PKCS#8 格式，**已在 .gitignore 中，禁止提交**） |
| GitHub 源 appcast | `appcast.xml`，feedURL `https://raw.githubusercontent.com/Kuck007/xzmj/main/appcast.xml` |
| Gitee 源 appcast | `appcast-gitee.xml`，feedURL `https://gitee.com/kuck007/xzmj/raw/main/appcast-gitee.xml` |
| 更新源切换代码 | `杏子美甲管理系统App.swift` 第 36-40 行 `feedURLString(for:)` |
| 本地 zip 输出 | `build/xzmj-mac-arm-{version}.zip` |
| archive 输出 | `build/Archive/杏子美甲管理系统.xcarchive` |

### 发布步骤（Agent 执行）

#### Step 1：修改版本号

编辑 `project.pbxproj`，将 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 各 2 处全部更新。

```bash
# 验证修改结果
grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION" 杏子美甲管理系统.xcodeproj/project.pbxproj
```

#### Step 2：Release archive 构建

```bash
xcodebuild archive \
  -project "杏子美甲管理系统.xcodeproj" \
  -scheme "杏子美甲管理系统" \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "build/Archive/杏子美甲管理系统.xcarchive"
```

构建完成后验证：
```bash
# 确认版本号
plutil -extract CFBundleShortVersionString raw \
  "build/Archive/杏子美甲管理系统.xcarchive/Products/Applications/杏子美甲管理系统.app/Contents/Info.plist"
plutil -extract CFBundleVersion raw \
  "build/Archive/杏子美甲管理系统.xcarchive/Products/Applications/杏子美甲管理系统.app/Contents/Info.plist"

# 确认架构（2026-09-19 起 arm64 only，应输出 arm64）
lipo -archs "build/Archive/杏子美甲管理系统.xcarchive/Products/Applications/杏子美甲管理系统.app/Contents/MacOS/杏子美甲管理系统"
```

#### Step 3：打包 zip（根目录仅含 .app）

```bash
# 用绝对路径输出到 build/。坑：cd 进 Applications 后，../../../ 只上溯到 build/Archive/（少一层），
# 要到 build/ 需 ../../../../；直接用绝对路径最稳妥
cd "build/Archive/杏子美甲管理系统.xcarchive/Products/Applications"
zip -r -y "/Users/kuck/Documents/杏子美甲管理系统/build/xzmj-mac-arm-{version}.zip" "杏子美甲管理系统.app"
cd -

# 验证 zip 结构（第一行必须是 杏子美甲管理系统.app/）
unzip -l "build/xzmj-mac-arm-{version}.zip" | head -5

# 记录文件大小（appcast 需要）
stat -f%z "build/xzmj-mac-arm-{version}.zip"
```

#### Step 4：Sparkle Ed25519 签名

> **⚠️ 系统 LibreSSL 不支持 Ed25519**（macOS 自带 openssl 是 LibreSSL 3.x）。
> `sign_update.sh` 脚本调用系统 openssl 会失败。必须用以下替代方案之一：

**方案 A：Swift CryptoKit 临时脚本（推荐，无需安装依赖）**

写一个临时 Swift 脚本，用 CryptoKit 的 `Curve25519.Signing.PrivateKey` 签名：
- 读取 `sparkle_ed25519_private.pem`（PKCS#8 格式），取 base64 解码后末 32 字节为 raw private key
- 读取 zip 文件二进制内容
- 用 `privateKey.signature(for: data)` 生成签名
- 输出 base64 编码的签名

```swift
import Foundation
import CryptoKit

// 用绝对路径 + URL 读取（macOS 15 SDK 下 Data(contentsOfFile:) / String(contentsOfFile:)
// 已弃用且会报 "no exact matches in call to initializer"，必须用 URL 版本）
let pemURL = URL(fileURLWithPath: "/Users/kuck/Documents/杏子美甲管理系统/sparkle_ed25519_private.pem")
let zipURL = URL(fileURLWithPath: "/Users/kuck/Documents/杏子美甲管理系统/build/xzmj-mac-arm-{version}.zip")

let pem = try String(contentsOf: pemURL, encoding: .utf8)
let base64 = pem.split(separator: "\n").dropFirst().dropLast().joined()
guard let der = Data(base64Encoded: base64) else { fatalError("私钥 base64 解码失败") }
let rawKey = Data(der.suffix(32))
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
let zipData = try Data(contentsOf: zipURL)
let sig = try privateKey.signature(for: zipData)
print(sig.base64EncodedString())
```

```bash
swift /tmp/sign_ed25519.swift  # 输出签名 base64，记录下来
rm /tmp/sign_ed25519.swift
```

**方案 B：安装 Homebrew openssl@3**

```bash
brew install openssl@3
/opt/homebrew/opt/openssl@3/bin/openssl pkeyutl -sign \
  -inkey sparkle_ed25519_private.pem \
  -rawin -in build/xzmj-mac-arm-{version}.zip | base64
```

签名结果格式示例：`2MXEu/Dt2c7OQrv/oeTgAVMXSsxPNHCEvpm23FNzGdLT1OerCnV3+n8PiUKNwG3SXrt0se/Cr81Un2xlAoIUAw==`

#### Step 5：更新双 appcast

**两个文件都要更新**，在 `<language>` 之后、第一个 `<item>` 之前插入新版本条目。

**appcast.xml（GitHub 源）**——下载 URL 指向 GitHub：
```xml
<item>
  <title>{version}</title>
  <description><![CDATA[
    <h2>{version} 更新内容</h2>
    <h3>修复</h3>
    <ul><li>...</li></ul>
  ]]></description>
  <pubDate>{发布日期 RFC822 格式，date +"%a, %d %b %Y %H:%M:%S %z"}</pubDate>
  <enclosure url="https://github.com/Kuck007/xzmj/releases/download/{version}-{build}/xzmj-mac-arm-{version}.zip"
             sparkle:version="{build}"
             sparkle:shortVersionString="{version}"
             length="{zip文件大小字节数}"
             type="application/octet-stream"
             sparkle:edSignature="{Step4的签名base64}" />
</item>
```

**appcast-gitee.xml（Gitee 源）**——下载 URL **必须指向 Gitee**，不能指向 GitHub：
```xml
<enclosure url="https://gitee.com/kuck007/xzmj/releases/download/{version}-{build}/xzmj-mac-arm-{version}.zip"
           ...其余字段与 appcast.xml 相同（含同一个 edSignature）... />
```

> **铁律**：appcast-gitee.xml 里所有版本的 enclosure URL 都必须是 `gitee.com` 地址。
> 改完用 `xmllint --noout appcast.xml appcast-gitee.xml` 校验 XML 合法性。

#### Step 6：commit 并 push（必须在打 tag 之前）

把版本号、双 appcast（以及本次顺带改的 workflow / AGENTS.md）一次性提交并推送到 origin/main：

```bash
git add "杏子美甲管理系统.xcodeproj/project.pbxproj" appcast.xml appcast-gitee.xml
# 如有 workflow / AGENTS.md 等发布相关改动也一并 add
git commit -m "{version} 发布"
git push origin main
```

> 这一步 push 后，sync-to-gitee.yml 会自动把代码同步到 Gitee；同时保证下一步打的 tag 指向含新版本号的 commit。

#### Step 7：创建 GitHub Release 并上传 zip（打 tag）

> **⚠️ 不要在 `gh release create` 时同时传附件**——大文件上传容易卡住生成 draft。
> 分两步：先创建空 release（这一步在远程 HEAD 上打 tag，因 Step 6 已 push，tag 精确），再单独上传附件。

```bash
# 第一步：创建 release（不带附件，推荐用 --notes-file 传多行中文说明）
gh release create "{version}-{build}" \
  --repo Kuck007/xzmj \
  --title "{version}" \
  --notes-file /tmp/release_notes.md

# 第二步：单独上传 zip
gh release upload "{version}-{build}" \
  --repo Kuck007/xzmj \
  "build/xzmj-mac-arm-{version}.zip"

# 验证 release 状态（必须 isDraft=false, isPrerelease=false, asset state=uploaded）
gh release view "{version}-{build}" --repo Kuck007/xzmj --json isDraft,isPrerelease,tagName,assets
```

GitHub 下载 URL 格式：`https://github.com/Kuck007/xzmj/releases/download/{version}-{build}/xzmj-mac-arm-{version}.zip`

> release 一旦 `published`，sync-release-to-gitee.yml 自动触发：在 Gitee 建同名 release（在 main 上建 tag）。**注意：只建 release 元数据，不含 zip**（zip 由 Step 8 本机脚本上传）。

#### Step 8：验证 GitHub + 本地脚本上传 Gitee zip

GitHub Actions 会自动建 Gitee Release 元数据（壳），但**不会、也无法在海外 runner 上传 zip**。zip 必须在**国内本机**用脚本上传（Actions 同步元数据约需 1-2 分钟，先确认壳已建好再传）。

> **为什么不能在海外 runner 传**：GitHub Actions 官方 runner 全在海外，往国内 Gitee 传大文件会被跨境链路掐死。2026-09-20 实测：同一 runner 上 1KB 小文件上传成功（HTTP 201）、从 GitHub 下载 11MB 仅 0.52s（21MB/s），但 11MB 上传 Gitee 跑满 240s 零进展（curl exit 28 超时）；加 `-H "Expect:"`、改 HTTP/1.1 均无效。而国内本机直连 Gitee 建连仅 0.25s。**不要再尝试在海外 runner 上传 Gitee 附件。**

**首次配置（仅一次）**：在 https://gitee.com/profile/personal_access_tokens 生成勾 `projects` 权限的私人令牌，存到本机（不进仓库、不回显）：

```bash
printf '%s' '你的令牌' > ~/.config/gitee-token && chmod 600 ~/.config/gitee-token
```

> 这个本地令牌与 GitHub Secrets 的 `GITEE_XZMJ_TOKEN` 是两个独立令牌：Secrets 里的只能写不能读，供 CI 用；本地这个供本机脚本用，互不影响、可独立吊销。

**上传（在本机国内网络执行，一条命令）**：

```bash
# 幂等：同名附件已存在会自动跳过；需要覆盖时末尾加 --force（先删后传）
./scripts/upload-gitee.sh {version}-{build} "build/xzmj-mac-arm-{version}.zip"
```

脚本内部：按 tag 查 release id → 查同名附件（幂等）→ `curl --noproxy '*'` 直连 Gitee multipart 上传，成功输出 `browser_download_url`。Gitee 官方 CLI（`@gitee/gitee-cli`）截至 v0.3.1 不支持传附件，故用此零依赖脚本（macOS 自带 curl + python3）。

**验证**：

```bash
# 1. GitHub 附件可下载（最终 HTTP 200）
curl -sIL -o /dev/null -w "%{http_code}\n" \
  "https://github.com/Kuck007/xzmj/releases/download/{version}-{build}/xzmj-mac-arm-{version}.zip"

# 2. 下载 Gitee 附件，与本地 zip 比对 SHA256（两行必须完全一致）
curl --noproxy '*' -sL "https://gitee.com/kuck007/xzmj/releases/download/{version}-{build}/xzmj-mac-arm-{version}.zip" -o /tmp/gitee.zip
shasum -a 256 /tmp/gitee.zip "build/xzmj-mac-arm-{version}.zip"
```

> **备用方案**：脚本不可用时，仍可在 https://gitee.com/kuck007/xzmj/releases 网页手动编辑对应 release 拖放 zip。真实附件 URL 含 `/releases/download/`；另外两个 `.zip/.tar.gz` 是 Gitee 自动生成的源码包，可忽略。
>
> appcast raw 内容约 1-2 分钟刷新，客户端随后检测到新版本。

### Agent 可以帮做的 vs 不能做的

| 可以做 | 不能做 |
|---|---|
| 修改版本号、archive 构建、zip 打包、Sparkle 签名 | 修改用户未授权的代码范围 |
| 更新 appcast.xml 和 appcast-gitee.xml | 提交与本次发布无关的业务代码（除非用户明确要求） |
| 用 gh/git commit + push **发布相关**变更，创建 GitHub Release、上传 zip，在本机用 `scripts/upload-gitee.sh` 上传 Gitee zip | 把 Sparkle 私钥、Gitee token 写进仓库（私钥在 .gitignore；CI token 只存 GitHub Secrets，本机 token 只存 `~/.config/gitee-token`） |
| Gitee 代码/tag/Release 元数据由 Actions 自动同步 | **在海外 runner 自动上传 Gitee zip**（跨境大文件必卡死，已实测）；Gitee zip 只能在国内本机用脚本上传 |

### 产物规则（强制）

- **压缩包命名**：`xzmj-mac-arm-{version}.zip`
- **zip 内部结构**：根目录直接是 `杏子美甲管理系统.app`，禁止嵌套目录
- **Release tag**：`{version}-{build}`（如 `1.7.2-34`）
- **appcast pubDate 格式**：RFC822，如 `Fri, 18 Sep 2026 00:41:00 +0800`
