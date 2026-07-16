import SwiftUI

// MARK: - Menu-bar ticker (extension E2, 2026-07-16)
//
// A glanceable MenuBarExtra over PUBLISHED StockSageStore state ONLY — zero engine calls.
// HARD RULE (learned by incident, 2026-07-16): menu-bar label/content bodies are evaluated
// during AppKit main-menu construction; calling anything with a caching/mutating side effect
// (bestOpportunity → convictionCalibration's memoized fit) re-invalidates the SwiftUI graph
// mid-construction and live-locks the app at launch (sampled: AppGraph→makeMainMenu loop,
// window never appears). The board's own ranking already ordered `store.ideas`, so the
// top-of-board rows ARE the glance — no recomputation needed or allowed here.
// Honesty: sample/cached provenance is disclosed before any row; actions shown are the
// board's advice labels; no EV figures here (estimates live in the app with full framing).
// Toggled by Settings ("stocksage.menubar.enabled", default ON); disappears when off.

struct StockSageMenuBarLabel: View {
    @ObservedObject var store: StockSageStore

    var body: some View {
        // Published state only: the top-ranked board symbol, or the bare glyph.
        if let top = store.ideas.first, !store.isSampleData {
            Label(top.symbol, systemImage: "chart.line.uptrend.xyaxis")
        } else {
            Image(systemName: "chart.line.uptrend.xyaxis")
        }
    }
}

struct StockSageMenuBarContent: View {
    @ObservedObject var store: StockSageStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Provenance first — never let a stale/sample board read as live in the menu bar.
        if store.isSampleData {
            Text("Sample data — open the app and run a scan")
        } else if store.loadedFromCache {
            Text("Last-session prices — NOT live")
        }

        if store.ideas.isEmpty {
            Text("No ideas yet — run Find ideas in the app")
        } else {
            ForEach(store.ideas.prefix(3), id: \.symbol) { idea in
                let name = StockSageTadawulNames.name(for: idea.symbol).map { " — \($0.english)" } ?? ""
                Text("\(idea.symbol)\(name): \(idea.advice.action.rawValue)")
            }
            Text("Board order — estimates and sizing in the app, not advice.")
        }

        Divider()
        Button("Open StockSage") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Quit StockSage") { NSApp.terminate(nil) }
    }
}
