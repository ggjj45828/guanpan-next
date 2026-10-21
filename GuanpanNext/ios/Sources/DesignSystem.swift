import SwiftUI
import UIKit

// Guanpan Pro's native system: editorial warmth for guidance and assets,
// disciplined data rhythm for market, order book, chart, and quant surfaces.
enum GPTheme: String, CaseIterable, Identifiable, Codable {
    case system, light, dark, comfort
    var id: String { rawValue }
    var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色"; case .comfort: "护眼" } }
    var colorScheme: ColorScheme? { switch self { case .system, .comfort: nil; case .light: .light; case .dark: .dark } }
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

struct GPPalette {
    let scheme: ColorScheme
    let comfort: Bool
    var appearance = GPAppearance()
    // The pale blue-lilac paper tint borrows the calm color layering the user
    // liked in the reference, while typography and editorial grouping remain A.
    var canvas: Color { appearance.canvasHex.map { Color(hex: $0) } ?? (comfort ? Color(hex: 0xF1F0E5) : scheme == .dark ? Color(hex: 0x131824) : Color(hex: 0xF1F2F9)) }
    var paper: Color { appearance.paperHex.map { Color(hex: $0) } ?? (comfort ? Color(hex: 0xFAF9F1) : scheme == .dark ? Color(hex: 0x1B2130) : Color(hex: 0xFCFCFF)) }
    var raised: Color { comfort ? Color(hex: 0xE8E7DA) : scheme == .dark ? Color(hex: 0x252C3C) : Color(hex: 0xE9EBF4) }
    var ink: Color { appearance.inkHex.map { Color(hex: $0) } ?? (comfort ? Color(hex: 0x263329) : scheme == .dark ? Color(hex: 0xEEF0F8) : Color(hex: 0x252A3B)) }
    var muted: Color { comfort ? Color(hex: 0x707568) : scheme == .dark ? Color(hex: 0xA6AEC0) : Color(hex: 0x73798C) }
    var line: Color { comfort ? Color(hex: 0xD8D7CA) : scheme == .dark ? Color(hex: 0x353D50) : Color(hex: 0xDFE2EC) }
    var forest: Color { comfort ? Color(hex: 0x42634E) : scheme == .dark ? Color(hex: 0x9CC8BD) : Color(hex: 0x315D58) }
    var forestDeep: Color { Color(hex: 0x244638) }
    var terracotta: Color { comfort ? Color(hex: 0xA66642) : scheme == .dark ? Color(hex: 0xE2A475) : Color(hex: 0xB46B58) }
    var jade: Color { comfort ? Color(hex: 0x3D765D) : scheme == .dark ? Color(hex: 0x83C4A0) : Color(hex: 0x347E63) }
    var risk: Color { comfort ? Color(hex: 0xAA574C) : scheme == .dark ? Color(hex: 0xEF9587) : Color(hex: 0xC24E58) }
    var tint: Color { comfort ? Color(hex: 0xE4E9DC) : scheme == .dark ? Color(hex: 0x263342) : Color(hex: 0xE5E8F3) }
    var heroSurface: Color { comfort ? Color(hex: 0xF0EFE2) : scheme == .dark ? Color(hex: 0x20283A) : Color(hex: 0xE8EAF7) }
    var chartBlue: Color { comfort ? Color(hex: 0x547D91) : scheme == .dark ? Color(hex: 0x8CA9E8) : Color(hex: 0x607EC5) }
    var chartViolet: Color { comfort ? Color(hex: 0x806C96) : scheme == .dark ? Color(hex: 0xC0A4E8) : Color(hex: 0x8872B7) }
    var chartGold: Color { comfort ? Color(hex: 0x9B7D42) : scheme == .dark ? Color(hex: 0xE2C178) : Color(hex: 0xB08A3C) }
    var chartCost: Color { comfort ? Color(hex: 0xA45F6C) : scheme == .dark ? Color(hex: 0xE38FA3) : Color(hex: 0xB85C78) }
}

private struct GPPaletteKey: EnvironmentKey {
    static let defaultValue = GPPalette(scheme: .light, comfort: false)
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
