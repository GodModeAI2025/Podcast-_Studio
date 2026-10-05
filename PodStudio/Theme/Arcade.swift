import SwiftUI

// Design language: calm dark navy, large rounded cards, system rounded type, one warm
// accent. The type is still called `Arcade` (all views use it); the look moved from the
// hard-edged arcade style to a modern, spacious Apple-like interface: continuous corner
// radii, soft shadows, sentence-case labels, 44 pt minimum touch targets.

enum Arcade {
    // MARK: Colour tokens
    static let bg = Color(hex: 0x0B1330)
    static let bgDeep = Color(hex: 0x070C20)
    static let bgTop = Color(hex: 0x14214F)
    static let panel = Color(hex: 0x16214A)
    static let panelStrong = Color(hex: 0x223268)
    static let bar = Color(hex: 0x0E1738)
    static let barEdge = Color(hex: 0x1B2A5E)
    static let field = Color(hex: 0x0D1537)
    static let ink = Color(hex: 0xF2F6FF)
    static let muted = Color(hex: 0xA7B4DC)
    static let line = Color(hex: 0x6FA8FF)
    static let accent = Color(hex: 0xFFC83D)
    static let accentHot = Color(hex: 0xFF8A3D)
    static let accentInk = Color(hex: 0x1A1400)
    static let warn = Color(hex: 0xFFD35A)
    static let rec = Color(hex: 0xFF4D5E)
    static let ok = Color(hex: 0x4BE3A0)
    static let shadow = Color.black.opacity(0.35)
    /// Hairline used for card borders and dividers.
    static let hairline = Color.white.opacity(0.10)

    // MARK: Type
    /// Headings, labels, numbers: system rounded.
    static func chrome(_ size: CGFloat, weight: Font.Weight = .semibold, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Running text: proportional system font.
    static func read(_ style: Font.TextStyle = .body) -> Font { .system(style) }

    static let radius: CGFloat = 22
    static let radiusSmall: CGFloat = 14
    static let edge: CGFloat = 1
    static let dropLarge: CGFloat = 16
    static let dropSmall: CGFloat = 10
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - Background

struct ArcadeBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Arcade.bgTop, Arcade.bg, Arcade.bgDeep],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Arcade.accent.opacity(0.10), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Cards

/// Soft elevation instead of the old hard offset shadow.
struct HardShadow: ViewModifier {
    var offset: CGFloat = Arcade.dropSmall
    var color: Color = Arcade.shadow

    func body(content: Content) -> some View {
        content.shadow(color: color, radius: offset, x: 0, y: offset / 2)
    }
}

/// Card: tinted surface, hairline border, continuous corners.
struct ArcadePanel: ViewModifier {
    var accentTop: Color?
    var padding: CGFloat = 22

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Arcade.radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Arcade.panel))
            .overlay(shape.strokeBorder(accentTop?.opacity(0.55) ?? Arcade.hairline, lineWidth: accentTop == nil ? 1 : 1.5))
            .modifier(HardShadow())
    }
}

extension View {
    func arcadePanel(accentTop: Color? = nil, padding: CGFloat = 22) -> some View {
        modifier(ArcadePanel(accentTop: accentTop, padding: padding))
    }

    func hardShadow(_ offset: CGFloat = Arcade.dropSmall) -> some View {
        modifier(HardShadow(offset: offset))
    }

    /// Large heading in the accent colour.
    func arcadeHeadline(_ size: CGFloat = 28, color: Color = Arcade.accent, shadow: CGFloat = 0) -> some View {
        self.font(Arcade.chrome(size, weight: .bold, relativeTo: .title))
            .foregroundStyle(color)
    }

    /// Rounded input field surface.
    func arcadeField() -> some View {
        self.padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: Arcade.radiusSmall, style: .continuous).fill(Arcade.field))
            .overlay(RoundedRectangle(cornerRadius: Arcade.radiusSmall, style: .continuous)
                .strokeBorder(Arcade.hairline, lineWidth: 1))
    }
}

