# AGENTS.md — 杏子美甲管理系统

> 本文件是所有 AI Agent（Trae / Codex / Cursor / Claude Code / ...）在本项目上工作前必须阅读的开发规范。
> 目标：让任何一个新 agent 拿到仓库就能立即按正确的方式开发，不踩历史上踩过的坑。

---

## 项目概述

macOS 原生应用（SwiftUI + SwiftData），美甲店铺管理系统。功能涵盖：Dashboard 概览、客户管理、技师管理、服务项目、预约/服务记录/订单结账、会员充值、库存、技师排班/薪资、收入统计、美睫提醒、用户权限（超管/管理员/技师）、自动备份/手动备份/加密备份、安全密码与找回。

- **项目路径**：`/Users/lgx/Documents/杏子美甲管理系统`
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

### 2. 旧版 → 新版升级不崩

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

---

## 权限模型

| 角色 | 可见模块 |
|---|---|
| superAdmin（超管） | 全部模块 + 用户管理 + 自动备份设置 + 应用名称设置 |
| admin（管理员） | 除用户管理外的全部 + 自动备份设置 |
| staff（技师） | 仅 Dashboard + 与自身相关的模块 |

- `SessionManager` 必须在 App 入口注入：`.environment(SessionManager.shared)`
- 模块权限列表从 `SidebarItem.allCases` 动态生成，新增模块自动出现在权限设置里

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
- 版本控制：用户用 GitHub Desktop 手动 commit 和 push，agent **不要替用户执行 git commit**

---

## 版本控制工作流（用户操作）

1. 用户在 GitHub Desktop 选中改动文件
2. 写 commit summary（简洁描述）
3. 提交到 main 分支
4. push 到 origin

Agent 不执行上述任何步骤。

---

## 备份格式说明

- **明文备份**：JSON 文件，密码仅用于操作者身份验证
- **加密备份**：AES-256 加密，密钥 = SHA256(密码哈希 + 固定盐)，支持旧密码解密旧备份
- 加密盐值硬编码在 `SecurityManager.autoBackupSalt`

---

## 修改前 Checklist（自问自答）

- [ ] 新增 @Model 字段是否带默认值？
- [ ] 改动是否影响备份导出/导入？加密备份密钥派生逻辑有没有被改？
- [ ] 旧版升级到新版是否安全？（加字段带默认值就安全）
- [ ] onAppear/onChange 里写 SwiftData 有没有用 DispatchQueue.main.async 延迟？
- [ ] sheet 是不是挂在 body 根级别？有没有嵌套在 NavigationStack 里？
- [ ] 新增 UserDefaults key 有没有用前缀命名避免冲突？
- [ ] 是否需要清理 TestDataSeeder 的测试数据逻辑？（DEBUG only，一般不需要动）
