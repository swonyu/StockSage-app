import Foundation
import Combine

/// Same-session research. Micro cap uses caller-controlled setup admission; no broker dependency.
@MainActor final class StockSageSameDayResearch: ObservableObject {
    nonisolated enum Mode: String, Codable, Sendable {
        case sameDay = "same-day", microcap, largecap
        var isAstra: Bool { self != .sameDay }
        var title: String {
            switch self { case .sameDay: "Same-day"; case .microcap: "Micro cap"; case .largecap: "Large cap" }
        }
        var directoryName: String {
            switch self { case .sameDay: "SameDayResearch"; case .microcap: "MicrocapResearch"; case .largecap: "LargecapResearch" }
        }
        var screenProfile: StockSageMicrocapScreen.Profile? {
            switch self { case .sameDay: nil; case .microcap: .microcap; case .largecap: .largecap }
        }
    }
    static let shared = StockSageSameDayResearch(receiptStore: productionReceipts())
    static let microcap = StockSageSameDayResearch(receiptStore: productionReceipts(mode: .microcap), mode: .microcap)
    static let largecap = StockSageSameDayResearch(receiptStore: productionReceipts(mode: .largecap), mode: .largecap)
    static var anyRunning: Bool { shared.isRunning || microcap.isRunning || largecap.isRunning }
    let mode: Mode
    var isMicrocap: Bool { mode == .microcap }
    var isAstra: Bool { mode.isAstra }
    var analyst: String { isAstra ? "Astra" : "Gemma" }
    var title: String { mode.title }
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
        var codexAudit: StockSageCodexResearch.Audit? = nil
        var rawModelOutput: String? = nil
        var setupID: String? = nil
        var fundamentals: StockSageFundamentals.Snapshot? = nil
        var momentum: StockSageMomentum.Stock? = nil
        var momentumTrigger: StockSageMomentum.Trigger? = nil
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
        var mode: Mode? = nil
        var microcapScreen: StockSageMicrocapScreen.Result? = nil
        var marketMomentum: StockSageMomentum.Market? = nil
    }
    @Published private(set) var receipt: Receipt?
    @Published private(set) var savedReceipts: [Receipt] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Press Run to check up to 24 activity-selected stocks for one same-day pick."
    private(set) var restored = false
    private let receiptStore: StockSageResearchReceiptStore?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(receiptStore: StockSageResearchReceiptStore? = nil, mode: Mode = .sameDay) {
        self.mode = mode
        self.receiptStore = receiptStore
        savedReceipts = receiptStore?.sameDayHistory ?? []
        receipt = savedReceipts.first
        restored = receipt != nil
        if mode.isAstra { status = "Set up Telegram and enable watching, or run a manual \(mode.title) check. Uses GPT-6 Astra through your Codex subscription." }
    }
    private static func productionReceipts(mode: Mode = .sameDay) -> StockSageResearchReceiptStore? {
        guard !StockSageStore.isRunningTests, (try? StockSageRecordWriter.require(.standard)) != nil else { return nil }
        return StockSageResearchReceiptStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockSage/" + mode.directoryName, isDirectory: true), sameDayLabel: mode.rawValue)
    }

    func stop() {
        generation = UUID(); task?.cancel()
        #if os(macOS)
        if isAstra && isRunning { StockSageCodexResearch.stopAll() }
        #endif
    }

    @discardableResult func start(store: StockSageStore, admitSetup: ((String) -> Bool)? = nil,
        stillValid: @escaping @MainActor @Sendable () -> Bool = { true }) -> Bool {
        guard stillValid(), !isRunning, !Self.anyRunning, StockSageHorizonResearch.shared.running == nil else { return false }
        if isAstra { return startCapResearch(store: store, admitSetup: admitSetup, stillValid: stillValid) }
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

    private func startCapResearch(store: StockSageStore, admitSetup: ((String) -> Bool)?,
        stillValid: @escaping @MainActor @Sendable () -> Bool) -> Bool {
        #if os(macOS)
        let requested = Date()
        guard let window = Self.session(at: requested), requested >= window.open.addingTimeInterval(1800) else {
            status = "\(title) watches verified regular US sessions after thirty completed minutes and stops new entries five minutes before close."; return false
        }
        guard ToolPolicy.isExternalAllowed, !store.isSampleData else {
            status = "\(title) requires current public market access; sample data cannot trigger research."; return false
        }
        if let reason = StockSageMassive.credentialAccessBlocker() { status = reason; return false }
        guard let receiptStore, (try? StockSageRecordWriter.require(.standard)) != nil else {
            status = "\(title) cannot start because its research record cannot be saved."; return false
        }
        let id = receiptStore.beginSameDay(at: requested)
        var initial = Receipt(id: id, startedAt: requested,
            selection: "Classifying supported common shares before the bounded \(title) screen.", checks: [])
        initial.mode = mode
        guard receiptStore.saveSameDay(initial) else { status = Self.receiptFailure; return false }
        let access = StockSageMassive.Access().capture(), run = UUID()
        generation = run; isRunning = true; restored = false; receipt = initial
        status = "Screening dated market evidence; Astra uses your Codex subscription only after a setup qualifies…"
        let allowed: @MainActor @Sendable () -> Bool = { [weak self] in
            self?.generation == run && !Task.isCancelled && access.isCurrent() && stillValid()
                && !store.isSampleData && !receiptStore.persistenceFailed(scanID: id)
        }
        task = Task { [self] in
            defer { isRunning = false; task = nil }
            guard let profile = mode.screenProfile else { await failedRun("Unknown research mode.", initial: initial); return }
            let capturedAccess = StockSageMassive.Access(key: { access.key }, credentialRevision: { nil },
                policyRevision: { nil }, allowed: access.isCurrent)
            async let market = StockSageMomentum.collect(now: Date(), access: capturedAccess)
            let selection = await StockSageMicrocapScreen.select(key: access.key, allowed: allowed, profile: profile)
            initial.marketMomentum = await market
            initial.microcapScreen = selection.receipt
            initial.selection = "\(selection.receipt.rows.count) reference rows; \(selection.receipt.detailedCount) detailed screens; \(selection.listings.count) passed candidates. \(selection.receipt.unassessedCount) candidates beyond the detail limit remain unassessed."
            receipt = initial
            guard receiptStore.saveSameDay(initial) else { reportReceiptFailure(scanID: id); return }
            guard allowed() else { await failedRun("\(title) interrupted after screening; captured checks remain saved.", initial: initial); return }
            let symbols = Set(selection.receipt.rows.filter { row in
                row.marketCap.map { isMicrocap ? (50_000_000...300_000_000).contains($0) : $0 >= 10_000_000_000 } == true
            }.map(\.symbol))
            if isMicrocap { StockSageLiveStream.shared.microcapSymbols = symbols }
            else { StockSageLiveStream.shared.largecapSymbols = symbols }
            if let blocker = selection.receipt.blocker {
                await failedRun(blocker, initial: initial); return
            }
            guard !selection.listings.isEmpty else {
                await failedRun("No candidate passed the dated \(title) screen. All classifications and exclusions are saved.", initial: initial); return
            }
            do {
                let regular = try await StockSageMassiveTicks.regularQuoteConditions(access: capturedAccess)
                guard allowed() else { await failedRun("Market access changed before assessment.", initial: initial); return }
                await self.run(selection: .init(selection.listings), initial: initial, capacity: { 1 }, allowed: allowed,
                    analyze: { item, _, observer in
                        await Self.assess(item, activity: selection.activity[item.ticker] ?? 0,
                            store: store, key: access.key, config: nil, regular: regular, allowed: allowed,
                            observer: observer, microcap: selection.receipt, admitSetup: admitSetup,
                            capMode: self.mode, marketMomentum: initial.marketMomentum,
                            fundamentalsAccess: capturedAccess)
                    }, refreshQuote: { symbol in
                        await StockSageMassiveTicks.freshResearchNBBO(symbol: symbol, regularConditions: regular, access: capturedAccess)
                    })
            } catch { await failedRun("Eligible quote conditions are unavailable. \(title) cannot publish a pick.", initial: initial) }
        }
        return true
        #else
        status = "\(title) with Codex is available on macOS."; return false
        #endif
    }

    /// A descriptive momentum review has its own receipt and can never publish trade levels.
    @discardableResult func startMomentum(store: StockSageStore, trigger: StockSageMomentum.Trigger,
        stock: StockSageMomentum.Stock, market: StockSageMomentum.Market, setupID: String,
        stillValid: @escaping @MainActor () -> Bool = { true },
        admitSetup: ((String) -> Bool)? = nil) -> Bool {
        #if os(macOS)
        let now = Date()
        guard stillValid(), isAstra, !isRunning, !Self.anyRunning, StockSageHorizonResearch.shared.running == nil,
              let profile = mode.screenProfile, trigger.profile == profile,
              stock.heavyMomentum(profile: profile, now: now) == trigger,
              StockSageMicrocapMonitor.trackingWindow(at: now) != nil,
              StockSageMicrocapMonitor.momentumID(trigger, mode: mode, purpose: .review) == setupID,
              !savedReceipts.contains(where: { $0.checks.contains { $0.setupID == setupID } }),
              ToolPolicy.isExternalAllowed, !store.isSampleData,
              let receiptStore, (try? StockSageRecordWriter.require(.standard)) != nil else { return false }
        if let reason = StockSageMassive.credentialAccessBlocker() { status = reason; return false }
        let access = StockSageMassive.Access().capture()
        guard access.isCurrent() else { return false }
        let id = receiptStore.beginSameDay(at: now)
        var initial = Receipt(id: id, startedAt: now,
            selection: "Heavy momentum in \(trigger.symbol) · descriptive Astra review, not a qualified trade setup.", checks: [])
        initial.mode = mode; initial.marketMomentum = market
        guard receiptStore.saveSameDay(initial) else { status = Self.receiptFailure; return false }
        guard admitSetup?(setupID) ?? true else {
            initial.finishedAt = now; initial.blocker = "This momentum review was already attempted or admission was unavailable."
            _ = receiptStore.saveSameDay(initial); receiptStore.finish(scanID: id, status: initial.blocker!, at: now)
            return false
        }
        let run = UUID(); generation = run
        receipt = initial; restored = false; isRunning = true; status = "Astra is reviewing \(trigger.symbol)'s heavy momentum…"
        let allowed: @MainActor () -> Bool = { [weak self] in
            self?.generation == run && !Task.isCancelled && access.isCurrent() && stillValid() && !store.isSampleData
                && StockSageMicrocapMonitor.trackingWindow(at: Date()) != nil
                && !receiptStore.persistenceFailed(scanID: id)
        }
        task = Task { [self] in
            defer { isRunning = false; task = nil }
            var check = await StockSageMomentumAssessment.assess(trigger: trigger, stock: stock, market: market, allowed: allowed)
            check.setupID = setupID; check.momentumTrigger = trigger
            // Defense at the publication boundary: momentum opinions are always descriptive.
            check.qualified = false; check.scenario = nil; check.verifiedQuote = nil
            initial.checks = [check]; initial.finishedAt = Date()
            initial.blocker = check.action == nil ? check.note : nil
            finishReceipt(initial, at: initial.finishedAt!, status: check.note)
        }
        return true
        #else
        return false
        #endif
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
        let now = Date()
        var value = initial
        value.finishedAt = now; value.blocker = reason; value.selectedSymbol = nil
        finishReceipt(value, at: now, status: reason)
    }

    /// Publish completed checks only after recording the terminal persistence result.
    func finishReceipt(_ value: Receipt, at: Date, status completedStatus: String) {
        var result = value
        result.finishedAt = at
        let saved = receiptStore?.saveSameDay(result) != false
        receiptStore?.finish(scanID: result.id, status: completedStatus, at: at)
        if !saved || receiptStore?.persistenceFailed(scanID: result.id) == true {
            result.selectedSymbol = nil; result.blocker = Self.receiptFailure
        }
        receipt = result; status = result.blocker ?? completedStatus; restored = false
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
        result.mode = mode; result.microcapScreen = initial?.microcapScreen
        result.marketMomentum = initial?.marketMomentum
        if isAstra, let screen = result.microcapScreen { result.selection = "\(screen.rows.count) reference rows; \(screen.detailedCount) detailed screens; \(listings.count) passed candidates. \(screen.unassessedCount) eligible candidates beyond the detail limit remain unassessed." }
        func active() -> Bool {
            !Task.isCancelled && allowed() && receiptStore?.persistenceFailed(scanID: id) != true
                && clock() >= started && Self.session(at: clock()) != nil
        }
        func finish(_ blocker: String?) {
            result.blocker = blocker
            finishReceipt(result, at: clock(), status: blocker ?? "App-ranked \(analyst)-qualified pick: \(result.selectedSymbol ?? "none")")
        }
        guard active() else { finish("Research interrupted or outside the verified same-day entry session."); return }
        guard !listings.isEmpty, Set(listings.map(\.ticker)).count == listings.count,
              listings.allSatisfy({ listing in
                let exchangeAllowed = listing.primary_exchange == "XNAS" || (mode == .largecap
                    && result.microcapScreen?.profile == .largecap
                    && result.microcapScreen?.rows.contains { $0.symbol == listing.ticker && $0.sp500Membership != nil && $0.status == .passed } == true)
                return listing.active && listing.type == "CS" && exchangeAllowed
                    && listing.currency_name?.lowercased() == "usd" && StockSageHorizonResearch.validTicker(listing.ticker)
              }), !isAstra || result.microcapScreen?.profile == mode.screenProfile else {
            finish("The bounded common-share shortlist or its research mode could not be verified."); return
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
                else { status = "\(title) research · \(completed)/\(listings.count) checks completed" }
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

    nonisolated static let microcapInstructions = instructions + """

    Use the supplied dated business-quality evidence as context for this same-day trade. Distinguish provider-reported ratios from app-calculated ratios, their formulas, financial periods, filing dates and unavailable inputs. A low valuation multiple or high accounting return does not establish an intraday entry. Negative earnings, equity or capital can make ratios not meaningful. Do not infer insider ownership from free float or insider trades. Do not call earnings normalized, recurring or comparable across sectors unless explicit supplied evidence establishes it. Reported one-off items and commodity-cycle exposure require context; do not invent adjustments or sector peer rankings. Social-media anecdotes are methodology references, not verified company evidence or proof of returns. Read the requested market-cap profile from the supplied screen policy: never apply Micro cap float, gap or RVOL cutoffs to Large cap. Use dated market-proxy and stock momentum evidence to discuss alignment or divergence; missing or stale intervals are unavailable, not flat. A rising price alone never qualifies a trade. Keep the same-day horizon and all supplied qualification requirements.
    """

    private static func assess(_ item: StockSageHorizonResearch.Listing, activity: Double,
        store: StockSageStore, key: String, config: StockSageLocalModelServer.Config?,
        regular: Set<Int64>, allowed: @escaping @MainActor @Sendable () -> Bool, observer: Observer?,
        microcap: StockSageMicrocapScreen.Result? = nil, admitSetup: ((String) -> Bool)? = nil,
        capMode: Mode = .microcap, marketMomentum: StockSageMomentum.Market? = nil,
        fundamentalsAccess: StockSageMassive.Access = .init()) async -> Check {
        var result = Check(symbol: item.ticker, name: item.name, at: Date(), note: "Not assessed")
        result.activity = activity; result.model = microcap == nil ? (config?.model ?? "") : "gpt-6-astra"
        func failed(_ reason: String) -> Check { result.note = reason; result.qualified = false; return result }
        guard allowed(), Self.session(at: Date()) != nil else { return failed("Research interrupted or entry session ended.") }
        async let background = StockSageHorizonResearch.gather(item, store: store, key: key, allowed: allowed)
        async let business: StockSageFundamentals.Snapshot? = microcap == nil ? nil
            : StockSageFundamentals.collect(symbol: item.ticker, asOf: Date(), access: fundamentalsAccess)
        let (gathered, fundamentals) = await (background, business)
        result.fundamentals = fundamentals
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
            from: max(window.open, requestTime.addingTimeInterval(-3600)), now: requestTime, access: fundamentalsAccess),
              allowed(), let quote = await StockSageMassiveTicks.freshResearchNBBO(symbol: item.ticker, regularConditions: regular, access: fundamentalsAccess),
              allowed(), quote.matches(item.ticker) else {
            return failed("Completed minute coverage, current eligible bid/ask, or observed stop/target failed the same-day screen. Trade-only fallback cannot qualify.")
        }
        return await assessCaptured(capture, item: item, activity: activity, intraday: intraday, quote: quote,
            config: config, allowed: allowed, observer: observer, microcap: microcap, admitSetup: admitSetup,
            fundamentals: fundamentals, capMode: capMode, marketMomentum: marketMomentum)
    }

    /// The same production prompt/validator path, with a clock and transport seam for offline replay.
    static func assessCaptured(_ capture: StockSageHorizonResearch.Capture,
        item: StockSageHorizonResearch.Listing, activity: Double, intraday: StockSageMassiveTicks.Intraday,
        quote: StockSageNBBO, config: StockSageLocalModelServer.Config?,
        allowed: @escaping @MainActor () -> Bool, observer: Observer? = nil,
        clock: @escaping @MainActor () -> Date = Date.init,
        modelTransport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
        microcap: StockSageMicrocapScreen.Result? = nil, admitSetup: ((String) -> Bool)? = nil,
        fundamentals: StockSageFundamentals.Snapshot? = nil,
        capMode: Mode = .microcap, marketMomentum: StockSageMomentum.Market? = nil,
        codexAssessment: ((String, String, Data) async -> Result<StockSageCodexResearch.Completion, StockSageCodexResearch.Failure>)? = nil) async -> Check {
        var result = Check(symbol: item.ticker, name: item.name, at: clock(), note: "Not assessed")
        result.activity = activity; result.model = microcap == nil ? (config?.model ?? "") : "gpt-6-astra"
        result.fundamentals = microcap == nil ? nil : fundamentals
        if microcap != nil, let marketMomentum {
            result.momentum = StockSageMomentum.stock(symbol: item.ticker, intraday: intraday, market: marketMomentum, now: clock())
        }
        func failed(_ reason: String) -> Check { result.note = reason; result.qualified = false; return result }
        let microcapValid = microcap.map { screen in
            capMode.isAstra && screen.profile == capMode.screenProfile && screen.blocker == nil
                && screen.facts(for: item.ticker).count == 4
                && (0...180).contains(clock().timeIntervalSince(screen.cutoff))
                && screen.rows.contains { $0.symbol == item.ticker && $0.status == .passed }
        } ?? false
        let modelValid = microcap != nil ? microcapValid
            : (config?.requiresStrictOutput == true && config?.model == StockSageLocalModelServer.gemmaModel)
        guard allowed(), modelValid,
              !capture.blockedByThrottle, capture.isFresh(at: clock()), quote.matches(item.ticker),
              let window = Self.session(at: clock()), let scenario = Self.scenario(intraday, quote: quote, at: clock()) else {
            return failed("The requested model, fresh public evidence, eligible quote or observed same-day scenario is unavailable.")
        }
        result.at = clock(); result.scenario = scenario; result.capturedQuote = Quote(quote)
        let deadline = min(capture.at.addingTimeInterval(300), intraday.asOf.addingTimeInterval(180), window.close.addingTimeInterval(-300),
            microcap?.cutoff.addingTimeInterval(180) ?? .distantFuture)
        result.expiresAt = deadline
        func active() -> Bool {
            allowed() && clock() >= result.at && clock() <= deadline && Self.session(at: clock()) != nil
                && capture.isFresh(at: clock()) && intraday.fresh(at: clock())
                && (microcap.map { (0...180).contains(clock().timeIntervalSince($0.cutoff)) } ?? true)
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
        if let microcap {
            extra += microcap.facts(for: item.ticker)
            if let marketMomentum { extra += marketMomentum.facts(at: result.at) }
            if let momentum = result.momentum, let marketMomentum { extra += momentum.facts(at: result.at, market: marketMomentum) }
            if let fundamentals, fundamentals.symbol == item.ticker,
               fundamentals.asOf <= result.at, fundamentals.retrievedAt <= result.at,
               (0...300).contains(result.at.timeIntervalSince(fundamentals.retrievedAt)) {
                extra += fundamentals.facts
            } else {
                extra.append(.init(key: "microcap.fundamentals.unavailable",
                    text: "Business-quality collection is unavailable, mismatched or stale. No company-quality ratio or insider ownership can be inferred from this missing evidence.",
                    required: true, availability: .missing, factClass: .coverageGap,
                    source: "StockSage fundamentals collection", observedAt: result.at))
            }
        }
        let packet = StockSageAIAssessment.EvidencePacket(facts: original.facts + extra,
            prePromptOmittedRecordCount: original.prePromptOmittedRecordCount)
        result.packet = packet
        guard extra.contains(where: { $0.key.hasPrefix("sameDay.catalyst.") }) else {
            return failed("No usable public news or filing record dated today; no same-day model request.")
        }
        let optional = packet.facts.filter { !$0.required }, mandatory = packet.facts.filter(\.required)
        guard let fitted = StockSageAIAssessment.fittedResearchPrompt(optional: optional.map(\.text), mandatory: mandatory.map(\.text),
            system: { _ in microcap == nil ? instructions : microcapInstructions }, optionalKeys: optional.map(\.key), outputTokens: config?.reservedOutputTokens(for: 192) ?? 384) else {
            return failed("Required same-day evidence could not fit the bounded research prompt.")
        }
        let offered = Array(optional.prefix(fitted.optionalKept)) + mandatory
        result.packet = .init(facts: offered, prePromptOmittedRecordCount: packet.prePromptOmittedRecordCount + fitted.omitted)
        guard active() else { return failed("Evidence expired or research was interrupted before inference.") }
        if microcap != nil {
            #if os(macOS)
            guard let schema = StockSageAIAssessment.responseSchema(facts: fitted.facts) else {
                return failed("Astra output schema could not be prepared.")
            }
            let setupID = StockSageMicrocapMonitor.setupID(symbol: item.ticker, facts: offered, at: result.at, mode: capMode)
            guard admitSetup?(setupID) ?? true else {
                return failed("No new Astra request was admitted. Check saved setup history and watching status.")
            }
            result.setupID = setupID
            let response: Result<StockSageCodexResearch.Completion, StockSageCodexResearch.Failure>
            if let codexAssessment { response = await codexAssessment(fitted.system, fitted.user, schema) }
            else { response = await StockSageCodexResearch.complete(system: fitted.system, user: fitted.user,
                schema: schema, deadline: deadline, allowed: active) }
            switch response {
            case .failure(let failure): result.codexAudit = failure.audit; return failed(failure.message)
            case .success(let completion):
                result.codexAudit = completion.audit; result.rawModelOutput = completion.text
                guard active() else { return failed("Evidence expired or watching stopped during Astra assessment. The original response is retained.") }
                guard completion.audit.requestedModel == StockSageCodexResearch.model,
                      completion.audit.requestedEffort == "ultra", completion.audit.terminalStatus == "completed",
                      completion.audit.reportedModel.map({ $0 == StockSageCodexResearch.model }) ?? true,
                      case .success(let verdict) = StockSageAIAssessment.validate(completion.text, facts: fitted.facts) else {
                    return failed("Astra output failed native model, schema or evidence validation; the original response is retained.")
                }
                result.action = verdict.action.rawValue; result.reason = verdict.reason; result.risk = verdict.risk; result.evidence = verdict.evidence
                result.quality = StockSageAIAssessment.quality(verdict, offered: offered, symbol: item.ticker)
                result.qualified = Self.qualifies(verdict, facts: offered, at: clock())
                result.note = result.qualified ? "Astra opinion passed the unvalidated \(capMode.title) and same-day screen."
                    : "Astra opinion did not pass the same-day action and citation gates."
                if !fitted.isComplete { result.note += " \(fitted.omitted) optional records omitted; mandatory records retained." }
                return result
            }
            #else
            return failed("Codex same-day assessment requires macOS.")
            #endif
        }
        guard let config else { return failed("The strict Gemma configuration is unavailable.") }
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
