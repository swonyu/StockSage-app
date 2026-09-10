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
        let records = (0..<3).map { record($0, details: String(repeating: "Attributed research opinion. ", count: 18)) }
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
        #expect(prepared.snapshot.researchStatus?.contains("\(records.count - offered.count) Benzinga records omitted.") == true)
        #expect(try encoded(captured) == before)
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
