import Foundation
import Combine

/// Manual same-session research. No account, order or automation dependency.
@MainActor final class StockSageSameDayResearch: ObservableObject {
    static let shared = StockSageSameDayResearch(receiptStore: productionReceipts())
    nonisolated static let policy = "Unvalidated screen v1: 30 completed regular-session minutes, latest five consecutive with volume; spread at most 25 bps; observed target room after spread at least twice observed downside after spread. App ranking: reward/risk, narrower spread, activity, ticker. No order or fill guarantee."
    typealias Observer = @Sendable (StockSageLocalModelServer.ModelAttemptEvent) async -> Void
    typealias Analysis = @MainActor @Sendable (StockSageHorizonResearch.Listing, Double, Observer?) async -> Check
    nonisolated struct Quote: Codable, Sendable, Equatable {
        let bid: Double; let ask: Double; let at: Date
        init(_ value: StockSageNBBO) { bid = value.bid; ask = value.ask; at = value.timestamp }
    }
    nonisolated struct Check: Codable, Sendable, Equatable {
        let symbol: String
        let name: String
        var at: Date
        var note: String
        var model = ""
        var action: String?
        var reason: String?
        var risk: String?
        var evidence: [String] = []
        var activity: Double = 0
        var scenario: Scenario?
        var packet: StockSageAIAssessment.EvidencePacket?
        var profile: StockSageAIAssessment.InferenceProfile?
        var quality: StockSageAIAssessment.QualityReport?
        var expiresAt: Date?
        var qualified = false
        var verifiedQuote: Quote?
        var capturedQuote: Quote?
    }
    nonisolated struct Receipt: Codable, Sendable, Equatable {
        var policyVersion = 1
        let id: UUID
        let startedAt: Date
        var finishedAt: Date?
        var selection: String
        var checks: [Check]
        var selectedSymbol: String?
        var blocker: String?
    }
    @Published private(set) var receipt: Receipt?
    @Published private(set) var savedReceipts: [Receipt] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Press Run to check up to 24 activity-selected stocks for one same-day pick."
    private(set) var restored = false
    private let receiptStore: StockSageResearchReceiptStore?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(receiptStore: StockSageResearchReceiptStore? = nil) {
        self.receiptStore = receiptStore
        savedReceipts = receiptStore?.sameDayHistory ?? []
        receipt = savedReceipts.first
        restored = receipt != nil
    }
    private static func productionReceipts() -> StockSageResearchReceiptStore? {
        guard !StockSageStore.isRunningTests, (try? StockSageRecordWriter.require(.standard)) != nil else { return nil }
        return StockSageResearchReceiptStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockSage/SameDayResearch", isDirectory: true))
    }

    func stop() { generation = UUID(); task?.cancel() }

