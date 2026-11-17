import Foundation
import Testing
@testable import StockSage

@Suite("Captured Benzinga consumer boundaries")
@MainActor
struct StockSageBenzingaConsumerTests {
    private typealias B = StockSageBenzinga
    private typealias C = StockSageChat
    private let now = Date(timeIntervalSince1970: 1_788_739_200)

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func record(_ index: Int = 0, details: String = "Attributed analyst opinion, not a quote.") -> B.Record {
        .init(id: "consensus.fixture.\(index)", vendorID: nil, revision: "fixture-\(index)",
              product: .consensusRatings, symbol: "ORCL", source: "Massive/Benzinga consensus",
              date: nil, time: nil, timeZone: nil, published: nil, lastUpdated: nil,
              headline: "Analyst consensus", details: [details], excerpt: nil,
              bullCase: nil, bearCase: nil, link: nil, analystIDs: [], firmIDs: [], ratingIDs: [])
    }

    private func evidence(_ records: [B.Record] = [], symbol: String = "ORCL") -> B.Snapshot {
        .init(symbol: symbol, capturedAt: now, credentialGeneration: "fixture-epoch",
              pages: B.Product.allCases.map { product in
                  .init(query: .init(product: product, subject: symbol, from: nil, through: nil),
                        checkedAt: now, credentialGeneration: "fixture-epoch", status: .answered,
                        records: records.filter { $0.product == product }, excludedCount: 0, hasMore: false)
              })
    }

    private func chat() -> C.Snapshot {
        .init(at: now, facts: [.init(id: "ORCL.quote", subject: "ORCL", field: "observed price",
            value: "100", unit: "USD", asOf: now, source: "Massive SIP", status: "Not executable")],
            context: C.snapshotContext)
    }

