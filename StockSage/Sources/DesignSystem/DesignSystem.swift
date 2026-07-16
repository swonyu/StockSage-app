import SwiftUI

// MARK: - Design System
enum DS {

    // MARK: Spacing
    enum Space {
        static let xxs: CGFloat = 4
        static let xs:  CGFloat = 8
        static let sm:  CGFloat = 10
        static let md:  CGFloat = 14
        static let lg:  CGFloat = 18
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Corner radii
    enum Radius {
        static let well:   CGFloat = 6   // small icon-well container (24-28 pt square)
        static let small:  CGFloat = 8
        static let chip:   CGFloat = 12
        static let card:   CGFloat = 14
        static let bubble: CGFloat = 16
        static let field:  CGFloat = 20
        static let modal:  CGFloat = 24
        static let icon:   CGFloat = 10
    }

    // MARK: Semantic colors
    enum Palette {
        static let accent        = Color(red: 0.98, green: 0.18, blue: 0.29)
        static let accent2       = Color(red: 1.00, green: 0.33, blue: 0.55)
        // Canvas wash (macOS 27 overhaul, 2026-07-16): deep slate with a slight
        // violet-warm cast that flatters the crimson accent — replaces the flat
        // codeSurface grey. Going DARKER only raises text contrast, so the
        // dangerSoft AA measurements (derived on the lighter 0.125 surface) hold.
        static let bgTop         = Color(red: 0.10, green: 0.09, blue: 0.11)
        static let bgBottom      = Color(red: 0.045, green: 0.04, blue: 0.06)
        static let surface       = Color.white.opacity(0.07)
        static let surfaceAlt    = Color.white.opacity(0.06)
        static let surfaceStroke = Color.white.opacity(0.12)
        static let hairline      = Color.white.opacity(0.12)
        static let textPrimary   = Color.white
        static let textSecondary = Color.white.opacity(0.66)
        static let success       = Color.green
        static let warning       = Color.orange
        static let danger        = Color.red
        static let successSoft   = Color(red: 0.45, green: 0.85, blue: 0.55)
        static let warningSoft   = Color(red: 1.0,  green: 0.72, blue: 0.35)
        /// Softened red for SMALL danger TEXT on dark surfaces (chips/labels): system
        /// red measures ~3.7–4.3:1 there — under WCAG AA 4.5:1 for sub-18pt text —
        /// while this swatch clears AA on every ideas-surface background (5.01 / 4.72 /
        /// 5.99:1; derivation in PLAN_2026-07-03_ux_wave2_design_system.md §D). Keep
        /// `danger` for icons, fills and strokes (non-text 3:1 bar). Mirrors the
        /// successSoft/warningSoft precedent; A11Y_BUGHUNT #12's swatch, lightened
        /// 0.45→0.50 to clear the detail sheet's lighter chip background.
        static let dangerSoft    = Color(red: 1.0,  green: 0.50, blue: 0.50)
    }

    // MARK: Typography
    // The ideas-surface type scale lives in MarketsView's @ScaledMetric mvFontNN
    // tokens and their semantic aliases (fontCardTitle, fontChipLabel, …) — a
    // Dynamic-Type-aware modular ladder ratified by visual QA. Only tokens with
    // live app-wide consumers belong here; the parent app's chat-scale ladder
    // was deleted in the macOS 27 overhaul (2026-07-16).
    enum Typography {
        static let titleM = Font.system(size: 17, weight: .semibold, design: .rounded)
    }

    // MARK: Motion
    enum Motion {
        static let spring   = Animation.spring(response: 0.35, dampingFraction: 0.85)
        static let snappy   = Animation.spring(response: 0.28, dampingFraction: 0.80)
        static let press    = Animation.timingCurve(0.32, 0.72, 0.0, 1.0, duration: 0.18)
        static let fade     = Animation.timingCurve(0.32, 0.72, 0.0, 1.0, duration: 0.22)
        static let smooth   = Animation.timingCurve(0.32, 0.72, 0.0, 1.0, duration: 0.45)
        static let cinematic = Animation.timingCurve(0.22, 0.61, 0.36, 1.0, duration: 0.80)
        static let magnetic = Animation.interpolatingSpring(stiffness: 220, damping: 18)
        static let stagger   = Animation.timingCurve(0.34, 0.0, 0.66, 1.0, duration: 0.32)
        static let entrance  = Animation.timingCurve(0.22, 0.61, 0.36, 1.0, duration: 0.55)
        /// The Code tab's signature curve (matches its local `lux`), promoted
        /// to a shared token so the chat composer/welcome animate identically.
        static let lux       = Animation.timingCurve(0.32, 0.72, 0.0, 1.0, duration: 0.40)
    }

    // MARK: Elevation
    // Retuned for the darker canvas (macOS 27 overhaul): on near-black, small
    // hard shadows read as dirt — depth comes from softer, larger, slightly
    // stronger ones.
    enum Elevation {
        static let shadow1 = (color: Color.black.opacity(0.28), radius: CGFloat(8),  y: CGFloat(3))
        static let shadow2 = (color: Color.black.opacity(0.40), radius: CGFloat(14), y: CGFloat(6))
        static let shadow3 = (color: Color.black.opacity(0.50), radius: CGFloat(24), y: CGFloat(10))
        static func accentGlow(_ intensity: Double = 0.24) -> (color: Color, radius: CGFloat, y: CGFloat) {
            (Palette.accent.opacity(intensity), 12, 4)
        }
    }

