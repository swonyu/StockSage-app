import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct StockSagePaperAutomationPanel: View {
    @ObservedObject private var automation = StockSagePaperAutomation.shared
    // Names the model actually configured for a request in flight, matching the @AppStorage
    // key the settings pane itself writes -- not a hardcoded "Qwen" left over from before the
    // Gemma switch (Qwen removal Step 8).
    @AppStorage(StockSageLocalModelServer.modelKey) private var serverModel: String = StockSageLocalModelServer.defaultModel
    #if os(macOS)
    @State private var exporting = false
    @State private var exportResult: String?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            #if os(macOS)
            Self.attention(automation.error)
            #endif
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) {
                        modeHeading
                        Spacer(minLength: 16)
                        modeButton
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        modeHeading
                        modeButton
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("New legacy paper runs are disabled. After relaunch, legacy open positions are not monitored and no paper exits are attempted. Recorded balances, positions and history are retained.")
                        .font(.callout).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    #if os(macOS)
                    let mode = Label(Self.modeLabel(running: automation.isRunning),
                                     systemImage: automation.isRunning ? "play.circle.fill" : "pause.circle")
                        .font(.headline)
                    let status = Text(automation.status).font(.callout).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 16) { mode; status }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 6) { mode; status }
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    #endif
                    if automation.isRunning {
                        Text("Pausing stops both research and exit checks. Open paper positions remain.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    researchProgress
                    #if !os(macOS)
                    Text(automation.status).font(.callout)
                    #endif
                }
                if automation.hasLoadedBook {
                    accountAndPositions
                } else {
                    Text("Paper balances and history unavailable: the saved account could not be verified. No new account balance is assumed.")
                        .font(.callout).foregroundStyle(DS.Palette.warningSoft)
                }
            }
            if automation.hasLoadedBook {
                Divider()
                activityHistory
            }
            #if !os(macOS)
            if let error = automation.error { Text(error).foregroundStyle(DS.Palette.warningSoft).font(.callout) }
            #endif
            simulationPolicy
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Legacy paper history")
                #if os(macOS)
                .font(.largeTitle.weight(.semibold))
                #else
                .font(.largeTitle.bold())
                #endif
            Text("Recorded simulation. Manual research offers one same-day pick and Top 5 for 1–7 or 7–14 trading days.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #if !os(macOS)
            Label(Self.modeLabel(running: automation.isRunning),
                  systemImage: automation.isRunning ? "play.circle.fill" : "pause.circle")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }

    @ViewBuilder private var modeButton: some View {
        if automation.isRunning {
            Button("Pause legacy run") { automation.stop() }
                .buttonStyle(.bordered).controlSize(.large)
                .help("Stops the active legacy research and position/exit checks. Cancels ordinary pending paper orders. Positions and triggered protective-exit intents remain. New legacy runs are disabled.")
                .accessibilityHint("Stops the active legacy research and position/exit checks. Cancels ordinary pending paper orders. Positions and triggered protective-exit intents remain. New legacy runs are disabled.")
        }
    }

    @ViewBuilder private var researchProgress: some View {
        if let progress = automation.researchProgress {
            Text(progress.isIndeterminate ? "Preparing market data and \(serverModel)…" : "Research: \(progress.completedUnitCount)/\(progress.totalUnitCount) checks completed")
                .font(.callout).monospacedDigit()
            #if os(macOS)
            ForEach(automation.researchingSymbols.sorted(), id: \.self) { symbol in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(symbol) · Checking sources and \(serverModel)…")
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
    }

    private var accountAndPositions: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            // A scheduled TimelineView entry can be older than a newly received quote.
            let at = Date()
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.monitoringLabel(running: automation.isRunning, at: at))
                        .font(.headline)
                    if automation.isRunning {
                        Text("This already-active legacy run checks positions while StockSage is open and this device is awake. The next check follows 30 seconds after the previous check finishes. Fresh data is required. Pausing or quitting stops monitoring; it will not restart after relaunch.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Legacy monitoring is off. Open positions and pending requests remain as records; no closing fill is assumed.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    #if os(macOS)
                    if let warning = Self.closeOutWarning(book: automation.book, at: at, running: automation.isRunning) {
                        Text(warning).font(.callout).foregroundStyle(DS.Palette.warningSoft)
                    }
                    if let timing = Self.researchTiming(book: automation.book, at: at, running: automation.isRunning, researching: automation.isResearching) {
                        Text(timing).font(.callout).foregroundStyle(.secondary)
                    }
                    #else
                    if automation.book.open.contains(where: { StockSagePaperAutomation.dayExitDue(openedAt: $0.openedAt, now: Date()) }) {
                        Text("Close-out required: awaiting fresh later prices. No overnight or closing fill is assumed.")
                            .font(.callout).foregroundStyle(DS.Palette.warningSoft)
                    }
                    #endif
                }
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                #if os(macOS)
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
                            Text(automation.isRunning ? "Waiting for fresh position prices · checks retry automatically" : "Fresh position marks unavailable · legacy monitoring is off")
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
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Positions and requests").font(.title2.weight(.semibold))
                        Text("\(automation.book.open.count) paper positions · \(automation.book.pending.count) pending · \(automation.book.trades.filter { !$0.isOpen }.count) closed")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    paperPositions
                    #if os(macOS)
                    Self.pendingRequests(automation.book.pending, running: automation.isRunning, at: at)
                    #endif
                }
            }
        }
    }

    private var paperPositions: some View { Self.paperPositions(automation.book.open) }

    @ViewBuilder static func paperPositions(_ positions: [TradeRecord]) -> some View {
        if !positions.isEmpty {
            let stackedPositions = VStack(alignment: .leading, spacing: 16) {
                Text("Paper positions").font(.headline)
                ForEach(positions) { trade in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(trade.symbol).font(.title3.bold())
                            Text("\(Int(trade.shares)) shares").font(.callout).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Entry").foregroundStyle(.secondary)
                                Text("$\(StockSageCurrency.adaptivePrice(trade.entry))").fontWeight(.medium)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Stop").foregroundStyle(.secondary)
                                Text("$\(StockSageCurrency.adaptivePrice(trade.stop))").fontWeight(.medium)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Target").foregroundStyle(.secondary)
                                Text(trade.target.map { "$" + StockSageCurrency.adaptivePrice($0) } ?? "not recorded").fontWeight(.medium)
                            }
                        }
                        .font(.callout).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            }
            #if os(macOS)
            ViewThatFits(in: .horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                    GridRow {
                        Text("Paper positions").font(.headline)
                        Text("Entry").foregroundStyle(.secondary)
                        Text("Stop").foregroundStyle(.secondary)
                        Text("Target").foregroundStyle(.secondary)
                    }
                    ForEach(positions) { trade in
                        GridRow {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(trade.symbol).font(.title3.weight(.semibold))
                                Text("\(Int(trade.shares)) shares").foregroundStyle(.secondary)
                            }
                            Text("$\(StockSageCurrency.adaptivePrice(trade.entry))").fontWeight(.medium)
                                .accessibilityLabel("\(trade.symbol), entry $\(StockSageCurrency.adaptivePrice(trade.entry))")
                            Text("$\(StockSageCurrency.adaptivePrice(trade.stop))").fontWeight(.medium)
                                .accessibilityLabel("\(trade.symbol), stop $\(StockSageCurrency.adaptivePrice(trade.stop))")
                            Text(trade.target.map { "$" + StockSageCurrency.adaptivePrice($0) } ?? "not recorded")
                                .fontWeight(.medium)
                                .accessibilityLabel("\(trade.symbol), target " + (trade.target.map { "$" + StockSageCurrency.adaptivePrice($0) } ?? "not recorded"))
                        }
                    }
                }
                .font(.callout).monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                stackedPositions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            #else
            stackedPositions
            #endif
        }
    }

    private var activityHistory: some View {
        VStack(alignment: .leading, spacing: 20) {
            #if os(macOS)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Recorded activity").font(.title2.weight(.semibold))
                    Spacer(minLength: 12)
                    exportButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recorded activity").font(.title2.weight(.semibold))
                    exportButton
                }
            }
            if let exportResult { Text(exportResult).font(.callout).textSelection(.enabled) }
            Self.recordedActivity(automation.book.decisions)
            DisclosureGroup("Market coverage and research cycles") {
                Self.coverageSummary(automation.book.decisions).padding(.top, 8)
            }.font(.callout)
            #else
            if let scan = automation.book.decisions.last(where: { $0.action.hasPrefix("Market scan") }) {
                Text("Market coverage · \(scan.at.formatted(date: .omitted, time: .shortened))").font(.caption.bold())
                Text(scan.reason).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No scan summary in recent legacy history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                    .font(.callout).foregroundStyle(.secondary)
            }
            researchHistory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(macOS)
    private var exportButton: some View {
        Button(exporting ? "Exporting verified history…" : "Export paper research…") { exportResearch() }
            .disabled(exporting)
            .help("Save the committed account, every referenced audit chunk and missing-evidence disclosures. No portfolio performance is calculated.")
    }
    #endif

    private var simulationPolicy: some View {
        DisclosureGroup("Legacy simulation policy and limitations") {
            Text("These rules explain the retained same-day simulation history. They do not define the current Research horizons. New legacy runs are disabled; an already-active run can be paused. Legacy positions are not monitored after relaunch.")
            #if os(macOS)
            Text("Paper sessions: normal 04:00–20:00 · early-close 04:00–17:00 New York · exchange holidays closed")
            Text("Same-day only · close-out begins at 19:55 normally, 16:55 on published early-close days")
            #endif
            Text("Research screening accepts Massive observations up to one minute old; model decisions also require qualifying trade conditions. This does not make them executable: simulated fills and live labels retain their stricter ten-second limit. Partial source evidence stays visible when no verified model decision is available.")
            Text("Same-day horizon only. The model receives completed minute bars from the latest hour, or explicitly labelled recent qualified trades when candles are unavailable. Individual trades are not candles or evidence of sufficient liquidity. Daily indicators are background, not intraday signals. New entries stop five minutes before the scheduled extended-session end and the timer requests exits independently of the model. If the app sleeps or fresh prices are missing, unresolved positions remain visible; overdue holdings block new buys and exits retry next open session. A same-day policy cannot guarantee a fill.")
            Text("Separate $10,000 account. Full Massive US listed-market snapshots, excluding OTC. All supported fresh observations are screened, not individually analyzed by the model. Up to \(StockSagePaperAutomation.discoveryLimit) total checks per cycle: all paper holdings first, then affordable new candidates, least recently attempted first and daily dollar activity next. Research uses up to \(StockSagePaperAutomation.researchConcurrency) concurrent workers. Cycles start at least fifteen minutes apart and never overlap, so a longer cycle delays the next one. Missing/stale data and unsupported symbol formats are excluded. The feed can include ETFs; this is not a common-stock-only reference census. Your watchlist is unchanged.")
            Text("Whole shares, long only, no margin, five positions maximum, and $2,000 maximum per new position. Buy/Strong Buy must cite an actual intraday observation to request an entry; daily background alone is insufficient. Sell/Reduce requests closing the entire simulated holding. Hold/Avoid creates no order. A completed scan is not a promise of a trade or profit.")
            Text("Settled-cash simulation: purchases immediately reduce spending capacity; net sale proceeds wait until the scheduled T+1 settlement date. The calendar includes bank-only holidays and covers 2026 through January 2027; unknown dates keep proceeds unavailable. Release at New York midnight is a simulation convention, not confirmation of broker funds. Unexpected closures and settlement failures are not modeled. Total cash and equity still include unsettled receivables; historical fills are not rewritten.")
            Text("Simulated fills require a qualified Massive SIP trade after the current attempt and no more than ten seconds old. The bounded tape check excludes average-price, prior-reference, corrected and unknown-condition trades. Each attempt expires after two minutes. A triggered stop retains its protective intent across expiry, price recovery, pause and restart until that holding closes; retries still need a later eligible observation. Ordinary model sell and target requests keep their existing expiry behavior. Costs assume 10 basis points per side; they do not measure spread, depth or extended-hours liquidity. A 2% stop and 4% target are simulation rules, not price forecasts.")
            Text("The legacy simulator required this device to be awake with StockSage open. Published 2026 holidays and early closes were modeled; unsupported calendar years and stale or missing data block fills. Sleep, disconnects and missed research are never backfilled. Dividends, actual liquidity, broker minimum fees and corporate actions are not modeled; large price/basis changes pause the account for review. No real orders or real-journal records are created.")
        }.font(.callout).foregroundStyle(.secondary)
    }

    private var researchHistory: some View {
        DisclosureGroup("Research and decisions · latest \(min(100, automation.book.decisions.count))") {
            ForEach(Array(automation.book.decisions.suffix(100).reversed())) { decision in
                VStack(alignment: .leading, spacing: 8) {
                    #if os(macOS)
                    let recordedAt = "\(Self.activityDateLabel(decision.at)) New York"
                    #else
                    let recordedAt = decision.at.formatted(date: .abbreviated, time: .shortened)
                    #endif
                    Text("\(decision.symbol) \(Self.actionLabel(decision.action)) · \(recordedAt)").font(.callout.bold())
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
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                Divider()
            }
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
        VStack(alignment: .leading, spacing: 12) {
            if let scan = decisions.last(where: { $0.action.hasPrefix("Market scan") }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Market coverage · \(activityDateLabel(scan.at)) New York").font(.callout.bold())
                    Text(verbatim: scan.reason).font(.callout)
                }
            } else {
                Text("No scan summary in recent history.").font(.callout)
            }
            if let cycle = decisions.last(where: { $0.action == "Research complete" }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last completed cycle · \(activityDateLabel(cycle.at)) New York").font(.callout.bold())
                    Text(verbatim: cycle.reason).font(.callout)
                }
            } else {
                Text("No completed-cycle summary in recent history.").font(.callout)
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
        return VStack(alignment: .leading, spacing: 16) {
            Text("Paper account").font(.title2.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 24, alignment: .topLeading)],
                      alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Settled spending capacity").font(.callout).foregroundStyle(.secondary)
                    Text(book.buyingCash(at: at), format: .currency(code: "USD"))
                        .font(.title2.weight(.medium)).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Estimated paper equity").font(.callout).foregroundStyle(.secondary)
                    if let equity = book.equity(quotes: quotes, at: at) {
                        Text(equity, format: .currency(code: "USD"))
                            .font(.title2.weight(.medium)).monospacedDigit()
                        Text("Change from $10,000: \((equity - 10_000).formatted(.currency(code: "USD")))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Fresh marks unavailable").font(.title3).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Total paper cash").font(.callout).foregroundStyle(.secondary)
                    Text(book.cash, format: .currency(code: "USD"))
                        .font(.title2.weight(.medium)).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Unsettled proceeds").font(.callout).foregroundStyle(.secondary)
                    Text(book.unsettledProceeds(at: at), format: .currency(code: "USD"))
                        .font(.title2.weight(.medium)).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .combine)
            }
            if settled < 0 {
                Text("Legacy funding deficit: \((-settled).formatted(.currency(code: "USD"))). New entries wait for settlement; holdings and exits are retained.")
                    .font(.callout).foregroundStyle(DS.Palette.warningSoft)
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
                }.font(.callout).foregroundStyle(.secondary)
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
        if request.protectiveTradeID != nil && !StockSagePaperAutomation.paperSessionOpen(now) {
            return "Protective intent retained; waiting for the next supported paper session."
        }
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
            VStack(alignment: .leading, spacing: 16) {
                Text("Pending paper requests").font(.headline)
                ForEach(requests) { request in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(request.symbol) · \(request.buy ? "Buy requested" : "Exit requested") · Not filled")
                            .font(.callout.bold())
                        Text("Current attempt: \(activityDateLabel(request.at)) New York")
                            .font(.caption).foregroundStyle(.secondary)
                        if request.protectiveTradeID != nil {
                            Text("Protective intent retained").font(.callout.bold())
                                .foregroundStyle(DS.Palette.warningSoft)
                        }
                        Text(pendingStatus(request, running: running, at: now))
                            .font(.callout).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 20) {
            if let latest {
                VStack(alignment: .leading, spacing: 12) {
                    activityRow(latest, title: "Latest recorded activity")
                    if let plan = latest.plan { entryPlan(plan) }
                }
            } else {
                Text("No recorded activity in recent history.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let noFill {
                if noFill.id != latest?.id {
                    Divider()
                    activityRow(noFill, title: "Latest recorded no-fill evidence")
                }
            } else {
                Text("No matching no-fill record in recent history.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func activityRow(_ decision: StockSagePaperAutomation.Decision, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text("\(activityDateLabel(decision.at)) New York · \(decision.symbol.isEmpty ? "General activity" : decision.symbol) · \(actionLabel(decision.action))")
                .font(.callout.weight(.medium))
            Text(verbatim: decision.reason).font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Historical record; does not establish current state or why a request is pending.")
                Text(decision.action == "Paper Buy" || decision.action == "Paper Sell"
                     ? "Simulated fill · not a broker execution." : "This record is not a fill.")
            }
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
        running ? "Legacy run active · simulation only" : "Legacy history · monitoring off"
    }

    static func monitoringLabel(running: Bool, at date: Date) -> String {
        guard running else { return "Position monitoring paused" }
        return StockSagePaperAutomation.paperSessionOpen(date)
            ? "Position and exit monitoring enabled"
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
