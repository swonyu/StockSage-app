import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct StockSagePaperAutomationPanel: View {
    @ObservedObject private var automation = StockSagePaperAutomation.shared
    #if os(macOS)
    @State private var exporting = false
    @State private var exportResult: String?
    #endif

    var body: some View {
        GroupBox("Qwen research and paper trading") {
            VStack(alignment: .leading, spacing: 10) {
                #if os(macOS)
                Self.attention(automation.error)
                #endif
                HStack {
                    Label(Self.modeLabel(running: automation.isRunning),
                          systemImage: automation.isRunning ? "play.circle.fill" : "pause.circle")
                    Spacer()
                    if automation.isRunning {
                        Button("Pause day trading") { automation.stop() }
                            .help("Stops day-trading research and position/exit checks. Cancels ordinary pending paper orders. Positions and triggered protective-exit intents remain, but no exit attempts run while paused.")
                            .accessibilityHint("Stops day-trading research and position/exit checks. Cancels ordinary pending paper orders. Positions and triggered protective-exit intents remain, but no exit attempts run while paused.")
                    } else {
                        Button("Start day trading") { automation.start() }
                    }
                }
                if let progress = automation.researchProgress {
                    Text(progress.isIndeterminate ? "Preparing market data and Qwen…" : "Research: \(progress.completedUnitCount)/\(progress.totalUnitCount) checks completed")
                        .font(.callout).monospacedDigit()
                    #if os(macOS)
                    ForEach(automation.researchingSymbols.sorted(), id: \.self) { symbol in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(symbol) · Checking sources and Qwen…")
                                .font(.caption).monospaced()
                            ProgressView()
                                .progressViewStyle(.linear)
                                .accessibilityLabel("\(symbol) research in progress")
                        }
                    }
                    let queued = max(0, progress.totalUnitCount - progress.completedUnitCount - Int64(automation.researchingSymbols.count))
                    if queued > 0 {
                        Text("\(queued) checks queued · waiting for a free worker")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    #else
                    ProgressView(progress)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Research checks completed")
                    #endif
                    Text("Ready results appear as they finish; other workers continue while a request is loading. Checks completed, not trades. Position and exit checks run separately from research.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(automation.status).font(.callout)
                #if !os(macOS)
                Text("Paper sessions: normal 04:00–20:00 · early-close 04:00–17:00 New York · exchange holidays closed")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Same-day only · close-out begins at 19:55 normally, 16:55 on published early-close days")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                if automation.hasLoadedBook {
                #if !os(macOS)
                if automation.book.open.contains(where: { StockSagePaperAutomation.dayExitDue(openedAt: $0.openedAt, now: Date()) }) {
                    Text("Close-out required: awaiting fresh later prices. No overnight or closing fill is assumed.")
                        .font(.callout).foregroundStyle(DS.Palette.warningSoft)
                }
                #endif
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                // A scheduled TimelineView entry can be older than a newly received quote.
                let at = Date()
                VStack(alignment: .leading, spacing: 10) {
                Text(Self.monitoringLabel(running: automation.isRunning, at: at))
                    .font(.callout.bold())
                Text("While StockSage is open and this Mac is awake: next position check 30 seconds after the previous check finishes. Fresh data is required; research does not pause these checks.")
                    .font(.caption).foregroundStyle(.secondary)
                #if os(macOS)
                if let warning = Self.closeOutWarning(book: automation.book, at: at, running: automation.isRunning) {
                    Text(warning).font(.callout).foregroundStyle(DS.Palette.warningSoft)
                }
                if let timing = Self.researchTiming(book: automation.book, at: at, running: automation.isRunning, researching: automation.isResearching) {
                    Text(timing).font(.caption).foregroundStyle(.secondary)
                }
                Self.pendingRequests(automation.book.pending, running: automation.isRunning, at: at)
                Self.accountSummary(book: automation.book, quotes: automation.quotes, at: at)
                #else
                HStack(spacing: 20) {
                    VStack(alignment: .leading) {
                        Text("Total paper cash").font(.caption)
                        Text(automation.book.cash, format: .currency(code: "USD")).monospacedDigit()
                    }
                    VStack(alignment: .leading) {
                        Text("Estimated liquidation value").font(.caption)
                        if let equity = automation.book.equity(quotes: automation.quotes, at: at) {
                            Text(equity, format: .currency(code: "USD")).monospacedDigit()
                            Text("Change from $10,000: \((equity - 10_000).formatted(.currency(code: "USD")))").font(.caption)
                        } else {
                            Text(automation.isRunning ? "Waiting for fresh position prices · checks retry automatically" : "Resume monitoring to refresh position prices")
                                .font(.caption)
                        }
                    }
                }
                    let sales = automation.book.unsettledSales(at: at)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settled available: \(automation.book.buyingCash(at: at).formatted(.currency(code: "USD"))) · Unsettled proceeds: \(automation.book.unsettledProceeds(at: at).formatted(.currency(code: "USD")))")
                        if automation.book.settledCash(at: at) < 0 {
                            Text("Legacy funding deficit: \((-automation.book.settledCash(at: at)).formatted(.currency(code: "USD"))). New entries wait for settlement; holdings and exits are retained.")
                                .foregroundStyle(DS.Palette.warningSoft)
                        }
                        if !sales.isEmpty {
                            DisclosureGroup("Scheduled paper settlements · \(sales.count)") {
                                ForEach(sales) { trade in
                                    if let closed = trade.closedAt, let date = StockSagePaperAutomation.settlementDate(forSaleAt: closed) {
                                        Text("\(trade.symbol): \(Self.settlementDateLabel(date)) New York · \((trade.exitPrice! * trade.shares).formatted(.currency(code: "USD")))")
                                    } else {
                                        Text("\(trade.symbol): settlement calendar unavailable; proceeds remain unspendable.")
                                            .foregroundStyle(DS.Palette.warningSoft)
                                    }
                                }
                            }
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                #endif
                }
                }
                Text("\(automation.book.open.count) paper positions · \(automation.book.pending.count) pending · \(automation.book.trades.filter { !$0.isOpen }.count) closed")
                    .font(.caption)
                #if !os(macOS)
                if let scan = automation.book.decisions.last(where: { $0.action.hasPrefix("Market scan") }) {
                    Text("Market coverage · \(scan.at.formatted(date: .omitted, time: .shortened))").font(.caption.bold())
                    Text(scan.reason).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Full US market discovery begins on the next research cycle; your watchlist is not the scan limit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #endif
                #if os(macOS)
                Self.recordedActivity(automation.book.decisions)
                DisclosureGroup("Market coverage and research cycles") {
                    Self.coverageSummary(automation.book.decisions)
                }.font(.caption)
                #else
                if let decision = automation.book.decisions.last(where: { !$0.symbol.isEmpty }) {
                    Text("Latest decision: \(decision.symbol) · \(Self.actionLabel(decision.action))").font(.callout.bold())
                    Text(decision.reason).font(.caption).foregroundStyle(.secondary)
                    if let plan = decision.plan { Self.entryPlan(plan) }
                }
                if let cycle = automation.book.decisions.last(where: { $0.action == "Research complete" }) {
                    Text("Last cycle · \(cycle.at.formatted(date: .omitted, time: .shortened)) · \(Self.reasonLabel(action: cycle.action, reason: cycle.reason))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if automation.isRunning, !automation.isResearching, StockSagePaperAutomation.entryWindowOpen(Date()), let last = automation.book.lastResearch {
                    Text("Next research due \(last.addingTimeInterval(StockSagePaperAutomation.interval).formatted(date: .omitted, time: .shortened)) · while awake, connected and in session")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #endif
                if let audit = automation.book.audit, !audit.archives.isEmpty {
                    Text("Older audit records preserved in \(audit.archives.count) verified archive chunks beside the account. Recent history is shown below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                } else {
                    Text("Paper balances and history unavailable: the saved account could not be verified. No new account balance is assumed.")
                        .font(.callout).foregroundStyle(DS.Palette.warningSoft)
                }
                #if !os(macOS)
                if let error = automation.error { Text(error).foregroundStyle(DS.Palette.warningSoft).font(.callout) }
                #endif
                if automation.hasLoadedBook, !automation.book.open.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paper positions").font(.callout.bold())
                        ForEach(automation.book.open) { trade in
                            Text("\(trade.symbol) · \(Int(trade.shares)) shares · entry $\(StockSageCurrency.adaptivePrice(trade.entry)) · stop $\(StockSageCurrency.adaptivePrice(trade.stop)) · target \(trade.target.map { "$" + StockSageCurrency.adaptivePrice($0) } ?? "not recorded")")
                                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                DisclosureGroup("Simulation policy and limitations") {
                    #if os(macOS)
                    Text("Paper sessions: normal 04:00–20:00 · early-close 04:00–17:00 New York · exchange holidays closed")
                    Text("Same-day only · close-out begins at 19:55 normally, 16:55 on published early-close days")
                    #endif
                    Text("Research screening accepts Massive observations up to one minute old; model decisions also require qualifying trade conditions. This does not make them executable: simulated fills and live labels retain their stricter ten-second limit. Partial source evidence stays visible when no verified model decision is available.")
                    Text("Same-day horizon only. Qwen receives completed minute bars from the latest hour, or explicitly labelled recent qualified trades when candles are unavailable. Individual trades are not candles or evidence of sufficient liquidity. Daily indicators are background, not intraday signals. New entries stop five minutes before the scheduled extended-session end and the timer requests exits independently of Qwen. If the app sleeps or fresh prices are missing, unresolved positions remain visible; overdue holdings block new buys and exits retry next open session. A same-day policy cannot guarantee a fill.")
                    Text("Separate $10,000 account. Full Massive US listed-market snapshots, excluding OTC. All supported fresh observations are screened, not individually analyzed by Qwen. Up to \(StockSagePaperAutomation.discoveryLimit) total checks per cycle: all paper holdings first, then affordable new candidates, least recently attempted first and daily dollar activity next. Research uses up to \(StockSagePaperAutomation.researchConcurrency) concurrent workers. Cycles start at least fifteen minutes apart and never overlap, so a longer cycle delays the next one. Missing/stale data and unsupported symbol formats are excluded. The feed can include ETFs; this is not a common-stock-only reference census. Your watchlist is unchanged.")
                    Text("Whole shares, long only, no margin, five positions maximum, and $2,000 maximum per new position. Buy/Strong Buy must cite an actual intraday observation to request an entry; daily background alone is insufficient. Sell/Reduce requests closing the entire simulated holding. Hold/Avoid creates no order. A completed scan is not a promise of a trade or profit.")
                    Text("Settled-cash simulation: purchases immediately reduce spending capacity; net sale proceeds wait until the scheduled T+1 settlement date. The calendar includes bank-only holidays and covers 2026 through January 2027; unknown dates keep proceeds unavailable. Release at New York midnight is a simulation convention, not confirmation of broker funds. Unexpected closures and settlement failures are not modeled. Total cash and equity still include unsettled receivables; historical fills are not rewritten.")
                    Text("Simulated fills require a qualified Massive SIP trade after the current attempt and no more than ten seconds old. The bounded tape check excludes average-price, prior-reference, corrected and unknown-condition trades. Each attempt expires after two minutes. A triggered stop retains its protective intent across expiry, price recovery, pause and restart until that holding closes; retries still need a later eligible observation. Ordinary model sell and target requests keep their existing expiry behavior. Costs assume 10 basis points per side; they do not measure spread, depth or extended-hours liquidity. A 2% stop and 4% target are simulation rules, not price forecasts.")
                    Text("Runs while this Mac is awake and StockSage is open. Published 2026 holidays and early closes are modeled; unsupported calendar years and stale or missing data block fills. Sleep, disconnects and missed research are never backfilled. Dividends, actual liquidity, broker minimum fees and corporate actions are not modeled; large price/basis changes pause the account for review. No real orders or real-journal records are created.")
                }.font(.caption).foregroundStyle(.secondary)
                if automation.hasLoadedBook {
                #if os(macOS)
                Button(exporting ? "Exporting verified history…" : "Export paper research…") { exportResearch() }
                    .disabled(exporting)
                    .help("Save the committed account, every referenced audit chunk and missing-evidence disclosures. No portfolio performance is calculated.")
                if let exportResult { Text(exportResult).font(.caption).textSelection(.enabled) }
                #endif
                DisclosureGroup("Research and decisions · latest \(min(100, automation.book.decisions.count))") {
                    ForEach(Array(automation.book.decisions.suffix(100).reversed())) { decision in
                        VStack(alignment: .leading, spacing: 4) {
                            #if os(macOS)
                            let recordedAt = "\(Self.activityDateLabel(decision.at)) New York"
                            #else
                            let recordedAt = decision.at.formatted(date: .abbreviated, time: .shortened)
                            #endif
                            Text("\(decision.symbol) \(Self.actionLabel(decision.action)) · \(recordedAt)").font(.caption.bold())
                            Text(Self.reasonLabel(action: decision.action, reason: decision.reason)).font(.callout)
                            if let plan = decision.plan { Self.entryPlan(plan) }
                            if !decision.risk.isEmpty { Text("Risk: \(decision.risk)").font(.caption) }
                            if !decision.facts.isEmpty {
                                DisclosureGroup(decision.action == "Unavailable" ? "Available source evidence · incomplete research" : "Saved evidence and model") {
                                    if decision.action == "Unavailable" {
                                        Text("Captured source observations only. No verified model opinion or paper order was created; these historical observations are not current fill prices.")
                                    } else {
                                        Text("Model: \(decision.model.isEmpty ? "Simulation rules" : decision.model). References: \(decision.evidence.joined(separator: ", "))")
                                    }
                                    ForEach(Array(decision.facts.enumerated()), id: \.offset) { index, fact in
                                        Text("F\(index + 1): \(fact)")
                                    }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    #if os(macOS)
    static func researchTiming(book: StockSagePaperAutomation.Book, at now: Date, running: Bool, researching: Bool) -> String? {
        guard running, !researching else { return nil }
        if let last = book.lastResearch, last > now {
            return "Clock precedes the saved cycle; waiting for monitor review."
        }
        guard StockSagePaperAutomation.entryWindowOpen(now) else { return nil }
        if StockSagePaperAutomation.researchDue(book: book, at: now) {
            return "Research due; waiting for monitor and eligible data."
        }
        guard let last = book.lastResearch else { return nil }
        return "Earliest next cycle: \(activityDateLabel(last.addingTimeInterval(StockSagePaperAutomation.interval))) New York · while awake, connected and in session"
    }

    static func closeOutWarning(book: StockSagePaperAutomation.Book, at now: Date, running: Bool) -> String? {
        guard book.open.contains(where: { StockSagePaperAutomation.dayExitDue(openedAt: $0.openedAt, now: now) }) else { return nil }
        return running ? "Close-out required: awaiting fresh later prices. No overnight or closing fill is assumed."
            : "Close-out required; exit checks are paused. No overnight or closing fill is assumed."
    }

    @ViewBuilder static func attention(_ error: String?) -> some View {
        if let error {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Label("Needs attention", systemImage: "exclamationmark.triangle").font(.callout.bold())
                Text(verbatim: error).font(.callout)
            }
            .foregroundStyle(DS.Palette.warningSoft).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func coverageSummary(_ decisions: [StockSagePaperAutomation.Decision]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let scan = decisions.last(where: { $0.action.hasPrefix("Market scan") }) {
                Text("Market coverage · \(activityDateLabel(scan.at)) New York").font(.caption.bold())
                Text(verbatim: scan.reason).font(.caption)
            } else {
                Text("No scan summary in recent history.").font(.caption)
            }
            if let cycle = decisions.last(where: { $0.action == "Research complete" }) {
                Text("Last completed cycle · \(activityDateLabel(cycle.at)) New York").font(.caption.bold())
                Text(verbatim: cycle.reason).font(.caption)
            } else {
                Text("No completed-cycle summary in recent history.").font(.caption)
            }
        }
        .foregroundStyle(.secondary).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func accountSummary(book: StockSagePaperAutomation.Book,
                               quotes: [String: StockSageQuoteService.LiveQuote], at: Date) -> some View {
        let settled = book.settledCash(at: at)
        let sales = book.unsettledSales(at: at)
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            LabeledContent("Settled spending capacity") {
                Text(book.buyingCash(at: at), format: .currency(code: "USD")).monospacedDigit()
            }
            if settled < 0 {
                Text("Legacy funding deficit: \((-settled).formatted(.currency(code: "USD"))). New entries wait for settlement; holdings and exits are retained.")
                    .font(.caption).foregroundStyle(DS.Palette.warningSoft)
            }
            LabeledContent("Total paper cash") {
                Text(book.cash, format: .currency(code: "USD")).monospacedDigit()
            }
            LabeledContent("Unsettled proceeds") {
                Text(book.unsettledProceeds(at: at), format: .currency(code: "USD")).monospacedDigit()
            }
            if let equity = book.equity(quotes: quotes, at: at) {
                LabeledContent("Estimated paper equity") {
                    Text(equity, format: .currency(code: "USD")).monospacedDigit()
                }
                Text("Change from $10,000: \((equity - 10_000).formatted(.currency(code: "USD")))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("Estimated paper equity") {
                    Text("Fresh marks unavailable").font(.caption)
                }
            }
            Text("Calculated \(Self.activityDateLabel(at)) New York. Calculation time, not a market timestamp or broker balance.")
                .font(.caption).foregroundStyle(.secondary)
            if !sales.isEmpty {
                DisclosureGroup("Scheduled paper settlements · \(sales.count)") {
                    ForEach(sales) { trade in
                        if let closed = trade.closedAt,
                           let date = StockSagePaperAutomation.settlementDate(forSaleAt: closed) {
                            Text("\(trade.symbol): \(Self.settlementDateLabel(date)) New York · \((trade.exitPrice! * trade.shares).formatted(.currency(code: "USD")))")
                        } else {
                            Text("\(trade.symbol): settlement calendar unavailable; proceeds remain unspendable.")
                                .foregroundStyle(DS.Palette.warningSoft)
                        }
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func latestActivity(in decisions: [StockSagePaperAutomation.Decision]) -> StockSagePaperAutomation.Decision? {
        decisions.last
    }

    static func latestNoFillEvidence(in decisions: [StockSagePaperAutomation.Decision]) -> StockSagePaperAutomation.Decision? {
        decisions.last { ["Unavailable", "Skipped", "Expired", "Cancelled"].contains($0.action) }
    }

    static func pendingStatus(_ request: StockSagePaperAutomation.Pending, running: Bool, at now: Date) -> String {
        if !running { return "Monitoring paused; no attempts run." }
        if request.buy && !StockSagePaperAutomation.entryWindowOpen(now) {
            return "Entry window closed; awaiting monitor processing."
        }
        if now < request.at { return "Current clock precedes the saved attempt; awaiting monitor processing." }
        if now.timeIntervalSince(request.at) >= 120 {
            return "Attempt window elapsed; awaiting monitor processing."
        }
        if !StockSagePaperAutomation.paperSessionOpen(now) {
            return "No fills outside a supported paper session."
        }
        return "Awaiting a later eligible observation; detailed cause not recorded."
    }

    @ViewBuilder static func pendingRequests(_ requests: [StockSagePaperAutomation.Pending], running: Bool, at now: Date) -> some View {
        if !requests.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Pending paper requests").font(.callout.bold())
                ForEach(requests) { request in
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("\(request.symbol) · \(request.buy ? "Buy requested" : "Exit requested") · Not filled")
                            .font(.caption.bold())
                        Text("Current attempt: \(activityDateLabel(request.at)) New York")
                            .font(.caption).foregroundStyle(.secondary)
                        if request.protectiveTradeID != nil {
                            Text("Protective intent retained").font(.caption.bold())
                                .foregroundStyle(DS.Palette.warningSoft)
                        }
                        Text(pendingStatus(request, running: running, at: now))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder static func recordedActivity(_ decisions: [StockSagePaperAutomation.Decision]) -> some View {
        let latest = latestActivity(in: decisions)
        let noFill = latestNoFillEvidence(in: decisions)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let latest {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    activityRow(latest, title: "Latest recorded activity")
                    if let plan = latest.plan { entryPlan(plan) }
                }
            } else {
                Text("No recorded activity in recent history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let noFill {
                if noFill.id != latest?.id {
                    activityRow(noFill, title: "Latest recorded no-fill evidence")
                }
            } else {
                Text("No matching no-fill record in recent history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func activityRow(_ decision: StockSagePaperAutomation.Decision, title: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(title).font(.callout.bold())
            Text("\(activityDateLabel(decision.at)) New York · \(decision.symbol.isEmpty ? "General activity" : decision.symbol) · \(actionLabel(decision.action))")
                .font(.caption.bold())
            Text(verbatim: decision.reason).font(.caption).foregroundStyle(.secondary)
            Text("Historical record; does not establish current state or why a request is pending.")
                .font(.caption).foregroundStyle(.secondary)
            Text(decision.action == "Paper Buy" || decision.action == "Paper Sell"
                 ? "Simulated fill · not a broker execution." : "This record is not a fill.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func activityDateLabel(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = TimeZone(identifier: "America/New_York")!
        return style.format(date)
    }

    private func exportResearch() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "stocksage-paper-research.json"
        panel.message = "Private paper history and model evidence. This does not establish portfolio profitability."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true; exportResult = nil
        Task {
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() }; exporting = false }
            do {
                try await automation.exportResearch(to: destination)
                exportResult = "Research export saved with verified archives and missing-evidence disclosures. Portfolio economics: not evaluated."
            } catch {
                exportResult = "Export failed: \(error.localizedDescription) Existing history and previous export preserved."
            }
        }
    }
    #endif

    static func modeLabel(running: Bool) -> String {
        running ? "Day trading enabled · simulation only" : "Day trading paused · simulation only"
    }

    static func monitoringLabel(running: Bool, at date: Date) -> String {
        guard running else { return "Position monitoring paused" }
        return StockSagePaperAutomation.paperSessionOpen(date)
            ? "Position and exit monitoring active"
            : "Monitoring enabled · waiting for the next supported session"
    }

    private static func entryPlan(_ plan: StockSagePaperAutomation.EntryPlan) -> some View {
        #if os(macOS)
        let observedAt = "\(activityDateLabel(plan.at)) New York"
        #else
        let observedAt = plan.at.formatted(date: .abbreviated, time: .shortened)
        #endif
        return VStack(alignment: .leading, spacing: 4) {
            Text("Entry reference: $\(StockSageCurrency.adaptivePrice(plan.entry)) · Stop-loss: $\(StockSageCurrency.adaptivePrice(plan.stop)) · Target: $\(StockSageCurrency.adaptivePrice(plan.target))")
                .font(.callout.bold()).monospacedDigit()
            Text("Preview from Massive observation \(observedAt): entry includes the assumed 10bps buy cost, stop 2% below and target 4% above. Not a fill or prediction. Actual paper levels use the later simulated fill, shown under Paper positions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func actionLabel(_ action: String) -> String {
        switch action {
        case "Unavailable": "Incomplete research"
        case "Market scan unavailable": "Market scan incomplete"
        default: action
        }
    }

    static func reasonLabel(action: String, reason: String) -> String {
        guard action == "Research complete" else { return reason }
        return reason.replacingOccurrences(of: " unavailable checks.", with: " incomplete checks.")
    }

    private static func settlementDateLabel(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(identifier: "America/New_York")!
        return style.format(date)
    }
}
