#if os(macOS)
import SwiftUI

/// Observes the existing coalesced feed. This view never opens a socket or starts a data request.
struct StockSageMicrocapActivityView: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var research: StockSageSameDayResearch
    @ObservedObject private var monitor: StockSageMicrocapMonitor
    @ObservedObject private var telegram = StockSageTelegram.shared
    @ObservedObject private var live = StockSageLiveStream.shared
    init(store: StockSageStore, research: StockSageSameDayResearch = .microcap) {
        self.store = store; self.research = research
        self.monitor = research.mode == .largecap ? .largecap : .shared
    }
    private var identifier: String { research.mode.rawValue }
    @State private var query = ""
    @State private var page = 0
    @State private var showScreen = false
    @State private var showTelegram = false
    private let pageSize = 50

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            watching
            if let screen = research.receipt?.microcapScreen {
                coverage(screen)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Label("Screening coverage", systemImage: "line.3.horizontal.decrease.circle")
                        .font(DS.Typography.titleM)
                    Text("A completed screen will keep every supported common-share classification here, including exclusions, unavailable inputs and candidates outside the detailed-screen limit.")
                        .font(.callout).foregroundStyle(DS.Palette.textSecondary)
                    Text("Live observations appear alongside each screened symbol when the existing Massive feed has received them.")
                        .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.lg)
                .background(DS.Bezel.cardFill, in: .rect(cornerRadius: DS.Radius.card))
            }
        }
        .onChange(of: query) { _, _ in page = 0 }
        .onChange(of: research.receipt?.id) { _, _ in page = 0 }
    }

    private var watching: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DS.Space.lg) {
                    watchTitle
                    Spacer(minLength: 12)
                    watchButton.fixedSize()
                }
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    watchTitle
                    watchButton
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Momentum detection coverage").font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(monitor.momentumStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("When enabled, detection covers all matching symbols with a current dated \(research.title) cap classification concurrently. Missing or stale classifications are not eligible. Confirmed observations below are recent event details, not the coverage list.")
                    .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("After connection or a feed gap, each symbol needs twenty consecutive completed minutes with positive volume before detection is ready. Missing minutes are unavailable, not zero. Prospective events are checked against Massive REST minute bars before alerts or Astra reviews.")
                    .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier(identifier + ".momentum.coverage")
            Text(monitor.momentumAlertStatus).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier + ".momentum.alertStatus")
            Text(monitor.momentumWorkStatus).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let market = monitor.marketMomentum { StockSageMomentumView(market: market) }
            if !monitor.stockMomentum.isEmpty {
                DisclosureGroup("Confirmed momentum observations · \(monitor.stockMomentum.count) symbols") {
                    LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                        ForEach(monitor.stockMomentum, id: \.symbol) { stock in StockSageMomentumView(stock: stock) }
                    }
                }
                .accessibilityIdentifier(identifier + ".momentum.observations")
            } else {
                Text("No confirmed momentum observations. See detection coverage for connection, warm-up or missing-data status; an empty detail list does not establish that every symbol was quiet.")
                    .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifier + ".momentum.observations.empty")
            }
            Text(monitor.status)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier + ".watch.status")
            if monitor.isEnabled, let next = monitor.nextCheck {
                Text("Next regular-session setup check: \(next.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
            }
            Text("Monday–Friday · 11:00 AM–11:00 PM Riyadh, including premarket, while StockSage is open and your Mac is awake. Confirmed heavy momentum can send a descriptive Telegram alert and queue a fresh-event Astra review. Reviews wait for research capacity and may expire before they run. A queued event is not a completed review or confirmed delivery.")
                .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("New trade setups require the regular US session. Automatic setup checks wait 2.5 minutes after each completed check and run when research capacity is available. A separately qualified setup can send a trade-research pick. Both use your paired chat; Astra uses your Codex subscription. Watching does not place orders or guarantee a same-day exit.")
                .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button {
                showTelegram = true
            } label: {
                Label(telegram.isReady ? "Telegram · paired" : "Set up Telegram alerts", systemImage: "paperplane")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier(identifier + ".telegram.setup")
            .sheet(isPresented: $showTelegram) { StockSageTelegramSetupView(telegram: telegram) }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Bezel.cardFill, in: .rect(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Bezel.coreInnerHighlight, lineWidth: 1))
    }

    private var watchTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Momentum & setup alerts", systemImage: "waveform.path.ecg")
                .font(DS.Typography.titleM).accessibilityAddTraits(.isHeader)
            Text(monitor.isEnabled ? "Automatic checks enabled" : "Automatic checks stopped")
                .font(.caption.weight(.medium))
                .foregroundStyle(monitor.isEnabled ? DS.Palette.accentText : DS.Palette.textSecondary)
        }
    }

    @ViewBuilder private var watchButton: some View {
        if monitor.isEnabled {
            Button("Stop watching", systemImage: "stop.fill") { monitor.stop() }
                .buttonStyle(.bordered).controlSize(.large)
                .accessibilityIdentifier(identifier + ".watch.stop")
        } else {
            Button("Enable tracking", systemImage: "play.fill") { monitor.start(store: store) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(research.isRunning)
                .help("Track momentum during your Riyadh schedule. Pair Telegram to enable momentum alerts, Astra reviews and fresh-setup assessments.")
                .accessibilityIdentifier(identifier + ".watch.start")
        }
    }

    private func coverage(_ screen: StockSageMicrocapScreen.Result) -> some View {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = screen.rows.filter { row in
            needle.isEmpty || row.symbol.localizedCaseInsensitiveContains(needle)
                || row.name.localizedCaseInsensitiveContains(needle)
                || status(row.status).localizedCaseInsensitiveContains(needle)
        }
        let count = max(1, (matching.count + pageSize - 1) / pageSize)
        let activePage = min(page, count - 1)
        let first = activePage * pageSize
        let visible = Array(matching.dropFirst(first).prefix(pageSize))
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Screening coverage", systemImage: "line.3.horizontal.decrease.circle")
                    .font(DS.Typography.titleM).accessibilityAddTraits(.isHeader)
                Text("\(screen.rows.count) classified · \(screen.detailedCount) detailed screens · \(screen.unassessedCount) unassessed")
                    .font(.callout).monospacedDigit()
                Text("Recorded cutoff: \(screen.cutoff.formatted(date: .abbreviated, time: .standard)). Screen values stay frozen; incoming prints do not recalculate RVOL or create a new opinion.")
                    .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let blocker = screen.blocker {
                    Label(blocker, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { tick in
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(live.connectionLabel, systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold))
                        Text("\(live.gapCount) recorded feed gaps. Latest coalesced observations only; no complete tape, Level 2 depth or verified halt/band monitoring.")
                            .font(.caption).foregroundStyle(live.gapCount > 0 ? DS.Palette.warningSoft : DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier(identifier + ".activity.feed")
                    DisclosureGroup(isExpanded: $showScreen) {
                        VStack(alignment: .leading, spacing: DS.Space.md) {
                            searchField
                            if matching.isEmpty {
                                Text(needle.isEmpty ? "No classifications were captured for this run." : "No classifications match this search. Clear the search to see every saved row.")
                                    .font(.callout).foregroundStyle(DS.Palette.textSecondary)
                                    .padding(.vertical, DS.Space.sm)
                            } else {
                                pagination(first: first, visible: visible.count, total: matching.count, activePage: activePage, pages: count)
                                ForEach(visible) { row in
                                    candidate(row, cutoff: screen.cutoff, at: tick.date)
                                    Divider()
                                }
                                if visible.count > 10 {
                                    pagination(first: first, visible: visible.count, total: matching.count, activePage: activePage, pages: count)
                                }
                            }
                        }.padding(.top, DS.Space.md)
                    } label: {
                        Text("All saved classifications and live observations").font(.subheadline.weight(.semibold))
                    }
                    .accessibilityIdentifier(identifier + ".screen.rows")
                }
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Bezel.cardFill, in: .rect(cornerRadius: DS.Radius.card))
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Search saved classifications").font(.caption.weight(.medium)).foregroundStyle(DS.Palette.textSecondary)
            HStack(spacing: DS.Space.xs) {
                TextField("Symbol, company or status", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search saved classifications")
                    .accessibilityIdentifier(identifier + ".screen.search")
                if !query.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                        .buttonStyle(.bordered).accessibilityLabel("Clear classification search")
                        .accessibilityIdentifier(identifier + ".screen.clear")
                }
            }
        }
    }

    private func pagination(first: Int, visible: Int, total: Int, activePage: Int, pages: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.md) {
                Text("\(first + 1)–\(first + visible) of \(total)").font(.caption).monospacedDigit()
                Spacer(minLength: 8)
                pageButtons(activePage: activePage, pages: pages)
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("\(first + 1)–\(first + visible) of \(total)").font(.caption).monospacedDigit()
                pageButtons(activePage: activePage, pages: pages)
            }
        }
    }

    private func pageButtons(activePage: Int, pages: Int) -> some View {
        HStack(spacing: DS.Space.sm) {
            Button("Previous", systemImage: "chevron.left") { page = max(0, activePage - 1) }
                .disabled(activePage == 0).accessibilityIdentifier(identifier + ".screen.previous")
            Text("Page \(activePage + 1) of \(pages)").font(.caption).monospacedDigit()
            Button("Next", systemImage: "chevron.right") { page = min(pages - 1, activePage + 1) }
                .disabled(activePage + 1 >= pages).accessibilityIdentifier(identifier + ".screen.next")
        }.buttonStyle(.bordered)
    }

    private func candidate(_ row: StockSageMicrocapScreen.Row, cutoff: Date, at now: Date) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Text(row.symbol).font(.headline).foregroundStyle(DS.Palette.textPrimary)
                    Text(status(row.status)).font(.caption.weight(.semibold)).foregroundStyle(tint(row.status))
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.symbol).font(.headline)
                    Text(status(row.status)).font(.caption.weight(.semibold)).foregroundStyle(tint(row.status))
                }
            }
            if row.name != row.symbol { Text(row.name).font(.subheadline).foregroundStyle(DS.Palette.textSecondary) }
            latestTrade(row.symbol, at: now)
            DisclosureGroup("Screen measurements, quote and source dates") {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Text(row.note).font(.callout).fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: DS.Space.sm) {
                        metric("Market cap", row.marketCap.map { $0.formatted(.currency(code: "USD").notation(.compactName)) } ?? "Unavailable / unqueried")
                        if research.isMicrocap { metric("Free float", row.freeFloat.map { $0.formatted() + " shares" } ?? "Unavailable") }
                        metric("Opening gap", row.openingGap.map { ($0 * 100).formatted(.number.precision(.fractionLength(2))) + "%" } ?? "Unassessed / unavailable")
                        metric("Time-matched RVOL", row.relativeVolume.map { $0.formatted(.number.precision(.fractionLength(2))) + "×" } ?? "Unassessed / unavailable")
                        metric("Captured session volume", row.volume.map { $0.formatted() + " shares" } ?? "Unavailable")
                        metric("Matched baseline volume", row.baselineVolume.map { $0.formatted(.number.precision(.fractionLength(0...2))) + " shares" } ?? "Unavailable")
                        metric("Open-to-observation momentum", row.momentum.map { ($0 * 100).formatted(.number.precision(.fractionLength(2))) + "%" } ?? "Unavailable")
                        metric("Annualized minute-close volatility proxy", row.annualizedVolatility.map { ($0 * 100).formatted(.number.precision(.fractionLength(2))) + "%" } ?? "Unavailable")
                    }
                    Text("Dated screen only · \(row.baselineSessions) baseline sessions · cutoff \(cutoff.formatted(date: .abbreviated, time: .standard)). These values are not recomputed from the latest print.")
                        .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    if let quote = StockSageLiveStream.displayQuote(for: row.symbol, in: live.quotes) {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(quote.isFresh(at: now) ? "Recent quote · five-second age limit" : "Dated or future quote · not current", systemImage: "arrow.left.arrow.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(quote.isFresh(at: now) ? DS.Palette.textPrimary : DS.Palette.warningSoft)
                            Text(StockSageNBBO.compactText(quote, exchanges: live.exchangeReference(at: now)))
                                .font(.caption).monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                            if !quote.costConditionVerified {
                                Text("Quote conditions are not verified for scenario costs.").font(.caption).foregroundStyle(DS.Palette.warningSoft)
                            }
                        }
                    } else {
                        Text("Bid/ask unavailable for this symbol; a last trade does not establish a current quote.")
                            .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                    Text("Observed: \(row.observedAt.formatted(date: .abbreviated, time: .standard))")
                    Text("Market-cap reference date requested: \(row.marketCapRequestedDate ?? "not queried / unavailable"). No separate cap effective timestamp is supplied.")
                    if let date = row.referenceRetrievedAt { Text("Reference retrieved: \(date.formatted(date: .abbreviated, time: .standard))") }
                    if let date = row.floatEffectiveDate { Text("Float effective: \(date.formatted(date: .abbreviated, time: .omitted)) · maximum age ninety days") }
                    if let date = row.previousRegularCloseDate {
                        Text("Gap reference: Massive daily open-close regular close for \(date); not an official auction-price guarantee.")
                    }
                    if let date = row.previousRegularCloseRetrievedAt { Text("Prior-session close retrieved: \(date.formatted(date: .abbreviated, time: .standard))") }
                    if let date = row.activityRetrievedAt { Text("Activity ordering retrieved: \(date.formatted(date: .abbreviated, time: .standard))") }
                }
                .font(.caption).textSelection(.enabled)
                .padding(.top, DS.Space.sm)
            }.font(.subheadline)
        }
        .padding(.vertical, DS.Space.xs)
    }

    @ViewBuilder private func latestTrade(_ symbol: String, at now: Date) -> some View {
        if let trade = live.latestTrade(for: symbol) {
            let fresh = StockSageLiveStream.isLiveObservation(trade.timestamp, at: now)
            VStack(alignment: .leading, spacing: 3) {
                Text("Latest received trade · $\(StockSageCurrency.adaptivePrice(trade.price, grouped: true))"
                    + (trade.size.map { " · \($0.formatted()) shares" } ?? " · size unavailable"))
                    .font(.subheadline).monospacedDigit()
                Text("\(trade.timestamp.formatted(date: .abbreviated, time: .standard)) · \(fresh ? "recent observation" : "stale or future-dated observation")")
                    .font(.caption).foregroundStyle(fresh ? DS.Palette.textSecondary : DS.Palette.warningSoft)
            }
        } else {
            Text("No current-stream trade received for this symbol.").font(.caption).foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.caption).foregroundStyle(DS.Palette.textSecondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func status(_ value: StockSageMicrocapScreen.Status) -> String {
        switch value {
        case .passed: "Screen passed · not a qualified pick"
        case .excluded: "Excluded by screen"
        case .unavailable: "Required data unavailable"
        case .unassessed: "Detailed screen unassessed"
        }
    }
    private func tint(_ value: StockSageMicrocapScreen.Status) -> Color {
        switch value {
        case .passed: DS.Palette.accentText
        case .excluded: DS.Palette.textSecondary
        case .unavailable: DS.Palette.warningSoft
        case .unassessed: DS.Palette.textSecondary
        }
    }
}
#endif
