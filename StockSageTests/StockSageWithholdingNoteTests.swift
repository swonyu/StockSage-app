import Testing
@testable import StockSage

// MARK: - US dividend-withholding honesty note (pure)

struct StockSageWithholdingNoteTests {
    @Test func usSymbolCarriesTheNote() {
        let note = StockSageWithholdingNote.note(for: "AAPL")
        #expect(note?.contains("30%") == true)
        #expect(note?.contains("not tax advice") == true)
    }

    @Test func saudiEquityIsNil() {
        #expect(StockSageWithholdingNote.note(for: "2222.SR") == nil)
    }

    @Test func saudiIndexIsNil() {
        #expect(StockSageWithholdingNote.note(for: "^TASI.SR") == nil)
    }
}
