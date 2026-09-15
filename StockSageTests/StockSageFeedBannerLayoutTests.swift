#if os(macOS)
import Testing
import SwiftUI
import AppKit
@testable import StockSage

// The feed banner's answer to a degenerate width (2026-09-11).
//
// WHAT THIS PINS, and why the whole app depended on it. An unbounded
// `.fixedSize(horizontal: false, vertical: true)` Text answers a NEAR-ZERO CONCRETE width with its
// fully wrapped height, roughly one character per line. Measured, because the mechanism is narrower
// than it first appears:
//
//     uncapped sentence, no width offered ......................... 15pt
//     uncapped sentence, 24pt offered ............................ 660pt
//     the real HStack { icon; sentence; Spacer() }, 24pt ........ 2085pt
//     the same row at the real 1080pt detail width ................ 15pt
//
// Offering NO width is harmless; offering almost none is what detonates. The adjacent Spacer is an
// amplifier rather than the cause — it starves the Text of the little width there is, which is why
// the shipped row measured 2085pt where the bare sentence measured 660pt. That is also why this
// suite forces `.frame(width: 24)` instead of leaving the proposal unspecified: an unspecified
// proposal would measure 15pt and prove nothing.
//
// The resulting height became the whole NavigationSplitView's, and AppKit centred the oversized
// split view inside the real ~800pt window content area, spilling ~690pt off the top and the
// bottom: the sidebar rendered blank because its rows sat above the window's top edge, the page
// began mid-sentence, and nothing scrolled to recover either end. The app was unusable at its
// normal window size.
//
// The existing 2220-test gate passed throughout. Nothing in it measured a view's answer to a
// width-less proposal, which is why a defect this visible reached the owner.
//
// WHY THE NEGATIVE CONTROL IS HERE. `uncapped` is deliberately the same sentence WITHOUT the line
// cap. It is not the thing under test; it exists so the test cannot pass vacuously. If the
// measurement stopped being sensitive to unbounded wrapping — a different font metric, a changed
// host, an API that quietly clamps — the control stops exceeding its floor and this suite fails
// loudly instead of going green while measuring nothing.
@Suite("Feed banner — bounded height at a degenerate width", .serialized)
@MainActor
struct StockSageFeedBannerLayoutTests {

    /// Narrow enough to force the pathological wrap, and a width the real window can never offer,
    /// so this measures the sizing behaviour rather than any shipped layout.
    private static let degenerateWidth: CGFloat = 24

    /// A capped caption sentence is 3 lines of ~13pt plus the frame, so ~40pt. 120 leaves room for
    /// font-metric drift across OS releases while staying far below the control's floor.
    private static let capCeiling: CGFloat = 120

    /// At 24pt a caption fits ~4 characters, so a 150-character sentence wraps to ~40 lines
    /// (~520pt). 300 is a floor the *broken* behaviour clears easily and the fixed one cannot.
    private static let controlFloor: CGFloat = 300

    /// The real shipped sentence, from the real formatter — not a stand-in string.
    private static func liveSentence() -> String {
        let now = Date(timeIntervalSince1970: 1_757_500_000)
        return MarketsView.quoteBannerText(asOf: now.addingTimeInterval(-600),
                                           source: "Massive SIP", now: now)
    }

    /// Height the view reports when hosted at `degenerateWidth`, the same way the app hosts it.
    private func height(_ view: some View, proposedHeight: CGFloat? = nil) throws -> CGFloat {
        let host = NSHostingController(rootView: view.frame(width: Self.degenerateWidth))
        let window = FeedBannerFixtureWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The app declares .preferredColorScheme(.dark); match it so metrics match what ships.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        host.view.layoutSubtreeIfNeeded()
        if let proposedHeight {
            return host.sizeThatFits(in: CGSize(width: Self.degenerateWidth, height: proposedHeight)).height
        }
        return host.view.fittingSize.height
    }

    // MARK: The sentence that broke the window

