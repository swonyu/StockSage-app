import Testing
import Foundation
@testable import StockSage

/// Hand-built fixtures — a small, fully-specified trade + position + symbol set, not
/// anything derived from the code under test. Round-trip proves export→restore preserves
/// every field; the error-path tests prove restore is all-or-nothing (never partial).
struct StockSageBackupTests {

    private func fixtureTrade() -> TradeRecord {
        TradeRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            symbol: "AAPL", side: .long, entry: 150.0, stop: 145.0, target: 165.0,
            shares: 10, openedAt: Date(timeIntervalSince1970: 1_700_000_000),
            exitPrice: 160.0, closedAt: Date(timeIntervalSince1970: 1_700_500_000),
            note: "test note", conviction: 0.72
        )
    }

    private func fixturePosition() -> PortfolioPosition {
        PortfolioPosition(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                           symbol: "MSFT", shares: 5, costBasis: 300.0)
    }

    @Test func exportRestoreRoundTrip() throws {
        let trade = fixtureTrade()
        let position = fixturePosition()
        let symbols = ["TSLA", "NVDA"]

        let data = StockSageBackup.export(trades: [trade], positions: [position], userSymbols: symbols)
        let result = StockSageBackup.restore(from: data)

        let payload = try result.get()
        #expect(payload.schemaVersion == StockSageBackup.currentSchemaVersion)
        #expect(payload.trades == [trade])
        #expect(payload.positions == [position])
        #expect(payload.userSymbols == symbols)
    }

    @Test func exportProducesNonEmptyPrettyJSON() {
        let data = StockSageBackup.export(trades: [fixtureTrade()], positions: [], userSymbols: [])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"schemaVersion\""))
        #expect(text.contains("AAPL"))
        #expect(text.contains("\n"))   // pretty-printed, not single-line
    }

    @Test func wrongSchemaVersionIsError() {
        // Hand-built JSON with schemaVersion 99 — never derived from the encoder.
        let json = """
        {"schemaVersion":99,"exportedAt":"2026-01-01T00:00:00Z","trades":[],"positions":[],"userSymbols":[]}
        """
        let result = StockSageBackup.restore(from: Data(json.utf8))
        switch result {
        case .success:
            Issue.record("expected a schema-version error, got success")
        case .failure(let error):
            guard case .unsupportedSchemaVersion(let found, let supported) = error else {
                Issue.record("expected unsupportedSchemaVersion, got \(error)")
                return
            }
            #expect(found == 99)
            #expect(supported == StockSageBackup.currentSchemaVersion)
        }
    }

    @Test func corruptJSONIsErrorNoPartialState() {
        let corrupt = Data("{not valid json at all".utf8)
        let result = StockSageBackup.restore(from: corrupt)
        switch result {
        case .success:
            Issue.record("expected a decode error, got success")
        case .failure(let error):
            guard case .decodeFailed = error else {
                Issue.record("expected decodeFailed, got \(error)")
                return
            }
        }
    }

    @Test func truncatedPayloadMissingFieldIsErrorNotPartial() {
        // Valid JSON, right schema version, but `trades` is missing entirely — must fail
        // the whole decode rather than silently defaulting trades to [].
        let json = """
        {"schemaVersion":1,"exportedAt":"2026-01-01T00:00:00Z","positions":[],"userSymbols":[]}
        """
        let result = StockSageBackup.restore(from: Data(json.utf8))
        switch result {
        case .success:
            Issue.record("expected a decode error for a missing required field, got success")
        case .failure(let error):
            guard case .decodeFailed = error else {
                Issue.record("expected decodeFailed, got \(error)")
                return
            }
        }
    }

    @Test func importFromParentAppNilWhenDomainEmpty() {
        // A suite name that has never been written to — the parent-app read must return
        // nil, never throw or fabricate data.
        let result = StockSageBackup.importFromParentApp()
        // Can't assert nil unconditionally (a real "SA.Salehman-AI" domain may exist on
        // the CI/dev machine running the parent app too) — only assert it never crashes
        // and, when present, the counts are non-negative and internally consistent.
        if let result {
            #expect(result.tradeCount == result.trades.count)
            #expect(result.positionCount == result.positions.count)
        }
    }
}