    // MARK: Bezel
    enum Bezel {
        static let outerRadius:  CGFloat = 22
        static let innerRadius:  CGFloat = 17
        static let shellPadding: CGFloat = 5
        static let shellFill        = Color.white.opacity(0.04)
        static let shellStroke      = Color.white.opacity(0.09)
        static let coreFill         = Color.white.opacity(0.06)
        static let coreInnerHighlight = LinearGradient(
            colors: [Color.white.opacity(0.14), Color.white.opacity(0.02)],
            startPoint: .top, endPoint: .bottom)
        /// Subtle fill for machined card containers — the background layer under
        /// the coreInnerHighlight stroke. Matches all per-view inline cards.
        /// 0.035 → 0.045 (macOS 27 overhaul): the darker canvas needs cards a
        /// step more present to keep the same perceived layering.
        /// Card sites chain .fill(cardFill).strokeBorder(coreInnerHighlight) on ONE
        /// shape view (goal-2 merge, 2026-07-16): identical pixels to the old
        /// 2-shape ZStack, one less view+layer per card — switch-commit work.
        static let cardFill             = Color.white.opacity(0.045)
    }

    // MARK: Gradients
    enum Gradient {
        static let brand = LinearGradient(colors: [Palette.accent, Palette.accent2],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)
        /// The canvas wash — base layer of `DSCanvasBackground` and the detail
        /// sheet's owner-drawn root (QA snapshot path needs an opaque backing).
        static let bg = LinearGradient(colors: [Palette.bgTop, Palette.bgBottom],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - DSCanvasBackground
/// The app's window canvas (macOS 27 overhaul, 2026-07-16): the deep slate wash
/// plus a faint crimson aurora bleeding from the top edge — the brand identity
/// breathing through the dark, and the depth Liquid Glass materials need behind
/// them to read as glass at all. Kept faint (screen-blended 0.08) so it frames
/// content without ever competing with it.
struct DSCanvasBackground: View {
    var body: some View {
        ZStack {
            DS.Gradient.bg
            RadialGradient(colors: [DS.Palette.accent.opacity(0.08), .clear],
                           center: .top, startRadius: 0, endRadius: 640)
                .blendMode(.screen)
        }
        .compositingGroup()
    }
}

// MARK: - Components
// Parent-app components with zero standalone consumers (CircleIconButton,
// SuggestionCard, SuperGrokBadge, Primary/Secondary/PressableStyle, the Bezel
// view) were deleted in the macOS 27 overhaul (2026-07-16) — verified dead by
// repo-wide grep including StockSageTests. The DS.Bezel token namespace stays:
// the card recipes consume it inline.

// MARK: - Card
struct Card<Content: View>: View {
    var padding: CGFloat = DS.Space.md
    var radius: CGFloat = DS.Radius.card
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }
}

// MARK: - Button styles
/// Gravity-pull press: 0.97 settle on the lux curve — heavier and more
/// deliberate than a plain press-curve settle. Use on tinted pill/capsule CTAs
/// that provide their own chrome (brand gradient, accent border, etc.).
/// Moved from CodeView so all tabs share one definition. (Marathon EN)
struct LuxPressStyle: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .scaleEffect(c.isPressed ? 0.97 : 1)
            .animation(DS.Motion.lux, value: c.isPressed)
    }
}

// MARK: - Eyebrow
struct Eyebrow: View {
    let text: String
    var color: Color = DS.Palette.accent

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(2)
            .foregroundStyle(color.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(
                LinearGradient(colors: [color.opacity(0.40), color.opacity(0.08)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.5))
    }
}

// MARK: - Elevation helper
extension View {
    func dsShadow(_ e: (color: Color, radius: CGFloat, y: CGFloat)) -> some View {
        shadow(color: e.color, radius: e.radius, y: e.y)
    }

    /// RTL-aware block layout for PLAIN-text LLM output: when `text` contains
    /// Arabic script, flips to right-to-left + trailing alignment (mirrors the
    /// verified `LiveTranscriptionView.lineView` pattern — the outer `.frame`
    /// resolves `.trailing` in the parent LTR context = the right edge, while the
    /// inner layoutDirection gives the text correct RTL bidi). Latin/English is a
    /// pure no-op (LTR + leading). NOT for Markdown/code surfaces — those need
    /// structural bidi (code blocks must stay LTR), handled separately.
    func rtlAware(_ text: String) -> some View {
        let rtl = text.range(of: "\\p{Arabic}", options: .regularExpression) != nil
        return environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
    }
}

// STANDALONE DEVIATION (extraction @ fc8f383): the parent's CloudKeyHintBanner (a
// Chat/Code-tab LLM cloud-key notice referencing LocalLLM) was removed here — it is not a
// Markets component and the standalone has no LLM stack. No Markets view referenced it.

// MARK: - DSSegmentPicker
/// Dark-themed sliding-pill segment control. Replaces `.pickerStyle(.segmented)` app-wide.
/// Selection indicator slides between segments via `matchedGeometryEffect`.
/// Usage: `DSSegmentPicker(cases: MyEnum.allCases, selection: $binding) { $0.title }`
struct DSSegmentPicker<T: Hashable>: View {
    let cases: [T]
    @Binding var selection: T
    let label: (T) -> String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(cases, id: \.self) { item in
                Button {
                    withAnimation(DS.Motion.spring) { selection = item }
                } label: {
                    Text(label(item))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == item ? Color.black : Color.white.opacity(0.62))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selection == item {
                                Capsule()
                                    .fill(Color.white.opacity(0.92))
                                    .matchedGeometryEffect(id: "segPill", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().stroke(
            LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)],
                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