    @discardableResult func start(store: StockSageStore) -> Bool {
        guard !isRunning, StockSageHorizonResearch.shared.running == nil else { return false }
        guard let window = Self.session(at: Date()), Date() >= window.open.addingTimeInterval(1800) else {
            status = "Same-day research requires a verified regular session, thirty completed minutes and more than five minutes until close. Earlier saved research remains dated history."; return false
        }
        guard ToolPolicy.isExternalAllowed, !store.isSampleData,
              !StockSageLocalModelServer.isShuttingDown,
              let config = StockSageAIAssessments.configuration, config.requiresStrictOutput,
              config.model == StockSageLocalModelServer.gemmaModel else {
            status = "Fresh market access and the exact strict-output Gemma configuration are required. No research started."; return false
        }
        if let reason = StockSageMassive.credentialAccessBlocker() {
            status = reason + " No research started."; return false
        }
        guard let receiptStore, (try? StockSageRecordWriter.require(.standard)) != nil else {
            status = "The same-day research writer is unavailable. No research started; existing records preserved."; return false
        }
        let requested = Date(), id = receiptStore.beginSameDay(at: requested)
        let initial = Receipt(id: id, startedAt: requested, selection: "Preparing Gemma and the dated activity shortlist.", checks: [])
        guard receiptStore.saveSameDay(initial) else {
            let reason = "The initial same-day receipt could not be saved. No model preparation or market collection started."
            var failure = initial
            failure.finishedAt = Date(); failure.blocker = reason
            receiptStore.finish(scanID: id, status: reason)
            receipt = failure; status = reason; restored = false; savedReceipts = receiptStore.sameDayHistory
            return false
        }
        receipt = initial; restored = false; savedReceipts = receiptStore.sameDayHistory
        let run = UUID(), key = StockSageMassive.apiKey
        let credentials = StockSageMassive.credentialRevision(), revision = StockSageLocalModelServer.settingsRevision()
        let policy = AppSettings.policyRevision()
        generation = run; isRunning = true; status = "Preparing Gemma and the dated activity shortlist…"
        let allowed: @MainActor @Sendable () -> Bool = { [weak self] in
            self?.generation == run && !Task.isCancelled && !StockSageLocalModelServer.isShuttingDown
                && ToolPolicy.isExternalAllowed && AppSettings.policyRevision() == policy && !store.isSampleData
                && StockSageMassive.apiKey == key && StockSageMassive.credentialRevision() == credentials
                && StockSageAIAssessments.configuration == config && StockSageLocalModelServer.settingsRevision() == revision
                && !receiptStore.persistenceFailed(scanID: id)
        }
        task = Task { [self] in
            defer { isRunning = false; task = nil }
            let probe = await StockSageLocalModelServer.prepare(config, stillValid: allowed)
            if let failure = Self.preparationFailure(probe, isAllowed: allowed()) {
                await failedRun(failure, initial: initial); return
            }
            do {
                let selection = try await StockSageResearchUniverse.fetch(key: key, allowed: allowed, limit: 500)
                let regular = try await StockSageMassiveTicks.regularQuoteConditions()
                guard allowed() else { await failedRun("Research interrupted before collection.", initial: initial); return }
                await self.run(selection: selection, initial: initial, capacity: { min(24, probe.researchParallelism) }, allowed: allowed,
                    analyze: { item, activity, observer in
                        await Self.assess(item, activity: activity, store: store, key: key, config: config,
                            regular: regular, allowed: allowed, observer: observer)
                    }, refreshQuote: { symbol in
                        await StockSageMassiveTicks.freshResearchNBBO(symbol: symbol, regularConditions: regular)
                    })
            } catch { await failedRun("Activity or quote-condition evidence unavailable or interrupted. No pick.", initial: initial) }
        }
        return true
    }

    nonisolated static func preparationFailure(_ probe: StockSageLocalModelServer.Probe,
                                               isAllowed: Bool) -> String? {
        guard isAllowed else { return "Gemma preparation was interrupted. No replacement model or pick." }
        guard probe.reachable, probe.hasModel, !probe.isOllama else {
            let detail = probe.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Gemma preparation failed: " + (detail.isEmpty ? "Check the selected model server." : String(detail.prefix(512)))
                + " No replacement model or pick."
        }
        return nil
    }

    private static let receiptFailure = "Research receipt could not be saved; collection stopped and no current pick published. Completed checks remain in memory."

    private func reportReceiptFailure(scanID: UUID) {
        guard receipt?.id == scanID, receiptStore?.persistenceFailed(scanID: scanID) == true else { return }
        receipt?.selectedSymbol = nil; receipt?.blocker = Self.receiptFailure
        status = Self.receiptFailure
        // In production this cancels the parent request and its structured children immediately,
        // including a model transport whose observer was the first failed write.
        task?.cancel()
    }

    private func failedRun(_ reason: String, initial: Receipt) async {
        let now = Date(), id = initial.id
        let value = Receipt(id: id, startedAt: initial.startedAt, finishedAt: now, selection: "No shortlist completed.", checks: [], blocker: reason)
        _ = receiptStore?.saveSameDay(value)
        receiptStore?.finish(scanID: id, status: reason, at: now)
        receipt = value; status = reason; restored = false
        savedReceipts = receiptStore?.sameDayHistory ?? []
    }

