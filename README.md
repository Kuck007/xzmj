# 杏子美甲管理系统

一个面向美甲 / 美睫工作室的 macOS 原生经营管理软件，从预约、服务记录、收银结账到会员充值、库存、技师工资与多机同步，覆盖门店日常经营的主要流程。

项目由我（非程序员）通过对话式 AI 开发，并在自己的工作室实际使用、持续迭代。所有功能都经过真实业务场景验证，发现问题就修，缺什么就补。

## 下载与更新

- **最新版本（GitHub）**：[github.com/Kuck007/xzmj/releases/latest](https://github.com/Kuck007/xzmj/releases/latest)
- **所有历史版本**：[GitHub Releases](https://github.com/Kuck007/xzmj/releases)
- **国内加速下载（Gitee 镜像）**：[Gitee Releases](https://gitee.com/kuck007/xzmj/releases)

当前版本：**2.4.1**

> 仅支持 Apple Silicon（arm64）Mac。已安装的用户会在 App 内收到自动更新提示，也可以手动到 Release 页面下载 `xzmj-mac-arm-*.zip`。

## 系统要求

| 项目 | 要求 |
|---|---|
| 系统版本 | macOS 15.5 及以上 |
| 处理器 | Apple Silicon（M 系列），不支持 Intel |
| 安装方式 | 下载 zip → 解压 → 拖入「应用程序」 |

首次打开如果系统提示「无法验证开发者」，在应用图标上右键 →「打开」即可。

## 功能概览

### 门店经营
- **仪表盘**：今日营业额、到店/预约、客户与库存概览
- **客户管理**：会员等级（普通 / 银卡 / 金卡）、标签、生日、消费记录、充值记录
- **技师管理**：技师档案、底薪、提成比例、在职状态
- **服务项目**：树形分类（如 美甲 / 美睫 → 手部 / 足部 → 具体项目）、价格与时长
- **预约排班**：按日查看技师排班，预约确认到店后自动生成服务记录
- **服务记录**：记录服务内容、技师、金额与照片（支持 iPhone 连续互通相机拍照/扫描）
- **收银结账**：服务项目结算、会员余额抵扣、生成订单并闭环预约状态
- **会员充值**：充值送金额、会员等级自动升级
- **库存管理**：耗材库存与数量维护
- **补睫提醒**：按订单自动生成补睫提醒，到期集中查看
- **收入统计**：按时间范围统计营业额、项目与技师表现
- **技师工资**：底薪 + 提成核算，按区间汇总
- **对账确认**：技师日结对账，锁定当天数据

### 账号与权限
- 三种角色：**超管 / 管理员 / 技师**
- 超管可管理账号、权限、同步与备份设置
- 管理员可使用除用户管理外的全部模块
- 技师只看到仪表盘和与自身相关的模块

### 数据安全
- 本地使用 SwiftData 持久化，数据保存在 `~/Library/Application Support/xzmj/`
- 支持**手动备份 / 自动备份（默认 15 天提醒）/ 加密备份**
- 支持 **WebDAV 网络备份**，可直接备份到 NAS 或网盘
- 系统密码 + 安全问题找回，敏感操作需要密码验证

### 多机增量同步（2.4 起）
- 多台 Mac 共用一套数据：本机改动后自动加密上传，另一台打开即可合并
- 只传变化记录，不传整库；删除通过墓碑同步，不会被旧数据「复活」
- 每店独立随机密钥，AES-GCM 端到端加密，云端文件名不含业务信息
- 启动后自动检查云端更新：
  - 超管 / 管理员：弹窗提醒，可直接打开快速合并面板，输入系统密码完成合并
  - 技师：提示使用管理员账号登录后合并
- 合并前自动生成一份加密全量备份，失败不改任何业务数据
- 完整协议与实现细节见 [docs/增量同步方案.md](docs/增量同步方案.md)

## 技术栈

| 层 | 选型 |
|---|---|
| 界面 | SwiftUI（NavigationSplitView） |
| 持久化 | SwiftData |
| 加密 | CryptoKit（SHA256 / AES-GCM / Ed25519） |
| 网络 | WebDAV（URLSession）、Vapor（内置 HTTP API） |
| 自动更新 | Sparkle 2 |
| 最低系统 | macOS 15.5，arm64 only |

## 从源码构建

需要 Xcode（macOS 15 SDK 及以上）：

```bash
git clone https://github.com/Kuck007/xzmj.git
cd xzmj
xcodebuild build -project "杏子美甲管理系统.xcodeproj" -scheme "杏子美甲管理系统" -destination 'platform=macOS'
```

Debug 与 Release 使用不同的 Bundle ID，数据互相隔离，可以同时安装。

## 项目结构

```
杏子美甲管理系统/
├── 杏子美甲管理系统App.swift   // App 入口、Sparkle、窗口行为
├── RootView.swift              // 登录态路由
├── ContentView.swift           // 侧边栏主框架
├── DesignSystem.swift          // 品牌色与通用组件
├── Models/                     // SwiftData 数据模型
├── Security/                   // 登录、密码、备份、WebDAV
├── Sync/                       // 增量同步内核（协议、加密、上传、合并）
└── Views/                      // 各功能模块界面
```

开发约定、踩坑记录与发布流程都写在 [AGENTS.md](AGENTS.md) 里。

## 展望

1. **Windows 版**：业务代码足够成熟后可以尝试，主要难点在界面与本地数据库。
2. **Web 版**：部署在云服务器，便于对接微信小程序；目前还没有云服务器，暂时用不到。
3. **数据库换成 MySQL**：数据安全更有保障，但需要一定运维能力。
4. **iOS / iPadOS / Android**：没有开发者账号，上架困难；安卓侧装相对容易，以后可能先做安卓。

## 反馈

- 问题与建议：[GitHub Issues](https://github.com/Kuck007/xzmj/issues)
- 这个项目是我多年前的一个梦想：当时在应用商店看到一个国外开发者做的 Nail Salon 应用，收费，但给了我启发。AI 时代让我把它做出来了，我会继续维护下去。

## 许可证

GNU General Public License v3.0，详见 [LICENSE](LICENSE)。