    @Test func theLiveSentenceIsLongEnoughForTheCapToMatter() throws {
        let sentence = Self.liveSentence()
        // If this ever shrinks to a short label the cap is harmless and the rest of this suite
        // stops proving anything — so the premise is asserted, not assumed.
        #expect(sentence.count > 100,
                "the live banner sentence is now only \(sentence.count) characters; re-derive this suite's bounds")
    }

    @Test func anUncappedSentenceReallyDoesExplode_negativeControl() throws {
        let uncapped = Text(Self.liveSentence())
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        let h = try height(uncapped)
        #expect(h > Self.controlFloor,
                """
                The negative control measured \(Int(h))pt, not above \(Int(Self.controlFloor))pt. \
                This suite can no longer detect an unbounded wrap, so its passing result is \
                meaningless. Re-derive the bounds before trusting the assertion below.
                """)
    }

    @Test func theShippedBannerSentenceStaysBounded() throws {
        let h = try height(MarketsView.bannerSentence(Self.liveSentence()))
        #expect(h < Self.capCeiling,
                """
                The banner sentence answered a \(Int(Self.degenerateWidth))pt width with \(Int(h))pt. \
                An unbounded sentence here propagates to the NavigationSplitView's own height and \
                AppKit centres the oversized split view in the window, hiding the sidebar above the \
                top edge and starting the page mid-sentence. Restore the line cap.
                """)
    }

    // Every banner routes through the same helper precisely so the cap cannot be kept in two of
    // them and dropped in the third. This pins the helper's contract rather than each call site.
    @Test func theCapIsFiniteAndSmall() throws {
        let limit = try #require(MarketsView.bannerSentenceLineLimit as Int?)
        #expect(limit > 0, "a non-positive line limit does not bound anything")
        #expect(limit <= 6, "a cap this loose stops bounding the degenerate wrap")
    }

    @Test func runningResearchCannotExpandTheWholeWorkspace() async throws {
        let suite = "stocksage.research.layout.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let research = StockSageHorizonResearch()
        var held: CheckedContinuation<Void, Never>?
        let started = research.start(.week, allowed: { true }, universe: {
            .init([.init(ticker: "AAPL", name: "Synthetic Apple", market: "stocks", locale: "us",
                         active: true, type: "CS", currency_name: "usd", primary_exchange: "XNAS")])
        }, analyze: { _ in
            await withCheckedContinuation { held = $0 }
            return .init(verdict: nil, note: "Synthetic incomplete check")
        })
        try #require(started)
        defer { research.stop(); held?.resume() }
        for _ in 0..<200 where held == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(held != nil)
        let panel = StockSageResearchModesPanel(store: store, research: research,
            presentation: .constant(.init(horizon: .week)))
        let h = try height(panel, proposedHeight: 0)
        #expect(h < 900, "Research answered a transient 24pt width with \(h)pt, pushing its progress and the sidebar outside the window")
    }

    // MARK: The chat composer — the same escape route, found by sweeping for the pattern

    // WHY THESE TWO. macOS `chatLayout` is `VStack { ScrollViewReader { ScrollView { conversation } }
    // ; Divider(); composer }` — the composer is a SIBLING of the scroll view, not inside it. So its
    // height contributes directly to the chat page, which is the NavigationSplitView's detail column:
    // the exact path the feed banner's 2185pt took. Both views below sit in the composer and wrap
    // without a cap.
    //
    // `connectionNotice` is deliberately NOT tested here. It carries a far longer sentence (584
    // characters) but no `.fixedSize`, so a width-less proposal gets its one-line ideal instead of a
    // wrapped height. Absence of the modifier is what makes it safe, and that is worth stating so a
    // later reader does not "fix" it by adding one.

    @Test func theMissingModelNoticeStaysBounded() throws {
        let h = try height(StockSageChatSection.missingModelNotice(openModelSettings: {}))
        #expect(h < Self.capCeiling,
                """
                missingModelNotice answered a \(Int(Self.degenerateWidth))pt width with \(Int(h))pt.                 It renders in the composer, which sits OUTSIDE the chat ScrollView, so this height                 reaches the detail column exactly as the feed banner's did.
                """)
    }

    @Test func composerWarningsStayBounded() throws {
        // The real string the send path produces for a rejected question.
        let issue = "Use 1–2000 characters without credentials or account identifiers. Nothing was saved or sent."
        let storage = "The latest turns could not be saved locally. Check any storage warning before closing Chat."
        let h = try height(VStack { StockSageChatSection.composerWarnings(issue: issue, storageError: storage) })
        #expect(h < Self.capCeiling * 2,
                """
                composerWarnings answered a \(Int(Self.degenerateWidth))pt width with \(Int(h))pt for                 two warnings. These render outside the chat ScrollView and add straight to the                 detail column's height.
                """)
    }

    // The sample-data and cached-snapshot banners carry their own sentences. They share the
    // helper, so what has to hold is that THEIR strings are also survivable at the cap — a
    // sentence far longer than the live one would be silently truncated rather than merely wrapped.
    @Test func theOtherBannerSentencesAlsoStayBounded() throws {
        let sample = "Sample data — connecting to the live Tadawul + NASDAQ feed… The signals show the engine running on illustrative prices."
        let h = try height(MarketsView.bannerSentence(sample))
        #expect(h < Self.capCeiling, "the sample-data sentence measured \(Int(h))pt at a degenerate width")
    }
}
@MainActor private final class FeedBannerFixtureWindow: NSWindow {
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { false }
}
#endif
