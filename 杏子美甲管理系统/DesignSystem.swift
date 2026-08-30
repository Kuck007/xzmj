//
//  DesignSystem.swift
//  杏子美甲管理系统
//
//  品牌主题统一入口：全局主色 + 圆角令牌 + 卡片表面样式。
//  通过把 `Color.brand` 注入到根视图的 `.tint()`，让侧边栏、按钮、
//  开关、分段选择器、表单、弹窗、日历、图表等所有原生控件自动统一为品牌色。
//

import SwiftUI
import AppKit

// MARK: - 品牌调色板
// 赛博朋克风格：近黑深蓝底 + 霓虹青主色 + 霓虹品红点缀 + 发光描边。
//   霓虹青（brand）用于发光、图标、霓虹文字、描边、图表；
//   电蓝青（brandDeep）用于需要白字可读的选中/填充态（作为全局 tint）；
//   霓虹品红（brandAccent）作次要强调，与青色构成招牌渐变。

extension Color {
    /// 根据浅色/深色外观返回自适应颜色。
    /// SwiftUI 的 `Color(light:dark:)` 在本 SDK 不可用，改用 AppKit 的
    /// `NSColor(name:dynamicProvider:)`（macOS 10.15+）可靠地跟随配色方案切换。
    private static func adaptive(light: (Double, Double, Double),
                                 dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: dark.0, green: dark.1, blue: dark.2, alpha: 1)
                : NSColor(srgbRed: light.0, green: light.1, blue: light.2, alpha: 1)
        }))
    }

    /// 品牌主强调：亮色→荧光粉 / 深色→霓虹青（发光、图标、霓虹文字、描边、图表）
    static let brand = Color.adaptive(light: (1.00, 0.16, 0.52),
                                      dark: (0.00, 0.92, 1.00))
    /// 品牌深色（白字可读的选中/填充态，作全局 tint）：亮色→深霓虹粉 / 深色→电蓝青
    static let brandDeep = Color.adaptive(light: (0.95, 0.05, 0.55),
                                          dark: (0.00, 0.55, 0.78))
    /// 品牌次要强调：霓虹品红（亮色更深、深色更艳）
    static let brandAccent = Color.adaptive(light: (0.98, 0.10, 0.52),
                                            dark: (1.00, 0.18, 0.53))
    /// 品牌浅色（柔和霓虹底色）：随主题取主强调
    static let brandSoft = Color.adaptive(light: (1.00, 0.16, 0.52),
                                          dark: (0.00, 0.92, 1.00))
    /// 页面背景：亮色→近白 / 深色→近黑深蓝灰
    static let brandBackground = Color.adaptive(light: (0.99, 0.985, 1.00),
                                                dark: (0.055, 0.050, 0.092))
    /// 卡片表面：亮色→淡紫白 / 深色→略亮的深面板
    static let brandSurface = Color.adaptive(light: (0.96, 0.955, 0.985),
                                             dark: (0.115, 0.11, 0.165))
    /// 正文色（表面上的文字/描边）：亮色→近黑 / 深色→近白
    static let brandInk = Color.adaptive(light: (0.13, 0.12, 0.17),
                                         dark: (0.87, 0.89, 0.95))
    /// 单色中性灰（侧边栏空闲图标）：亮色→中灰 / 深色→偏蓝灰
    static let brandMono = Color.adaptive(light: (0.46, 0.47, 0.53),
                                          dark: (0.60, 0.63, 0.70))
    /// 品牌霓虹渐变（用于 logo、图表强调）：随主题自适应
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [.brandDeep, .brandAccent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 外观主题（浅色 / 深色 / 跟随系统）
enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark, system

    static let storageKey = "app_theme"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "浅色"
        case .dark: "深色"
        case .system: "跟随系统"
        }
    }

    var icon: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        case .system: "circle.lefthalf.filled"
        }
    }

    var colorSchemeOverride: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil // 跟随系统
        }
    }
}

// MARK: - 圆角令牌
enum Theme {
    enum Corner {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }
}

// MARK: - 卡片表面样式
/// 赛博朋克卡片：深色面板 + 霓虹发丝描边 + 圆角。
struct CardBackground: ViewModifier {
    var corner: CGFloat = Theme.Corner.medium
    var fill: Color = .brandSurface
    var stroke: Color = Color.brand.opacity(0.16)
    var glow: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(stroke, lineWidth: 0.6)
            )
            .shadow(color: glow ? Color.brand.opacity(0.10) : .clear,
                    radius: glow ? 10 : 0, y: glow ? 2 : 0)
    }
}

extension View {
    /// 套用统一的赛博朋克卡片表面
    func cardSurface(corner: CGFloat = Theme.Corner.medium,
                     glow: Bool = false) -> some View {
        modifier(CardBackground(corner: corner, glow: glow))
    }
}

// MARK: - 品牌徽章（胶囊）
/// 生成一个浅品牌底 + 深品牌字的小标签，常用于状态/类别提示
struct BrandBadge: View {
    let text: String
    var color: Color = .brand

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - 标志性图标方片
/// 本次升级的核心视觉语言：给功能图标套一个圆角"方片"容器，
/// 用品牌色的浅底（未选中）或品牌渐变（选中/强调）承载，加强模块辨识度与精致度。
struct IconChip: View {
    let systemName: String
    var tint: Color = .brand
    var size: CGFloat = 26
    var corner: CGFloat = 8
    var isFilled: Bool = false

    var body: some View {
        ZStack {
            if isFilled {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(tint.gradient)
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(tint.opacity(0.13))
            }
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(isFilled ? Color.white : tint)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 品牌主按钮样式（霓虹描边胶囊，带发光/按压反馈）
struct BrandPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(configuration.isPressed ? Color.brand.opacity(0.7) : Color.brand)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Color.brand.opacity(configuration.isPressed ? 0.05 : 0.08))
            )
            .overlay(
                Capsule().stroke(Color.brand.opacity(0.9), lineWidth: 1)
            )
            .shadow(color: Color.brand.opacity(configuration.isPressed ? 0.2 : 0.5),
                    radius: configuration.isPressed ? 3 : 7)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}