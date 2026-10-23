import SwiftUI
import UIKit

// Guanpan Pro's native system: editorial warmth for guidance and assets,
// disciplined data rhythm for market, order book, chart, and quant surfaces.
/// 五套主题，每一套的「底色 + 主强调色 + 图表色」都从各自配方取，互不相同：
/// 跟随系统（设备）、浅色（蓝白）、深色（藏蓝）、护眼（米黄）、暗夜金（纯黑+金）。
/// 用户自定义色（inkHex/paperHex/canvasHex）仍可在任意主题上叠加，不破坏「五套不同」。
enum GPTheme: String, CaseIterable, Identifiable, Codable {
    case system, light, dark, comfort, noir
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        case .comfort: "护眼"
        case .noir: "暗夜金"
        }
    }
    /// 显式主题强制配色方案；system 跟随设备（返回 nil）。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light, .comfort: .light
        case .dark, .noir: .dark
        }
    }
}

/// 字号档位选项。必须是结构体：命名元组不能用作 ForEach 的 id keyPath。
struct GPScaleOption: Identifiable, Equatable {
    var id: Double { value }
    let title: String
    let value: Double
}

/// 字体族：系统 / 圆体 / 衬线 / 等宽。只影响通过 `gpFont` 渲染的正文，
/// 系统控件（导航栏、Tab）跟随系统字体，避免混排出两种排版风格。
enum GPFontFamily: String, CaseIterable, Identifiable, Codable {
    case system, rounded, serif, monospaced
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "系统"; case .rounded: "圆体"; case .serif: "衬线"; case .monospaced: "等宽" }
    }
    var design: Font.Design {
        switch self { case .system: .default; case .rounded: .rounded; case .serif: .serif; case .monospaced: .monospaced }
    }
}

/// 用户可调外观。颜色用 `0xRRGGBB` 存，nil 表示跟随当前主题。
/// 字号不直接改 point，而是映射到 Dynamic Type 档位 —— 这样所有系统字体
/// （导航栏、列表、表单）会一起放大，而不是只有自定义文本变大、系统控件不变。
struct GPAppearance: Codable, Equatable {
    var fontScale: Double = 1.0
    var fontFamily: GPFontFamily = .system
    var inkHex: UInt32?
    var paperHex: UInt32?
    var canvasHex: UInt32?

    var dynamicTypeSize: DynamicTypeSize {
        switch fontScale {
        case ..<0.92: return .small
        case ..<1.0: return .medium
        case ..<1.12: return .large
        case ..<1.28: return .xLarge
        case ..<1.45: return .xxLarge
        default: return .xxxLarge
        }
    }
    var fontScaleTitle: String {
        switch fontScale {
        case ..<0.92: return "小"
        case ..<1.0: return "稍小"
        case ..<1.12: return "标准"
        case ..<1.28: return "大"
        case ..<1.45: return "特大"
        default: return "最大"
        }
    }
    var hasCustomColors: Bool { inkHex != nil || paperHex != nil || canvasHex != nil }

    /// 设置页字号档位。值不是 point，而是 Dynamic Type 档位的代表值。
    /// 用结构体而不是元组：Swift 不支持对命名元组做 keyPath，ForEach(id://.value) 会编译失败。
    static let scaleOptions: [GPScaleOption] = [
        GPScaleOption(title: "小", value: 0.88),
        GPScaleOption(title: "稍小", value: 0.96),
        GPScaleOption(title: "标准", value: 1.0),
        GPScaleOption(title: "大", value: 1.20),
        GPScaleOption(title: "特大", value: 1.36),
        GPScaleOption(title: "最大", value: 1.50)
    ]
}

private struct GPAppearanceKey: EnvironmentKey {
    static let defaultValue = GPAppearance()
}
extension EnvironmentValues {
    var gpAppearance: GPAppearance { get { self[GPAppearanceKey.self] } set { self[GPAppearanceKey.self] = newValue } }
}

