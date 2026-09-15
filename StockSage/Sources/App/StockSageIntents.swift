import AppIntents
import SwiftUI

// MARK: - App Intents (extension E9, 2026-07-16)
//
// Two read-only/kick-off intents for Shortcuts/Spotlight: "best opportunity" (speaks the
// current top idea with the SAME honesty framing the card uses — estimate, gross, not
// advice) and "run a scan" (fire-and-return; results land in the app). Nothing here
// bypasses the app's gates: no order placement, no sizing mutation, no settings writes.
// Honesty: a sample/cached board is disclosed in the dialog, never spoken as live.

/// Spoken/glanceable provenance for the OFF-BOARD surfaces (Shortcuts + Spotlight dialog, menu
/// bar). Same precedence the idea card's `MarketsView.sourceTagLabel` uses — sample beats cached
/// beats age — and the same thresholds (60s / 3600s / 86400s), so an answer spoken about an idea
/// can never contradict the tag rendered beside it. Words, not the card's compact "3h": these
/// strings are read aloud. Same honesty rule as everywhere else — an unknown, future or
/// non-finite timestamp is disclosed as unverified, never a false "now" or a refusal to answer.
enum StockSageSpokenProvenance {

    /// Age in the words a person hears, or nil when it cannot be judged. nil is deliberate:
    /// `priceAsOf` is legitimately absent on older/test-built ideas; the caller must disclose
    /// that uncertainty while retaining the answer.
    nonisolated static func spokenAge(from asOf: Date?, now: Date) -> String? {
        guard let asOf else { return nil }
        let secs = now.timeIntervalSince(asOf)
        guard secs.isFinite, secs >= 0, secs < Double(Int.max) else { return nil }
        if secs < 60 { return "less than a minute old" }
        if secs < 3_600 { return plural(Int(secs / 60), "minute") }
        if secs < 86_400 { return plural(Int(secs / 3_600), "hour") }
        return plural(Int(secs / 86_400), "day")
    }

    /// The parenthetical the intent appends to its answer. The sample and cached wordings are the
    /// shipped strings, byte-identical; only the third branch is new.
    nonisolated static func ageClause(isSampleData: Bool, loadedFromCache: Bool,
                                      asOf: Date?, now: Date) -> String {
        if isSampleData { return " (SAMPLE data — not live prices)" }
        if loadedFromCache { return " (last-session prices — not live)" }
        guard let age = spokenAge(from: asOf, now: now) else {
            return " (price timestamp unavailable — freshness unverified)"
        }
        return " (prices \(age))"
    }

    private nonisolated static func plural(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s") old"
    }
}

struct BestOpportunityIntent: AppIntent {
    static let title: LocalizedStringResource = "Best Opportunity Now"
    static let description = IntentDescription(
        "The current top-ranked idea with its estimated (gross) EV — an estimate, not advice.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = StockSageStore.shared
        guard !store.ideas.isEmpty else {
            return .result(dialog: "No ideas on the board yet — open StockSage and run Find ideas.")
        }
        // A board refreshed on Friday and asked on Sunday is NEITHER sample NOR cached
        // (`loadedFromCache` clears on the next successful refresh), so the two flags alone let a
        // days-old answer be spoken as if it were current.
        //
        // CLOSEABLE clock, not `quoteAsOf`: that one is the max across ALL symbols
        // (StockSageStore.swift:216-217 says so explicitly), so a single always-on crypto ticker
        // keeps it ~now and would make a two-day-stale equity board speak "prices less than a
        // minute old". MarketsView.swift:818 — the shipped banner — uses this same expression.
        let now = Date()
        let boardProvenance = StockSageSpokenProvenance.ageClause(
            isSampleData: store.isSampleData, loadedFromCache: store.loadedFromCache,
            asOf: store.closeableQuoteAsOf ?? store.quoteAsOf, now: now)

        guard let best = StockSageExpectedValue.bestOpportunity(store.ideas, regime: store.regime,
                                                                earnings: store.earnings,
                                                                liquidity: store.liquidity,
                                                                calibration: store.convictionCalibration) else {
            return .result(dialog: "No positive-EV buy candidate right now\(boardProvenance).")
        }
        let idea = best.idea
        let name = StockSageTadawulNames.name(for: idea.symbol).map { " (\($0.english))" } ?? ""
        let evText = String(format: "estimated EV %+.2fR gross", best.ev.evR)
        // This answer QUOTES one idea, so it is dated by that idea's OWN clock — matching the tag
        // rendered beside it on the card — not by the board-wide one.
        let ideaProvenance = StockSageSpokenProvenance.ageClause(
            isSampleData: store.isSampleData, loadedFromCache: store.loadedFromCache,
            asOf: idea.priceAsOf, now: now)
        return .result(dialog: IntentDialog(stringLiteral:
            "\(idea.symbol)\(name): \(idea.advice.action.rawValue), \(evText)\(ideaProvenance). "
            + "An estimate from conviction, not a forecast — details and sizing in StockSage."))
    }
}

struct RunScanIntent: AppIntent {
    static let title: LocalizedStringResource = "Run StockSage Scan"
    static let description = IntentDescription(
        "Starts a Find-ideas scan of the Tadawul + NASDAQ universe. Results appear in the app.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = StockSageStore.shared
        if let reason = ToolPolicy.webToolsDisabledReason() {
            return .result(dialog: IntentDialog(stringLiteral: reason))
        }
        Task { await store.refreshIdeas() }
        return .result(dialog: "Scan started — the board fills in over the next few minutes.")
    }
}

// BISECT NOTE (2026-07-16): AppShortcutsProvider registration (com.apple.linkd.autoShortcut)
// appears to hang the UNSIGNED test host at bootstrap (suite SIGTERM before connection).
// The two intents above remain fully usable from the Shortcuts app; the pre-baked Siri
// phrases below return once the app is signed. Kept compiled-out, not deleted.
#if STOCKSAGE_ENABLE_APPSHORTCUTS
struct StockSageShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BestOpportunityIntent(),
                    phrases: ["Best opportunity in \(.applicationName)",
                              "What's the best trade in \(.applicationName)"],
                    shortTitle: "Best Opportunity",
                    systemImageName: "chart.line.uptrend.xyaxis")
        AppShortcut(intent: RunScanIntent(),
                    phrases: ["Run a scan in \(.applicationName)",
                              "Find ideas in \(.applicationName)"],
                    shortTitle: "Run Scan",
                    systemImageName: "magnifyingglass")
    }
}
#endif
