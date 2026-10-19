import SwiftUI

// Guanpan Pro's native system: editorial warmth for guidance and assets,
// disciplined data rhythm for market, order book, chart, and quant surfaces.
enum GPTheme: String, CaseIterable, Identifiable, Codable {
    case system, light, dark, comfort
    var id: String { rawValue }
    var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色"; case .comfort: "护眼" } }
    var colorScheme: ColorScheme? { switch self { case .system, .comfort: nil; case .light: .light; case .dark: .dark } }
}

struct GPPalette {
    let scheme: ColorScheme
    let comfort: Bool
    var canvas: Color { comfort ? Color(hex: 0xF1F0E5) : scheme == .dark ? Color(hex: 0x111915) : Color(hex: 0xF7F5EF) }
    var paper: Color { comfort ? Color(hex: 0xFAF9F1) : scheme == .dark ? Color(hex: 0x19231D) : Color(hex: 0xFFFEFA) }
    var raised: Color { scheme == .dark ? Color(hex: 0x202C25) : Color(hex: 0xF0EEE6) }
    var ink: Color { scheme == .dark ? Color(hex: 0xEEF2E9) : Color(hex: 0x202B24) }
    var muted: Color { scheme == .dark ? Color(hex: 0xA3AEA3) : Color(hex: 0x747B72) }
    var line: Color { scheme == .dark ? Color(hex: 0x344038) : Color(hex: 0xE1DED4) }
    var forest: Color { scheme == .dark ? Color(hex: 0xA7C9A8) : Color(hex: 0x315D4A) }
    var forestDeep: Color { Color(hex: 0x244638) }
    var terracotta: Color { scheme == .dark ? Color(hex: 0xE2A475) : Color(hex: 0xB46B42) }
    var jade: Color { scheme == .dark ? Color(hex: 0x83C4A0) : Color(hex: 0x347E63) }
    var risk: Color { scheme == .dark ? Color(hex: 0xEF9587) : Color(hex: 0xB9564D) }
    var tint: Color { scheme == .dark ? Color(hex: 0x26392D) : Color(hex: 0xE5ECE4) }
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
}

private struct GPScaledFontModifier: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    init(size: CGFloat, relativeTo: Font.TextStyle, weight: Font.Weight, design: Font.Design) {
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
        self.weight = weight; self.design = design
    }
    func body(content: Content) -> some View { content.font(.system(size: scaledSize, weight: weight, design: design)) }
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
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(.headline, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(.caption).foregroundStyle(p.muted) }
            }
            content
        }.padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 0.7) }
    }
}

struct DataPanel<Content: View>: View {
    @Environment(\.gp) private var p
    let title: String
    var caption: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 6)
                if let caption { Text(caption).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(p.muted) }
            }
            content
        }.padding(13).background(p.paper, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(p.line.opacity(0.82), lineWidth: 0.7))
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
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 0) { content }.padding(.horizontal, 20).padding(.bottom, 32).frame(maxWidth: 760).frame(maxWidth: .infinity, alignment: .top) }.background(p.canvas).scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively) }
}
