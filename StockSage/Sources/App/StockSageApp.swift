import SwiftUI

// MARK: - StockSage (standalone app entry)
//
// The Markets/StockSage money engine, extracted from the "Salehman AI" app @ fc8f383 as a
// standalone macOS app. There is no tab bar here — `MarketsView` IS the app: the ideas board,
// best-opportunity card, fast lane, detail sheet, journal, and backtest are the whole product.
//
// The extraction is source-clean: the engine (StockSage/*) and the Markets views depend only on
// the DesignSystem (`DS.*`), `ToolPolicy`, and a 3-member `AppSettings` shim — none of the
// parent app's brain/agents/knowledge/voice/media code came along.
@main
struct StockSageApp: App {
    var body: some Scene {
        WindowGroup {
            MarketsView()
                .frame(minWidth: 900, minHeight: 700)
        }
        .windowResizability(.contentSize)
    }
}
