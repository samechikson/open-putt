import SwiftUI
import CoreText

// MARK: - Palette
//
// The "Organic" design system: a warm cream ground, burnt-orange accent, and a
// sage-green secondary. Tokens mirror `_ds/.../styles.css` from the imported
// Claude Design project (Putting Gate App.dc.html). Kept in one place so the
// whole app speaks with one voice.

extension Color {
    init(pgHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    // Roles
    static let pgBg = Color(pgHex: 0xf5ead8)
    static let pgSurface = Color(pgHex: 0xebddc5)
    static let pgText = Color(pgHex: 0x201e1d)
    static let pgAccent = Color(pgHex: 0xc67139)
    static let pgAccent2 = Color(pgHex: 0x7a8a5e)

    // Cards sit a hair lighter than the ground.
    static let pgCardBg = Color(pgHex: 0xf9f4ed) // neutral-100
    static let pgShadow = Color(pgHex: 0x2e2b25).opacity(0.14)
    static let pgDivider = Color(pgHex: 0x201e1d).opacity(0.10)

    // Neutral ramp
    static let pgNeutral200 = Color(pgHex: 0xeee7db)
    static let pgNeutral300 = Color(pgHex: 0xdcd3c4)
    static let pgNeutral400 = Color(pgHex: 0xc0b6a5)
    static let pgNeutral500 = Color(pgHex: 0xa19786)
    static let pgNeutral600 = Color(pgHex: 0x82796a)
    static let pgNeutral700 = Color(pgHex: 0x645c50)

    // Accent (orange) ramp
    static let pgAccent100 = Color(pgHex: 0xfff2eb)
    static let pgAccent600 = Color(pgHex: 0xb2622d)
    static let pgAccent700 = Color(pgHex: 0x8c491a)
    static let pgAccent800 = Color(pgHex: 0x643312)

    // Accent-2 (sage) ramp
    static let pgAccent2_100 = Color(pgHex: 0xf0fae1)
    static let pgAccent2_200 = Color(pgHex: 0xe1eecc)
    static let pgAccent2_300 = Color(pgHex: 0xccdbb2)
    static let pgAccent2_500 = Color(pgHex: 0x8fa073)
    static let pgAccent2_600 = Color(pgHex: 0x728157)
    static let pgAccent2_700 = Color(pgHex: 0x56633f)
    static let pgAccent2_800 = Color(pgHex: 0x3d472b)
}

// MARK: - Fonts

/// Registers the bundled Caprasimo (heading) + Figtree (body) TTFs at launch.
/// The target's Info.plist is generated (no `UIAppFonts` to edit), so the fonts
/// are registered programmatically instead. If a file is missing, the matching
/// `Font.pg*` helper falls back to the system font.
enum PGFonts {
    static let heading = "Caprasimo-Regular"
    static let bodyRegular = "Figtree-Regular"
    static let bodySemibold = "Figtree-SemiBold"
    static let bodyBold = "Figtree-Bold"

    static func register() {
        for name in [heading, bodyRegular, bodySemibold, bodyBold] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Font {
    enum PGBodyWeight { case regular, semibold, bold }

    /// Caprasimo display heading at a fixed size, scaling with Dynamic Type.
    static func pgHeading(_ size: CGFloat, relativeTo style: TextStyle = .body) -> Font {
        .custom(PGFonts.heading, size: size, relativeTo: style)
    }

    /// Figtree body text at the given weight.
    static func pgBody(_ size: CGFloat, weight: PGBodyWeight = .regular, relativeTo style: TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .regular: name = PGFonts.bodyRegular
        case .semibold: name = PGFonts.bodySemibold
        case .bold: name = PGFonts.bodyBold
        }
        return .custom(name, size: size, relativeTo: style)
    }
}

// MARK: - Building blocks

/// A hairline divider between rows inside a card.
struct PGDivider: View {
    var body: some View { Rectangle().fill(Color.pgDivider).frame(height: 1) }
}

/// An uppercase, tracked section kicker (the design's `h6`).
struct PGSectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.pgBody(11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Color.pgNeutral700)
    }
}

/// A large left-aligned screen title in the heading face (the design's `pg-title`).
struct PGHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack {
            Text(title)
                .font(.pgHeading(30, relativeTo: .largeTitle))
                .foregroundStyle(Color.pgText)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// A small pill tag.
struct PGTag: View {
    enum Style { case accent, accent2 }
    let text: String
    var style: Style = .accent

    init(_ text: String, style: Style = .accent) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Text(text)
            .font(.pgBody(11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .foregroundStyle(style == .accent ? Color.pgAccent800 : Color.pgAccent2_800)
            .background(style == .accent ? Color.pgAccent100 : Color.pgAccent2_100, in: Capsule())
    }
}

/// The Open Putt mark: a golf "gate" glyph. Drawn to scale from the design's
/// 64×64 SVG so it renders crisp at any size.
struct PGGlyph: View {
    var barColor: Color = .pgBg
    var dashColor: Color = .pgAccent2_300

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 64
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s),
                     cornerRadius: 3.25 * s)
            }
            ctx.fill(bar(16, 17, 6.5, 31), with: .color(barColor))
            ctx.fill(bar(41.5, 17, 6.5, 31), with: .color(barColor))
            ctx.fill(bar(16, 17, 32, 6.5), with: .color(barColor))
            var line = Path()
            line.move(to: CGPoint(x: 22.5 * s, y: 29 * s))
            line.addLine(to: CGPoint(x: 41.5 * s, y: 29 * s))
            ctx.stroke(line, with: .color(dashColor),
                       style: StrokeStyle(lineWidth: 2.5 * s, dash: [3 * s, 4 * s]))
        }
    }
}

/// The circular app-mark: the gate glyph on an accent disc.
struct PGLogo: View {
    var size: CGFloat = 56
    var body: some View {
        ZStack {
            Circle().fill(Color.pgAccent)
            PGGlyph()
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Modifiers

extension View {
    /// Wraps content in the design's card surface: lighter-than-ground fill,
    /// large corner radius, soft ink shadow. Content is clipped to the corners so
    /// full-bleed row dividers meet the edge cleanly.
    func pgCard(cornerRadius: CGFloat = 22) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.pgCardBg)
                    .shadow(color: Color.pgShadow, radius: 3, x: 0, y: 1)
            )
    }

    /// Fills the screen behind content with the warm ground color.
    func pgScreenBackground() -> some View {
        self.background(Color.pgBg.ignoresSafeArea())
    }
}

// MARK: - Button styles

/// Full-width primary action: accent fill, ground-colored heading text, pill.
struct PGPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pgHeading(15))
            .foregroundStyle(Color.pgBg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(configuration.isPressed ? Color.pgAccent700 : Color.pgAccent, in: Capsule())
            .contentShape(Capsule())
    }
}

/// A quiet text button in the accent color.
struct PGGhostButtonStyle: ButtonStyle {
    var color: Color = .pgAccent
    var size: CGFloat = 14
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pgBody(size, weight: .semibold))
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}
