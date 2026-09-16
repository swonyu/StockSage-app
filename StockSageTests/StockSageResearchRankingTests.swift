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
                                                  system: StockSageResearchRanking.instructions(horizon: horizon, version: 1),
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

    @Test func rankingDiagnosticsGroupTransientAndLengthRetriesWithoutChangingTheSelection() async throws {
        typealias Server = StockSageLocalModelServer
        typealias Store = StockSageResearchDiagnostics
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        let local = Server.Config(baseURL: URL(string: Server.lmStudioURL)!, model: Server.gemmaModel)
        var posts = 0, limits: [Int] = []
        let result = await Ranking.rank(scan: fixtureScan(["AAA", "BBB"]), horizon: .fortnight,
            config: local, isOllama: false, allowed: { true }, diagnostics: store, modelTransport: { request in
                if request.httpMethod == "GET" {
                    #expect(request.url?.path == "/api/v1/models")
                    let inventory = StockSageManagedModelLifecycleTests.installed.replacingOccurrences(of: "\"loaded_instances\":[]",
                        with: #""loaded_instances":[{"id":"\#(Server.gemmaModel)","config":{"context_length":262144,"parallel":1}}]"#)
                    return (Data(inventory.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                posts += 1
                let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                limits.append(try #require(body["max_tokens"] as? Int))
                if posts == 1 { throw URLError(.networkConnectionLost) }
                let response = try JSONSerialization.data(withJSONObject: ["model": Server.gemmaModel,
                    "choices": [["message": ["content": posts == 2 ? "" : #"{"symbols":["BBB","AAA"]}"#],
                                 "finish_reason": posts == 2 ? "length" : "stop"]]])
                return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let receipt = try result.get()
        #expect(receipt.symbols == ["BBB", "AAA"] && posts == 3 && limits == [256, 256, 512])
        let round = try #require(receipt.rounds.first)
        let id = try #require(round.diagnosticID)
        #expect(round.diagnosticsComplete == true && Ranking.valid(receipt))
        let entries = await Store(directory: dir).entries(for: id)
        #expect(entries.allSatisfy { $0.context.id == id && $0.context.symbol == nil && $0.context.horizon == 14 && $0.context.purpose == .ranking })
        let attempts = entries.compactMap(\.attempt)
        #expect(attempts.count == 6 && Set(attempts.map(\.callID)).count == 3)
        #expect(attempts.filter { $0.stage == .finished }.map(\.outputLimit) == limits)
        #expect(attempts.filter { $0.stage == .finished }.compactMap { $0.diagnostic?.finish } == [.absent, .tokenLimit, .stop])
        #expect(entries.last?.outcome?.state == .accepted && entries.last?.complete == true)
        let encoded = try JSONEncoder().encode(receipt)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("responseBody"))
    }

    @Test func rankingDiagnosticStorageFailureDoesNotDiscardValidComparison() async throws {
        let result = await Ranking.rank(scan: fixtureScan(["AAA", "BBB"]), horizon: .week,
            config: config, isOllama: false, allowed: { true },
            diagnostics: StockSageResearchDiagnostics(directory: nil), completion: { _, _, _ in
                self.response(["BBB", "AAA"])
            })
        let receipt = try result.get()
        #expect(receipt.symbols == ["BBB", "AAA"] && Ranking.valid(receipt))
        #expect(receipt.rounds.first?.diagnosticID != nil && receipt.rounds.first?.diagnosticsComplete == false)
    }

    @Test(arguments: [false, true])
    func rankingDiagnosticOutcomeDistinguishesInvalidOutputFromCancellation(cancel: Bool) async throws {
        typealias Store = StockSageResearchDiagnostics
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        var allowed = true, posts = 0
        let result = await Ranking.rank(scan: fixtureScan(["AAA", "BBB"]), horizon: .week,
            config: config, isOllama: false, allowed: { allowed }, diagnostics: store, modelTransport: { request in
                posts += 1
                if cancel { allowed = false }
                let body = try JSONSerialization.data(withJSONObject: ["model": self.config.model,
                    "choices": [["message": ["content": #"{"symbols":["AAA","AAA"]}"#], "finish_reason": "stop"]]])
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        #expect(posts == 1 && result == .failure(cancel ? .cancelled : .invalidOutput))
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        let file = try #require(files.first)
        let id = try #require(UUID(uuidString: file.deletingPathExtension().lastPathComponent))
        let entries = await store.entries(for: id)
        #expect(files.count == 1 && entries.allSatisfy { $0.context.id == id && $0.context.horizon == 7 && $0.context.purpose == .ranking })
        #expect(entries.compactMap(\.attempt).count == 2)
        #expect(entries.last?.outcome?.state == (cancel ? .cancelled : .rejected))
        #expect(entries.last?.complete == true)
        if !cancel {
            #expect(entries.compactMap(\.attempt).last?.diagnostic?.finish == .stop,
                    "A completed HTTP/model reply is distinct from valid ranking output")
        }
    }

    @Test func legacyRankingRoundOmitsNewDiagnosticFieldsAndReencodesIdentically() throws {
        let receipt = Ranking.Receipt.fixture(scan: fixtureScan(["AAA", "BBB"]), symbols: ["AAA", "BBB"], horizon: .week, at: at)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(receipt)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("diagnostic"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("earningsWindow"))
        let restored = try JSONDecoder().decode(Ranking.Receipt.self, from: bytes)
        #expect(restored == receipt && Ranking.valid(restored))
        #expect(try encoder.encode(restored) == bytes)
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = (0..<48).map { String(format: "S%03d", $0) }
        let scan = fixtureScan(names.reversed(), caseText: String(repeating: "Dated supporting case. ", count: 25))
        var seen = Set<String>(), calls = 0
        let result = await Ranking.rank(scan: scan, horizon: .fortnight, config: config, isOllama: false, allowed: { true }, diagnostics: StockSageResearchDiagnostics(directory: dir), completion: { system, user, _ in
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
        #expect(Set(receipt.rounds.compactMap(\.diagnosticID)).count == receipt.rounds.count)
        #expect(receipt.rounds.allSatisfy { $0.diagnosticsComplete == true })
        #expect(Ranking.valid(receipt))
    }

    @Test(arguments: [false, true])
    func uncitedEarningsWindowRemainsMandatoryWhenCitationsAreTrimmed(trim: Bool) async throws {
        var scan = fixtureScan(["AAA", "BBB", "CCC", "DDD", "EEE", "FFF"])
        let window = StockSageMassiveEarnings.Window.factPrefix
            + "listed projected date 2026-11-05 is outside the holding window; release time is unknown."
        for symbol in scan.results.keys {
            scan.results[symbol]?.facts = [trim ? String(repeating: "oversized source record ", count: 1_000) : "Dated cited fact \(symbol)", window]
        }
        let result = await Ranking.rank(scan: scan, horizon: .fortnight, config: config, isOllama: false,
            allowed: { true }, completion: { _, user, _ in
                for packet in self.packets(in: user) {
                    #expect(packet["earningsWindow"] as? String == window)
                    #expect(packet["evidence"] as? [String] == ["F1"], "The new window is intentionally not cited by the assessment")
                    #expect((packet["citedFacts"] as? [[String: String]])?.count == (trim ? 0 : 1))
                    #expect(packet["omittedCitedFacts"] as? Int == (trim ? 1 : 0))
                }
                return self.response(Array(self.symbols(in: user).prefix(5)))
            })
        let receipt = try result.get()
        #expect(receipt.version == Ranking.currentVersion && Ranking.valid(receipt))
        let restored = try JSONDecoder().decode(Ranking.Receipt.self, from: JSONEncoder().encode(receipt))
        #expect(restored == receipt && Ranking.valid(restored))
    }

    @Test(arguments: ["duplicate", "empty", "oversized"])
    func invalidEarningsWindowFailsBeforeRankingRequests(_ invalid: String) async {
        var scan = fixtureScan(["AAA"])
        let prefix = StockSageMassiveEarnings.Window.factPrefix
        switch invalid {
        case "duplicate": scan.results["AAA"]?.facts += [prefix + "inside", prefix + "outside"]
        case "empty": scan.results["AAA"]?.facts.append(prefix + " \n")
        default: scan.results["AAA"]?.facts.append(prefix + String(repeating: "x", count: 4_096))
        }
        var requests = 0
        let result = await Ranking.rank(scan: scan, horizon: .fortnight, config: config, isOllama: false,
            allowed: { true }, completion: { _, _, _ in
                requests += 1
                return self.response(["AAA"])
            })
        #expect(result == .failure(.invalidCandidates) && requests == 0)
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

    @Test func rankingReceiptRejectsIncompleteOrReusedDiagnosticReferences() async throws {
        let names = (0..<48).map { String(format: "S%03d", $0) }
        let result = await Ranking.rank(
            scan: fixtureScan(names, caseText: String(repeating: "Dated supporting case. ", count: 25)),
            horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, user, _ in
                self.response(Array(self.symbols(in: user).sorted(by: >).prefix(5)))
            })
        let original = try result.get()
        try #require(original.rounds.count >= 2 && Ranking.valid(original))
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        let legacy = try #require(body["rounds"] as? [[String: Any]])
        func decode(_ rounds: [[String: Any]]) throws -> Ranking.Receipt {
            var object = body
            object["rounds"] = rounds
            return try JSONDecoder().decode(Ranking.Receipt.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(legacy.allSatisfy { $0["diagnosticID"] == nil && $0["diagnosticsComplete"] == nil })
        #expect(Ranking.valid(try decode(legacy)))
        let paired = legacy.enumerated().map { index, row in
            var copy = row
            copy["diagnosticID"] = UUID().uuidString
            copy["diagnosticsComplete"] = index.isMultiple(of: 2)
            return copy
        }
        #expect(Ranking.valid(try decode(paired)), "Both complete and incomplete retention references are valid")
        for corruption in ["id-only", "complete-only", "incomplete-only", "reused-id"] {
            var altered = paired
            switch corruption {
            case "id-only": altered[0].removeValue(forKey: "diagnosticsComplete")
            case "complete-only": altered[0].removeValue(forKey: "diagnosticID")
            case "incomplete-only":
                altered[0].removeValue(forKey: "diagnosticID")
                altered[0]["diagnosticsComplete"] = false
            default: altered[1]["diagnosticID"] = altered[0]["diagnosticID"]
            }
            #expect(!Ranking.valid(try decode(altered)), "Diagnostic reference corruption: \(corruption)")
        }
    }

    // MARK: Task 4 — evidence selection must never drop a whole fact class

    /// Confirmed risk: the byte-fair trim fills each candidate's allowance in evidence order, so a
    /// single oversized technical record could consume the whole share and silently remove the only
    /// insider SALE record from the comparison packet. An insider sale is exactly the evidence that
    /// must never disappear because it is inconvenient or late in the array.
    @Test func everyFactClassSurvivesTheRankingTrimAndOmissionsAreSummarisedPerClass() async throws {
        let names = ["AAA", "BBB", "CCC", "DDD", "EEE", "FFF"]
        var scan = fixtureScan(names)
        let mandatory = Ranking.Receipt.fixture(scan: scan, symbols: Array(names.prefix(5)), horizon: .week, at: at).rounds[0]
        let available = StockSageLocalModelServer.maximumUserBytes(system: mandatory.system, outputTokens: 256, contextTokens: 16_384)
            - mandatory.user.precomposedStringWithCanonicalMapping.utf8.count
        try #require(available > 2_000)
        // One huge technical record first, then the short insider sale and lead records.
        let huge = String(repeating: "T", count: available)
        for symbol in names {
            scan.results[symbol]?.facts = [
                huge,
                "Form 4: officer SALE of 10,000 shares on 2026-09-02, filed 2026-09-04.",
                "Imported WhatsApp lead mentioning \(symbol); author and claims unverified.",
            ]
            scan.results[symbol]?.factClasses = [.technical, .insider, .importedLead]
            scan.results[symbol]?.verdict = .init(action: .buy, reason: "Case \(symbol)", risk: "Risk \(symbol)",
                                                  evidence: ["F1", "F2", "F3"])
        }
        let result = await Ranking.rank(scan: scan, horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, user, _ in
            for packet in self.packets(in: user) {
                let symbol = packet["symbol"] as! String
                let cited = (packet["citedFacts"] as? [[String: String]]) ?? []
                let cls = (packet["classSummary"] as? [String: [String: Any]]) ?? [:]
                #expect(Set(cls.keys) == ["technical", "insider", "importedLead"],
                        "every class present in the evidence must appear in the summary for \(symbol)")
                for (name, entry) in cls { #expect(entry["total"] as? Int == 1, "\(name) total for \(symbol)") }
                // The oversized technical record cannot starve the two short classes.
                #expect(cited.contains { $0["id"] == "\(symbol):F2" },
                        "the insider SALE record must survive the trim for \(symbol)")
                #expect(cited.contains { $0["id"] == "\(symbol):F3" },
                        "the imported lead record must survive the trim for \(symbol)")
                let technicalOmitted = (cls["technical"]?["omittedIDs"] as? [String]) ?? []
                #expect(technicalOmitted == ["\(symbol):F1"],
                        "the dropped oversized technical record must be named, not silently absent")
            }
            return self.response(Array(names.prefix(5)))
        })
        #expect(Ranking.valid(try result.get()))
    }

    /// An imported lead is a claim, not evidence. Ranking must be able to see that it is a lead.
    @Test func importedLeadStaysLabelledUnverifiedInTheRankingPacket() async throws {
        let names = ["AAA", "BBB", "CCC", "DDD", "EEE"]
        var scan = fixtureScan(names)
        for symbol in names {
            scan.results[symbol]?.facts = ["Imported lead about \(symbol); unverified author and claims."]
            scan.results[symbol]?.factClasses = [.importedLead]
            scan.results[symbol]?.verdict = .init(action: .buy, reason: "Case \(symbol)", risk: "Risk \(symbol)", evidence: ["F1"])
        }
        let result = await Ranking.rank(scan: scan, horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { system, user, _ in
            #expect(system.contains("unverified lead"), "the comparison instructions must define lead handling")
            for packet in self.packets(in: user) {
                let cls = (packet["classSummary"] as? [String: [String: Any]]) ?? [:]
                #expect(Set(cls.keys) == ["importedLead"])
            }
            return self.response(names)
        })
        #expect(Ranking.valid(try result.get()))
    }

    /// Absent data is uncertainty. It must be visible as a gap class and must never read as support.
    @Test func missingCoverageIsSummarisedAsAGapNotAsSupport() async throws {
        let names = ["AAA", "BBB", "CCC", "DDD", "EEE"]
        var scan = fixtureScan(names)
        for symbol in names {
            scan.results[symbol]?.facts = ["Dated technical record \(symbol)", "News coverage unavailable for \(symbol)."]
            scan.results[symbol]?.factClasses = [.technical, .coverageGap]
            scan.results[symbol]?.verdict = .init(action: .buy, reason: "Case \(symbol)", risk: "Risk \(symbol)", evidence: ["F1", "F2"])
        }
        let result = await Ranking.rank(scan: scan, horizon: .week, config: config, isOllama: false, allowed: { true }, completion: { _, user, _ in
            for packet in self.packets(in: user) {
                let cls = (packet["classSummary"] as? [String: [String: Any]]) ?? [:]
                #expect(cls["coverageGap"]?["total"] as? Int == 1, "the gap must be counted as a gap")
                #expect(cls["technical"]?["total"] as? Int == 1)
            }
            return self.response(names)
        })
        #expect(Ranking.valid(try result.get()))
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
