import SwiftUI

// Visual language borrowed from the "Think Different, Think AI" site (docs/base.css,
// docs/landing.css): deep arcade blue with a scanline grid, Courier New in uppercase for
// chrome, labels and numbers, yellow call-to-action blocks with a dark ink border and a
// hard (unblurred) drop shadow, cyan 4 px panel edges, square corners. Running text
// (the script) uses the proportional system font because Courier is hard to read for
// several paragraphs.

enum Arcade {
    // MARK: Colour tokens (base.css :root)
    static let bg = Color(hex: 0x051A7A)
    static let bgDeep = Color(hex: 0x031052)
    static let bgTop = Color(hex: 0x061EB0)
    static let panel = Color(hex: 0x071D8F)
    static let panelStrong = Color(hex: 0x0927BA)
    static let bar = Color(hex: 0x06145F)
    static let barEdge = Color(hex: 0x00093D)
    static let field = Color(hex: 0x04156A)
    static let ink = Color(hex: 0xD8F8FF)
    static let muted = Color(hex: 0x83DFF4)
    static let line = Color(hex: 0x34D4FF)
    static let accent = Color(hex: 0xFFCF24)
    static let accentHot = Color(hex: 0xFF7A1A)
    static let accentInk = Color(hex: 0x06145F)
    static let warn = Color(hex: 0xFFD35A)
    static let rec = Color(hex: 0xFF3B4E)
    static let ok = Color(hex: 0x5CF2A2)
    static let shadow = Color(red: 0, green: 9 / 255, blue: 70 / 255).opacity(0.9)

    // MARK: Type
    /// "chrome": headings, labels, numbers — Courier New.
    static func chrome(_ size: CGFloat, weight: Font.Weight = .bold, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Courier New", size: size, relativeTo: style).weight(weight)
    }

    /// "read": running text — proportional system font.
    static func read(_ style: Font.TextStyle = .body) -> Font { .system(style) }

    static let edge: CGFloat = 4
    static let dropLarge: CGFloat = 8
    static let dropSmall: CGFloat = 5
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

/// body background: 135° gradient + horizontal cyan scanlines (2 px every 8 px) +
/// vertical yellow grid lines (2 px every 96 px).
struct ArcadeBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: Arcade.bgTop, location: 0),
                                   .init(color: Arcade.bg, location: 0.42),
                                   .init(color: Arcade.bgDeep, location: 1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 2)),
                                 with: .color(Color(red: 92 / 255, green: 220 / 255, blue: 1).opacity(0.07)))
                    y += 8
                }
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: 0, width: 2, height: size.height)),
                                 with: .color(Arcade.accent.opacity(0.08)))
                    x += 96
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Hard shadow + panels

/// Unblurred offset shadow (`box-shadow: 8px 8px 0`).
struct HardShadow: ViewModifier {
    var offset: CGFloat = Arcade.dropSmall
    var color: Color = Arcade.shadow

    func body(content: Content) -> some View {
        content.background(alignment: .topLeading) {
            Rectangle().fill(color).offset(x: offset, y: offset)
        }
    }
}

/// `.lp-card`: panel colour, cyan 4 px edge, small hard drop.
struct ArcadePanel: ViewModifier {
    var accentTop: Color?
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Arcade.panel)
            .overlay(Rectangle().strokeBorder(accentTop == nil ? Arcade.line : Arcade.line.opacity(0.24),
                                              lineWidth: accentTop == nil ? Arcade.edge : 3))
            .overlay(alignment: .top) {
                if let accentTop { Rectangle().fill(accentTop).frame(height: 6) }
            }
            .modifier(HardShadow())
    }
}

extension View {
    func arcadePanel(accentTop: Color? = nil, padding: CGFloat = 18) -> some View {
        modifier(ArcadePanel(accentTop: accentTop, padding: padding))
    }

    func hardShadow(_ offset: CGFloat = Arcade.dropSmall) -> some View {
        modifier(HardShadow(offset: offset))
    }

    /// Yellow headline with ink text shadow (`text-shadow: 5px 5px 0 var(--accent-ink)`).
    func arcadeHeadline(_ size: CGFloat = 28, color: Color = Arcade.accent, shadow: CGFloat = 3) -> some View {
        self.font(Arcade.chrome(size, weight: .heavy, relativeTo: .title))
            .textCase(.uppercase)
            .tracking(1)
            .foregroundStyle(color)
            .shadow(color: Arcade.accentInk, radius: 0, x: shadow, y: shadow)
    }
}