/// 主题配方：每套主题一套独立的底色 / 强调色 / 图表色，保证「五套真正不同」。
/// 字段顺序固定：canvas, paper, raised, ink, muted, line,
/// accentA(主), accentADeep(主深), accentB, accentC, risk, tint, hero,
/// chartA, chartB, chartC, chartCost, up(涨), down(跌)。
private struct GPRecipe {
    let canvas, paper, raised, ink, muted, line: UInt32
    let accentA, accentADeep, accentB, accentC, risk, tint, hero: UInt32
    let chartA, chartB, chartC, chartCost, up, down: UInt32
}

private let gpLightRecipe = GPRecipe(
    canvas: 0xF5F7FB, paper: 0xFFFFFF, raised: 0xE8EDF4, ink: 0x17263A, muted: 0x708095, line: 0xE5EAF1,
    accentA: 0x3268E8, accentADeep: 0x1F4FBE, accentB: 0x795CE0, accentC: 0x0DA69A, risk: 0xED665E, tint: 0xE4EBFB, hero: 0xE9F0FC,
    chartA: 0x386DEF, chartB: 0x795CE0, chartC: 0xD99528, chartCost: 0xB85C78, up: 0xDB3B34, down: 0x1E9E5A)

private let gpDarkRecipe = GPRecipe(
    canvas: 0x121826, paper: 0x1A2233, raised: 0x222B3D, ink: 0xF0F2FA, muted: 0xAEB6C8, line: 0x33405A,
    accentA: 0x7FA6F5, accentADeep: 0x1E49A8, accentB: 0xB3A0F2, accentC: 0x45C8BC, risk: 0xF2857E, tint: 0x26324A, hero: 0x1E2C48,
    chartA: 0x7FA6F5, chartB: 0xB3A0F2, chartC: 0xE8B45A, chartCost: 0xE38FA3, up: 0xFF6B5E, down: 0x4FC07E)

/// 护眼：米黄底 + 低饱和墨绿/靛蓝，长时间看不刺眼。
private let gpComfortRecipe = GPRecipe(
    canvas: 0xF3F1E6, paper: 0xFBFAF2, raised: 0xEAE8DA, ink: 0x2A2F24, muted: 0x736B55, line: 0xDAD8CB,
    accentA: 0x2F5CC4, accentADeep: 0x24479C, accentB: 0x6A4FC8, accentC: 0x0B8F85, risk: 0xC9524C, tint: 0xEDEBF8, hero: 0xEDEBF8,
    chartA: 0x2F5CC4, chartB: 0x6A4FC8, chartC: 0xB8842A, chartCost: 0x9B5660, up: 0xA8432F, down: 0x3D765D)

/// 暗夜金：近黑底 + 金色强调，与「深色（藏蓝）」明显区分——金 vs 蓝。
private let gpNoirRecipe = GPRecipe(
    canvas: 0x0B0B0D, paper: 0x16161A, raised: 0x232329, ink: 0xF5F0E6, muted: 0xB0A892, line: 0x33332F,
    accentA: 0xD4AF37, accentADeep: 0xA9842A, accentB: 0xC9A24B, accentC: 0x8FBF9A, risk: 0xE0625A, tint: 0x2A2418, hero: 0x211B10,
    chartA: 0xD4AF37, chartB: 0xC9A227, chartC: 0xE08A3C, chartCost: 0xC77B6E, up: 0xF0795E, down: 0x5FBF86)

private func gpRecipe(_ theme: GPTheme, scheme: ColorScheme) -> GPRecipe {
    switch theme {
    case .system: return scheme == .dark ? gpDarkRecipe : gpLightRecipe
    case .light: return gpLightRecipe
    case .dark: return gpDarkRecipe
    case .comfort: return gpComfortRecipe
    case .noir: return gpNoirRecipe
    }
}