    func run(selection: StockSageResearchUniverse.Selection, initial: Receipt? = nil,
        capacity: @escaping @MainActor () -> Int, allowed: @escaping @MainActor () -> Bool,
        clock: @escaping @MainActor () -> Date = Date.init, analyze: @escaping Analysis,
        refreshQuote: @escaping @MainActor (String) async -> StockSageNBBO?) async {
        isRunning = true; restored = false
        defer { isRunning = false }
        let started = initial?.startedAt ?? clock(), id = initial?.id ?? receiptStore?.beginSameDay(at: started) ?? UUID()
        let listings = Array(selection.listings.prefix(24))
        var result = Receipt(id: id, startedAt: started,
            selection: "\(listings.count) of \(selection.receipt?.eligibleCount ?? selection.listings.count) eligible activity-selected listings shortlisted. " + (selection.receipt?.summary ?? "Selection activity receipt unavailable."),
            checks: listings.map { .init(symbol: $0.ticker, name: $0.name, at: started, note: "Not started") })
        func active() -> Bool {
            !Task.isCancelled && allowed() && receiptStore?.persistenceFailed(scanID: id) != true
                && clock() >= started && Self.session(at: clock()) != nil
        }
        func finish(_ blocker: String?) {
            result.finishedAt = clock(); result.blocker = blocker
            _ = receiptStore?.saveSameDay(result)
            receiptStore?.finish(scanID: id, status: blocker ?? "Completed same-day research", at: clock())
            if receiptStore?.persistenceFailed(scanID: id) == true {
                result.selectedSymbol = nil; result.blocker = Self.receiptFailure
            }
            receipt = result; status = result.blocker ?? "App-ranked Gemma-qualified pick: \(result.selectedSymbol ?? "none")"
            savedReceipts = receiptStore?.sameDayHistory ?? []
        }
        guard active() else { finish("Research interrupted or outside the verified same-day entry session."); return }
        guard !listings.isEmpty, Set(listings.map(\.ticker)).count == listings.count,
              listings.allSatisfy({ $0.active && $0.type == "CS" && $0.primary_exchange == "XNAS"
                && $0.currency_name?.lowercased() == "usd" && StockSageHorizonResearch.validTicker($0.ticker) }) else {
            finish("The bounded NASDAQ common-share shortlist could not be verified."); return
        }
        let attempts = receiptStore?.registerSelection(selection.receipt, listings: listings, for: id) ?? listings.map { _ in UUID() }
        guard attempts.count == listings.count else { finish("The research attempts could not be registered."); return }
        _ = receiptStore?.saveSameDay(result)
        receipt = result
        guard active() else { finish("Research interrupted before collection."); return }
        await withTaskGroup(of: (Int, Check).self) { group in
            var next = 0, inflight = 0, completed = 0
            while next < listings.count || inflight > 0 {
                while next < listings.count && inflight < max(1, min(24, capacity())) && active() {
                    let index = next, item = listings[index], attempt = attempts[index], writer = receiptStore
                    let activity = selection.receipt?.dollarVolume[item.ticker] ?? 0
                    writer?.beginAttempt(attempt, scanID: id, at: clock())
                    guard active() else { group.cancelAll(); break }
                    let observer: Observer = { [weak self] event in
                        await writer?.capture(event, for: attempt, scanID: id)
                        await self?.reportReceiptFailure(scanID: id)
                    }
                    group.addTask { @MainActor @Sendable in (index, await analyze(item, activity, observer)) }
                    next += 1; inflight += 1
                }
                guard inflight > 0, let (index, check) = await group.next() else { break }
                inflight -= 1; completed += 1
                result.checks[index] = check
                let opinion = check.action.flatMap(TradeAdvice.Action.init(rawValue:)).map {
                    StockSageAIAssessment.Verdict(action: $0, reason: check.reason ?? "", risk: check.risk ?? "", evidence: check.evidence)
                }
                receiptStore?.finishAttempt(.init(verdict: opinion, facts: check.packet?.facts.map(\.text) ?? [],
                    note: check.note, at: check.at, model: check.model,
                    validationOutcome: opinion == nil ? .unknown : .validated), attemptID: attempts[index], scanID: id,
                    status: check.qualified ? "qualified" : "not_qualified", at: clock())
                _ = receiptStore?.saveSameDay(result)
                receipt = result
                if receiptStore?.persistenceFailed(scanID: id) == true { reportReceiptFailure(scanID: id) }
                else { status = "Same-day research · \(completed)/\(listings.count) checks completed" }
                if !active() { group.cancelAll() }
            }
        }
        guard active() else { finish("Research interrupted; original checks retained and no pick published."); return }
        let eligible = result.checks.filter { $0.qualified && $0.scenario != nil && $0.expiresAt.map { $0 >= clock() } == true }
        let ranked = eligible.sorted { a, b in
            let x = a.scenario!, y = b.scenario!
            if x.rewardRisk != y.rewardRisk { return x.rewardRisk > y.rewardRisk }
            if x.spreadBps != y.spreadBps { return x.spreadBps < y.spreadBps }
            if a.activity != b.activity { return a.activity > b.activity }
            return a.symbol < b.symbol
        }
        guard let winner = ranked.first, let plan = winner.scenario else { finish("No stock passed the same-day evidence, model and observed-scenario gates."); return }
        let quote = await refreshQuote(winner.symbol)
        guard active() else { finish("Research interrupted before final winner publication."); return }
        guard winner.expiresAt.map({ $0 >= clock() }) == true, let quote, quote.matches(winner.symbol),
              quote.costConditionVerified, let spread = quote.spreadBps(at: clock()), spread <= 25,
              quote.ask <= plan.entry, quote.bid > plan.stop, quote.ask < plan.target,
              (plan.target - plan.entry - (quote.ask - quote.bid)) / (plan.entry - plan.stop + (quote.ask - quote.bid)) >= 2 else {
            finish("The selected winner failed its final fresh quote or frozen-scenario check. No runner-up substituted."); return
        }
        if let index = result.checks.firstIndex(where: { $0.symbol == winner.symbol }) {
            result.checks[index].verifiedQuote = Quote(quote)
        }
        result.selectedSymbol = winner.symbol
        finish(nil)
    }
    nonisolated static func current(_ receipt: Receipt, at now: Date) -> Bool {
        guard receipt.policyVersion == 1, receipt.blocker == nil, session(at: now) != nil,
              let ended = receipt.finishedAt, ended <= now, receipt.startedAt <= ended,
              let winner = receipt.checks.first(where: { $0.symbol == receipt.selectedSymbol }),
              winner.qualified, winner.at <= now, let expiry = winner.expiresAt, now <= expiry,
              let quote = winner.verifiedQuote, (0...5).contains(now.timeIntervalSince(quote.at)) else { return false }
        return calendar.isDate(receipt.startedAt, inSameDayAs: now)
    }