/// `.eyebrow`: tiny cyan uppercase label with wide tracking.
struct Eyebrow: View {
    let text: String
    var color: Color = Arcade.line

    init(_ text: String, color: Color = Arcade.line) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Arcade.chrome(12, weight: .bold, relativeTo: .caption))
            .textCase(.uppercase)
            .tracking(3)
            .foregroundStyle(color)
    }
}

/// Panel with eyebrow title, used for every side panel.
struct ArcadeSection<Content: View>: View {
    let title: String
    var accent: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(title, color: accent ?? Arcade.line)
            content
        }
        .arcadePanel(accentTop: accent)
    }
}

// MARK: - Buttons

/// `.lp-btn`: primary = yellow block, ghost = transparent with cyan edge, rec = red block.
struct ArcadeButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, rec, danger }
    var kind: Kind = .primary
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(Arcade.chrome(compact ? 12 : 14, weight: .heavy, relativeTo: .callout))
            .textCase(.uppercase)
            .tracking(1)
            .lineLimit(1)
            .padding(.horizontal, compact ? 12 : 20)
            .padding(.vertical, compact ? 7 : 12)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(Rectangle().strokeBorder(border, lineWidth: 3))
            .background(alignment: .topLeading) {
                if kind != .ghost {
                    Rectangle().fill(Arcade.shadow)
                        .offset(x: pressed ? 3 : Arcade.dropSmall, y: pressed ? 3 : Arcade.dropSmall)
                }
            }
            .offset(x: pressed ? 2 : 0, y: pressed ? 2 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }

    private var background: Color {
        switch kind {
        case .primary: return Arcade.accent
        case .ghost: return .clear
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

    private var border: Color {
        switch kind {
        case .ghost: return Arcade.line
        default: return Arcade.accentInk
        }
    }
}

extension ButtonStyle where Self == ArcadeButtonStyle {
    static var arcade: ArcadeButtonStyle { ArcadeButtonStyle() }
    static var arcadeGhost: ArcadeButtonStyle { ArcadeButtonStyle(kind: .ghost) }
    static var arcadeRec: ArcadeButtonStyle { ArcadeButtonStyle(kind: .rec) }
    static func arcade(_ kind: ArcadeButtonStyle.Kind, compact: Bool = false) -> ArcadeButtonStyle {
        ArcadeButtonStyle(kind: kind, compact: compact)
    }
}

/// Square checkbox toggle in chrome type.
struct ArcadeToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(configuration.isOn ? "[X]" : "[ ]")
                    .font(Arcade.chrome(15, weight: .heavy))
                    .foregroundStyle(configuration.isOn ? Arcade.accent : Arcade.muted)
                configuration.label
                    .font(Arcade.read(.callout))
                    .foregroundStyle(Arcade.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == ArcadeToggleStyle {
    static var arcade: ArcadeToggleStyle { ArcadeToggleStyle() }
}

/// Big score number (`.lp-score b`) with label (`.lp-score span`).
struct ScoreView: View {
    let value: String
    let label: String
    var color: Color = Arcade.accent

    var body: some View {
        VStack(spacing: 6) {
            Text(value)
                .font(Arcade.chrome(34, weight: .heavy, relativeTo: .largeTitle))
                .monospacedDigit()
                .foregroundStyle(color)
                .shadow(color: Arcade.accentInk, radius: 0, x: 3, y: 3)
                .contentTransition(.numericText())
            Text(label)
                .font(Arcade.chrome(11, relativeTo: .caption2))
                .textCase(.uppercase)
                .tracking(2)
                .foregroundStyle(Arcade.muted)
        }
    }
}

/// Square monogram (`.gu-m`) used for participants.
struct Monogram: View {
    let name: String
    var color: Color = Arcade.accent

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(Arcade.chrome(15, weight: .heavy))
            .foregroundStyle(Arcade.accentInk)
            .frame(width: 30, height: 30)
            .background(color)
            .overlay(Rectangle().strokeBorder(Arcade.accentInk, lineWidth: 2))
    }
}

/// Cycle of accent colours for participants (quotes use one colour per speaker).
enum SpeakerColors {
    static let all: [Color] = [Arcade.accent, Arcade.line, Arcade.accentHot, Arcade.ok, Color(hex: 0xFF8AD8)]
    static func color(for index: Int) -> Color { all[index % all.count] }
}
