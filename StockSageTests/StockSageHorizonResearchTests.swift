import Foundation
import Testing
@testable import StockSage

@Suite(.serialized) @MainActor struct StockSageHorizonResearchTests {
    typealias R = StockSageHorizonResearch
    @Test func retryOnlyFourIncompleteKeepsOther496AndComparesEveryUpdatedBuy() async throws {
        let history = StockSageResearchHistory()
        let research = R(history: history)
        let names = (0..<500).map { listing(String(format: "S%03d", $0)) }
        let started = research.start(.fortnight, allowed: { true }, universe: { .init(names) }, rank: { _, _ in .failure(.modelFailure) }, analyze: { item in
            let index = Int(item.ticker.dropFirst())!
            return .init(verdict: index >= 496 ? nil : .init(action: index == 0 ? .buy : .hold,
                reason: "Original case", risk: "Original risk", evidence: ["F1"]), facts: ["Original \(item.ticker)"], note: "Original", model: "fixture")
        })
        try #require(started)
        for _ in 0..<500 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        let original = try #require(research.scans[.fortnight])
        let originalRun = try #require(history.runs.first)
        var retried: [String] = []
        var compared = false
        let retry = research.retryIncomplete(.fortnight, allowed: { true }, parallelism: { 4 }, makeAnalysis: { item in
            retried.append(item.ticker)
            return { _ in
                .init(verdict: .init(action: .buy, reason: "New case", risk: "New risk", evidence: ["F1"]),
                    facts: ["Fresh evidence \(item.ticker)"], note: "New capture", model: "fixture")
            }
        }, rank: { scan, horizon in
            compared = true
            #expect(scan.retainedFromRunID == originalRun.id && scan.at! > originalRun.completedAt)
            #expect(scan.results.count == 500)
            for listing in names.prefix(496) {
                let old = original.results[listing.ticker]!, current = scan.results[listing.ticker]!
                #expect(current.at == old.at && current.verdict == old.verdict && current.facts == old.facts)
            }
            return .success(.fixture(scan: scan, symbols: ["S499", "S498", "S497", "S496", "S000"], horizon: horizon))
        })
        try #require(retry)
        for _ in 0..<500 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(research.running == nil && compared && retried == ["S496", "S497", "S498", "S499"])
        #expect(history.runs.count == 2 && history.runs.last == originalRun)
        #expect(history.runs.first?.retainedFromRunID == originalRun.id)
        #expect(research.scans[.fortnight]?.topBuys.map(\.ticker) == ["S499", "S498", "S497", "S496", "S000"])
        #expect(research.incompleteListings(.fortnight).isEmpty)
        #expect(R(history: history).scans[.fortnight]?.results.count == 500)
    }

    @Test func stoppingIncompleteRetryKeepsTheOriginalResearch() async throws {
        let history = StockSageResearchHistory()
        let research = R(history: history)
        let started = research.start(.week, allowed: { true }, universe: { .init([listing("AAA")]) }, analyze: { _ in .init(note: "Original unavailable check") })
        try #require(started)
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        let original = try #require(research.scans[.week])
        let records = history.runs
        var held: CheckedContinuation<Void, Never>?
        let retry = research.retryIncomplete(.week, allowed: { true }, makeAnalysis: { _ in
            { _ in await withCheckedContinuation { held = $0 }; return .init(note: "Late") }
        }, rank: { _, _ in Issue.record("Cancelled checks cannot be ranked"); return .failure(.unavailable) })
        try #require(retry)
        for _ in 0..<100 where held == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(held != nil)
        research.stop(); held?.resume()
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(history.runs == records && research.scans[.week]?.at == original.at)
        #expect(research.scans[.week]?.results["AAA"]?.note == "Original unavailable check")
    }

    @Test func failedAmendedCheckpointKeepsHoldAndAvoidResultsSaveableWithoutMoreResearch() async throws {
        let suite = "stocksage.research.amended-save.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.json")
        let checkpointURL = directory.appendingPathComponent("completed-7.json")
        let history = StockSageResearchHistory(storageURL: url, defaults: defaults)
        let research = R(history: history)
        var initialChecks = 0, preparations = 0, assessments = 0, comparisons = 0
        let started = research.start(.week, allowed: { true }, universe: { .init([listing("AAA"), listing("BBB")]) }, analyze: { item in
            initialChecks += 1
            return .init(verdict: item.ticker == "AAA" ? nil : .init(action: .avoid,
                reason: "Original case", risk: "Original risk", evidence: ["F1"]),
                facts: ["Original \(item.ticker)"], note: "Original capture", model: "fixture")
        })
        try #require(started)
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(research.running == nil && history.runs.count == 1)
        let originalRun = try #require(history.runs.first)
        let original = try #require(research.scans[.week])
        try #require(!original.needsSaving)
        var held: CheckedContinuation<Void, Never>?
        var checkpointLease: StockSageFileLock?
        defer { research.stop(); held?.resume(); withExtendedLifetime(checkpointLease) {} }
        let retried = research.retryIncomplete(.week, allowed: { true }, makeAnalysis: { item in
            preparations += 1
            #expect(item.ticker == "AAA")
            return { _ in
                assessments += 1
                await withCheckedContinuation { held = $0 }
                return .init(verdict: .init(action: .hold, reason: "Updated case", risk: "Updated risk", evidence: ["F1"]),
                    facts: ["Fresh AAA evidence"], note: "Updated capture", model: "fixture")
            }
        }, rank: { _, _ in comparisons += 1; return .failure(.unavailable) })
        try #require(retried)
        for _ in 0..<100 where held == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(held != nil)
        // The retry's original-save preflight has succeeded. Only its amended checkpoint is blocked.
        let originalCheckpoint = try Data(contentsOf: checkpointURL)
        checkpointLease = try StockSageFileLock(url: checkpointURL.appendingPathExtension("lock"))
        held?.resume(); held = nil
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(research.running == nil)
        withExtendedLifetime(checkpointLease) {}
        let revised = try #require(research.scans[.week])
        #expect(revised.results["AAA"]?.verdict?.action == .hold && revised.results["AAA"]?.facts == ["Fresh AAA evidence"])
        #expect(revised.results["BBB"]?.verdict == original.results["BBB"]?.verdict)
        #expect(revised.results["BBB"]?.at == original.results["BBB"]?.at && revised.results["BBB"]?.facts == original.results["BBB"]?.facts)
        #expect(revised.retainedFromRunID == originalRun.id && revised.at != original.at)
        #expect(revised.needsSaving && !research.canRetryTopFive(.week))
        #expect(revised.status.contains("could not be saved") && !revised.isComparing && comparisons == 0)
        #expect(history.runs == [originalRun] && history.lastError != nil)
        #expect(try Data(contentsOf: checkpointURL) == originalCheckpoint)