    nonisolated static let instructions = StockSageAIAssessment.instructions.replacingOccurrences(
        of: "Assess the supplied stock for the next trading week.",
        with: "Assess the supplied stock only for the remainder of today's regular trading session, research only.") + """

    Use completed intraday observations for this same-day setup; daily technical rules are background, never intraday confirmation. Buy or Strong Buy requires citing an actual completed-minute observation AND a public news or filing record published today. A recent publication alone does not establish that its event happens today or that price will rise. In reason explain the observed entry setup; in risk explain what would invalidate it. The app supplies frozen numeric entry, stop and target references separately: do not invent or alter them. No overnight thesis, orders, position management or guarantee. Hold or Avoid is appropriate when the same-day case is insufficient.
    """

    private static func assess(_ item: StockSageHorizonResearch.Listing, activity: Double,
        store: StockSageStore, key: String, config: StockSageLocalModelServer.Config,
        regular: Set<Int64>, allowed: @escaping @MainActor @Sendable () -> Bool, observer: Observer?) async -> Check {
        var result = Check(symbol: item.ticker, name: item.name, at: Date(), note: "Not assessed")
        result.activity = activity; result.model = config.model
        func failed(_ reason: String) -> Check { result.note = reason; result.qualified = false; return result }
        guard allowed(), Self.session(at: Date()) != nil else { return failed("Research interrupted or entry session ended.") }
        let gathered = await StockSageHorizonResearch.gather(item, store: store, key: key, allowed: allowed)
        guard allowed() else { return failed("Research interrupted after background collection.") }
        guard case .captured(let capture) = gathered else {
            if case .failed(let failure) = gathered { return failed(failure.note) }
            return failed("Public background evidence unavailable.")
        }
        guard !capture.blockedByThrottle, capture.isFresh(at: Date()), let window = Self.session(at: Date()) else {
            return failed("Background evidence expired, was throttled, or the regular entry session ended.")
        }
        let requestTime = Date()
        guard let intraday = await StockSageMassiveTicks.intradayFacts(symbol: item.ticker,
            from: max(window.open, requestTime.addingTimeInterval(-3600)), now: requestTime),
              allowed(), let quote = await StockSageMassiveTicks.freshResearchNBBO(symbol: item.ticker, regularConditions: regular),
              allowed(), quote.matches(item.ticker) else {
            return failed("Completed minute coverage, current eligible bid/ask, or observed stop/target failed the same-day screen. Trade-only fallback cannot qualify.")
        }
        return await assessCaptured(capture, item: item, activity: activity, intraday: intraday, quote: quote,
            config: config, allowed: allowed, observer: observer)
    }

