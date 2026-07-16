import AppIntents
import SwiftUI

// MARK: - App Intents (extension E9, 2026-07-16)
//
// Two read-only/kick-off intents for Shortcuts/Spotlight: "best opportunity" (speaks the
// current top idea with the SAME honesty framing the card uses — estimate, gross, not
// advice) and "run a scan" (fire-and-return; results land in the app). Nothing here
// bypasses the app's gates: no order placement, no sizing mutation, no settings writes.
// Honesty: a sample/cached board is disclosed in the dialog, never spoken as live.

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
        var provenance = ""
        if store.isSampleData { provenance = " (SAMPLE data — not live prices)" }
        else if store.loadedFromCache { provenance = " (last-session prices — not live)" }

        guard let best = StockSageExpectedValue.bestOpportunity(store.ideas, regime: store.regime,
                                                                earnings: store.earnings,
                                                                liquidity: store.liquidity,
                                                                calibration: store.convictionCalibration) else {
            return .result(dialog: "No positive-EV buy candidate right now\(provenance).")
        }
        let idea = best.idea
        let name = StockSageTadawulNames.name(for: idea.symbol).map { " (\($0.english))" } ?? ""
        let evText = String(format: "estimated EV %+.2fR gross", best.ev.evR)
        return .result(dialog: IntentDialog(stringLiteral:
            "\(idea.symbol)\(name): \(idea.advice.action.rawValue), \(evText)\(provenance). "
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
