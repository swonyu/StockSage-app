import Foundation
import Testing
@testable import StockSage

/// Shared, explicitly synthetic comparison provenance for offline native/history fixtures.
extension StockSageResearchRanking.Receipt {
    @MainActor static func fixture(scan: StockSageHorizonResearch.Scan, symbols: [String],
                                   horizon: StockSageHorizonResearch.Horizon, at: Date = Date()) -> Self {
        let candidates = scan.listings.map(\.ticker).filter {
            scan.results[$0]?.verdict?.action == .buy || scan.results[$0]?.verdict?.action == .strongBuy
        }.sorted()
        let packets: [[String: Any]] = candidates.map { symbol in
            let result = scan.results[symbol]!
            let verdict = result.verdict!
            var packet: [String: Any] = [
                "symbol": symbol, "action": verdict.action.rawValue, "reason": verdict.reason,
                "risk": verdict.risk, "evidence": verdict.evidence, "capturedAt": result.at.ISO8601Format(), "note": result.note,
                "coverage": result.coverage.map(\.detail), "citedFacts": [[String: String]](),
                "omittedCitedFacts": verdict.evidence.count
            ]
            if let level = result.levels {
                packet["scenario"] = ["entry": level.entry, "stop": level.stop, "target": level.target,
                                      "at": level.at.ISO8601Format(), "basis": level.basis]
            }
            if let close = result.referenceClose {
                packet["reference"] = ["value": close.value, "at": close.at.ISO8601Format()]
            }
            return packet
        }
        let user = String(data: try! JSONSerialization.data(withJSONObject: ["horizon": horizon.rawValue, "candidates": packets], options: [.sortedKeys]), encoding: .utf8)!
        let round = StockSageResearchRanking.Round(candidateSymbols: candidates,
                                                  system: StockSageResearchRanking.instructions(horizon: horizon),
                                                  user: user, symbols: symbols, model: "synthetic-test-fixture",
                                                  omittedCitedFacts: Dictionary(uniqueKeysWithValues: candidates.map { ($0, scan.results[$0]!.verdict!.evidence.count) }))
        return .init(version: 1, method: StockSageResearchRanking.wholePoolMethod, horizon: horizon.rawValue,
                     candidateSymbols: candidates, symbols: symbols, model: "synthetic-test-fixture", at: at,
                     rounds: candidates.isEmpty ? [] : [round])
    }
}

@Suite(.serialized) @MainActor struct StockSageResearchRankingTests {
    typealias Ranking = StockSageResearchRanking
    typealias Research = StockSageHorizonResearch
    private let at = Date(timeIntervalSince1970: 1_789_419_570)
    private var config: StockSageLocalModelServer.Config {
        .init(baseURL: URL(string: "http://127.0.0.1:1234")!, model: "offline-ranking-fixture")
    }

    @Test func lateBuyCanBeatEarlierStrongBuysAcrossAllCompletedChecks() async throws {
        var scan = fixtureScan(["AAA", "BBB", "CCC", "DDD", "EEE", "ZZZ"])
        scan.results["ZZZ"]?.verdict = .init(action: .buy, reason: "Best supported case", risk: "Original risk", evidence: ["F1"])
        scan.listings.append(listing("HOLD"))
        scan.results["HOLD"] = .init(verdict: .init(action: .hold, reason: "Wait", risk: "Weak case", evidence: ["F1"]), note: "Hold", at: at)
        var calls = 0
        let result = await Ranking.rank(scan: scan, horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { system, user, schema in
            calls += 1
            let ids = self.symbols(in: user)
            #expect(ids == ["AAA", "BBB", "CCC", "DDD", "EEE", "ZZZ"])
            #expect(system.contains("a Buy can rank above a Strong Buy"))
            #expect(String(decoding: schema, as: UTF8.self).contains("additionalProperties"))
            #expect(!String(decoding: schema, as: UTF8.self).contains("uniqueItems"), "The installed MLX grammar rejects uniqueItems; application validation still rejects duplicates")
            return self.response(["ZZZ", "AAA", "BBB", "CCC", "DDD"])
        })
        let receipt = try result.get()
        #expect(calls == 1)
        #expect(receipt.symbols == ["ZZZ", "AAA", "BBB", "CCC", "DDD"])
        #expect(receipt.candidateSymbols.count == 6 && receipt.method == Ranking.wholePoolMethod)
        #expect(receipt.rounds.first?.symbols == receipt.symbols && receipt.rounds.first?.model == "actual-fixture-model")
        #expect(Ranking.valid(receipt))
        #expect(try JSONDecoder().decode(Ranking.Receipt.self, from: JSONEncoder().encode(receipt)) == receipt)
        #expect(scan.results["AAA"]?.verdict?.action == .strongBuy && scan.results["ZZZ"]?.verdict?.action == .buy)
    }