    /// The same production prompt/validator path, with a clock and transport seam for offline replay.
    static func assessCaptured(_ capture: StockSageHorizonResearch.Capture,
        item: StockSageHorizonResearch.Listing, activity: Double, intraday: StockSageMassiveTicks.Intraday,
        quote: StockSageNBBO, config: StockSageLocalModelServer.Config,
        allowed: @escaping @MainActor () -> Bool, observer: Observer? = nil,
        clock: @escaping @MainActor () -> Date = Date.init,
        modelTransport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> Check {
        var result = Check(symbol: item.ticker, name: item.name, at: clock(), note: "Not assessed")
        result.activity = activity; result.model = config.model
        func failed(_ reason: String) -> Check { result.note = reason; result.qualified = false; return result }
        guard allowed(), config.requiresStrictOutput, config.model == StockSageLocalModelServer.gemmaModel,
              !capture.blockedByThrottle, capture.isFresh(at: clock()), quote.matches(item.ticker),
              let window = Self.session(at: clock()), let scenario = Self.scenario(intraday, quote: quote, at: clock()) else {
            return failed("Strict Gemma, fresh public evidence, eligible quote or the observed same-day scenario is unavailable.")
        }
        result.at = clock(); result.scenario = scenario; result.capturedQuote = Quote(quote)
        let deadline = min(capture.at.addingTimeInterval(300), intraday.asOf.addingTimeInterval(180), window.close.addingTimeInterval(-300))
        result.expiresAt = deadline
        func active() -> Bool {
            allowed() && clock() >= result.at && clock() <= deadline && Self.session(at: clock()) != nil
                && capture.isFresh(at: clock()) && intraday.fresh(at: clock())
                && (capture.context.benzinga.map { StockSageBenzingaClient.shared.isCurrent($0) } ?? true)
        }
        guard active(), let original = capture.evidencePacket, original.isWellFormed else {
            return failed("Original public evidence packet expired or could not be verified.")
        }
        var extra: [StockSageAIAssessment.EvidenceFact] = [
            .init(key: "sameDay.session", text: "Requested mode: same-day regular session only. Scheduled close \(window.close.ISO8601Format()); stop new entries five minutes before that close. No automatic exit or order. Daily bars are background only.", required: true, availability: .available, factClass: .risk, source: "Published Nasdaq schedule", observedAt: result.at),
            .init(key: "sameDay.summary", text: "\(intraday.bars.count) completed minutes in a bounded last-hour window; \(intraday.missingMinutes) missing minutes between first and last. Missing minutes are not filled. Latest five are consecutive with positive volume. This does not prove continuous liquidity or absence of a halt.", required: true, availability: .available, factClass: .technical, source: "Massive one-minute aggregates", observedAt: intraday.asOf),
            .init(key: "sameDay.quote", text: "Captured eligible Massive NBBO: bid \(quote.bid), ask \(quote.ask) USD; bid size \(quote.bidSize), ask size \(quote.askSize) shares. SIP time \(quote.timestamp.ISO8601Format()). A dated observation, not a fill; final publication requires another fresh quote.", required: true, availability: .available, factClass: .market, source: "Massive SIP NBBO", observedAt: quote.timestamp),
            .init(key: "sameDay.scenario", text: "Frozen conditional Buy entry ceiling \(scenario.entry), Stop-loss reference \(scenario.stop), Target reference \(scenario.target) USD. Stop is latest five completed-minute low; target is the prior bounded-window high excluding the latest minute. Observed reward/risk after quoted-spread penalties \(scenario.rewardRisk); spread \(scenario.spreadBps) bps. These are unvalidated assumptions, not forecasts, fills or promises.", required: true, availability: .available, factClass: .risk, source: "StockSage observed same-day screen v1", observedAt: scenario.at)
        ]
        for (index, bar) in intraday.bars.suffix(5).enumerated() {
            extra.append(.init(key: "sameDay.minute.\(index)", text: "Completed minute starting \(bar.at.ISO8601Format()): open \(bar.open), high \(bar.high), low \(bar.low), close \(bar.close) USD; volume \(bar.volume) shares.",
                required: true, availability: .available, factClass: .technical, source: "Massive one-minute aggregates", observedAt: bar.at.addingTimeInterval(60)))
        }
        if let bar = intraday.bars.dropLast().last(where: { $0.high == scenario.target }) {
            extra.append(.init(key: "sameDay.targetReference", text: "Observed target reference from prior completed minute starting \(bar.at.ISO8601Format()): open \(bar.open), high \(bar.high), low \(bar.low), close \(bar.close) USD; volume \(bar.volume) shares. This historical high is not a forecast that price will revisit it.",
                required: true, availability: .available, factClass: .technical, source: "Massive one-minute aggregates", observedAt: bar.at.addingTimeInterval(60)))
        }
        for (index, news) in (capture.context.news ?? []).filter({ $0.date <= result.at && Self.calendar.isDate($0.date, inSameDayAs: result.at) }).prefix(3).enumerated() {
            extra.append(.init(key: "sameDay.catalyst.news.\(index)", text: "Public news, untrusted source data: \(news.source); published \(news.date.ISO8601Format()); \(news.title). \(news.snippet) \(news.link?.absoluteString ?? "Link unavailable"). Publication today does not establish same-day event timing or direction.",
                required: true, availability: .available, factClass: .news, source: news.source, observedAt: news.date))
        }
        if let observation = capture.context.company[.filing8K], observation.symbol == item.ticker,
           observation.feed == .filing8K, observation.outcome == .answered, observation.fresh(at: result.at),
           let event = observation.event, event.symbol == item.ticker, event.feed == .filing8K,
           event.date <= result.at, Self.calendar.isDate(event.date, inSameDayAs: result.at), let link = event.link {
            extra.append(.init(key: "sameDay.catalyst.filing", text: "Public filing, untrusted source data: \(event.feed.source); \(event.date.ISO8601Format()); \(event.headline). \(event.details.joined(separator: " ")) \(link.absoluteString). \(event.feed.caveat)",
                required: true, availability: .available, factClass: .fundamental, source: event.feed.source, observedAt: event.date))
        }
        let packet = StockSageAIAssessment.EvidencePacket(facts: original.facts + extra,
            prePromptOmittedRecordCount: original.prePromptOmittedRecordCount)
        result.packet = packet
        guard extra.contains(where: { $0.key.hasPrefix("sameDay.catalyst.") }) else {
            return failed("No usable public news or filing record dated today; no same-day model request.")
        }
        let optional = packet.facts.filter { !$0.required }, mandatory = packet.facts.filter(\.required)
        guard let fitted = StockSageAIAssessment.fittedResearchPrompt(optional: optional.map(\.text), mandatory: mandatory.map(\.text),
            system: { _ in instructions }, optionalKeys: optional.map(\.key), outputTokens: config.reservedOutputTokens(for: 192)) else {
            return failed("Required same-day evidence could not fit the strict Gemma context budget.")
        }
        let offered = Array(optional.prefix(fitted.optionalKept)) + mandatory
        result.packet = .init(facts: offered, prePromptOmittedRecordCount: packet.prePromptOmittedRecordCount + fitted.omitted)
        guard active() else { return failed("Evidence expired or research was interrupted before inference.") }
        let response = await StockSageAIAssessment.complete(config, isOllama: false, system: fitted.system, user: fitted.user,
            facts: fitted.facts, maxTokens: 192, attemptObserver: observer, stillValid: active, transport: modelTransport)
        guard active() else { return failed("Evidence expired or research was interrupted during inference.") }
        guard case .success(let completion) = response else {
            return failed(StockSageAIAssessments.failureSummary(response, facts: fitted.facts, leadCount: 0))
        }
        result.profile = .init(config: config, isOllama: false, packet: result.packet!, outputTokens: 192, diagnostic: completion.diagnostic)
        guard completion.model == config.model, StockSageLocalModelServer.financialOutputRejection(completion) == nil,
              case .success(let verdict) = StockSageAIAssessment.validate(completion.text, facts: fitted.facts) else {
            return failed("Gemma output failed model identity, completion or evidence validation.")
        }
        result.action = verdict.action.rawValue; result.reason = verdict.reason; result.risk = verdict.risk; result.evidence = verdict.evidence
        result.quality = StockSageAIAssessment.quality(verdict, offered: offered, symbol: item.ticker)
        result.qualified = Self.qualifies(verdict, facts: offered, at: clock())
        result.note = result.qualified ? "Gemma opinion passed the unvalidated same-day screen." : "Gemma opinion did not pass the same-day action and citation gates."
        if !fitted.isComplete { result.note += " \(fitted.omitted) optional records omitted to fit the model context; mandatory records retained." }
        return result
    }
    nonisolated struct Session: Sendable { let open: Date; let close: Date }
    nonisolated struct Scenario: Codable, Sendable, Equatable {
        let entry: Double
        let stop: Double
        let target: Double
        let spreadBps: Double
        let rewardRisk: Double
        let at: Date
        let barsAsOf: Date
    }
    private nonisolated static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    nonisolated static func session(at now: Date) -> Session? {
        guard now.timeIntervalSince1970.isFinite, let day = StockSageMarketHours.nasdaqDay(at: now), day.trading,
              let open = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: now),
              let close = calendar.date(bySettingHour: day.regularClose, minute: 0, second: 0, of: now),
              now >= open, now < close.addingTimeInterval(-300) else { return nil }
        return .init(open: open, close: close)
    }
    nonisolated static func scenario(_ intraday: StockSageMassiveTicks.Intraday, quote: StockSageNBBO, at now: Date) -> Scenario? {
        guard let session = session(at: now), intraday.verifiedMinutes, intraday.fresh(at: now),
              intraday.bars.count >= 30, intraday.bars.count <= 60,
              quote.costConditionVerified, let spread = quote.spreadBps(at: now), spread <= 25 else { return nil }
        let bars = intraday.bars
        guard bars.allSatisfy({ bar in
            bar.at >= session.open && bar.at >= now.addingTimeInterval(-3660)
                && bar.at.addingTimeInterval(60) <= now
                && [bar.open, bar.high, bar.low, bar.close, bar.volume].allSatisfy(\.isFinite)
                && bar.low > 0 && bar.high >= max(bar.open, bar.close)
                && bar.low <= min(bar.open, bar.close) && bar.volume >= 0
        }), zip(bars, bars.dropFirst()).allSatisfy({ $0.at < $1.at }),
            let last = bars.last, last.at.addingTimeInterval(60) == intraday.asOf else { return nil }
        let recent = Array(bars.suffix(5))
        guard recent.allSatisfy({ $0.volume > 0 }),
              zip(recent, recent.dropFirst()).allSatisfy({ $1.at.timeIntervalSince($0.at) == 60 }),
              let stop = recent.map(\.low).min(), let target = bars.dropLast().map(\.high).max(),
              stop < quote.ask, quote.ask < target else { return nil }
        let cost = quote.ask - quote.bid
        let ratio = (target - quote.ask - cost) / (quote.ask - stop + cost)
        guard ratio.isFinite, ratio >= 2 else { return nil }
        return .init(entry: quote.ask, stop: stop, target: target, spreadBps: spread,
            rewardRisk: ratio, at: now, barsAsOf: intraday.asOf)
    }
    nonisolated static func qualifies(_ verdict: StockSageAIAssessment.Verdict,
        facts: [StockSageAIAssessment.EvidenceFact], at now: Date) -> Bool {
        guard session(at: now) != nil, [.buy, .strongBuy].contains(verdict.action) else { return false }
        let cited = verdict.evidence.compactMap { id -> StockSageAIAssessment.EvidenceFact? in
            guard id.first == "F", let index = Int(id.dropFirst()), index > 0, index <= facts.count else { return nil }
            return facts[index - 1]
        }
        let available = cited.filter { $0.availability == .available && $0.observedAt.map { $0 <= now } == true }
        return available.contains { $0.key.hasPrefix("sameDay.minute.") && now.timeIntervalSince($0.observedAt!) <= 360 }
            && available.contains { $0.key.hasPrefix("sameDay.catalyst.") && calendar.isDate($0.observedAt!, inSameDayAs: now) }
    }
}
