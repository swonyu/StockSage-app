import Testing
import Foundation
@testable import StockSage

// Tadawul bilingual names (owner request, 2026-07-16). The load-bearing assertion is COVERAGE:
// every `.SR` symbol in the analyzed universe must have a curated name — a future universe
// addition without one fails HERE instead of silently shipping a bare numeric ticker.
struct StockSageTadawulNamesTests {

    @Test func everyUniverseTadawulSymbolHasABilingualName() {
        let srSymbols = StockSageUniverse.worldwide.map(\.symbol).filter { $0.uppercased().hasSuffix(".SR") }
        #expect(!srSymbols.isEmpty)                    // the Saudi half exists (29 post-restriction)
        for s in srSymbols {
            #expect(StockSageTadawulNames.name(for: s) != nil, "missing bilingual name for \(s)")
        }
    }

    // Spot-checks pinned to the exchange's own brandings (hand-curated, not derived from code).
    @Test func wellKnownNamesAreCorrectInBothLanguages() {
        let aramco = StockSageTadawulNames.name(for: "2222.SR")
        #expect(aramco?.english == "Saudi Aramco")
        #expect(aramco?.arabic == "أرامكو السعودية")
        let rajhi = StockSageTadawulNames.name(for: "1120.sr")   // case-insensitive lookup
        #expect(rajhi?.english == "Al Rajhi Bank")
        #expect(rajhi?.arabic == "مصرف الراجحي")
        #expect(StockSageTadawulNames.displayLine(for: "7010.SR") == "stc (Saudi Telecom) · إس تي سي — الاتصالات السعودية")
    }

    // Honesty guard: unknown symbols return nil (plain-symbol fallback), never a guessed name.
    @Test func unknownAndNonTadawulSymbolsReturnNil() {
        #expect(StockSageTadawulNames.name(for: "AAPL") == nil)
        #expect(StockSageTadawulNames.name(for: "9999.SR") == nil)
        #expect(StockSageTadawulNames.displayLine(for: "MSFT") == nil)
    }
}