    @Test func boundedRoundsConsiderEveryCandidateAndLateBestSurvives() async throws {
        let names = (0..<48).map { String(format: "S%03d", $0) }
        let scan = fixtureScan(names.reversed(), caseText: String(repeating: "Dated supporting case. ", count: 25))
        var seen = Set<String>(), calls = 0
        let result = await Ranking.rank(scan: scan, horizon: .fortnight, config: config, isOllama: false, allowed: { true }, completion: { system, user, _ in
            calls += 1
            let ids = self.symbols(in: user)
            seen.formUnion(ids)
            #expect(ids == ids.sorted())
            #expect(ids.count >= 6)
            #expect(StockSageLocalModelServer.promptFits(system: system, user: user, outputTokens: 256, contextTokens: 16_384))
            return self.response(Array(ids.sorted(by: >).prefix(5)))
        })
        let receipt = try result.get()
        #expect(calls > 1 && calls < names.count)
        #expect(seen == Set(names))
        #expect(receipt.symbols == Array(names.reversed().prefix(5)))
        #expect(receipt.method == Ranking.rollingMethod && receipt.horizon == Research.Horizon.fortnight.rawValue)
        #expect(Ranking.valid(receipt))
    }

    @Test func optionalCitationsAreWholeFairlyIncludedAndOmissionsDisclosed() async throws {
        var scan = fixtureScan(["AAA", "BBB", "CCC", "DDD", "EEE", "FFF"])
        for symbol in scan.results.keys {
            scan.results[symbol]?.facts = [String(repeating: "oversized source record ", count: 1_000), "Short dated counterevidence \(symbol)"]
            scan.results[symbol]?.verdict = .init(action: .buy, reason: "Complete original case \(symbol)", risk: "Complete original risk \(symbol)", evidence: ["F1", "F2"])
        }
        let result = await Ranking.rank(scan: scan, horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, user, _ in
            for packet in self.packets(in: user) {
                let symbol = packet["symbol"] as! String
                #expect(packet["reason"] as? String == "Complete original case \(symbol)")
                #expect(packet["risk"] as? String == "Complete original risk \(symbol)")
                #expect(packet["omittedCitedFacts"] as? Int == 1)
                let facts = packet["citedFacts"] as? [[String: String]]
                #expect(facts?.count == 1 && facts?.first?["text"] == "Short dated counterevidence \(symbol)")
                #expect(facts?.first?["id"] == "\(symbol):F2")
            }
            return self.response(Array(self.symbols(in: user).prefix(5)))
        })
        let receipt = try result.get()
        #expect(receipt.rounds.first?.omittedCitedFacts.values.allSatisfy { $0 == 1 } == true)
        #expect(Ranking.valid(receipt))
    }

    @Test func oneLargeCitationCannotTakeTheInitialEvidenceAllowanceOfOtherCandidates() async throws {
        let names = ["AAA", "BBB", "CCC", "DDD", "EEE", "FFF"]
        var scan = fixtureScan(names)
        let mandatory = Ranking.Receipt.fixture(scan: scan, symbols: Array(names.prefix(5)), horizon: .week, at: at).rounds[0]
        let available = StockSageLocalModelServer.maximumUserBytes(system: mandatory.system, outputTokens: 256, contextTokens: 16_384)
            - mandatory.user.precomposedStringWithCanonicalMapping.utf8.count
        try #require(available > 1_000)
        scan.results["AAA"]?.facts = [String(repeating: "L", count: available * 3 / 4)]
        for symbol in names.dropFirst() {
            scan.results[symbol]?.facts = [String(repeating: "P", count: available / 8)]
        }
        let result = await Ranking.rank(scan: scan, horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, user, _ in
            for packet in self.packets(in: user) {
                let symbol = packet["symbol"] as! String
                let facts = packet["citedFacts"] as? [[String: String]]
                #expect(facts?.count == (symbol == "AAA" ? 0 : 1), "Each shorter peer must retain its whole cited record when only the large first record exceeds a fair share")
                #expect(packet["omittedCitedFacts"] as? Int == (symbol == "AAA" ? 1 : 0))
            }
            return self.response(Array(names.prefix(5)))
        })
        #expect(Ranking.valid(try result.get()))
    }

    @Test func allOriginalCitationsRemainWhenTheFullEvidencePackFits() async throws {
        let names = ["AAA", "BBB", "CCC", "DDD", "EEE", "FFF"]
        var scan = fixtureScan(names)
        let mandatory = Ranking.Receipt.fixture(scan: scan, symbols: Array(names.prefix(5)), horizon: .week, at: at).rounds[0]
        let available = StockSageLocalModelServer.maximumUserBytes(system: mandatory.system, outputTokens: 256, contextTokens: 16_384)
            - mandatory.user.precomposedStringWithCanonicalMapping.utf8.count
        try #require(available > 1_000)
        let large = String(repeating: "L", count: available * 3 / 4)
        scan.results["AAA"]?.facts = [large]
        let result = await Ranking.rank(scan: scan, horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, user, _ in
            for packet in self.packets(in: user) {
                #expect(packet["omittedCitedFacts"] as? Int == 0)
                let facts = packet["citedFacts"] as? [[String: String]]
                #expect(facts?.count == 1)
                if packet["symbol"] as? String == "AAA" { #expect(facts?.first?["text"] == large) }
            }
            return self.response(Array(names.prefix(5)))
        })
        #expect(Ranking.valid(try result.get()))
    }

    @Test(arguments: [
        "{\"symbols\":[\"AAA\",\"AAA\",\"CCC\",\"DDD\",\"EEE\"]}",
        "{\"symbols\":[\"FOREIGN\",\"BBB\",\"CCC\",\"DDD\",\"EEE\"]}",
        "{\"symbols\":[\"AAA\",\"BBB\",\"CCC\",\"DDD\"]}",
        "{\"symbols\":[\"AAA\",\"BBB\",\"CCC\",\"DDD\",\"EEE\",\"FFF\"]}",
        "{\"symbols\":[\"AAA\",\"BBB\",\"CCC\",\"DDD\",\"EEE\"],\"reason\":\"New financial prose\"}",
        "```json\n{\"symbols\":[\"AAA\",\"BBB\",\"CCC\",\"DDD\",\"EEE\"]}\n```",
        "{\"symbols\":[\"AAA\",true,3,null,\"EEE\"]}", "{malformed"
    ]) func invalidModelSelectionNeverFallsBackToOriginalOrder(_ text: String) async {
        let result = await Ranking.rank(scan: fixtureScan(["AAA", "BBB", "CCC", "DDD", "EEE", "FFF"]), horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, _, _ in
            .success(.init(text: text, diagnostic: .init(finish: .stop)))
        })
        #expect(result == .failure(.invalidOutput))
    }

    @Test func incompleteOutputAndModelFailureCannotPublishPicks() async {
        let scan = fixtureScan(["AAA", "BBB"])
        for finish in [StockSageLocalModelServer.Finish.tokenLimit, .toolCall, .filtered, .unknown, .malformed] {
            let result = await Ranking.rank(scan: scan, horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, _, _ in
                .success(.init(text: "{\"symbols\":[\"AAA\",\"BBB\"]}", diagnostic: .init(finish: finish)))
            })
            #expect(result == .failure(.invalidOutput))
        }
        let failed = await Ranking.rank(scan: scan, horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, _, _ in
            .failure(.init(diagnostic: .init(category: .unavailable)))
        })
        #expect(failed == .failure(.modelFailure))
    }

    @Test(arguments: [false, true]) func transientComparisonFailureRetriesOnceWithIdenticalEvidence(persistent: Bool) async throws {
        let scan = fixtureScan(["AAA", "BBB"])
        var calls = 0
        var inputs: [String] = []
        let result = await Ranking.rank(scan: scan, horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { system, user, schema in
            calls += 1
            inputs.append(system + user + String(decoding: schema, as: UTF8.self))
            if calls == 1 || persistent { return .failure(.init(diagnostic: .init(category: .http, httpStatus: 500))) }
            return self.response(["BBB", "AAA"])
        })
        #expect(calls == 2 && Set(inputs).count == 1)
        if persistent { #expect(result == .failure(.modelFailure)) }
        else { #expect(try result.get().symbols == ["BBB", "AAA"]) }
    }

    @Test func oversizedMandatoryCandidateFailsBeforeAnyModelRequest() async {
        let scan = fixtureScan(["AAA", "BBB", "CCC", "DDD", "EEE", "ZZZ"], caseText: String(repeating: "Full mandatory case ", count: 2_000))
        var requests = 0
        let result = await Ranking.rank(scan: scan, horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, _, _ in
            requests += 1; return self.response(["AAA", "BBB", "CCC", "DDD", "EEE"])
        })
        #expect(result == .failure(.contextBudget) && requests == 0)
    }

    @Test func tooLargeSixCandidateReductionFailsWithoutDroppingRecords() async {
        let scan = fixtureScan(["AAA", "BBB", "CCC", "DDD", "EEE", "FFF", "GGG"], caseText: String(repeating: "Whole original case. ", count: 130))
        var requests = 0
        let result = await Ranking.rank(scan: scan, horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, _, _ in
            requests += 1; return self.response(["AAA", "BBB", "CCC", "DDD", "EEE"])
        })
        #expect(result == .failure(.contextBudget) && requests == 0)
    }

    @Test(arguments: [false, true]) func lateReplyIsRejectedAfterAccessRevocationOrCancellation(_ cancel: Bool) async throws {
        var access = true
        var held: CheckedContinuation<StockSageLocalModelServer.CompletionResult, Never>?
        let task = Task { @MainActor in
            await Ranking.rank(scan: fixtureScan(["AAA", "BBB"]), horizon: .week, config: config, isOllama: false, allowed: { access }, completion: { _, _, _ in
                await withCheckedContinuation { held = $0 }
            })
        }
        for _ in 0..<100 where held == nil { await Task.yield() }
        guard let continuation = held else {
            task.cancel()
            Issue.record("The comparison never reached the injected completion seam")
            return
        }
        if cancel { task.cancel() } else { access = false }
        continuation.resume(returning: response(["AAA", "BBB"]))
        #expect(await task.value == .failure(.cancelled))
    }

    @Test func emptyPoolNeedsNoModelAndSmallPoolCannotInventFiveSlots() async throws {
        var calls = 0
        let empty = await Ranking.rank(scan: .init(), horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, _, _ in
            calls += 1; return self.response([])
        })
        let emptyReceipt = try empty.get()
        #expect(calls == 0 && emptyReceipt.symbols.isEmpty && emptyReceipt.rounds.isEmpty && Ranking.valid(emptyReceipt))
        let small = await Ranking.rank(scan: fixtureScan(["AAA", "BBB"]), horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, _, _ in
            self.response(["BBB", "AAA"])
        })
        #expect(try small.get().symbols == ["BBB", "AAA"])
    }

    @Test func receiptValidationRejectsMissingParticipantAndChangedProvenance() throws {
        let scan = fixtureScan(["AAA", "BBB", "CCC", "DDD", "EEE", "FFF"])
        let receipt = Ranking.Receipt.fixture(scan: scan, symbols: ["FFF", "AAA", "BBB", "CCC", "DDD"], horizon: .week, at: at)
        #expect(Ranking.valid(receipt))
        let data = try JSONEncoder().encode(receipt)
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in ["symbols", "candidateSymbols", "method", "horizon", "rounds"] {
            var altered = original
            switch field {
            case "symbols": altered[field] = ["AAA", "AAA", "BBB", "CCC", "DDD"]
            case "candidateSymbols": altered[field] = ["AAA", "BBB", "CCC", "DDD", "EEE"]
            case "method": altered[field] = "validated profit ranking"
            case "horizon": altered[field] = "one day"
            default: altered[field] = [[String: Any]]()
            }
            let corrupt = try JSONDecoder().decode(Ranking.Receipt.self, from: JSONSerialization.data(withJSONObject: altered))
            #expect(!Ranking.valid(corrupt))
        }
    }

    private func fixtureScan<S: Sequence>(_ names: S, caseText: String = "Dated supporting case") -> Research.Scan where S.Element == String {
        var scan = Research.Scan()
        scan.listings = names.map { listing($0) }
        scan.at = at
        for item in scan.listings {
            scan.results[item.ticker] = .init(verdict: .init(action: .strongBuy, reason: caseText, risk: "Dated counterevidence and missing coverage", evidence: ["F1"]),
                                            levels: .init(entry: 100, stop: 95, target: 110, at: at, basis: "Captured synthetic ATR scenario"),
                                            facts: ["Dated cited fact \(item.ticker)"], note: "Completed offline fixture", at: at,
                                            model: "original-fixture-model", referenceClose: (100, at),
                                            coverage: [.init(source: "News", state: .partial, checkedAt: at)])
        }
        return scan
    }

    private func listing(_ symbol: String) -> Research.Listing {
        .init(ticker: symbol, name: symbol, market: "stocks", locale: "us", active: true,
              type: "CS", currency_name: "usd", primary_exchange: "XNAS")
    }

    private func packets(in user: String) -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String: Any])?["candidates"] as? [[String: Any]] ?? []
    }

    private func symbols(in user: String) -> [String] { packets(in: user).compactMap { $0["symbol"] as? String } }

    private func response(_ symbols: [String]) -> StockSageLocalModelServer.CompletionResult {
        let text = String(data: try! JSONSerialization.data(withJSONObject: ["symbols": symbols]), encoding: .utf8)!
        return .success(.init(text: text, diagnostic: .init(finish: .stop), model: "actual-fixture-model"))
    }
}