        checkpointLease = nil
        research.retrySave(.week)
        #expect(research.scans[.week]?.needsSaving == false && research.scans[.week]?.at == revised.at)
        #expect(initialChecks == 2 && preparations == 1 && assessments == 1 && comparisons == 0)
        #expect(history.runs.count == 2 && history.runs.last == originalRun)
        let restoredHistory = StockSageResearchHistory(storageURL: url, defaults: defaults)
        let restored = try #require(restoredHistory.completedScan(horizon: .week))
        #expect(restored.run.retainedFromRunID == originalRun.id && restored.run.predictions.isEmpty)
        #expect(restored.scan.at == revised.at && restored.scan.results["AAA"]?.verdict == revised.results["AAA"]?.verdict)
        #expect(restored.scan.results["AAA"]?.facts == ["Fresh AAA evidence"])
        #expect(restored.scan.results["BBB"]?.verdict == original.results["BBB"]?.verdict)
    }

    @Test func cloudRetryStartsWithOneSlotThenOwnsItsTwoGatherLookahead() async throws {
        let r = R()
        let names = (0..<4).map { listing("S\($0)") }
        let started = r.start(.week, allowed: { true }, universe: { .init(names) }, analyze: { item in
            .init(facts: [item.ticker], note: "Original incomplete")
        })
        try #require(started)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(2)) }
        let original = try #require(r.scans[.week])
        var capacity = 1, prepared: [String] = [], modelCalls = 0, compared = false
        var held: [String: CheckedContinuation<Void, Never>] = [:]
        defer { r.stop(); for continuation in held.values { continuation.resume() } }
        let retried = r.retryIncomplete(.week, allowed: { true }, parallelism: { capacity },
            concurrentGathering: true, makeAnalysis: { item in
                prepared.append(item.ticker)
                await withCheckedContinuation { held[item.ticker] = $0 }
                capacity = 8
                return { _ in modelCalls += 1; return .init(note: "Fresh retry") }
            }, rank: { _, _ in compared = true; return .failure(.unavailable) })
        try #require(retried)
        for _ in 0..<100 where held.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        try #require(prepared == ["S0"] && held.count == 1)
        held.removeValue(forKey: "S0")?.resume()
        for _ in 0..<100 where held.count < 2 || modelCalls < 1 { try await Task.sleep(for: .milliseconds(2)) }
        try #require(Set(held.keys) == Set(["S1", "S2"]) && prepared.count == 3 && modelCalls == 1)
        r.stop()
        held.removeValue(forKey: "S1")?.resume()
        try await Task.sleep(for: .milliseconds(5))
        #expect(r.running != nil && modelCalls == 1)
        held.removeValue(forKey: "S2")?.resume()
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(r.running == nil && prepared.count == 3 && modelCalls == 1 && !compared)
        #expect(r.scans[.week]?.at == original.at)
        #expect(names.allSatisfy { r.scans[.week]?.results[$0.ticker]?.note == "Original incomplete" })
    }

    @Test(arguments: [false, true], [false, true]) func checkpointSuccessDoesNotStrandUnsavedPredictionsAfterRelaunch(manualRetry: Bool, ranked: Bool) async throws {
        let suite = "stocksage.research.history-save.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.json")
        let lock = url.appendingPathExtension("lock")
        let history = StockSageResearchHistory(storageURL: url, defaults: defaults)
        let research = R(history: history)
        let started = research.start(.week, allowed: { true }, universe: { .init([listing("AAA")]) }, rank: { scan, horizon in
            // The checkpoint remains writable; only the history writer fails.
            try! FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
            return ranked ? .success(.fixture(scan: scan, symbols: ["AAA"], horizon: horizon)) : .failure(.unavailable)
        }, analyze: { _ in
            .init(verdict: .init(action: ranked ? .buy : .hold, reason: "Case", risk: "Risk", evidence: ["F1"]), facts: ["Original"], note: "Original", model: "fixture")
        })
        try #require(started)
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(history.runs.isEmpty && history.lastError != nil)
        let retained = try #require(history.completedScan(horizon: .week))
        #expect(retained.run.predictions.map(\.symbol) == (ranked ? ["AAA"] : []))
        if !manualRetry { try FileManager.default.removeItem(at: lock) }
        let restoredHistory = StockSageResearchHistory(storageURL: url, defaults: defaults)
        let restored = R(history: restoredHistory)
        if manualRetry {
            #expect(restored.scans[.week]?.needsSaving == true && restoredHistory.runs.isEmpty)
            try FileManager.default.removeItem(at: lock)
            restored.retrySave(.week)
        }
        #expect(restored.scans[.week]?.needsSaving == false)
        #expect(restoredHistory.runs.count == 1)
        #expect(restoredHistory.runs.first?.id == retained.run.id)
        #expect(restoredHistory.runs.first?.completedAt == retained.run.completedAt)
        #expect(restored.scans[.week]?.topBuys.map(\.ticker) == (ranked ? ["AAA"] : []))
    }

    @Test func checkpointFailureBlocksInitialComparisonAndRetryWithoutDiscardingChecks() async throws {
        let suite = "stocksage.research.unsaved.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let checkpointURL = directory.appendingPathComponent("completed-7.json")
        let corrupt = Data("{original unreadable checkpoint".utf8)
        try corrupt.write(to: checkpointURL)
        let history = StockSageResearchHistory(storageURL: directory.appendingPathComponent("history.json"), defaults: defaults)
        let research = R(history: history)
        var comparisons = 0
        let started = research.start(.week, allowed: { true }, universe: { .init([listing("AAA")]) }, rank: { _, _ in
            comparisons += 1; return .failure(.unavailable)
        }, analyze: { _ in
            .init(verdict: .init(action: .buy, reason: "Case", risk: "Risk", evidence: ["F1"]), facts: ["Original"], note: "Original", model: "fixture")
        })
        try #require(started)
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(comparisons == 0 && research.scans[.week]?.results.count == 1 && history.runs.isEmpty)
        #expect(research.scans[.week]?.status.contains("could not be saved") == true)
        #expect(research.scans[.week]?.needsSaving == true)
        let retry = research.retryTopFive(.week, allowed: { true }) { _, _ in comparisons += 1; return .failure(.unavailable) }
        #expect(!retry && comparisons == 0 && history.runs.isEmpty)
        #expect(try Data(contentsOf: checkpointURL) == corrupt)
        try FileManager.default.removeItem(at: checkpointURL)
        research.retrySave(.week)
        #expect(research.scans[.week]?.needsSaving == false && comparisons == 0)
        #expect(history.runs.count == 1 && history.completedScan(horizon: .week)?.scan.results.count == 1)
        var scan = try #require(research.scans[.week])
        scan.isComparing = true
        #expect(StockSageResearchModesPanel.emptyState(for: scan, isRunning: true).title == "Comparing research for Top 5")
    }

    @Test func failedComparisonRestoresAllChecksAndRetriesOnlyRanking() async throws {
        let history = StockSageResearchHistory()
        let research = R(history: history)
        var selections = 0, checks = 0
        let names = ["AAA", "BBB", "CCC", "DDD", "EEE", "ZZZ"].map { listing($0) }
        let started = research.start(.fortnight, allowed: { true }, universe: {
            selections += 1; return .init(names)
        }, rank: { _, _ in .failure(.modelFailure) }, analyze: { item in
            checks += 1
            return .init(verdict: .init(action: .buy, reason: "Case", risk: "Risk", evidence: ["F1"]),
                facts: ["Original fact \(item.ticker)"], note: "Original", model: "original-fixture")
        })
        try #require(started)
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        let original = try #require(history.runs.first)
        let restored = R(history: history)
        try #require(restored.canRetryTopFive(.fortnight))
        let originalScan = try #require(restored.scans[.fortnight])
        var comparisons = 0
        let retry = restored.retryTopFive(.fortnight, allowed: { true }) { scan, horizon in
            comparisons += 1
            #expect(scan.listings == originalScan.listings)
            for item in names {
                #expect(scan.results[item.ticker]?.at == originalScan.results[item.ticker]?.at)
                #expect(scan.results[item.ticker]?.facts == originalScan.results[item.ticker]?.facts)
            }
            return .success(.fixture(scan: scan, symbols: ["ZZZ", "EEE", "DDD", "CCC", "BBB"], horizon: horizon))
        }
        try #require(retry)
        let duplicate = restored.retryTopFive(.fortnight, allowed: { true }, rank: { _, _ in Issue.record("Duplicate retry"); return .failure(.unavailable) })
        #expect(!duplicate)
        for _ in 0..<100 where restored.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(selections == 1 && checks == 6 && comparisons == 1)
        #expect(history.runs.count == 2 && history.runs.last == original)
        let recovered = try #require(history.runs.first)
        #expect(recovered.originalRunID == original.id && recovered.startedAt == original.startedAt)
        #expect(recovered.completedAt > original.completedAt && recovered.ranking!.at >= original.completedAt)
        #expect(recovered.predictions.map(\.symbol) == ["ZZZ", "EEE", "DDD", "CCC", "BBB"])
        #expect(!restored.canRetryTopFive(.fortnight))
        #expect(R(history: history).scans[.fortnight]?.topBuys.map(\.ticker) == recovered.predictions.map(\.symbol))
    }

    @Test(arguments: [false, true]) func retryRejectsLateAnswerAfterSettingsChangeOrStop(cancel: Bool) async throws {
        let history = StockSageResearchHistory()
        let research = R(history: history)
        let started = research.start(.week, allowed: { true }, universe: { .init([listing("AAA")]) }, rank: { _, _ in .failure(.modelFailure) }, analyze: { _ in
            .init(verdict: .init(action: .buy, reason: "Case", risk: "Risk", evidence: ["F1"]), facts: ["Fact"], note: "Original", model: "fixture")
        })
        try #require(started)
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        let before = history.runs
        var held: CheckedContinuation<Void, Never>?
        var allowed = true
        let retry = research.retryTopFive(.week, allowed: { allowed }) { scan, horizon in
            await withCheckedContinuation { held = $0 }
            return .success(.fixture(scan: scan, symbols: ["AAA"], horizon: horizon))
        }
        try #require(retry)
        for _ in 0..<100 where held == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(held != nil)
        if cancel { research.stop() } else { allowed = false }
        held?.resume()
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(history.runs == before && research.scans[.week]?.topBuys.isEmpty == true)
        #expect(research.canRetryTopFive(.week))
    }

    @Test func bothHorizonsShareOneSelectionAndOneSymbolWorkerAndSaveIndependentRuns() async throws {
        let history = StockSageResearchHistory(storageURL: nil)
        let research = R(history: history)
        defer { research.stop() }
        let names = [listing("AAPL"), listing("MSFT")]
        var selections = 0, captures = 0
        let started = research.start(R.Horizon.allCases, allowed: { true }, universe: {
            selections += 1; return .init(names)
        }, rank: { scan, horizon in
            .success(.fixture(scan: scan, symbols: ["AAPL", "MSFT"], horizon: horizon))
        }, analyze: { item, horizon in
            if horizon == .week { captures += 1 }
            let verdict = StockSageAIAssessment.Verdict(action: .buy, reason: "Fixture", risk: "Fixture", evidence: ["F1"])
            return .init(verdict: verdict, facts: ["One capture \(item.ticker)"], note: horizon.rawValue, model: "fixture")
        })
        try #require(started)
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(research.running == nil)
        #expect(selections == 1 && captures == 2)
        #expect(history.runs.count == 2)
        #expect(Set(history.runs.map(\.horizon)) == [.week, .fortnight])
        for horizon in R.Horizon.allCases { #expect(research.scans[horizon]?.topBuys.map(\.ticker) == ["AAPL", "MSFT"]) }
    }

    @Test func stoppingBothHorizonsDoesNotSaveAPartialRun() async throws {
        let history = StockSageResearchHistory(storageURL: nil)
        let owningResearch = R(history: history)
        defer { owningResearch.stop() }
        var resume: CheckedContinuation<Void, Never>?
        let started = owningResearch.start(R.Horizon.allCases, allowed: { true }, universe: { .init([listing("AAPL")]) }, analyze: { _, _ in
            await withCheckedContinuation { resume = $0 }
            return .init(note: "late")
        })
        try #require(started)
        for _ in 0..<100 where resume == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(resume != nil)
        owningResearch.stop(); resume?.resume()
        for _ in 0..<100 where owningResearch.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(owningResearch.running == nil && history.runs.isEmpty)
        #expect(owningResearch.scans.values.allSatisfy { $0.results.isEmpty })
    }

    @Test func stoppingSecondComparisonPreservesTheFirstRankedRun() async throws {
        let history = StockSageResearchHistory(storageURL: nil)
        let owner = R(history: history)
        defer { owner.stop() }
        var resume: CheckedContinuation<Void, Never>?
        let started = owner.start(R.Horizon.allCases, allowed: { true }, universe: { .init([listing("AAPL")]) }, rank: { scan, horizon in
            if horizon == .fortnight { await withCheckedContinuation { resume = $0 } }
            return .success(.fixture(scan: scan, symbols: ["AAPL"], horizon: horizon))
        }, analyze: { _, horizon in
            .init(verdict: .init(action: .buy, reason: "Case", risk: "Risk", evidence: ["F1"]), facts: ["Captured fact"], note: horizon.rawValue, model: "fixture")
        })
        try #require(started)
        for _ in 0..<100 where resume == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(resume != nil)
        #expect(history.runs.count == 1 && history.runs.first?.horizon == .week)
        owner.stop(); resume?.resume()
        for _ in 0..<100 where owner.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(owner.scans[.week]?.results["AAPL"] != nil)
        #expect(owner.scans[.week]?.status.hasPrefix("Scan finished") == true && !owner.isRunning(.week))
        #expect(owner.scans[.fortnight]?.results.count == 1 && owner.scans[.fortnight]?.topBuys.isEmpty == true)
        #expect(history.runs.count == 1)
    }

    @Test(arguments: [true, false])
    func cancellationOrSettingsChangeRejectsLateComparison(cancel: Bool) async throws {
        let history = StockSageResearchHistory(storageURL: nil)
        let research = R(history: history)
        var allowed = true
        var held: CheckedContinuation<Void, Never>?
        defer { research.stop(); held?.resume() }
        let started = research.start(.week, allowed: { allowed }, universe: { .init([listing("AAPL")]) }, rank: { scan, horizon in
            await withCheckedContinuation { held = $0 }
            return .success(.fixture(scan: scan, symbols: ["AAPL"], horizon: horizon))
        }, analyze: { _ in
            .init(verdict: .init(action: .buy, reason: "Case", risk: "Risk", evidence: ["F1"]), facts: ["Dated fact"], note: "Fixture", model: "fixture")
        })
        try #require(started)
        for _ in 0..<100 where held == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(held != nil)
        #expect(research.scans[.week]?.results.count == 1 && research.scans[.week]?.topBuys.isEmpty == true)
        #expect(history.runs.isEmpty, "Checks alone cannot publish or save final top picks")
        if cancel { research.stop() } else { allowed = false }
        let release = held; held = nil; release?.resume()
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        let scan = try #require(research.scans[.week])
        #expect(research.running == nil && history.runs.isEmpty && scan.topBuys.isEmpty)
        #expect(scan.results.count == 1 && scan.rankingFailure != nil)
        #expect(!scan.status.contains("remaining listings were not checked"))
        #expect(StockSageResearchModesPanel.emptyState(for: scan, isRunning: false).title == "Top five comparison unavailable")
    }

    @Test func lastHorizonUsesIsolatedPreferencesAndExplicitHomeChoiceClearsSelection() throws {
        let name = "stocksage.research.presentation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        typealias P = StockSageResearchModesPanel.Presentation
        #expect(P.restore(from: defaults) == .week)
        P.save(.fortnight, to: defaults)
        #expect(P.restore(from: defaults) == .fortnight)
        defaults.set("unrecognized", forKey: "stocksage.research.horizon")
        #expect(P.restore(from: defaults) == .week)
        let explicit = P(horizon: .week)
        #expect(explicit.horizon == .week && explicit.search.isEmpty && explicit.selected == nil)
    }

    @Test func cancelledPreflightKeepsPreviousRankedPicks() async throws {
        let research = R()
        var held: CheckedContinuation<Void, Never>?
        defer { research.stop(); held?.resume() }
        let started = research.start(.week, allowed: { true }, universe: { .init([listing("AAPL")]) }, rank: { scan, horizon in
            .success(.fixture(scan: scan, symbols: ["AAPL"], horizon: horizon))
        }, analyze: { _ in
            .init(verdict: .init(action: .buy, reason: "Case", risk: "Risk", evidence: ["F1"]), facts: ["Original fact"], note: "Original")
        })
        try #require(started)
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        let original = try #require(research.scans[.week])
        try #require(original.topBuys.map(\.ticker) == ["AAPL"])
        let restarted = research.start(.week, allowed: { true }, universe: {
            await withCheckedContinuation { held = $0 }
            return .init([])
        }, analyze: { _ in .init(note: "Must not run") })
        try #require(restarted)
        for _ in 0..<100 where held == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(held != nil)
        research.stop()
        let release = held; held = nil; release?.resume()
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        let retained = try #require(research.scans[.week])
        #expect(retained.ranking == original.ranking && retained.rankingFailure == nil)
        #expect(retained.topBuys == original.topBuys && retained.results["AAPL"]?.facts == ["Original fact"])
        #expect(retained.status.contains("Earlier scan data retained"))
    }

    @Test func filtersKeepAllChecksAndTopFiveUsesOnlyCompletedComparisonOrder() {
        var scan = R.Scan()
        scan.listings = ["BUY1", "HOLD", "STRONG1", "INCOMPLETE", "STRONG2", "BUY2",
                         "STRONG3", "BUY3", "SELL", "AVOID", "REDUCE", "UNCHECKED"].map { listing($0) }
        func result(_ action: TradeAdvice.Action) -> R.Result {
            .init(verdict: .init(action: action, reason: "Fixture", risk: "Fixture", evidence: ["F1"]), note: "Fixture")
        }
        scan.results = ["BUY1": result(.buy), "HOLD": result(.hold), "STRONG1": result(.strongBuy),
            "INCOMPLETE": .init(note: "Unverified draft: Buy"), "STRONG2": result(.strongBuy),
            "BUY2": result(.buy), "STRONG3": result(.strongBuy), "BUY3": result(.buy),
            "SELL": result(.sell), "AVOID": result(.avoid), "REDUCE": result(.reduce)]
        typealias Panel = StockSageResearchModesPanel
        let filters: [(Panel.ResultFilter, [String])] = [
            (.all, scan.listings.map(\.ticker)), (.topBuys, []),
            (.buys, ["BUY1", "STRONG1", "STRONG2", "BUY2", "STRONG3", "BUY3"]),
            (.hold, ["HOLD"]), (.avoid, ["AVOID"]),
            (.incomplete, ["INCOMPLETE"]), (.unchecked, ["UNCHECKED"])
        ]
        for (filter, expected) in filters {
            #expect(Panel.filteredListings(scan, search: "", filter: filter).map(\.ticker) == expected)
        }
        #expect(scan.topBuys.isEmpty, "First-arriving buys are never presented as the best five")
        #expect(Panel.emptyState(for: scan, isRunning: true).title == "Top five after the full scan")
        #expect(Panel.filteredListings(scan, search: " buy3 ", filter: .all).map(\.ticker) == ["BUY3"])
        scan.results["UNCHECKED"] = .init(note: "Completed without an opinion")
        let originalListings = scan.listings
        let originalResults = Set(scan.results.keys)
        let ranked = ["BUY3", "STRONG2", "BUY1", "STRONG3", "STRONG1"]
        scan.ranking = .fixture(scan: scan, symbols: ranked, horizon: .week)
        #expect(scan.topBuys.map(\.ticker) == ranked, "A later Buy may rank above earlier Strong Buys")
        #expect(Panel.filteredListings(scan, search: " \n").map(\.ticker) == ranked)
        #expect(Panel.filteredListings(scan, search: " buy1 ").map(\.ticker) == ["BUY1"])
        #expect(Panel.filteredListings(scan, search: "BUY2").isEmpty, "Search never promotes an unselected candidate")
        #expect(scan.listings == originalListings && Set(scan.results.keys) == originalResults)
        #expect(Panel.emptyState(for: scan, isRunning: true, search: "absent", filter: .hold).title == "No matching checks")
        #if os(macOS)
        #expect(Panel.Presentation().filter == .all)
        #else
        #expect(Panel.Presentation().filter == .topBuys)
        #endif
    }

    @Test func completedOpinionRemainsVisibleWhileSecondHorizonChecksSameStock() async throws {
        let research = R()
        var held: CheckedContinuation<Void, Never>?
        defer { research.stop(); held?.resume() }
        let started = research.start(R.Horizon.allCases, allowed: { true }, universe: {
            .init([listing("AAPL"), listing("MSFT")])
        }, analyze: { _, horizon in
            if horizon == .fortnight { await withCheckedContinuation { held = $0 } }
            return .init(verdict: .init(action: .hold, reason: "Fixture", risk: "Fixture", evidence: []), note: "Fixture")
        })
        try #require(started)
        for _ in 0..<100 where held == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(held != nil && research.activeSymbol == "AAPL")
        let week = try #require(research.scans[.week])
        let fortnight = try #require(research.scans[.fortnight])
        #expect(research.isRunning(.week))
        #expect(StockSageResearchModesPanel.resultLabel("AAPL", research: research, scan: week, horizon: .week) == "Hold")
        #expect(StockSageResearchModesPanel.resultLabel("AAPL", research: research, scan: fortnight, horizon: .fortnight) == "Checking…")
    }

    @Test(arguments: 0..<5)
    func fewerThanFiveBuysAreNeverFilledWithOtherActions(count: Int) {
        var scan = R.Scan()
        scan.listings = (0..<count).map { listing("BUY\($0)") } + [listing("HOLD"), listing("MISSING")]
        for item in scan.listings where item.ticker.hasPrefix("BUY") {
            scan.results[item.ticker] = .init(verdict: .init(action: .buy, reason: "Fixture", risk: "Fixture", evidence: ["F1"]), note: "Fixture")
        }
        scan.results["HOLD"] = .init(verdict: .init(action: .hold, reason: "Fixture", risk: "Fixture", evidence: ["F1"]), note: "Fixture")
        scan.results["MISSING"] = .init(note: "No opinion")
        scan.ranking = .fixture(scan: scan, symbols: (0..<count).map { "BUY\($0)" }, horizon: .week)
        #expect(scan.topBuys.map(\.ticker) == (0..<count).map { "BUY\($0)" })
    }

    @Test func topBuysStayIndependentAcrossBothActualScanStores() async throws {
        let research = R()
        defer { research.stop() }
        let names = [listing("AAPL"), listing("MSFT"), listing("NVDA")]
        for horizon in R.Horizon.allCases {
            let started = research.start(horizon, allowed: { true }, universe: { .init(names) }, rank: { scan, horizon in
                .success(.fixture(scan: scan, symbols: horizon == .week ? ["MSFT"] : ["AAPL"], horizon: horizon))
            }, analyze: { item in
                let action: TradeAdvice.Action = horizon == .week
                    ? (item.ticker == "MSFT" ? .buy : .hold)
                    : (item.ticker == "AAPL" ? .strongBuy : .hold)
                return .init(verdict: .init(action: action, reason: "Fixture", risk: "Fixture", evidence: ["F1"]), note: "Fixture")
            })
            #expect(started)
            for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
            try #require(research.running == nil)
        }
        #expect(research.scans[.week]?.topBuys.map(\.ticker) == ["MSFT"])
        #expect(research.scans[.fortnight]?.topBuys.map(\.ticker) == ["AAPL"])
        for horizon in R.Horizon.allCases {
            #expect(research.scans[horizon]?.listings == names)
            #expect(research.scans[horizon]?.results.count == names.count)
        }
    }

    @Test func researchDetailsKeepExplanationSeparateFromExactDiagnostics() {
        let note = "No verified opinion. Numerical claims failed validation. validation=nonASCIINumber server=completed status=200"
        let parts = StockSageResearchModesPanel.notePresentation(note)
        #expect(parts.explanation == "No verified opinion. Numerical claims failed validation.")
        #expect(parts.diagnostics == "validation=nonASCIINumber server=completed status=200")
        let omission = "2 of 7 optional evidence records were omitted to fit the context budget."
        let limited = StockSageResearchModesPanel.notePresentation(note + " " + omission)
        #expect(limited.explanation == parts.explanation + "\n" + omission)
        #expect(limited.diagnostics == parts.diagnostics)
        for plain in ["No verified opinion. History missing.", "Unvalidated Qwen research.", "", "A server=word is not a recognized receipt"] {
            let result = StockSageResearchModesPanel.notePresentation(plain)
            #expect(result.explanation == plain && result.diagnostics == nil)
        }
    }

    @Test func failedModelRequestsHaveHumanCausesAndPreserveReceipts() {
        typealias S = StockSageLocalModelServer
        let cases: [(S.FailureCategory?, String)] = [
            (.invalidConfig, "URL or model ID"), (.unavailable, "could not be reached"),
            (.modelMissing, "requested model"), (.unsupportedModel, "requested model"),
            (.nonHTTP, "could not be reached"), (.http, "rejected the request"),
            (.malformedJSON, "could not read"), (.responseShape, "could not read"),
            (.missingContent, "empty answer"), (.emptyContent, "empty answer"),
            (.timeout, "within the request deadline"), (.cancelled, "cancelled"),
            (.network, "could not be reached"), (.obsoleteRequest, "settings changed"),
            (.policyDenied, "turned off"), (.responseTooLarge, "more data"),
            (.contextBudget, "context size"), (.incompleteOutput, "before finishing"),
            (nil, "did not complete")
        ]
        let omission = "2 of 7 optional evidence records were omitted to fit the context budget."
        for (category, expected) in cases {
            let diagnostic = S.Diagnostic(category: category, httpStatus: category == .http ? 503 : nil)
            let reply: S.CompletionResult = .failure(.init(diagnostic: diagnostic))
            let summary = StockSageAIAssessments.failureSummary(reply, facts: [], leadCount: 0)
            #expect(summary.contains(expected))
            let note = "No verified opinion. " + summary + " " + omission
            let parts = StockSageResearchModesPanel.notePresentation(note)
            #expect(parts.explanation.contains(expected))
            #expect(parts.explanation.hasSuffix(omission))
            #expect(!parts.explanation.contains("server="))
            #expect(parts.diagnostics == diagnostic.summary)
        }
        for unknown in ["No verified opinion. This server=word is part of the explanation.",
                        "No verified opinion.\nserver=not-an-app-category status=unknown"] {
            let parts = StockSageResearchModesPanel.notePresentation(unknown)
            #expect(parts.explanation == unknown && parts.diagnostics == nil)
        }
    }
    let now = ISO8601DateFormatter().date(from: "2026-09-09T15:00:00Z")!
    func listing(_ symbol: String = "AAPL") -> R.Listing {
        .init(ticker: symbol, name: symbol, market: "stocks", locale: "us", active: true,
              type: "CS", currency_name: "usd", primary_exchange: "XNAS")
    }
    func history() -> StockSagePriceHistory {
        let dates = (0..<35).map { now.addingTimeInterval(Double($0 - 35) * 86400) }
        return .init(symbol: "AAPL", dates: dates, opens: Array(repeating: 100, count: 35),
            highs: Array(repeating: 102, count: 35), lows: Array(repeating: 98, count: 35),
            closes: Array(repeating: 100, count: 35), volumes: Array(repeating: 1000, count: 35), priceSource: .massiveDaily)
    }
    @Test func requestBindsHostPathAndHeaderWithoutLeakingKey() throws {
        let r = try #require(R.referenceRequest(key: "synthetic-test-only"))
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-only")
        #expect(!r.url!.absoluteString.contains("synthetic-test-only"))
        #expect(r.url!.absoluteString.contains("limit=1000"))
        #expect(R.referenceRequest(key: "x", next: "https://api.massive.com/v3/reference/tickers?cursor=next") != nil)
        for bad in ["http://api.massive.com/v3/reference/tickers", "https://evil.test/v3/reference/tickers",
                    "https://api.massive.com.evil.test/v3/reference/tickers", "https://user@api.massive.com/v3/reference/tickers",
                    "https://api.massive.com:444/v3/reference/tickers", "https://api.massive.com/v3/other",
                    "https://api.massive.com/v3/reference/tickers#fragment"] {
            #expect(R.referenceRequest(key: "x", next: bad) == nil)
        }
    }
    @Test func dailyRequestsRequireExactDatesAndKeepResearchShareClasses() throws {
        for symbol in ["BRK.B", "ETF-X"] {
            let request = try #require(R.dailyHistoryRequest(symbol: symbol, from: "2024-02-29", to: "2026-09-23", key: "synthetic-test-only"))
            #expect(request.url?.path == "/v2/aggs/ticker/\(symbol)/range/1/day/2024-02-29/2026-09-23")
            #expect(request.url?.host == "api.massive.com" && request.url?.scheme == "https")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-only")
            #expect(request.url?.absoluteString.contains("synthetic-test-only") == false)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData && request.timeoutInterval == 30)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query == [.init(name: "adjusted", value: "true"), .init(name: "sort", value: "asc"), .init(name: "limit", value: "5000")])
        }
        for invalid in ["2026-02-29", "2026-09-31", "2026-9-01", "12026-09-11", "2026-09-11T00:00:00Z", "2026-09-11\n", "../2026-09-11", ""] {
            #expect(R.dailyHistoryRequest(symbol: "AAPL", from: invalid, to: "2026-09-23", key: "x") == nil)
            #expect(R.dailyHistoryRequest(symbol: "AAPL", from: "2026-01-01", to: invalid, key: "x") == nil)
        }
        #expect(R.dailyHistoryRequest(symbol: "AAPL", from: "2026-09-24", to: "2026-09-23", key: "x") == nil)
        for symbol in ["../AAPL", "aapl", "A..B", "AAPL?key=x"] {
            #expect(R.dailyHistoryRequest(symbol: symbol, from: "2026-09-11", to: "2026-09-23", key: "x") == nil)
        }
        for key in ["", " \n"] {
            #expect(R.dailyHistoryRequest(symbol: "AAPL", from: "2026-09-11", to: "2026-09-23", key: key) == nil)
        }
    }

    private func reviewDate(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func reviewRun(symbol: String = "ACME", horizon: StockSageResearchHistory.Horizon = .week,
                           includeReference: Bool = true) -> StockSageResearchHistory.Run {
        .init(id: UUID(), startedAt: reviewDate("2026-09-14T20:59:00Z"), completedAt: reviewDate("2026-09-14T21:00:00Z"),
            horizon: horizon, predictions: [.init(symbol: symbol, name: symbol, action: "Buy", reason: "Fixture", risk: "Fixture",
                evidence: ["F1"], facts: ["Dated fixture"], model: "fixture-model", note: "Unvalidated research",
                referencePrice: includeReference ? 200 : nil,
                referenceDate: includeReference ? reviewDate("2026-09-11T04:00:00Z") : nil, levels: nil)],
            coverage: .init(requested: 1, checked: 1, incomplete: 0, buyCount: 1, selection: nil))
    }
    private func reviewPayload(_ run: StockSageResearchHistory.Run) -> [String: Any] {
        let target = StockSageResearchHistory.targetClose(after: run.completedAt, horizon: run.horizon)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let dates = [StockSageResearchHistory.benchmarkDay(after: run.completedAt)!, calendar.startOfDay(for: target)]
        let rows: [[String: Any]] = dates.enumerated().map { index, date in
            let open = index == 0 ? 100 : 110
            let close = index == 0 ? 105 : 110
            return ["t": date.timeIntervalSince1970 * 1000, "o": open, "h": close, "l": open, "c": close, "v": 100]
        }
        return ["status": "OK", "ticker": run.predictions[0].symbol, "adjusted": true, "resultsCount": 2, "results": rows]
    }

    @Test(arguments: ["BRK.B", "ETF-X"], StockSageResearchHistory.Horizon.allCases)
    func dueReviewFetchesTheForwardBenchmarkToTargetRange(symbol: String, horizon: StockSageResearchHistory.Horizon) async throws {
        let run = reviewRun(symbol: symbol, horizon: horizon)
        let readyAt = try #require(StockSageResearchHistory.reviewAvailableAt(for: run))
        var clock = readyAt
        var calls = 0
        let result = await R.fetchReviewObservation(prediction: run.predictions[0], run: run, key: "synthetic-test-only",
            allowed: { true }, clock: { clock }, transport: { request in
                calls += 1
                let end = horizon == .week ? "2026-09-23" : "2026-10-02"
                #expect(request.url?.path == "/v2/aggs/ticker/\(symbol)/range/1/day/2026-09-15/\(end)")
                clock = readyAt.addingTimeInterval(2)
                return (try JSONSerialization.data(withJSONObject: reviewPayload(run)),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let observation = try #require(result)
        #expect(calls == 1 && observation.splitAdjusted && observation.history.priceSource == .massiveDaily)
        #expect(observation.provider == "Massive split-adjusted daily aggregates" && observation.fetchedAt == clock)
        #expect(observation.history.symbol == symbol && observation.history.opens == [100, 110] && observation.history.closes == [105, 110])
        #expect(run.predictions[0].referencePrice == 200, "Fetching a revised split basis must not rewrite the saved prediction")
        let evaluation = StockSageResearchHistory.evaluate(run.predictions[0], in: run, observation: observation, now: clock)
        #expect(evaluation.state == .evaluated)
        #expect(abs(try #require(evaluation.priceReturn) - 0.10) < 0.000000001,
                "The forward benchmark uses the next trading date's daily open, not its close or the old reference")
    }

    @Test func missingOriginalReferenceContextDoesNotBlockForwardReview() async throws {
        let run = reviewRun(includeReference: false)
        let readyAt = try #require(StockSageResearchHistory.reviewAvailableAt(for: run))
        let result = await R.fetchReviewObservation(prediction: run.predictions[0], run: run, key: "synthetic-test-only",
            allowed: { true }, clock: { readyAt }, transport: { request in
                #expect(request.url?.path == "/v2/aggs/ticker/ACME/range/1/day/2026-09-15/2026-09-23")
                return (try JSONSerialization.data(withJSONObject: reviewPayload(run)),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let observation = try #require(result)
        let evaluation = StockSageResearchHistory.evaluate(run.predictions[0], in: run, observation: observation, now: readyAt)
        #expect(evaluation.state == .evaluated && run.predictions[0].referencePrice == nil && run.predictions[0].referenceDate == nil)
    }

    @Test(arguments: ["notDue", "denied", "emptyKey", "foreignPrediction", "cancelled"])
    func reviewPreflightNeverDispatchesIneligibleRequests(reason: String) async {
        let run = reviewRun()
        let readyAt = StockSageResearchHistory.reviewAvailableAt(for: run)!
        var calls = 0
        let task = Task { @MainActor in
            if reason == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
            return await R.fetchReviewObservation(prediction: reason == "foreignPrediction" ? reviewRun(symbol: "OTHER").predictions[0] : run.predictions[0],
                run: run, key: reason == "emptyKey" ? "" : "synthetic-test-only", allowed: { reason != "denied" },
                clock: { readyAt.addingTimeInterval(reason == "notDue" ? -1 : 1) }, transport: { _ in
                    calls += 1
                    throw URLError(.unknown)
                })
        }
        #expect(await task.value == nil && calls == 0)
    }

    @Test(arguments: ["missingAdjustment", "falseAdjustment", "numericAdjustment", "stringAdjustment", "wrongTicker", "wrongCount", "pagination", "oversized", "http"])
    func reviewFetchRejectsUnverifiedResponses(failure: String) async throws {
        let run = reviewRun()
        let readyAt = try #require(StockSageResearchHistory.reviewAvailableAt(for: run))
        var payload = reviewPayload(run)
        switch failure {
        case "missingAdjustment": payload.removeValue(forKey: "adjusted")
        case "falseAdjustment": payload["adjusted"] = false
        case "numericAdjustment": payload["adjusted"] = 1
        case "stringAdjustment": payload["adjusted"] = "true"
        case "wrongTicker": payload["ticker"] = "OTHER"
        case "wrongCount": payload["resultsCount"] = 3
        case "pagination": payload["next_url"] = "https://api.massive.com/next"
        default: break
        }
        let data = failure == "oversized" ? Data(repeating: 32, count: 2_000_001) : try JSONSerialization.data(withJSONObject: payload)
        var calls = 0
        let result = await R.fetchReviewObservation(prediction: run.predictions[0], run: run, key: "synthetic-test-only",
            allowed: { true }, clock: { readyAt }, transport: { request in
                calls += 1
                return (data, HTTPURLResponse(url: request.url!, statusCode: failure == "http" ? 503 : 200, httpVersion: nil, headerFields: nil)!)
            })
        #expect(calls == 1 && result == nil)
    }

    @Test(arguments: [false, true])
    func reviewResponseIsDiscardedAfterAccessRevocationOrCancellation(cancel: Bool) async throws {
        let run = reviewRun()
        let readyAt = try #require(StockSageResearchHistory.reviewAvailableAt(for: run))
        let data = try JSONSerialization.data(withJSONObject: reviewPayload(run))
        var allowed = true
        var calls = 0
        var held: CheckedContinuation<Void, Never>?
        let task = Task { @MainActor in
            await R.fetchReviewObservation(prediction: run.predictions[0], run: run, key: "synthetic-test-only",
                allowed: { allowed }, clock: { readyAt }, transport: { request in
                    calls += 1
                    await withCheckedContinuation { held = $0 }
                    return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
        }
        defer { task.cancel(); held?.resume() }
        for _ in 0..<2000 where held == nil { await Task.yield() }
        try #require(held != nil && calls == 1)
        if cancel { task.cancel() } else { allowed = false }
        let release = held; held = nil; release?.resume()
        #expect(await task.value == nil)
    }

    // MARK: - Settled-session review window (outcome policy 2)

    private func dailyReviewRun(symbol: String = "ACME",
                                horizon: StockSageResearchHistory.Horizon = .week,
                                completed: String = "2026-09-14T21:00:00Z") -> StockSageResearchHistory.Run {
        .init(id: UUID(), startedAt: reviewDate(completed).addingTimeInterval(-60),
            completedAt: reviewDate(completed), horizon: horizon,
            predictions: [.init(symbol: symbol, name: symbol, action: "Buy", reason: "Fixture", risk: "Fixture",
                evidence: ["F1"], facts: ["Dated fixture"], model: "fixture-model", note: "Unvalidated research",
                referencePrice: 100, referenceDate: reviewDate("2026-09-11T04:00:00Z"),
                levels: .init(entry: 100, stop: 90, target: 120, at: reviewDate("2026-09-11T04:00:00Z"),
                    basis: "Captured ATR scenario"))],
            coverage: .init(requested: 1, checked: 1, incomplete: 0, buyCount: 1, selection: nil),
            measurementPolicy: .nextTradingDateSessions, outcomePolicy: .dailyBarFirstHit)
    }

    private func newYorkDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "America/New_York")!
        return formatter.string(from: date)
    }

    /// One adjusted series: the saved reference bar followed by settled monitoring sessions.
    private func dailyReviewPayload(_ run: StockSageResearchHistory.Run, sessions: [String],
                                    lastHigh: Double = 105) -> [String: Any] {
        var rows: [[String: Any]] = [["t": reviewDate("2026-09-11T04:00:00Z").timeIntervalSince1970 * 1000,
                                      "o": 100, "h": 100, "l": 100, "c": 100, "v": 100]]
        for (index, stamp) in sessions.enumerated() {
            let high = index == sessions.count - 1 ? lastHigh : 105
            rows.append(["t": reviewDate(stamp).timeIntervalSince1970 * 1000,
                         "o": 100, "h": high, "l": 95, "c": 100, "v": 100])
        }
        return ["status": "OK", "ticker": run.predictions[0].symbol, "adjusted": true,
                "resultsCount": rows.count, "results": rows]
    }

    @Test(arguments: [("2026-09-16T04:01:00Z", "2026-09-15"), ("2026-09-16T16:00:00Z", "2026-09-15"),
                      ("2026-09-17T03:59:59Z", "2026-09-15"), ("2026-09-17T04:00:00Z", "2026-09-16"),
                      ("2026-09-20T12:00:00Z", "2026-09-18"), ("2026-09-15T23:59:00Z", ""),
                      ("2026-10-05T12:00:00Z", "2026-09-23")])
    func settledReviewEndIsTheLastWhollyEndedNewYorkSessionCappedAtTheHorizon(now: String, expected: String) throws {
        let run = dailyReviewRun()
        let end = R.reviewEnd(for: run, now: reviewDate(now))
        #expect(end.map(newYorkDateString) == (expected.isEmpty ? nil : expected))
    }

    @Test func settledReviewEndWalksBackOverAHolidayAndLegacyRunsKeepTheHorizonWindow() throws {
        let overLabourDay = dailyReviewRun(completed: "2026-09-02T21:00:00Z")
        #expect(StockSageResearchHistory.benchmarkDay(after: overLabourDay.completedAt)
            .map(newYorkDateString) == "2026-09-03")
        #expect(R.reviewEnd(for: overLabourDay, now: reviewDate("2026-09-08T04:01:00Z"))
            .map(newYorkDateString) == "2026-09-04", "2026-09-07 is a published Nasdaq holiday")
        let legacy = reviewRun()
        #expect(legacy.outcomePolicy == nil)
        #expect(R.reviewEnd(for: legacy, now: reviewDate("2026-09-17T04:00:00Z"))
            == StockSageResearchHistory.targetClose(for: legacy))
    }

    @Test func dailyPolicyReviewRequestsTheSavedReferenceDateThroughTheLastSettledSession() async throws {
        let run = dailyReviewRun()
        var clock = reviewDate("2026-09-18T04:01:00Z")
        var calls = 0
        let result = await R.fetchReviewObservation(prediction: run.predictions[0], run: run,
            key: "synthetic-test-only", allowed: { true }, clock: { clock }, transport: { request in
                calls += 1
                #expect(request.url?.path.contains("/2026-09-11/2026-09-17") == true)
                #expect(request.url?.path.contains("2026-09-18") == false,
                        "A session that has not wholly ended is never requested")
                clock = clock.addingTimeInterval(2)
                return (try JSONSerialization.data(withJSONObject: dailyReviewPayload(run,
                    sessions: ["2026-09-15T04:00:00Z", "2026-09-16T04:00:00Z", "2026-09-17T04:00:00Z"],
                    lastHigh: 121)),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let observation = try #require(result)
        #expect(calls == 1 && observation.splitAdjusted && observation.history.count == 4)
        let receipt = StockSageResearchHistory.evaluate(run.predictions[0], in: run,
            observation: observation, now: clock)
        #expect(receipt.terminalKind == .targetHit && receipt.terminalAt == reviewDate("2026-09-17T04:00:00Z"))
        #expect(run.predictions[0].levels?.target == 120, "Reviewing never rewrites the captured scenario")
    }

    @Test func dailyPolicyReviewCapsTheRequestAtTheHorizonAndWaitsForTheFirstSession() async throws {
        let run = dailyReviewRun()
        var calls = 0
        let capped = await R.fetchReviewObservation(prediction: run.predictions[0], run: run,
            key: "synthetic-test-only", allowed: { true },
            clock: { self.reviewDate("2026-10-05T12:00:00Z") }, transport: { request in
                calls += 1
                #expect(request.url?.path.contains("/2026-09-11/2026-09-23") == true,
                        "The window never runs past the scheduled seventh session")
                return (try JSONSerialization.data(withJSONObject: dailyReviewPayload(run,
                    sessions: ["2026-09-15T04:00:00Z", "2026-09-16T04:00:00Z", "2026-09-17T04:00:00Z",
                               "2026-09-18T04:00:00Z", "2026-09-21T04:00:00Z", "2026-09-22T04:00:00Z",
                               "2026-09-23T04:00:00Z"])),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        #expect(calls == 1)
        let observation = try #require(capped)
        let receipt = StockSageResearchHistory.evaluate(run.predictions[0], in: run, observation: observation,
            now: reviewDate("2026-10-05T12:00:00Z"))
        #expect(receipt.terminalKind == .horizonClose && receipt.terminalAt == reviewDate("2026-09-23T04:00:00Z"))

        let tooEarly = await R.fetchReviewObservation(prediction: run.predictions[0], run: run,
            key: "synthetic-test-only", allowed: { true },
            clock: { self.reviewDate("2026-09-15T23:59:00Z") }, transport: { _ in
                calls += 1
                throw URLError(.unknown)
            })
        #expect(tooEarly == nil && calls == 1, "No request before the first monitoring session has ended")
    }

    @Test(arguments: ["denied", "cancelled", "unadjusted"])
    func dailyPolicyReviewHonoursTheSameGates(reason: String) async throws {
        let run = dailyReviewRun()
        var payload = dailyReviewPayload(run, sessions: ["2026-09-15T04:00:00Z", "2026-09-16T04:00:00Z"])
        if reason == "unadjusted" { payload["adjusted"] = false }
        let data = try JSONSerialization.data(withJSONObject: payload)
        var calls = 0
        let task = Task { @MainActor in
            if reason == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
            return await R.fetchReviewObservation(prediction: run.predictions[0], run: run,
                key: "synthetic-test-only", allowed: { reason != "denied" },
                clock: { self.reviewDate("2026-09-17T04:01:00Z") }, transport: { request in
                    calls += 1
                    return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
        }
        #expect(await task.value == nil)
        #expect(calls == (reason == "unadjusted" ? 1 : 0))
    }

    @Test func badPagesNeverBecomeCompleteCensuses() throws {
        let good = Data(#"{"status":"OK","results":[{"ticker":"BRK.B","name":"Berkshire","market":"stocks","locale":"us","active":true,"type":"CS","currency_name":"usd"}]}"#.utf8)
        #expect(try R.parsePage(good).results.first?.ticker == "BRK.B")
        for bad in [#"{"status":"ERROR","results":[]}"#, #"{"status":"OK"}"#,
                    #"{"status":"OK","results":[{"ticker":"../../secret"}]}"#] {
            #expect(throws: (any Error).self) { _ = try R.parsePage(Data(bad.utf8)) }
        }
    }
    @Test func paginationVisitsAllPagesAndRejectsUnsafeOrRepeatedContinuation() async throws {
        func payload(_ symbol: String, next: String?) throws -> Data {
            var page: [String: Any] = ["status": "OK", "count": 1, "results": [["ticker": symbol, "name": symbol,
                "market": "stocks", "locale": "us", "active": true, "type": "ETF"]]]
            if let next { page["next_url"] = next }
            return try JSONSerialization.data(withJSONObject: page)
        }
        let continuation = "https://api.massive.com/v3/reference/tickers?cursor=second"
        var calls = 0
        let all = try await R.fetchUniverse(key: "synthetic-test-only", allowed: { true }, transport: { request in
            calls += 1
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-only")
            let data = try payload(calls == 1 ? "BRK.B" : "ETF-X", next: calls == 1 ? continuation : nil)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(calls == 2 && all.map(\.ticker) == ["BRK.B", "ETF-X"])
        #expect(all.allSatisfy { $0.currency_name == nil }) // retained, not silently removed or assumed USD
        for next in ["https://evil.test/v3/reference/tickers", continuation] {
            calls = 0
            do {
                _ = try await R.fetchUniverse(key: "synthetic-test-only", allowed: { true }, transport: { request in
                    calls += 1
                    return (try payload("AAPL", next: next), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
                Issue.record("Incomplete census accepted")
            } catch { #expect(calls <= 2) }
        }
        #expect(R.referenceRequest(key: "x", next: continuation + "&apiKey=not-for-urls") == nil)
    }
    @Test func closedBarsAndLevelsAreRealBoundedAndUseExistingRules() throws {
        let h = history()
        let closed = try #require(R.completedHistory(h, at: now))
        #expect(closed == h)
        let extended = StockSagePriceHistory(symbol: h.symbol, dates: h.dates + [now, now.addingTimeInterval(86400)],
            opens: h.opens + [999,999], highs: h.highs + [999,999], lows: h.lows + [999,999],
            closes: h.closes + [999,999], volumes: h.volumes + [1,1], priceSource: .massiveDaily)
        #expect(R.completedHistory(extended, at: now) == h)
        let expected = StockSageAdvisor.stopTarget(action: .buy, price: 100, atr: 4,
            realizedVol: StockSageIndicators.annualizedVolatility(h.closes))
        for action in [TradeAdvice.Action.buy, .strongBuy] {
            let p = try #require(R.levels(history: h, action: action, at: now))
            #expect(p.entry == 100 && p.stop == expected.stop && p.target == expected.target)
            #expect(p.stop < p.entry && p.target > p.entry && p.at == h.dates.last)
        }
        #expect(R.levels(history: h, action: .hold, at: now) == nil)
        #expect(R.completedHistory(h, at: now.addingTimeInterval(5 * 86400)) == nil)
        let broken = StockSagePriceHistory(symbol: h.symbol, dates: h.dates, opens: h.opens,
            highs: [0], lows: h.lows, closes: h.closes, volumes: h.volumes, priceSource: .massiveDaily)
        #expect(R.completedHistory(broken, at: now) == nil)
    }
    @Test(arguments: [
        ("2026-09-15T20:00:00Z", "2026-09-15T04:00:00Z", false),
        ("2026-09-15T23:59:59Z", "2026-09-15T04:00:00Z", false),
        ("2026-09-16T00:00:00Z", "2026-09-15T04:00:00Z", true),
        ("2026-09-16T00:59:00Z", "2026-09-15T04:00:00Z", true),
        ("2026-11-27T21:59:59Z", "2026-11-27T05:00:00Z", false),
        ("2026-11-27T22:00:00Z", "2026-11-27T05:00:00Z", true),
        ("2026-11-03T01:00:00Z", "2026-11-02T05:00:00Z", true)
    ])
    func completedHistoryIncludesEndedAggregateSession(clock: String, today: String, includeToday: Bool) throws {
        let formatter = ISO8601DateFormatter()
        let at = try #require(formatter.date(from: clock))
        let day = try #require(formatter.date(from: today))
        var dates = [Date](), cursor = day
        while dates.count < 70 {
            if StockSageMarketHours.nasdaqDay(at: cursor)?.trading == true { dates.append(cursor) }
            cursor = cursor.addingTimeInterval(-86_400)
        }
        dates.reverse()
        let closes = Array(repeating: 153.40, count: 69) + [156.99]
        let h = StockSagePriceHistory(symbol: "AVAV", dates: dates, opens: closes,
            highs: closes.map { $0 + 2 }, lows: closes.map { $0 - 2 }, closes: closes,
            volumes: Array(repeating: 1_000, count: 70), priceSource: .massiveDaily)
        let completed = try #require(R.completedHistory(h, at: at))
        #expect(completed.count == (includeToday ? 70 : 69))
        #expect(completed.closes.last == (includeToday ? 156.99 : 153.40))
        #expect(R.levels(history: h, action: .buy, at: at)?.entry == completed.closes.last)
        if includeToday {
            let missing = StockSagePriceHistory(symbol: h.symbol, dates: Array(dates.dropLast()),
                opens: Array(h.opens.dropLast()), highs: Array(h.highs.dropLast()), lows: Array(h.lows.dropLast()),
                closes: Array(h.closes.dropLast()), volumes: Array(h.volumes.dropLast()), priceSource: .massiveDaily)
            #expect(R.completedHistory(missing, at: at) == nil, "Do not silently use yesterday after today's aggregate session ends")
        }
    }

    @Test func completedHistoryAcceptsHolidayGapsButRejectsMissingSessions() throws {
        let cases: [(String, String, Bool)] = [
            ("2026-09-08T14:00:00Z", "2026-09-04T04:00:00Z", true), // Tuesday after Labor Day; Friday is latest.
            ("2026-04-06T14:00:00Z", "2026-04-02T04:00:00Z", true), // Monday after Good Friday; Thursday is latest.
            ("2026-09-15T14:00:00Z", "2026-09-11T04:00:00Z", false), // Same 106-hour age, but Monday is missing.
            ("2027-01-19T15:00:00Z", "2027-01-15T05:00:00Z", false), // Calendar year is not verified.
            ("2027-01-06T15:00:00Z", "2027-01-05T05:00:00Z", false) // Even recent Horizon history needs the calendar.
        ]
        let formatter = ISO8601DateFormatter()
        for (clock, latest, accepted) in cases {
            let at = try #require(formatter.date(from: clock))
            let last = try #require(formatter.date(from: latest))
            let dates = (0..<35).map { last.addingTimeInterval(Double($0 - 34) * 86_400) }
            let h = StockSagePriceHistory(symbol: "AAPL", dates: dates,
                opens: Array(repeating: 100, count: 35), highs: Array(repeating: 102, count: 35),
                lows: Array(repeating: 98, count: 35), closes: Array(repeating: 100, count: 35),
                volumes: Array(repeating: 1_000, count: 35), priceSource: .massiveDaily)
            let completed = R.completedHistory(h, at: at)
            #expect((completed != nil) == accepted, "Latest completed session at \(clock)")
            if accepted { #expect(completed == h, "Preserve the original bar date and values") }
        }
    }

    @Test func promptsDifferByRequestedHorizonNotTradingPolicy() {
        #expect(R.Horizon.week.instructions.contains("1–7 trading days"))
        #expect(R.Horizon.fortnight.instructions.contains("7–14 trading days"))
        #expect(R.Horizon.week.instructions != R.Horizon.fortnight.instructions)
        #expect(R.Horizon.week.instructions.contains("research only"))
        #expect(!R.Horizon.fortnight.instructions.contains("next trading week"))
    }
    #if os(macOS)
    @Test func emptyResearchPresentationSeparatesWaitingFailureAndFilters() {
        typealias Panel = StockSageResearchModesPanel
        var scan = R.Scan()
        #expect(Panel.emptyState(for: scan, isRunning: false).title == "Your research starts here")
        #expect(Panel.emptyState(for: scan, isRunning: true).title == "Waiting for scan results")
        scan.at = now
        scan.status = "Scan incomplete: listing directory could not be verified."
        #expect(Panel.emptyState(for: scan, isRunning: false).title == "No results collected")
        #expect(Panel.emptyState(for: scan, isRunning: true).title == "Waiting for scan results")
        scan.status = "Stopping scan…"
        #expect(Panel.emptyState(for: scan, isRunning: true).title == "Waiting for scan results")
        #expect(Panel.emptyState(for: scan, isRunning: true).detail == "The current status is shown above.")
        #expect(scan.status == "Stopping scan…")
        scan.status = "Scan incomplete: listing directory could not be verified."
        scan.listings = [listing()]
        #expect(Panel.emptyState(for: scan, isRunning: true).title == "Top five after the full scan")
        #expect(Panel.emptyState(for: scan, isRunning: false).title == "Scan stopped before comparison")
        scan.results["AAPL"] = .init(verdict: .init(action: .buy, reason: "Fixture", risk: "Fixture", evidence: ["F1"]), note: "Fixture")
        scan.ranking = .fixture(scan: scan, symbols: ["AAPL"], horizon: .week)
        #expect(Panel.emptyState(for: scan, isRunning: false, search: "MSFT").title == "No matching top results")
        #expect(scan.status == "Scan incomplete: listing directory could not be verified.")
    }
    #endif
    @Test func confirmedUSShareClassPricesAreNeitherForeignCurrenciesNorMinorUnits() {
        for symbol in ["BRK.B", "TEST.L"] {
            let idea = StockSageIdea(symbol: symbol, market: "US", price: 100,
                advice: StockSageAdvisor.advise(history: history()), spark: [], generatedAt: now,
                priceAsOf: now, priceSource: .massiveDaily)
            let facts = StockSageAIAssessment.Context(idea: idea, earnings: nil, company: [:], at: now, quotedInUSD: true).facts
            #expect(facts[1].contains("Observed quote: \(StockSageCurrency.adaptivePrice(100)) USD."))
        }
    }
    @Test func historyMustConfirmIdentityAdjustmentAndCompleteParsing() throws {
        let bar: [String: Any] = ["t": now.timeIntervalSince1970 * 1000, "o": 100, "h": 102, "l": 98, "c": 100, "v": 10]
        var earlier = bar; earlier["t"] = now.addingTimeInterval(-86400).timeIntervalSince1970 * 1000
        let base: [String: Any] = ["status": "OK", "ticker": "AAPL", "adjusted": true, "resultsCount": 2, "results": [earlier, bar]]
        #expect(R.parseResearchHistory(try JSONSerialization.data(withJSONObject: base), symbol: "AAPL")?.count == 2)
        for (key, value) in [("ticker", "MSFT" as Any), ("adjusted", false as Any), ("adjusted", 1 as Any),
                             ("resultsCount", 3 as Any), ("next_url", "https://api.massive.com/next" as Any)] {
            var altered = base; altered[key] = value
            #expect(R.parseResearchHistory(try JSONSerialization.data(withJSONObject: altered), symbol: "AAPL") == nil)
        }
        var absent = base; absent.removeValue(forKey: "adjusted")
        #expect(R.parseResearchHistory(try JSONSerialization.data(withJSONObject: absent), symbol: "AAPL") == nil)
        var noVolume = bar; noVolume.removeValue(forKey: "v")
        var incomplete = base; incomplete["results"] = [earlier, noVolume]
        #expect(R.parseResearchHistory(try JSONSerialization.data(withJSONObject: incomplete), symbol: "AAPL") == nil)
    }
    @Test func dailyBoundaryUsesNewYorkAcrossDSTAndWeekend() throws {
        for (stamp, lastSession) in [("2026-03-09T04:30:00Z", "2026-03-06T05:00:00Z"),
                                     ("2026-11-02T05:30:00Z", "2026-10-30T04:00:00Z"),
                                     ("2026-09-12T15:00:00Z", "2026-09-11T04:00:00Z")] {
            let at = try #require(ISO8601DateFormatter().date(from: stamp))
            let last = try #require(ISO8601DateFormatter().date(from: lastSession))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            let today = calendar.startOfDay(for: at)
            // The final completed bar is a real session, not a synthesized Sunday candle.
            let dates = (0..<35).map { calendar.date(byAdding: .day, value: $0 - 34, to: last)! } + [today]
            let h = StockSagePriceHistory(symbol: "AAPL", dates: dates, opens: Array(repeating: 100, count: 36),
                highs: Array(repeating: 102, count: 36), lows: Array(repeating: 98, count: 36),
                closes: Array(repeating: 100, count: 36), volumes: Array(repeating: 1000, count: 36), priceSource: .massiveDaily)
            let filtered = try #require(R.completedHistory(h, at: at))
            #expect(filtered.count == 35 && filtered.dates.last == last)
            #expect(filtered.dates.allSatisfy { $0 < today })
        }
    }
    @Test func manualRunVisitsEveryListingExactlyOnceAndCannotOverlap() async throws {
        let r = R()
        let names = (0..<150).map { listing("S\($0)") }
        var seen: [String] = []
        let started = r.start(.week, allowed: { true }, universe: { .init(names) }, analyze: { value in
            seen.append(value.ticker); return .init(note: "Synthetic research only")
        })
        #expect(started)
        let overlapped = r.start(.fortnight, allowed: { true }, universe: { .init([]) }, analyze: { _ in .init(note: "must not run") })
        #expect(!overlapped)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(r.running == nil && seen == names.map(\.ticker))
        #expect(r.scans[.week]?.results.count == 150 && r.scans[.fortnight] == nil)
        let count = seen.count
        try await Task.sleep(for: .milliseconds(10))
        #expect(seen.count == count) // no timer or automatic repeat
    }
    @Test(arguments: [false, true])
    func firstPreflightStopDoesNotClaimRetainedResults(cancel: Bool) async throws {
        let r = R()
        var permitted = true
        var held: CheckedContinuation<Void, Never>?
        var analyzed = false
        let started = r.start(.week, allowed: { permitted }, universe: {
            await withCheckedContinuation { held = $0 }
            return .init([listing()])
        }, analyze: { _ in analyzed = true; return .init(note: "Must not run") })
        #expect(started)
        defer { r.stop(); held?.resume() }
        for _ in 0..<2000 where held == nil { await Task.yield() }
        try #require(held != nil)
        if cancel { r.stop() } else { permitted = false }
        let release = held; held = nil; release?.resume()
        for _ in 0..<2000 where r.running != nil { await Task.yield() }
        let scan = try #require(r.scans[.week])
        #expect(r.running == nil && !analyzed && scan.listings.isEmpty && scan.results.isEmpty)
        #expect(!scan.status.contains("completed results retained"))
        #expect(scan.status.contains(cancel ? "Stop requested" : "settings or access changed"))
        #expect(scan.status.contains("No stocks were checked"))
    }

    @Test func modelPreparationMessageSurvivesPreflightFailure() async throws {
        let r = R()
        var analyzed = false
        let started = r.start(.week, allowed: { true }, universe: {
            throw R.ScanFailure.modelUnavailable("Downloading Qwen3.5 9B · 20%.")
        }, analyze: { _ in analyzed = true; return .init(note: "Must not run") })
        #expect(started)
        for _ in 0..<2000 where r.running != nil { await Task.yield() }
        let scan = try #require(r.scans[.week])
        #expect(!analyzed && scan.listings.isEmpty && r.running == nil)
        #expect(scan.status.contains("Downloading Qwen3.5 9B · 20%") && scan.status.contains("Run again"))
    }

    @Test(arguments: ["unreachable", "invalid", "cancel", "settings"])
    func failedPreflightRetryRetainsCompletedResearch(outcome: String) async throws {
        let r = R()
        let levels = R.Levels(entry: 100, stop: 90, target: 120, at: now, basis: "Synthetic fixture")
        let receipt = StockSageResearchUniverse.Receipt(session: "2026-09-08", requestedAt: now,
            returnedCount: 1, eligibleCount: 1, directoryCount: 1, partialSession: false, dollarVolume: ["AAPL": 100])
        let first = r.start(.week, allowed: { true }, universe: { .init([listing()], receipt: receipt) },
            analyze: { _ in .init(levels: levels, facts: ["Synthetic retained evidence"],
                note: "Earlier result", at: now, model: "synthetic-model") })
        #expect(first)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil)
        let previous = try #require(r.scans[.week])
        try #require(previous.results["AAPL"]?.note == "Earlier result")
        var analyzed = false
        var permitted = true
        var resume: CheckedContinuation<Void, Never>?
        let retry = r.start(.week, allowed: { permitted }, universe: {
            if outcome == "cancel" || outcome == "settings" {
                await withCheckedContinuation { resume = $0 }
                return .init([listing("NEW")])
            }
            if outcome == "invalid" { return .init([listing(), listing()]) }
            throw URLError(.cannotConnectToHost)
        }, analyze: { _ in analyzed = true; return .init(note: "Must not run") })
        #expect(retry)
        if outcome == "cancel" || outcome == "settings" {
            for _ in 0..<100 where resume == nil { try await Task.sleep(for: .milliseconds(5)) }
            let continuation = try #require(resume)
            if outcome == "cancel" { r.stop() } else { permitted = false }
            continuation.resume()
        }
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil)
        let retained = try #require(r.scans[.week])
        #expect(!analyzed)
        #expect(retained.listings == previous.listings)
        #expect(retained.at == previous.at)
        #expect(retained.selection == receipt && retained.selection == previous.selection)
        #expect(retained.results["AAPL"]?.note == "Earlier result")
        #expect(retained.results["AAPL"]?.facts == ["Synthetic retained evidence"])
        #expect(retained.results["AAPL"]?.at == now)
        #expect(retained.results["AAPL"]?.levels == levels && retained.results["AAPL"]?.model == "synthetic-model")
        #expect(retained.status.contains("Earlier scan data retained; no new listings checked."))
        #expect(retained.status.contains(outcome == "cancel" || outcome == "settings" ? "Scan stopped" : "Scan incomplete"))
    }

    @Test func firstPreflightFailureDoesNotInventPreviousResults() async throws {
        let r = R()
        var analyzed = false
        let started = r.start(.week, allowed: { true }, universe: { throw URLError(.cannotConnectToHost) },
            analyze: { _ in analyzed = true; return .init(note: "Must not run") })
        #expect(started)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil)
        let scan = try #require(r.scans[.week])
        #expect(scan.at != nil && scan.listings.isEmpty && scan.results.isEmpty && !analyzed)
        #expect(scan.status == "Scan incomplete: the directory or dated activity response was unavailable or inconsistent. No verified selection could be made; retry after checking data access.")
    }

    @Test(arguments: [false, true])
    func acceptedDirectoryReplacesPreviousScan(empty: Bool) async throws {
        let r = R()
        let first = r.start(.week, allowed: { true }, universe: { .init([listing("OLD")]) },
            analyze: { _ in .init(note: "Earlier") })
        #expect(first)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil && r.scans[.week]?.results["OLD"] != nil)
        let requestedAfter = Date()
        let names = empty ? [] : [listing("NEW")]
        let second = r.start(.week, allowed: { true }, universe: { .init(names) },
            analyze: { _ in .init(note: "New") })
        #expect(second)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil)
        let scan = try #require(r.scans[.week])
        let requested = try #require(scan.at)
        #expect(requested >= requestedAfter && scan.listings == names)
        #expect(scan.results["OLD"] == nil && scan.results.count == names.count)
        #expect(scan.status.contains("Scan finished") && !scan.status.contains("Earlier"))
    }

    @Test(arguments: [true, false], [true, false])
    func stoppedAcceptedRetryKeepsNewPartialResultsNotOldScan(cancel: Bool, completedFirst: Bool) async throws {
        let r = R()
        let first = r.start(.week, allowed: { true }, universe: { .init([listing("OLD")]) },
            analyze: { _ in .init(note: "Earlier") })
        #expect(first)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil && r.scans[.week]?.results["OLD"] != nil)
        var permitted = true
        var resume: CheckedContinuation<Void, Never>?
        let names = completedFirst ? [listing("NEW"), listing("LATE")] : [listing("LATE")]
        let retry = r.start(.week, allowed: { permitted }, universe: { .init(names) }, analyze: { item in
            if item.ticker == "LATE" { await withCheckedContinuation { resume = $0 } }
            return .init(note: item.ticker)
        })
        #expect(retry)
        for _ in 0..<100 where resume == nil { try await Task.sleep(for: .milliseconds(5)) }
        let continuation = try #require(resume)
        #expect(r.scans[.week]?.results["NEW"]?.note == (completedFirst ? "NEW" : nil))
        if cancel { r.stop() } else { permitted = false }
        continuation.resume()
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil && r.activeSymbol == nil)
        let scan = try #require(r.scans[.week])
        #expect(scan.listings == names && Set(scan.results.keys) == (completedFirst ? ["NEW"] : []))
        #expect(scan.status.contains("Scan stopped") && !scan.status.contains("Earlier"))
    }
    @Test(arguments: R.Horizon.allCases)
    func manualRunCapsDirectoryAt500BeforeResearch(_ horizon: R.Horizon) async throws {
        let r = R()
        let names = (0..<13_000).map { listing(String(format: "S%05d", $0)) }
        var seen: [String] = []
        let started = r.start(horizon, allowed: { true }, universe: { .init(names) }, analyze: { item in
            seen.append(item.ticker)
            return .init(note: "Synthetic research only")
        })
        #expect(started)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(r.running == nil)
        #expect(seen.count == 500 && Set(seen).count == 500)
        #expect(Array(seen.prefix(500)) == names.prefix(500).map(\.ticker))
        #expect(r.scans[horizon]?.listings.count == 500)
        #expect(r.scans[horizon]?.results.count == 500)
        #expect(r.scans[horizon]?.status.contains("500 listings checked once") == true)
    }

    @Test(arguments: [false, true])
    func twoCloudGathersFeedEightModelSlotsWithoutChangingLocalScheduling(cloud: Bool) async throws {
        let r = R()
        let names = (0..<10).map { listing("S\($0)") }
        var gathers: [String: CheckedContinuation<Void, Never>] = [:]
        var models: [String: CheckedContinuation<Void, Never>] = [:]
        var prepared: [String] = [], calls: [String] = []
        var gathering = 0, peakGathering = 0, activeModels = 0, peakModels = 0, comparisons = 0
        defer {
            r.stop()
            for held in gathers.values { held.resume() }
            for held in models.values { held.resume() }
        }
        let started = r.start(R.Horizon.allCases, allowed: { true }, universe: { .init(names) },
            rank: { scan, _ in
                #expect(gathering == 0 && activeModels == 0 && scan.results.count == names.count)
                comparisons += 1; return .failure(.unavailable)
            }, parallelism: { 8 }, concurrentGathering: cloud, makeAnalysis: { item in
                prepared.append(item.ticker)
                gathering += 1; peakGathering = max(peakGathering, gathering)
                await withCheckedContinuation { gathers[item.ticker] = $0 }
                gathering -= 1
                let capturedAt = Date()
                return { horizon in
                    let key = item.ticker + horizon.rawValue
                    calls.append(key); activeModels += 1; peakModels = max(peakModels, activeModels)
                    await withCheckedContinuation { models[key] = $0 }
                    activeModels -= 1
                    return .init(facts: [item.ticker], note: horizon.rawValue, at: capturedAt)
                }
            })
        try #require(started)
        for _ in 0..<100 where gathers.count < (cloud ? 2 : 1) { try await Task.sleep(for: .milliseconds(2)) }
        #expect(gathers.count == (cloud ? 2 : 1))
        for _ in 0..<500 where models.count < 8 {
            let ready = Array(gathers.values); gathers.removeAll()
            for held in ready { held.resume() }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(models.count == 8 && prepared.count == 8)
        #expect(peakGathering == (cloud ? 2 : 1) && peakModels == 8 && comparisons == 0)
        for _ in 0..<500 where r.running != nil {
            let ready = Array(gathers.values) + Array(models.values)
            gathers.removeAll(); models.removeAll()
            for held in ready { held.resume() }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(r.running == nil && Set(prepared) == Set(names.map(\.ticker)) && prepared.count == 10)
        #expect(calls.count == 20 && Set(calls).count == 20 && comparisons == 2)
        for item in names {
            #expect(r.scans[.week]?.results[item.ticker]?.facts == [item.ticker])
            #expect(r.scans[.week]?.results[item.ticker]?.at == r.scans[.fortnight]?.results[item.ticker]?.at)
        }
    }

    @Test(arguments: [false, true])
    func cloudGatherCancellationOwnsBothPendingCaptures(cancel: Bool) async throws {
        let r = R()
        var allowed = true, modelCalls = 0, compared = false
        var gathers: [String: CheckedContinuation<Void, Never>] = [:]
        defer { r.stop(); for held in gathers.values { held.resume() } }
        let started = r.start([.week], allowed: { allowed }, universe: { .init([listing("AAA"), listing("BBB"), listing("CCC")]) },
            rank: { _, _ in compared = true; return .failure(.unavailable) },
            parallelism: { 8 }, concurrentGathering: true, makeAnalysis: { item in
                await withCheckedContinuation { gathers[item.ticker] = $0 }
                return { _ in modelCalls += 1; return .init(note: "Late capture") }
            })
        try #require(started)
        for _ in 0..<100 where gathers.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        try #require(gathers.count == 2)
        if cancel { r.stop() } else { allowed = false }
        gathers.removeValue(forKey: "AAA")?.resume()
        try await Task.sleep(for: .milliseconds(5))
        #expect(r.running != nil && modelCalls == 0 && !compared)
        let restarted = r.start(.week, allowed: { true }, universe: { .init([]) }, analyze: { _ in .init(note: "Must not run") })
        #expect(!restarted)
        gathers.removeValue(forKey: "BBB")?.resume()
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(r.running == nil && r.activeSymbols.isEmpty && modelCalls == 0 && !compared)
        #expect(r.scans[.week]?.results.isEmpty == true)
    }

    @Test func stockWorkersOverlapWithoutPreparingPastTheirBound() async throws {
        let r = R()
        var prepared: [String] = []
        var waiting: [String: CheckedContinuation<Void, Never>] = [:]
        var active = 0
        var peak = 0
        var compared = false
        let started = r.start([.week, .fortnight], allowed: { true },
            universe: { .init([listing("AAA"), listing("BBB"), listing("CCC")]) },
            rank: { _, _ in compared = true; return .failure(.unavailable) },
            parallelism: { 2 }, makeAnalysis: { item in
                prepared.append(item.ticker)
                let symbol = item.ticker
                return { horizon in
                    active += 1; peak = max(peak, active)
                    await withCheckedContinuation { waiting[symbol + horizon.rawValue] = $0 }
                    active -= 1
                    return .init(note: symbol + horizon.rawValue)
                }
            })
        #expect(started)
        for _ in 0..<100 where waiting.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(prepared == ["AAA", "BBB"], "The second stock must prepare while the first model call waits; the third must wait for a whole stock slot")
        #expect(peak == 2 && waiting.count == 2 && !compared)
        #if os(macOS)
        let scan = try #require(r.scans[.week])
        #expect(StockSageResearchModesPanel.resultLabel("AAA", research: r, scan: scan, horizon: .week) == "Checking…")
        #expect(StockSageResearchModesPanel.resultLabel("BBB", research: r, scan: scan, horizon: .week) == "Checking…")
        #endif
        r.stop()
        let held = waiting.values; waiting.removeAll()
        for continuation in held { continuation.resume() }
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(r.running == nil && r.scans[.week]?.results.isEmpty == true && !compared)
    }

    @Test(arguments: [-1, 1, 2, 4, 8, 64])
    func parallelChecksKeepOrderIdentityAndFinishBeforeRanking(capacity: Int) async throws {
        let history = StockSageResearchHistory(storageURL: nil)
        let r = R(history: history)
        defer { r.stop() }
        let names = (0..<12).map { listing("S\($0)") }
        var prepared: [String] = [], calls: [String] = [], finished: [String] = []
        var active = 0, peak = 0, comparisons = 0
        let started = r.start(R.Horizon.allCases, allowed: { true }, universe: { .init(names) },
            rank: { scan, horizon in
                #expect(active == 0 && calls.count == names.count * 2)
                #expect(scan.results.count == names.count && scan.listings == names)
                comparisons += 1
                return .success(.fixture(scan: scan, symbols: Array(names.reversed().prefix(5)).map(\.ticker), horizon: horizon))
            }, parallelism: { capacity }, makeAnalysis: { item in
                prepared.append(item.ticker)
                let capturedAt = Date()
                return { horizon in
                    calls.append(item.ticker + horizon.rawValue)
                    active += 1; peak = max(peak, active)
                    // Unequal delays force later listings to finish first when capacity allows.
                    try? await Task.sleep(for: .milliseconds(item.ticker == "S0" ? 25 : 5))
                    active -= 1; finished.append(item.ticker)
                    return .init(verdict: .init(action: .buy, reason: "Case", risk: "Risk", evidence: ["F1"]),
                        facts: [item.ticker], note: horizon.rawValue, at: capturedAt, model: "fixture")
                }
            })
        #expect(started)
        for _ in 0..<500 where r.running != nil { try await Task.sleep(for: .milliseconds(2)) }
        try #require(r.running == nil)
        #expect(peak == min(8, max(1, capacity)))
        #expect(prepared == names.map(\.ticker) && calls.count == 24 && Set(calls).count == 24)
        #expect(comparisons == 2 && history.runs.count == 2 && r.activeSymbols.isEmpty)
        if capacity > 1 { #expect(finished.first != "S0") }
        for item in names {
            for horizon in R.Horizon.allCases {
                let result = try #require(r.scans[horizon]?.results[item.ticker])
                #expect(result.facts == [item.ticker] && result.note == horizon.rawValue)
            }
            #expect(r.scans[.week]?.results[item.ticker]?.at == r.scans[.fortnight]?.results[item.ticker]?.at)
        }
    }

    @Test func capacityDiscoveredAfterFirstModelRequestAppliesToRemainingStocks() async throws {
        let r = R()
        var capacity = 1, active = 0, peak = 0
        var prepared: [String] = []
        var held: [String: CheckedContinuation<Void, Never>] = [:]
        defer { r.stop(); for continuation in held.values { continuation.resume() } }
        let started = r.start([.week], allowed: { true },
            universe: { .init((0..<9).map { listing("S\($0)") }) }, parallelism: { capacity },
            makeAnalysis: { item in
                prepared.append(item.ticker)
                return { _ in
                    active += 1; peak = max(peak, active)
                    await withCheckedContinuation { held[item.ticker] = $0 }
                    active -= 1
                    capacity = 8
                    return .init(note: item.ticker)
                }
            })
        #expect(started)
        for _ in 0..<100 where held.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        try #require(prepared == ["S0"] && held.count == 1)
        held.removeValue(forKey: "S0")?.resume()
        for _ in 0..<100 where held.count < 8 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(peak == 8 && prepared.count == 9 && held.count == 8)
        r.stop()
        let pending = held.values; held.removeAll()
        for continuation in pending { continuation.resume() }
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(r.running == nil && r.scans[.week]?.results.count == 1)
    }

    @Test(arguments: [true, false])
    func parallelStopRetainsCompletedHorizonsAndOwnsAllChildren(cancel: Bool) async throws {
        let history = StockSageResearchHistory(storageURL: nil)
        let r = R(history: history)
        var allowed = true, compared = false
        var prepared: [String] = []
        var waiting: [String: CheckedContinuation<Void, Never>] = [:]
        defer { r.stop(); for held in waiting.values { held.resume() } }
        let started = r.start(R.Horizon.allCases, allowed: { allowed },
            universe: { .init((0..<9).map { listing("S\($0)") }) },
            rank: { _, _ in compared = true; return .failure(.unavailable) },
            parallelism: { 8 }, makeAnalysis: { item in
                prepared.append(item.ticker)
                return { horizon in
                    if horizon == .fortnight { await withCheckedContinuation { waiting[item.ticker] = $0 } }
                    return .init(verdict: .init(action: .hold, reason: "Case", risk: "Risk", evidence: []), note: item.ticker)
                }
            })
        #expect(started)
        for _ in 0..<100 where waiting.count < 8 { try await Task.sleep(for: .milliseconds(2)) }
        try #require(waiting.count == 8)
        #expect(prepared.count == 8 && r.scans[.week]?.results.count == 8)
        #expect(r.activeDescription == "S0, S1, S2 +5 more")
        for symbol in waiting.keys {
            #expect(StockSageResearchModesPanel.resultLabel(symbol, research: r, scan: r.scans[.week]!, horizon: .week) == "Hold")
            #expect(StockSageResearchModesPanel.resultLabel(symbol, research: r, scan: r.scans[.fortnight]!, horizon: .fortnight) == "Checking…")
        }
        if cancel { r.stop(); #expect(r.activeSymbols.isEmpty) } else { allowed = false }
        waiting.removeValue(forKey: "S0")?.resume()
        try await Task.sleep(for: .milliseconds(10))
        #expect(r.running != nil, "One finished child cannot release the other seven workers' ownership")
        let restarted = r.start(.week, allowed: { true }, universe: { .init([]) }, analyze: { _ in .init(note: "Must not run") })
        #expect(!restarted)
        let held = waiting.values; waiting.removeAll()
        for continuation in held { continuation.resume() }
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(r.running == nil && r.activeSymbols.isEmpty && prepared.count == 8 && !compared)
        #expect(r.scans[.week]?.results.count == 8 && r.scans[.fortnight]?.results.isEmpty == true && history.runs.isEmpty)
    }

    @Test func cancellationOrSettingsChangeCannotPublishLateResult() async throws {
        for cancel in [true, false] {
            let r = R()
            var permitted = true
            var resume: CheckedContinuation<Void, Never>?
            defer { r.stop(); resume?.resume() }
            var analyzed: [String] = []
            let started = r.start(.week, allowed: { permitted }, universe: { .init([listing(), listing("MSFT")]) }, analyze: { item in
                analyzed.append(item.ticker)
                if item.ticker == "AAPL" { await withCheckedContinuation { resume = $0 } }
                return .init(note: "late")
            })
            #expect(started)
            for _ in 0..<100 where resume == nil { try await Task.sleep(for: .milliseconds(5)) }
            let continuation = try #require(resume)
            #expect(r.activeSymbol == "AAPL")
            #if os(macOS)
            let scan = try #require(r.scans[.week])
            #expect(StockSageResearchModesPanel.resultLabel("AAPL", research: r, scan: scan, horizon: .week) == "Checking…")
            #expect(StockSageResearchModesPanel.resultLabel("MSFT", research: r, scan: scan, horizon: .week) == "Queued")
            #expect(StockSageResearchModesPanel.resultLabel("MSFT", research: r, scan: scan, horizon: .fortnight) == "Not checked")
            #endif
            if cancel { r.stop() } else { permitted = false }
            #expect(r.running == .week, "The first request still owns the scan until it unwinds")
            let overlap = r.start(.fortnight, allowed: { true }, universe: { .init([]) },
                analyze: { _ in .init(note: "must not run") })
            #expect(!overlap && r.running == .week && r.scans[.fortnight] == nil)
            #if os(macOS)
            if cancel {
                #expect(r.activeSymbol == nil)
                #expect(StockSageResearchModesPanel.resultLabel("AAPL", research: r, scan: scan, horizon: .week) == "Not checked")
                #expect(StockSageResearchModesPanel.resultLabel("MSFT", research: r, scan: scan, horizon: .week) == "Not checked")
                #expect(StockSageResearchModesPanel.resultLabel("MSFT", research: r, scan: scan, horizon: .fortnight) == "Not checked")
                var completed = scan
                completed.results["MSFT"] = .init(note: "Synthetic completed check")
                #expect(StockSageResearchModesPanel.resultLabel("MSFT", research: r, scan: completed, horizon: .week) == "Incomplete")
                #expect(StockSageResearchModesPanel.resultLabel("MSFT", research: r, scan: completed, horizon: .fortnight) == "Incomplete")
            }
            #endif
            resume = nil
            continuation.resume()
            for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
            #expect(r.running == nil && r.activeSymbol == nil && r.scans[.week]?.results.isEmpty == true)
            #expect(analyzed == ["AAPL"], "Neither stop nor revoked settings may start the second listing")
        }
    }
}