struct GPPalette {
    let scheme: ColorScheme
    var appearance = GPAppearance()
    private let r: GPRecipe
    /// 配色改版：对齐「观盘Next 五页界面预览」设计稿——鲜亮蓝/紫/青/金，告别墨绿闷色调。
    /// 五套主题各自从配方取色，确保互不相同；用户自定义色仍可叠加。
    init(theme: GPTheme, scheme: ColorScheme, appearance: GPAppearance = GPAppearance()) {
        self.scheme = scheme
        self.appearance = appearance
        self.r = gpRecipe(theme, scheme: scheme)
    }
    var canvas: Color { appearance.canvasHex.map { Color(hex: $0) } ?? Color(hex: r.canvas) }
    var paper: Color { appearance.paperHex.map { Color(hex: $0) } ?? Color(hex: r.paper) }
    var raised: Color { Color(hex: r.raised) }
    var ink: Color { appearance.inkHex.map { Color(hex: $0) } ?? Color(hex: r.ink) }
    var muted: Color { Color(hex: r.muted) }
    var line: Color { Color(hex: r.line) }
    var forest: Color { Color(hex: r.accentA) }
    var forestDeep: Color { Color(hex: r.accentADeep) }
    var terracotta: Color { Color(hex: r.accentB) }
    var jade: Color { Color(hex: r.accentC) }
    var risk: Color { Color(hex: r.risk) }
    var tint: Color { Color(hex: r.tint) }
    var heroSurface: Color { Color(hex: r.hero) }
    var chartBlue: Color { Color(hex: r.chartA) }
    var chartViolet: Color { Color(hex: r.chartB) }
    var chartGold: Color { Color(hex: r.chartC) }
    var chartCost: Color { Color(hex: r.chartCost) }
    /// 涨跌语义色（全局唯一来源）：国内口径「红涨绿跌」。
    /// 任何价格变动的着色都必须走 `changeTone(_:)` 或这两个属性；
    /// 不要再拿 risk / jade / terracotta 当涨跌色用（它们是「警示 / 建议 / 均线」语义）。
    var gpUp: Color { Color(hex: r.up) }
    var gpDown: Color { Color(hex: r.down) }
    /// 价格线本身用 `ink`（近黑），涨跌用 `gpUp`/`gpDown`，与「price=黑、涨红跌绿」一致。
    func changeTone(_ value: Double) -> Color { value >= 0 ? gpUp : gpDown }
}

private struct GPPaletteKey: EnvironmentKey {
    static let defaultValue = GPPalette(theme: .light, scheme: .light)
}
extension EnvironmentValues {
    var gp: GPPalette { get { self[GPPaletteKey.self] } set { self[GPPaletteKey.self] = newValue } }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: 1)
    }
    /// 存回 `GPAppearance` 用的 0xRRGGBB。取不到分量时返回 nil，界面保持"跟随主题"。
    var gpHex: UInt32? {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func clamp(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return (clamp(r) << 16) | (clamp(g) << 8) | clamp(b)
    }
}

private struct GPScaledFontModifier: ViewModifier {
    @Environment(\.gpAppearance) private var appearance
    @ScaledMetric private var scaledSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    init(size: CGFloat, relativeTo: Font.TextStyle, weight: Font.Weight, design: Font.Design) {
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
        self.weight = weight; self.design = design
    }
    func body(content: Content) -> some View {
        // 用户选了字体族就整体替换，否则保留调用处原本的排版意图。
        let resolved = appearance.fontFamily == .system ? design : appearance.fontFamily.design
        return content.font(.system(size: scaledSize, weight: weight, design: resolved))
    }
}
extension View {
    func gpFont(size: CGFloat, relativeTo: Font.TextStyle = .body, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(GPScaledFontModifier(size: size, relativeTo: relativeTo, weight: weight, design: design))
    }
}