    @Test func chatDisclosureDoesNotInventExclusionOrOmissionCauses() throws {
        // The aggregate excludes two rows without preserving their reasons. The retained row
        // belongs to an obsolete credential epoch, so it is omitted even with ample byte space.
        let page = B.Page(query: .init(product: .consensusRatings, subject: "ORCL", from: nil, through: nil),
            checkedAt: now, credentialGeneration: "old-epoch", status: .answered,
            records: [record()], excludedCount: 2, hasMore: false)
        let snapshot = B.Snapshot(symbol: "ORCL", capturedAt: now, credentialGeneration: "fixture-epoch", pages: [page])
        let captured = C.addingBenzinga(to: chat(), evidence: snapshot)
        let before = try encoded(captured)
        let projection = try #require(B.projection(snapshot, maximumUTF8Bytes: 12_000))
        #expect(projection.notEligibleCount == 2 && projection.trimmedRecordCount == 1)
        let prepared = try #require(C.request(question: "Explain ORCL", snapshot: captured, history: []))
        let status = try #require(prepared.snapshot.researchStatus)
        #expect(status.contains("2 not eligible at capture"))
        #expect(status.contains("eligibility or validation"))
        #expect(status.contains("1 retained records not sent in this request"))
        #expect(!status.contains("ratings 7-day") && !status.contains("no rating change"))
        #expect(!status.contains("trimmed to fit"))
        #expect(projection.statusLines.count == 9)
        for line in projection.statusLines { #expect(prepared.prompt.replacingOccurrences(of: "\\/", with: "/").contains(line)) }
        #expect(try encoded(captured) == before)
    }

    @Test func panelSeparatesExcludedCappedAndNotDisplayedCounts() {
        let projection = B.Projection(statusLines: [], records: [], omittedRecordCount: 5,
            notEligibleCount: 4, cappedRecordCount: 2)
        let lines = StockSageBenzingaEvidenceView.omissionLines(for: projection)
        #expect(lines.count == 3)
        #expect(lines.contains { $0.contains("4 records excluded") && $0.contains("eligibility or validation") })
        #expect(lines.contains { $0.contains("2 records beyond") && $0.contains("3 per product") })
        #expect(lines.contains("3 retained records not shown in this panel."))
        #expect(lines.allSatisfy { !$0.contains("model") && !$0.contains("trimmed") })
    }

    @Test func panelKeepsExclusionsVisibleWhenNoRetainedRecordWasOmitted() {
        let excluded = B.Projection(statusLines: [], records: [], omittedRecordCount: 0, notEligibleCount: 4)
        let lines = StockSageBenzingaEvidenceView.omissionLines(for: excluded)
        #expect(lines.count == 1 && lines.first?.contains("4 records excluded") == true)
        let empty = B.Projection(statusLines: [], records: [], omittedRecordCount: 0)
        #expect(StockSageBenzingaEvidenceView.omissionLines(for: empty).isEmpty)
    }

    @Test func assessmentAndNarratorUseSameCaptureWithoutInventingPublication() throws {
        let item = SageFix.idea("ORCL", conviction: 0.6, rr: 2, price: 100, riskDistance: 10)
            .withLivePrice(100, asOf: now, priceSource: .massiveSIP)
        let snapshot = evidence([record(details: "Mean target 150 USD; analyst opinion, not an observed price.")])
        let before = try encoded(snapshot)
        let base = StockSageAIAssessment.Context(idea: item, earnings: nil, company: [:], at: now)
        let enriched = StockSageAIAssessment.Context(idea: item, earnings: nil, company: [:], at: now, benzinga: snapshot)
        #expect(enriched.facts.starts(with: base.facts))
        let added = enriched.facts.dropFirst(base.facts.count).joined(separator: "\n")
        for status in try #require(B.projection(snapshot, maximumUTF8Bytes: 12_000)).statusLines {
            #expect(added.contains(status))
        }
        #expect(added.contains("150") && enriched.idea.price == 100)
        let brief = StockSageCatalystWatch.brief(for: item, inputs: .init(now: now))
        let facts = StockSageCatalystNarrator.facts(for: brief, benzinga: snapshot)
        #expect(facts.joined().contains("150"))
        #expect(!StockSageCatalystNarrator.citationsValid("As source [1] states", sourceCount: 0),
                "Undated Benzinga records do not manufacture a dated numbered source")
        #expect(snapshot.pages.flatMap(\.records).allSatisfy { $0.published == nil && $0.date == nil })
        #expect(try encoded(snapshot) == before)
    }

    @Test func chatOffersOnlyWholeCapturedRecordsAndKeepsNineStatuses() throws {
        // Each record is deliberately larger than a third of the 12,000-byte projection cap, so
        // omission is forced by that cap rather than by the whole-prompt budget. Before
        // 2026-09-11 a count of 18 sufficed only because Chat's prompt budget was 1,317 bytes;
        // when the window was raised these records all fitted and the assertion below went
        // vacuous. Tying the fixture to the projection cap keeps it honest across window changes.
        let records = (0..<3).map { record($0, details: String(repeating: "Attributed research opinion. ", count: 200)) }
        let captured = C.addingBenzinga(to: chat(), evidence: evidence(records))
        let before = try encoded(captured)
        let prepared = try #require(C.request(question: "Explain ORCL", snapshot: captured, history: []))
        #expect(prepared.prompt.utf8.count <= C.promptByteLimit)
        #expect(prepared.snapshot.facts == captured.facts)
        let capturedEvidence = try #require(captured.benzinga)
        let projection = try #require(B.projection(capturedEvidence, maximumUTF8Bytes: 12_000))
        let offered = prepared.snapshot.offeredBenzingaIDs ?? []
        let json = try #require(prepared.prompt.components(separatedBy: "\n").dropFirst().first)
        let wire = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let supplied = try #require(wire["benzinga"] as? String)
        for product in B.Product.allCases {
            #expect(supplied.contains(product.label + ":"), "Every product keeps its availability status")
        }
        #expect(projection.statusLines.count == 9)
        for item in records {
            if offered.contains(item.id) {
                #expect(prepared.prompt.contains(item.id) && prepared.prompt.contains(item.headline))
            } else {
                let body = try JSONSerialization.data(withJSONObject: ["analysis": "An analyst opinion.", "evidence": [item.id]])
                #expect(C.reply(String(decoding: body, as: UTF8.self), snapshot: prepared.snapshot).evidence.isEmpty)
            }
        }
        #expect(offered.count < records.count)
        // Count actual request omissions separately from capture exclusions. The aggregate
        // omission count does not retain a reason for every rejected or over-budget record.
        #expect(prepared.snapshot.researchStatus?.contains("\(records.count - offered.count) retained records not sent in this request.") == true,
                "status did not disclose request omissions: \(prepared.snapshot.researchStatus ?? "nil")")
        #expect(prepared.snapshot.researchStatus?.contains("not eligible at capture") == true,
                "the capture-time exclusion bucket must be stated even when it is zero")
        #expect(try encoded(captured) == before)
    }

    // A record the PARSER rejected and a record the REQUEST trimmed are different facts, and the
    // disclosure must not merge them. Before 2026-09-11 only the second was counted, so a symbol
    // with no recent analyst action read identically to a request that could not fit its evidence.
    // On the owner's real RKLB capture that is 42 records that were simply not recent, reported as
    // nothing at all, while the visible "47 omitted" came from the per-product cap and the budget.
    @Test func theDisclosureSeparatesNotEligibleFromTrimmed() throws {
        let now = Date()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = TimeZone(identifier: "UTC")
        // Older than the evidence window, DERIVED rather than a literal. A hard-coded 40 days was
        // outside the window when this test was written and inside it an hour later, when the
        // window was widened to 45 — the same rot that made three other fixtures go vacuous today.
        let staleDays = Double(B.ratingsEvidenceDays + 15)
        let stale = fmt.string(from: now.addingTimeInterval(-staleDays * 86_400))
        let row: [String: Any] = ["benzinga_id": "e1", "ticker": "ORCL", "date": stale,
            "last_updated": "\(stale)T11:00:00Z", "firm": "Fixture Firm", "rating_action": "upgrades",
            "rating": "buy", "previous_rating": "hold", "price_target": 110,
            "previous_price_target": 100, "currency": "USD", "benzinga_analyst_id": "A",
            "benzinga_firm_id": "F", "time": "07:00:00"]
        let body = try JSONSerialization.data(withJSONObject: ["status": "OK", "results": [row]])
        let page = B.parse(body, query: .init(product: .ratings, subject: "ORCL", from: nil, through: nil),
                           checkedAt: now, credentialGeneration: "epoch")
        try #require(page.records.isEmpty && page.excludedCount == 1,
                     "the fixture must actually be rejected by the recency window")

        let snapshot = B.Snapshot(symbol: "ORCL", capturedAt: now, credentialGeneration: "epoch", pages: [page])
        let projection = try #require(B.projection(snapshot, maximumUTF8Bytes: 12_000))
        #expect(projection.notEligibleCount == 1, "a recency-rejected record must be counted as not eligible")
        #expect(projection.trimmedRecordCount == 0, "nothing was trimmed; the budget was never the constraint")
        #expect(projection.cappedRecordCount == 0)
        #expect(projection.text.contains("Not eligible at capture: 1"))
    }

    @Test func completionIntersectsOfferedRecordsNotJustIDs() throws {
        let originalRecord = record()
        let captured = C.addingBenzinga(to: chat(), evidence: evidence([originalRecord]))
        var offered = captured
        offered.offeredBenzingaIDs = [originalRecord.id]
        let body = try JSONSerialization.data(withJSONObject: ["analysis": "An attributed opinion, not a price.", "evidence": [originalRecord.id]])
        for tampered in [false, true] {
            let session = StockSageChatSession(historyURL: nil)
            let id = try #require(session.begin(question: "Explain ORCL", snapshot: captured, model: "fixture"))
            if tampered { offered.benzinga = evidence([record(details: "Different unoffered evidence.")]) }
            session.finish(id: id, text: String(decoding: body, as: UTF8.self), requestSnapshot: offered)
            let turn = try #require(session.turns.first)
            #expect(turn.snapshot == captured)
            #expect(turn.evidence == (tampered ? [] : [originalRecord.id]))
        }
    }

    @Test func statusBudgetExhaustionCannotSilentlyDiscardProviderStates() async throws {
        let item = SageFix.idea("ORCL", conviction: 0.6, rr: 2, price: 100, riskDistance: 10)
            .withLivePrice(100, asOf: now, priceSource: .massiveSIP)
        let snapshot = evidence([record()])
        let base = StockSageAIAssessment.Context(idea: item, earnings: nil, company: [:], at: now)
        let enriched = StockSageAIAssessment.Context(idea: item, earnings: nil, company: [:], at: now, benzinga: snapshot)
        let ceiling = base.facts.joined(separator: "\n").utf8.count + 1
        let supplied = enriched.facts(maximumUTF8Bytes: ceiling).joined(separator: "\n")
        #expect(supplied.utf8.count > ceiling, "A caller must reject oversize mandatory statuses, not send undisclosed evidence gaps")
        for product in B.Product.allCases { #expect(supplied.contains(product.label + ":")) }

        let brief = StockSageCatalystWatch.brief(for: item, inputs: .init(now: now))
        let source = StockSageCatalystNarrator.CitedSource(date: now, source: "Fixture", title: "Fixture", snippet: "", link: nil)
        let baseSize = StockSageCatalystNarrator.facts(for: brief, sources: [source]).joined(separator: "\n").utf8.count
        let padded = StockSageCatalystNarrator.CitedSource(date: now, source: "Fixture", title: "Fixture",
            snippet: String(repeating: "x", count: 11_990 - baseSize), link: nil)
        let plain = StockSageCatalystNarrator.facts(for: brief, sources: [padded])
        try #require(plain.joined(separator: "\n").utf8.count < 12_000)
        let withEvidence = StockSageCatalystNarrator.facts(for: brief, sources: [padded], benzinga: snapshot)
        #expect(withEvidence.joined(separator: "\n").utf8.count > 12_000)
        for product in B.Product.allCases { #expect(withEvidence.joined().contains(product.label + ":")) }
        let name = "BenzingaBudget-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(StockSageLocalModelServer.Backend.onDeviceOnly.rawValue, forKey: StockSageLocalModelServer.backendKey)
        var calls = 0
        _ = await StockSageCatalystNarrator.explain(brief, sources: [padded], benzinga: snapshot,
            defaults: defaults, checkServer: { _ in calls += 1; return .init(reachable: false, isOllama: false, models: [], hasModel: false, detail: "Unexpected probe") },
            local: { calls += 1; return .unavailable("Unexpected model") },
            server: { _, _ in calls += 1; return .unavailable("Unexpected model") })
        #expect(calls == 0, "Oversize mandatory facts must fail before any model or network probe")
    }

    @Test func oldHistoryAndOneShotAttachmentRemainCompatible() throws {
        let old = chat()
        #expect(try JSONDecoder().decode(C.Snapshot.self, from: JSONEncoder().encode(old)) == old)
        #expect(C.addingBenzinga(to: old, evidence: evidence(symbol: "AAPL")).benzinga == nil)
        let session = StockSageChatSession(historyURL: nil)
        let id = try #require(session.begin(question: "Explain ORCL", snapshot: old, model: "fixture"))
        let enriched = C.addingBenzinga(to: old, evidence: evidence([record()]))
        #expect(session.attachResearch(id: id, snapshot: enriched))
        #expect(!session.attachResearch(id: id, snapshot: enriched))
        session.cancel()
        #expect(session.turns.first?.snapshot == enriched)
    }
}