/// Small section label.
struct Eyebrow: View {
    let text: String
    var color: Color = Arcade.muted

    init(_ text: String, color: Color = Arcade.muted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Arcade.chrome(13, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(color)
    }
}

/// Card with a title, used for every side panel.
struct ArcadeSection<Content: View>: View {
    let title: String
    var accent: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(Arcade.chrome(20, weight: .bold, relativeTo: .title3))
                .foregroundStyle(Arcade.ink)
            content
        }
        .arcadePanel(accentTop: accent)
    }
}

// MARK: - Buttons

struct ArcadeButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, rec, danger }
    var kind: Kind = .primary
    var compact = false
    /// Stretch the label to the full available width (iPhone transport row).
    var fill = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Arcade.radiusSmall, style: .continuous)
        configuration.label
            .font(Arcade.chrome(compact ? 15 : 17, weight: .semibold, relativeTo: .callout))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: fill ? .infinity : nil)
            .padding(.horizontal, compact ? 16 : 24)
            .padding(.vertical, compact ? 10 : 14)
            .frame(minHeight: compact ? 44 : 54)
            .foregroundStyle(foreground)
            .background(shape.fill(background))
            .overlay(shape.strokeBorder(border, lineWidth: kind == .ghost ? 1 : 0))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(shape)
    }

    private var background: Color {
        switch kind {
        case .primary: return Arcade.accent
        case .ghost: return Color.white.opacity(0.07)
        case .rec: return Arcade.rec
        case .danger: return Arcade.accentHot
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary, .danger: return Arcade.accentInk
        case .ghost: return Arcade.ink
        case .rec: return .white
        }
    }

    private var border: Color { Color.white.opacity(0.18) }
}

extension ButtonStyle where Self == ArcadeButtonStyle {
    static var arcade: ArcadeButtonStyle { ArcadeButtonStyle() }
    static var arcadeGhost: ArcadeButtonStyle { ArcadeButtonStyle(kind: .ghost) }
    static var arcadeRec: ArcadeButtonStyle { ArcadeButtonStyle(kind: .rec) }
    static func arcade(_ kind: ArcadeButtonStyle.Kind, compact: Bool = false, fill: Bool = false) -> ArcadeButtonStyle {
        ArcadeButtonStyle(kind: kind, compact: compact, fill: fill)
    }
}

/// iOS-style switch with the label on the left.
struct ArcadeToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 14) {
                configuration.label
                    .font(Arcade.read(.body))
                    .foregroundStyle(Arcade.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Arcade.accent : Color.white.opacity(0.16))
                    Circle().fill(configuration.isOn ? Arcade.accentInk : .white)
                        .padding(3)
                }
                .frame(width: 52, height: 32)
                .animation(.snappy(duration: 0.18), value: configuration.isOn)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == ArcadeToggleStyle {
    static var arcade: ArcadeToggleStyle { ArcadeToggleStyle() }
}

/// Big number with label.
struct ScoreView: View {
    let value: String
    let label: String
    var color: Color = Arcade.accent

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(Arcade.chrome(36, weight: .bold, relativeTo: .largeTitle))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text(label)
                .font(Arcade.chrome(13, weight: .medium, relativeTo: .caption))
                .foregroundStyle(Arcade.muted)
        }
    }
}

/// Round initial used for participants.
struct Monogram: View {
    let name: String
    var color: Color = Arcade.accent

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(Arcade.chrome(17, weight: .bold))
            .foregroundStyle(Arcade.accentInk)
            .frame(width: 38, height: 38)
            .background(Circle().fill(color))
    }
}

/// Cycle of accent colours for participants.
enum SpeakerColors {
    static let all: [Color] = [Arcade.accent, Arcade.line, Arcade.accentHot, Arcade.ok, Color(hex: 0xFF8AD8)]
    static func color(for index: Int) -> Color { all[index % all.count] }
}