struct EditorialSection<Content: View>: View {
    @Environment(\.gp) private var p
    let title: String
    var trailing: String? = nil
    /// 分组主色。默认森林绿；行情/买卖类用陶红，风险类用 risk，
    /// 这样一屏扫下来能靠颜色分辨「这是哪一类信息」，而不是一片灰字。
    var accent: Color? = nil
    @ViewBuilder var content: Content
    private var tone: Color { accent ?? p.forest }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Capsule().fill(tone.opacity(0.85)).frame(width: 3, height: 15).offset(y: 1)
                Text(title).font(.system(.headline, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(.caption).foregroundStyle(tone.opacity(0.85)) }
            }
            content
        }.padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [tone.opacity(0.34), p.line.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 0.8)
        }
    }
}

struct DataPanel<Content: View>: View {
    @Environment(\.gp) private var p
    let title: String
    var accent: Color? = nil
    var caption: String? = nil
    @ViewBuilder var content: Content
    private var tone: Color { accent ?? p.forest }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 6)
                if let caption { Text(caption).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(tone.opacity(0.8)) }
            }
            content
        }.padding(13)
        .background(
            LinearGradient(colors: [p.paper, tone.opacity(0.09)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(tone.opacity(0.22), lineWidth: 0.9))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tone.opacity(0.75)).frame(width: 2.5).padding(.vertical, 14).padding(.leading, 1.2)
        }
        .shadow(color: tone.opacity(0.08), radius: 7, x: 0, y: 3)
    }
}

struct GPValue: View {
    @Environment(\.gp) private var p
    let label: String
    let value: String
    var footnote: String? = nil
    var emphasis: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(p.muted)
            Text(value).font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(emphasis ?? p.ink).lineLimit(1).minimumScaleFactor(0.78)
            if let footnote { Text(footnote).font(.caption2).foregroundStyle(p.muted).lineLimit(1) }
        }
    }
}

struct GPStatus: View {
    @Environment(\.gp) private var p
    let title: String
    let detail: String
    var symbol = "clock"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 21, weight: .regular)).foregroundStyle(p.forest)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
            Text(detail).font(.caption).foregroundStyle(p.muted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action { Button(actionTitle, action: action).font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(p.forest) }
        }.frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 16)
    }
}

struct GPDataRow: View {
    @Environment(\.gp) private var p
    let title: String
    let value: String
    var note: String? = nil
    var valueColor: Color? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(.subheadline, design: .default).weight(.medium)).foregroundStyle(p.ink); if let note { Text(note).font(.caption2).foregroundStyle(p.muted) } }
            Spacer(minLength: 8)
            Text(value).font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(valueColor ?? p.ink).multilineTextAlignment(.trailing)
        }.padding(.vertical, 8).overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.7)).frame(height: 0.5) }
    }
}

struct GPActionButton: View {
    @Environment(\.gp) private var p
    let title: String
    var secondary = false
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { if let systemImage { Image(systemName: systemImage) }; Text(title).lineLimit(1) }
                .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 46)
                .foregroundStyle(secondary ? p.forest : Color.white)
                .background(secondary ? p.tint : p.forestDeep, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }.buttonStyle(.plain).accessibilityAddTraits(.isButton)
    }
}

struct GPPageBackground<Content: View>: View {
    @Environment(\.gp) private var p
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14).padding(.bottom, 32)
                .frame(maxWidth: 820).frame(maxWidth: .infinity, alignment: .top)
        }
        // 极浅的双色渐变：纸张底 + 一抹青绿，避免整页糊成一片灰白。
        .background(
            LinearGradient(colors: [p.canvas, p.forest.opacity(0.07), p.canvas],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea())
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - 键盘收起

/// 数字键盘没有回车键，输入完必须点别的区域才能收起来。
/// 这里统一给一个键盘上方的「完成」按钮，并让内容下拉时立即收起键盘。
struct GPKeyboardDismiss: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { GPKeyboardDismiss.resign() }
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("keyboard.done")
                }
            }
            .scrollDismissesKeyboard(.immediately)
    }
    static func resign() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension View {
    /// 给页面/表单加「完成」键盘工具条。可重复应用，不会叠加出多个按钮。
    func gpKeyboardDismiss() -> some View { modifier(GPKeyboardDismiss()) }
}
