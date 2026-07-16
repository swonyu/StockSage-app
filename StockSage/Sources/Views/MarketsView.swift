import UniformTypeIdentifiers
import SwiftUI
import AppKit   // NSPasteboard for the trade-plan copy

/// The Markets tab — now wired to the live `StockSage` subsystem: per-symbol
/// rule-based momentum signals (`StockSageSignalEngine`, deterministic
/// |Δ%| thresholds) + an on-device daily briefing (`StockSageBriefingService`,
/// routed through `LocalLLM.generateOnDevice`). Data comes from `StockSageStore`
/// (sample seed until a live feed lands — honestly flagged). Sections not yet
/// built show a clear "coming soon".
struct MarketsView: View {
    /// Equity count within `StockSageUniverse.worldwide`, computed ONCE. The lesson this comment
    /// records: NEVER hardcode a universe count in copy — a literal regresses the auto-updating
    /// number the moment the universe changes (a past bug hardcoded "≈2,330 equities"; the
    /// 2026-07-16 Tadawul+NASDAQ restriction to 901 names would have stranded any literal again).
    /// A `static let` (not a per-render computed property) — `MarketsView` is a `View` struct
    /// SwiftUI recreates on every body evaluation; filtering the whole universe on each render
    /// would be pure waste for a number that only changes when the universe itself does.
    private static let worldwideEquityCount = StockSageUniverse.worldwide
        .filter { StockSageAllocation.assetClass($0.symbol) == "Equity" }.count

    @State private var section: MarketSection
    @AppStorage("marketsWatchSort") private var sort: MarketSort = .feed
    @State private var showBrowseMarkets = false
    /// Ideas board ordering: by expected value, EV-per-day velocity, or signal rank.
    /// F19/F20 (2026-07-15): moved to the engine (StockSageIdeaProjection.Sort) so the board's
    /// sort/filter contract is testable. Raw values unchanged → @AppStorage identity intact.
    typealias IdeaSort = StockSageIdeaProjection.Sort
    // Default to money-velocity (EV per day) — the "fastest money" objective: a quick small edge
    // compounds faster than a slow large one. (Existing users keep whatever they last picked.)
    @AppStorage("marketsIdeaSort") private var ideaSort: IdeaSort = .velocity
    /// Hide ideas below this conviction (0 = show all).
    @AppStorage("marketsIdeaMinConv") private var ideaMinConv = 0.0

    /// F19/F20 (2026-07-15): moved to the engine (StockSageIdeaProjection.Filter) — see IdeaSort.
    typealias IdeaFilter = StockSageIdeaProjection.Filter
    @AppStorage("marketsIdeaFilter") private var ideaFilter: IdeaFilter = .all
    /// Live name filter over the ideas list (by symbol / market).
    @State private var ideaSearch = ""

    /// Tunable hold-day assumptions feeding velocity (EV/day). Persisted; defaults match
    /// the engine's so nothing shifts until the owner changes it.
    @AppStorage("velocityCryptoHoldDays") private var cryptoHoldDays = VelocityHoldDays.defaults.crypto
    @AppStorage("velocityEquityHoldDays") private var equityHoldDays = VelocityHoldDays.defaults.equity
    private var velocityHolds: VelocityHoldDays { VelocityHoldDays(crypto: cryptoHoldDays, equity: equityHoldDays) }
    /// FASTMONEY_BACKLOG #7 — which fast-lane board(s) to show. Defaults to Both (the new
    /// split-board layout replaces the old single blended top-3 list, per the backlog's intent).
    enum FastLaneBoard: String, CaseIterable, Identifiable {
        case both = "Both", crypto = "Crypto", equities = "Equities"
        var id: String { rawValue }
    }
    @AppStorage("marketsFastLaneBoard") private var fastLaneBoard: FastLaneBoard = .both
    @ObservedObject private var velocityHistory = StockSageVelocityHistoryStore.shared

    // Dynamic-Type-aware small fonts: each equals its base size at the default text
    // setting (mvFont9 == 9), so the dense layout is unchanged, but they scale up when
    // the user enlarges system text — fixing the "tiny fixed money font" a11y finding.
    @ScaledMetric(relativeTo: .caption2) private var mvFont7: CGFloat = 7
    @ScaledMetric(relativeTo: .caption2) private var mvFont8: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var mvFont9: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var mvFont10: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var mvFont11: CGFloat = 11
    // 11.5 gets its own token (not rounded into mvFont11) so the "Find ideas" button keeps its
    // exact pre-Dynamic-Type visible size at the default text setting.
    @ScaledMetric(relativeTo: .caption2) private var mvFont11_5: CGFloat = 11.5
    @ScaledMetric(relativeTo: .caption2) private var mvFont12: CGFloat = 12
    // 12.5 gets its own token (not rounded into mvFont12 or mvFont13) for the same reason as
    // mvFont11_5 — it is ideaMetric's value-text size and must keep its exact pre-Dynamic-Type
    // rendered size at the default text setting.
    @ScaledMetric(relativeTo: .caption2) private var mvFont12_5: CGFloat = 12.5
    @ScaledMetric(relativeTo: .caption2) private var mvFont13: CGFloat = 13
    @ScaledMetric(relativeTo: .caption2) private var mvFont14: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var mvFont15: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) private var mvFont16: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var mvFont17: CGFloat = 17
    @ScaledMetric(relativeTo: .caption2) private var mvFont18: CGFloat = 18
    @ScaledMetric(relativeTo: .caption2) private var mvFont20: CGFloat = 20
    @ScaledMetric(relativeTo: .caption2) private var mvFont22: CGFloat = 22

    // ── Ideas-surface type roles (UX wave 2) ─────────────────────────────────
    // A documented hierarchy ON TOP of the mvFont @ScaledMetric tokens (the F48
    // mechanism is unchanged — every role scales with Dynamic Type via its token).
    // Ramp ≈ a major-second (1.125×) modular scale anchored at the 9pt caption:
    //   9.0 → 10.1 → 11.4 → 12.8 → 14.4 → … → 20.5, snapped to the token grid:
    //   micro 8 · caption/metricLabel 9 · chipLabel 10 · body/button 11.5 ·
    //   metricValue 12.5 (legacy exact-size token, kept) · sectionHeader 13 ·
    //   cardTitle 15 · sheetTitle 20.
    // Deliberate wave-2 change: sectionHeader 12 → 13 (mvFont13) so the sheet's
    // section headers (Why / Evidence / Exit plan / Context) outrank the 12.5pt
    // metric values they introduce. Roles name SIZES, never displayed terms —
    // the Conviction-vs-Signal-strength wording question stays parked (F08).
    // New call sites use roles; legacy mvFontN call sites migrate in a later wave.
    private var fontSheetTitle: CGFloat { mvFont20 }
    private var fontCardTitle: CGFloat { mvFont15 }
    private var fontSectionHeader: CGFloat { mvFont13 }
    private var fontMetricValue: CGFloat { mvFont12_5 }
    private var fontBody: CGFloat { mvFont11_5 }
    private var fontChipLabel: CGFloat { mvFont10 }
    private var fontMetricLabel: CGFloat { mvFont9 }
    private var fontCaption: CGFloat { mvFont9 }
    private var fontMicro: CGFloat { mvFont8 }

    /// Ideas-surface spacing rhythm (UX wave 2): a 4/8pt grid. DS.Space stays app-wide
    /// (its sm=10 / md=14 are off-grid); these roles apply ONLY to the ideas card +
    /// detail sheet. Values chosen so the surface tightens INSIDE groups (stack 8)
    /// and breathes BETWEEN groups (cardPad/section 12) — rhythm, not uniform padding.
    private enum IdeaSpace {
        static let chipH: CGFloat = 8    // tinted-chip horizontal inset (was 7 and 8)
        static let chipV: CGFloat = 3    // tinted-chip vertical inset (was 3 and 4)
        static let chipGap: CGFloat = 8  // gap between chips / badge-row items (was 10 and 6)
        static let stack: CGFloat = 8    // intra-card vertical rhythm (was 10)
        static let cardPad: CGFloat = 12 // card inset (was 10)
        static let section: CGFloat = 12 // sheet root vertical rhythm (was 10)
    }

    @ObservedObject private var store = StockSageStore.shared
    @ObservedObject private var portfolio = StockSagePortfolio.shared
    @ObservedObject private var journal = StockSageJournalStore.shared
    @ObservedObject private var paperStore = StockSagePaperTradeStore.shared
    @State private var briefing = ""
    @State private var briefingGeneratedAt: Date? = nil
    @State private var loadingBriefing = false
    @State private var newSymbol = ""
    @State private var newShares = ""
    @State private var newCost = ""
    /// Watchlist add-symbol field (track any global ticker beyond the universe).
    @State private var newWatchSymbol = ""
    /// Local error for the watchlist add box only. Populated from store.addSymbolError after
    /// addWatchSymbol() completes, then displayed here — NOT from store.addSymbolError directly,
    /// so browse-sheet add failures (which also set store.addSymbolError) never bleed into
    /// this box. Cleared when the browse sheet opens/closes.
    @State private var watchlistAddError: String? = nil
    /// Tapped idea → per-symbol detail sheet (full advice + larger sparkline + backtest).
    @State private var selectedIdea: StockSageIdea?
    @State private var ideasCopied = false
    /// Feedback state for the sheet's pinned-bar "Copy plan" button — mirrors the ideasCopied
    /// pattern (2s revert). Reset on sheet dismiss via .onChange(of: selectedIdea).
    @State private var planCopied = false
    /// Kelly position-sizer inputs (interactive, no fetch).
    @State private var kellyWinRate = "55"
    @State private var kellyPayoff = "2.0"
    @State private var kellyAccount = "10000"
    /// Trade-journal add form (inline; no sheet to avoid presentation races).
    @State private var showAddTrade = false
    /// Extension batch (2026-07-16): one honest result line for the journal Data menu
    /// (CSV import / backup / restore / parent import) — counts, skips, errors; never silent.
    @State private var journalDataFeedback: String?
    @State private var draftSymbol = ""
    @State private var draftSide: TradeRecord.Side = .long
    @State private var draftEntry = ""
    @State private var draftStop = ""
    @State private var draftTarget = ""
    @State private var draftShares = ""
    @State private var draftNote = ""
    /// The idea's conviction when this draft was prefilled FROM an idea (nil for a manual trade) —
    /// recorded on the TradeRecord so the journal can calibrate conviction→win-rate from real fills.
    @State private var draftConviction: Double? = nil
    /// Optional realized-cost capture: the price the plan quoted vs. the actual fill, at entry.
    /// Measurement only — never a P&L input (see TradeRecord.entrySlippageBps).
    @State private var draftPlannedEntry = ""
    @State private var draftEntryFill = ""
    /// Inline close-a-trade: the open trade being closed + its exit-price field.
    @State private var closingTradeID: UUID?
    @State private var closeExitText = ""
    /// Optional realized-cost capture at exit — mirrors draftPlannedEntry/draftEntryFill.
    @State private var closePlannedExitText = ""
    @State private var closeExitFillText = ""
    @State private var pendingJournalDeleteID: UUID?
    /// Detail-sheet position sizer inputs.
    // F6 (rotation-3 triage, first-run honesty floor): fresh installs used to seed these
    // AppStorage keys with a FABRICATED $10,000/1% account — every sized order, gate verdict,
    // and Deploy-capital plan a first-run owner saw was silently computed off numbers nobody
    // typed. Unset ("") on a fresh install; every downstream read already goes through
    // `StockSageInput.positiveAmount`/`.percent` (nil on ""), which every call site below
    // already honestly nil-guards (SET RISK % badge, "set account to size", gate == nil, etc.)
    // — verified by reading every read site before this change, not assumed. The TextField
    // placeholder ("10000"/"1", `journalField` calls ~5389/5392) still shows the SHAPE of a
    // valid input; only the seeded VALUE is gone. An owner who already ran the app keeps their
    // real typed value — AppStorage persists past this default, this only changes first-run.
    @AppStorage("marketsSizerAccount") private var sizerAccount = ""
    @AppStorage("marketsSizerRiskPct") private var sizerRiskPct = ""
    // F04 (sizer-input trust seam): the comma-aware parse the idea CARDS already use
    // (StockSageInput.positiveAmount/.percent) — nil on blank/unparseable/"10,000" mis-thousands.
    // Every sheet/copied-plan/gate site below must read THESE, never `Double(sizerAccount)`
    // directly, or a typed "10,000" silently becomes 0 findings / a fabricated 1% gate verdict.
    private var parsedAccount: Double? { StockSageInput.positiveAmount(sizerAccount) }
    /// 0–1 fraction (StockSageInput.percent returns 0–100, matching the card sites' own
    /// `StockSageInput.percent(sizerRiskPct)` then `/ 100`) — pre-divided here since every
    /// non-card call site below wants a bare riskFraction, not a displayable percent.
    private var parsedRiskFraction: Double? { StockSageInput.percent(sizerRiskPct).map { $0 / 100 } }
    /// Focus identity for the three add-holding fields → accent focus glow,
    /// matching the app's other primary inputs.
    private enum AddField: Hashable { case symbol, shares, cost }
    @FocusState private var focusedAddField: AddField?
    // Alerts (wired to StockSageMonitor — strong-signal Mac notifications).
    @State private var monitoring = false
    // Shared key with StockSageMonitor.watchlistOnlyKey — scopes the alert scan to the watchlist.
    @AppStorage("marketsWatchlistOnly") private var watchlistOnly = false
    // User-set price-alert form.
    @State private var paSymbol = ""
    @State private var paTarget = ""
    @State private var paDirection: PriceAlert.Direction = .above
    @State private var paError = ""
    @State private var alertSignals: [StockSageSignal] = []
    @State private var checkingAlerts = false
    @State private var monitorError = ""
    /// True once the user has tapped "Check now" at least once, so the empty-state copy is
    /// honest ("no strong signals found") rather than pre-emptive ("no signals right now").
    @State private var hasScanned = false
    // Hover states — one per interactive surface type.
    @State private var hoveredSignalID: UUID?
    @State private var hoveredPositionID: UUID?
    @State private var hoveredAlertSymbol: String?
    @State private var hoveredHeatID: UUID?
    @State private var hoveredIdeaID: String?
    /// Staggered entrance. Pre-set under `--qa` so the offscreen snapshot
    /// (onAppear never fires) captures the settled layout, not the pre-entrance pose.
    // STANDALONE FIX (2026-07-16, pixel-verified): the parent's fade-in gate left the whole
    // board at opacity 0 in the standalone (entrance animation never completed; footer — the
    // only ungated element — rendered alone). The fade is cosmetic; a visible board is not.
    @State private var appeared = true
    /// Tracks symbols whose multi-timeframe fetch task has completed (success OR failure).
    /// Used to bound the weekly-timeframe spinner: once the task finishes, if the store
    /// still has no data for the symbol the fetch failed and we show "unavailable" instead
    /// of leaving a permanent ProgressView.
    @State private var mtfFetchCompleted: Set<String> = []
    /// The symbol the sheet's .task(id:) last ran a refresh chain for. nil means "the sheet
    /// hasn't opened yet this session" (or just closed) — distinguishes first-open from a
    /// prev/next STEP so the rapid-stepping debounce only applies to the step case, never the
    /// dominant plain-open path. Reset to nil in .onChange(of: selectedIdea) when the sheet
    /// closes, so re-opening any idea afterward is treated as a fresh first-open, not a step.
    @State private var lastSheetSymbol: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `qaSection` lets the QA harness capture a specific sub-section (e.g. the
    /// heatmap) offscreen; normal use defaults to the watchlist.
    // Land on the EV-ranked Ideas board on open — the owner's "where's my best move?" answer,
    // 0 taps in. (The QA harness passes an explicit section so its snapshots stay deterministic.)
    /// QA-only seam (mirrors `qaSection`): when set, `body` renders the idea-detail SHEET
    /// content for the matching `store.ideas` symbol directly — no `.sheet` presentation,
    /// so the harness can snapshot it pixel-stable and unclipped. nil (every non-QA
    /// construction site) is byte-identical to today's body; never set outside QASnapshots.
    private let qaDetailSymbol: String?
    init(qaSection: MarketSection = .ideas, qaDetailSymbol: String? = nil) {
        _section = State(initialValue: qaSection)
        self.qaDetailSymbol = qaDetailSymbol
    }

    var body: some View {
        if let sym = qaDetailSymbol {
            if let idea = store.ideas.first(where: { $0.symbol.uppercased() == sym.uppercased() }) {
                ideaDetailSheet(idea)
            } else {
                Text("QA: no such idea — \(sym)").foregroundStyle(.red)
            }
        } else {
            normalBody
        }
    }

    @ViewBuilder private var normalBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    feedBanner
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(DS.Motion.lux.delay(0.05), value: appeared)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                    regimeCard
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(DS.Motion.lux.delay(0.06), value: appeared)
                    moneyVelocityCard
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(DS.Motion.lux.delay(0.07), value: appeared)
                    // Always-visible best-move CTA (FASTMONEY_BACKLOG #3) — the single
                    // highest-EV idea as a concrete, sizeable, copyable order ticket,
                    // on EVERY section tab (unlike bestOpportunityCard, Ideas-tab only).
                    // Hierarchy lens 2026-07-09: on the Ideas section, bestOpportunityCard is a
                    // strict SUPERSET of this CTA (same order, same caveats, plus R:R/Win est./
                    // Base size/Target) rendered one card below — the same ticket twice added
                    // length, not decision content. The CTA's own doc says its purpose is the
                    // OTHER tabs; it keeps serving them unchanged.
                    if section != .ideas {
                        bestOpportunityCTA
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 8)
                            .animation(DS.Motion.lux.delay(0.075), value: appeared)
                    }
                    sectionPicker
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(DS.Motion.lux.delay(0.08), value: appeared)
                    content
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 6)
                        .animation(DS.Motion.lux.delay(0.12), value: appeared)
                }
                .animation(DS.Motion.smooth, value: store.isSampleData)
                .padding(DS.Space.xl)
                // Centered content column, same as the chat surfaces.
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Pinned frosted top toolbar (macOS 27 overhaul wave 2): identity +
            // feed-provenance + session clocks stay visible while the board scrolls
            // beneath — provenance is an honesty surface, so it should never scroll
            // away. Fade-only entrance (an offset would slide a PINNED bar over
            // content). Same auto-inset behavior as the bottom bar.
            .safeAreaInset(edge: .top, spacing: 0) {
                header
                    .opacity(appeared ? 1 : 0)
                    .animation(DS.Motion.lux, value: appeared)
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.vertical, DS.Space.sm)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                    .overlay(Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1),
                             alignment: .bottom)
            }
            // Frosted footer (macOS 27 overhaul): content scrolls beneath it —
            // macOS 26.5 auto-insets ScrollView content for safeAreaInset (see the
            // 72px-spacer note in the detail sheet's pinned bar).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MarketDisclaimerFooter()
            }
        }
        // Canvas with atmosphere (macOS 27 overhaul): slate wash + faint crimson
        // aurora — the depth Liquid Glass materials sample. Was flat codeSurface.
        .background(DSCanvasBackground().ignoresSafeArea())
        .onAppear {
            appeared = true
            // Sync the toggle with the singleton: the monitor is a process-lifetime task that
            // survives window close/reopen, so a freshly-built view must read the live state
            // rather than defaulting to false (which would make the running monitor unstoppable).
            monitoring = StockSageMonitor.shared.isRunning
        }
        .task {
            // Auto-pull a live Tadawul+NASDAQ snapshot on open — skipped under the QA
            // snapshot harness so captures stay deterministic and offline.
            guard !ProcessInfo.processInfo.arguments.contains("--qa") else { return }
            await store.refresh()
            // Auto-scan the EV ideas so the board the app lands on is already populated —
            // 0 taps from open to the best move. refreshIdeas self-guards re-entry/ToolPolicy.
            if store.ideas.isEmpty { await store.refreshIdeas() }
            // F8 (rotation-3 triage, first-run honesty): a fresh install's Deploy-capital plan
            // and every regime-aware sizing path silently ran with ZERO risk-off/on brake until
            // the owner noticed the ungauged state and tapped Gauge by hand — same "0 taps to
            // the best move" reasoning as the ideas auto-scan above. The Gauge/Refresh button
            // stays for every later re-gauge; this only covers the one-time nil→gauged step.
            if store.regime == nil { await store.refreshRegime() }
            // Snapshot today's money-velocity (one per UTC day) so the trend can build. Skipped
            // when the scan that just ran was cancelled mid-way (post-ship critique fleet,
            // orchestrator-confirmed): the board is a partial snapshot in that case, and this
            // history is DURABLE per-day storage — a cancelled-scan snapshot would poison the
            // trend permanently, not just for this session. Round-H: a THROTTLED scan (extended
            // universe scan aborted early on a 429-storm signature — store.scanThrottled) is ALSO
            // a partial board with the SAME poisoning risk, so it gets the same skip.
            if !store.lastScanCancelled && !store.scanThrottled {
                let snap = StockSageExpectedValue.summary(store.ideas, trades: journal.trades, holds: velocityHolds, regime: store.regime, earnings: store.earnings, liquidity: store.liquidity, seasonality: store.seasonality, calibration: store.convictionCalibration)
                if let wk = snap.weeklyR {
                    // Deliberately still the GROSS figure (F03/F44 net-headline, 2026-07-09):
                    // the durable per-day history must keep comparing like-with-like across
                    // sessions recorded before the netting — switching the RECORDED metric
                    // would fake a "since last session" drop equal to the friction estimate.
                    velocityHistory.record(weeklyR: wk, bestSymbol: snap.bestSymbol, fastestSymbol: snap.fastestSymbol)
                }
            }
        }
        .sheet(item: $selectedIdea) { ideaDetailSheet($0) }
        // Reset plan-copy feedback when the sheet closes (selectedIdea → nil) OR steps to a
        // DIFFERENT idea via the prev/next chevrons — "Copied" must never describe the
        // previous idea's plan while a new symbol is on screen (honesty floor).
        .onChange(of: selectedIdea) { oldVal, newVal in
            if oldVal?.id != newVal?.id { planCopied = false }
            // Sheet closed: forget the last-refreshed symbol so the NEXT open (any idea) is
            // treated as a fresh first-open by the .task(id:) debounce, not a step.
            if newVal == nil { lastSheetSymbol = nil }
        }
    }

    /// Honest feed status: the live (green) note once real quotes land, otherwise
    /// the sample/offline notice — surfacing `feedError` (web off, unreachable)
    /// when there is one so the message is actionable.
    @ViewBuilder private var feedBanner: some View {
        if store.isSampleData { sampleBanner }
        else if store.loadedFromCache { cachedBanner }   // last-good disk cache is NOT live — say so
        else { liveBanner }
    }

    /// Cached (last-good) prices loaded from disk after a failed/unreachable refresh. These are real
    /// numbers but NOT live — showing them under the green "Live" banner would imply a freshness the
    /// data doesn't have, so it gets its own amber banner with the snapshot age.
    private var cachedBanner: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: mvFont11))
                .foregroundStyle(DS.Palette.warningSoft)
            Text(cachedBannerText)
                .font(.caption).foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.sm)
        .background(DS.Palette.warningSoft.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .stroke(DS.Palette.warningSoft.opacity(0.45), lineWidth: 1))
    }

    private var cachedBannerText: String {
        let age: String = {
            guard let saved = store.cacheSavedAt else { return "" }
            let secs = Date().timeIntervalSince(saved)
            if secs < 3600 { return " (\(Int(secs / 60))m old)" }
            if secs < 86_400 { return " (\(Int(secs / 3600))h old)" }
            return " (\(Int(secs / 86_400))d old)"
        }()
        let reason = store.feedError.map { " \($0)" } ?? " Refreshing live quotes…"
        return "Last-good (cached) prices\(age) — NOT live.\(reason)"
    }

    private var liveBanner: some View {
        // Honest freshness from the quote's MARKET time (not our fetch time): if the newest quote is
        // materially old (markets closed / feed stale), drop the green "Live" + "~15 min" claim and
        // say plainly it's a last close as of that time. >1h tolerates the normal ~15-min delay.
        // Judge "live" by the CLOSEABLE (non-24/7) board's freshness — an always-on crypto quote must
        // not mask a days-old weekend equity close. Fall back to the global asOf only when there are no
        // closeable assets (an all-crypto board, which genuinely is live).
        let asOf = store.closeableQuoteAsOf ?? store.quoteAsOf
        let stale = asOf.map { Date().timeIntervalSince($0) > 3600 } ?? false
        let tint = stale ? DS.Palette.warningSoft : DS.Palette.successSoft
        let text = (stale && asOf != nil)
            ? "Prices are the last close as of \(asOf!.formatted(date: .abbreviated, time: .shortened)) — markets may be closed; NOT live. Educational, not financial advice."
            : "Live Tadawul + NASDAQ quotes across \(StockSageUniverse.marketCount) market groups (\(StockSageUniverse.worldwide.count) names). Prices may be delayed ~15 min — educational, not financial advice."
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DS.Space.sm) {
                Circle().fill(tint).frame(width: 7, height: 7)
                    .shadow(color: stale ? .clear : tint.opacity(0.7), radius: 4)
                Text(text)
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            if let err = store.feedError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft)
                    Text(err).font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.sm)
        .background(tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .stroke(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.10)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }

    // MARK: Market regime gauge

    @ViewBuilder private var regimeCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: 10) {
                Image(systemName: store.regime.map { regimeIcon($0.state) } ?? "speedometer")
                    .font(.system(size: mvFont16))
                    .foregroundStyle(store.regime.map { regimeColor($0.state) } ?? DS.Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.regime?.state.rawValue ?? "Market regime")
                        .font(.system(size: mvFont14, weight: .semibold)).foregroundStyle(.white)
                        .help(StockSageGlossary.regimeHelp)
                    if let r = store.regime {
                        Text(String(format: "Suggested sizing: ×%.2f of normal", r.sizingBias))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Risk-on / risk-off gauge — biases how much to size.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { Task { await store.refreshRegime() } } label: {
                    HStack(spacing: 6) {
                        Group {
                            if store.isLoadingRegime { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "speedometer").font(.system(size: mvFont11, weight: .semibold)) }
                        }
                        Text(store.isLoadingRegime ? "Gauging…" : (store.regime == nil ? "Gauge" : "Refresh"))
                            .font(.system(size: mvFont11, weight: .semibold)).contentTransition(.opacity)
                    }
                    .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(DS.Palette.accent, in: Capsule())
                }
                .buttonStyle(LuxPressStyle()).disabled(store.isLoadingRegime)
                .help("Gauge the market regime (S&P 500 trend, momentum/RSI, breadth, VIX)")
            }
            if let r = store.regime {
                convictionMeter((r.riskScore + 1) / 2, color: regimeColor(r.state))   // −1…+1 → 0…1
                    .accessibilityLabel("Risk gauge")
                    .accessibilityValue(String(format: "%@ %.0f percent", r.riskScore >= 0 ? "risk-on" : "risk-off", abs(r.riskScore) * 100))
                ForEach(Array(r.signals.prefix(4).enumerated()), id: \.offset) { _, s in
                    Text("· \(s)").font(.caption2).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(r.caveat).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let at = store.regimeGaugedAt {
                    Text(store.regimeIsStale
                         ? "⚠︎ Gauged \(at.formatted(.relative(presentation: .named))) — stale, re-gauge."
                         : "Gauged \(at.formatted(.relative(presentation: .named))).")
                        .font(.system(size: mvFont9)).foregroundStyle(store.regimeIsStale ? DS.Palette.warningSoft : DS.Palette.textSecondary)
                }
            }
            if let e = store.regimeError {
                Text(e).font(.caption2).foregroundStyle(DS.Palette.warningSoft)
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(store.regime.map { regimeColor($0.state).opacity(0.35) } ?? DS.Palette.surfaceStroke, lineWidth: 1))
        .animation(DS.Motion.smooth, value: store.regime)
    }

    private func regimeColor(_ s: MarketRegime.State) -> Color {
        switch s {
        case .trendingBull:          return DS.Palette.successSoft
        case .ranging:               return DS.Palette.warningSoft
        case .trendingBear, .crisis: return DS.Palette.danger
        }
    }
    private func regimeIcon(_ s: MarketRegime.State) -> String {
        switch s {
        case .trendingBull: return "arrow.up.right.circle.fill"
        case .ranging:      return "arrow.left.and.right.circle.fill"
        case .trendingBear: return "arrow.down.right.circle.fill"
        case .crisis:       return "exclamationmark.triangle.fill"
        }
    }

    /// True when the Deploy-capital plan carries NO regime disclosure and should — i.e. the
    /// allocator's regime step (`regime.map { adjustedWeight } ?? suggestedFraction`) silently
    /// skipped the risk-off/on brake because the regime was never gauged, or the gauge is old
    /// enough to be untrustworthy. Pure/testable: nil regime OR stale regime → true; a fresh,
    /// present regime → false (the allocator's own caveat already discloses that case).
    static func regimeWarningNeeded(regime: MarketRegime?, isStale: Bool) -> Bool {
        regime == nil || isStale
    }

    /// F7 (rotation-3 triage, first-run honesty): non-nil ONLY during the FIRST-EVER scan — a
    /// later re-scan already has `ideasUpdated` committed and the board keeps showing the PRIOR
    /// results while the new ones stream in (see the "re-scan in progress" line the scan button
    /// area already shows), so this caption is reserved for the one moment there is no committed
    /// board at all yet — the "best" the card names right now is provisional, not the true best
    /// of the eventual full universe. Pure/testable.
    static func firstScanProgressCaption(isLoadingIdeas: Bool, ideasUpdated: Date?, progress: (current: Int, total: Int)?) -> String? {
        guard isLoadingIdeas, ideasUpdated == nil, let p = progress, p.total > 0 else { return nil }
        return "First scan in progress — \(p.current) of \(p.total) names analyzed; best-so-far, order may change."
    }

    /// L1 (2026-07-09, DISPLAY-ONLY): maps the Deploy-capital plan's positions + the live idea
    /// board to the aligned spark-return series `effectiveBets` needs — the SAME series
    /// `correlationAdjustedWeights` reads (spark-derived, suffix-aligned), so the diagnostic
    /// describes the plan's OWN de-weighting, not a separately-modeled correlation. Pure/testable.
    static func deployEffectiveBets(positions: [AllocatedPosition], ideas: [StockSageIdea]) -> EffectiveBets? {
        let sparkBy: [String: [Double]] = Dictionary(ideas.map { ($0.symbol, $0.spark) }, uniquingKeysWith: { a, _ in a })
        let symbols: [String] = positions.map(\.symbol)
        let returns: [[Double]] = symbols.map { StockSagePortfolioAnalytics.dailyReturns(sparkBy[$0] ?? []) }
        return StockSageCorrelationCluster.effectiveBets(symbols: symbols, returns: returns)
    }

    /// One-line caption for the effective-bets diagnostic (pinned by test — copy-plan and the
    /// on-screen caption both call this on the SAME computed `EffectiveBets`, so they can't drift).
    static func effectiveBetsCaption(_ eb: EffectiveBets) -> String {
        String(format: "Effective bets ≈ %.1f of %d — correlated positions count less", eb.nEff, eb.n)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(DS.Gradient.brand)
                    .frame(width: 36, height: 36)
                    .dsShadow(DS.Elevation.accentGlow(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                            .stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.02)],
                                                   startPoint: .top, endPoint: .bottom),
                                    lineWidth: 0.75)
                    )
                if reduceMotion {
                    // Reduce Motion: static icon (no scale bounce-in).
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: mvFont14, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    KeyframeAnimator(initialValue: CGFloat(1.0), trigger: appeared) { scale in
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: mvFont14, weight: .bold))
                            .foregroundStyle(.white)
                            .scaleEffect(scale)
                    } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(0.60, duration: 0.07)
                            SpringKeyframe(1.18, duration: 0.28, spring: .snappy)
                            SpringKeyframe(1.0, duration: 0.22, spring: .bouncy)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Markets")
                        .font(.system(size: mvFont17, weight: .semibold)).foregroundStyle(.white)
                    Eyebrow(text: "Signals & Portfolio")
                }
                Text(headerSubtitle)
                    .font(.system(size: mvFont11)).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(DS.Motion.smooth, value: headerSubtitle)
                // Extension batch (2026-07-16): schedule-state clock for both markets — a
                // SCHEDULE readout (holidays not modeled; the caveat is in its .help), never
                // a data-freshness claim (that stays with the quote banner).
                MarketSessionClockView()
            }
            Spacer()
            refreshButton
        }
    }

    /// Live status line: once a real feed lands, show the freshness + market count;
    /// otherwise the educational tagline.
    private var headerSubtitle: String {
        if !store.isSampleData, let when = store.lastUpdated {
            // Reuse the same staleness logic as liveBanner so the header and banner never contradict.
            let asOf = store.closeableQuoteAsOf ?? store.quoteAsOf
            let stale = asOf.map { Date().timeIntervalSince($0) > 3600 } ?? false
            if stale, let asOf {
                return "Last close · \(StockSageUniverse.marketCount) market groups · as of \(asOf.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Live · \(StockSageUniverse.marketCount) market groups · updated \(Self.timeFormatter.string(from: when))"
        }
        if store.loadedFromCache, let saved = store.cacheSavedAt {
            // Use a date-aware format so a Friday cache opened Monday isn't shown as just "16:42".
            return "Last-good (cached) as of \(saved.formatted(date: .abbreviated, time: .shortened)) · refresh for live"
        }
        if store.isSampleData {
            // Be unmistakable that these are NOT real prices — tap refresh for live data.
            return "⚠︎ SAMPLE prices (not real) — tap ↻ to load live data"
        }
        return "Rule-based momentum signals · educational, not financial advice"
    }

    private var refreshButton: some View {
        Button { Task { await store.refresh() } } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: mvFont12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                .animation(store.isRefreshing
                           ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                           : .default, value: store.isRefreshing)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.08), in: Circle())
                .overlay(Circle().stroke(
                    LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0.04)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
                // Keep the 30pt visual circle but pad the tappable region to the
                // 44pt a11y hit-target floor (the only sub-44pt control in this header).
                .padding(7)
                .contentShape(Circle())
        }
        .buttonStyle(LuxPressStyle())
        .disabled(store.isRefreshing)
        .help("Refresh live quotes")
        .accessibilityLabel("Refresh live quotes")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private var sampleBanner: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "info.circle.fill").foregroundStyle(DS.Palette.warningSoft)
            // D5 (rotation-3 triage): `feedError ?? sample` hid the sample-data truth whenever a
            // feed error was ALSO present — both facts are true simultaneously (on sample data
            // AND the live feed errored) and the reader needs both, not whichever one won ??.
            Text("Sample data — connecting to the live Tadawul + NASDAQ feed… The signals show the engine running on illustrative prices."
                 + (store.feedError.map { " \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.sm)
        .background(DS.Palette.warningSoft.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            .stroke(LinearGradient(colors: [DS.Palette.warningSoft.opacity(0.52),
                                            DS.Palette.warningSoft.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }

    private var sectionPicker: some View {
        DSSegmentPicker(cases: Array(MarketSection.allCases), selection: $section) { $0.title }
            .frame(maxWidth: 520)
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .watchlist: signalListView(watchlistOnly: true)
        case .all:       signalListView(watchlistOnly: false)
        case .ideas:           ideasSection
        case .heatmap:         heatmap
        case .portfolio:       portfolioSection
        case .alerts:          alertsSection
        case .briefing:        briefingSection
        }
    }

    // MARK: Alerts

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "bell.badge.fill").font(.system(size: mvFont18)).foregroundStyle(DS.Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Strong-signal alerts").font(.system(size: mvFont15, weight: .semibold)).foregroundStyle(.white)
                        // POST2420-COPY item 5: across the full analyzed universe (901 names since
                        // the 2026-07-16 restriction), an
                        // unqualified "appears" reads as "anywhere in the analyzed universe" —
                        // the monitor's unattended background cycle is scoped to
                        // StockSageUniverse.core (~210) + the user's watchlist (StockSageMonitor's
                        // runCycle, owner-ratified core+watchlist scoping), not the full universe.
                        // Interpolated so it can't drift from the live count.
                        Text("Get a Mac notification when a Strong Buy or Strong Sell appears among the \(StockSageUniverse.core.count)-name curated core + your watchlist.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { monitoring }, set: { toggleMonitoring($0) }))
                        .labelsHidden().tint(DS.Palette.accent)
                        .accessibilityLabel("Strong-signal monitoring")
                }
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "star.circle").font(.system(size: mvFont12)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Watch only my watchlist").font(.system(size: mvFont12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                        Text(store.userSymbols.isEmpty
                             ? "Add tickers to your watchlist to use this — alerts scan the curated \(StockSageUniverse.core.count)-name core + your watchlist — not the full \(StockSageUniverse.worldwide.count)-name analyzed universe (that runs on Find ideas)."
                             : "Alerts scan only your \(store.userSymbols.count) watchlist name\(store.userSymbols.count == 1 ? "" : "s") (faster). The full board won't auto-refresh — tap Refresh for it.")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $watchlistOnly).labelsHidden().tint(DS.Palette.accent)
                        .disabled(store.userSymbols.isEmpty)
                        .accessibilityLabel("Watch only my watchlist")
                }
                if !monitorError.isEmpty {
                    Text(monitorError).font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
                Button { Task { await checkAlertsNow() } } label: {
                    HStack(spacing: 6) {
                        Group {
                            if checkingAlerts { ProgressView().controlSize(.small).tint(DS.Palette.accent) }
                            else { Image(systemName: "arrow.clockwise").font(.system(size: mvFont11, weight: .semibold)) }
                        }
                        .transition(.opacity)
                        .animation(DS.Motion.smooth, value: checkingAlerts)
                        Text(checkingAlerts ? "Checking…" : "Check now")
                            .font(.system(size: mvFont11_5, weight: .semibold))
                            .contentTransition(.opacity)
                            .animation(DS.Motion.smooth, value: checkingAlerts)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(
                        LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
                }
                .buttonStyle(LuxPressStyle()).disabled(checkingAlerts)
            }
            .animation(DS.Motion.smooth, value: monitorError.isEmpty)
            .padding(DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(DS.Bezel.cardFill)
                    .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
            )
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(DS.Palette.surfaceStroke, lineWidth: 1))

            if alertSignals.isEmpty {
                Text(hasScanned
                     ? "No strong signals found — mostly Hold. Tap Check now to scan again."
                     : "Not scanned yet — tap Check now to find strong signals.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .transition(.opacity)
            } else {
                VStack(spacing: 1) {
                    ForEach(alertSignals, id: \.symbol) {
                        signalAlertRow($0)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .animation(DS.Motion.smooth, value: alertSignals.count)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .fill(DS.Bezel.cardFill)
                        .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
                )
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
                .transition(.opacity)
            }

            priceAlertsPanel
        }
        .animation(DS.Motion.smooth, value: alertSignals.isEmpty)
    }

    // MARK: Price alerts (user-set levels)

    private var priceAlertsPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "target").font(.system(size: mvFont16)).foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Price alerts").font(.system(size: mvFont14, weight: .semibold)).foregroundStyle(.white)
                    Text("Notify me once when a symbol reaches a level I set — at or through it (needs alerts on).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                journalField("Ticker", text: $paSymbol, width: 78)
                DSSegmentPicker(cases: [PriceAlert.Direction.above, .below],
                                selection: $paDirection) { $0 == .above ? "≥" : "≤" }
                    .frame(width: 74)
                    .accessibilityLabel("Alert direction")
                journalField("Price", text: $paTarget, width: 78)
                Button { addPriceAlert() } label: {
                    Text("Add").font(.system(size: mvFont11_5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(DS.Palette.accent, in: Capsule())
                }.buttonStyle(LuxPressStyle())
                Spacer()
            }
            if !paError.isEmpty {
                Text(paError).font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                    .transition(.opacity)
            }
            if !store.priceAlerts.isEmpty {
                VStack(spacing: 1) {
                    ForEach(store.priceAlerts) { priceAlertRow($0) }
                }
                .animation(DS.Motion.smooth, value: store.priceAlerts.count)
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    private func priceAlertRow(_ a: PriceAlert) -> some View {
        // Audit 2026-07-12 pass-3 (finding ②): the monitor's checkPriceAlerts fetches EVERY armed
        // alert's symbol independently (StockSageMonitor.checkPriceAlerts → fetchQuotes(armed symbols)),
        // NOT just board symbols — so an off-board ticker's alert DOES fire. currentPrice reads only the
        // board (store.symbols), so a nil there for an OFF-BOARD symbol is not evidence the alert can't
        // fire; asserting "no quote / cannot fire" would make a user delete a working alert. Only warn
        // for a symbol that IS on the board yet has no price (genuinely unquotable this session).
        let onBoard = store.symbols.contains { $0.symbol.uppercased() == a.symbol.uppercased() }
        let noQuote = !store.isSampleData && !store.loadedFromCache && onBoard && currentPrice(a.symbol) == nil
        return HStack(spacing: 10) {
            Text(a.symbol).font(.system(size: mvFont13, weight: .bold, design: .rounded)).foregroundStyle(.white)
            // ALERT-FMT-1 (round-3 honesty hunt): was bare `.formatted()`, diverging from the
            // shared adaptive formatter every other card/board/sheet uses — this row now matches.
            Text("\(a.direction.symbol) \(adaptivePrice(a.target))").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if a.triggeredAt != nil {
                Text("triggered").font(.caption2.weight(.semibold)).foregroundStyle(DS.Palette.warningSoft)
                Button { store.resetPriceAlert(a.id) } label: {
                    Text("Re-arm").font(.caption2.weight(.semibold)).foregroundStyle(DS.Palette.accent)
                }.buttonStyle(.plain).help("Re-arm this alert")
            } else if noQuote {
                // The monitor fetches quotes to check alerts; if this symbol returns nothing,
                // the alert will never fire — show "no quote" rather than a false green "armed".
                Text("no quote")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DS.Palette.warningSoft)
                    .help("No live price found for \(a.symbol) — alert cannot fire until a quote is available. Check the ticker spelling.")
            } else {
                Text("armed").font(.caption2.weight(.semibold)).foregroundStyle(.green.opacity(0.85))
            }
            Button { store.removePriceAlert(a.id) } label: {
                Image(systemName: "trash").font(.system(size: mvFont11)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Remove alert")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func addPriceAlert() {
        let sym = paSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !sym.isEmpty, !sym.contains(" "), sym.count <= 20 else { paError = "Enter a valid ticker."; return }
        let (price, err) = StockSagePriceAlertEngine.validateTarget(paTarget)
        guard let p = price else { paError = err ?? "Enter a price."; return }
        // Detect a duplicate BEFORE calling the engine so the field contents are preserved and
        // the user gets an honest error instead of a silent success (the engine guard returns
        // without adding, but the view would clear the fields and show no feedback).
        if store.priceAlerts.contains(where: { $0.isArmed && $0.symbol == sym && $0.target == p && $0.direction == paDirection }) {
            paError = "Already armed — this alert is already active."
            return
        }
        store.addPriceAlert(symbol: sym, target: p, direction: paDirection)
        paSymbol = ""; paTarget = ""; paError = ""
    }

    private func signalAlertRow(_ s: StockSageSignal) -> some View {
        let hovered = hoveredAlertSymbol == s.symbol
        return HStack(spacing: 10) {
            Text(s.symbol).font(.system(size: mvFont14, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(s.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(s.reason)
            Spacer(minLength: 8)
            Text(s.recommendation.rawValue)
                .font(.system(size: mvFont11, weight: .bold)).foregroundStyle(recTextColor(s.recommendation))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(recColor(s.recommendation), in: Capsule())
        }
        .padding(.horizontal, DS.Space.sm).padding(.vertical, 10)
        .background(hovered ? DS.Palette.accent.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { over in
            withAnimation(DS.Motion.smooth) {
                if over { hoveredAlertSymbol = s.symbol }
                else if hoveredAlertSymbol == s.symbol { hoveredAlertSymbol = nil }
            }
        }
    }

    private func toggleMonitoring(_ on: Bool) {
        monitorError = ""
        if on {
            do {
                try StockSageMonitor.shared.start()
                monitoring = true
            } catch StockSageMonitor.MonitorError.alreadyRunning {
                // Monitor is already live (e.g. window was closed and reopened) — treat as
                // success so the toggle reaches ON and stop() becomes reachable again.
                monitoring = true
            } catch {
                monitorError = error.localizedDescription
                monitoring = false
            }
        } else {
            StockSageMonitor.shared.stop(); monitoring = false
        }
    }

    private func checkAlertsNow() async {
        checkingAlerts = true
        // Honour the watchlist-only scope here too, so "Check now" matches what the
        // background monitor actually evaluates.
        if watchlistOnly && !store.userSymbols.isEmpty {
            // runWatchlistCycle fetches fresh quotes internally — no pre-refresh needed.
            alertSignals = await StockSageMonitor.shared.runWatchlistCycle(store.userSymbols, notify: false)
        } else {
            // Mirror the monitor's full-core loop: pull a fresh snapshot BEFORE scoring so
            // "Check now" never re-evaluates stale / sample-seeded prices. Without this
            // the else-branch would re-score hours-old quotes (or the sample-seeded strong
            // movers) and display them as current alerts with no caveat.
            await store.refresh()
            alertSignals = await StockSageMonitor.shared.runCycle(notify: false)
        }
        hasScanned = true
        checkingAlerts = false
    }

    // MARK: Portfolio

    private func currentPrice(_ symbol: String) -> Double? {
        store.symbols.first { $0.symbol.uppercased() == symbol.uppercased() }?.latest?.price
    }

    /// THE one true holding value: per-share price × shares, with the symbol's quote unit applied.
    /// London .L trades in PENCE, so a raw price×shares is ~100× the real (£) value — every value /
    /// P&L site MUST route through here (previously only the currency-exposure widget did, so the
    /// headline total, position rows, rebalance and allocation all over-valued .L holdings ~100×).
    private func holdingValue(_ symbol: String, perShare: Double, shares: Double) -> Double {
        StockSageCurrency.majorUnitValue(symbol: symbol, rawValue: perShare * shares)
    }

    /// ALERT-FMT-1: thin alias onto the single shared formatter (`StockSageCurrency.adaptivePrice`,
    /// pure, tested there) — keeps call sites below unchanged in shape.
    private func adaptivePrice(_ v: Double) -> String { StockSageCurrency.adaptivePrice(v) }

    /// L10N-01: thin alias onto StockSageCurrency.approxAmount (pure, tested there) — keeps
    /// call sites below unchanged in shape.
    private func approxAmount(_ v: Double, symbol: String) -> String {
        StockSageCurrency.approxAmount(v, symbol: symbol)
    }

    /// THE one CCY→USD rate resolver (post-restriction review, 2026-07-16): tracked quote first
    /// (direct CCYUSD=X, else inverse 1/USDCCY=X), then `store.infraFX` the same two ways.
    /// FX pairs left the tracked universe with the Tadawul+NASDAQ restriction, so the tracked
    /// lookups now normally miss and infraFX (the engine's direct fetch, currently USDSAR=X)
    /// carries the .SR conversions. nil = genuinely no rate → callers exclude, never sum 1:1.
    /// EVERY FX-resolution site routes through here — the adversarial review found the heat
    /// gauge and the currency-exposure card each had a private COPY of this logic that missed
    /// the infraFX fallback (the heat copy silently DROPPED open .SR trades → under-reported
    /// risk, the dangerous direction). One resolver = the drift is structurally impossible.
    private func fxRateToUSD(_ ccy: String) -> Double? {
        if ccy == "USD" { return 1 }
        if let r = currentPrice("\(ccy)USD=X"), r > 0 { return r }
        if let inv = currentPrice("USD\(ccy)=X"), inv > 0 { return 1 / inv }
        if let r = store.infraFX["\(ccy)USD=X".uppercased()], r > 0 { return r }
        if let inv = store.infraFX["USD\(ccy)=X".uppercased()], inv > 0 { return 1 / inv }
        return nil
    }

    /// CCY→USD rates for every currency held (via `fxRateToUSD`; USD = 1). Currencies with no
    /// rate keep the honest degradation (excluded from USD totals via `untrackedFXCurrencies`).
    private var fxRatesToUSD: [String: Double] {
        var rates: [String: Double] = ["USD": 1]
        for ccy in Set(portfolio.positions.map { StockSageCurrency.currencyForSymbol($0.symbol) }) where ccy != "USD" {
            if let r = fxRateToUSD(ccy) { rates[ccy] = r }
        }
        return rates
    }

    /// Currencies in the book with NO tracked FX rate — EXCLUDED from the USD total (never summed 1:1).
    private var untrackedFXCurrencies: [String] {
        let rates = fxRatesToUSD
        return Set(portfolio.positions.map { StockSageCurrency.currencyForSymbol($0.symbol) })
            .filter { rates[$0] == nil }.sorted()
    }

    /// FX trades ~24x5, so a rate quote older than this (a long holiday weekend) is stale — the USD
    /// conversion it produces may be off. We still convert (dropping the holding distorts net worth
    /// MORE than a slightly-old rate), but the summary flags it. Only-real-data: stale is not "live".
    private static let maxFXAgeSeconds: TimeInterval = 72 * 3600

    /// Age of the freshest FX quote (CCYUSD=X or USDCCY=X) backing a currency; nil if none is tracked
    /// OR none carries a real market timestamp (can't judge → not stale, never a false alarm). Uses the
    /// quote's MARKET time, not its fetch time (`.time` defaults to now, which would read ~0 age and make
    /// the stale-FX warning permanently dead — the same trap fixed in the live-quote path).
    private func fxRateAge(_ ccy: String, asOf now: Date) -> TimeInterval? {
        let times = ["\(ccy)USD=X", "USD\(ccy)=X"].compactMap { sym in
            store.symbols.first { $0.symbol.uppercased() == sym.uppercased() }?.latest?.marketTime
        }
        guard let freshest = times.max() else { return nil }
        return Swift.max(0, now.timeIntervalSince(freshest))
    }

    /// Held currencies whose FX rate EXISTS but is STALE (older than maxFXAge): the USD total still
    /// converts them, but at an old rate — surfaced so the headline value is not silently overstated.
    private var staleFXCurrencies: [String] {
        let now = Date()
        let rates = fxRatesToUSD
        return Set(portfolio.positions.map { StockSageCurrency.currencyForSymbol($0.symbol) })
            .filter { $0 != "USD" && rates[$0] != nil }
            .filter { (fxRateAge($0, asOf: now) ?? 0) > Self.maxFXAgeSeconds }
            .sorted()
    }

    /// For an FX pair symbol (ending "=X"), returns the QUOTE (trailing) currency, which is the
    /// denomination of price×shares. When the quote leg is USD the position is already in USD and
    /// needs no conversion (rate = 1). This differs from currencyForSymbol's EXPOSURE leg, which
    /// is correct for risk semantics but wrong as a USD-conversion key for …USD=X pairs (using
    /// the exposure leg there would multiply an already-USD amount by the rate again — rate²).
    /// Non-=X symbols fall back to currencyForSymbol as before.
    private func conversionCurrencyForSymbol(_ symbol: String, base: String = "USD") -> String {
        // Canonical, unit-tested logic lives in StockSageCurrency (extracted 2026-07-12 pass-2 so
        // every valuation call site shares one accessor). Kept as a thin instance method so the
        // existing call sites read unchanged.
        StockSageCurrency.conversionCurrencyForSymbol(symbol, base: base)
    }

    /// Audit 2026-07-12 (ideas-card wave-2 #2): `ps.pctOfAccount` compares a NATIVE-currency notional
    /// to the (USD) account, so a JPY/SAR/pence winner reads 100×/3.75×/100× over → a FALSE "exceeds
    /// account" / leverage warning on an unleveraged cash position. This returns the notional as a %
    /// of the account in ONE currency: notional (pence-normalized × FX rate) ÷ account. Untracked FX
    /// → falls back to the raw `ps.pctOfAccount` (prior behavior). Display-only; `ps` is unchanged.
    /// F3 follow-up (2026-07-16): ONE raw-quote-unit→USD converter for display math, backed by
    /// the shared `fxRateToUSD` RESOLVER (portfolio dict + infraFX), not the portfolio-only
    /// `fxRatesToUSD` dict — the dict silently lacked SAR whenever no .SR position was held,
    /// reverting "FX-corrected" figures to the wrong basis. nil = untracked (caller falls back).
    private func usdAmount(_ raw: Double, symbol: String) -> Double? {
        let ccy = conversionCurrencyForSymbol(symbol)
        if ccy == "USD" { return raw }
        guard let rate = fxRateToUSD(ccy) else { return nil }
        return StockSageCurrency.majorUnitValue(symbol: symbol, rawValue: raw) * rate
    }

    /// First-real-trade review (2026-07-16): the "Realized P&L" stat's display string. When the
    /// closed book is a single currency it renders `totalProfit` through the tested
    /// `signedAmount` (USD → byte-identical bare "+150.00", else "+150.00 SAR", pence ÷100); when
    /// it mixes currencies (`profitSymbol == nil`) the raw 1:1 sum is meaningless, so it shows
    /// "mixed" instead of a fabricated number. Pure display.
    private func realizedProfitText(_ s: JournalStats) -> String {
        guard let sym = s.profitSymbol else { return "mixed" }
        return StockSageCurrency.signedAmount(s.totalProfit, symbol: sym)
    }

    private func pctOfAccountUSD(_ ps: PositionSize, symbol: String, account: Double) -> Double {
        guard account > 0 else { return ps.pctOfAccount }
        guard let notionalUSD = usdAmount(ps.notional, symbol: symbol) else { return ps.pctOfAccount }
        return notionalUSD / account * 100
    }

    /// First-real-trade review F3 (2026-07-16): THE sizing path for every "Size it now" /
    /// copy-plan / what-if surface. The share count was currency-mixed — a USD risk budget
    /// divided by a native-currency risk/share under-sized .SR ~3.75× vs the stated risk%
    /// (the 07-12/07-13 audits fixed only labels). When the symbol's quote currency has a
    /// tracked FX rate, the account is converted into RAW quote units (pence-aware via
    /// majorUnitValue) so a 1%/trade plan genuinely risks 1%; USD symbols and untracked-FX
    /// currencies keep the prior behavior byte-identical (never guess a rate).
    private func sizedPosition(account: Double, riskFraction: Double, symbol: String,
                               entry: Double, stop: Double) -> PositionSize? {
        let ccy = conversionCurrencyForSymbol(symbol)
        if ccy != "USD", let rate = fxRateToUSD(ccy) {
            let rawUnitToUSD = StockSageCurrency.majorUnitValue(symbol: symbol, rawValue: 1) * rate
            return StockSagePositionSizer.size(accountUSD: account, riskFraction: riskFraction,
                                               entry: entry, stop: stop, rawUnitToUSD: rawUnitToUSD)
        }
        return StockSagePositionSizer.size(account: account, riskFraction: riskFraction,
                                           entry: entry, stop: stop)
    }

    /// F3 wave-A (2026-07-16): ccy→USD rate map for the PURE plan/snapshot builders (TodayPlan,
    /// DecisionSnapshot, the unfundable-row qualifier) — resolver-backed like `sizedPosition`,
    /// so .SR resolves via infraFX even with no .SR position held. Only tracked rates enter
    /// the map; the builders treat a missing entry as "never guess" (prior behavior).
    private func sizingFXRates(for symbols: [String]) -> [String: Double] {
        var rates: [String: Double] = [:]
        for ccy in Set(symbols.map { conversionCurrencyForSymbol($0) }) where ccy != "USD" {
            if let r = fxRateToUSD(ccy) { rates[ccy] = r }
        }
        return rates
    }

    /// Portfolio cost & value in USD. Each holding's value AND cost go through holdingValue (so the
    /// .L-pence ÷100 is applied to BOTH — the P&L unit matches) then × its CCY→USD rate, so we never
    /// sum GBP + USD at 1:1. Holdings whose currency has no tracked rate are EXCLUDED (see
    /// untrackedFXCurrencies), not counted at par. (Cost uses today's FX, so P&L blends asset + FX.)
    ///
    /// FX-pair positions (…=X): price×shares is already denominated in the pair's QUOTE currency
    /// (e.g. EURUSD=X price is in USD), so we convert by the quote leg, not the exposure leg that
    /// currencyForSymbol returns. Using the exposure leg for …USD=X pairs would multiply an
    /// already-USD amount by the EURUSD rate again → rate², inflating value ~8–27%.
    private var portfolioTotals: (cost: Double, value: Double) {
        var cost = 0.0, value = 0.0
        let rates = fxRatesToUSD
        for p in portfolio.positions {
            // Exclude untracked-FX AND unpriced holdings. Crucially, NO `?? costBasis` fallback for
            // value — substituting cost basis would fabricate value == cost ⇒ a fake green $0 P&L.
            // Use the quote-leg currency for =X pairs (already-USD when quote = "USD"),
            // and the exposure-based currencyForSymbol for all other instruments.
            let ccyKey = conversionCurrencyForSymbol(p.symbol)
            guard let rate = rates[ccyKey], let px = currentPrice(p.symbol) else { continue }
            cost += holdingValue(p.symbol, perShare: p.costBasis, shares: p.shares) * rate
            value += holdingValue(p.symbol, perShare: px, shares: p.shares) * rate
        }
        return (cost, value)
    }

    /// Held symbols with NO live price — EXCLUDED from the USD total (never valued at cost basis),
    /// surfaced in the summary so the headline value/P&L is honestly "priced holdings only".
    private var unpricedHoldings: [String] {
        portfolio.positions.filter { currentPrice($0.symbol) == nil }.map(\.symbol)
    }

    private var portfolioSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            portfolioSummary
            addPositionForm
            if portfolio.positions.isEmpty {
                Text("No holdings yet — add one above to track value & P&L.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .transition(.opacity)
            } else {
                VStack(spacing: 1) {
                    ForEach(portfolio.positions) {
                        positionRow($0)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .animation(DS.Motion.smooth, value: portfolio.positions.count)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .fill(DS.Bezel.cardFill)
                        .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
                )
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
                .transition(.opacity)
            }
            if !portfolio.positions.isEmpty { allocationPanel }
            if !portfolio.positions.isEmpty { riskParityPanel }
            if !portfolio.positions.isEmpty { portfolioAnalyticsPanel }
            correlationHeatmapPanel
            forwardScoreboardPanel   // engine's bias-corrected paper track vs the owner's own journal
            tradeJournalPanel   // records the owner's actual trades + realized P&L/R
            kellySizerPanel   // a standalone calculator — useful with or without holdings
        }
        .animation(DS.Motion.smooth, value: portfolio.positions.isEmpty)
    }

    private var portfolioSummary: some View {
        let t = portfolioTotals
        let pl = t.value - t.cost
        let plPct = t.cost > 0 ? pl / t.cost * 100 : 0
        let up = pl >= 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Portfolio value (USD)").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "$%.2f", t.value))
                        .font(.system(size: mvFont22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(DS.Motion.smooth, value: t.value)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total P&L (USD)").font(.caption).foregroundStyle(.secondary)
                    if t.value == 0, t.cost == 0, !portfolio.positions.isEmpty {
                        // Nothing priced/convertible → don't paint a fake green +$0.00 P&L.
                        Text("— no priced holdings").font(.system(size: mvFont15, weight: .semibold)).foregroundStyle(.secondary)
                    } else {
                        // Percent return is undefined when cost basis is 0 (e.g. gifted/0-cost lots) —
                        // show the real dollar P&L but "—%" instead of a fabricated +0.0%.
                        Text((up ? "+" : "") + String(format: "$%.2f", pl)
                             + (t.cost > 0 ? String(format: " (%+.1f%%)", plPct) : " (—%)"))
                            .font(.system(size: mvFont15, weight: .semibold))
                            .foregroundStyle(up ? DS.Palette.successSoft : DS.Palette.danger)
                            .contentTransition(.numericText())
                            .animation(DS.Motion.smooth, value: pl)
                    }
                }
            }
            if !unpricedHoldings.isEmpty {
                Text("\(unpricedHoldings.count) holding\(unpricedHoldings.count == 1 ? "" : "s") with no live price (\(unpricedHoldings.prefix(3).joined(separator: ", "))) — excluded; value/P&L is priced holdings only.")
                    .font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !untrackedFXCurrencies.isEmpty {
                Text("Excludes \(untrackedFXCurrencies.joined(separator: ", ")) holdings — no FX rate to convert to USD (track \(untrackedFXCurrencies.first ?? "")USD=X). P&L uses today's FX, so it blends asset + currency moves.")
                    .font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !staleFXCurrencies.isEmpty {
                Text("FX rate for \(staleFXCurrencies.joined(separator: ", ")) is over \(Int(Self.maxFXAgeSeconds / 3600))h old — those holdings convert to USD at a stale rate, so the total may be off.")
                    .font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    private var addPositionForm: some View {
        HStack(spacing: DS.Space.sm) {
            field($newSymbol, "Symbol", width: 84, focus: .symbol)
            field($newShares, "Shares", width: 66, focus: .shares)
            field($newCost, "Cost/sh", width: 72, focus: .cost)
            Button {
                // Validated parse — an unparseable cost ("1,234.56" pasted from a broker, a blank
                // field) must never default to $0 basis: that renders the ENTIRE value as fake
                // green profit and inflates the headline Total P&L. The disabled gate below makes
                // this unreachable with invalid input; the guard is belt-and-suspenders.
                guard let sh = StockSageInput.positiveAmount(newShares),
                      let cost = StockSageInput.nonNegativeAmount(newCost) else { return }
                portfolio.add(symbol: newSymbol, shares: sh, costBasis: cost)
                newSymbol = ""; newShares = ""; newCost = ""
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: mvFont20)).foregroundStyle(DS.Palette.accent)
            }
            .buttonStyle(LuxPressStyle())
            .help("Add holding").accessibilityLabel("Add holding")
            .disabled(newSymbol.trimmingCharacters(in: .whitespaces).isEmpty
                      || StockSageInput.positiveAmount(newShares) == nil
                      || StockSageInput.nonNegativeAmount(newCost) == nil)
            Spacer()
        }
    }

    private func field(_ text: Binding<String>, _ placeholder: String, width: CGFloat, focus: AddField) -> some View {
        let active = focusedAddField == focus
        return TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: mvFont13))
            .focused($focusedAddField, equals: focus)
            .padding(.horizontal, 8).padding(.vertical, 6).frame(width: width)
            .background(Color.white.opacity(active ? 0.11 : 0.09), in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .stroke(active
                        ? AnyShapeStyle(LinearGradient(colors: [DS.Palette.accent.opacity(0.55), DS.Palette.accent.opacity(0.15)],
                                                       startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(DS.Palette.surfaceStroke), lineWidth: 1))
            .shadow(color: DS.Palette.accent.opacity(active ? 0.15 : 0.0), radius: 8, y: 2)
            .animation(DS.Motion.lux, value: active)
            .accessibilityLabel(placeholder)
    }

    private func positionRow(_ p: PortfolioPosition) -> some View {
        let price = currentPrice(p.symbol)
        let value = holdingValue(p.symbol, perShare: price ?? p.costBasis, shares: p.shares)
        // Cost through holdingValue too, so a .L holding's P&L isn't £value − pence-cost (per-row
        // stays in the LOCAL currency; the headline total does the USD conversion).
        let pl = value - holdingValue(p.symbol, perShare: p.costBasis, shares: p.shares)
        let up = pl >= 0
        let hovered = hoveredPositionID == p.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.symbol).font(.system(size: mvFont14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("\(numString(p.shares)) sh @ \(adaptivePrice(p.costBasis))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(price == nil ? "— no price" : adaptivePrice(value))
                    .font(.system(size: mvFont14, weight: .semibold)).foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(DS.Motion.smooth, value: value)
                if price != nil {
                    Text((up ? "+" : "") + adaptivePrice(pl))
                        .font(.caption).foregroundStyle(up ? DS.Palette.successSoft : DS.Palette.danger)
                        .contentTransition(.numericText())
                        .animation(DS.Motion.smooth, value: pl)
                }
            }
            .animation(DS.Motion.smooth, value: up)
            Button { portfolio.remove(p.id) } label: {
                Image(systemName: "trash").font(.system(size: mvFont12))
                    .foregroundStyle(hovered ? DS.Palette.danger.opacity(0.7) : Color.secondary)
            }
            .buttonStyle(LuxPressStyle()).help("Remove holding").accessibilityLabel("Remove \(p.symbol)")
        }
        .padding(.horizontal, DS.Space.sm).padding(.vertical, 10)
        .background(hovered ? DS.Palette.accent.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { over in
            withAnimation(DS.Motion.smooth) {
                if over { hoveredPositionID = p.id }
                else if hoveredPositionID == p.id { hoveredPositionID = nil }
            }
        }
    }

    private func numString(_ d: Double) -> String {
        // %.0f, not String(Int(d)) — Int(Double) TRAPS past Int.max (~9.22e18), and a persisted
        // pathological share count would then crash every Portfolio render (an in-app-unrecoverable
        // crash loop, since positions live in UserDefaults).
        d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d)
    }

    // MARK: Risk parity

    private var riskParityPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "scalemass.fill").font(.system(size: mvFont16)).foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Risk-parity weights").font(DS.Typography.titleM).foregroundStyle(.white)
                    Text("Size each holding by 1 ÷ volatility so they contribute equal risk.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { Task { await store.refreshRiskParity() } } label: {
                    HStack(spacing: 6) {
                        Group {
                            if store.isComputingParity { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "scalemass").font(.system(size: mvFont11, weight: .semibold)) }
                        }
                        Text(store.isComputingParity ? "Sizing…" : "Balance by risk")
                            .font(.system(size: mvFont11_5, weight: .semibold)).contentTransition(.opacity)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(DS.Palette.accent, in: Capsule())
                }
                .buttonStyle(LuxPressStyle()).disabled(store.isComputingParity)
            }
            if let err = store.parityError {
                Text(err).font(.caption2).foregroundStyle(DS.Palette.warningSoft)
            }
            if !store.riskParityDropped.isEmpty {
                Text("⚠︎ \(store.riskParityDropped.joined(separator: ", ")) excluded — no usable vol data; risk-parity covers only what was assessable.")
                    .font(.caption2).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
            }
            if !store.riskParity.isEmpty {
                // Aggregate multi-lot books: the engine emits one RiskParityTarget per lot; same-symbol
                // lots have identical IDs (symbol), causing undefined SwiftUI ForEach behavior, and
                // the targets are additive (each lot's targetWeight is its share of the whole book's
                // risk budget). Sum currentWeight/targetWeight and average volatility per symbol.
                let aggregatedParity: [RiskParityTarget] = {
                    var bySymbol: [String: RiskParityTarget] = [:]
                    var lotCount: [String: Int] = [:]
                    for t in store.riskParity {
                        if let existing = bySymbol[t.symbol] {
                            bySymbol[t.symbol] = RiskParityTarget(
                                symbol: t.symbol,
                                currentWeight: existing.currentWeight + t.currentWeight,
                                targetWeight: existing.targetWeight + t.targetWeight,
                                volatility: existing.volatility + t.volatility
                            )
                            lotCount[t.symbol, default: 1] += 1
                        } else {
                            bySymbol[t.symbol] = t
                            lotCount[t.symbol] = 1
                        }
                    }
                    // Average volatility across lots; preserve original ordering (first appearance wins).
                    var seen = Set<String>()
                    return store.riskParity.compactMap { t -> RiskParityTarget? in
                        guard seen.insert(t.symbol).inserted, let agg = bySymbol[t.symbol] else { return nil }
                        let n = Double(lotCount[t.symbol] ?? 1)
                        return RiskParityTarget(symbol: agg.symbol, currentWeight: agg.currentWeight,
                                               targetWeight: agg.targetWeight, volatility: agg.volatility / n)
                    }
                }()
                VStack(spacing: 1) { ForEach(aggregatedParity) { parityRow($0) } }
                if let vs = StockSageRiskParity.vsEqualWeight(store.riskParity) {
                    Text(vs.note).font(.caption2).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Equalizes risk, not a profit promise. Risk parity can suffer in correlation shocks — keep a cash sleeve.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                // Concrete rebalance: the actual $ trades to reach the risk-parity targets,
                // with a no-trade band (see rebalancePlanView) so you don't churn on tiny drifts.
                // Convert each holding to USD BEFORE the plan (mirrors portfolioTotals) — summing
                // GBP/SAR/JPY at 1:1 skewed the target weights AND mislabeled the trade sizes as "$".
                // Untracked-FX holdings are excluded (no rate to convert), same as the headline total.
                //
                // TWO SCOPING RULES (2026-07-02 adversarial-review fixes, both fabricated trades):
                //  • The plan is computed over the INTERSECTION of FX-convertible holdings and the
                //    symbols risk-parity actually SIZED — a holding dropped for missing vol has no
                //    target, and plan()'s `norm[s] ?? 0` would otherwise render it as a concrete
                //    "Sell $<everything>" liquidation the engine never issued; a target whose
                //    holding has no tracked FX rate would conversely render a phantom "Buy" for a
                //    name already owned (and skew every other trade via the excluded value).
                //  • Targets are frozen at "Balance by risk" time while holdings are live — after
                //    any portfolio add/remove the two sets describe DIFFERENT books, so the plan is
                //    suppressed with a refresh notice instead of computing trades from mismatched sets.
                let liveSymbols = Set(portfolio.positions.map { $0.symbol.uppercased() })
                let sizedSymbols = Set(store.riskParity.map { $0.symbol.uppercased() })
                    .union(store.riskParityDropped.map { $0.uppercased() })
                if liveSymbols != sizedSymbols {
                    Text("⚠︎ Holdings changed since the last risk sizing — tap “Balance by risk” again before trading on these targets.")
                        .font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    rebalancePlanView
                }
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    /// The concrete rebalance-trades block, computed ONLY over symbols that are BOTH
    /// FX-convertible AND actually sized by risk parity (see the scoping comment at the call
    /// site). Split out so the set-intersection logic stays readable and independently checkable.
    @ViewBuilder private var rebalancePlanView: some View {
        // Named constant so the band value is passed explicitly to plan() AND interpolated
        // into the copy — if the engine default ever changes, one edit keeps them in sync.
        let rebalBand: Double = 0.02
        let rebalFX = fxRatesToUSD
        let targetSymbols = Set(store.riskParity.map { $0.symbol.uppercased() })
        // Exclude unpriced holdings (no live quote) rather than falling back to cost basis:
        // substituting cost basis fabricates a value that distorts every other weight and the
        // trade sizes (mirrors portfolioTotals' explicit "substituting cost basis would fabricate
        // value" exclusion). The unpricedHoldings list already names them at the headline total.
        let rebalHoldings = portfolio.positions.compactMap { p -> (symbol: String, value: Double)? in
            guard targetSymbols.contains(p.symbol.uppercased()),
                  let price = currentPrice(p.symbol),
                  // Audit 2026-07-12 pass-2 (finding C): key on the QUOTE leg (conversionCurrencyForSymbol),
                  // not the exposure leg — else an already-USD …USD=X pair is multiplied by the rate again (rate²).
                  let rate = rebalFX[conversionCurrencyForSymbol(p.symbol)] else { return nil }
            return (symbol: p.symbol,
                    value: holdingValue(p.symbol, perShare: price, shares: p.shares) * rate)
        }
        let holdingSymbols = Set(rebalHoldings.map { $0.symbol.uppercased() })
        // Sum target weights for multi-lot same-symbol entries (+ not first-wins) so a
        // two-lot AAPL position gets its full combined target, not just the first lot's.
        let rebalTargets = Dictionary(store.riskParity.filter { holdingSymbols.contains($0.symbol.uppercased()) }
                                        .map { ($0.symbol, $0.targetWeight) },
                                      uniquingKeysWith: +)
        let fxExcluded = store.riskParity.map(\.symbol).filter { !holdingSymbols.contains($0.uppercased()) }
        if !fxExcluded.isEmpty {
            Text("⚠︎ \(fxExcluded.joined(separator: ", ")) excluded from the trade plan — no tracked FX rate to convert to USD.")
                .font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let plan = StockSageRebalance.plan(holdings: rebalHoldings, targets: rebalTargets, band: rebalBand) {
                    if plan.isBalanced {
                        Text("✓ Within \(Int(rebalBand * 100))% of target — no rebalance needed.")
                            .font(.caption2).foregroundStyle(DS.Palette.successSoft)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("To rebalance (≈$ trades, ignores costs/taxes):")
                                .font(.system(size: mvFont9, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(plan.trades) { t in
                                Text("\(t.action) \(String(format: "$%.0f", abs(t.deltaValue))) of \(t.symbol)  (\(String(format: "%.0f%%→%.0f%%", t.currentWeight * 100, t.targetWeight * 100)))")
                                    .font(.system(size: mvFont9, design: .monospaced))
                                    .foregroundStyle(t.deltaValue > 0 ? DS.Palette.successSoft : DS.Palette.danger)
                            }
                        }
                    }
                }
    }

    private func parityRow(_ t: RiskParityTarget) -> some View {
        // NOTE: t.currentWeight is the engine's RAW price×shares value (no FX conversion, no
        // pence normalisation). The rebalance-trade plan below uses USD-converted values and
        // can disagree for mixed-currency books. To avoid showing two contradictory "current"
        // numbers on the same card, we display only the TARGET weight here and let the trade
        // plan (which IS USD-correct) carry the current→target movement for each symbol.
        let targetPct = String(format: "%.0f%%", t.targetWeight * 100)
        return HStack(spacing: 10) {
            Text(t.symbol).font(.system(size: mvFont13, weight: .bold, design: .rounded))
                .foregroundStyle(.white).frame(width: 70, alignment: .leading).lineLimit(1)
            Text(String(format: "vol %.0f%%", t.volatility * 100)).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("target \(targetPct)")
                .font(.system(size: mvFont12, weight: .semibold)).foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, DS.Space.sm).padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(t.symbol), vol \(Int((t.volatility * 100).rounded())) percent, target \(Int((t.targetWeight * 100).rounded())) percent")
    }

    // MARK: Allocation breakdown

    private var allocationPanel: some View {
        // Convert to USD before the breakdown (mirrors portfolioTotals/rebalance) — summing currencies
        // at 1:1 skews the asset-class / region slice percentages. Untracked-FX holdings are excluded.
        let allocFX = fxRatesToUSD
        // Exclude unpriced holdings (no live quote) rather than falling back to cost basis —
        // a possibly years-old basis price distorts every slice percentage with no caveat.
        // These holdings are already named by unpricedHoldings at the headline total.
        let holdings = portfolio.positions.compactMap { p -> (symbol: String, value: Double)? in
            guard let price = currentPrice(p.symbol),
                  // Audit 2026-07-12 pass-2 (finding B): quote leg, not exposure leg (rate² fix, see rebalance).
                  let rate = allocFX[conversionCurrencyForSymbol(p.symbol)] else { return nil }
            return (symbol: p.symbol,
                    value: holdingValue(p.symbol, perShare: price, shares: p.shares) * rate)
        }
        let alloc = StockSageAllocation.breakdown(holdings)
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "chart.bar.doc.horizontal.fill").font(.system(size: mvFont16)).foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allocation").font(DS.Typography.titleM).foregroundStyle(.white)
                    Text("Where the money sits — by asset class, region and sector.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            allocationGroup("By asset class", alloc.byClass)
            allocationGroup("By region", alloc.byRegion)
            allocationGroup("By sector", StockSageAllocation.slices(holdings, by: StockSageSector.sector))
            if alloc.topClassConcentration > 0.6 {
                Text("⚠︎ \(Int(alloc.topClassConcentration * 100))% in one asset class — concentrated.")
                    .font(.caption2).foregroundStyle(DS.Palette.warningSoft)
            }

            // Currency exposure — only worth showing when there's an actual FX dimension.
            // Exclude unpriced holdings (no live quote) rather than falling back to cost basis;
            // a stale basis price would distort every currency-exposure slice with no caveat.
            let ccyHoldings = portfolio.positions.compactMap { pos -> (value: Double, currency: String)? in
                guard let price = currentPrice(pos.symbol) else { return nil }
                let raw = price * pos.shares
                // London .L is quoted in pence — normalize to pounds so GBP isn't inflated ~100×.
                // Audit 2026-07-12 pass-2 (finding A, HIGH): key on the QUOTE leg — an already-USD …USD=X
                // pair keys as "USD", gets subtracted from the FX-rate set below, and stays at rate 1,
                // matching the headline USD total (the exposure leg re-multiplied it by the rate → rate²).
                return (value: StockSageCurrency.majorUnitValue(symbol: pos.symbol, rawValue: raw),
                        currency: conversionCurrencyForSymbol(pos.symbol))
            }
            let fxRates: [String: Double] = Dictionary(uniqueKeysWithValues:
                Set(ccyHoldings.map(\.currency)).subtracting(["USD"]).compactMap { ccy -> (String, Double)? in
                    // Review fix 2026-07-16: was a private COPY of the rate resolution that missed
                    // the infraFX fallback (post-restriction a .SR holding showed "unpriced" here
                    // while the headline total priced it) — now the ONE shared resolver.
                    fxRateToUSD(ccy).map { (ccy, $0) }
                })
            // Show the FX section whenever there is real FX risk, not just when the book spans
            // multiple currencies: a 100%-GBP book has count == 1 but hasFXRisk is true and the
            // concentration warning MUST fire (hiding it is the worst case — maximal exposure).
            if let cb = StockSageCurrency.breakdown(holdings: ccyHoldings, ratesToBase: fxRates, base: "USD"),
               cb.hasFXRisk || cb.exposures.count > 1 || !cb.unpriced.isEmpty {
                Text("Currency exposure (base USD)").font(.system(size: mvFont10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(cb.exposures) { e in
                    HStack(spacing: DS.Space.sm) {
                        Text(e.currency).font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white).frame(width: 46, alignment: .leading)
                        Text(String(format: "%.0f%%", e.weight * 100)).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(e.baseValue.formatted(.number.precision(.fractionLength(0)))).font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(e.currency): \(Int((e.weight * 100).rounded())) percent of the priced book")
                }
                if let c = cb.concentration {
                    Text("⚠︎ \(Int(c.weight * 100))% in \(c.currency) — FX risk (currency moves swing your USD value).")
                        .font(.caption2).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                }
                if !cb.unpriced.isEmpty {
                    Text("Unpriced (track \(cb.unpriced.first ?? "")USD=X to convert): \(cb.unpriced.joined(separator: ", ")) — excluded from the split.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Local prices assumed in each market's currency (London .L in pence may distort). Rates are snapshots; FX moves are real, un-modeled risk.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    private func allocationGroup(_ title: String, _ slices: [AllocationBreakdown.Slice]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: mvFont10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(slices) { s in
                HStack(spacing: DS.Space.sm) {
                    Text(s.label).font(.system(size: mvFont11)).foregroundStyle(.white)
                        .frame(width: 92, alignment: .leading).lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                            Capsule().fill(DS.Palette.accent)
                                .frame(width: max(4, geo.size.width * s.fraction), height: 6)
                        }
                    }
                    .frame(height: 6)
                    Text(String(format: "%.0f%%", s.fraction * 100))
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(s.label) \(Int((s.fraction * 100).rounded())) percent")
            }
        }
    }

    // MARK: Correlation heatmap

    @ViewBuilder private var correlationHeatmapPanel: some View {
        if let c = store.correlation, c.symbols.count >= 2 {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "square.grid.3x3.fill").font(.system(size: mvFont16)).foregroundStyle(DS.Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Correlation heatmap").font(DS.Typography.titleM).foregroundStyle(.white)
                            .help(StockSageGlossary.heatmapHelp)
                        Text("Green = independent · red = moves together (concentration risk).")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(c.symbols.indices, id: \.self) { i in
                            HStack(spacing: 2) {
                                Text(String(c.symbols[i].prefix(6)))
                                    .font(.system(size: mvFont8, weight: .semibold)).foregroundStyle(.secondary)
                                    .frame(width: 46, alignment: .leading).lineLimit(1)
                                ForEach(c.symbols.indices, id: \.self) { j in
                                    let v = c.matrix[i][j]
                                    // F3 (audit 2026-07-12): an undefined pair (zero-variance series)
                                    // holds a display-only 0 — render it as a neutral "—", never a
                                    // green "0.0 independent" cell that fabricates a diversification claim.
                                    let defined = c.isDefined(i, j)
                                    Rectangle().fill(defined ? correlationColor(v) : DS.Palette.surfaceAlt)
                                        .frame(width: 26, height: 18)
                                        .overlay(Text(defined ? String(format: "%.1f", v) : "—")
                                            .font(.system(size: mvFont7, weight: .bold)).foregroundStyle(.white.opacity(defined ? 0.92 : 0.5)))
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel(defined
                                            ? "\(c.symbols[i]) vs \(c.symbols[j]), correlation \(String(format: "%.1f", v))"
                                            : "\(c.symbols[i]) vs \(c.symbols[j]), correlation undefined — one series has no price variation over the window")
                                }
                            }
                        }
                    }
                }
                if let cluster = StockSageCorrelationCluster.largest(c) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "link").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.danger)
                        Text(cluster.note).font(.caption2).foregroundStyle(DS.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // F5 (audit 2026-07-12): disclose the thin-sample floor + the "—" undefined cell.
                Text("Pairwise daily-return correlation over the overlapping window — lower (greener) off-diagonal = better diversified. Computed on as few as ~5 overlapping days for a freshly-added name, so a few-point cell is a weak estimate, not a settled relationship; a “—” cell is undefined (a series with no price variation).")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(DS.Bezel.cardFill)
                    .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
            )
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
            // .contain (not .combine) so the per-cell correlation labels above survive as children.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Correlation heatmap, \(c.symbols.count) symbols")
        }
    }

    /// ≤0 (green, independent/hedged) → +1 (red, moves together / concentration).
    /// A correlation of ~0 IS the diversified case, so it must read green, not red.
    private func correlationColor(_ v: Double) -> Color {
        if v > 0 { return DS.Palette.danger.opacity(0.22 + min(v, 1) * 0.55) }
        return DS.Palette.successSoft.opacity(0.22 + min(-v, 1) * 0.55)
    }

    // MARK: Trade journal

    /// Forward scoreboard — the engine's paper track marked HONESTLY (bias-corrected bracket), and
    /// the contrast against the owner's own journal. Display-only; reads published state, changes
    /// nothing in scoring/sizing. The whole point is to show the CORRECT number: the closed-only read
    /// is selection-biased (fast stop-outs resolve first), so both bounds + the caveat are shown.
    private func rTxt(_ r: Double) -> String { String(format: "%+.2fR", r) }

    private var forwardScoreboardPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: mvFont16)).foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forward scoreboard").font(DS.Typography.titleM).foregroundStyle(.white)
                    Text("The engine's paper track, marked forward — vs the trades you actually take.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if let sb = paperStore.scoreboard {
                // Two bounds that BRACKET the truth. Closed-only over-represents fast losers; the
                // full-book mark leans optimistic (open winners can reverse). Neither is an edge claim.
                HStack(spacing: 1) {
                    scoreCell(title: "Closed only", value: sb.realizedN > 0 ? rTxt(sb.realizedAvgR) : "—",
                              sub: "\(sb.realizedN) resolved", tint: sb.realizedAvgR < 0 ? DS.Palette.danger : .white)
                    scoreCell(title: "Full book", value: rTxt(sb.fullAvgR),
                              sub: "\(sb.fullN) marked", tint: sb.fullAvgR < 0 ? DS.Palette.danger : DS.Palette.successSoft)
                    scoreCell(title: "Resolved", value: String(format: "%.0f%%", sb.resolvedFrac * 100),
                              sub: "\(sb.openMarked) open", tint: .white)
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                Text("The truth sits between the two. Only \(String(format: "%.0f%%", sb.resolvedFrac * 100)) has closed, and stops resolve before targets, so “closed only” over-states the loss; the full-book mark counts open positions at their current price (unrealized — they can still reverse). Both are typically ≈0 — the engine's value is risk-discipline, not a proven edge.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if paperStore.trades.isEmpty {
                Text("No paper trades yet — the engine opens one per long idea on each scan.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                // Live-book disclosure (owner asked to "try it with fake money",
                // 2026-07-16): before anything closes or a scan marks the book this
                // session, the experiment is ALREADY running — the old bare "run a
                // scan" empty state read as "nothing is happening" over a live book.
                // Review fix (2026-07-16): the since-date is min over ALL trades, so
                // attribute it to the EXPERIMENT, not the open positions — a closed
                // trade can own the earliest openedAt, and openCount can be 0.
                let openCount = paperStore.open.count
                let closedCount = paperStore.closed.count
                let since = paperStore.trades.map(\.openedAt).min()
                    .map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
                VStack(alignment: .leading, spacing: 3) {
                    Text("Paper experiment live since \(since): \(openCount) fake-money position\(openCount == 1 ? "" : "s") open · \(closedCount) closed.")
                        .font(.caption).foregroundStyle(.white)
                    Text("Closes land when a later scan's new daily bars cross a stop/target/time-stop — run a scan to mark the book and fill this scoreboard in. Fills are net-of-cost; paper never mixes into your real journal or win-rate calibration.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }

            // The contrast: engine vs the owner's own realized trades.
            let ownEdge = journal.edgeStats
            if ownEdge.closedWithR > 0 {
                Text("Your own realized track: \(rTxt(ownEdge.expectancyR)) over \(ownEdge.closedWithR) closed — \(paperStore.scoreboard.map { ownEdge.expectancyR > $0.realizedAvgR ? "ahead of the engine so far" : "behind the engine so far" } ?? "logged"). Both small; read at ~100 each.")
                    .font(.caption2).foregroundStyle(DS.Palette.accent).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Your own journal is empty — log the trades you actually take (below) to measure YOUR edge against the engine's track. That's the one experiment no dataset can run for you.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Text(StockSagePaperTrader.caveat)
                .font(.system(size: mvFont10)).foregroundStyle(.secondary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    private func scoreCell(title: String, value: String, sub: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: mvFont10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.5)
            Text(value).font(.system(size: mvFont16, weight: .bold, design: .rounded)).foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(sub).font(.system(size: mvFont10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(DS.Palette.surfaceAlt)
    }

    private var tradeJournalPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "book.closed.fill").font(.system(size: mvFont16)).foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trade journal").font(DS.Typography.titleM).foregroundStyle(.white)
                        .help(StockSageGlossary.journalHelp)
                    Text("Log the trades you actually take, then close them to build your realized track record.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !journal.trades.isEmpty {
                    Button {
                        let csv = StockSageJournalCSV.csv(journal.trades)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(csv, forType: .string)
                    } label: {
                        Text("Copy CSV").font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy the whole journal as CSV (Excel / Sheets / Python-ready)")
                }
                // Extension batch (2026-07-16): import/backup — every action reports an honest
                // one-line result (added/skipped/error counts) via journalDataFeedback.
                Menu {
                    Button("Import CSV…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
                        panel.allowsMultipleSelection = false
                        guard panel.runModal() == .OK, let url = panel.url,
                              let csv = try? String(contentsOf: url, encoding: .utf8) else { return }
                        let preview = StockSageJournalCSVImport.preview(csv, existing: journal.trades)
                        for t in preview.trades { journal.add(t) }
                        journalDataFeedback = "Imported \(preview.imported) trade\(preview.imported == 1 ? "" : "s")"
                            + (preview.skipped > 0 ? ", skipped \(preview.skipped) duplicate\(preview.skipped == 1 ? "" : "s")" : "")
                            + (preview.errors.isEmpty ? "." : "; \(preview.errors.count) row\(preview.errors.count == 1 ? "" : "s") failed (first: line \(preview.errors[0].line) — \(preview.errors[0].reason)).")
                    }
                    Divider()
                    Button("Export backup…") {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.json]
                        panel.nameFieldStringValue = "stocksage-backup.json"
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        let data = StockSageBackup.export(trades: journal.trades,
                                                          positions: portfolio.positions,
                                                          userSymbols: store.userSymbols)
                        do { try data.write(to: url); journalDataFeedback = "Backup saved (journal, portfolio, watchlist)." }
                        catch { journalDataFeedback = "Backup failed: \(error.localizedDescription)" }
                    }
                    Button("Restore backup…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.json]
                        panel.allowsMultipleSelection = false
                        guard panel.runModal() == .OK, let url = panel.url,
                              let data = try? Data(contentsOf: url) else { return }
                        switch StockSageBackup.restore(from: data) {
                        case .success(let payload):
                            let existing = Set(journal.trades.map(\.id))
                            var added = 0
                            for t in payload.trades where !existing.contains(t.id) { journal.add(t); added += 1 }
                            journalDataFeedback = "Restored \(added) trade\(added == 1 ? "" : "s")"
                                + (payload.trades.count > added ? " (\(payload.trades.count - added) already present)" : "")
                                + "; \(payload.positions.count) portfolio position(s) in file — add via Portfolio."
                        case .failure(let err):
                            journalDataFeedback = "Restore failed: \(err.localizedDescription)"
                        }
                    }
                    Divider()
                    Button("Import from Salehman AI…") {
                        if let parent = StockSageBackup.importFromParentApp() {
                            let existing = Set(journal.trades.map(\.id))
                            var added = 0
                            for t in parent.trades where !existing.contains(t.id) { journal.add(t); added += 1 }
                            journalDataFeedback = "Imported \(added) trade\(added == 1 ? "" : "s") from Salehman AI"
                                + (parent.trades.count > added ? " (\(parent.trades.count - added) already present)" : "") + "."
                        } else {
                            journalDataFeedback = "No Salehman AI data found on this Mac."
                        }
                    }
                } label: {
                    Text("Data").font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Import a broker/journal CSV, back up or restore ALL app data (JSON), or import your journal from the Salehman AI app")
                Button { withAnimation(.easeOut(duration: 0.15)) { showAddTrade.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showAddTrade ? "xmark" : "plus").font(.system(size: mvFont10, weight: .bold))
                        Text(showAddTrade ? "Close" : "Log trade").font(.system(size: mvFont11, weight: .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 6)
                    .background(DS.Palette.accent, in: Capsule())
                }.buttonStyle(LuxPressStyle())
            }

            if let journalDataFeedback {
                Text(journalDataFeedback).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            lossLimitBanner   // STOP-TRADING / approaching-limit circuit breaker (above system-health)

            if let health = journal.systemHealth {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: healthIcon(health.verdict)).font(.system(size: mvFont11)).foregroundStyle(healthColor(health.verdict))
                    Text(health.verdict.rawValue).font(.system(size: mvFont11, weight: .bold)).foregroundStyle(healthColor(health.verdict))
                    Text(health.reason).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if showAddTrade { addTradeForm }

            // Realized stats (closed trades only).
            let s = journal.stats
            if s.closed > 0 {
                HStack(spacing: DS.Space.sm) {
                    ideaMetric("Closed", "\(s.closed)")
                    ideaMetric("Win", String(format: "%.0f%%", s.winRate * 100),
                               color: s.winRate >= 0.5 ? DS.Palette.successSoft : DS.Palette.danger)
                    ideaMetric("Total R", String(format: "%+.2f", s.totalR),
                               color: s.totalR >= 0 ? DS.Palette.successSoft : DS.Palette.danger)
                    ideaMetric("Avg R", String(format: "%+.2f", s.avgR),
                               color: s.avgR >= 0 ? DS.Palette.successSoft : DS.Palette.danger)
                    // First-real-trade review (2026-07-16): totalProfit sums each trade's profit
                    // in its NATIVE currency, so a mixed-currency closed book (SAR + USD) is a
                    // meaningless 1:1 sum — never show it as one number. profitCurrency is the
                    // single ISO code when the book is one currency (USD → byte-identical bare;
                    // else labeled), nil when mixed (show "mixed", route to the per-row P&L).
                    ideaMetric("Realized P&L", realizedProfitText(s),
                               color: s.profitSymbol == nil ? DS.Palette.warningSoft
                                    : (s.totalProfit >= 0 ? DS.Palette.successSoft : DS.Palette.danger))
                        .help(s.profitSymbol == nil
                            ? "Closed trades span multiple currencies — a single total can't be summed honestly; see each trade's own P&L below."
                            : "Closed trades only — a record, not a promise of future results.")
                    Spacer(minLength: 0)
                }
                let edge = journal.edgeStats
                if edge.closedWithR > 0 {
                    HStack(spacing: DS.Space.sm) {
                        ideaMetric("Expectancy", String(format: "%+.2fR", edge.expectancyR),
                                   color: edge.expectancyR >= 0 ? DS.Palette.successSoft : DS.Palette.danger)
                        ideaMetric("Avg win", String(format: "+%.2fR", edge.avgWinR), color: DS.Palette.successSoft)
                        ideaMetric("Avg loss", String(format: "−%.2fR", edge.avgLossR), color: DS.Palette.danger)
                        ideaMetric("Payoff", edge.payoffRatio > 0 ? String(format: "%.2f", edge.payoffRatio) : "—")
                        ideaMetric("PF", edge.profitFactor.map { String(format: "%.2f", $0) } ?? "—",
                                   // nil means no losing trades — the engine treats this as pfStrong (∞).
                                   // ?? 0 was turning nil into 0 and falsely painting "—" danger red.
                                   color: edge.profitFactor.map { $0 >= 1 } ?? true ? DS.Palette.successSoft : DS.Palette.danger)
                        Spacer(minLength: 0)
                    }
                    if let pf = edge.profitFactor {
                        Text(String(format: "Profit factor %.2f — for every 1R you lost, you won %.2fR (>1 = net positive). R-based; a record, not a promise.", pf, pf))
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Expectancy = R you make per trade on average. Positive = the system has paid you so far; it's a record, not a promise.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    let excludedNoR = journal.closed.count - edge.closedWithR
                    if excludedNoR > 0 {
                        Text("\(excludedNoR) closed trade\(excludedNoR == 1 ? "" : "s") excluded from the edge — logged with entry == stop, so R is undefined (no risk to measure against).")
                            .font(.caption2).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                    }
                    if let ci = journal.expectancyCI {
                        Text(ci.note).font(.caption2)
                            .foregroundStyle(ci.isSignificant ? DS.Palette.successSoft : DS.Palette.warningSoft)
                            .fixedSize(horizontal: false, vertical: true)
                        if let sig = journal.tradesToSignificance, sig.more > 0 {
                            Text("≈ \(sig.more) more trades to confirm the edge at 2σ (95%).")
                                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let trend = journal.expectancyTrend {
                            Text(String(format: "Recent %+.2fR vs early %+.2fR — %@.", trend.recentR, trend.earlyR, trend.direction.rawValue))
                                .font(.caption2)
                                .foregroundStyle(trend.direction == .improving ? DS.Palette.successSoft
                                                 : (trend.direction == .fading ? DS.Palette.danger : .secondary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let streak = journal.streakSummary {
                    let run = streak.streakCount == 0 ? "—"
                        : "\(streak.streakCount) \(streak.streakIsWin ? "win" : "loss")\(streak.streakCount == 1 ? "" : (streak.streakIsWin ? "s" : "es"))"
                    Text(String(format: "Best %+.2fR (%@) · worst %+.2fR (%@) · current run: %@",
                                streak.bestR, streak.bestSymbol, streak.worstR, streak.worstSymbol, run))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let hp = journal.holdingPeriod {
                    Text(hp.note).font(.caption2)
                        .foregroundStyle(hp.ridingLosers ? DS.Palette.warningSoft : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let risk = journal.equityRisk {
                    Text(String(format: "Worst losing run: %d · max drawdown −%.2fR (your realized path so far).",
                                risk.maxConsecutiveLosses, risk.maxDrawdownR))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    // The user's REAL per-trade risk (same as the MonteCarlo line below) — NOT a
                    // hardcoded 1%, so this survival number reflects how they actually size. A user at
                    // 2–3%/trade was shown a drawdown understated ~2–3× with text falsely claiming "1%".
                    // F04: nil (unparseable risk %) must suppress both estimates, never silently
                    // fall back to a fabricated 1% — that produced a false "survivable" verdict.
                    if let riskFrac = parsedRiskFraction {
                        if let dd = StockSageRiskOfRuin.scenario(losses: risk.maxConsecutiveLosses, fraction: riskFrac) {
                            Text(String(format: "Stay in the game: %d 1R stops in a row at %g%%/trade ≈ −%.1f%% to the account — %@",
                                        dd.losses, riskFrac * 100, dd.drawdownPct * 100,
                                        dd.isSteep ? "size down; surviving variance is how velocity compounds."
                                                   : "survivable — staying in the game is what lets velocity pay off."))
                                .font(.caption2)
                                .foregroundStyle(dd.isSteep ? DS.Palette.warningSoft : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(StockSageGlossary.explain(.drawdownSurvival))
                        }
                        // Forward-looking ruin DISTRIBUTION — bootstraps YOUR realized R into many
                        // simulated futures at your configured risk %, the complement to the single
                        // historical path above. nil under 20 R-defined trades (the engine self-gates).
                        if let mc = StockSageMonteCarloRuin.simulate(journal.trades, riskFraction: riskFrac) {
                            Text(String(format: "Forward ruin risk (%d sims @ %g%%/trade): P(ruin) %.1f%% · P(>20%% drawdown) %.0f%% · max drawdown ~%.0f%% typical, %.0f%% 95th-pct — bootstrapped from your %d closed trades.",
                                        mc.sims, riskFrac * 100, mc.pRuin * 100, mc.p20DrawdownProb * 100,
                                        mc.medianMaxDD * 100, mc.p95MaxDD * 100, mc.sampleSize))
                                .font(.caption2)
                                .foregroundStyle(mc.pRuin > 0.05 ? DS.Palette.warningSoft : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(StockSageMonteCarloRuin.caveat)
                                // A11Y_BUGHUNT #6: VoiceOver read the literal format string — at
                                // spoken as at-sign, middle dots dropped, P(ruin) as bare letters
                                // with lost parens. Same figures, speech-safe phrasing; the
                                // engine caveat moves to the hint (hover .help kept for sighted).
                                .accessibilityLabel(String(format: "Forward ruin risk from %d simulations at %g percent risk per trade. Probability of ruin %.1f percent. Probability of a drawdown over 20 percent, %.0f percent. Typical maximum drawdown %.0f percent, 95th percentile %.0f percent. Bootstrapped from your %d closed trades.",
                                        mc.sims, riskFrac * 100, mc.pRuin * 100, mc.p20DrawdownProb * 100,
                                        mc.medianMaxDD * 100, mc.p95MaxDD * 100, mc.sampleSize))
                                .accessibilityHint(StockSageMonteCarloRuin.caveat)
                        }
                    } else {
                        Text("Enter risk % to estimate drawdown survival.")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let comp = journal.compounding, comp.multiples.count >= 2 {
                    let up = comp.finalMultiple >= 1
                    VStack(alignment: .leading, spacing: 3) {
                        Text(comp.isRuined
                             ? String(format: "Wiped out at %.0f%%/trade — the account hit ruin on this or an earlier trade.", comp.fraction * 100)
                             : String(format: "Compounded to ×%.2f at %.0f%%/trade", comp.finalMultiple, comp.fraction * 100))
                            .font(.system(size: mvFont11, weight: .semibold))
                            .foregroundStyle(up ? DS.Palette.successSoft : DS.Palette.danger)
                        Sparkline(values: comp.multiples)
                            .stroke(up ? DS.Palette.successSoft : DS.Palette.danger,
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .frame(height: 26).opacity(0.9)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(comp.isRuined
                                ? "Compounding curve, wiped out"
                                : String(format: "Compounding curve, currently ×%.2f", comp.finalMultiple))
                        Text("Your OWN logged R compounded at a fixed risk % — the past path of your trades, NOT a projection of future returns.")
                            .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .help(StockSageGlossary.explain(.compounding))
                }
                if journal.closed.count >= 20,
                   let proj = StockSageJournal.projectGrowth(expectancyR: journal.edgeStats.expectancyR, trades: 100, fraction: 0.01) {
                    Text(String(format: "What-if (HYPOTHETICAL): at your measured %+.2fR/trade & 1%%/trade, 100 trades ≈ ×%.2f. %@",
                                proj.expectancyR, proj.multiple, MoneyVelocityCopy.growthProjection))
                        .font(.caption2)
                        .foregroundStyle(.secondary)   // neutral: a hypothetical projection, not a warning or a promise
                        .fixedSize(horizontal: false, vertical: true)
                        .help("A deterministic compounding of your measured average R — it ignores variance and drawdown, which make the real path lower and bumpier. Not advice, not a forecast.")
                }
                if let dist = journal.rDistribution, dist.total >= 3 {
                    let maxC = max(dist.bins.map(\.count).max() ?? 1, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("R-multiple distribution").font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white)
                        HStack(alignment: .bottom, spacing: DS.Space.sm) {
                            ForEach(dist.bins.indices, id: \.self) { i in
                                let bin = dist.bins[i]
                                VStack(spacing: 2) {
                                    Text("\(bin.count)").font(.system(size: mvFont8)).foregroundStyle(.secondary)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(i < 2 ? DS.Palette.danger : DS.Palette.successSoft)
                                        .frame(width: 26, height: max(2, CGFloat(bin.count) / CGFloat(maxC) * 26))
                                    Text(bin.label).font(.system(size: mvFont7)).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(bin.label): \(bin.count) trades")
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                let months = journal.monthlyPnL
                if months.count >= 2 {
                    Text("By month").font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white)
                    ForEach(months.prefix(6)) { mo in
                        HStack(spacing: DS.Space.sm) {
                            Text(mo.month).font(.system(size: mvFont11)).foregroundStyle(.white).frame(width: 72, alignment: .leading)
                            Text("\(mo.trades) tr").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%+.2fR", mo.totalR)).font(.system(size: mvFont11, weight: .semibold))
                                .foregroundStyle(mo.totalR >= 0 ? DS.Palette.successSoft : DS.Palette.danger)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(minWidth: 60, alignment: .trailing)
                        }
                    }
                }
                // Extension batch (2026-07-16): measured execution costs (planned vs fill) —
                // the one dataset no research can replace (the owner's own fills). The panel
                // self-gates below the engine's 5-leg floor; it never shows a thin-sample stat.
                ExecutionQualityPanel(trades: journal.trades)
                let years = journal.yearlyPnL
                if !years.isEmpty {
                    Text("By year (realized — record-keeping, not tax advice)")
                        .font(.system(size: mvFont10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(years) { yr in
                        HStack(spacing: DS.Space.sm) {
                            Text(yr.year).font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white).frame(width: 48, alignment: .leading)
                            Text("\(yr.trades) tr · \(Int(yr.winRate * 100))% win").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            // First-real-trade review (2026-07-16): realizedDollars sums native
                            // currency, so a year mixing .SR + NASDAQ is a meaningless 1:1 sum —
                            // show "mixed" (never a fabricated number); single-currency renders
                            // via signedAmount (USD byte-identical, pence ÷100, else labeled).
                            Text(yr.profitSymbol.map { StockSageCurrency.signedAmount(yr.realizedDollars, symbol: $0) } ?? "mixed")
                                .font(.system(size: mvFont11, weight: .semibold))
                                .foregroundStyle(yr.profitSymbol == nil ? DS.Palette.warningSoft
                                     : (yr.realizedDollars >= 0 ? DS.Palette.successSoft : DS.Palette.danger))
                                .help(yr.profitSymbol == nil ? "This year's trades span multiple currencies — a single total can't be summed honestly." : "")
                            // width (NOT minWidth), unlike the month/side/sector R columns below: this
                            // is the only journal row where another figure (realizedDollars, just
                            // above, no frame of its own) precedes the trailing R text in the same
                            // HStack — minimumScaleFactor already prevents truncation at 56pt, but a
                            // GROWING frame would push realizedDollars left as the R string widens,
                            // breaking its constant-x alignment across year rows. The fixed width is
                            // what keeps the dollars column aligned, not the scale factor.
                            Text(String(format: "%+.1fR", yr.totalR)).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                }
                let sides = journal.sideStats
                if sides.count == 2 {
                    Text("By side").font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white)
                    ForEach(sides) { s in
                        let rel = StockSageJournal.reliability(s)
                        HStack(spacing: DS.Space.sm) {
                            Text(s.side.rawValue).font(.system(size: mvFont11)).foregroundStyle(.white).frame(width: 60, alignment: .leading)
                            Text(rel.isReliable
                                 ? "\(s.trades) tr · \(Int(s.winRate * 100))% win · \(String(format: "%+.2f", s.avgR))R avg"
                                 : "\(s.trades) tr · \(rel.tooFewLabel)")
                                .font(.caption2).foregroundStyle(rel.isReliable ? Color.secondary : DS.Palette.warningSoft)
                            Spacer()
                            Text(String(format: "%+.2fR", s.totalR)).font(.system(size: mvFont11, weight: .semibold))
                                .foregroundStyle(s.totalR >= 0 ? DS.Palette.successSoft : DS.Palette.danger)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(minWidth: 60, alignment: .trailing)
                        }
                    }
                }
                let sectors = journal.sectorPnL
                if sectors.count >= 2 {
                    Text("By sector").font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white)
                    ForEach(sectors) { sec in
                        let rel = StockSageJournal.reliability(sec)
                        HStack(spacing: DS.Space.sm) {
                            Text(sec.sector).font(.system(size: mvFont11)).foregroundStyle(.white)
                                .frame(width: 96, alignment: .leading).lineLimit(1)
                            Text(rel.isReliable ? "\(sec.trades) tr · \(Int(sec.winRate * 100))% win"
                                                : "\(sec.trades) tr · \(rel.tooFewLabel)")
                                .font(.caption2).foregroundStyle(rel.isReliable ? Color.secondary : DS.Palette.warningSoft)
                            Spacer()
                            Text(String(format: "%+.2fR", sec.totalR)).font(.system(size: mvFont11, weight: .semibold))
                                .foregroundStyle(sec.totalR >= 0 ? DS.Palette.successSoft : DS.Palette.danger)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(minWidth: 60, alignment: .trailing)
                        }
                    }
                }
                if sides.count == 2 || sectors.count >= 2 {
                    Text(StockSageJournal.attributionCaveat)
                        .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if journal.trades.isEmpty {
                Text("No trades logged yet. \"Log trade\" records a decision you made — the journal tracks it, it doesn't endorse it.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                if !journal.open.isEmpty {
                    // Portfolio heat: total open $-at-risk vs account — the exposure ten
                    // "1% risk" trades hide (they're 10% together).
                    // Entry and stop must pass through majorUnitValue (÷100 for .L/.JO pence
                    // quotes) and FX-convert to USD before the $-at-risk comparison against the
                    // account. Trades whose currency has no tracked rate are excluded (mirroring
                    // untrackedFXCurrencies) rather than summed 1:1 against the USD account.
                    if let acct = StockSageInput.positiveAmount(sizerAccount),
                       let heat = StockSagePortfolioHeat.compute(
                            openTrades: journal.open.compactMap { t -> (shares: Double, entry: Double, stop: Double)? in
                                // Audit 2026-07-12 pass-2 (4th site, found by grepping every caller — NOT in
                                // the audit's 3): key on the QUOTE leg — a …USD=X trade's entry/stop are already
                                // USD, so the exposure leg would re-multiply by the rate (rate²), inflating open
                                // heat and skewing the risk gate that feeds sizing. Same root cause as A/B/C.
                                let ccy = conversionCurrencyForSymbol(t.symbol)
                                // Review fix 2026-07-16 (DANGEROUS direction): this was a private
                                // COPY of the rate resolution missing the infraFX fallback — post-
                                // restriction an open .SR trade was silently EXCLUDED from heat
                                // (the gauge read cooler than the real book). Now the ONE resolver.
                                guard let rate = fxRateToUSD(ccy) else { return nil }   // no rate — exclude, never 1:1
                                let e = StockSageCurrency.majorUnitValue(symbol: t.symbol, rawValue: t.entry) * rate
                                let s = StockSageCurrency.majorUnitValue(symbol: t.symbol, rawValue: t.stop) * rate
                                return (shares: t.shares, entry: e, stop: s)
                            },
                            accountSize: acct) {
                        let hc: Color = heat.level == .hot ? DS.Palette.danger
                            : (heat.level == .warm ? DS.Palette.warningSoft : DS.Palette.successSoft)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "flame.fill").font(.system(size: mvFont11)).foregroundStyle(hc)
                                Text("Portfolio heat — \(heat.verdict)")
                                    .font(.system(size: mvFont9, weight: .medium)).foregroundStyle(hc)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(heat.caveat).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Portfolio heat: \(Int(heat.heatPct * 100)) percent of account at open risk across \(heat.openCount) trades")
                    }
                    Text("Open").font(.system(size: mvFont10, weight: .semibold)).foregroundStyle(.secondary)
                    // Live "act now": OPEN trades that have crossed their stop or target need action
                    // while the owner is away — the only surface that acts on a position in real time.
                    let urgentActs = StockSageJournal.openActions(journal.open, mark: { currentPrice($0) })
                        .filter(\.isUrgent)
                    ForEach(urgentActs) { act in
                        Text("⚠︎ \(act.symbol) — \(act.kind.rawValue): \(act.detail)")
                            .font(.system(size: mvFont9, weight: .semibold))
                            .foregroundStyle(act.kind == .stopHit ? DS.Palette.danger : DS.Palette.successSoft)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("\(act.symbol) \(act.kind.rawValue). \(act.detail)")
                    }
                    ForEach(journal.open) { journalOpenRow($0) }
                }
                if !journal.closed.isEmpty {
                    Text("Closed").font(.system(size: mvFont10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(journal.closed) { journalClosedRow($0) }
                }
            }

            measuredSlippageLine
            Text(StockSageJournal.caveat).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    /// Realized-vs-assumed execution cost summary — measurement/display only (see the fence on
    /// StockSageJournal.measuredSlippage). Plain caption2 text, no color-coded verdict.
    private var measuredSlippageLine: some View {
        let slip = StockSageJournal.measuredSlippage(journal.trades)
        let text: String
        if let slip, slip.meetsFloor {
            text = String(format: "Measured slippage: median %+.1f bps/leg over %d legs (your fills) — assumed: %.1f bps/leg (half the asset-class round-trip table).",
                          slip.medianBps, slip.legs, slip.assumedMedianBpsPerLeg)
        } else {
            let n = slip?.legs ?? 0
            text = "Not enough fill data — enter fill prices to measure your real costs (\(n) of 5 legs)."
        }
        return Text(text).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func healthColor(_ v: SystemHealth.Verdict) -> Color {
        switch v {
        case .strong: return DS.Palette.successSoft
        case .developing: return DS.Palette.accent
        case .unproven: return DS.Palette.textSecondary
        case .negative: return DS.Palette.danger
        }
    }
    private func healthIcon(_ v: SystemHealth.Verdict) -> String {
        switch v {
        case .strong: return "checkmark.seal.fill"
        case .developing: return "chart.line.uptrend.xyaxis"
        case .unproven: return "questionmark.circle"
        case .negative: return "exclamationmark.triangle.fill"
        }
    }

    /// Shared tooltip for the two weekly-R display sites: the existing F03/F44 gross label + the
    /// Item-A turnover disclosure (assumed re-cycles) + the coded refuse-list policy line.
    /// LABEL-ONLY — the weekly number itself stays GROSS (netting is owner-gated F03/F44).
    /// `tradingDays`: reuses an already-computed `tradingDaysForLane(...)` value when the caller
    /// has one (both call sites do — this is just the `tradingDays:` MULTIPLIER argument
    /// `weeklyTurnoverNote` already accepted as a parameter, not a lane re-derivation; its OWN
    /// internal `assumedWeeklyRoundTrips` still computes its own non-earnings/liquidity-aware
    /// fastLane pass, deliberately left untouched — that pass is `.prefix`-order-sensitive and
    /// NOT provably identical to the caller's earnings/liquidity-aware `lane`, so deduping it
    /// would risk a silently wrong turnover count; nil defaults to the pre-existing derivation
    /// so no call site is required to change).
    /// `netFigure: true` (F03/F44 review fix, 2026-07-09): the turnover note's tail calls the
    /// annotated number "this gross figure" — TRUE for the gross fallback, FALSE for the net
    /// headline (which already charges frictions per re-cycle). The net branch swaps that tail
    /// for the net-true phrasing instead of inheriting a mislabel onto the card's money number.
    /// C1 wave (2026-07-09): the owner's TOM KEEP ratification is premised on "UI-disclosED" —
    /// and `bestOpportunity` carries the seasonal tilt on EVERY sort and tab, while the ideas-
    /// board disclosure line correctly renders only under the EV sort (the tilt is not in
    /// rankByVelocity). Every bestOpportunity-CROWNED surface therefore appends this to its own
    /// caveat whenever the tilt can actually be moving the crown. Empty when inert.
    private var tomTiltDisclosureSuffix: String {
        // Centralized in MoneyVelocityCopy (in-turn 2026-07-09) so the Today tile's copy of
        // this disclosure cannot drift from the Markets surfaces'.
        MoneyVelocityCopy.tomTiltSuffix(seasonalityPopulated: !store.seasonality.isEmpty)
    }

    private func weeklyGrossHelp(_ base: String, tradingDays: Double? = nil, netFigure: Bool = false) -> String {
        var s = base
        let days = tradingDays ?? StockSageExpectedValue.tradingDaysForLane(store.ideas, holds: velocityHolds, calibration: store.convictionCalibration)
        if var note = StockSageExpectedValue.weeklyTurnoverNote(
            store.ideas, tradingDays: days, holds: velocityHolds, calibration: store.convictionCalibration) {
            if netFigure {
                note = note.replacingOccurrences(
                    of: "every re-entry pays the est. round-trip costs this gross figure excludes",
                    with: "every re-entry pays the est. round-trip costs — already charged in this net figure")
            }
            s += "\n\n" + note
        }
        s += "\n\n" + StockSageRefuseList.policyNote
        return s
    }

    // The loss-limit circuit breaker, surfaced. R-based + loss-streak policy (no account needed):
    // halts after 3 daily / 6 weekly R lost or a 3-loss streak. A behavioral brake, not advice.
    @ViewBuilder private var lossLimitBanner: some View {
        let state = StockSageLossLimit.evaluate(
            closedTrades: journal.trades,
            policy: LossLimitPolicy(maxDailyLossR: 3, maxWeeklyLossR: 6, standDownLossRun: 3),
            now: Date())
        switch state.status {
        case .ok:
            EmptyView()
        case .halted:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill").font(.system(size: mvFont13, weight: .bold)).foregroundStyle(.white)
                    Text("STOP TRADING").font(.system(size: mvFont12, weight: .heavy)).foregroundStyle(.white)
                    Spacer()
                }
                if let reason = state.haltReason {
                    Text(reason).font(.system(size: mvFont11, weight: .semibold))
                        .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                }
                Text(state.caveat).font(.system(size: mvFont9))
                    .foregroundStyle(.white.opacity(0.82)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.sm).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.danger.opacity(0.85), in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).stroke(DS.Palette.danger, lineWidth: 1.5))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Stop trading. \(state.haltReason ?? ""). \(state.caveat)")
        case .warn:
            // The warn trigger can come from either the daily-R gate OR the weekly-R gate (or
            // both). LossLimitState exposes dailyRealizedR but not weeklyRealizedR, so we cannot
            // reliably attribute the warning to one gate — show both readings so the copy is
            // honest regardless of which gate fired. Daily R is the precise engine value; weekly
            // loss is shown in dollars (the only weekly figure the state exposes) so the trader
            // can see the actual weekly exposure even when daily R is near-zero.
            // Signs come from the raw realized values, NOT a hardcoded "−": the warn can fire
            // from the daily-R gate while the week is net positive (or vice versa), so a fixed
            // minus would render "−-0.3R" / "−$-350". Negative = loss; the U+2212 glyph is kept.
            let dailyR    = state.dailyRealizedR
            let weeklyUsd = state.weeklyRealized      // dollars (negative = loss)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.warningSoft)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Approaching your loss limit \u{2014} ease off and size down.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "Today: %@%.1fR (daily limit 3R) \u{B7} This week: %@$%.0f (weekly limit varies by account).",
                                dailyR < 0 ? "\u{2212}" : "+", abs(dailyR), weeklyUsd < 0 ? "\u{2212}" : "+", abs(weeklyUsd)))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityLabel(String(format: "Approaching loss limit. %@ %.1fR today and %@ $%.0f this week. Ease off and size down.",
                                       dailyR < 0 ? "Down" : "Up", abs(dailyR), weeklyUsd < 0 ? "down" : "up", abs(weeklyUsd)))
        }
    }

    private var addTradeForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: DS.Space.sm) {
                journalField("Symbol", text: $draftSymbol, width: 90)
                DSSegmentPicker(cases: Array(TradeRecord.Side.allCases),
                                selection: $draftSide) { $0.rawValue }
                    .frame(width: 130)
                    .accessibilityLabel("Trade side")
                Spacer(minLength: 0)
            }
            HStack(spacing: DS.Space.sm) {
                journalField("Entry", text: $draftEntry)
                journalField("Stop", text: $draftStop)
                journalField("Target", text: $draftTarget)
                journalField("Shares", text: $draftShares)
            }
            HStack(spacing: DS.Space.sm) {
                journalField("Planned px (opt)", text: $draftPlannedEntry, width: 100)
                    .help("What the plan quoted when you decided to enter. Measures your real execution cost vs. the plan — never changes P&L.")
                journalField("Fill px (opt)", text: $draftEntryFill, width: 100)
                    .help("Your actual entry fill price. Measures your real execution cost vs. the plan — never changes P&L.")
                Spacer(minLength: 0)
            }
            journalField("Note (optional)", text: $draftNote, width: 280)
            // Cycle-4 (2026-07-16): the copy plan and detail sheet both show the reward:risk of a
            // setup, but the manual add form — where the owner types entry/stop/target — showed
            // none, so they journal a trade without seeing its R:R or break-even win-rate. Same
            // tested RewardRisk.assess/.note (labeled gross, carries the break-even honesty); nil
            // (no line) until entry+stop+target all parse. Display-only; never changes the record.
            if let e = StockSageInput.positiveAmount(draftEntry),
               let st = StockSageInput.positiveAmount(draftStop),
               let tg = StockSageInput.positiveAmount(draftTarget),
               let rr = StockSageRewardRisk.assess(entry: e, stop: st, target: tg) {
                Text(rr.note).font(.system(size: mvFont9))
                    .foregroundStyle(rr.quality == .poor ? DS.Palette.warningSoft : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Cycle-3 (2026-07-16): the copy-plan export and the close form both flag off-grid
            // .SR prices; the manual add form is the third entry point and had no such feedback —
            // a stop/target typed from the idea card can be off the Tadawul grid and unplaceable.
            // Same tested placeabilityNote (entry+stop+target); nil unless .SR + a leg off-grid.
            if let tickNote = StockSageTickSize.placeabilityNote(
                symbol: draftSymbol,
                entry: StockSageInput.positiveAmount(draftEntry),
                stop: StockSageInput.positiveAmount(draftStop),
                target: StockSageInput.positiveAmount(draftTarget)) {
                Text("⚠ " + tickNote).font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button { saveDraftTrade() } label: {
                    Text("Save").font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6).background(DS.Palette.accent, in: Capsule())
                }.buttonStyle(LuxPressStyle()).disabled(!draftIsValid)
                if !draftIsValid {
                    Text("Symbol, entry, stop, shares required — protective stop (below entry for Long, above for Short); optional target must be on the profit side.")
                        .font(.system(size: mvFont9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func journalField(_ placeholder: String, text: Binding<String>, width: CGFloat = 70) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: mvFont12))
            .padding(.horizontal, 8).padding(.vertical, 6).frame(width: width)
            .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    private var draftIsValid: Bool {
        // Parse via StockSageInput.positiveAmount: rejects non-finite (inf/"1e999"), negatives,
        // and zero — the same discipline used by addPositionForm and the close-exit confirm button.
        guard !draftSymbol.trimmingCharacters(in: .whitespaces).isEmpty,
              let e = StockSageInput.positiveAmount(draftEntry),
              let st = StockSageInput.positiveAmount(draftStop),
              StockSageInput.positiveAmount(draftShares) != nil,
              e != st,
              // Stop must be PROTECTIVE, else the recorded R is meaningless.
              (draftSide == .long ? st < e : st > e) else { return false }
        // Target (optional) must be on the PROFIT side — a long with target below entry yields a
        // false "TARGET HIT" alert on any price under entry (engine openActions isLong ? px >= tgt).
        if let tgt = StockSageInput.positiveAmount(draftTarget) {
            guard draftSide == .long ? tgt > e : tgt < e else { return false }
        }
        // Optional realized-cost fields: blank is fine (never fabricated), but a TYPED,
        // unparseable value blocks save rather than silently dropping to nil.
        let plannedEntryOK = draftPlannedEntry.trimmingCharacters(in: .whitespaces).isEmpty
            || StockSageInput.positiveAmount(draftPlannedEntry) != nil
        let entryFillOK = draftEntryFill.trimmingCharacters(in: .whitespaces).isEmpty
            || StockSageInput.positiveAmount(draftEntryFill) != nil
        guard plannedEntryOK, entryFillOK else { return false }
        return true
    }

    private func saveDraftTrade() {
        guard draftIsValid,
              let e = StockSageInput.positiveAmount(draftEntry),
              let st = StockSageInput.positiveAmount(draftStop),
              let sh = StockSageInput.positiveAmount(draftShares) else { return }
        let trimmedNote = draftNote.trimmingCharacters(in: .whitespaces)
        let trade = TradeRecord(symbol: draftSymbol.trimmingCharacters(in: .whitespaces).uppercased(),
                                side: draftSide, entry: e, stop: st, target: StockSageInput.positiveAmount(draftTarget),
                                shares: sh, openedAt: Date(),
                                note: trimmedNote.isEmpty ? nil : trimmedNote, conviction: draftConviction,
                                plannedEntry: StockSageInput.positiveAmount(draftPlannedEntry),
                                entryFill: StockSageInput.positiveAmount(draftEntryFill))
        journal.add(trade)
        draftSymbol = ""; draftEntry = ""; draftStop = ""; draftTarget = ""; draftShares = ""; draftNote = ""
        draftConviction = nil
        draftPlannedEntry = ""; draftEntryFill = ""
        draftSide = .long
        withAnimation(.easeOut(duration: 0.15)) { showAddTrade = false }
    }

    /// Prefill the journal's inline add form from an idea, dismiss the detail
    /// sheet, and jump to the Portfolio section where the form lives. Robust —
    /// the form is inline, so there's no sheet-over-sheet presentation race.
    /// Ideas worth logging as a trade — bullish (Buy/Strong Buy) or bearish
    /// (Sell/Reduce) entries. Hold/Avoid are "stand aside", not trades.
    private func isLoggableIdea(_ action: TradeAdvice.Action) -> Bool {
        switch action {
        case .strongBuy, .buy, .sell, .reduce: return true
        case .hold, .avoid: return false
        }
    }

    private func prefillTradeFromIdea(_ idea: StockSageIdea) {
        let bearish = idea.advice.action == .sell || idea.advice.action == .reduce
        draftSymbol = idea.symbol
        draftEntry = adaptivePrice(idea.price)
        // The advisor fills a SIDE-CORRECT stop/target for shorts too (sell stop ABOVE entry, target
        // BELOW) — prefill them regardless of side so a logged short keeps its defined risk. The
        // .map/?? still blanks the genuine degenerate case (advisor returned nil, e.g. huge ATR).
        draftStop = idea.advice.stopPrice.map { adaptivePrice($0) } ?? ""
        draftTarget = idea.advice.targetPrice.map { adaptivePrice($0) } ?? ""
        draftShares = ""
        // T11 (rotation-3 triage): "N% conviction" read as a win-probability percent — F08
        // (wave-8) already relabeled this everywhere else to "signal strength N/100"
        // (StockSageTradePlan.swift's own note), this journal-note prefill was the straggler.
        draftNote = "From idea: \(idea.advice.action.rawValue), signal strength \(Int(idea.advice.conviction * 100))/100"
        draftConviction = idea.advice.conviction   // recorded on the trade for journal calibration
        draftSide = bearish ? .short : .long   // side follows the idea's direction
        showAddTrade = true
        selectedIdea = nil          // dismiss the detail sheet
        section = .portfolio        // the journal lives in the Portfolio section
    }

    private func journalOpenRow(_ trade: TradeRecord) -> some View {
        let mark = currentPrice(trade.symbol)
        let pnl = mark.map { trade.profit(at: $0) }
        let r = mark.flatMap { trade.rMultiple(at: $0) }
        // The FULL live verdict for this position (not just the urgent banner) so every open trade
        // shows its next step: hold / near-stop / in-profit / stop-or-target hit.
        let act = StockSageJournal.openActions([trade], mark: { currentPrice($0) }).first
        // Build the spoken label as a plain String OUTSIDE the ViewBuilder — the multi-clause `+`
        // concatenation was tipping journalOpenRow over the SwiftUI type-checker complexity budget.
        var a11y = "\(trade.side.rawValue) \(trade.symbol), entry \(adaptivePrice(trade.entry))"
        a11y += pnl.map { ", unrealized \(StockSageCurrency.signedAmount($0, symbol: trade.symbol))" } ?? ", no live price"
        if let r { a11y += String(format: ", %+.2f R", r) }
        if let act { a11y += ", \(act.kind.rawValue): \(act.detail)" }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DS.Space.sm) {
                Text(trade.symbol).font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white).frame(width: 64, alignment: .leading).lineLimit(1)
                Text(trade.side.rawValue).font(.system(size: mvFont9, weight: .semibold))
                    .foregroundStyle(trade.side == .long ? DS.Palette.successSoft : DS.Palette.danger)
                Text("@ \(adaptivePrice(trade.entry))").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let pnl, let r {
                    // Journal leg of the first-real-trade review (2026-07-16): P&L is in the
                    // symbol's OWN quote currency — a bare "+150.00" on a 2222.SR row reads as
                    // dollars but is SAR. signedAmount keeps USD rows byte-identical.
                    Text(StockSageCurrency.signedAmount(pnl, symbol: trade.symbol)).font(.system(size: mvFont11, weight: .semibold))
                        .foregroundStyle(pnl >= 0 ? DS.Palette.successSoft : DS.Palette.danger)
                    Text(String(format: "%+.2fR", r)).font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                } else {
                    Text("no live px").font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    closeExitText = mark.map { adaptivePrice($0) } ?? ""
                    closePlannedExitText = ""; closeExitFillText = ""
                    withAnimation(.easeOut(duration: 0.12)) { closingTradeID = (closingTradeID == trade.id) ? nil : trade.id }
                } label: {
                    Text(closingTradeID == trade.id ? "Cancel" : "Close").font(.system(size: mvFont10, weight: .semibold)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                .accessibilityLabel(closingTradeID == trade.id ? "Cancel closing \(trade.symbol)" : "Close \(trade.symbol) position")
            }
            if let note = trade.note, !note.isEmpty {
                Text(note).font(.system(size: mvFont9)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            // Time-stop: nudge when a position has outlived its planned hold window (the
            // asset-class velocity assumption) — dead money the loss column never shows.
            let plannedHold = StockSageAllocation.assetClass(trade.symbol) == "Crypto" ? Int(cryptoHoldDays) : Int(equityHoldDays)
            if let ts = StockSageTimeStop.suggest(openedAt: trade.openedAt, now: Date(), daysToHold: plannedHold), ts.shouldExit {
                Text("⏳ \(ts.rationale)").font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Time stop: held \(ts.daysHeld) days, past the \(plannedHold) day plan")
            }
            if let act {
                Text("\(act.kind.rawValue) — \(act.detail)")
                    .font(.system(size: mvFont9, weight: act.isUrgent ? .semibold : .regular))
                    .foregroundStyle(openActionColor(act.kind))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if closingTradeID == trade.id {
                HStack(spacing: DS.Space.sm) {
                    journalField("Exit px", text: $closeExitText, width: 80)
                    journalField("Plan px (opt)", text: $closePlannedExitText, width: 100)
                        .help("What the plan quoted when you decided to exit. Measures your real execution cost vs. the plan — never changes P&L.")
                    journalField("Fill px (opt)", text: $closeExitFillText, width: 100)
                        .help("Your actual exit fill price. Measures your real execution cost vs. the plan — never changes P&L.")
                    Button {
                        guard let exit = StockSageInput.positiveAmount(closeExitText) else { return }
                        journal.close(trade.id, exitPrice: exit,
                                     plannedExit: StockSageInput.positiveAmount(closePlannedExitText),
                                     exitFill: StockSageInput.positiveAmount(closeExitFillText))
                        closingTradeID = nil
                        closePlannedExitText = ""; closeExitFillText = ""
                    } label: {
                        Text("Confirm close").font(.system(size: mvFont10, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(DS.Palette.danger, in: Capsule())
                    }.buttonStyle(LuxPressStyle()).disabled(!closeIsValid)
                    Spacer(minLength: 0)
                }
                // First-real-trade review cycle-1 (2026-07-16): closing was blind — the owner typed
                // an exit and only saw the realized P&L AFTER confirming. Preview it at the typed
                // exit: currency-correct P&L (signedAmount — a .SR exit reads SAR, not "$") + the
                // R-multiple, colored by sign. Pure display over the tested trade.profit/rMultiple;
                // nil (no note) until the exit parses, so it never shows a fabricated number.
                if let exit = StockSageInput.positiveAmount(closeExitText) {
                    let pnl = trade.profit(at: exit)
                    let rStr = trade.rMultiple(at: exit).map { String(format: " · %+.2fR", $0) } ?? ""
                    Text("Closing here: \(StockSageCurrency.signedAmount(pnl, symbol: trade.symbol))\(rStr)")
                        .font(.system(size: mvFont9, weight: .semibold))
                        .foregroundStyle(pnl >= 0 ? DS.Palette.successSoft : DS.Palette.danger)
                        .accessibilityLabel("Closing at \(adaptivePrice(exit)) realizes \(StockSageCurrency.signedAmount(pnl, symbol: trade.symbol))"
                            + (trade.rMultiple(at: exit).map { String(format: ", %+.2f R", $0) } ?? ""))
                    // Cycle-2 (2026-07-16): a .SR exit off the Tadawul tick grid would be rejected
                    // by the broker — same guard the entry stop/target already carry. Display-only.
                    if let tickNote = StockSageTickSize.exitPlaceabilityNote(symbol: trade.symbol, exit: exit) {
                        Text("⚠ " + tickNote).font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11y)
    }

    /// Confirm-close gate: exit price required + parseable; the two optional realized-cost
    /// fields may be blank but block close if typed-and-unparseable (never silently drop to nil).
    private var closeIsValid: Bool {
        guard StockSageInput.positiveAmount(closeExitText) != nil else { return false }
        let plannedOK = closePlannedExitText.trimmingCharacters(in: .whitespaces).isEmpty
            || StockSageInput.positiveAmount(closePlannedExitText) != nil
        let fillOK = closeExitFillText.trimmingCharacters(in: .whitespaces).isEmpty
            || StockSageInput.positiveAmount(closeExitFillText) != nil
        return plannedOK && fillOK
    }

    /// Color the per-position live verdict by urgency: red stop-hit, amber near-stop, green
    /// target-hit/in-profit, muted holding.
    private func openActionColor(_ kind: OpenAction.Kind) -> Color {
        switch kind {
        case .stopHit:              return DS.Palette.danger
        case .nearStop:             return DS.Palette.warningSoft
        case .targetHit, .inProfit: return DS.Palette.successSoft
        case .holding:              return .secondary
        }
    }

    private func journalClosedRow(_ trade: TradeRecord) -> some View {
        // Use adaptivePrice for entry/exit so sub-dollar symbols (micro-caps, coins) don't
        // collapse to "0.00→0.00". realizedProfit is Optional by design — show "—" not "+0.00"
        // when a record is missing it (e.g. decoded/edited data without exitPrice).
        let exitStr = trade.exitPrice.map { adaptivePrice($0) } ?? "—"
        let pnlText: String
        let pnlColor: Color
        if let pnl = trade.realizedProfit {
            pnlText = StockSageCurrency.signedAmount(pnl, symbol: trade.symbol)
            pnlColor = pnl >= 0 ? DS.Palette.successSoft : DS.Palette.danger
        } else {
            pnlText = "—"
            pnlColor = .secondary
        }
        // Per-leg realized slippage — "—" for a nil leg (never fabricate 0), shown only when at
        // least one leg has data.
        let slipLine: String? = {
            guard trade.entrySlippageBps != nil || trade.exitSlippageBps != nil else { return nil }
            let entryStr = trade.entrySlippageBps.map { String(format: "%+.1f bps", $0) } ?? "—"
            let exitStr = trade.exitSlippageBps.map { String(format: "%+.1f bps", $0) } ?? "—"
            return "slip: entry \(entryStr) · exit \(exitStr)"
        }()
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.sm) {
                Text(trade.symbol).font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).frame(width: 64, alignment: .leading).lineLimit(1)
                Text("\(adaptivePrice(trade.entry))→\(exitStr)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(pnlText).font(.system(size: mvFont11, weight: .semibold))
                    .foregroundStyle(pnlColor)
                if let r = trade.realizedR {
                    Text(String(format: "%+.2fR", r)).font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
                Button { pendingJournalDeleteID = trade.id } label: {
                    Image(systemName: "trash").font(.system(size: mvFont9)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                .accessibilityLabel("Delete \(trade.symbol) from journal")
            }
            if let slipLine {
                Text(slipLine).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(trade.symbol), \(adaptivePrice(trade.entry)) to \(exitStr), realized \(pnlText)"
            + (trade.realizedR.map { String(format: ", %+.2f R", $0) } ?? ""))
        .confirmationDialog("Delete this logged trade?",
                            isPresented: Binding(get: { pendingJournalDeleteID == trade.id },
                                                 set: { if !$0 { pendingJournalDeleteID = nil } })) {
            Button("Delete \(trade.symbol)", role: .destructive) { journal.remove(trade.id); pendingJournalDeleteID = nil }
            Button("Cancel", role: .cancel) { pendingJournalDeleteID = nil }
        } message: { Text("Removes it from your realized P&L and edge stats. This can't be undone.") }
    }

    // MARK: Kelly position sizer

    private var kellySizerPanel: some View {
        // FIX 1 (round-g): route through the comma-aware StockSageInput seam — the same one the
        // account-position sizer already uses (parsedAccount, F04 comment above) — instead of raw
        // Double(…) ?? 0. A decimal-comma "2,5"/"1,5"/"10,000" (Saudi/EU) previously parsed to nil
        // at every field and silently computed Kelly on 0/0/0, rendering a fabricated "no positive
        // edge" verdict from a pure parse failure. nil on ANY field ⇒ render an honest hint, never
        // compute on a fabricated 0 (honesty floor).
        let acct = StockSageInput.positiveAmount(kellyAccount)
        let payoff = StockSageInput.positiveAmount(kellyPayoff)
        let winPct = StockSageInput.percent(kellyWinRate)
        let k: KellyResult? = {
            guard let acct, let payoff, let winPct else { return nil }
            return StockSageKelly.compute(winRate: winPct / 100, payoffRatio: payoff, accountSize: acct)
        }()
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "percent").font(.system(size: mvFont16)).foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Position sizer (Kelly)").font(DS.Typography.titleM).foregroundStyle(.white)
                        .help(StockSageGlossary.kellyHelp)
                    Text("Suggested fraction of capital to ALLOCATE (lose-the-whole-bet Kelly sizing) — NOT the ~1% stop-risk the position sizer uses.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            HStack(spacing: DS.Space.sm) {
                kellyField($kellyWinRate, "Win %", width: 56)
                kellyField($kellyPayoff, "Payoff R", width: 64)
                kellyField($kellyAccount, "Account $", width: 92)
                Spacer(minLength: 0)
            }
            if let bt = store.backtest, bt.isSignificant,
               let inp = StockSageKelly.inputs(winRate: bt.winRate, avgWinR: bt.avgWinR, avgLossR: bt.avgLossR) {
                Button {
                    kellyWinRate = String(format: "%.0f", inp.winRate * 100)
                    kellyPayoff = String(format: "%.2f", inp.payoffRatio)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.doc.fill").font(.system(size: mvFont10, weight: .semibold))
                        Text("Use \(store.backtestSymbol ?? "symbol") backtest (\(bt.trades) trades)")
                            .font(.system(size: mvFont10, weight: .semibold))
                    }
                    .foregroundStyle(DS.Palette.accent)
                }
                .buttonStyle(.plain)
                .help("Fill Win% and Payoff from the backtested win-rate and avg-win÷avg-loss — still a backward-looking estimate.")
            }
            if let ji = journal.kellyInputs {
                Button {
                    kellyWinRate = String(format: "%.0f", ji.winRate * 100)
                    kellyPayoff = String(format: "%.2f", ji.payoffRatio)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "book.closed.fill").font(.system(size: mvFont10, weight: .semibold))
                        Text("Use my journal (\(ji.n) trades)").font(.system(size: mvFont10, weight: .semibold))
                    }
                    .foregroundStyle(DS.Palette.accent)
                }
                .buttonStyle(.plain)
                .help("Fill Win% and Payoff from your OWN logged trades (≥10 closed, with wins and losses) — your real edge, not a backtest.")
            }
            if let k {
                HStack(spacing: 18) {
                    ideaMetric("Full Kelly", String(format: "%.1f%%", k.fullKelly * 100))
                    ideaMetric("Half", String(format: "%.1f%%", k.halfKelly * 100), color: DS.Palette.successSoft)
                    ideaMetric("Suggested", String(format: "%.1f%%", k.suggestedFraction * 100), color: DS.Palette.accent)
                    ideaMetric("Allocate $", String(format: "%.0f", k.dollarsToAllocate))
                    Spacer(minLength: 0)
                }
                Text(k.note).font(.caption2)
                    // Note color: success only when there is an edge AND half-Kelly fits under the cap.
                    // The "capped for safety" note has fullKelly > 0 but should render as a warning, not success.
                    .foregroundStyle((k.fullKelly > 0 && k.halfKelly < StockSageKelly.maxFraction) ? DS.Palette.successSoft : DS.Palette.warningSoft)
                Text(k.caveat).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                // Honesty floor: nil input (blank, unparseable, "abc", ambiguous comma) renders a
                // hint, never a computed 0/0/0 verdict — matches the account-sizer's nil idiom.
                Text("Enter a valid Win %, Payoff R, and Account $ to see a Kelly suggestion.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    private func kellyField(_ text: Binding<String>, _ label: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: mvFont9, weight: .semibold)).foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.plain).font(.system(size: mvFont13)).frame(width: width)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
                .accessibilityLabel(label)
        }
    }

    // MARK: Portfolio risk analytics

    private var portfolioAnalyticsPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "chart.pie.fill").font(.system(size: mvFont16)).foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Risk analytics").font(DS.Typography.titleM).foregroundStyle(.white)
                        .help(StockSageGlossary.analyticsHelp)
                    Text("Sharpe · drawdown · VaR · correlation across your holdings.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { Task { await store.refreshPortfolioAnalytics() } } label: {
                    HStack(spacing: 6) {
                        Group {
                            if store.isLoadingAnalytics { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "function").font(.system(size: mvFont11, weight: .semibold)) }
                        }
                        Text(store.isLoadingAnalytics ? "Analyzing…" : "Analyze")
                            .font(.system(size: mvFont11_5, weight: .semibold)).contentTransition(.opacity)
                    }
                    .foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 6)
                    .background(DS.Palette.accent, in: Capsule())
                }
                .buttonStyle(LuxPressStyle()).disabled(store.isLoadingAnalytics)
            }
            if let e = store.analyticsError {
                Text(e).font(.caption2).foregroundStyle(DS.Palette.warningSoft)
            }
            if let a = store.analytics {
                // When an error is also present the numbers below are from a previous book — flag them.
                if store.analyticsError != nil {
                    Text("Showing previous analysis — re-run Analyze for updated numbers.")
                        .font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Audit 2026-07-12 pass-3 (finding ③): the risk blend weights holdings by value but
                // does NOT FX-convert across currencies, so a multi-currency book's weights (and thus
                // every stat below) are approximate. Disclose rather than imply exactness.
                if store.analyticsWeightsApproximate {
                    Text("⚠︎ Multi-currency book — these stats weight holdings by local-currency value without FX conversion, so the blend is approximate. Single-currency books are exact.")
                        .font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 18) {
                    ideaMetric("Ann. return", String(format: "%+.1f%%", a.annualizedReturn),
                               color: a.annualizedReturn >= 0 ? DS.Palette.successSoft : DS.Palette.danger)
                    ideaMetric("Volatility", String(format: "%.1f%%", a.annualizedVolatility))
                    ideaMetric("Sharpe", a.sharpe.map { String(format: "%.2f", $0) } ?? "n/a",
                               color: a.sharpe == nil ? .secondary : (a.sharpe! >= 1 ? DS.Palette.successSoft : (a.sharpe! >= 0.3 ? .white : DS.Palette.danger)))
                    ideaMetric("Sortino", a.sortino.map { String(format: "%.2f", $0) } ?? "n/a")
                    Spacer(minLength: 0)
                }
                HStack(spacing: 18) {
                    ideaMetric("Max DD", String(format: "−%.1f%%", a.maxDrawdown), color: DS.Palette.danger)
                    ideaMetric("Calmar", a.calmar.map { String(format: "%.2f", $0) } ?? "n/a")
                    ideaMetric("VaR 95%", String(format: "−%.1f%%", a.valueAtRisk95), color: DS.Palette.danger)
                    ideaMetric("Avg corr", String(format: "%.2f", a.avgCorrelation))
                    if let beta = store.portfolioBeta {
                        ideaMetric("β vs S&P", String(format: "%.2f", beta),
                                   color: beta > 1.15 ? DS.Palette.warningSoft : (beta < 0 ? DS.Palette.accent : .white))
                            .help(StockSageGlossary.betaHelp)
                    }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Diversification").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f / 100", a.diversificationScore)).font(.caption2).foregroundStyle(.white)
                    }
                    convictionMeter(a.diversificationScore / 100,
                                    color: a.diversificationScore >= 60 ? DS.Palette.successSoft
                                         : (a.diversificationScore >= 30 ? DS.Palette.warningSoft : DS.Palette.danger))
                }
                // When analyticsError != nil the snapshot may be from a previous (larger/smaller)
                // book; comparing a.holdingsAnalyzed against the CURRENT portfolio count can
                // produce nonsensical "5 of 2 holdings" copy. Show the snapshot's own counts
                // without referencing the live count in the stale-error case.
                if store.analyticsError != nil {
                    Text("\(a.observations) days · \(a.holdingsAnalyzed) holdings (previous analysis) · \(a.caveat)")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    let totalPositions = StockSagePortfolio.shared.positions.count
                    let excludedCount = max(0, totalPositions - a.holdingsAnalyzed)
                    Text("\(a.observations) days · \(a.holdingsAnalyzed) of \(totalPositions) holdings\(excludedCount > 0 ? " — \(excludedCount) had no history and are excluded" : "") · \(a.caveat)")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    // MARK: Heatmap

    private var heatmap: some View {
        Group {
            if store.symbols.isEmpty {
                emptyState
                    .transition(.opacity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(store.symbols) { sym in
                        let change = sym.latest?.changePercent ?? 0
                        let heatHovered = hoveredHeatID == sym.id
                        // Per-row freshness: a days-old weekend/holiday close (or a stale crypto
                        // feed) is dimmed + clock-flagged so it isn't read as a live price.
                        let stale = sym.isStale()
                        // A brand-new listing has no real previousClose — Yahoo's flat placeholder
                        // reads as a genuine 0% "hold" without this; show "unevaluated," not "flat."
                        let isNew = store.newListings.contains(sym.symbol.uppercased())
                        VStack(spacing: 3) {
                            Text(sym.symbol)
                                .font(.system(size: mvFont13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                            Text(isNew ? "N/A (new)" : String(format: "%+.1f%%", change))
                                .font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                                .contentTransition(.numericText())
                                .animation(DS.Motion.smooth, value: change)
                        }
                        // Legibility on saturated tiles: white on a strong green/red is
                        // borderline — a subtle dark shadow lifts the text on any shade.
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .frame(maxWidth: .infinity).frame(height: 66)
                        .background(isNew ? Color.white.opacity(0.10) : heatColor(change),
                                   in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if stale {
                                Image(systemName: "clock.fill")
                                    .font(.system(size: mvFont8)).foregroundStyle(.white.opacity(0.95))
                                    .padding(3)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                            .stroke(Color.white.opacity(heatHovered ? 0.22 : 0.08), lineWidth: 1))
                        // C4 harvest (2026-07-09): 0.55 was sub-AA on this row's own secondary
                        // text — same defect the ideas card fixed (its comment: "0.85 keeps
                        // .secondary text ≥4.5:1 AA (was 0.75 → 3.84:1)"). Same fix, same floor;
                        // staleness stays legible instead of illegibly dim.
                        .opacity(stale ? 0.85 : 1)   // visually recede a stale row (AA floor)
                        .scaleEffect(heatHovered ? 1.04 : 1.0)
                        .animation(DS.Motion.press, value: heatHovered)
                        .onHover { over in
                            withAnimation(DS.Motion.press) {
                                if over { hoveredHeatID = sym.id }
                                else if hoveredHeatID == sym.id { hoveredHeatID = nil }
                            }
                        }
                        .help(isNew
                              ? "\(sym.market) — newly listed, no prior close to compare against yet; not a real 0% move."
                              : (stale
                              ? "\(sym.market) — STALE: last quote \((sym.latest?.time).map { $0.formatted(.relative(presentation: .named)) } ?? "unknown"); market likely closed, not a live price."
                              : sym.market))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(sym.symbol), \(isNew ? "newly listed, not yet evaluated" : String(format: "%+.1f percent", change))\(stale ? ", stale quote — market likely closed" : "")")
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                }
                // .contain (not .combine) so each tile's own accessibilityLabel above survives.
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Market heatmap, \(store.symbols.count) symbols by price change")
                .animation(DS.Motion.smooth, value: store.symbols.count)
                .transition(.opacity)
            }
        }
        .animation(DS.Motion.smooth, value: store.symbols.isEmpty)
    }

    /// Tile color: green-to-red by change magnitude (gain → green, loss → red,
    /// flat → neutral). Opacity scales with the move so a big swing reads hotter.
    private func heatColor(_ change: Double) -> Color {
        if change > 0.05 { return DS.Palette.success.opacity(min(0.28 + change / 18, 0.85)) }
        if change < -0.05 { return DS.Palette.danger.opacity(min(0.28 + abs(change) / 18, 0.85)) }
        return Color.white.opacity(0.10)
    }

    // MARK: Signals

    /// `watchlistOnly`: when true, scope the list to `store.userSymbols` (the owner's hand-picked
    /// tickers); when false, show the full board. The two picker segments ("Watchlist" / "All")
    /// now diverge here instead of both routing to the full-universe list.
    private func signalListView(watchlistOnly: Bool) -> some View {
        let userSet = Set(store.userSymbols.map { $0.uppercased() })
        let displayed: [StockSageSymbol] = watchlistOnly
            ? store.symbols.filter { userSet.contains($0.symbol.uppercased()) }
            : store.symbols
        return VStack(spacing: DS.Space.sm) {
            addSymbolBar
            if store.symbols.isEmpty {
                emptyState
                    .transition(.opacity)
            } else if watchlistOnly && displayed.isEmpty {
                Text("Your watchlist is empty — add a ticker above or in Browse.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, DS.Space.sm)
                    .transition(.opacity)
            } else {
                HStack {
                    Spacer()
                    Menu {
                        ForEach(MarketSort.allCases) { s in
                            Button { sort = s } label: {
                                Label(s.title, systemImage: sort == s ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Label("Sort: \(sort.title)", systemImage: "arrow.up.arrow.down")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Sort watchlist")
                }
                ForEach(sort.apply(displayed)) { signalCard($0)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
        .animation(DS.Motion.smooth, value: displayed.count)
    }

    private var addSymbolBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "magnifyingglass").font(.system(size: mvFont12)).foregroundStyle(.secondary)
                TextField("Track any ticker — AAPL · 2222.SR · BTC-USD · EURUSD=X", text: $newWatchSymbol)
                    .textFieldStyle(.plain).font(.system(size: mvFont13))
                    .onSubmit { Task { await addWatchSymbol() } }
                    .accessibilityLabel("Ticker to add to watchlist")
                if store.isAddingSymbol {
                    ProgressView().controlSize(.small).tint(DS.Palette.accent)
                } else {
                    Button { Task { await addWatchSymbol() } } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: mvFont18)).foregroundStyle(DS.Palette.accent)
                    }
                    .buttonStyle(LuxPressStyle())
                    .disabled(newWatchSymbol.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Validate against a live quote, then add to the watchlist")
                    .accessibilityLabel("Add ticker to watchlist")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .stroke(DS.Palette.surfaceStroke, lineWidth: 1))

            // Catalog autocomplete — search the full directory (incl. names not yet on
            // the board) and one-tap add. Hidden once the query already matches a tracked row.
            let q = newWatchSymbol.trimmingCharacters(in: .whitespaces)
            let suggestions: [StockSageSymbol] = q.isEmpty ? [] :
                StockSageUniverse.search(q, limit: 6).filter { sug in
                    !store.symbols.contains { $0.symbol.uppercased() == sug.symbol.uppercased() }
                }
            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions) { sug in
                        Button {
                            newWatchSymbol = sug.symbol
                            Task { await addWatchSymbol() }
                        } label: {
                            HStack(spacing: DS.Space.sm) {
                                Text(sug.symbol).font(.system(size: mvFont12, weight: .semibold)).foregroundStyle(.white)
                                    .frame(minWidth: 64, alignment: .leading)
                                Text(sug.market).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "plus.circle").font(.system(size: mvFont12)).foregroundStyle(DS.Palette.accent)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add \(sug.symbol), \(sug.market)")
                    }
                }
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
            }
            if let err = watchlistAddError {
                // Local error — set only by addWatchSymbol(), never by browse-sheet adds.
                Text(err).font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            Button { showBrowseMarkets = true } label: {
                Label("Browse all \(StockSageUniverse.catalog.count) tickers", systemImage: "square.grid.2x2")
                    .font(.system(size: mvFont11, weight: .medium)).foregroundStyle(DS.Palette.accent)
            }
            .buttonStyle(.plain)
            .help("Browse the full searchable directory by region & asset class; tap + to track any (fetches one quote).")
        }
        .animation(DS.Motion.smooth, value: watchlistAddError)
        // Clear the watchlist error when the browse sheet opens or closes so errors from one
        // surface never bleed into the other (fixes direction (b): browse-sheet fail → watchlist).
        .onChange(of: showBrowseMarkets) { watchlistAddError = nil }
        .sheet(isPresented: $showBrowseMarkets) { BrowseMarketsView(store: store) }
    }

    private func addWatchSymbol() async {
        watchlistAddError = nil
        await store.addSymbol(newWatchSymbol)
        // Capture the error locally; the store's addSymbolError is shared with the browse sheet
        // so we never read it directly in the watchlist box display (see watchlistAddError).
        watchlistAddError = store.addSymbolError
        if store.addSymbolError == nil { newWatchSymbol = "" }
    }

    private func signalCard(_ sym: StockSageSymbol) -> some View {
        let signal = StockSageSignalEngine.generateSignal(for: sym)
        let change = sym.latest?.changePercent ?? 0
        // A 0.00% day is FLAT, not a green gain — match the ±0.05% neutral band heatColor/sparkColor
        // already use, so the same field never reads as an up-move here and neutral elsewhere.
        let flat = abs(change) <= 0.05
        let up = change > 0
        // Tabs-audit 2026-07-09: a NEW LISTING (Yahoo placeholder previousClose — real prior
        // close unknown) rendered here as a fabricated "+0.00%" flat day while the heatmap
        // honestly says "N/A (new)" for the SAME symbol. Mirror the heatmap's guard.
        let isNew = store.newListings.contains(sym.symbol.uppercased())
        let hovered = hoveredSignalID == sym.id
        // Per-row freshness: a stale (weekend/holiday or stale-feed) quote is dimmed + clock-flagged so
        // its Buy/Sell + strength% isn't acted on as a live signal — matching the heatmap's treatment.
        let stale = sym.isStale()
        return HStack(spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.xs) {
                    Text(sym.symbol).font(.system(size: mvFont15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    if stale {
                        Image(systemName: "clock.fill").font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft)
                    }
                }
                Text(stale ? "\(sym.market) · stale" : sym.market).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let p = sym.latest?.price {
                    Text(adaptivePrice(p))
                        .font(.system(size: mvFont15, weight: .semibold)).foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(DS.Motion.smooth, value: p)
                }
                HStack(spacing: 3) {
                    if !isNew {
                        Image(systemName: flat ? "minus" : (up ? "arrow.up.right" : "arrow.down.right")).font(.system(size: mvFont9, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                            .animation(DS.Motion.smooth, value: up)
                    }
                    Text(isNew ? "N/A (new)" : String(format: "%+.2f%%", change))
                        .font(.system(size: mvFont12, weight: .medium))
                        .contentTransition(.numericText())
                        .animation(DS.Motion.smooth, value: change)
                }
                .foregroundStyle(isNew ? Color.secondary : (flat ? Color.secondary : (up ? DS.Palette.successSoft : DS.Palette.danger)))
            }
            if let signal {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(signal.recommendation.rawValue)
                        .font(.system(size: mvFont11, weight: .bold)).foregroundStyle(recTextColor(signal.recommendation))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(recColor(signal.recommendation), in: Capsule())
                    // "Strength %" only makes sense for an actual buy/sell signal —
                    // SignalEngine hardcodes 0.65 for hold ("price consolidating"),
                    // which would read as "65% strength of doing nothing." Hide it.
                    if signal.recommendation != .hold {
                        Text("strength \(Int(signal.confidence * 100))%").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, alignment: .trailing)
            }
            // Hover quick-remove — only for user-added rows (curated rows aren't removable).
            if sym.market == "★ My watchlist", hovered {
                Button { withAnimation(DS.Motion.smooth) { store.removeSymbol(sym.symbol) } } label: {
                    Image(systemName: "trash").font(.system(size: mvFont12)).foregroundStyle(DS.Palette.danger)
                }
                .buttonStyle(.plain)
                .help("Remove from watchlist")
                .accessibilityLabel("Remove \(sym.symbol) from watchlist")
                .transition(.opacity)
            }
        }
        .padding(DS.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(hovered ? Color.white.opacity(0.055) : DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(hovered ? DS.Palette.accent.opacity(0.35) : DS.Palette.surfaceStroke, lineWidth: 1))
        .scaleEffect(hovered ? 1.008 : 1.0)
        // Tabs-audit 2026-07-09: 0.55 was sub-AA on this row's own secondary text — the exact
        // gap the ideas-card comment deferred "to its own wave"; heatmap got the same fix
        // earlier today (0.85 AA floor). Clock icon + "· stale" caption stay the primary cues.
        .opacity(stale ? 0.85 : 1)   // visually recede a stale row (AA floor) — not a live, actionable signal
        .shadow(color: DS.Palette.accent.opacity(hovered ? 0.10 : 0), radius: 10, y: 3)
        .animation(DS.Motion.smooth, value: hovered)
        .contentShape(Rectangle())
        .onHover { over in
            withAnimation(DS.Motion.smooth) {
                if over { hoveredSignalID = sym.id }
                else if hoveredSignalID == sym.id { hoveredSignalID = nil }
            }
        }
        .help({
            var h = stale
                ? "STALE: last quote \((sym.latest?.time).map { $0.formatted(.relative(presentation: .named)) } ?? "unknown") — market likely closed, not a live price. \(signal?.reason ?? "")"
                : (signal?.reason ?? "")
            if isNew { h = "Newly listed — no prior close to compare against yet. " + h }
            return h
        }())
        .contextMenu {
            if sym.market == "★ My watchlist" {
                Button(role: .destructive) { store.removeSymbol(sym.symbol) } label: {
                    Label("Remove “\(sym.symbol)” from watchlist", systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .combine)
        // Tabs-audit 2026-07-09 a11y parity: speak the visible "strength N%" qualifier (its
        // absence made a marginal 55% Buy and a 90% Buy sound identical) and the new-listing
        // honesty state, mirroring the visibility conditions exactly.
        .accessibilityLabel("\(sym.symbol), \(sym.market), \(sym.latest.map { adaptivePrice($0.price) } ?? "no price"), \(isNew ? "newly listed, not yet evaluated" : String(format: "%+.1f percent", change)), signal \(signal?.recommendation.rawValue ?? "none")\(signal.flatMap { $0.recommendation != .hold ? ", strength \(Int($0.confidence * 100)) percent" : nil } ?? "")\(stale ? ", stale quote — market likely closed" : "")")
    }

    private func recColor(_ r: StockSageRecommendation) -> Color {
        switch r {
        case .strongBuy, .buy:   return DS.Palette.successSoft
        case .hold:              return DS.Palette.warningSoft
        case .sell, .strongSell: return DS.Palette.danger
        }
    }

    /// Badge text colour for legibility. The buy/hold badges sit on LIGHT pastel
    /// backgrounds (successSoft/warningSoft), where white text is only ~1.9:1 (the
    /// QA textContrast scan flagged exactly this) — use a dark ink there; white
    /// still reads on the darker red sell badge.
    private func recTextColor(_ r: StockSageRecommendation) -> Color {
        switch r {
        case .sell, .strongSell: return .white
        default:                 return Color(white: 0.06)   // darker ink → AA contrast on bright pastels
        }
    }

    // MARK: Briefing

    private var briefingSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text("Daily briefing")
                    .font(.system(size: mvFont16, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Spacer()
                Button { Task { await generateBriefing() } } label: {
                    HStack(spacing: 6) {
                        Group {
                            if loadingBriefing { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "sparkles") }
                        }
                        .transition(.opacity)
                        .animation(DS.Motion.smooth, value: loadingBriefing)
                        Text(loadingBriefing ? "Generating…" : "Generate")
                            .contentTransition(.opacity)
                            .animation(DS.Motion.smooth, value: loadingBriefing)
                    }
                    .font(.system(size: mvFont11_5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(DS.Palette.accent, in: Capsule())
                    .shadow(color: DS.Palette.accent.opacity(0.25), radius: 4, y: 1)
                }
                .buttonStyle(LuxPressStyle())
                .disabled(loadingBriefing)
            }
            Text(briefing.isEmpty ? StockSageBriefingService.deterministicSummary(for: store.symbols) : briefing)
                .font(.callout).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .contentTransition(.opacity)
                .animation(DS.Motion.smooth, value: briefing.isEmpty)
            if !briefing.isEmpty, let generatedAt = briefingGeneratedAt {
                let stale = generatedAt < Date().addingTimeInterval(-4 * 3600)
                Text((stale ? "⚠︎ Generated " : "Generated ")
                     + generatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(stale ? DS.Palette.warningSoft : Color.secondary)
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
        // Reset a generated briefing when the watched symbol list changes so stale
        // LLM text naming removed tickers is never presented as current.
        .onChange(of: store.symbols.map(\.symbol).sorted().joined()) {
            briefing = ""
            briefingGeneratedAt = nil
        }
    }

    private func generateBriefing() async {
        loadingBriefing = true
        briefing = await StockSageBriefingService.generateBriefing(for: store.symbols)
        briefingGeneratedAt = Date()
        loadingBriefing = false
    }

    // MARK: Ideas (the advisor across the universe)

    private var ideasSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ideasHeader
            bestOpportunityCard
            capitalAllocationCard
            fastLaneStrip
            todaysActionsCard
            alertsPanel
            strategyBacktestPanel
            backtestPanel
            if store.ideas.isEmpty {
                Text(store.isLoadingIdeas
                     ? "Analyzing every market on 1-year price history…"
                     : "Tap “Find ideas” to scan every market and rank the strongest rules-based setups.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            } else {
                HStack(spacing: DS.Space.sm) {
                    Menu {
                        ForEach(IdeaSort.pickerCases, id: \.self) { s in
                            Button { ideaSort = s } label: { Label(s.label, systemImage: ideaSort == s ? "checkmark" : "") }
                        }
                    } label: {
                        Label("Sort: \(ideaSort.label)", systemImage: "arrow.up.arrow.down")
                            .font(.system(size: mvFont10)).foregroundStyle(DS.Palette.accent)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Sort ideas")
                    Menu {
                        ForEach(IdeaFilter.allCases) { f in
                            Button { ideaFilter = f } label: { Label(f.rawValue, systemImage: ideaFilter == f ? "checkmark" : "") }
                        }
                    } label: {
                        Label(ideaFilter == .all ? "Filter" : ideaFilter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                            .font(.system(size: mvFont10)).foregroundStyle(ideaFilter == .all ? .secondary : DS.Palette.accent)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Filter ideas by action")
                    Menu {
                        ForEach([0.0, 0.5, 0.6, 0.7, 0.8], id: \.self) { v in
                            Button { ideaMinConv = v } label: {
                                Label(v == 0 ? "Any signal strength" : "≥ \(Int(v * 100))%",
                                      systemImage: ideaMinConv == v ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Label(ideaMinConv == 0 ? "Signal strength" : "≥ \(Int(ideaMinConv * 100))%", systemImage: "speedometer")
                            .font(.system(size: mvFont10)).foregroundStyle(ideaMinConv == 0 ? .secondary : DS.Palette.accent)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Minimum signal-strength filter")
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "magnifyingglass").font(.system(size: mvFont10)).foregroundStyle(.secondary)
                        TextField("Search", text: $ideaSearch).textFieldStyle(.plain).font(.system(size: mvFont11))
                            .frame(width: 84)
                        if !ideaSearch.isEmpty {
                            Button { ideaSearch = "" } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: mvFont10)).foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Clear idea search").help("Clear search")
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.white.opacity(0.06), in: Capsule())
                    .accessibilityLabel("Search ideas by symbol")
                    Spacer()
                }
                // Bind once — displayedIdeas re-runs a full velocity re-rank (≈3 NetEdge evals/idea
                // + sort) on every access; the three sites below used to each call it separately.
                let shown = displayedIdeas
                if shown.isEmpty {
                    Text(ideasEmptyMessage)
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
                } else {
                    ideasSummaryStrip(shown)
                    // PERF-2/4: one O(trades)/O(positions) pass for the whole board instead of
                    // one per card — StockSageJournal.history(for:in:)/StockSagePortfolio.holding(for:in:)
                    // stay the semantic source of truth; these are the batch-lookup counterparts.
                    let historyBySymbol = StockSageJournal.historyBySymbol(in: journal.trades)
                    let holdingsBySymbol = StockSagePortfolio.holdingBySymbol(in: portfolio.positions)
                    LazyVStack(spacing: DS.Space.sm) {
                        ForEach(shown) { ideaCard($0, holdingsBySymbol: holdingsBySymbol, historyBySymbol: historyBySymbol) }
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(DS.Motion.smooth, value: store.ideas.count)
    }

    /// At-a-glance overview of the shown ideas: count, action breakdown (tap to filter),
    /// avg conviction and avg reward:risk. Counts reflect the current sort/filter/search.
    @ViewBuilder private func ideasSummaryStrip(_ ideas: [StockSageIdea]) -> some View {
        let strong = ideas.filter { $0.advice.action == .strongBuy }.count
        // buy FAMILY (matches the .buys filter this chip triggers: strong buy + buy)
        let buys = ideas.filter { $0.advice.action == .strongBuy || $0.advice.action == .buy }.count
        let sells = ideas.filter { $0.advice.action == .sell || $0.advice.action == .reduce }.count
        let avgConv = ideas.isEmpty ? 0 : ideas.map(\.advice.conviction).reduce(0, +) / Double(ideas.count)
        let rrs = ideas.map(rewardRisk).filter { $0 > 0 }
        let avgRR = rrs.isEmpty ? 0 : rrs.reduce(0, +) / Double(rrs.count)
        HStack(spacing: DS.Space.sm) {
            summaryChip("\(ideas.count)", "shown", .white) { ideaFilter = .all; ideaMinConv = 0; ideaSearch = "" }
            if strong > 0 { summaryChip("\(strong)", "strong buy", DS.Palette.successSoft) { ideaFilter = .strongBuy } }
            if buys > 0 { summaryChip("\(buys)", "buys", .white) { ideaFilter = .buys } }
            if sells > 0 { summaryChip("\(sells)", "sells", DS.Palette.warningSoft) { ideaFilter = .sells } }
            // T9 (rotation-3 triage): "avg conv" read as an average PROBABILITY of winning —
            // it's the average rules-based signal score (F08 vocabulary), same idiom as the
            // idea card's own "Signal strength — a rules-based score, not a probability." .help.
            summaryChip("\(Int((avgConv * 100).rounded()))%", "avg signal", help: "Average signal strength across the shown ideas — a rules-based score, not a probability.")
            if avgRR > 0 { summaryChip(String(format: "%.1f", avgRR), "avg R:R") }
            // Non-interactive sort-mode chip so the user always knows why
            // the board is ordered as it is, even after scrolling past the sort/filter strip.
            summaryChip("↕", ideaSort.label.lowercased() + " sort")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func summaryChip(_ value: String, _ label: String, _ valueColor: Color = .white,
                             help: String? = nil, action: (() -> Void)? = nil) -> some View {
        let chip = HStack(spacing: DS.Space.xs) {
            Text(value).font(.system(size: mvFont11, weight: .bold)).foregroundStyle(valueColor)
                .lineLimit(1).fixedSize()   // narrow lens 2026-07-09: "48%" split into "48"/"%" at 560pt
            Text(label).font(.system(size: mvFont10)).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.white.opacity(0.05), in: Capsule())
        if let action {
            Button(action: action) { chip }.buttonStyle(.plain).help("Filter to \(label)")
        } else if let help {
            // T9 (rotation-3 triage): non-interactive chips get an optional .help — a hover
            // explanation for a number that isn't a tap target, e.g. "avg signal"'s
            // rules-based-not-a-probability caveat. nil (every other call site) ⇒ no .help
            // modifier at all, byte-unchanged from before.
            chip.help(help)
        } else {
            chip
        }
    }

    /// The ideas in display order — by expected value (best bet first) or the
    /// store's default signal rank.
    /// Shared earnings-severity warning row — the buy-family (above the gate) and
    /// sell/reduce (evidence fallback) branches of ideaDetailSheet rendered this
    /// byte-identical HStack twice; one body = no drift risk (IL-16/IL-22 class).
    private func earningsWarningRow(_ ep: EarningsProximity) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "calendar.badge.exclamationmark").font(.system(size: mvFont11))
                .foregroundStyle(ep.severity == .imminent ? DS.Palette.dangerSoft : DS.Palette.warningSoft)
            Text(ep.note).font(.caption2).accessibilityLabel("Earnings risk: \(ep.note)")
                .foregroundStyle(ep.severity == .imminent ? DS.Palette.dangerSoft : DS.Palette.warningSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// F19/F20 (2026-07-15): delegates to the engine projection — the body moved VERBATIM to
    /// StockSageIdeaProjection.displayed so the sort/filter/search contract is testable (F16 pins).
    private var displayedIdeas: [StockSageIdea] {
        StockSageIdeaProjection.displayed(store.ideas, sort: ideaSort, filter: ideaFilter,
                                          minConviction: ideaMinConv, search: ideaSearch,
                                          regime: store.regime, earnings: store.earnings,
                                          liquidity: store.liquidity, seasonality: store.seasonality,
                                          holds: velocityHolds, calibration: store.convictionCalibration)
    }

    /// Why the filtered ideas list is empty — names the active constraint so the user knows what to relax.
    private var ideasEmptyMessage: String {
        if !ideaSearch.trimmingCharacters(in: .whitespaces).isEmpty { return "No ideas match “\(ideaSearch)”." }
        if ideaMinConv > 0 { return "No ideas at ≥ \(Int(ideaMinConv * 100))% signal strength — lower the signal-strength filter." }
        if ideaFilter != .all { return "No \(ideaFilter.rawValue.lowercased()) ideas in this scan." }
        return "No ideas in this scan."
    }

    /// F19/F20 (2026-07-15): body moved to the engine (see StockSageIdeaProjection.rewardRisk);
    /// this thin wrapper keeps the view's 3 call sites diff-free.
    private func rewardRisk(_ idea: StockSageIdea) -> Double {
        StockSageIdeaProjection.rewardRisk(idea)
    }

    private var ideasHeader: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: mvFont18)).foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trade ideas").font(.system(size: mvFont15, weight: .semibold)).foregroundStyle(.white)
                    Text("Rules-based what / when / how-much across the \(StockSageUniverse.worldwide.count)-name analyzed universe (\(Self.worldwideEquityCount) equities), on 1-year history.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    // Honesty: say plainly whether the EV/win numbers below are measured, fitted, or
                    // assumed — right where they're read. F01/F02: keyed on the calibration METHOD,
                    // not on non-nil (an identity calibration is an assumption, not a measurement).
                    if let cal = store.convictionCalibration {
                        if cal.method == .identity {
                            Label("EV win-rates are assumed (identity floor) — conviction, capped at the conservative ~\(StockSageExpectedValue.assumedWinBandLabel) prior when the sample is too thin to validate out-of-sample, used as win% until a fit beats it out-of-sample", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: mvFont10, weight: .semibold)).foregroundStyle(DS.Palette.warningSoft)
                                .help(cal.chipHelp)
                        } else {
                            Label("EV win-rates \(cal.method == .platt ? "fitted" : "measured") from \(cal.sampleSize) realized trades (your journal, else the backtest)", systemImage: "checkmark.seal.fill")
                                .font(.system(size: mvFont10, weight: .semibold)).foregroundStyle(DS.Palette.successSoft)
                                .help(cal.chipHelp)
                        }
                    } else {
                        Label("EV win-rates are an assumed estimate — run the Strategy backtest to calibrate", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: mvFont10, weight: .semibold)).foregroundStyle(DS.Palette.warningSoft)
                            .help("Until a backtest runs, EV uses a cautious hand-set win-prob band (\(StockSageExpectedValue.assumedWinBandLabel)), not measured rates.")
                    }
                }
                Spacer()
                // EXPORT-03: sample/QA-seeded prices are indistinguishable from live once pasted —
                // hide the export entirely rather than caveat it.
                if !displayedIdeas.isEmpty && !store.isSampleData {   // matches what would actually be copied (post sort+filter)
                    Button {
                        // EXPORT-04: same batch-lookup helpers round F hoisted for the board's
                        // per-card Held/Journal lines — populates the CSV's optional trailing
                        // heldShares/closedTrades columns so the spreadsheet keeps the doubling flag.
                        let heldShares = StockSagePortfolio.holdingBySymbol(in: portfolio.positions)
                            .mapValues(\.shares)
                        let closedTrades = StockSageJournal.historyBySymbol(in: journal.trades)
                            .mapValues(\.count)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            StockSageIdeasCSV.csv(displayedIdeas, heldShares: heldShares, closedTrades: closedTrades),
                            forType: .string)
                        ideasCopied = true
                        Task { try? await Task.sleep(for: .seconds(2)); ideasCopied = false }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: ideasCopied ? "checkmark" : "doc.on.clipboard")
                                .font(.system(size: mvFont10, weight: .semibold)).contentTransition(.symbolEffect(.replace))
                            Text(ideasCopied ? "Copied" : "Copy CSV")
                                .font(.system(size: mvFont11, weight: .semibold)).contentTransition(.opacity)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(LuxPressStyle())
                    .help("Copy the ranked ideas as CSV (rank, action, conviction, stop/target, weight, rationale)")
                    .accessibilityLabel("Copy ideas board as CSV")
                }
                if store.isLoadingIdeas {
                    Button { store.cancelIdeasRefresh() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark")
                                .font(.system(size: mvFont10, weight: .semibold))
                            Text("Cancel")
                                .font(.system(size: mvFont11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(LuxPressStyle())
                    .help("Stop the in-progress ideas scan")
                    .accessibilityLabel("Cancel ideas analysis")
                }
                Button { Task { await store.refreshIdeas() } } label: {
                    HStack(spacing: 6) {
                        Group {
                            if store.isLoadingIdeas { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "wand.and.stars").font(.system(size: mvFont11, weight: .semibold)) }
                        }
                        Group {
                            if store.isLoadingIdeas, let p = store.ideasProgress, p.total > 0 {
                                Text("Loading \(p.current)/\(p.total)…")
                            } else {
                                Text(store.isLoadingIdeas ? "Analyzing…" : "Find ideas")
                            }
                        }
                        .font(.system(size: mvFont11_5, weight: .semibold)).contentTransition(.opacity)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(DS.Palette.accent, in: Capsule())
                    .shadow(color: DS.Palette.accent.opacity(0.25), radius: 4, y: 1)
                }
                .buttonStyle(LuxPressStyle()).disabled(store.isLoadingIdeas)
                .help("First scan of the day covers all \(StockSageUniverse.worldwide.count) names and takes several minutes — results stream in as they complete.")
                // POST2420-COPY item 7: this button is the ONLY progress indicator for the
                // minutes-long scan — give it an explicit label + a value that tracks "N of M"
                // as ideasProgress updates, so VoiceOver's value-change announcements carry the
                // live count instead of relying on the synthesized label alone.
                .accessibilityLabel(store.isLoadingIdeas ? "Scanning ideas" : "Find ideas")
                .accessibilityValue(store.isLoadingIdeas
                                     ? (store.ideasProgress.map { "\($0.current) of \($0.total)" } ?? "")
                                     : "")
            }
            // POST2420-COPY item 4: the "takes several minutes" expectation above previously
            // lived ONLY in a hover .help — invisible unless the user happens to hover the
            // button. Surface it as a small factual line near the progress counter for the
            // whole duration of a FULL scan (never a retry — a retry's `ideasProgress.total`
            // is `ideasMissing.count`, always well under the full universe size). Interpolates
            // the live universe count, never a literal, so it can't drift from
            // StockSageUniverse.worldwide as the universe grows.
            if store.isLoadingIdeas, let p = store.ideasProgress, p.total >= StockSageUniverse.worldwide.count {
                Text("Scanning the \(StockSageUniverse.worldwide.count)-name universe — first scan of the day takes several minutes; results stream in as they complete.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let when = store.ideasUpdated {
                // POST2420-COPY item 1(b): a re-scan already in progress must never instruct
                // the user to start one — `store.ideasIsStale` is keyed on `ideasUpdated`,
                // which only advances when the WHOLE scan commits, so mid-scan it can still
                // read stale from the PRIOR scan while a fresh one streams in. Factual
                // in-progress form instead of the "re-scan for current ideas" call-to-action.
                Text(store.isLoadingIdeas
                     ? "Last full analysis \(when.formatted(.relative(presentation: .named))) — re-scan in progress, results streaming in · ranked by \(ideaSort.label.lowercased())"
                     : (store.ideasIsStale
                        ? "⚠︎ Analyzed \(when.formatted(.relative(presentation: .named))) — over 4h old; re-scan for current ideas · ranked by \(ideaSort.label.lowercased())"
                        : "Analyzed \(Self.timeFormatter.string(from: when)) · ranked by \(ideaSort.label.lowercased())"))
                    .font(.caption2).foregroundStyle(store.isLoadingIdeas ? .secondary : (store.ideasIsStale ? DS.Palette.warningSoft : .secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // TOM disclosure (activation 2026-07-09): the seasonal month tilt is a rank INPUT the
            // user can't otherwise see — an invisible ranking factor violates the honesty floor.
            // Shown only when the EV sort is active (2026-07-09 review fix: the tilt lives in
            // rankByEV only — claiming it under velocity/conviction/R:R sorts would be the
            // inverse honesty error, disclosing an input that is NOT in effect) AND the flag is
            // on AND at least one name has seasonality data (the tilt can actually move ranks).
            if ideaSort == .ev && StockSageAdvisor.turnOfMonthEnabled && !store.seasonality.isEmpty {
                Text("Ranking includes a small seasonal month tilt (each name’s calendar-month history, capped ±0.03 rank units) — a weak, backward-looking tendency, not a forecast.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if store.scanThrottled {
                // POST2420-COPY item 2: "paused" was false — a throttle trip permanently ends
                // the scan run (recovery is the "Retry failed" button below, not an automatic
                // resume). Item 6: this banner appears mid-scan with no VoiceOver announcement
                // by default — made one accessibility element with its text as the label so a
                // screen reader user landing here hears the full sentence, and the .onChange
                // below (attached to ideasHeader's outer VStack) posts an announcement the
                // instant scanThrottled flips true, so a VoiceOver user doesn't have to be
                // focused here already to learn the scan stopped.
                Text("Scan stopped early — feed throttling; results for the names already scanned are shown. Use “Retry failed” below or re-run Find ideas.")
                    .font(.caption2).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Scan stopped early — feed throttling. Results for the names already scanned are shown. Use Retry failed below or re-run Find ideas.")
            }
            if !store.ideasMissing.isEmpty {
                let miss = store.ideasMissing
                HStack(alignment: .top, spacing: 6) {
                    // POST2420-COPY item 3: `missingAfterScan` (the source of `ideasMissing`) can't
                    // currently distinguish "fetched but failed" from "never attempted" — after a
                    // throttle trip most of the universe's misses are the latter (the scan
                    // stopped before reaching them), so "couldn't be fetched" overclaimed an attempt
                    // that didn't happen. "not analyzed this scan" is honest for both cases without
                    // adding attempted-set bookkeeping.
                    Text("⚠︎ \(store.ideas.count) priced · \(miss.count) not analyzed this scan (\(miss.prefix(3).joined(separator: ", "))\(miss.count > 3 ? "…" : "")) — ranking covers only what loaded.")
                        .font(.caption2).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { Task { await store.retryFailedIdeas() } } label: {
                        Text("Retry failed").font(.caption2.weight(.semibold)).foregroundStyle(DS.Palette.accent)
                    }
                    .buttonStyle(.plain).disabled(store.isLoadingIdeas)
                    .accessibilityLabel("Retry analyzing the \(miss.count) symbols not analyzed this scan")
                }
            }
            if let err = store.ideasError {
                Text(err).font(.caption2).foregroundStyle(DS.Palette.warningSoft)
            }
            Text(StockSageAdvisor.caveat)
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
        // POST2420-COPY item 6: VoiceOver never learned a throttle trip stopped the scan unless
        // already focused on the banner — post an announcement the instant scanThrottled flips
        // true (false→true only; a retry that resets it back to false says nothing here, the
        // banner disappearing is enough).
        .onChange(of: store.scanThrottled) { old, new in
            guard !old, new else { return }
            AccessibilityNotification.Announcement(
                "Scan stopped early due to feed throttling. Results for the names already scanned are shown."
            ).post()
        }
        // POST2420-COPY item 7: the only progress indicator for the minutes-long scan is the
        // disabled Find-Ideas button — post a completion announcement on isLoadingIdeas
        // true→false so a VoiceOver user who stepped away from the button still learns the
        // scan ended, mirroring the throttle announcement's true-edge-only gate above.
        .onChange(of: store.isLoadingIdeas) { old, new in
            guard old, !new else { return }
            AccessibilityNotification.Announcement("Ideas scan finished.").post()
        }
    }

    private func ideaCard(_ idea: StockSageIdea,
                           holdingsBySymbol: [String: AggregatedHolding],
                           historyBySymbol: [String: (count: Int, totalR: Double, rDefinedCount: Int)]) -> some View {
        let a = idea.advice
        let snapshot = StockSageDecisionSnapshotBuilder.build(
            idea: idea,
            holds: velocityHolds,
            calibration: store.convictionCalibration,
            earnings: store.earnings,
            liquidity: store.liquidity,
            account: parsedAccount ?? 10_000,
            riskFraction: parsedRiskFraction ?? 0.01,
            regime: store.regime,
            fxRatesToUSD: sizingFXRates(for: [idea.symbol]))
        let cardVM = snapshot.cardViewModel
        let earningsBadge = cardVM.earningsWarningBadge
        let hasFloorWarning = cardVM.hasFloorWarning
        // Legible reason for the earnings-aware rank: a chip when earnings are imminent/approaching.
        let earnFlag = StockSageExpectedValue.earningsRankFlag(for: idea, earnings: store.earnings)
        // At-the-extreme chip (OSS-borrow B3, Ghostfolio min/max highlight; L1 honesty fix
        // 2026-07-07): purely descriptive fact about the RAW last-N-day close window — NOT a
        // momentum/breakout claim, so it sits with the neutral badges, not the warning/opportunity
        // ones either side of it. Reads idea.recentExtreme (computed by the Store over the raw
        // closes, not the downsampled spark) so the claim is honest about the full window, not
        // just the ≤32 sampled points the sparkline draws.
        let extreme = idea.recentExtreme ?? .neither
        let extremeSpan = idea.recentExtremeSpan ?? idea.spark.count
        // "Own it" awareness (top gap, 2026-07-07 assessment): owning a name is context for
        // reading the card, never an endorsement — neutral styling like the at-extreme chip,
        // not tinted success/danger. Aggregates every lot (multi-lot books) by symbol. PERF-2/4:
        // dict lookup, not a per-card O(trades)/O(positions) filter — the caller builds the dict
        // once per render via StockSageJournal.historyBySymbol / StockSagePortfolio.holdingBySymbol.
        let held = holdingsBySymbol[idea.symbol.uppercased()]
        let jh = historyBySymbol[idea.symbol.uppercased()]
        // PERF-5: hoisted once — the chips row and the accessibility label closure below both
        // used to recompute these independently (near-doubling the card's cost). Same guard
        // chains as the render sites they replace, so this is parity by construction.
        let ev = StockSageExpectedValue.ev(for: idea, calibration: store.convictionCalibration)
        let vel = ideaSort == .velocity
            ? StockSageExpectedValue.velocity(for: idea, holds: velocityHolds, calibration: store.convictionCalibration)
            : nil
        let atRisk: PositionSize? = {
            guard let stop = a.stopPrice, let acct = StockSageInput.positiveAmount(sizerAccount),
                  let rp = StockSageInput.percent(sizerRiskPct) else { return nil }
            return sizedPosition(account: acct, riskFraction: rp / 100, symbol: idea.symbol, entry: idea.price, stop: stop)
        }()
        let hovered = hoveredIdeaID == idea.id
        // Per-card staleness — adds a clock badge when the board is stale, same TRIGGER as
        // watchlist signalCard's sym.isStale() pattern. The dim amount DELIBERATELY diverges:
        // this card dims to 0.85 (the AA floor derived below at .opacity — .secondary text
        // must clear 4.5:1), while watchlist signalCard still dims to the older 0.55 (legacy,
        // sub-AA on its own .secondary text — a known gap, tracked as its own DEFERRED
        // follow-up; different surface, own wave, no watchlist code touched here).
        // POST2420-COPY item 1: keyed on THIS card's own `generatedAt` (>4h), not the
        // board-level `store.ideasIsStale` — during a streaming scan `ideasUpdated` only
        // advances at the very end, so the old board-level key wore the stale badge on cards
        // that were just freshly merged in. Same >4h threshold, same Self.cardIsStale the
        // detail sheet's DEG-03 as-of cue reads generatedAt from. Round-3: also flags a
        // cache-served idea whose price bar (`priceAsOf`) is not from today, even when
        // `generatedAt` itself is fresh (cache-served-as-fresh honesty gap).
        let boardIsStale = Self.cardIsStale(generatedAt: idea.generatedAt, now: Date(), priceAsOf: idea.priceAsOf)
        // S3 (settle triage 2026-07-10): boardIsStale ORs two axes (analysis >4h OR price not
        // from today) but the chip/a11y wording below used to claim only the analysis axis —
        // split on the same axis D3 already uses for bestOpportunityCard/CTA (price takes
        // wording priority when both fire, mirroring the `if let staleAsOf {} else if
        // analysisStaleOnly {}` precedence there).
        let priceIsStale = Self.staleAsOfPrice(idea.priceAsOf, now: Date()) != nil
        // QA-4+F1 (density rework): ONE seam for which conditional chips are
        // visible — see IdeaChipPlan's doc for the priority order + why the
        // action badge/EV chip stay uncounted. Computed once per card; both the
        // render site below and the a11y label builder consume this SAME list,
        // so they can never desync (the prior bug: two hand-copied `chipsSoFar`
        // computations, one of which didn't even see confluence/extreme as
        // droppable).
        let visibleChips = IdeaChipPlan.visibleChips(
            stale: boardIsStale, earnings: earningsBadge != nil, floor: hasFloorWarning,
            heldOrTraded: held != nil || jh != nil, delta: store.scanDeltas[idea.symbol] != nil,
            extreme: extreme != .neither, confluence: a.timeframeAligned)
        return VStack(alignment: .leading, spacing: IdeaSpace.stack) {
            HStack(spacing: IdeaSpace.chipGap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(idea.symbol).font(.system(size: mvFont15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    // Tadawul numeric tickers are unreadable at a glance (owner, 2026-07-16):
                    // bilingual company name as a READING AID — the symbol stays the identity.
                    if let n = StockSageTadawulNames.displayLine(for: idea.symbol) {
                        Text(n).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(idea.market).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                // Badge row order: risk warnings FIRST (earnings/floor), then
                // opportunity signals (EV/confluence). Action chip is always the identity anchor.
                // Action badge has minWidth so EV chip aligns across cards.
                Text(a.action.rawValue)
                    .font(.system(size: mvFont11, weight: .bold)).foregroundStyle(actionTextColor(a.action))
                    .lineLimit(1).fixedSize()   // 440pt: "Strong Buy" must never wrap into "Strong/Buy" (narrow lens 2026-07-09)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(actionColor(a.action), in: Capsule())
                    .frame(minWidth: 74, alignment: .center)
                // Staleness badge — mirrors watchlist card pattern.
                if visibleChips.contains(.stale) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: mvFont10)).foregroundStyle(DS.Palette.warningSoft)
                        .help(priceIsStale ? "This idea's price is not from today — tap Refresh for a current read" : "This idea's analysis is over 4h old — tap Refresh for a current read")
                        .accessibilityLabel(priceIsStale ? "This idea's price is stale — not from today" : "This idea's analysis is stale — over 4 hours old")
                }
                // Risk warnings first: earnings and floor before EV.
                if visibleChips.contains(.earnings) {
                    Text(earningsBadge ?? earnFlag.badge)
                        .font(.system(size: fontChipLabel, weight: .semibold))
                        .foregroundStyle(earnFlag.isDemoted ? DS.Palette.warningSoft : .secondary)
                        .modifier(IdeaChipChrome(tint: earnFlag.isDemoted ? DS.Palette.warningSoft : DS.Palette.surfaceStroke))
                        .help(store.earnings[idea.symbol.uppercased()]?.note ?? "Upcoming earnings — binary event risk; a protective stop may gap through it.")
                }
                if visibleChips.contains(.floor) {
                    Text("costs > edge")
                        .font(.system(size: fontChipLabel, weight: .semibold))
                        .foregroundStyle(DS.Palette.warningSoft)
                        .modifier(IdeaChipChrome(tint: DS.Palette.warningSoft))
                        .help(String(format: "Net EV/day after est. costs is under %.3fR/day — de-ranked on the velocity board. See the detail sheet for the full net-cost breakdown.", StockSageExpectedValue.minNetEVPerDayFloor))
                        .accessibilityLabel("Below net-cost floor — costs exceed edge; de-ranked on velocity board")
                }
                // At-the-extreme chip: neutral descriptive fact, not a signal — deliberately
                // secondary/plain styling (no success/danger tint) so it never implies good/bad.
                // Lowest-priority-but-one in IdeaChipPlan — droppable under the cap.
                if visibleChips.contains(.extreme) {
                    Text(extreme == .atHigh ? "At \(extremeSpan)-day high" : "At \(extremeSpan)-day low")
                        .font(.system(size: fontChipLabel, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .modifier(IdeaChipChrome(tint: DS.Palette.surfaceStroke))
                        .help("Latest close is the highest/lowest of the last \(extremeSpan) daily closes — context, not a buy/sell signal.")
                        .accessibilityLabel(extreme == .atHigh ? "At the high of the last \(extremeSpan) days" : "At the low of the last \(extremeSpan) days")
                }
                // "Own it" / "Your history with this name" chips (2026-07-07 fix round, issue
                // #1): six chips garbled mid-word at 560pt ("Backtes/t" defect class — see
                // incident-ledger). When BOTH held and traded context exist, merge into ONE
                // combined neutral chip — ONE slot in IdeaChipPlan regardless of which of the
                // three renders below. Still neutral/display-only, never part of ranking.
                if visibleChips.contains(.heldOrTraded), let held, let jh {
                    let rNote = jh.rDefinedCount != jh.count ? " (R defined on \(jh.rDefinedCount))" : ""
                    Text("Held · \(numString(held.shares)) sh · \(jh.count)x")
                        .font(.system(size: fontChipLabel, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .modifier(IdeaChipChrome(tint: DS.Palette.surfaceStroke))
                        .help(String(format: "You hold %@ shares @ %@ (avg cost). Your journal: %d closed trades on %@, realized %+.1fR total%@. Context only — not part of ranking.", numString(held.shares), adaptivePrice(held.costBasis), jh.count, idea.symbol, jh.totalR, rNote))
                        .accessibilityLabel(String(format: "You hold %@ shares of %@ at an average cost of %@. Your journal: %d closed trades, realized %+.1fR total%@. Context only, not part of ranking.", numString(held.shares), idea.symbol, adaptivePrice(held.costBasis), jh.count, jh.totalR, rNote))
                } else if visibleChips.contains(.heldOrTraded), let held {
                    Text("Held · \(numString(held.shares)) sh")
                        .font(.system(size: fontChipLabel, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .modifier(IdeaChipChrome(tint: DS.Palette.surfaceStroke))
                        .help("You hold \(numString(held.shares)) shares @ \(adaptivePrice(held.costBasis)) (avg cost). Context only — not part of ranking.")
                        .accessibilityLabel("You hold \(numString(held.shares)) shares of \(idea.symbol) at an average cost of \(adaptivePrice(held.costBasis)). Context only, not part of ranking.")
                } else if visibleChips.contains(.heldOrTraded), let jh {
                    let rNote = jh.rDefinedCount != jh.count ? " (R defined on \(jh.rDefinedCount))" : ""
                    Text("Traded \(jh.count)x")
                        .font(.system(size: fontChipLabel, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .modifier(IdeaChipChrome(tint: DS.Palette.surfaceStroke))
                        .help(String(format: "Your journal: %d closed trades on %@, realized %+.1fR total%@. Context only — not part of ranking.", jh.count, idea.symbol, jh.totalR, rNote))
                        .accessibilityLabel(String(format: "Your journal: %d closed trades on %@, realized %+.1fR total%@. Context only, not part of ranking.", jh.count, idea.symbol, jh.totalR, rNote))
                }
                // Scan-delta chip ("New" / "was <Action>", PLAN_2026-07-07_scan_deltas.md):
                // visibility now comes solely from IdeaChipPlan (single seam, see above).
                if visibleChips.contains(.delta), let delta = store.scanDeltas[idea.symbol] {
                    let label: String = {
                        switch delta {
                        case .new: return "New"
                        case .actionChanged(let previous): return "was \(previous)"
                        }
                    }()
                    Text(label)
                        .font(.system(size: fontChipLabel, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .modifier(IdeaChipChrome(tint: DS.Palette.surfaceStroke))
                        .help(delta == .new
                              ? "New on the board since the last full scan — wasn't in the ranked ideas before."
                              : "The action changed since the last full scan.")
                        .accessibilityLabel(delta == .new
                              ? "New on the board since the last full scan"
                              : label)
                }
                // Opportunity signals after warnings.
                // "(gross)" label — consistent with fast-lane row.
                // monospacedDigit + minWidth so EV aligns across cards.
                if let ev, let evText = cardVM.evText {
                    Text(evText)
                        .font(.system(size: fontChipLabel, weight: .semibold).monospacedDigit())
                        .foregroundStyle(ev.isPositive ? DS.Palette.successSoft : DS.Palette.warningSoft)
                        .modifier(IdeaChipChrome(tint: ev.isPositive ? DS.Palette.successSoft : DS.Palette.warningSoft))
                        .frame(minWidth: 72, alignment: .trailing)
                        // T12 (rotation-3 triage): "frictions" was the last straggler — every
                        // other surface (StockSageKelly/NetEdge/TodayPlan/etc.) already says
                        // "round-trip costs" (993bdce), not "frictions".
                        .help("Gross EV — before est. round-trip costs. The detail sheet's Evidence section shows gross + net velocity, and the net-cost breakdown. Conviction→win-prob estimate × reward:risk. An estimate, not a forecast.")
                }
                if visibleChips.contains(.confluence) {
                    // RANKING_BACKLOG #12 (reframed, pure observer) — display-only badge, never a
                    // ranking input; see StockSageIndicators.timeframeConfluence. The engine only
                    // ever sets timeframeAligned for a buy- or sell-family action (StockSageAdvisor
                    // gates it on isBuy/isSell), so a.action alone tells us the direction — tint
                    // matches actionColor's own bullish/bearish convention (2026-07-01 fix: this
                    // badge used to be hardcoded green even for a bearish-aligned Sell/Reduce card).
                    // QA-4+F1: confluence now JOINS IdeaChipPlan's counted set (lowest priority) —
                    // it used to render unconditionally, uncapped.
                    let bearish = a.action == .sell || a.action == .reduce
                    Text("3-TF confluence")
                        .font(.system(size: fontChipLabel, weight: .semibold))
                        .foregroundStyle(bearish ? DS.Palette.dangerSoft : DS.Palette.successSoft)
                        .modifier(IdeaChipChrome(tint: bearish ? DS.Palette.dangerSoft : DS.Palette.successSoft))
                        .help(a.confluenceNote ?? "1-month, daily, and 1-year trends all agree — a breadth read, not a probability of profit.")
                        .accessibilityLabel(a.confluenceNote ?? "Three-timeframe confluence")
                }
                // Execution-timing note: surfaced in the rationale strip (first two bullets via
                // StockSageStore.buildIdeas) and in the detail sheet "Why". The inline badge was
                // removed: it fired on ~60-80% of buy cards in trending regimes, making
                // it near-zero differential information while crowding the badge row. Information
                // is NOT dropped — StockSageExecutionTiming and buildIdeas wiring are unchanged.
                if a.targetPrice != nil || a.stopPrice != nil {
                Menu {
                    // Direction derives from where the level sits vs the CURRENT price — a
                    // sell/reduce (short) idea's target is BELOW and stop ABOVE, so hardcoding
                    // .above/.below would create alerts that are already met (fire a meaningless
                    // notification immediately, disarm) while the REAL level-cross never notifies.
                    if let t = a.targetPrice {
                        let dir: PriceAlert.Direction = t > idea.price ? .above : .below
                        Button { store.addPriceAlert(symbol: idea.symbol, target: t, direction: dir) } label: {
                            Label("Alert \(dir.symbol) \(adaptivePrice(t)) (target)", systemImage: "target")
                        }
                    }
                    if let s = a.stopPrice {
                        let dir: PriceAlert.Direction = s > idea.price ? .above : .below
                        Button { store.addPriceAlert(symbol: idea.symbol, target: s, direction: dir) } label: {
                            Label("Alert \(dir.symbol) \(adaptivePrice(s)) (stop)", systemImage: "shield.lefthalf.filled")
                        }
                    }
                    // (no "alert at current price" — it would be already-met and fire immediately)
                } label: {
                    Image(systemName: "bell.badge")
                        .font(.system(size: mvFont12, weight: .semibold)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Set a price alert for \(idea.symbol)")
                .accessibilityLabel("Set a price alert for \(idea.symbol)")
                }
                Button { Task { await store.runBacktest(symbol: idea.symbol) } } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: mvFont12, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(LuxPressStyle()).disabled(store.isBacktesting)
                .help("Backtest \(idea.symbol) over 5 years")
                .accessibilityLabel("Backtest \(idea.symbol)")
            }
            signalBlocks(a.conviction, color: actionColor(a.action))
                // F01/F02: wording keyed on the calibration METHOD — identity must read "assumed".
                .help(store.convictionCalibration.map { cal in
                    cal.method == .identity
                    ? "Signal strength — a rules-based score; win-rate currently ASSUMED — conviction, capped at the conservative ~\(StockSageExpectedValue.assumedWinBandLabel) prior when the sample is too thin to validate out-of-sample, is used as the win probability (identity floor), not measured from outcomes."
                    : "Signal strength — a rules-based score; win-rate \(cal.method == .platt ? "fitted" : "measured") from \(cal.sampleSize) realized trades."
                } ?? "Signal strength — a rules-based score, not a probability. Estimated win-rate range ~\(StockSageExpectedValue.assumedWinBandLabel), not a forecast.")
            if idea.spark.count >= 2 {
                Sparkline(values: idea.spark)
                    .stroke(sparkColor(idea.spark),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(height: 22)
                    .opacity(0.9)
                    .accessibilityHidden(true)
            }
            HStack(spacing: IdeaSpace.chipGap) {
                // When sorted by velocity, show the sort key first so the
                // user can compare #3 vs #5 without opening the detail sheet.
                if ideaSort == .velocity, let vel {
                    ideaMetric("Vel.", String(format: "%+.3fR/d", vel), color: DS.Palette.successSoft)
                        // T14 (rotation-3 triage): "net-adjusted growth rate (costs + variance
                        // haircuts)" named the same ordering key the fastLane hover
                        // (StockSageGlossary.explain(.fastLane)) already names precisely —
                        // align on that naming instead of a second, divergent description.
                        .help("Gross EV/day. The board ORDERS by per-day log-growth at ½-Kelly, cost-haircut, which can differ — two cards with similar gross Vel. may rank apart.")
                }
                // F-round-j FIX 2: per-idea provenance tag, subtle caption under the price —
                // reuses the SAME isSampleData/loadedFromCache truth the top banner keys on, so
                // it can never contradict it; live path ages THIS symbol's own priceAsOf.
                if let src = Self.sourceTagLabel(isSampleData: store.isSampleData, loadedFromCache: store.loadedFromCache, priceAsOf: idea.priceAsOf, now: Date()) {
                    ideaMetric("Price", adaptivePrice(idea.price), sub: src, subColor: .secondary)
                } else {
                    ideaMetric("Price", adaptivePrice(idea.price))
                }
                if let stop = a.stopPrice, idea.price > 0 {
                    // Stop distance % in parentheses — glanceable risk without
                    // opening the sheet. price > 0 guard matches rewardRisk()'s own pattern — a
                    // malformed zero price must not render "(inf%)"/"(nan%)".
                    // VO/edge lens 2026-07-09: sign from DIRECTION, not a hardcoded '−' — a
                    // sell-family stop sits ABOVE entry (+x.x% away); the hardcoded minus claimed
                    // the adverse move was downward for shorts.
                    ideaMetric("Stop", adaptivePrice(stop), color: DS.Palette.dangerSoft,
                               sub: String(format: "%+.1f%% away", (stop - idea.price) / idea.price * 100), subColor: DS.Palette.dangerSoft)
                } else if let stop = a.stopPrice {
                    ideaMetric("Stop", adaptivePrice(stop), color: DS.Palette.dangerSoft)
                }
                // B1 (OSS-borrow, FreqUI TradeDetail "At risk"): the $ LOST if the stop fills —
                // same guard chain + same sizer call as bestOpportunityCard's "Size it now" line
                // (line ~3563) so this can never diverge from the shipped sizer's math. nil on
                // any unparseable/missing input ⇒ nothing new renders.
                if let stop = a.stopPrice, let ps = atRisk, let acct = StockSageInput.positiveAmount(sizerAccount) {
                    ideaMetric("At risk", "\(approxAmount(ps.dollarsAtRisk, symbol: idea.symbol)) · \(ps.shares) sh", color: DS.Palette.warningSoft)
                        .help("Sizes the LOSS: a stop-out at \(adaptivePrice(stop)) costs ~\(approxAmount(ps.dollarsAtRisk, symbol: idea.symbol).dropFirst()) (\(String(format: "%.2f", (usdAmount(ps.dollarsAtRisk, symbol: idea.symbol) ?? ps.dollarsAtRisk) / acct * 100))% of the account). Not a profit promise.")
                }
                if let target = a.targetPrice {
                    ideaMetric("Target", adaptivePrice(target), color: DS.Palette.successSoft)
                }
                if a.suggestedWeight > 0 {
                    // "Base size" — the raw half-Kelly before regime/vol adjustments.
                    ideaMetric("Base size", String(format: "%.1f%%", a.suggestedWeight * 100), color: DS.Palette.accent)
                        .help(Self.sizeMetricHelp)
                    // Vol-adj size when the brake materially cuts size (>15% cut).
                    // Label is "Vol-adj" — NOT "Effective" or "Final"; the Deploy plan still layers
                    // regime bias and correlation cuts on top, so this remains an intermediate step.
                    // nil volRegime → show nothing (honesty floor: no fabricated multiplier).
                    if let vr = idea.volRegime, vr.sizingMultiplier < 0.85 {
                        ideaMetric("Vol-adj", String(format: "%.1f%%", a.suggestedWeight * vr.sizingMultiplier * 100), color: DS.Palette.warningSoft)
                    }
                }
                let rr = rewardRisk(idea)
                if rr > 0 {
                    ideaMetric("R:R", String(format: "%.1f", rr))
                }
                // Momentum dot on the main card, same logic as fastLaneRow.
                // nil momentumQuality → show nothing (honesty floor preserved).
                if let mq = idea.momentumQuality {
                    let mqHot   = mq >= 2.0 / 3.0
                    let mqMixed = mq >= 1.0 / 3.0
                    let mqColor = mqHot ? DS.Palette.successSoft : mqMixed ? DS.Palette.warningSoft : DS.Palette.dangerSoft
                    let mqLabel = mqHot ? "hot" : mqMixed ? "mixed" : "cold"
                    HStack(spacing: 3) {
                        Circle().fill(mqColor).frame(width: 5, height: 5)
                        Text(mqLabel).font(.system(size: mvFont8)).foregroundStyle(mqColor)
                    }
                    .help("Momentum read: ER trend + MACD histogram + 21-day return — short histories may use fewer than 3 signals. A 1-day blip is not a 3-12d win. Descriptive, not predictive.")
                }
                Spacer(minLength: 0)
            }
            // Rationale first, regime token last — regime provides context
            // but action badge already carries the directional signal; the first rationale bullet
            // is the most actionable skip/open signal and deserves the first fixation.
            // lineLimit(2) is a deliberate board-density clamp — but a clamped bullet must
            // never be UNREACHABLE (2026-07-09, harvested Copilot HELD finding #3): the full
            // rationale (all bullets, not just the displayed prefix(2)) is one hover away.
            Text(a.rationale.prefix(2).joined(separator: " · ") + " · " + a.regime.rawValue)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .help(a.rationale.joined(separator: "\n") + "\n\nRegime: " + a.regime.rawValue)
        }
        .padding(IdeaSpace.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(boardIsStale ? 0.85 : 1.0)   // dim stale cards — 0.85 keeps .secondary text ≥4.5:1 AA (was 0.75 → 3.84:1); clock badge + a11y label + help still carry staleness
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(hovered ? Color.white.opacity(0.055) : DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(hovered ? DS.Palette.accent.opacity(0.35) : DS.Palette.surfaceStroke, lineWidth: 1))
        // Leading accent whose intensity scales with conviction — high-conviction ideas
        // stand out at a glance (EV is ~uniform because targets are pinned ~2:1).
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(actionColor(a.action).opacity(0.25 + 0.75 * a.conviction))
                .frame(width: 3).padding(.vertical, 8)
                .accessibilityHidden(true)
        }
        .scaleEffect(hovered ? 1.008 : 1.0)
        .shadow(color: DS.Palette.accent.opacity(hovered ? 0.10 : 0), radius: 10, y: 3)
        .animation(DS.Motion.smooth, value: hovered)
        // One combined, activatable element (mirrors the watchlist card): the
        // custom label carries the conviction, the DEFAULT action opens the detail
        // sheet (VoiceOver double-tap), and Backtest is a named rotor action — so
        // both stay reachable WITHOUT losing the summary (the `.contain` attempt
        // dropped the label and left the tap non-activatable).
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel({ () -> String in
            var label = "\(idea.symbol), \(a.action.rawValue), signal strength: \(Self.signalBlockCount(a.conviction)) of 5 signal blocks, rules-based, not a probability"
            switch earnFlag {
            case .demoted(let d):     label += ", earnings imminent in about \(d) days — demoted in the rank"
            case .approaching(let d): label += ", earnings approaching in about \(d) days"
            case .clear, .unknown:    break
            }
            // The explicit label on a .combine element REPLACES the synthesized child labels,
            // so the staleness clock badge's own accessibilityLabel is never spoken — convey
            // it here (the opacity dimming is invisible to VoiceOver too).
            if boardIsStale { label += priceIsStale ? ", this idea's price is not from today" : ", this idea's analysis is over 4 hours old" }
            // A11Y-01 (2026-07-07 fix round; QA-4+F1 2026-07-07 fix round): every remaining
            // badge/chip/metric below this element is also silenced by .combine — mirror EACH
            // render condition above in the SAME order they appear on screen, reusing the
            // visible strings/help wording. Gates now come from `visibleChips` — the SAME list
            // the render site above built — so this can never claim a chip the card dropped for
            // density (the bug this fix closes: two independently hand-copied computations).
            if hasFloorWarning { label += ", below net-cost floor, de-ranked" }
            if visibleChips.contains(.extreme) {
                label += extreme == .atHigh ? ", at \(extremeSpan)-day high" : ", at \(extremeSpan)-day low"
            }
            if visibleChips.contains(.heldOrTraded), let held, let jh {
                let rNote = jh.rDefinedCount != jh.count ? " (R defined on \(jh.rDefinedCount))" : ""
                label += ", " + String(format: "you hold %@ shares of %@ at an average cost of %@. Your journal: %d closed trades, realized %+.1fR total%@. Context only, not part of ranking.", numString(held.shares), idea.symbol, adaptivePrice(held.costBasis), jh.count, jh.totalR, rNote)
            } else if visibleChips.contains(.heldOrTraded), let held {
                label += ", you hold \(numString(held.shares)) shares of \(idea.symbol) at an average cost of \(adaptivePrice(held.costBasis)). Context only, not part of ranking."
            } else if visibleChips.contains(.heldOrTraded), let jh {
                let rNote = jh.rDefinedCount != jh.count ? " (R defined on \(jh.rDefinedCount))" : ""
                label += ", " + String(format: "your journal: %d closed trades on %@, realized %+.1fR total%@. Context only, not part of ranking.", jh.count, idea.symbol, jh.totalR, rNote)
            }
            if visibleChips.contains(.delta), let delta = store.scanDeltas[idea.symbol] {
                switch delta {
                case .new: label += ", new this scan"
                case .actionChanged(let previous): label += ", was \(previous)"
                }
            }
            if let evText = cardVM.evText, ev != nil {
                label += ", " + evText.replacingOccurrences(of: " (gross)", with: " gross")
            }
            if visibleChips.contains(.confluence) {
                label += ", " + (a.confluenceNote ?? "three-timeframe confluence")
            }
            if ideaSort == .velocity, let vel {
                label += String(format: ", velocity %+.3fR per day", vel)
            }
            label += ", price \(adaptivePrice(idea.price))"
            // S4 (settle triage 2026-07-10, A11Y-01 contract): round-J's per-idea source tag
            // ("Yahoo · 31m" / "cached · 3h" / "sample") is pixels-only — this .combine element's
            // explicit label replaces every child label, so VoiceOver never heard it. Reuses the
            // SAME call the render site makes (~3746) so it can never desync from the pixels.
            if let src = Self.sourceTagLabel(isSampleData: store.isSampleData, loadedFromCache: store.loadedFromCache, priceAsOf: idea.priceAsOf, now: Date()) {
                label += " (\(src))"
            }
            if let stop = a.stopPrice, idea.price > 0 {
                let stopPct = abs(idea.price - stop) / idea.price * 100
                label += ", stop \(adaptivePrice(stop)) (\(String(format: "%.1f%%", stopPct)))"
            } else if let stop = a.stopPrice {
                label += ", stop \(adaptivePrice(stop))"
            }
            if let ps = atRisk {
                label += ", at risk \(approxAmount(ps.dollarsAtRisk, symbol: idea.symbol)), \(ps.shares) shares"
            }
            if let target = a.targetPrice {
                label += ", target \(adaptivePrice(target))"
            }
            if a.suggestedWeight > 0 {
                label += String(format: ", base size %.1f%%", a.suggestedWeight * 100)
                if let vr = idea.volRegime, vr.sizingMultiplier < 0.85 {
                    label += String(format: ", vol-adjusted size %.1f%%", a.suggestedWeight * vr.sizingMultiplier * 100)
                }
            }
            let rr = rewardRisk(idea)
            if rr > 0 { label += String(format: ", reward to risk %.1f", rr) }
            if let mq = idea.momentumQuality {
                let mqLabel = mq >= 2.0 / 3.0 ? "hot" : mq >= 1.0 / 3.0 ? "mixed" : "cold"
                label += ", momentum \(mqLabel)"
            }
            // C1 wave: the explicit label silences all child text, which had dropped the
            // rationale entirely — including engine-appended ⚠ honesty notes (left-tail,
            // erratic vol, vol-regime brake) that live ONLY in rationale. Speak the first
            // bullet plus every ⚠ bullet (deduped), mirroring the sheet's "Why:".
            if let first = a.rationale.first { label += ". Why: \(first)" }
            for warn in a.rationale.dropFirst() where warn.hasPrefix("⚠") { label += ". \(warn)" }
            return label
        }())
        .accessibilityHint("Opens full advice and backtest")
        .accessibilityAction { selectedIdea = idea }
        .accessibilityAction(named: "Backtest") { Task { await store.runBacktest(symbol: idea.symbol) } }
        .accessibilityAction(named: "Set price alert") {
            // Same level-vs-price direction rule as the alert Menu — hardcoded .above/.below
            // creates already-met (instantly dead) alerts on sell/reduce (short) ideas.
            if let t = a.targetPrice { store.addPriceAlert(symbol: idea.symbol, target: t, direction: t > idea.price ? .above : .below) }
            else if let s = a.stopPrice { store.addPriceAlert(symbol: idea.symbol, target: s, direction: s > idea.price ? .above : .below) }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedIdea = idea }
        .onHover { over in
            withAnimation(DS.Motion.smooth) {
                if over { hoveredIdeaID = idea.id }
                else if hoveredIdeaID == idea.id { hoveredIdeaID = nil }
            }
        }
        .contextMenu {
            Button { copyIdeaPlan(idea) } label: { Label("Copy trade plan", systemImage: "doc.on.clipboard") }
            Button { selectedIdea = idea } label: { Label("Open details", systemImage: "info.circle") }
            if a.targetPrice != nil || a.stopPrice != nil { Divider() }
            // Same level-vs-price direction rule as the alert Menu (see comment there).
            if let t = a.targetPrice {
                let dir: PriceAlert.Direction = t > idea.price ? .above : .below
                Button { store.addPriceAlert(symbol: idea.symbol, target: t, direction: dir) } label: {
                    Label("Alert \(dir.symbol) target", systemImage: "target")
                }
            }
            if let s = a.stopPrice {
                let dir: PriceAlert.Direction = s > idea.price ? .above : .below
                Button { store.addPriceAlert(symbol: idea.symbol, target: s, direction: dir) } label: {
                    Label("Alert \(dir.symbol) stop", systemImage: "shield.lefthalf.filled")
                }
            }
        }
        .help("Tap for full advice + backtest · right-click to copy the plan or set an alert")
    }

    /// Copy the full honest trade plan for an idea to the clipboard.
    /// Honesty-floor fix: replaces the former hand-rolled one-liner that omitted
    /// the caveat, the net R:R, the pre-trade gate verdict, risk flags, and the "not a
    /// win probability" disclaimer. Now routes through the same fullPlanText(for:) helper
    /// the sheet's Copy-plan button uses — the card export can never disagree with the sheet.
    private func copyIdeaPlan(_ idea: StockSageIdea) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullPlanText(for: idea), forType: .string)
    }

    // Signal alerts — opt-in event log of flips / stop / target crossings.
    private var alertsPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "bell.badge.fill").font(.system(size: mvFont16)).foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signal alerts").font(DS.Typography.titleM).foregroundStyle(.white)
                    Text("Flags when an idea turns bullish/bearish or its price crosses the advised stop or target — between refreshes.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $store.alertsEnabled).labelsHidden().toggleStyle(.switch).tint(DS.Palette.accent)
            }
            if !store.alertsEnabled {
                Text("Off — turn on, then refresh ideas to start detecting events. Events fire on a crossing, so they don't repeat every refresh.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if store.alerts.isEmpty {
                Text("On — no events yet. They'll appear here when an idea flips or a stop/target is crossed on a future refresh.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(store.alerts.prefix(12).enumerated()), id: \.offset) { _, alert in
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: alertIcon(alert.kind))
                            .font(.system(size: mvFont11)).foregroundStyle(alert.isWarning ? DS.Palette.dangerSoft : DS.Palette.successSoft)
                            .frame(width: 14)
                        Text(alert.symbol).font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 64, alignment: .leading).lineLimit(1)
                        Text(alert.kind.rawValue).font(.caption2)
                            .foregroundStyle(alert.isWarning ? DS.Palette.dangerSoft : DS.Palette.successSoft)
                            .frame(width: 86, alignment: .leading)
                        Text(alert.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                Button { store.clearAlerts() } label: {
                    Text("Clear").font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    private func alertIcon(_ kind: IdeaAlert.Kind) -> String {
        switch kind {
        case .flipBullish: return "arrow.up.right.circle.fill"
        case .flipBearish: return "arrow.down.right.circle.fill"
        case .stopBreach:  return "exclamationmark.triangle.fill"
        case .targetHit:   return "target"
        }
    }

    // Best opportunity now — the single highest positive-EV buy idea (money velocity).
    @ViewBuilder private var bestOpportunityCard: some View {
        if let best = StockSageExpectedValue.bestOpportunity(store.ideas, regime: store.regime, earnings: store.earnings, liquidity: store.liquidity, seasonality: store.seasonality, calibration: store.convictionCalibration) {
            let idea = best.idea, ev = best.ev
            // D1 (2026-07-16 review): on the Ideas tab THIS card is the crown surface (the
            // bestOpportunityCTA is hidden here, section != .ideas), so it — not the CTA — must
            // carry the F8 crown-divergence disclosure when Today's plan #1 (fastest net EV/day,
            // equities-first) names a different symbol than this highest-gross-EV pick. Same
            // inputs (incl. the FX-adjusted rankedActions call) the CTA and todaysActionsCard use.
            let todayFirstSymbol = StockSageTodayPlan.rankedActions(
                store.ideas, account: StockSageInput.positiveAmount(sizerAccount),
                riskFraction: StockSageInput.percent(sizerRiskPct).map { $0 / 100 },
                holds: velocityHolds, calibration: store.convictionCalibration, marketRegime: store.regime,
                earnings: store.earnings, liquidity: store.liquidity,
                positions: portfolio.positions, journalTrades: journal.trades,
                mode: .equityExecutableFirst, max: 1,
                fxRatesToUSD: sizingFXRates(for: store.ideas.map(\.symbol))).first?.symbol
            let crownDivergenceSuffix = (todayFirstSymbol != nil && todayFirstSymbol != idea.symbol)
                ? " Today's plan leads with \(todayFirstSymbol!) — different lens." : ""
            // Round-H: this card presents a sized, placeable order (Entry/Stop/Target + "Size it
            // now") off `idea.price`, which can be a cache-served prior-UTC-day close even when
            // the scan itself just ran — same gap the board card (`Self.cardIsStale`) and detail
            // sheet (`Self.staleAsOfPrice`) already close. Computed once, reused by the visible
            // line below and folded into orderLabel for VoiceOver.
            let staleAsOf = Self.staleAsOfPrice(idea.priceAsOf, now: Date())
            // D3 (rotation-3 triage): upgrade to the two-axis `cardIsStale` (price OR analysis
            // >4h old) the board card already uses — a fresh price bar can still ride a stale
            // ANALYSIS (the advice/EV numbers were computed >4h ago and the tape has moved since).
            // `cardIsStale` = analysisStale || priceStale; `staleAsOf` above is non-nil exactly
            // when priceStale, so "stale overall but staleAsOf nil" isolates the analysis-only
            // axis without duplicating cardIsStale's internals.
            let cardIsStaleOverall = Self.cardIsStale(generatedAt: idea.generatedAt, now: Date(), priceAsOf: idea.priceAsOf)
            let analysisStaleOnly = cardIsStaleOverall && staleAsOf == nil
            // F7 (rotation-3 triage): first-ever scan only — see firstScanProgressCaption's doc.
            let firstScanCaption = Self.firstScanProgressCaption(isLoadingIdeas: store.isLoadingIdeas, ideasUpdated: store.ideasUpdated, progress: store.ideasProgress)
            // Gate verdict ON the prescriptive card (hierarchy lens HIGH, 2026-07-09): the card's
            // own copied plan already prints "Gate: <verdict>" — the pixels must not be less
            // honest than the export. Honest-nil (F04): no chip when risk % isn't set.
            let cardGate: TradeGateVerdict? = parsedRiskFraction != nil
                ? tradeGateVerdict(for: idea, inputs: tradeGateInputs(for: idea)) : nil
            // PERF: netEVR feeds both the visible sub metric and the spoken label — once.
            let cardNetEV = StockSageExpectedValue.netEVR(for: idea, calibration: store.convictionCalibration)
            // Spoken full order (precomputed OUTSIDE the ViewBuilder so the multi-clause concat does
            // not tip the card body over the type-checker budget). Earnings warning and over-size
            // caveat are folded in here so VoiceOver hears them (the .accessibilityLabel below
            // collapses the Button to one leaf, silencing the inner per-Text labels).
            let orderLabel: String = {
                var s = "Best opportunity: \(idea.symbol), \(idea.advice.action.rawValue), estimated EV \(String(format: "%.2f", ev.evR)) R gross, entry \(adaptivePrice(idea.price))"
                if let stop = idea.advice.stopPrice { s += ", stop \(adaptivePrice(stop))" }
                if let target = idea.advice.targetPrice { s += ", target \(adaptivePrice(target))" }
                // F-review fix (2026-07-10, S5): no trailing period on either clause — every
                // successor below prepends its own ". " separator (same class as the
                // crown-divergence hasSuffix(".") fix a few lines down); a trailing period here
                // doubled up into "..".
                if let staleAsOf {
                    s += ". Price as of \(staleAsOf.formatted(.relative(presentation: .named))) — not live; re-price before ordering"
                } else if analysisStaleOnly {
                    s += ". Analysis over 4h old — re-scan for a current read"
                }
                if let firstScanCaption { s += ". \(firstScanCaption)" }
                if let ep = store.earnings[idea.symbol.uppercased()], ep.isWarning {
                    s += ". Earnings risk: \(ep.note)"
                }
                if let stop = idea.advice.stopPrice, let acct = StockSageInput.positiveAmount(sizerAccount),
                   let rp = StockSageInput.percent(sizerRiskPct),
                   let ps = sizedPosition(account: acct, riskFraction: rp / 100, symbol: idea.symbol, entry: idea.price, stop: stop),
                   pctOfAccountUSD(ps, symbol: idea.symbol, account: acct) > 100 {   // wave-2 #2: USD-correct, no false leverage
                    s += ". Size warning: position exceeds account balance."
                }
                if let g = cardGate {
                    s += ". Pre-trade gate: \(g.decision == .blocked ? "do not trade" : g.decision.rawValue)."
                }
                // VO walk 2026-07-09: the label override silences every child Text — the net
                // estimate, the sized order (the CTA used to speak it on this tab before the
                // dedup), and the tilt disclosure must be IN the label or they are pixels-only.
                if let net = cardNetEV {
                    s += String(format: ", about %+.2f R net estimated", net)
                }
                if let stop = idea.advice.stopPrice, let acct = StockSageInput.positiveAmount(sizerAccount),
                   let rp = StockSageInput.percent(sizerRiskPct),
                   let ps = sizedPosition(account: acct, riskFraction: rp / 100, symbol: idea.symbol, entry: idea.price, stop: stop) {
                    s += ". Size it now: \(StockSagePositionSizer.summaryLine(ps, riskPct: rp, symbol: idea.symbol, pctOverride: pctOfAccountUSD(ps, symbol: idea.symbol, account: acct)))"
                }
                if !tomTiltDisclosureSuffix.isEmpty {
                    s += ". Ranking includes a small seasonal month tilt."
                }
                // D1: same crown-divergence disclosure the CTA speaks — suffix carries its own
                // leading space + trailing period; add one separator only if `s` lacks it.
                if !crownDivergenceSuffix.isEmpty {
                    if !s.hasSuffix(".") { s += "." }
                    s += crownDivergenceSuffix
                }
                return s
            }()
            VStack(alignment: .leading, spacing: 6) {
            Button { selectedIdea = idea } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: "bolt.fill").font(.system(size: mvFont13)).foregroundStyle(DS.Palette.accent)
                        Text("Best opportunity now").font(.system(size: mvFont12, weight: .bold)).foregroundStyle(.white)
                        if let g = cardGate {
                            Text(g.decision == .blocked ? "DO NOT TRADE" : g.decision.rawValue.uppercased())
                                .font(.system(size: mvFont9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(g.decision == .blocked ? DS.Palette.danger
                                            : (g.decision == .caution ? DS.Palette.warningSoft.opacity(0.85) : DS.Palette.successSoft.opacity(0.85)),
                                            in: Capsule())
                                .lineLimit(1).fixedSize()
                        }
                        Spacer()
                        calibrationChip   // is the green Est. EV / Win est. below measured or assumed?
                        Text(idea.advice.action.rawValue).font(.system(size: mvFont10, weight: .bold))
                            .foregroundStyle(actionTextColor(idea.advice.action))
                            .padding(.horizontal, 7).padding(.vertical, 2).background(actionColor(idea.advice.action), in: Capsule())
                    }
                    // F7 (rotation-3 triage): this card's "best" is provisional during the
                    // first-ever scan — say so, folded into orderLabel above for VoiceOver.
                    if let firstScanCaption {
                        Text(firstScanCaption)
                            .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: DS.Space.sm) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(idea.symbol).font(.system(size: mvFont16, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            if let n = StockSageTadawulNames.displayLine(for: idea.symbol) {
                                Text(n).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        ideaMetric("Est. EV", String(format: "%+.2fR (gross)", ev.evR),
                                   color: DS.Palette.successSoft,
                                   sub: cardNetEV.map { String(format: "≈%+.2fR net est.", $0) },
                                   subColor: .secondary)
                            .help(StockSageGlossary.explain(.ev))
                        ideaMetric("R:R (gross)", String(format: "%.1f:1", ev.rewardR))
                            .help("Gross reward:risk from entry/stop/target, before est. costs — the pre-trade gate evaluates the NET ratio; the ranked rows below flag when net R:R falls under 2:1.")
                        ideaMetric("Win est.", String(format: "~%.0f%%", ev.winProbEstimate * 100))
                        if idea.advice.suggestedWeight > 0 {
                            // "Base size" — raw half-Kelly before regime/vol adjustments.
                            ideaMetric("Base size", String(format: "%.1f%%", idea.advice.suggestedWeight * 100))
                                .help(Self.sizeMetricHelp)
                        }
                        Spacer(minLength: 0)
                    }
                    // Imminent-earnings warning (now that earnings are fed to the boards): a #1 pick
                    // reporting in days can gap through a protective stop — say so on the headline card.
                    if let ep = store.earnings[idea.symbol.uppercased()], ep.isWarning {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "calendar.badge.exclamationmark").font(.system(size: mvFont11))
                                .foregroundStyle(ep.severity == .imminent ? DS.Palette.dangerSoft : DS.Palette.warningSoft)
                            Text(ep.note).font(.caption2)
                                .foregroundStyle(ep.severity == .imminent ? DS.Palette.dangerSoft : DS.Palette.warningSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityHidden(true)  // folded into orderLabel above so VoiceOver reads it once
                    }
                    // The actual order levels, so the card is a placeable order, not just a verdict.
                    HStack(spacing: DS.Space.sm) {
                        ideaMetric("Entry", adaptivePrice(idea.price))
                        if let stop = idea.advice.stopPrice {
                            if idea.price > 0 {
                                // Signed distance-to-invalidation: raw (stop/price − 1)×100 — negative
                                // for longs (stop below price), positive for shorts (stop above). No abs().
                                let stopDistPct = (stop / idea.price - 1) * 100
                                ideaMetric("Stop", "\(adaptivePrice(stop)) (\(String(format: "%+.1f%%", stopDistPct)) to stop)", color: DS.Palette.dangerSoft)
                            } else {
                                ideaMetric("Stop", adaptivePrice(stop), color: DS.Palette.dangerSoft)
                            }
                        }
                        if let target = idea.advice.targetPrice {
                            ideaMetric("Target", adaptivePrice(target), color: DS.Palette.successSoft)
                        }
                        Spacer(minLength: 0)
                    }
                    // Round-H: the Entry/Stop/Target above and "Size it now" below are a
                    // placeable order — flag it when idea.price is off a stale (prior-UTC-day)
                    // cache price, same wording as the detail sheet's DEG-03 cue.
                    if let staleAsOf {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "clock.badge.exclamationmark").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.warningSoft)
                            Text("⚠︎ Price as of \(staleAsOf.formatted(.relative(presentation: .named))) — not live; re-price before ordering.")
                                .font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityHidden(true)  // folded into orderLabel above so VoiceOver reads it once
                    } else if analysisStaleOnly {
                        // D3: the price bar itself is current but the advice/EV numbers behind
                        // this card were computed >4h ago — a different honesty gap than a stale
                        // price, so it gets its own wording rather than reusing the price cue.
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "clock.badge.exclamationmark").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.warningSoft)
                            Text("⚠︎ Analysis over 4h old — re-scan for a current read.")
                                .font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityHidden(true)  // folded into orderLabel above so VoiceOver reads it once
                    }
                    if let stop = idea.advice.stopPrice, let acct = StockSageInput.positiveAmount(sizerAccount),
                       let rp = StockSageInput.percent(sizerRiskPct),
                       let ps = sizedPosition(account: acct, riskFraction: rp / 100, symbol: idea.symbol, entry: idea.price, stop: stop) {
                        // Blocked-fixture QA 2026-07-09: a green sized order directly under a
                        // DO-NOT-TRADE chip read as two voices — the size line now names the
                        // refusal itself (and drops the go-green tint) when the gate blocks.
                        Text("Size it now: \(StockSagePositionSizer.summaryLine(ps, riskPct: rp, symbol: idea.symbol, pctOverride: pctOfAccountUSD(ps, symbol: idea.symbol, account: acct)))"
                             + (cardGate?.decision == .blocked ? " — gate: do NOT trade at this risk %" : ""))
                            .font(.system(size: mvFont9, weight: .medium))
                            .foregroundStyle(cardGate?.decision == .blocked ? DS.Palette.dangerSoft
                                             : (pctOfAccountUSD(ps, symbol: idea.symbol, account: acct) > 100 || ps.shares == 0 ? DS.Palette.warningSoft : DS.Palette.successSoft))   // wave-2 #2
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(MoneyVelocityCopy.bestOpportunity + tomTiltDisclosureSuffix + crownDivergenceSuffix)
                        .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.sm).frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.accent.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(LuxPressStyle())
            .accessibilityLabel(orderLabel)
            HStack(spacing: 6) {
                Spacer()
                Button {
                    let plan = StockSageTodayPlan.build(
                        idea: idea, ev: ev,
                        account: StockSageInput.positiveAmount(sizerAccount),
                        riskFraction: StockSageInput.percent(sizerRiskPct).map { $0 / 100 },
                        daysToEarnings: store.earnings[idea.symbol.uppercased()]?.daysUntil,
                        isSample: store.isSampleData,
                        // TODAY-PARITY: same held-position awareness rankedActions/the ideas
                        // board's Held chip already carry — display-only.
                        positions: portfolio.positions,
                        // Round-H: flags a cache-stale price in the copied plan itself.
                        priceAsOf: idea.priceAsOf,
                        fxRatesToUSD: sizingFXRates(for: [idea.symbol]),
                        // A3: carry the same analysis-stale flag the card's pixels show.
                        analysisStale: analysisStaleOnly)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plan, forType: .string)
                } label: {
                    Label("Copy today's plan", systemImage: "checklist").font(.system(size: mvFont9, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(DS.Palette.accent)
                .help("Copy a checklist — best bet, the pre-trade gate verdict, and the size — to the clipboard. Estimates, not advice.")
            }
            }
        }
    }

    // Capital allocation — turns the whole ranked board into a concrete "how much in each"
    // plan via StockSageCapitalAllocator (half-Kelly, edge-weighted, heat-capped). Fed the
    // real board (store.ideas) and the user's editable account. Hidden until there's an
    // account AND at least one fundable position — never a manufactured plan.
    @ViewBuilder private var capitalAllocationCard: some View {
        if let acct = StockSageInput.positiveAmount(sizerAccount) {
            let plan = StockSageCapitalAllocator.allocate(ideas: store.ideas, account: acct, calibration: store.convictionCalibration, regime: store.regime,
                                                          fxRatesToUSD: sizingFXRates(for: store.ideas.map(\.symbol)))
            // F5 (2026-07-09): allocate() silently drops every position that floors to 0 shares —
            // this card used to just vanish when ALL of them did, indistinguishable from "nothing
            // qualified". Name the reason instead when there WERE fundable candidates.
            if plan.positions.isEmpty, plan.fundableCandidateCount > 0 {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.warningSoft)
                    Text("Deploy capital — all \(plan.fundableCandidateCount) fundable position\(plan.fundableCandidateCount == 1 ? "" : "s") are below the 1-share minimum at this $\(String(format: "%.0f", acct)) account size. Raise the account size or pick fewer/cheaper names to see an allocation plan.")
                        .font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.sm).frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.accent.opacity(0.30), lineWidth: 1))
                .accessibilityElement(children: .combine)
            }
            if !plan.positions.isEmpty {
                let heatColor: Color = plan.totalHeat > plan.maxHeat * 0.75 ? DS.Palette.warningSoft : DS.Palette.successSoft
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: "chart.pie.fill").font(.system(size: mvFont13)).foregroundStyle(DS.Palette.accent)
                        Text("Deploy capital — allocation plan").font(.system(size: mvFont12, weight: .bold)).foregroundStyle(.white)
                        Spacer()
                        calibrationChip   // the per-line EV that drove these sizes — measured or assumed?
                        ideaMetric("Open heat", String(format: "%.1f%%", plan.totalHeat * 100), color: heatColor)
                        if plan.scaleApplied < 1 {
                            ideaMetric("Cap scale", String(format: "%.0f%%", plan.scaleApplied * 100), color: DS.Palette.warningSoft)
                        }
                    }
                    // Honesty-disclosure gap fix: the allocator's regime step silently no-ops when
                    // regime is nil (intentional graceful-degradation — see allocate()'s
                    // `regime.map { ... } ?? k.suggestedFraction`), and its own caveat only mentions
                    // regime sizing when a regime IS present. An ungauged/stale plan otherwise ships
                    // with NO on-screen signal that it is carrying zero risk-off/on brake.
                    if Self.regimeWarningNeeded(regime: store.regime, isStale: store.regimeIsStale) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.warningSoft)
                            Text("⚠︎ Regime not gauged — this plan applies no risk-off/on brake; tap Gauge for a plan sized to the tape.")
                                .font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(plan.positions) { p in
                        deployPositionRow(p, planAccount: plan.account)
                    }
                    // L1 (2026-07-09, DISPLAY-ONLY): Kish/design-effect concentration diagnostic —
                    // the plan's own correlation de-weighting implies this number but never shows
                    // it. Computed once, reused by the copy-plan button below (byte-identical text).
                    let eb = plan.positions.count >= 2 ? Self.deployEffectiveBets(positions: plan.positions, ideas: store.ideas) : nil
                    if let eb {
                        Text(Self.effectiveBetsCaption(eb))
                            .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .help("Kish/design-effect: n_eff = N ÷ (1 + (N−1)·ρ̄); ρ̄ = mean pairwise correlation of the plan's positions over their shared \(eb.windowBars)-return recent window (spark-derived) — the same series the plan's correlation de-weighting reads. Sparks are downsampled (~2-day points); cross-calendar pairs understate co-movement, so treat n_eff as an OPTIMISTIC upper bound. Correlations are regime-dependent and rise in crashes (US average pairwise ~0.30–0.40 normal → >0.80 in 2008, ~0.75 Feb–Mar 2020) — a calm-window n_eff overstates crisis diversification. RESEARCH_2026-07-03_weekly_concentration.md §3b.")
                    }
                    // D2 (rotation-3 triage): per-position price-freshness lookup, reused by both
                    // the visible one-line note and the copy-plan export below — AllocatedPosition
                    // carries no priceAsOf of its own, so resolve it via the matching board idea
                    // (same symbol join `deployEffectiveBets` already does).
                    let ideaBySymbol = Dictionary(store.ideas.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
                    let staleDeploySymbols = plan.positions.filter {
                        MarketsView.staleAsOfPrice(ideaBySymbol[$0.symbol]?.priceAsOf, now: Date()) != nil
                    }
                    if !staleDeploySymbols.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "clock.badge.exclamationmark").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.warningSoft)
                            Text("⚠︎ \(staleDeploySymbols.count) position\(staleDeploySymbols.count == 1 ? "" : "s") priced off a prior-day close — not live; re-price before ordering.")
                                .font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 6) {
                        Spacer()
                        Button {
                            var lines = ["Capital allocation — \(String(format: "$%.0f", plan.account)) account, heat \(String(format: "%.1f%%", plan.totalHeat * 100)) (cap \(String(format: "%.0f%%", plan.maxHeat * 100)))."]
                                + plan.positions.map { p in
                                    // Audit 2026-07-12 (export-parity): at-risk/notional are native
                                    // currency — label each in its own currency (approxAmount), matching
                                    // the on-screen deploy row and never a false "$" for a .SR/.L name.
                                    var line = "\(p.symbol): \(p.shares) sh · \(String(format: "%.2f%%", p.riskFraction * 100)) risk · \(StockSageCurrency.approxAmount(p.dollarsAtRisk, symbol: p.symbol)) at risk · \(StockSageCurrency.approxAmount(p.notional, symbol: p.symbol)) notional · Est. EV \(String(format: "%+.2fR (gross)", p.evR))"
                                    // D2: mirror StockSageTodayPlan.copyAllText's per-line stale-price
                                    // suffix verbatim — same utcDayKey check, same wording.
                                    if let staleAsOf = MarketsView.staleAsOfPrice(ideaBySymbol[p.symbol]?.priceAsOf, now: Date()) {
                                        line += " | ⚠ PRICE NOT LIVE — as of \(staleAsOf.formatted(.relative(presentation: .named)))"
                                    }
                                    return line
                                }
                                + (eb.map { [Self.effectiveBetsCaption($0)] } ?? [])
                                + [plan.caveat]
                                + (Self.regimeWarningNeeded(regime: store.regime, isStale: store.regimeIsStale)
                                   ? ["⚠︎ Regime not gauged — this plan applies no risk-off/on brake; tap Gauge for a plan sized to the tape."]
                                   : [])
                            // D2: the copied allocation plan is a placeable order list — it must
                            // carry the same SAMPLE-data warning the board banner shows (mirrors
                            // StockSageTodayPlan.build/copyAllText's identical prepend).
                            if store.isSampleData {
                                lines.insert("⚠ SAMPLE DATA — illustrative prices, NOT live quotes. Re-price before any order.", at: 0)
                            }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                        } label: {
                            Label("Copy allocation plan", systemImage: "doc.on.doc").font(.system(size: mvFont9, weight: .medium))
                        }
                        .buttonStyle(.plain).foregroundStyle(DS.Palette.accent)
                        .help("Copy the half-Kelly, heat-capped allocation across the board to the clipboard. Estimates, not advice.")
                    }
                    Text(plan.caveat)
                        .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    // Hierarchy lens HIGH (2026-07-09): the plan's TOTAL capital requirement was
                    // invisible — say it whenever the full deployment exceeds the account.
                    // F7 (audit 2026-07-12): each notional is in the symbol's OWN currency — summing
                    // SAR + USD + pence raw is meaningless (the old "≈$53,000 (530%)"). deployPlanTotalUSD
                    // FX-converts each to USD before summing and reports how many had no tracked rate.
                    let deployTotal = deployPlanTotalUSD(plan)
                    if deployTotal.usd > plan.account {
                        Text(String(format: "⚠︎ Deploying the FULL plan needs ≈$%.0f of notional on a $%.0f account (%.0f%%) — deploy partially or with margin; each line still risks only its stated %% at its stop.%@",
                                    deployTotal.usd, plan.account,
                                    deployTotal.usd / plan.account * 100,
                                    deployTotal.untracked > 0 ? " (\(deployTotal.untracked) non-USD position\(deployTotal.untracked == 1 ? "" : "s") excluded from this total — no tracked FX rate.)" : ""))
                            .font(.system(size: mvFont9, weight: .medium)).foregroundStyle(DS.Palette.warningSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DS.Space.sm).frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.accent.opacity(0.30), lineWidth: 1))
            }
        }
    }

    // Money-velocity summary — one-glance header (best bet · fastest · est. weekly R),
    // visible across every section. Tappable to the best opportunity's plan.
    // Honesty: the per-card Size% already uses the calibrated win-prob (buildIdeas re-sizes on the
    // fitted calibration when one exists, else the conservative linear prior). The "Deploy capital"
    // plan layers on top: regime sizing bias, per-symbol vol-regime brake, correlation de-weighting,
    // and the total-heat cap — those are the genuine additions the Deploy plan makes.
    /// One Deploy-capital position row — extracted (VO walk 2026-07-09) so the row can be ONE
    /// combined, self-identifying VoiceOver stop: the "⚠︎ exceeds account" chip was a bare
    /// floating stop whose row attribution was only inferable from linear order.
    /// F7 (audit 2026-07-12): the deploy plan's total capital requirement, FX-converted to the USD
    /// account currency. Each position's notional is in its own currency, so a raw sum across
    /// SAR/USD/pence is meaningless; this converts each (pence-normalized × rate) and reports how many
    /// positions had no tracked FX rate (excluded from the sum rather than added 1:1). Pure.
    /// F3 review fix (2026-07-16): converts via `usdAmount` (the shared fxRateToUSD RESOLVER) —
    /// the portfolio-only dict lacked SAR on an empty book, so this total EXCLUDED the very `.SR`
    /// position the card had just FX-sized and called it "untracked". Same exclusion semantics;
    /// "untracked" now means genuinely no rate anywhere.
    private func deployPlanTotalUSD(_ plan: CapitalAllocation) -> (usd: Double, untracked: Int) {
        var usd = 0.0, untracked = 0
        for pos in plan.positions {
            if let v = usdAmount(pos.notional, symbol: pos.symbol) { usd += v } else { untracked += 1 }
        }
        return (usd, untracked)
    }

    @ViewBuilder private func deployPositionRow(_ p: AllocatedPosition, planAccount: Double) -> some View {
        HStack(spacing: 12) {
            Text(p.symbol).font(.system(size: mvFont13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 64, alignment: .leading)
            ideaMetric("Risk", String(format: "%.2f%%", p.riskFraction * 100))
            ideaMetric("Shares", "\(p.shares)")
            // F2 (audit 2026-07-12): at-risk / notional are in the symbol's OWN currency — label them
            // as such (approxAmount → "≈200 SAR" not "$200"), same fix as the idea-card "At risk".
            ideaMetric("At risk", StockSageCurrency.approxAmount(p.dollarsAtRisk, symbol: p.symbol), color: DS.Palette.warningSoft)
            ideaMetric("Notional", StockSageCurrency.approxAmount(p.notional, symbol: p.symbol))
            // "Est. EV" (2026-07-09, harvested Copilot HELD finding #2): same
            // estimate class as the best-opp card's "Est. EV" — an unlabeled "EV"
            // here read as a firmer number than the identical figure one card up.
            ideaMetric("Est. EV", String(format: "%+.2fR (gross)", p.evR), color: DS.Palette.successSoft)
                .help(StockSageGlossary.explain(.ev))
            // Hierarchy lens HIGH (2026-07-09): the smaller per-card plan warns at
            // >100%-of-account, but THIS plan — the portfolio-level one — showed a
            // $15,978 notional on a $10,000 account with no flag.
            // F2 (audit 2026-07-12): compare the notional to the account in the SAME currency (USD) —
            // a native SAR/pence notional vs a USD account either falsely trips (pence ~100×) or misses.
            // When the symbol's FX rate is untracked, fall back to the raw compare (prior behavior).
            // F3 review fix (2026-07-16): via `usdAmount` (resolver-backed) — the portfolio-only dict
            // lacked SAR on an empty book, so an FX-sized .SR plan position compared raw SAR vs USD
            // and false-fired this chip (worse post-F3: native counts rose ~3.75×).
            let notionalUSD = usdAmount(p.notional, symbol: p.symbol) ?? p.notional
            if notionalUSD > planAccount {
                Text("⚠︎ exceeds account")
                    .font(.system(size: mvFont9, weight: .semibold)).foregroundStyle(DS.Palette.warningSoft)
                    .lineLimit(1).fixedSize()
                    .help("This position's notional is larger than the whole account — placing it needs margin or a partial fill. The risk% column still describes only the loss at the stop, not the capital required.")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private static let sizeMetricHelp = "Size uses the calibrated win-prob when a journal or backtest calibration is fitted (the same win-rate shown in the EV chip), or the conservative ~\(StockSageExpectedValue.assumedWinBandLabel) prior otherwise. The ‘Deploy capital’ plan is the PORTFOLIO-level size — act on it when allocating the whole book (it layers regime sizing bias → vol-targeting shrink → per-symbol vol-regime brake → correlation de-weighting → heat cap); this per-card Size answers the SINGLE-trade question at your flat risk %."

    // Honest "are these EV numbers measured, fitted, or assumed?" chip — reused on every EV-headline
    // surface. F01/F02 (2026-07-02): keys on the calibration's METHOD, never on `calibration != nil`
    // — an identity calibration (winProb ≈ conviction, measured from ZERO outcomes) renders
    // "win% assumed", a Platt fit "win% fitted" (central MLE, not conservative), and only the
    // Wilson-LCB isotonic / OOS-validated Beta paths earn "win% measured". Title/tooltip come from
    // StockSageConvictionCalibration.chipTitle/chipHelp (single source, test-pinned).
    /// Decision 5 (calibration runtime activation): append persisted-fit provenance (source +
    /// data-as-of date + n) to the chip tooltip ONLY when the EFFECTIVE calibration is the
    /// persisted backtest leg (journal fit nil) with a real fit (never identity — the method-keyed
    /// `chipTitle` already guarantees an identity title can never say "measured"). Identity ⇒
    /// return `chipHelp` unchanged: every rendered byte stays identical to before this activation.
    private func calibrationChipHelp(_ cal: StockSageConvictionCalibration) -> String {
        guard store.convictionCalibrationIsFromBacktest,
              let snap = store.persistedCalibrationSnapshot,
              cal.method != .identity else { return cal.chipHelp }
        return cal.chipHelp + " Fit from \(snap.source) · data as of \(snap.fittedAt.formatted(date: .abbreviated, time: .omitted)) · n=\(snap.sampleCount)"
    }

    @ViewBuilder private var calibrationChip: some View {
        if let cal = store.convictionCalibration {
            let assumed = cal.method == .identity
            calibrationChipChrome(assumed: assumed) {
                Label(cal.chipTitle, systemImage: assumed ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: fontChipLabel, weight: .semibold))
                    .foregroundStyle(assumed ? DS.Palette.warningSoft : DS.Palette.successSoft)
                    .help(calibrationChipHelp(cal))
            }
        } else {
            calibrationChipChrome(assumed: true) {
                Label("win% assumed", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: fontChipLabel, weight: .semibold)).foregroundStyle(DS.Palette.warningSoft)
                    .help("Win-rate uses a cautious hand-set band (\(StockSageExpectedValue.assumedWinBandLabel)), not measured rates — run the Strategy backtest to calibrate.")
            }
        }
    }

    /// Audit 2026-07-12 (ideas-card LANE 2 — "why this rank"): an honest, display-only decomposition
    /// of WHY this idea sits where it does on the EV board. It calls the SAME term functions the
    /// ranker uses (`StockSageExpectedValue.rankExplanation`), so the breakdown provably matches the
    /// real sort key — never a plausible-but-fabricated story (the honesty-floor failure the whole
    /// audit fenced). Shows nothing when only the base EV drove the rank (no adjustments to explain)
    /// or for a nil-EV idea. Only rendered on the EV sort (the key it decomposes); other sorts use a
    /// different key, so showing this there would misattribute the order.
    @ViewBuilder private func whyThisRankSection(_ idea: StockSageIdea) -> some View {
        if ideaSort == .ev,
           let exp = StockSageExpectedValue.rankExplanation(for: idea, regime: store.regime,
                                                            earnings: store.earnings, liquidity: store.liquidity,
                                                            seasonality: store.seasonality,
                                                            calibration: store.convictionCalibration),
           !exp.activeAdjustments.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Why this rank")
                    .font(.system(size: fontChipLabel, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                // The base EV rank key, then each adjustment that ACTUALLY moved it — the same terms
                // rankByEV sums. A boost reads green, a demotion reads amber; magnitudes are the raw
                // rank-key deltas (not returns), so they're labeled as ranking weight, not P&L.
                Text("Ranked on estimated EV, then adjusted:")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(Array(exp.activeAdjustments.enumerated()), id: \.offset) { _, adj in
                    HStack(spacing: 5) {
                        Image(systemName: adj.delta >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: mvFont9)).foregroundStyle(adj.delta >= 0 ? DS.Palette.successSoft : DS.Palette.warningSoft)
                        Text("\(adj.delta >= 0 ? "Boosted" : "Demoted") — \(adj.label)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("These are ranking weights (why it sorts where it does), not returns. The rank orders by estimated payoff — it doesn't predict it.")
                    .font(.system(size: mvFont9)).foregroundStyle(.secondary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Why this rank. Ranked on estimated EV, then adjusted: "
                + exp.activeAdjustments.map { "\($0.delta >= 0 ? "boosted" : "demoted") by \($0.label)" }.joined(separator: ", "))
        }
    }

    // Preattentive assumed-vs-measured chrome for calibrationChip (Gemini UI-wave #6, LOW risk).
    // Keyed on the SAME `assumed` condition the icon/color already use — one condition, two
    // encodings, no new semantic tier. No DS chip-stroke token existed to extend, so values are
    // inline: dashed capsule stroke for assumed, solid for measured; both at reduced opacity so
    // this stays a chip accent, not a banner.
    @ViewBuilder
    private func calibrationChipChrome<Content: View>(assumed: Bool, @ViewBuilder content: () -> Content) -> some View {
        let strokeColor = (assumed ? DS.Palette.warningSoft : DS.Palette.successSoft)
            .opacity(assumed ? 0.55 : 0.8)
        content()
            .opacity(assumed ? 0.85 : 1.0)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().strokeBorder(
                    strokeColor,
                    style: StrokeStyle(lineWidth: 1, dash: assumed ? [3, 2] : [])
                )
            )
    }

    @ViewBuilder private var moneyVelocityCard: some View {
        // Honor the user's editable Risk % so the drawdown brake's magnitude AND its label
        // track the same fraction the rest of the card uses (was a hardcoded 1%).
        // F04: `summary(fraction:)` has no nil path (it always computes a brake scenario), so
        // when the risk % is unparseable we still call it with the 0.01 default to get the
        // OTHER content (best/fastest/weeklyR, unaffected by fraction) but then strip the
        // fraction-dependent brake fields — never show a drawdown number modeled on a risk %
        // the user never typed.
        let rawSummary = StockSageExpectedValue.summary(store.ideas, trades: journal.trades, fraction: parsedRiskFraction ?? 0.01, holds: velocityHolds, regime: store.regime, earnings: store.earnings, liquidity: store.liquidity, seasonality: store.seasonality, calibration: store.convictionCalibration)
        let riskFrac = parsedRiskFraction
        let s = riskFrac != nil ? rawSummary : MoneyVelocitySummary(
            bestSymbol: rawSummary.bestSymbol, bestEV: rawSummary.bestEV,
            fastestSymbol: rawSummary.fastestSymbol, fastestVelocity: rawSummary.fastestVelocity,
            weeklyR: rawSummary.weeklyR, weeklyRNet: rawSummary.weeklyRNet,
            weeklyRGrossSameBasket: rawSummary.weeklyRGrossSameBasket,
            weeklyTopCount: rawSummary.weeklyTopCount)
        // Whether a Brake WOULD have shown had risk % been set — gates the explicit nil-state below.
        let hadBrakeContent = rawSummary.worstRunLosses != nil
        // F4: the SAME earnings/liquidity-aware lane summary()'s weeklyRNet/weeklyRGrossSameBasket
        // sum over (see summary()'s own netAwareLane) — bound here once to check fundability of
        // the top-N the $/week line below dollarizes, without touching that line's own math.
        let velocityLane = StockSageExpectedValue.fastLane(store.ideas, holds: velocityHolds, calibration: store.convictionCalibration, earnings: store.earnings, liquidity: store.liquidity)
        // PERF-MVCARD: computed once, reused at both the visual warning below and the a11y-label
        // closure that folds it in — was computed twice (byte-identical args) per render.
        let conc = StockSageExpectedValue.fastLaneConcentration(store.ideas, holds: velocityHolds, calibration: store.convictionCalibration, earnings: store.earnings, liquidity: store.liquidity)
        // F7 (rotation-3 triage): first-ever scan only — see firstScanProgressCaption's doc.
        let firstScanCaption = Self.firstScanProgressCaption(isLoadingIdeas: store.isLoadingIdeas, ideasUpdated: store.ideasUpdated, progress: store.ideasProgress)
        if s.hasContent {
            VStack(alignment: .leading, spacing: 6) {
            Button {
                if let best = StockSageExpectedValue.bestOpportunity(store.ideas, regime: store.regime, earnings: store.earnings, liquidity: store.liquidity, seasonality: store.seasonality, calibration: store.convictionCalibration) { selectedIdea = best.idea }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.system(size: mvFont12)).foregroundStyle(DS.Palette.accent)
                        Text("Money velocity — fastest moves now").font(.system(size: mvFont11, weight: .bold)).foregroundStyle(.white)
                        Spacer()
                        calibrationChip   // measured (n) vs assumed — qualifies the EV/$ numbers below
                    }
                    // F7 (rotation-3 triage): this card's "best"/"fastest" are provisional
                    // during the first-ever scan — folded into the accessibilityLabel below.
                    if let firstScanCaption {
                        Text(firstScanCaption)
                            .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityHidden(true)
                    }
                    HStack(alignment: .top, spacing: DS.Space.lg) {
                        if let sym = s.bestSymbol, let ev = s.bestEV {
                            VStack(alignment: .leading, spacing: 2) {
                                // T10 (rotation-3 triage): "+0.45R EV (gross)" read as a labeled
                                // R figure with EV as a tag; "Est. EV +0.45R (gross)" matches
                                // every other EV surface (bestOpportunityCard's "Est. EV" metric,
                                // the idea card's EV chip) — the last unlabeled EV in the app.
                                ideaMetric("Best now", sym, sub: String(format: "Est. EV %+.2fR (gross)", ev))
                                    .help(MoneyVelocityCopy.bestOpportunity + tomTiltDisclosureSuffix)
                                if let ep = store.earnings[sym.uppercased()], ep.isWarning {
                                    let badge = ep.severity == .imminent ? "⚠︎ earnings ~\(ep.daysUntil)d" : "earnings ~\(ep.daysUntil)d"
                                    Text(badge).font(.system(size: mvFont8))
                                        .foregroundStyle(ep.severity == .imminent ? DS.Palette.dangerSoft : .secondary)
                                }
                            }
                        }
                        if let sym = s.fastestSymbol, let v = s.fastestVelocity {
                            VStack(alignment: .leading, spacing: 2) {
                                ideaMetric("Fastest", sym, sub: String(format: "%+.2fR/day net", v))
                                if let ep = store.earnings[sym.uppercased()], ep.isWarning {
                                    let badge = ep.severity == .imminent ? "⚠︎ earnings ~\(ep.daysUntil)d" : "earnings ~\(ep.daysUntil)d"
                                    Text(badge).font(.system(size: mvFont8))
                                        .foregroundStyle(ep.severity == .imminent ? DS.Palette.dangerSoft : .secondary)
                                }
                            }
                        }
                        if let netWk = s.weeklyRNet {
                            // F03/F44 SETTLED 2026-07-09 (owner lifted the netting gate): the
                            // headline is NET — the decision-relevant number after est. frictions.
                            // Gross stays one hover away, labeled, never hidden.
                            ideaMetric("Est./week", String(format: "%+.1fR", netWk), sub: "net of est. costs, top \(s.weeklyTopCount ?? 3)", subColor: .secondary)
                                // F9: pair net with weeklyRGrossSameBasket (same top-N net was summed
                                // over), not weeklyR — that field is deliberately basket-unaware
                                // (trend continuity), so pairing it here could show two different baskets.
                                .help(weeklyGrossHelp(String(format: "1R = the amount you risk on one trade (entry→stop distance × size). Net of estimated costs — sums the top fast-lane NET velocities%@. It can include ideas the net-cost floor demotes on the boards; the 'Fastest' pick excludes them. An estimate, not income.", s.weeklyRGrossSameBasket.map { String(format: " (gross %+.1fR before costs)", $0) } ?? ""), netFigure: true))
                        } else if let wk = s.weeklyR {
                            // Fallback when the net figure can't be formed: the labeled gross
                            // (F03/F44's original disposition) — never a fabricated net.
                            ideaMetric("Est./week", String(format: "%+.1fR", wk), sub: "gross, if you run top \(s.weeklyTopCount ?? 3)", subColor: .secondary)
                                .help(weeklyGrossHelp("Gross, before costs — sums the top fast-lane GROSS velocities. It can include ideas the net-cost floor demotes on the boards; the 'Fastest' pick excludes them. An estimate, not income."))
                        }
                        Spacer(minLength: 0)
                    }
                    // PERF-MVCARD: expectedWeeklyDollars's body is exactly `wkR * account * riskFraction`
                    // once its guards pass — `s.weeklyR` IS that wkR by construction (summary()'s own
                    // weeklyR field is expectedWeeklyR(ideas, tradingDaysForLane(ideas, holds, calibration),
                    // holds, calibration), called here with the same ideas/holds/calibration), so this
                    // avoids a second full fastLane + fastLaneConcentration recompute.
                    if let wk = s.weeklyRNet ?? s.weeklyR, let acct = StockSageInput.positiveAmount(sizerAccount), let rp = StockSageInput.percent(sizerRiskPct) {
                        // F03/F44: dollars line follows the headline — net when available,
                        // labeled gross fallback otherwise (never a fabricated net).
                        let usd = wk * acct * (rp / 100)
                        // Sign from the value (matches the %+.1fR headline): a net-cost-demoted
                        // lane can sum to a negative weekly $, which "+$" would render "+$-42".
                        Text(String(format: "≈ %@$%.0f/week at $%.0f acct, %.1f%% risk — %@", usd < 0 ? "-" : "+", abs(usd), acct, rp, s.weeklyRNet != nil ? MoneyVelocityCopy.weeklyDollarsNet : MoneyVelocityCopy.weeklyDollars))
                            .font(.system(size: mvFont9, weight: .medium))
                            .foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)   // neutral: an estimate, not a realized gain
                            .help((s.weeklyRNet != nil ? "Net of est. costs — weekly R × the dollar value of 1R. " : "Gross, before costs — weekly R × the dollar value of 1R. ") + "Can include ideas the net-cost floor demotes on the boards; the 'Fastest' pick excludes them. NOT income.")
                        // F4 (2026-07-09): the $/week figure above is byte-identical math — this
                        // only adds an honest qualifier when it dollarizes a setup that floors to
                        // 0 shares at this account size (F1/F3's silent-unfundable-#1 finding).
                        if StockSageExpectedValue.weeklyDollarsIncludesUnfundableRow(lane: velocityLane, account: acct, riskFraction: rp / 100, fxRatesToUSD: sizingFXRates(for: velocityLane.map(\.symbol))) {
                            Text("⚠︎ At least one of the top setups summed above is below the 1-share minimum at this account size — the $/week figure overstates what you can actually place. See 'Size it now' on each idea.")
                                .font(.system(size: mvFont8)).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let d = velocityHistory.lastDelta, abs(d) >= 0.05 {
                        Text(String(format: "Since last session: gross weekly-R %@ %.1fR — %@", d >= 0 ? "↑" : "↓", abs(d), MoneyVelocityCopy.ownHistory))
                            .font(.system(size: mvFont8))
                            .foregroundStyle(d >= 0 ? DS.Palette.successSoft : DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                    }
                    if let ch = velocityHistory.change {
                        let movers = [ch.bestChangedTo.map { "best → \($0)" }, ch.fastestChangedTo.map { "fastest → \($0)" }].compactMap { $0 }
                        if !movers.isEmpty {
                            Text("Mover: \(movers.joined(separator: ", ")) — \(MoneyVelocityCopy.ownHistory)")
                                .font(.system(size: mvFont8)).foregroundStyle(DS.Palette.accent).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let t = velocityHistory.trend {
                        let rising = t.direction == .rising, fading = t.direction == .fading
                        HStack(spacing: 5) {
                            Image(systemName: rising ? "arrow.up.right" : (fading ? "arrow.down.right" : "arrow.right"))
                                .font(.system(size: mvFont8, weight: .bold))
                                .foregroundStyle(rising ? DS.Palette.successSoft : (fading ? DS.Palette.warningSoft : .secondary))
                            Text(String(format: "Your opportunity set is %@ (recent gross wk-R %+.1f vs %+.1f early) — %@",
                                        t.direction.rawValue, t.recentAvg, t.earlyAvg, MoneyVelocityCopy.ownHistory))
                                .font(.system(size: mvFont8)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if velocityHistory.series.count >= 2 {
                                Sparkline(values: velocityHistory.series.map(\.weeklyR))
                                    .stroke(rising ? DS.Palette.successSoft : (fading ? DS.Palette.warningSoft : DS.Palette.surfaceStroke),
                                            style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                                    .frame(width: 48, height: 14)
                            }
                        }
                    }
                    if let ddPct = s.worstRunDrawdownPct, let losses = s.worstRunLosses {
                        Text(String(format: "⚠︎ Brake — your worst run (%d) at %.1g%%/trade ≈ −%.1f%% to the account. %@", losses, s.riskFraction * 100, ddPct * 100, MoneyVelocityCopy.drawdownBrake))
                            .font(.system(size: mvFont10, weight: .semibold))
                            .foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(String(format: "Risk warning: worst losing run %d trades at %.1g percent risk is about %.1f percent drawdown. Size to survive variance.", losses, s.riskFraction * 100, ddPct * 100))
                    } else if riskFrac == nil && hadBrakeContent {
                        // F04: there IS loss history to model a brake from, but risk % is unparseable —
                        // say so explicitly rather than silently dropping the warning.
                        Text("Enter risk % to see your drawdown brake.")
                            .font(.system(size: mvFont10, weight: .semibold))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let conc, let warning = StockSageExpectedValue.moneyVelocityConcentrationWarning(conc) {
                        Text(warning)
                            .font(.system(size: mvFont10, weight: .semibold))
                            .foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Velocity warning: the fastest \(conc.total) ideas are all \(conc.dominantClass) — concentration risk; size them as one bet")
                    }
                    Text(MoneyVelocityCopy.summary)
                        .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.sm).frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.accent.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(LuxPressStyle())
            // Fold the risk warnings INTO the Button label — the override above collapses the Button to
            // one leaf, so the inner per-Text labels (drawdown brake, fast-lane concentration) are dead.
            .accessibilityLabel("Money velocity summary; tap for the best opportunity"
                // C1 wave: the Button override silences every child Text, which had dropped ALL
                // of today's headline facts for VoiceOver — speak them with the same net/gross
                // qualifiers the pixels carry.
                + ({ () -> String in
                    var t = ""
                    if let firstScanCaption { t += ". \(firstScanCaption)" }
                    if let sym = s.bestSymbol, let ev = s.bestEV { t += String(format: ". Best now %@, estimated EV %+.2f R gross", sym, ev) }
                    if let sym = s.fastestSymbol, let v = s.fastestVelocity { t += String(format: ". Fastest %@, %+.2f R per day net", sym, v) }
                    if let netWk = s.weeklyRNet {
                        t += String(format: ". Estimated %+.1f R per week net of estimated costs", netWk)
                        // F9: same-basket gross, not the basket-unaware weeklyR (see the .help above).
                        if let wk = s.weeklyRGrossSameBasket { t += String(format: ", gross %+.1f R before costs", wk) }
                        t += ", top \(s.weeklyTopCount ?? 3) — an estimate, not income"
                    } else if let wk = s.weeklyR {
                        t += String(format: ". Estimated %+.1f R per week gross, before costs — an estimate, not income", wk)
                    }
                    // VO walk 2026-07-09: the Best-now tilt disclosure is .help-only inside this
                    // overridden Button — speak it here when it applies.
                    if !tomTiltDisclosureSuffix.isEmpty {
                        t += ". Best-now ranking includes a small seasonal month tilt."
                    }
                    // F4 a11y parity with the visible unfundable-row warning above.
                    if let acct = StockSageInput.positiveAmount(sizerAccount), let rp = StockSageInput.percent(sizerRiskPct),
                       StockSageExpectedValue.weeklyDollarsIncludesUnfundableRow(lane: velocityLane, account: acct, riskFraction: rp / 100, fxRatesToUSD: sizingFXRates(for: velocityLane.map(\.symbol))) {
                        t += ". Warning: at least one of the top setups summed is below the 1-share minimum at this account size; the dollar-per-week figure overstates what you can actually place."
                    }
                    return t
                }())
                + ({ () -> String in
                    if let ddPct = s.worstRunDrawdownPct, let losses = s.worstRunLosses {
                        return String(format: ". Risk warning: worst losing run %d trades at %.1g percent risk is about %.1f percent drawdown.", losses, s.riskFraction * 100, ddPct * 100)
                    }
                    if riskFrac == nil && hadBrakeContent { return ". Enter risk percent to see your drawdown brake." }
                    return ""
                }())
                + ({ () -> String in
                    guard let conc, conc.isConcentrated else { return "" }
                    return ". Velocity warning: the fastest \(conc.total) ideas are all \(conc.dominantClass), concentration risk; size them as one bet."
                }()))
            .help(StockSageGlossary.moneyVelocityHelp)
            HStack(spacing: 6) {
                Spacer()
                Button {
                    var plan = StockSageExpectedValue.playbook(s)
                    if store.isSampleData {
                        // Parity with every sibling export: a sample-data playbook must carry the flag.
                        plan = "⚠ SAMPLE DATA — illustrative prices, NOT live quotes. Re-price before any order.\n" + plan
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plan, forType: .string)
                } label: {
                    Label("Copy plan", systemImage: "doc.on.doc").font(.system(size: mvFont9, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(DS.Palette.accent)
                .help("Copy a short, caveated money-velocity action list to the clipboard.")
            }
            }
        }
    }

    /// Always-visible best-move action CTA. Reuses the SAME `bestOpportunity` call
    /// `moneyVelocityCard`'s tap target already makes (no new fetch), `StockSagePositionSizer`
    /// for the size line, and `StockSageTodayPlan.build` for the copy action — identical to
    /// `bestOpportunityCard`, just rendered globally instead of only inside the Ideas tab.
    /// Renders nothing without a positive-EV buy idea (bestOpportunity's own `e.evR > 0`
    /// guard) — never manufactures a move. Crypto (`StockSageAllocation.assetClass == "Crypto"`,
    /// the SAME predicate `fastLaneStrip` already uses) gets the warning tint + an honest
    /// 24h-range variance line from the idea's ALREADY-STORED `realizedVol` — no new volatility
    /// computation.
    @ViewBuilder private var bestOpportunityCTA: some View {
        if let best = StockSageExpectedValue.bestOpportunity(store.ideas, regime: store.regime, earnings: store.earnings, liquidity: store.liquidity, seasonality: store.seasonality, calibration: store.convictionCalibration) {
            let idea = best.idea, ev = best.ev
            let isCrypto = StockSageAllocation.assetClass(idea.symbol) == "Crypto"
            let variance: Double? = isCrypto ? StockSageExpectedValue.dailyVariancePct(annualizedVol: idea.realizedVol) : nil
            // Round-H: same stale-price gap as bestOpportunityCard — this CTA renders the
            // identical sized/placeable order globally, not just on the Ideas tab.
            let staleAsOf = Self.staleAsOfPrice(idea.priceAsOf, now: Date())
            // D3 (rotation-3 triage): same two-axis upgrade as bestOpportunityCard — see the
            // comment there for the derivation (cardIsStale = analysisStale || priceStale;
            // staleAsOf non-nil exactly when priceStale).
            let cardIsStaleOverall = Self.cardIsStale(generatedAt: idea.generatedAt, now: Date(), priceAsOf: idea.priceAsOf)
            let analysisStaleOnly = cardIsStaleOverall && staleAsOf == nil
            // PERF (2026-07-09 cleanup of this day's own waves): compute once per body
            // evaluation — the gate verdict was computed TWICE (gateLabel + gateColor
            // closures) and netEVR twice (evText + accessibilityText).
            let ctaGate: TradeGateVerdict? = parsedRiskFraction != nil
                ? tradeGateVerdict(for: idea, inputs: tradeGateInputs(for: idea)) : nil
            let ctaNetEV = StockSageExpectedValue.netEVR(for: idea, calibration: store.convictionCalibration)
            // F8 (2026-07-09): this global "Do this now" CTA (bestOpportunity: highest gross EV)
            // and Today's plan's #1 row (rankedActions: fastest EV/day, equities-first) rank by
            // DIFFERENT lenses and can legitimately name different symbols with no cross-reference
            // — copy-only fix: when they diverge, say so in this card's existing sub-line.
            // `max: 1` asks rankedActions for ONLY the #1 row (same inputs todaysActionsCard uses).
            let todayFirstSymbol = StockSageTodayPlan.rankedActions(
                store.ideas, account: StockSageInput.positiveAmount(sizerAccount),
                riskFraction: StockSageInput.percent(sizerRiskPct).map { $0 / 100 },
                holds: velocityHolds, calibration: store.convictionCalibration, marketRegime: store.regime,
                earnings: store.earnings, liquidity: store.liquidity,
                positions: portfolio.positions, journalTrades: journal.trades,
                mode: .equityExecutableFirst, max: 1,
                fxRatesToUSD: sizingFXRates(for: store.ideas.map(\.symbol))).first?.symbol
            let crownDivergenceSuffix = (todayFirstSymbol != nil && todayFirstSymbol != idea.symbol)
                ? " Today's plan leads with \(todayFirstSymbol!) — different lens." : ""
            // Settle S1 review fix: isWarning drives the TINT (over-account OR unfundable 0-share);
            // exceedsAccount alone keys the spoken "exceeds account balance" claim — a $0/0-share
            // position does not exceed the balance, and summaryLine already speaks its honest
            // "below the 1-share minimum" suffix (honesty floor: never speak a false clause).
            let sizeInfo: (text: String, isWarning: Bool, exceedsAccount: Bool) = {
                if let stop = idea.advice.stopPrice, let acct = StockSageInput.positiveAmount(sizerAccount),
                   let rp = StockSageInput.percent(sizerRiskPct),
                   let ps = sizedPosition(account: acct, riskFraction: rp / 100, symbol: idea.symbol, entry: idea.price, stop: stop) {
                    // wave-2 #2: USD-correct pct so a non-USD winner isn't falsely flagged "exceeds account".
                    let pctUSD = pctOfAccountUSD(ps, symbol: idea.symbol, account: acct)
                    return (StockSagePositionSizer.summaryLine(ps, riskPct: rp, symbol: idea.symbol, pctOverride: pctUSD), pctUSD > 100 || ps.shares == 0, pctUSD > 100)
                }
                return ("Set account to size — add one in the position sizer below.", false, false)
            }()
            let accessibilityText: String = {
                var s = "Do this now: \(idea.symbol), \(idea.advice.action.rawValue), estimated EV \(String(format: "%.2f", ev.evR)) R gross, entry \(adaptivePrice(idea.price))"
                if let stop = idea.advice.stopPrice { s += ", stop \(adaptivePrice(stop))" }
                // C1 wave: the size line carries the loss-not-profit honesty tail and the
                // >100%-of-account warning tint — VoiceOver gets the same facts.
                s += ", " + sizeInfo.text
                if sizeInfo.exceedsAccount { s += ". Size warning: position exceeds account balance" }
                if let variance { s += String(format: ", typical 24-hour range plus or minus %.1f percent", variance) }
                if let staleAsOf {
                    s += ". Price as of \(staleAsOf.formatted(.relative(presentation: .named))) — not live; re-price before ordering"
                } else if analysisStaleOnly {
                    s += ". Analysis over 4h old — re-scan for a current read"
                }
                if let g = ctaGate {
                    s += ". Pre-trade gate: \(g.decision == .blocked ? "do not trade" : g.decision.rawValue)."
                }
                // VO walk 2026-07-09: speak the net estimate + tilt disclosure (pixels-only otherwise).
                if let net = ctaNetEV {
                    s += String(format: ", about %+.2f R net estimated", net)
                }
                if !tomTiltDisclosureSuffix.isEmpty {
                    s += ". Ranking includes a small seasonal month tilt."
                }
                // F-review fix (2026-07-10): `s` can already end with "." here (e.g. the tilt
                // sentence just above) — unconditionally prepending another "." produced a
                // double period ("...tilt.. Today's plan...") when both suffixes fired. Only add
                // one when `s` doesn't already end with one (mirrors the caveatText path below,
                // which concatenates suffixes that already carry their own leading space/trailing
                // period and never inserts a manual ".").
                if !crownDivergenceSuffix.isEmpty {
                    if !s.hasSuffix(".") { s += "." }
                    s += crownDivergenceSuffix
                }
                // Audit 2026-07-12 (wave-2 #4): the sibling bestOpportunityCard discloses "first scan
                // in progress — best-so-far, order may change"; this global CTA crowns the same
                // provisional pick and must say so too (a11y parity — the visible caption is added
                // to BestOpportunityActionCard below via firstScanCaption).
                if let firstScanCaption = Self.firstScanProgressCaption(isLoadingIdeas: store.isLoadingIdeas, ideasUpdated: store.ideasUpdated, progress: store.ideasProgress) {
                    if !s.hasSuffix(".") { s += "." }
                    s += " " + firstScanCaption
                }
                return s
            }()
            BestOpportunityActionCard(
                symbol: idea.symbol,
                actionLabel: idea.advice.action.rawValue,
                actionColor: actionColor(idea.advice.action),
                actionTextColor: actionTextColor(idea.advice.action),
                isCrypto: isCrypto,
                entryText: "Entry ~\(adaptivePrice(idea.price))",
                stopText: idea.advice.stopPrice.map { "stop \(adaptivePrice($0))" },
                sizeText: sizeInfo.text + (ctaGate?.decision == .blocked ? " — gate: do NOT trade at this risk %" : ""),
                sizeIsWarning: sizeInfo.isWarning || ctaGate?.decision == .blocked,
                evText: String(format: "Est. EV %+.2fR (gross)", ev.evR)
                    + (ctaNetEV.map { String(format: " · ≈%+.2fR net est.", $0) } ?? ""),
                gateLabel: ctaGate.map { $0.decision == .blocked ? "DO NOT TRADE" : $0.decision.rawValue.uppercased() },
                gateColor: ctaGate.map { $0.decision == .blocked ? DS.Palette.danger
                         : ($0.decision == .caution ? DS.Palette.warningSoft.opacity(0.85) : DS.Palette.successSoft.opacity(0.85)) } ?? .clear,
                // wave-2 #4: append the first-scan "best-so-far, order may change" caption (sibling
                // bestOpportunityCard already shows it) so this global crown discloses it's provisional.
                caveatText: MoneyVelocityCopy.bestOpportunity + tomTiltDisclosureSuffix + crownDivergenceSuffix
                    + (Self.firstScanProgressCaption(isLoadingIdeas: store.isLoadingIdeas, ideasUpdated: store.ideasUpdated, progress: store.ideasProgress).map { " " + $0 } ?? ""),
                varianceText: variance.map { String(format: "Typical 24h range ±%.1f%% — size down for 24/7.", $0) },
                staleAsOfText: staleAsOf.map { "⚠︎ Price as of \($0.formatted(.relative(presentation: .named))) — not live; re-price before ordering." }
                    ?? (analysisStaleOnly ? "⚠︎ Analysis over 4h old — re-scan for a current read." : nil),
                accessibilityText: accessibilityText,
                onTap: { selectedIdea = idea },
                onCopy: {
                    // Use StockSageInput.positiveAmount/percent (comma-aware) to match the
                    // sizeInfo computation above and the bestOpportunityCard onCopy at line ~3304.
                    // Double("10,000") == nil; StockSageInput.positiveAmount("10,000") == 10000.
                    let plan = StockSageTodayPlan.build(
                        idea: idea, ev: ev,
                        account: StockSageInput.positiveAmount(sizerAccount),
                        riskFraction: StockSageInput.percent(sizerRiskPct).map { $0 / 100 },
                        daysToEarnings: store.earnings[idea.symbol.uppercased()]?.daysUntil,
                        isSample: store.isSampleData,
                        // TODAY-PARITY: same held-position awareness rankedActions/the ideas
                        // board's Held chip already carry — display-only.
                        positions: portfolio.positions,
                        // Round-H: flags a cache-stale price in the copied plan itself.
                        priceAsOf: idea.priceAsOf,
                        fxRatesToUSD: sizingFXRates(for: [idea.symbol]),
                        // A3: carry the same analysis-stale flag the card's pixels show.
                        analysisStale: analysisStaleOnly)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plan, forType: .string)
                },
                mvFont9: mvFont9,
                mvFont10: mvFont10,
                mvFont11: mvFont11,
                mvFont12: mvFont12,
                mvFont13: mvFont13,
                mvFont15: mvFont15)
        }
    }

    // Fast lane — the highest-turnover positive-EV setups, split into a crypto (24/7, ~3d hold)
    // board and an equity (9:30–4, ~12d hold) board, since blending them hides that the two run
    // on entirely different clocks (FASTMONEY_BACKLOG #7).
    /// The fast-lane strip's "$/week" sentence, built as a plain String OUTSIDE the ViewBuilder so
    /// its arithmetic + the same-basket-gross engine call don't tip `fastLaneStrip`'s body over the
    /// Swift type-check budget. Net-first (net when available, labeled gross beside); the gross
    /// parenthetical is the SAME-BASKET aware gross (F9 / engine's weeklyRGrossSameBasket path),
    /// never the unaware `wk` which can print gross below net across the 0.70 haircut; signs come
    /// from the values so a net-cost-demoted (negative) lane never renders "+$-42" (B1).
    private func fastLaneWeeklyDollarLine(wk: Double, netWkOpt: Double?, lane: [StockSageIdea],
                                          tradingDays: Double, acct: Double, rp: Double) -> String {
        let usd = (netWkOpt ?? wk) * acct * (rp / 100)
        let grossPart: String
        if netWkOpt != nil {
            let grossSame = StockSageExpectedValue.expectedWeeklyR(lane: lane, ideas: store.ideas, tradingDays: tradingDays, holds: velocityHolds, calibration: store.convictionCalibration, earnings: store.earnings, liquidity: store.liquidity) ?? wk
            let g = grossSame * acct * (rp / 100)
            grossPart = String(format: " (gross %@$%.0f)", g < 0 ? "-" : "+", abs(g))
        } else {
            grossPart = ""
        }
        return String(format: "≈ %@$%.0f/week at $%.0f account, %.1f%% risk — %@%@; estimate, high variance, NOT income.",
                      usd < 0 ? "-" : "+", abs(usd), acct, rp, netWkOpt != nil ? "net of est. costs" : "gross, before costs", grossPart)
    }

    @ViewBuilder private var fastLaneStrip: some View {
        let lane = StockSageExpectedValue.fastLane(store.ideas, holds: velocityHolds, calibration: store.convictionCalibration, earnings: store.earnings, liquidity: store.liquidity)
        if lane.count >= 2 {
            // PERF-STRIP: pure filter of the already-computed `lane` above — byte-identical to
            // calling StockSageExpectedValue.fastLaneByClass(store.ideas, ...) (its body does
            // exactly this: fastLane(...) then filter by asset class with the SAME args), but
            // without recomputing fastLane a second time. Does NOT touch the with/without-earnings
            // lane distinction (owner-gated F03/F44/L4-2 territory) — this only splits ONE already-
            // resolved lane by asset class.
            let split = (crypto: lane.filter { StockSageAllocation.assetClass($0.symbol) == "Crypto" },
                         equity: lane.filter { StockSageAllocation.assetClass($0.symbol) == "Equity" })
            // PERF-STRIP: computed once, reused below — was recomputed (each a full fastLane pass)
            // at every one of its 3 call sites in this view with byte-identical arguments.
            // BIND-ONCE (post-ship perf probe): now sourced from the `lane:` overload, which
            // takes the `lane` already bound above instead of re-deriving fastLane a 4th time.
            let tradingDays = StockSageExpectedValue.tradingDaysForLane(lane: lane)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "hare.fill").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.accent)
                    Text("Fast lane — fastest compounding").font(.system(size: mvFont11, weight: .bold)).foregroundStyle(.white)
                    Spacer()
                    // Post-restriction (2026-07-16): the board picker is a stale affordance when
                    // no crypto lane exists (crypto left the universe; it reappears only via a
                    // watchlisted crypto name that yields ideas) — data-driven visibility, so the
                    // "Crypto" segment is offered exactly when a crypto lane can render.
                    if !split.crypto.isEmpty {
                        DSSegmentPicker(cases: Array(FastLaneBoard.allCases),
                                        selection: $fastLaneBoard) { $0.rawValue }
                        // 170 (the old NSSegmentedControl width) truncated two of the
                        // three equal-width pill segments ("Cry…"/"Equi…") — DSSegment-
                        // Picker splits width evenly; "Equities" at 12pt semibold needs
                        // ~200 total (review 2026-07-16, offscreen-render verified).
                        .frame(width: 200)
                        .accessibilityLabel("Fast-lane board filter")
                    }
                }
                // Why the order can differ from raw EV/day: it's ranked by growth RATE.
                Text("Ranked by growth rate (log-growth at ½-Kelly) — a steady compounder can out-rank a higher-EV/day but higher-variance lottery setup.")
                    .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                if fastLaneBoard != .equities {
                    fastLaneBoardSection(title: "Crypto fast lane (base ~\(Int(cryptoHoldDays))d, 24/7)", ideas: split.crypto)
                }
                // `|| split.crypto.isEmpty`: a persisted "Crypto" selection from before the
                // 2026-07-16 restriction must never blank the whole strip — with no crypto lane,
                // equities ALWAYS show (the picker above is hidden in that state, so the stale
                // @AppStorage value is unreachable-to-change yet must not act).
                if fastLaneBoard != .crypto || split.crypto.isEmpty {
                    fastLaneBoardSection(title: "Equity swing lane (base ~\(Int(equityHoldDays))d)", ideas: split.equity)
                }

                if !split.crypto.isEmpty, !split.equity.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.and.right").font(.system(size: mvFont9)).foregroundStyle(.secondary)
                        if let c = store.laneCorrelationValue {
                            Text(String(format: "Correlation now: %.2f (%@)", c,
                                        c >= 0.5 ? "moving together — poor hedge" : (c <= -0.2 ? "genuinely offsetting" : "loosely related")))
                                .font(.system(size: mvFont9, weight: .medium))
                                .foregroundStyle(c >= 0.5 ? DS.Palette.warningSoft : DS.Palette.textSecondary)
                        } else if store.laneCorrelationCompleted {
                            // G1: attempt finished with no value (failed/policy-blocked) — say so
                            // instead of a "fetching…" spinner that would never resolve.
                            Text("Correlation unavailable").font(.system(size: mvFont9)).foregroundStyle(.secondary)
                        } else {
                            Text("Correlation — fetching…").font(.system(size: mvFont9)).foregroundStyle(.secondary)
                        }
                    }
                    .task(id: (split.crypto.map(\.symbol) + split.equity.map(\.symbol)).sorted()) {
                        await store.refreshLaneCorrelation(holds: velocityHolds)
                    }
                    if StockSageExpectedValue.cryptoRotationDominant(crypto: split.crypto, equity: split.equity, holds: velocityHolds, calibration: store.convictionCalibration) {
                        Text("⚠︎ Fastest rotation is 24/7 crypto — gap risk; size down if you sleep. \(MoneyVelocityCopy.cannotHedgeOvernight)")
                            .font(.system(size: mvFont9, weight: .medium))
                            .foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // REVERT (review round, 2026-07-08): the BIND-ONCE dedupe previously passed this
                // strip's earnings/liquidity-AWARE `lane` into GROSS expectedWeeklyR — silently
                // executing the PARKED owner-gated L4-2 decision (F03/F44 surface; the map's own
                // "GROSS expectedWeeklyR stays undemoted-lane" invariant). Reverted to the
                // ideas-only unaware overload; `tradingDays: tradingDays` stays (order- and
                // membership-insensitive per tradingDaysForLane(lane:)'s own doc, so reusing the
                // already-bound value here is still byte-identical, no owner-gate exposure).
                if let wk = StockSageExpectedValue.expectedWeeklyR(store.ideas, tradingDays: tradingDays, holds: velocityHolds, calibration: store.convictionCalibration) {
                    // F03/F44: gross label + floor-demotion caveat (the weekly sum never excludes
                    // floor-demoted ideas; the per-row floor badges below DO mark them).
                    Text(String(format: "≈ %+.1fR/week gross, before costs, if you run the top %d — estimate, high variance, assumes you take and re-cycle these. Not a promise.", wk, Swift.min(3, lane.count)))
                        .font(.system(size: mvFont9, weight: .medium))
                        .foregroundStyle(DS.Palette.successSoft).fixedSize(horizontal: false, vertical: true)
                        .help(weeklyGrossHelp("Gross, before costs — sums the top fast-lane GROSS velocities. It can include ideas the net-cost floor demotes on the boards; the 'Fastest' pick excludes them. An estimate, not income.", tradingDays: tradingDays))
                    let netWkOpt = StockSageExpectedValue.netExpectedWeeklyR(lane: lane, ideas: store.ideas, tradingDays: tradingDays, holds: velocityHolds, calibration: store.convictionCalibration, earnings: store.earnings, liquidity: store.liquidity)
                    if let netWk = netWkOpt {
                        Text(String(format: "   ↳ %+.1fR/week net (after est. costs)", netWk))
                            .font(.system(size: mvFont8)).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    // PERF-STRIP: expectedWeeklyDollars's body is exactly `wkR * account * riskFraction`
                    // once its guards pass — `wk` above IS that wkR (byte-identical args: same ideas,
                    // tradingDays, holds, calibration), so this avoids a second full fastLane recompute
                    // for arithmetic StockSageInput already guarded (acct/rp finite and positive).
                    if let acct = StockSageInput.positiveAmount(sizerAccount), let rp = StockSageInput.percent(sizerRiskPct) {
                        // C1/B1 arithmetic + the same-basket-gross engine call are hoisted into
                        // fastLaneWeeklyDollarLine (a plain func) so they don't tip fastLaneStrip's
                        // ViewBuilder body over the Swift type-check budget (it timed out inline).
                        Text(fastLaneWeeklyDollarLine(wk: wk, netWkOpt: netWkOpt, lane: lane, tradingDays: tradingDays, acct: acct, rp: rp))
                            .font(.system(size: mvFont9, weight: .medium))
                            .foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)   // neutral: estimate, not a realized gain
                            .help((netWkOpt != nil ? "Net of est. costs — weekly R × the dollar value of 1R. " : "Gross, before costs — weekly R × the dollar value of 1R. ") + "Can include ideas the net-cost floor demotes on the boards; the 'Fastest' pick excludes them. NOT income.")
                    }
                }
                if let conc = StockSageExpectedValue.fastLaneConcentration(lane: lane), conc.isConcentrated {
                    Text("⚠︎ Your top \(conc.total) fastest are all \(conc.dominantClass) — likely correlated; that's closer to ONE bet than \(conc.total). Size all \(conc.total) TOGETHER at 1-2% total risk, not per symbol.")
                        .font(.system(size: mvFont9, weight: .medium))
                        .foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                }
                Text(MoneyVelocityCopy.fastLane)
                    .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.md) {
                    Text("Hold est:").font(.system(size: mvFont9)).foregroundStyle(.secondary)
                    Stepper(value: $cryptoHoldDays, in: 1...60, step: 1) {
                        Text("crypto \(Int(cryptoHoldDays))d").font(.system(size: mvFont9)).foregroundStyle(.white)
                    }.frame(maxWidth: 132)
                    Stepper(value: $equityHoldDays, in: 1...180, step: 1) {
                        Text("equity \(Int(equityHoldDays))d").font(.system(size: mvFont9)).foregroundStyle(.white)
                    }.frame(maxWidth: 132)
                    Spacer(minLength: 0)
                }
                .help("Anchor for each idea's estimated hold — the engine adjusts per setup (target distance ÷ typical daily move, clamped 0.4–3× this value). A shorter anchor biases the hold estimate down but the per-idea adjustment can override it.")
            }
            .padding(DS.Space.sm).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.accent.opacity(0.25), lineWidth: 1))
            .help(StockSageGlossary.explain(.fastLane))
        }
    }

    /// One asset-class sub-board (title + up to 5 rows). Hidden entirely when its bucket is empty
    /// (e.g. an all-equity day shows no "Crypto fast lane" header at all).
    @ViewBuilder private func fastLaneBoardSection(title: String, ideas: [StockSageIdea]) -> some View {
        if !ideas.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(.system(size: mvFont8, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(ideas.prefix(5), id: \.id) { idea in fastLaneRow(idea) }
            }
        }
    }

    /// A single fast-lane row — factored out of the old inline ForEach so both boards share it
    /// byte-identically (same fields, same accessibility label as before the split).
    @ViewBuilder private func fastLaneRow(_ idea: StockSageIdea) -> some View {
        if let v = StockSageExpectedValue.velocity(for: idea, holds: velocityHolds, calibration: store.convictionCalibration) {
            let floorFlag = StockSageExpectedValue.netCostFloorFlag(for: idea, holds: velocityHolds, calibration: store.convictionCalibration)
            let earnFlag  = StockSageExpectedValue.earningsRankFlag(for: idea, earnings: store.earnings)
            Button { selectedIdea = idea } label: {
                HStack(spacing: DS.Space.sm) {
                    Text(idea.symbol).font(.system(size: mvFont12, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 84, alignment: .leading)
                    Text(String(format: "%+.3fR/day gross", v)).font(.system(size: mvFont11, design: .monospaced))
                        .foregroundStyle(DS.Palette.successSoft)
                    // Momentum dot FIRST (highest-differential signal), then
                    // earnings and floor badges. "24/7 · volatile" removed —
                    // the section header already says "24/7" for all crypto rows.
                    // FASTMONEY #5 — momentum quality dot: colored indicator when the field is
                    // non-nil (nil → show NOTHING, per honesty-floor: no fabricated neutral).
                    // Natural values are 0, 1/3, 2/3, 1 (3 binary signals averaged).
                    if let mq = idea.momentumQuality {
                        let mqHot   = mq >= 2.0 / 3.0
                        let mqMixed = mq >= 1.0 / 3.0
                        let mqColor = mqHot ? DS.Palette.successSoft : mqMixed ? DS.Palette.warningSoft : DS.Palette.dangerSoft
                        let mqLabel = mqHot ? "hot" : mqMixed ? "mixed" : "cold"
                        HStack(spacing: 3) {
                            Circle().fill(mqColor).frame(width: 5, height: 5)
                            Text(mqLabel).font(.system(size: mvFont8)).foregroundStyle(mqColor)
                        }
                        .help("Momentum read: ER trend + MACD histogram + 21-day return — short histories may use fewer than 3 signals. A 1-day blip is not a 3-12d win. Descriptive, not predictive.")
                    }
                    if !earnFlag.badge.isEmpty {
                        Text(earnFlag.badge).font(.system(size: mvFont8))
                            .foregroundStyle(earnFlag.isDemoted ? DS.Palette.warningSoft : .secondary)
                    }
                    if floorFlag.isDeranked {
                        Text("below net-cost floor").font(.system(size: mvFont8)).foregroundStyle(DS.Palette.warningSoft)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: mvFont8)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(LuxPressStyle())
            .accessibilityLabel({
                var label = "\(idea.symbol): \(String(format: "%+.3f", v)) R per day gross velocity"
                // a11y: momentum first (matches new visual order), 24/7 retained for VoiceOver users
                if let mq = idea.momentumQuality {
                    let mqLabel = mq >= 2.0/3.0 ? "hot" : mq >= 1.0/3.0 ? "mixed" : "cold"
                    label += ", momentum \(mqLabel)"
                }
                if StockSageAllocation.assetClass(idea.symbol) == "Crypto" { label += ", 24/7 volatile" }
                if !earnFlag.badge.isEmpty { label += ", \(earnFlag.badge)" }
                if floorFlag.isDeranked { label += ", below net-cost floor" }
                label += ". Tap for the plan."
                return label
            }())
        }
    }

    // Today's ranked action list (FASTMONEY_BACKLOG #4) — the fast lane's top-3 by velocity,
    // each row already sized (PositionSizer, the account/risk% set below) and gated
    // (TradeGate) so "do I take #1 or #2 today?" doesn't require opening 3 detail sheets.
    // Same fast-lane ordering as fastLaneStrip above; this adds the size + verdict it doesn't show.
    @ViewBuilder private var todaysActionsCard: some View {
        let plans = StockSageTodayPlan.rankedActions(
            store.ideas,
            account: StockSageInput.positiveAmount(sizerAccount),
            riskFraction: StockSageInput.percent(sizerRiskPct).map { $0 / 100 },
            holds: velocityHolds,
            calibration: store.convictionCalibration,
            marketRegime: store.regime,
            earnings: store.earnings,
            liquidity: store.liquidity,
            // TODAY-PARITY: same held/journal awareness the ideas board's Held/Traded chips
            // already carry — display-only (see TodayActionPlan.heldShares doc).
            positions: portfolio.positions,
            journalTrades: journal.trades,
            mode: .equityExecutableFirst,
            fxRatesToUSD: sizingFXRates(for: store.ideas.map(\.symbol)))
        // F8 (2026-07-09): the global "Do this now" CTA's own pick, so this card can disclose it
        // when it names a different symbol than this list's own #1 row — the SAME bestOpportunity
        // call bestOpportunityCTA already makes (byte-identical inputs), just for its symbol.
        let globalBestSymbol = StockSageExpectedValue.bestOpportunity(store.ideas, regime: store.regime, earnings: store.earnings, liquidity: store.liquidity, seasonality: store.seasonality, calibration: store.convictionCalibration)?.idea.symbol
        MarketsTodayActionsCard(plans: plans, isSampleData: store.isSampleData, onSelectSymbol: { symbol in
            if let idea = store.ideas.first(where: { $0.symbol == symbol }) { selectedIdea = idea }
        }, globalBestSymbol: globalBestSymbol)
    }

    // Strategy backtest — the advisor's rules aggregated across the sample universe.
    private var strategyBacktestPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: mvFont16)).foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Strategy backtest").font(DS.Typography.titleM).foregroundStyle(.white)
                        .help(StockSageGlossary.strategyHelp)
                    Text(store.strategyBacktest.map { "Tested \($0.symbolsTested)/\(StockSageStrategyBacktest.sampleSymbols.count) names, ~5 years — does the system hold up?" }
                         ?? "The advisor's rules across the sample (~\(StockSageStrategyBacktest.sampleSymbols.count) names), ~5 years — does the system hold up?")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { Task { await store.refreshStrategyBacktest() } } label: {
                    HStack(spacing: 6) {
                        Group {
                            if store.isLoadingStrategy { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "play.fill").font(.system(size: mvFont10, weight: .semibold)) }
                        }
                        Text(store.isLoadingStrategy ? "Running…" : "Run").font(.system(size: mvFont11, weight: .semibold)).contentTransition(.opacity)
                    }
                    .foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 6)
                    .background(DS.Palette.accent, in: Capsule())
                }
                .buttonStyle(LuxPressStyle()).disabled(store.isLoadingStrategy)
                .help("Backtest the advisor's rules across the sample universe (~5y each)")
            }
            if let e = store.strategyError {
                Text(e).font(.caption2).foregroundStyle(DS.Palette.warningSoft)
            }
            if let s = store.strategyBacktest {
                HStack(spacing: DS.Space.sm) {
                    ideaMetric("Trades", "\(s.totalTrades)")
                    // Break-even for the fixed 2:1 exit is 1/(1+2) ≈ 33%, not 50% — coloring danger
                    // below 50% would flag every profitable 35-49% win-rate system as a loser.
                    // AUDIT_FINDINGS_2 #1: significance gates the COLOR (the verdict), not just
                    // the caption — an insignificant sample renders these NEUTRAL.
                    ideaMetric("Win", String(format: "%.0f%%", s.blendedWinRate * 100),
                               color: BacktestVerdict.metricColor(positive: s.blendedWinRate >= 1.0 / 3, significant: s.isSignificant))
                    ideaMetric("Avg R", String(format: "%+.2f", s.avgR),
                               color: BacktestVerdict.metricColor(positive: s.avgR >= 0, significant: s.isSignificant))
                    ideaMetric("Total R", String(format: "%+.0f", s.totalR),
                               color: BacktestVerdict.metricColor(positive: s.totalR >= 0, significant: s.isSignificant))
                    ideaMetric("Worst-name DD", String(format: "−%.0fR", s.worstDrawdownR), color: DS.Palette.dangerSoft)
                    ideaMetric("Pooled DD (eq-wt)", String(format: "−%.0fR", s.pooledDrawdownR), color: DS.Palette.dangerSoft)
                        .help("Equal-weight pooled proxy: all trades across all names, sorted chronologically, cumulative-R worst peak-to-trough. Ignores position sizing and concurrency — not a true sized-portfolio drawdown. Typically larger than worst single-name DD because losses across symbols stack in time.")
                    ideaMetric("Profit.", "\(s.symbolsProfitable)/\(s.symbolsWithTrades)")
                    Spacer(minLength: 0)
                }
                if !s.isSignificant && s.totalTrades > 0 {
                    Text("⚠︎ \(s.totalTrades) trades — still a small sample; treat as illustrative.")
                        .font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                }
                // Honest significance vs the t>3 multiple-testing bar (matches the per-symbol panel).
                // PASS requires enough trades AND the fat-tail-corrected t too — never a green check
                // next to a "not meaningful yet" verdict or on a normal-assumption t the tails sink.
                if s.totalTrades > 0 {
                    let pass = s.passesHonestSignificance
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Image(systemName: pass ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: mvFont10))
                        Text(s.significanceVerdict).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption2)
                    .foregroundStyle(pass ? DS.Palette.successSoft : DS.Palette.warningSoft)
                    .help("Harvey-Liu-Zhu (2016): with many strategy variants tried, the significance bar rises to t>3 (not 2.0). Necessary, not sufficient.")
                }
                // Deflated Sharpe: the honest "real edge" bar — PSR plus selection-bias haircut for
                // ~estimatedStrategyTrials variants tried. DSR > 0.95 is the engine's own definition
                // of "real edge" (StockSageDeflatedSharpe.Result.passes). The per-symbol panel shows
                // PSR only (no selection-bias term); this panel shows both so the two read together.
                if s.totalTrades > 0, let d = s.deflatedSharpe {
                    // #8 (mirrors round-g FIX-4 for the per-symbol PSR): the green DSR seal must not
                    // sit beside this panel's own "<100 trades, not meaningful yet" verdict. DSR
                    // populates at n≥4 and a high small-sample Sharpe can clear 0.95, so gate the
                    // glyph/word/color on isSignificant too (deflatedSharpeShowsPass). The DSR NUMBER
                    // still always shows — only the PASS seal/word is withheld until the sample is
                    // statistically meaningful.
                    let dpass = s.deflatedSharpeShowsPass
                    let dWord = s.isSignificant ? (dpass ? "PASS (honest bar >95%)" : "UNPROVEN (honest bar >95%)")
                                                : "UNPROVEN (sample too small — <100 trades)"
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Image(systemName: dpass ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: mvFont10))
                        Text(String(format: "Deflated Sharpe (selection-bias haircut, ~%d variants tried): DSR %.0f%% — %@.",
                                    d.trials, d.dsr * 100, dWord))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption2)
                    .foregroundStyle(dpass ? DS.Palette.successSoft : DS.Palette.warningSoft)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(format: "Deflated Sharpe, selection bias haircut for %d variants. DSR %.0f percent. %@.",
                                               d.trials, d.dsr * 100,
                                               dpass ? "Passes the honest bar"
                                                     : (s.isSignificant ? "Unproven, below honest bar"
                                                                        : "Unproven, sample too small under 100 trades")))
                    .help(StockSageDeflatedSharpe.caveat)
                }
                Text(s.caveat).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // Calibration status — F01/F02: keyed on the fit METHOD, not on non-nil. Only the
            // Wilson-LCB isotonic / OOS-validated Beta paths may claim "measured"; a Platt fit is
            // a central estimate ("fitted"); an identity calibration is an assumption and says so.
            if let cal = store.convictionCalibration {
                let assumed = cal.method == .identity
                HStack(spacing: 6) {
                    Image(systemName: assumed ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.system(size: mvFont11))
                        .foregroundStyle(assumed ? DS.Palette.warningSoft : DS.Palette.successSoft)
                    Text(assumed
                         ? "EV win-prob is currently the identity floor — conviction, capped at the conservative ~\(StockSageExpectedValue.assumedWinBandLabel) prior when the sample is too thin to validate out-of-sample, used as win%, assumed, not measured; more closed trades let a real fit earn 'measured'."
                         : (cal.method == .platt
                            ? "EV fitted from \(cal.sampleSize) realized trades (your journal when rich enough, else the backtest) — a central fit, not a conservative bound."
                            : "EV calibrated from \(cal.sampleSize) realized trades (your journal when rich enough, else the backtest) — measured, not assumed."))
                        .font(.caption2)
                        .foregroundStyle(assumed ? DS.Palette.warningSoft : DS.Palette.successSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help(cal.chipHelp)
            }
            // Out-of-sample honesty check: does the conviction map hold on trades it was NOT fit on?
            if let oos = store.calibrationOOS {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: oos.addsSkill ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: mvFont11))
                        .foregroundStyle(oos.addsSkill ? DS.Palette.successSoft : DS.Palette.warningSoft)
                    Text(oos.addsSkill
                         ? String(format: "Conviction map holds out-of-sample: Brier %.2f vs %.2f no-skill baseline (%d test trades) — small sample, still firming up.", oos.oosBrier, oos.baselineBrier, oos.n)
                         : String(format: "Out-of-sample check: not beating the base-rate yet (Brier %.2f vs %.2f, %d test trades) — small sample, treat as unproven.", oos.oosBrier, oos.baselineBrier, oos.n))
                        .font(.caption2)
                        .foregroundStyle(oos.addsSkill ? DS.Palette.successSoft : DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help("Fits the conviction→win-probability map on your earlier trades and scores it on later, held-out ones (purged/embargoed split). It earns trust only by beating a no-skill base-rate predictor out-of-sample. Noisy on a small journal.")
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    // Backtest result panel — appears when a symbol has been (or is being) tested.
    @ViewBuilder private var backtestPanel: some View {
        if store.isBacktesting || store.backtest != nil || store.backtestError != nil {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: mvFont13)).foregroundStyle(DS.Palette.accent)
                    Text(backtestTitle).font(.system(size: mvFont13, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    if store.isBacktesting { ProgressView().controlSize(.small).tint(DS.Palette.accent) }
                }
                if let err = store.backtestError {
                    Text(err).font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                } else if let bt = store.backtest {
                    HStack(spacing: DS.Space.sm) {
                        ideaMetric("Trades", "\(bt.trades)")
                        // Break-even for the fixed 2:1 exit is 1/(1+2) ≈ 33%, not 50%.
                        // AUDIT_FINDINGS_2 #1: significance gates the COLOR — see BacktestVerdict.
                        ideaMetric("Win", String(format: "%.0f%%", bt.winRate * 100),
                                   color: BacktestVerdict.metricColor(positive: bt.winRate >= 1.0 / 3, significant: bt.isSignificant))
                        ideaMetric("Avg R", String(format: "%+.2f", bt.avgR),
                                   color: BacktestVerdict.metricColor(positive: bt.avgR >= 0, significant: bt.isSignificant))
                        ideaMetric("Total R", String(format: "%+.1f", bt.totalR),
                                   color: BacktestVerdict.metricColor(positive: bt.totalR >= 0, significant: bt.isSignificant))
                        ideaMetric("Max DD", String(format: "−%.1fR", bt.maxDrawdownR), color: DS.Palette.dangerSoft)
                        // bt.sharpe is 0 when <2 trades or zero variance (engine sentinel, not a measurement).
                        ideaMetric("Sharpe", bt.trades >= 2 ? String(format: "%.2f", bt.sharpe) : "n/a")
                        Spacer(minLength: 0)
                    }
                    if !bt.isSignificant && bt.trades > 0 {
                        Text("⚠︎ Only \(bt.trades) trades — too small a sample to trust; treat as illustrative.")
                            .font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                    } else if bt.trades == 0 {
                        Text("The rules never triggered a long entry over this window.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if bt.openAtEndCount > 0 {
                        Text("⚠︎ \(bt.trades - bt.openAtEndCount) closed · \(bt.openAtEndCount) open at end — open trades exit at last close, so avgR may be optimistic.")
                            .font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                    }
                    // Real-edge confidence: PSR (sample/skew/fat-tail haircut) + out-of-sample decay (overfit).
                    if let psr = bt.probabilisticSharpe {
                        // FIX 4 (round-g): gate the PASS verdict on bt.isSignificant too — mirroring
                        // the aggregate panel's passesHonestSignificance (#8: "a PASS glyph can never
                        // sit next to a not-meaningful verdict"). probabilisticSharpe populates at
                        // trades≥4 and the √(n−1) scaling can clear 0.95 at tiny n, which previously
                        // rendered a green "PASS" seal directly beside the "too small a sample to
                        // trust" warning above. The PSR NUMBER still always shows; only the glyph/
                        // wording is gated. Glyph + PASS/BELOW word so the verdict survives color-
                        // blindness (successSoft/warningSoft collapse under deuteranopia) + a11y label.
                        let pass = psr > 0.95 && bt.isSignificant
                        let verdictWord = bt.isSignificant ? (pass ? "PASS" : "BELOW BAR") : "BELOW BAR (sample too small)"
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                            Image(systemName: pass ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: mvFont10))
                            Text(String(format: "Real-edge confidence (PSR): %.0f%% — %@ (P(true Sharpe > 0) after a sample/skew/fat-tail haircut; clears sample/skew bar but does NOT include the multi-name selection-bias haircut — see strategy backtest for DSR).", psr * 100, verdictWord))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption2)
                        .foregroundStyle(pass ? DS.Palette.successSoft : DS.Palette.warningSoft)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(String(format: "Real edge confidence, probabilistic Sharpe ratio %.0f percent, %@.", psr * 100, verdictWord))
                        .accessibilityHint(StockSageDeflatedSharpe.caveat)
                        .help(StockSageDeflatedSharpe.caveat)
                    }
                    // Significance vs the t>3 multiple-testing bar (Harvey-Liu-Zhu 2016): t>2 is NOT
                    // enough once you've tried many rule variants. Necessary, not sufficient.
                    if bt.isSignificant {
                        let pass = bt.clearsMultipleTestingBar
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                            Image(systemName: pass ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: mvFont10))
                            Text(bt.significanceVerdict).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption2)
                        .foregroundStyle(pass ? DS.Palette.successSoft : DS.Palette.warningSoft)
                        .help("Harvey-Liu-Zhu (2016): once many strategy variants are tried, the significance bar rises to t>3 (not the textbook 2.0). This is necessary, not sufficient — it can't see how many variants you actually tested.")
                    }
                    if let d = bt.decay {
                        // decayRatio is 0 when isAvgR ≤ 0 (engine sentinel: no in-sample edge to decay
                        // from). Saying "kept 0% of the edge" in that case is nonsense — show the
                        // raw transition instead so the user sees what actually happened.
                        let tail = d.isRedFlag ? " — RED FLAG: likely overfit; the edge collapsed out-of-sample."
                                               : (d.oosSignificant ? "." : " — OOS sample thin (<20), low confidence.")
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                            if d.isRedFlag {
                                Image(systemName: "exclamationmark.octagon.fill").font(.system(size: mvFont10))
                            }
                            if d.isAvgR <= 0 {
                                Text(String(format: "No in-sample edge to decay from (in-sample %+.2fR → out-of-sample %+.2fR)%@",
                                            d.isAvgR, d.oosAvgR, tail))
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(String(format: "Out-of-sample: kept %.0f%% of the edge (in-sample %+.2fR → out-of-sample %+.2fR)%@",
                                            d.decayRatio * 100, d.isAvgR, d.oosAvgR, tail))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(d.isRedFlag ? DS.Palette.dangerSoft : .secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(d.isAvgR <= 0
                            ? String(format: "No in-sample edge. In sample %+.2f R, out of sample %+.2f R.%@",
                                     d.isAvgR, d.oosAvgR, tail)
                            : String(format: "Out of sample, kept %.0f percent of the edge. In sample %+.2f R to out of sample %+.2f R.%@",
                                     d.decayRatio * 100, d.isAvgR, d.oosAvgR, tail))
                    }
                    // L3 (2026-07-09, DISPLAY-ONLY): reframed as realized left-tail truncation
                    // (quant_engine_II.md checklist #3) — two channels, not one comparison line.
                    // Tail channel (headline): the robust, mechanical part — how much the wide
                    // trail cuts the worst trade / worst drawdown / per-trade stdev, fixed→trail.
                    // Return channel: the SAME tie-aware verdict this line replaced, folded in —
                    // a momentum/regime bet that can be negative (Kaminski-Lo), not a free win.
                    if let trail = store.backtestTrail, bt.trades > 0, trail.trades > 0 {
                        let ddBetter = trail.maxDrawdownR < bt.maxDrawdownR - 0.05
                        let retBetter = trail.avgR > bt.avgR + 0.005
                        // A tie is a tie — don't declare a winner when neither margin is cleared.
                        let ddWorse = bt.maxDrawdownR < trail.maxDrawdownR - 0.05
                        let retWorse = bt.avgR > trail.avgR + 0.005
                        let verdict = ddBetter
                            ? (retBetter ? "trail wins on both" : "trail cuts drawdown, gives up some return")
                            : (retBetter ? "trail adds return at a deeper drawdown"
                               : (!ddWorse && !retWorse ? "about a wash here" : "fixed 2:1 holds up better here"))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                                Image(systemName: "arrow.triangle.branch").font(.system(size: mvFont10))
                                Text(String(format: "Left-tail truncation (fixed 2:1 → trail): worst trade %+.2fR → %+.2fR · worst drawdown −%.1fR → −%.1fR · per-trade stdev %.2f → %.2f (realized, net of round-trip costs, this symbol's 5y).",
                                            bt.worstTradeR, trail.worstTradeR, bt.maxDrawdownR, trail.maxDrawdownR, bt.stdevR, trail.stdevR))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(String(format: "Return effect: avg %+.2fR → %+.2fR — %@ — a momentum/regime bet that can be negative, not a free improvement.",
                                        bt.avgR, trail.avgR, verdict))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("Same entry rules, two exits, both charged the round-trip cost. Under a random walk a stop always LOWERS expected return (Kaminski-Lo) — any avg-R gain is a regime bet. The robust, mechanical part is the vol/tail cut (Han-Zhou-Zhu: left-tail truncation) — a risk-preference trade, not alpha. One symbol's 5y, whole-window (not per-regime); trade counts differ between modes. RESEARCH_2026-06-27_quant_engine_II.md checklist #3.")
                    }
                    if let u = store.underwater, !u.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Buy & hold underwater (5y)").font(.system(size: mvFont10, weight: .semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "worst −%.0f%% · longest %d bars under", u.maxDrawdown, u.longestUnderwaterBars))
                                    .font(.system(size: mvFont9, weight: .semibold)).foregroundStyle(DS.Palette.dangerSoft)
                            }
                            underwaterSparkline(u)
                        }
                    }
                    Text("Past performance ≠ future. Survivorship bias — only currently-listed names are tested. Rules are fixed, not optimized per symbol.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.accent.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(DS.Palette.accent.opacity(0.30), lineWidth: 1))
            .transition(.opacity.combined(with: .offset(y: -4)))
        }
    }

    /// Red area chart hanging from a 0 (new-high) line down to the worst drawdown.
    private func underwaterSparkline(_ u: UnderwaterCurve) -> some View {
        // Downsample for the path (5y daily ≈ 1250 pts) while keeping depth/duration from the full series.
        let s = u.series
        // Min-preserving buckets: each plotted point is the WORST (most negative)
        // value in its window, so downsampling can never skip the trough and
        // visually understate the drawdown vs the stated worst number.
        let k = max(1, s.count / 240)
        let plot: [Double] = s.count > 240
            ? stride(from: 0, to: s.count, by: k).map { lo in s[lo..<min(lo + k, s.count)].min() ?? s[lo] }
            : s
        let denom = -Swift.max(u.maxDrawdown, 0.5)   // bottom of the chart (avoid /0)
        return GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = plot.count
            let point: (Int) -> CGPoint = { i in
                let x = n > 1 ? w * CGFloat(i) / CGFloat(n - 1) : 0
                let frac = CGFloat(plot[i] / denom)   // 0 at a new high → 1 at the worst
                return CGPoint(x: x, y: h * min(max(frac, 0), 1))
            }
            ZStack {
                Path { p in
                    guard n > 0 else { return }
                    p.move(to: CGPoint(x: 0, y: 0))
                    for i in 0..<n { p.addLine(to: point(i)) }
                    p.addLine(to: CGPoint(x: w, y: 0))
                    p.closeSubpath()
                }.fill(DS.Palette.danger.opacity(0.18))
                Path { p in
                    guard n > 0 else { return }
                    p.move(to: point(0))
                    for i in 1..<n { p.addLine(to: point(i)) }
                }.stroke(DS.Palette.danger.opacity(0.85), lineWidth: 1)
            }
        }
        .frame(height: 34)
        .accessibilityLabel(String(format: "Underwater curve, worst drawdown %.0f percent", u.maxDrawdown))
    }

    /// UI-wave (Gemini #3, detail sheet): compact waterfall of the per-idea sizing-brake
    /// chain — base half-Kelly → regime-adjusted → vol-regime-brake. ONLY numbers that
    /// already exist per-idea and are already shown/derivable on this sheet (Base size /
    /// Regime size / Vol-adj, same symbols as the HStack above) — no fabricated stages.
    /// Correlation de-weighting + heat cap are PORTFOLIO-level (allocator), so they get no
    /// per-idea bar; the footer reuses the exact established `sizeMetricHelp` wording.
    /// A stage whose input is nil is omitted entirely (nil ⇒ nothing rendered); fewer than
    /// 2 resolved stages ⇒ the whole waterfall renders nothing (no single-bar waterfall).
    private func sizingBrakeStages(_ idea: StockSageIdea) -> [(label: String, value: Double)] {
        let a = idea.advice
        guard a.suggestedWeight > 0 else { return [] }
        var stages: [(label: String, value: Double)] = [("Base size", a.suggestedWeight)]
        if let r = store.regime {
            let adj = StockSageRegime.adjustedWeight(base: a.suggestedWeight, bias: r.sizingBias, cap: StockSageAdvisor.maxWeight)
            stages.append(("Regime size", adj))
        }
        if let vr = idea.volRegime {
            stages.append(("Vol-adj size", a.suggestedWeight * vr.sizingMultiplier))
        }
        return stages
    }

    @ViewBuilder private func sizingBrakeWaterfall(_ idea: StockSageIdea) -> some View {
        let stages = sizingBrakeStages(idea)
        if stages.count >= 2 {
            let base = stages[0].value
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sizing brakes").font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(stages.indices, id: \.self) { i in
                        let s = stages[i]
                        HStack(spacing: 8) {
                            Text(s.label).font(.system(size: mvFont9)).foregroundStyle(.secondary)
                                .frame(width: 78, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 8)
                                    Capsule().fill(i == 0 ? DS.Palette.accent : DS.Palette.textSecondary)
                                        .frame(width: max(4, geo.size.width * min(max(base > 0 ? s.value / base : 0, 0), 1)), height: 8)
                                }
                            }
                            .frame(height: 8)
                            Text(String(format: "%.1f%%", s.value * 100))
                                .font(.system(size: mvFont9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white).frame(width: 42, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(s.label) \(String(format: "%.1f", s.value * 100)) percent")
                    }
                    Text("Correlation de-weighting and the heat cap apply at the portfolio level, not shown per-idea. Each brake is shown applied to Base independently — they compound in the Deploy plan. " + Self.sizeMetricHelp)
                        .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        }
    }

    @ViewBuilder private func positionSizerPanel(_ idea: StockSageIdea) -> some View {
        if let stop = idea.advice.stopPrice {
            let entry = idea.price
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "function").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.accent)
                    Text("Position size").font(.system(size: mvFont11, weight: .semibold)).foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("Acct $").font(.system(size: mvFont9)).foregroundStyle(.secondary)
                    journalField("10000", text: $sizerAccount, width: 72)
                        .accessibilityLabel("Account size in dollars")
                    Text("Risk %").font(.system(size: mvFont9)).foregroundStyle(.secondary)
                    journalField("1", text: $sizerRiskPct, width: 40)
                        .accessibilityLabel("Risk percent per trade")
                }
                if let acct = parsedAccount, let rf = parsedRiskFraction,
                   let ps = sizedPosition(account: acct, riskFraction: rf, symbol: idea.symbol, entry: entry, stop: stop) {
                    // F4 (audit 2026-07-12): ps.notional/dollarsAtRisk/pctOfAccount and `entry` are in the
                    // SYMBOL's own currency, but `acct` is USD. A native-vs-USD compare inflates ~100× for a
                    // pence stock → false leverage/liquidation warnings on an unleveraged cash position, and
                    // over-/under-states the "% of account". Convert the native amounts to USD (pence-normalized
                    // × FX rate) before every account comparison; untracked FX → factor 1 (prior behavior).
                    let usdFactor: Double = {
                        // F3 follow-up (2026-07-16): resolver-backed (was the portfolio-only dict,
                        // which lacked SAR whenever no .SR position was held → factor fell to 1).
                        guard let rate = fxRateToUSD(conversionCurrencyForSymbol(idea.symbol)) else { return 1 }
                        // majorUnitValue handles the pence ÷100; divide by the raw amount to get a pure scale.
                        let normalized = StockSageCurrency.majorUnitValue(symbol: idea.symbol, rawValue: 1)
                        return normalized * rate
                    }()
                    let notionalUSD = ps.notional * usdFactor
                    let atRiskUSD = ps.dollarsAtRisk * usdFactor
                    let pctOfAccountUSD = notionalUSD / acct * 100
                    let leveraged = pctOfAccountUSD > 100
                    if ps.shares >= 1 {
                        HStack(spacing: DS.Space.sm) {
                            ideaMetric("Shares", "\(ps.shares)", color: DS.Palette.accent)
                            ideaMetric("At risk", StockSageCurrency.approxAmount(ps.dollarsAtRisk, symbol: idea.symbol), color: DS.Palette.dangerSoft)
                            ideaMetric("Notional", StockSageCurrency.approxAmount(ps.notional, symbol: idea.symbol))
                            ideaMetric("% acct", String(format: "%.0f%%", pctOfAccountUSD),
                                       color: leveraged ? DS.Palette.dangerSoft : .white)
                            Spacer(minLength: 0)
                        }
                        // % of account from the FLOORED dollars-at-risk (was the requested risk %, which
                        // overstates the loss it sits beside once shares round down). USD-converted so a
                        // non-USD holding's loss reads against the USD account correctly.
                        Text("Sizes the LOSS: a stop-out at \(adaptivePrice(stop)) costs ~$\(String(format: "%.0f", atRiskUSD)) (\(String(format: "%.2f", atRiskUSD / acct * 100))% of the account). Not a profit promise.")
                            .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        // Floored to 0 shares: the budget cannot fund even one share at this stop. Saying
                        // "$0 at risk" would read as a free trade — it is an un-takeable one.
                        // T13 (rotation-3 triage): lead with the Wave-A ratified phrase
                        // (StockSagePositionSizer.summaryLine's own "Below the 1-share minimum at
                        // your account size" — the same event every other "Size it now" surface
                        // already names this way), keep this widget's own remedy + honesty tail.
                        Text("Below the 1-share minimum at your account size — raise the account or risk %, or tighten the stop. This is NOT a zero-risk trade.")
                            .font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                    }
                    // One side derivation for BOTH risk lines below — a sell/reduce idea is a genuine
                    // short-side plan (stop above entry), and both the leverage liquidation price and
                    // the gap scenario are side-dependent.
                    let isShortIdea = idea.advice.action == .sell || idea.advice.action == .reduce
                    // Leverage truth: liquidation distance + can-lose-more-than-account (replaces the static string).
                    // isShort matters: a short's wipe-out is entry·(1 + 1/L), ABOVE entry — the long
                    // formula would print a "liquidation" price on the side where the short PROFITS.
                    // F4: leverage compares notional to the USD account — pass the USD-converted notional so
                    // a pence/SAR position isn't falsely flagged leveraged. `entry` stays native (the
                    // liquidation PRICE it derives is legitimately in the symbol's own currency).
                    if leveraged, let lev = StockSageLeverage.assess(account: acct, notional: notionalUSD, entry: entry,
                                                                     isShort: isShortIdea) {
                        Text("⚠︎ " + lev.verdict)
                            .font(.system(size: mvFont9))
                            .foregroundStyle(lev.canLoseMoreThanAccount ? DS.Palette.dangerSoft : DS.Palette.warningSoft)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(StockSageLeverage.caveat)
                            .accessibilityLabel("Leverage warning. " + lev.verdict)
                    }
                    // Gap risk: a stop is a TRIGGER, not a fill — show the worst-case 20% gap-through loss.
                    // F4 (audit 2026-07-12): the loss is computed from native-currency entry/stop/shares, so
                    // the loss-vs-equity ratio needs the account in the SAME (native) currency — else a pence
                    // stock's loss vs a USD account falsely reads "MORE than you have / owe the broker". Pass
                    // acct converted to the symbol's currency (÷ usdFactor); untracked FX → usdFactor 1 (no-op).
                    let gapSide: TradeSide = isShortIdea ? .short : .long
                    let acctNative = acct / usdFactor
                    if let gap = StockSageGapRisk.scenario(side: gapSide, entry: entry, stop: stop,
                                                           shares: Double(ps.shares), gapPct: 0.20, accountEquity: acctNative) {
                        // BUGHUNT_NEWENGINES #2 residual: the row keeps the single 20% headline;
                        // the hover tooltip now carries the FULL what-if ladder (weekend 5% /
                        // earnings 8% / crypto-flash 20% / halt-reopen 35%) — the "a stop is not
                        // a fill" table, without adding card height. Illustrative magnitudes,
                        // never probabilities (the caveat leads the tooltip and says so).
                        let ladder = StockSageGapRisk.worstCase(side: gapSide, entry: entry, stop: stop,
                                                                shares: Double(ps.shares), accountEquity: acctNative)
                            .map { "• " + $0.verdict }.joined(separator: "\n")
                        Text("⚠︎ " + gap.verdict)
                            .font(.system(size: mvFont9))
                            .foregroundStyle(gap.exceedsAccount ? DS.Palette.dangerSoft : DS.Palette.warningSoft)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(ladder.isEmpty ? StockSageGapRisk.caveat : StockSageGapRisk.caveat + "\n\n" + ladder)
                            .accessibilityLabel("Gap risk warning. " + gap.verdict)
                    }
                } else {
                    Text("Enter a valid account size and risk %.").font(.system(size: mvFont9)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        }
    }

    /// ONE chip chrome for every tinted status chip on the ideas surface (UX wave 2):
    /// 8/3 capsule insets, 0.14 tint fill, 0.35 hairline stroke — the riskChip pattern
    /// promoted to all tinted chips; the stroke is a non-color edge channel. Filled
    /// identity chips (actionColor background) are the one sanctioned variant and do
    /// not use this. Fonts stay at call sites (EV needs monospacedDigit).
    private struct IdeaChipChrome: ViewModifier {
        let tint: Color
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, IdeaSpace.chipH).padding(.vertical, IdeaSpace.chipV)
                .background(tint.opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
        }
    }

    private func riskChip(_ flag: RiskFlag) -> some View {
        let color = flag.level == .high ? DS.Palette.dangerSoft
                  : (flag.level == .caution ? DS.Palette.warningSoft : DS.Palette.textSecondary)
        return HStack(spacing: DS.Space.xs) {
            Image(systemName: flag.level == .high ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                .font(.system(size: mvFont9))
            Text(flag.label).font(.system(size: fontChipLabel, weight: .semibold))
        }
        .foregroundStyle(color)
        .modifier(IdeaChipChrome(tint: color))
        .accessibilityLabel("Risk: \(flag.label)")
    }

    private var backtestTitle: String {
        if store.isBacktesting { return "Backtesting \(store.backtestSymbol ?? "")… (5y, walk-forward)" }
        if let s = store.backtestSymbol { return "Backtest: \(s) · 5y walk-forward" }
        return "Backtest"
    }

    // MARK: Idea detail sheet

    // Pre-trade gate verdict block for the detail sheet (go / caution / no-go + checks).
    @ViewBuilder private func tradeGateView(_ v: TradeGateVerdict) -> some View {
        let color: Color = v.decision == .blocked ? DS.Palette.dangerSoft
            : (v.decision == .caution ? DS.Palette.warningSoft : DS.Palette.successSoft)
        let icon = v.decision == .blocked ? "xmark.octagon.fill"
            : (v.decision == .caution ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: mvFont13)).foregroundStyle(color)
                Text("Pre-trade gate — \(v.decision.rawValue)").font(.system(size: mvFont12, weight: .bold)).foregroundStyle(color)
                Spacer()
            }
            ForEach(v.checks.indices, id: \.self) { i in
                let c = v.checks[i]
                let cc: Color = c.level == .fail ? DS.Palette.dangerSoft : (c.level == .warn ? DS.Palette.warningSoft : DS.Palette.successSoft)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: c.level == .fail ? "xmark" : (c.level == .warn ? "exclamationmark" : "checkmark"))
                        .font(.system(size: mvFont9, weight: .bold)).foregroundStyle(cc).frame(width: 10)
                    Text(c.label).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(v.caveat).font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.sm).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(color.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel({ () -> String in
            var label = "Pre-trade gate: \(v.decision.rawValue). \(v.fails) failed, \(v.warns) warnings, \(v.passes) passed."
            // A11Y-04 (2026-07-07 fix round): the count-only label never says WHICH check
            // failed or warned — append the non-passing checks' own visible labels so VoiceOver
            // users get the same information sighted users read in the list below.
            let nonPassing = v.checks.filter { $0.level != .pass }.map { $0.label }
            if !nonPassing.isEmpty {
                label += " Failed or warned: \(nonPassing.joined(separator: ". "))."
            }
            return label
        }())
    }

    // MARK: - Full plan text helper (item 4 — honesty-floor breach fix)
    // Extracts the sheet's "Copy plan" text into a private helper so both the
    // sheet button AND the card context-menu "Copy trade plan" produce the same
    // honest, full plan (with caveats, gate verdict, and net R:R) rather than
    // the card's former hand-rolled one-liner that omitted all of those.
    private func tradeGateInputs(for idea: StockSageIdea) -> (hasStop: Bool, rewardToRisk: Double?, resolvedNetRR: Double?, daysToEarnings: Int?) {
        let a = idea.advice
        let resolvedNetRR: Double? = {
            guard let stop = a.stopPrice, let target = a.targetPrice else { return nil }
            let (finRate, finDays) = StockSageExpectedValue.financingCostInputs(for: idea)
            return StockSageNetEdge.netRR(symbol: idea.symbol, entry: idea.price, stop: stop, target: target,
                                          annualFinancingRate: finRate, holdDays: finDays)
        }()
        let rewardToRisk: Double? = {
            guard let stop = a.stopPrice, let target = a.targetPrice else { return nil }
            let risk = abs(idea.price - stop)
            guard risk > 0 else { return nil }
            let gross = abs(target - idea.price) / risk
            return resolvedNetRR ?? gross
        }()
        return (
            hasStop: a.stopPrice != nil,
            rewardToRisk: rewardToRisk,
            resolvedNetRR: resolvedNetRR,
            daysToEarnings: store.earnings[idea.symbol.uppercased()]?.daysUntil
        )
    }

    private func tradeGateVerdict(for idea: StockSageIdea, inputs: (hasStop: Bool, rewardToRisk: Double?, resolvedNetRR: Double?, daysToEarnings: Int?)) -> TradeGateVerdict? {
        guard let rf = parsedRiskFraction else { return nil }
        return StockSageTradeGate.evaluate(
            hasStop: inputs.hasStop,
            rewardToRisk: inputs.rewardToRisk,
            riskFraction: rf,
            daysToEarnings: inputs.daysToEarnings,
            rrIsNet: inputs.resolvedNetRR != nil
        )
    }

    private func fullPlanText(for idea: StockSageIdea) -> String {
        let a = idea.advice
        let gateInputs = tradeGateInputs(for: idea)
        let copyGate: TradeGateVerdict? = {
            guard a.action == .buy || a.action == .strongBuy else { return nil }
            return tradeGateVerdict(for: idea, inputs: gateInputs)
        }()
        // EXPORT-W4-1: auto-skip blocked setups in copied plan output so a blocked idea is never
        // exported as an actionable order checklist from the detail sheet.
        if let gate = copyGate, gate.decision == .blocked {
            let failLabels = gate.checks.filter { $0.level == .fail }.map(\.label)
            let warnLabels = gate.checks.filter { $0.level == .warn }.map(\.label)
            var blocked = "Copy plan skipped — \(idea.symbol) is currently BLOCKED by the pre-trade gate."
            if !failLabels.isEmpty { blocked += "\nFAIL: " + failLabels.joined(separator: "; ") }
            if !warnLabels.isEmpty { blocked += "\nWARN: " + warnLabels.joined(separator: "; ") }
            blocked += "\nNo order plan exported. Fix the gate failures, then copy again."
            if store.isSampleData {
                blocked = "⚠ SAMPLE DATA — illustrative prices, NOT live quotes. Re-price before any order.\n" + blocked
            }
            return blocked
        }
        let riskFlags = StockSageRiskFlags.flags(
            action: a.action, conviction: a.conviction, symbol: idea.symbol,
            earnings: store.earnings[idea.symbol.uppercased()],
            precheck: store.precheck[idea.symbol.uppercased()],
            regimeIsStale: store.regimeIsStale, hasRegime: store.regime != nil,
            liquidityTier: store.liquidity[idea.symbol.uppercased()]?.tier)
        let rr = a.stopPrice.flatMap { s in
            a.targetPrice.flatMap { t in StockSageRewardRisk.assess(entry: idea.price, stop: s, target: t) }
        }
        let size: PositionSize? = a.stopPrice.flatMap { s in
            guard let acct = parsedAccount, let rf = parsedRiskFraction else { return nil }
            return sizedPosition(account: acct, riskFraction: rf, symbol: idea.symbol, entry: idea.price, stop: s)
        }
        let planLadder: PartialLadder? = {
            guard let stop = a.stopPrice, let target = a.targetPrice else { return nil }
            return StockSagePartialLadder.levels(entry: idea.price, stop: stop, target: target, rungs: 3)
        }()
        let planChandelier: Double? = store.trailingStop[idea.symbol.uppercased()]?.level
        var plan = StockSageTradePlan.text(symbol: idea.symbol, market: idea.market, price: idea.price,
                                           advice: a, rewardRisk: rr, size: size, flags: riskFlags,
                                           ladder: planLadder, chandelierLevel: planChandelier)
        // First-real-trade review (2026-07-16): Tadawul rejects off-grid prices — the exported
        // plan (the broker ticket source) carries the placeable equivalents for .SR orders.
        // Display-only; the engine's stop/target (and every EV/R:R derived from them) unchanged.
        if let tickNote = StockSageTickSize.placeabilityNote(symbol: idea.symbol, entry: idea.price,
                                                             stop: a.stopPrice, target: a.targetPrice) {
            plan += "\n⚠ " + tickNote
        }
        // F04: StockSageTradePlan.text silently OMITS the "Size:" line when size is nil — which
        // used to happen for a typed "10,000" (Double() choking on the comma), reading as "no
        // size available" with no hint why. Say so explicitly when there's a stop to size against.
        if a.stopPrice != nil, size == nil {
            plan += "\nSize: enter account size to size this trade."
        }
        // F15: Net R:R line only when stop+target both exist (need both prices for the ratio).
        // Gate is emitted for buy-family ONLY — same condition as the on-screen gate chip.
        // For a stop-less buy, hasStop=false → "Don't take this trade" appears in the export.
        // Sell/reduce never gets a gate line (screen gates buy-family only).
        let (finRate, finDays) = StockSageExpectedValue.financingCostInputs(for: idea)
        if let stop = a.stopPrice, let target = a.targetPrice {
            let costs = StockSageNetEdge.defaultCosts(forSymbol: idea.symbol)
            if let ne = StockSageNetEdge.evaluate(
                entry: idea.price, stop: stop, target: target,
                spreadBps: costs.spreadBps, slippageBps: costs.slippageBps, takerFeeBps: costs.takerFeeBps,
                annualFinancingRate: finRate, holdDays: finDays) {
                // F27 (factored): single source of truth — StockSageExpectedValue.financingNoteSuffix
                // keys on BOTH rate > 0 AND days > 0 (FX/index sells have 0 hold days → $0 financing;
                // a rate-only guard would falsely claim financing was modeled when nothing was charged).
                let financingNote = StockSageExpectedValue.financingNoteSuffix(rate: finRate, days: finDays)
                // Audit 2026-07-12 pass-3 (finding ④): mirror the ON-SCREEN sheet's cost label — for
                // crypto that is the tier BAND (costsDisplayLabel), not the flat 70bps point, and when
                // the band exceeds the priced floor, carry the "net is optimistic" disclosure into the
                // paste too. Otherwise the exported artifact (pasted into a broker) reads MORE
                // authoritative than the UI it came from — a gross-optimism-as-net breach. Non-crypto
                // is byte-identical to the old "~Nbps est. <class>" wording (costsDisplayLabel matches).
                let costLabel = StockSageNetEdge.costsDisplayLabel(forSymbol: idea.symbol,
                                                                   advDollar: store.liquidity[idea.symbol.uppercased()]?.avgDollarVolume)
                let optimismNote = StockSageNetEdge.costsOptimismSentence(forSymbol: idea.symbol,
                                                                          advDollar: store.liquidity[idea.symbol.uppercased()]?.avgDollarVolume)
                plan += String(format: "\nNet R:R (after %@ costs%@): %.1f:1 (gross %.1f:1)",
                               costLabel, financingNote, ne.netRR, ne.grossRR)
                if let optimismNote { plan += "\n  ⚠ " + optimismNote }
                // F2 (owner-signed 2026-07-10): export parity for the per-order-minimum
                // disclosure the on-screen ledger shows — same guards, same wording.
                if costs.perOrderMinimum > 0,
                   let acct = StockSageInput.positiveAmount(sizerAccount),
                   let rp = StockSageInput.percent(sizerRiskPct),
                   let ps = sizedPosition(account: acct, riskFraction: rp / 100, symbol: idea.symbol, entry: idea.price, stop: stop),
                   ps.shares > 0,
                   let neSized = StockSageNetEdge.evaluate(
                       entry: idea.price, stop: stop, target: target,
                       spreadBps: costs.spreadBps, slippageBps: costs.slippageBps,
                       takerFeeBps: costs.takerFeeBps,
                       annualFinancingRate: finRate, holdDays: finDays,
                       perOrderMinimum: costs.perOrderMinimum,
                       orderNotional: Double(ps.shares) * idea.price),
                   neSized.costPerShare > ne.costPerShare + 1e-9 {
                    let liftedBps = neSized.costPerShare / idea.price * 10_000
                    plan += String(format: "\n⚠ At your %d-share order, per-order broker minimums lift est. costs to ~%.0fbps — net R:R %.1f:1 at this size.",
                                   ps.shares, liftedBps, neSized.netRR)
                }
                if let be = ne.breakEvenWinRate {
                    plan += String(format: " — needs >%.1f%% win-rate net", be * 100)
                }
            }
        }
        // Gate: buy-family only, matching the on-screen gate chip (sell/reduce gets no gate line).
        if a.action == .buy || a.action == .strongBuy {
            // F04: was `?? 0.01` — a typed-but-unparseable risk % silently evaluated the gate at a
            // fabricated 1%, printing a "Clear"/"Caution" verdict the user never actually asked for.
            if let gate = copyGate {
                plan += "\nPre-trade gate: \(gate.decision.rawValue)"
                let failLabels = gate.checks.filter { $0.level == .fail }.map(\.label)
                let warnLabels = gate.checks.filter { $0.level == .warn }.map(\.label)
                if !failLabels.isEmpty { plan += "\n  FAIL: " + failLabels.joined(separator: "; ") }
                if !warnLabels.isEmpty { plan += "\n  WARN: " + warnLabels.joined(separator: "; ") }
            } else {
                plan += "\nPre-trade gate: not evaluated — enter risk % to see the verdict."
            }
        }
        // Sheet-lens (2026-07-09) — EXPORT parity with the on-screen sized-risk warnings the
        // pasted plan previously understated (the leverage warning's own rationale, extended):
        // the 20% gap-through-stop worst case and the sector-concentration crossing, SAME
        // inputs as the on-screen rows; no line when they don't resolve (never fabricated).
        if let stop = a.stopPrice, let acct = parsedAccount, let ps = size {
            let gapSide: TradeSide = (a.action == .sell || a.action == .reduce) ? .short : .long
            // F4 (audit 2026-07-12): gap loss is native-currency, so the account must be in the same
            // currency for an honest loss-vs-equity ratio (export parity with the on-screen fix above).
            // F3 review fix (2026-07-16): via `usdAmount` (resolver-backed) — the portfolio-only dict
            // fell to factor 1 for an unheld .SR, overstating the exported gap verdict ~3.75×.
            let usdFactor = usdAmount(1, symbol: idea.symbol) ?? 1
            if let gap = StockSageGapRisk.scenario(side: gapSide, entry: idea.price, stop: stop,
                                                   shares: Double(ps.shares), gapPct: 0.20, accountEquity: acct / usdFactor) {
                plan += "\n⚠ " + gap.verdict
            }
        }
        // Audit 2026-07-12 pass-3: FX-convert to USD (mirror the on-screen what-if + allocation panel)
        // so the exported concentration % isn't distorted by a 1:1 multi-currency sum.
        let exportFX = fxRatesToUSD
        let exportHoldings = portfolio.positions.compactMap { p -> (symbol: String, value: Double)? in
            guard let rate = exportFX[conversionCurrencyForSymbol(p.symbol)] else { return nil }
            return (symbol: p.symbol,
                    value: holdingValue(p.symbol, perShare: currentPrice(p.symbol) ?? p.costBasis, shares: p.shares) * rate)
        }
        if !exportHoldings.isEmpty {
            let bookTotal = exportHoldings.reduce(0) { $0 + $1.value }
            let sizedNotional = size.map { StockSageCurrency.majorUnitValue(symbol: idea.symbol, rawValue: $0.notional) }
            let addValue = StockSageWhatIf.proposedAddValue(sizedNotional: sizedNotional, account: parsedAccount, bookTotal: bookTotal)
            let sectorImpact = StockSageWhatIf.addingHolding(symbol: idea.symbol, addedValue: addValue,
                                                             to: exportHoldings, classify: StockSageSector.sector)
            if sectorImpact.isWarning { plan += "\nBy sector — " + sectorImpact.note }
        }
        // EXPORT-02: mirror StockSageTodayPlan.copyAllText's SAMPLE-data warning — this is
        // the OTHER artifact that gets pasted into a broker; a seed price must not be acted
        // on as real just because this export path skipped the on-screen banner's caveat.
        if store.isSampleData {
            plan = "⚠ SAMPLE DATA — illustrative prices, NOT live quotes. Re-price before any order.\n" + plan
        }
        // ROUND-H PARITY (sheet-lens MED, 2026-07-09): the sheet's copy is the OTHER
        // broker-paste artifact — it must carry the same stale-price flag copyAllText/build
        // already do. nil priceAsOf ⇒ unknown ⇒ no line, never a false warning.
        if let asOf = idea.priceAsOf,
           StockSageScanChunking.utcDayKey(asOf) != StockSageScanChunking.utcDayKey(Date()) {
            plan = "⚠ PRICE NOT LIVE — as of \(asOf.formatted(.relative(presentation: .named))); re-price before any order.\n" + plan
        }
        // EXPORT-01: mirror the sheet's Held/Journal context lines (same formats, same call sites)
        // so a pasted plan doesn't invite doubling a position the owner already holds. Only append
        // when they resolve — no line when nil, exactly like the sheet.
        if let held = StockSagePortfolio.holding(for: idea.symbol, in: portfolio.positions) {
            let pct = held.unrealizedPct(vs: idea.price)
            var line = "Held: \(numString(held.shares)) sh @ \(adaptivePrice(held.costBasis)) (avg cost)"
            if let pct {
                let up = pct >= 0
                line += " · \(up ? "+" : "")\(String(format: "%.1f", pct))% vs avg cost"
            }
            plan += "\n" + line
        }
        if let jh = StockSageJournal.history(for: idea.symbol, in: journal.trades) {
            let up = jh.totalR >= 0
            plan += "\n" + String(format: "Journal: %d closed on this name · realized %@%.1fR total%@",
                                   jh.count, up ? "+" : "", jh.totalR,
                                   jh.rDefinedCount != jh.count ? " (R defined on \(jh.rDefinedCount))" : "")
        }
        return plan
    }

    private func ideaDetailSheet(_ idea: StockSageIdea) -> some View {
        let a = idea.advice
        let snapshot = StockSageDecisionSnapshotBuilder.build(
            idea: idea,
            holds: velocityHolds,
            calibration: store.convictionCalibration,
            earnings: store.earnings,
            liquidity: store.liquidity,
            account: parsedAccount ?? 10_000,
            riskFraction: parsedRiskFraction ?? 0.01,
            regime: store.regime,
            fxRatesToUSD: sizingFXRates(for: [idea.symbol]))
        let detailVM = snapshot.detailViewModel
        let hasEarningsWarning = detailVM.hasEarningsWarning
        let hasFloorWarning = detailVM.hasFloorWarning
        // Hoist riskFlags for the chips row and CTA bar: shared in ideaDetailSheet only.
        // fullPlanText(for:) recomputes its own riskFlags from the same store inputs so the
        // card context-menu "Copy trade plan" path works with no sheet alive.
        let riskFlags = StockSageRiskFlags.flags(
            action: a.action, conviction: a.conviction, symbol: idea.symbol,
            earnings: store.earnings[idea.symbol.uppercased()],
            precheck: store.precheck[idea.symbol.uppercased()],
            regimeIsStale: store.regimeIsStale, hasRegime: store.regime != nil,
            liquidityTier: store.liquidity[idea.symbol.uppercased()]?.tier)
        // House pattern: ScrollViewReader is the outer view; ScrollView is its content.
        // ScrollViewReader outside, ScrollView inside — the proxy stays available to .onChange and the
        // proxy is available to modifiers (.onChange) placed on the ScrollView itself.
        return ScrollViewReader { proxy in
            ScrollView {
            VStack(alignment: .leading, spacing: IdeaSpace.section) {

                // ── 1. Header (symbol / market / action badge / prev-next nav) ──────
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(idea.symbol).font(.system(size: mvFont20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        if let n = StockSageTadawulNames.displayLine(for: idea.symbol) {
                            Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(idea.market).font(.caption).foregroundStyle(.secondary)
                        // Extension batch (2026-07-16): Saudi-investor cost honesty — US dividends
                        // net ≈70% of headline (30% NRA withholding, no US–Saudi treaty). Sourced
                        // note in the tooltip; informational, not tax advice; nil for non-US names.
                        if let w = StockSageWithholdingNote.note(for: idea.symbol) {
                            Text("Dividends: 30% US withholding applies")
                                .font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                                .help(w)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(idea.symbol)\(StockSageTadawulNames.name(for: idea.symbol).map { ", \($0.english)" } ?? ""), \(idea.market)")
                    Spacer()
                    Text(a.action.rawValue)
                        .font(.system(size: mvFont12, weight: .bold)).foregroundStyle(actionTextColor(a.action))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(actionColor(a.action), in: Capsule())
                        .accessibilityLabel("Action: \(a.action.rawValue)")
                    // Prev/next candidate stepper — board order, next to the X (see
                    // sheetNavControls for the press-time-resolution + ⌘-modifier rationale).
                    sheetNavControls(idea)
                    Button { selectedIdea = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: mvFont18)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Close (Esc)").accessibilityLabel("Close")
                    .keyboardShortcut(.cancelAction)
                }
                // Scroll target for the prev/next stepper (Step 5): the sheet stays
                // presented across a step, so the scroll offset would otherwise persist.
                .id("sheetTopAnchor")

                // Sparkline
                if idea.spark.count >= 2 {
                    let trendWord = (idea.spark.last ?? 0) >= (idea.spark.first ?? 0) ? "up" : "down"
                    // Registration fix (OSS-borrow B2 review): compute the extended domain ONCE
                    // and hand the SAME value to the Shape and the overlay — two independent
                    // normalizations (spark's own min/max vs. the overlay's extended domain)
                    // used to diverge whenever stop/target fell outside the spark's own range.
                    // ALL-OR-NOTHING gate unchanged: overlayDomain is nil unless stop AND target
                    // both resolve, so the bare sheet spark stays byte-identical to main whenever
                    // the overlay itself wouldn't render.
                    let overlayDomain: (lo: Double, hi: Double)? = {
                        guard let stop = idea.advice.stopPrice, let target = idea.advice.targetPrice else { return nil }
                        return SparkSeries.domain(idea.spark, extending: [stop, target, idea.price])
                    }()
                    Sparkline(values: idea.spark, domain: overlayDomain)
                        .stroke(sparkColor(idea.spark), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(height: 64)
                        .overlay(tradePlanOverlay(idea, domain: overlayDomain))
                        // L4 dedup (critique fleet #1): the trade-plan overlay itself is
                        // .accessibilityHidden + .allowsHitTesting(false), so its own .help was
                        // dead (never hit-testable) and its .accessibilityLabel was dead (never
                        // reachable by VoiceOver) — both deleted from tradePlanOverlay. .help moved
                        // here, onto this hit-testable container, gated on overlayDomain != nil (the
                        // overlay's own all-or-nothing render condition) so the tooltip never claims
                        // an overlay that isn't drawn.
                        .help(overlayDomain != nil
                              ? "Trade plan overlay: stop/target lines and the latest-close marker — see \u{201C}Stop & Target computed\u{201D} below."
                              : "")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Price sparkline, trending \(trendWord), high \(adaptivePrice(idea.spark.max() ?? 0)), low \(adaptivePrice(idea.spark.min() ?? 0))")
                    // At-the-extreme chip (OSS-borrow B3, Ghostfolio min/max highlight; L1 honesty
                    // fix 2026-07-07): same idea.recentExtreme predicate as the ranked card (raw
                    // last-N-day closes, not the downsampled spark), rendered right under the
                    // chart it describes. Neutral secondary styling — context, not a signal.
                    let extreme = idea.recentExtreme ?? .neither
                    let extremeSpan = idea.recentExtremeSpan ?? idea.spark.count
                    if extreme != .neither {
                        Text(extreme == .atHigh ? "At \(extremeSpan)-day high" : "At \(extremeSpan)-day low")
                            .font(.system(size: fontChipLabel, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .help("Latest close is the highest/lowest of the last \(extremeSpan) daily closes — context, not a buy/sell signal.")
                            // a11y parity with the card's chip (OSS-borrow B3): same explicit
                            // label instead of relying on the raw visible text.
                            .accessibilityLabel(extreme == .atHigh ? "At the high of the last \(extremeSpan) days" : "At the low of the last \(extremeSpan) days")
                    }
                }

                // Conviction meter + honesty caption
                signalBlocks(a.conviction, color: actionColor(a.action))
                    // F01/F02: wording keyed on the calibration METHOD — identity must read "assumed".
                    .help(store.convictionCalibration.map { cal in
                        cal.method == .identity
                        ? "Signal strength — a rules-based score; win-rate currently ASSUMED — conviction, capped at the conservative ~\(StockSageExpectedValue.assumedWinBandLabel) prior when the sample is too thin to validate out-of-sample, is used as the win probability (identity floor), not measured from outcomes."
                        : "Signal strength — a rules-based score; win-rate \(cal.method == .platt ? "fitted" : "measured") from \(cal.sampleSize) realized trades."
                    } ?? "Signal strength — a rules-based score, not a probability. Estimated win-rate range ~\(StockSageExpectedValue.assumedWinBandLabel), not a forecast.")
                Text("Signal strength \(Int(a.conviction * 100)) · \(a.regime.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
                // Always-visible disclaimer: meter % must not read as P(win).
                // One disclaimer only — the trailing clause was removed from the value
                // label above (G) to avoid saying "not a win probability" twice.
                Text("How many rules agree — NOT a win probability.")
                    .font(.system(size: mvFont9)).foregroundStyle(.secondary)

                // ── 2. Risk-flag chips row ───────────────────────────────────────────
                // riskFlags is hoisted for the chips row and the CTA bar (see comment above).
                if !riskFlags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: IdeaSpace.chipGap) { ForEach(riskFlags) { riskChip($0) } }
                    }
                }

                // ── 3 + 4. Earnings warning (buy-family: above gate) + gate + sizer ─
                if a.action == .buy || a.action == .strongBuy {
                    // Earnings severity warning above the gate for buy-family.
                    // Keep ep.isWarning guard — purely a position move, not a logic change.
                    if hasEarningsWarning,
                       let ep = store.earnings[idea.symbol.uppercased()], ep.isWarning {
                        earningsWarningRow(ep)
                    }

                    let gateInputs = tradeGateInputs(for: idea)
                    // F04: was a `?? 0.01` floor — an unparseable risk % (e.g. a typed "10,000" account
                    // is fine but a malformed risk field) silently evaluated the gate at a fabricated
                    // 1%, printing a "Clear"/"Caution" verdict the user never actually set. nil now
                    // suppresses the verdict instead of fabricating one (fullPlanText mirrors this).
                    if let gate = tradeGateVerdict(for: idea, inputs: gateInputs) {
                        tradeGateView(gate)
                    } else {
                        Text("Pre-trade gate: enter risk % to see the verdict.")
                            .font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }

                    // ── 5. Position sizer (moved above evidence; gate reads sizerRiskPct
                    //       so proximity makes the dependency legible). ─────────────────────────
                    positionSizerPanel(idea)

                    // Concentration-in-disguise: warn if this idea moves in lockstep with
                    // something already held (series sourced from the ideas board's sparklines).
                    // Moved into Context section below; kept in buy-guard.
                }
                // sd#D: sell/reduce ideas also have stopPrice and benefit from the sizer's
                // short-side leverage/liquidation display. Show the sizer for non-buy actions
                // immediately after the buy-guard so it never renders twice for one idea
                // (buy-guard already calls positionSizerPanel inside). The sizer's own
                // stopPrice guard hides it for Hold/Avoid (no stop → nothing rendered).
                if !(a.action == .buy || a.action == .strongBuy) { positionSizerPanel(idea) }

                // "Own it" awareness: held-context line right after the Position-size block,
                // for every idea (not gated on stopPrice, so it survives even for Hold/Avoid
                // where positionSizerPanel renders nothing). No special-casing for sell-family —
                // same line for every action, since a held position matters most for exit reads.
                if let held = StockSagePortfolio.holding(for: idea.symbol, in: portfolio.positions) {
                    let pct = held.unrealizedPct(vs: idea.price)
                    HStack(spacing: 4) {
                        Text("Held: \(numString(held.shares)) sh @ \(adaptivePrice(held.costBasis)) (avg cost)")
                            .font(.system(size: mvFont9)).foregroundStyle(.secondary)
                        if let pct {
                            let up = pct >= 0
                            Text("· \(up ? "+" : "")\(String(format: "%.1f", pct))% vs avg cost")
                                .font(.system(size: mvFont9)).foregroundStyle(up ? DS.Palette.successSoft : DS.Palette.dangerSoft)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }

                // "Your history with this name" (2026-07-07 assessment gap #2): the owner's OWN
                // closed-trade record on this symbol, right after the Held line — same neutral/
                // display-only placement. successSoft/dangerSoft coloring (never plain danger —
                // the ideas-sheet AA rule) matches the Held-line unrealized-% convention above.
                if let jh = StockSageJournal.history(for: idea.symbol, in: journal.trades) {
                    let up = jh.totalR >= 0
                    Text(String(format: "Journal: %d closed on this name · realized %@%.1fR total%@",
                                jh.count, up ? "+" : "", jh.totalR,
                                jh.rDefinedCount != jh.count ? " (R defined on \(jh.rDefinedCount))" : ""))
                        .font(.system(size: mvFont9))
                        .foregroundStyle(up ? DS.Palette.successSoft : DS.Palette.dangerSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // ── 6. Plan numerics (Price/Stop/Target/Base size only — F2 dedup) ─
                // Regime size / Vol-adj DROPPED from this row (see comment below the Base-size
                // metric) — they duplicate the sizingBrakeWaterfall rendered directly under this
                // HStack. Spacing 14 kept for the remaining 4 metrics with 6-figure crypto prices.
                HStack(spacing: 14) {
                    ideaMetric("Price", adaptivePrice(idea.price))
                    if let s = a.stopPrice {
                        // Signed distance-to-invalidation, same convention as the board card/best-opportunity
                        // card: raw (stop/price − 1)×100, negative for longs, positive for shorts, no abs().
                        if idea.price > 0 {
                            let stopDistPct = (s / idea.price - 1) * 100
                            ideaMetric("Stop", "\(adaptivePrice(s)) (\(String(format: "%+.1f%%", stopDistPct)) to stop)", color: DS.Palette.dangerSoft)
                        } else {
                            ideaMetric("Stop", adaptivePrice(s), color: DS.Palette.dangerSoft)
                        }
                    }
                    if let t = a.targetPrice { ideaMetric("Target", adaptivePrice(t), color: DS.Palette.successSoft) }
                    // "Base size" = raw half-Kelly before regime/vol/correlation adjustments.
                    if a.suggestedWeight > 0 {
                        ideaMetric("Base size", String(format: "%.1f%%", a.suggestedWeight * 100), color: DS.Palette.accent)
                            .help(Self.sizeMetricHelp)
                    }
                    // F2 dedup (critique fleet #1): "Regime size" / "Vol-adj" metrics dropped from
                    // this row — the sizingBrakeWaterfall directly below renders the SAME two figures
                    // (from the identical StockSageRegime.adjustedWeight / idea.volRegime calls) as
                    // soon as ≥2 stages resolve, and is strictly more informative (labeled chain,
                    // not two disconnected numbers). Nil-gating equivalence verified: the row's Regime
                    // gate (a.suggestedWeight>0, store.regime) is identical to the waterfall's; the
                    // row's Vol-adj gate additionally requires sizingMultiplier<0.85 (waterfall has no
                    // such threshold) — a STRICT SUBSET, so whenever the row's Vol-adj would have
                    // rendered, the waterfall's Vol-adj stage already resolves too. Dropping the row
                    // loses nothing. Regime-size caveat text below now free-floats but still applies
                    // whenever the waterfall's Regime stage is showing.
                    Spacer(minLength: 0)
                }
                // Regime-size caveat directly under the plan-numerics metrics row — it explains the
                // Regime size metric there (relocated from the top of the Exit plan section).
                // Stale-regime color branch preserved: amber when regime data is stale.
                if a.suggestedWeight > 0, store.regime != nil {
                    Text(store.regimeIsStale
                         ? "Regime size uses a STALE regime read — re-gauge the regime for a current number."
                         : "Regime size = base × the regime's risk bias — a gauge, not a forecast; green = a de-risking cut.")
                        .font(.caption2)
                        .foregroundStyle(store.regimeIsStale ? DS.Palette.warningSoft : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                sizingBrakeWaterfall(idea)
                if let stop = a.stopPrice, let target = a.targetPrice,
                   let rr = StockSageRewardRisk.assess(entry: idea.price, stop: stop, target: target) {
                    let c = rr.quality == .strong ? DS.Palette.successSoft
                          : (rr.quality == .poor ? DS.Palette.warningSoft : DS.Palette.textSecondary)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "scalemass.fill").font(.system(size: mvFont11)).foregroundStyle(c)
                        Text(rr.note).font(.caption2).foregroundStyle(c).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // DEG-03: as-of cue used to be gated on stop+target, so Hold/Avoid sheets (no plan
                // numerics) rendered scan-time claims (own-it %, extreme chip, journal) with ZERO
                // staleness context. Render whenever generatedAt resolves — nil generatedAt
                // (older/test-built ideas) → no note, never a fabricated timestamp — with the
                // Stop & Target clause (exact wording preserved) only when both prices exist.
                // Round-3: when the PRICE itself isn't from today (cache-served on a
                // weekend/offline — see StockSageIdea.priceAsOf), swap in a "not live" wording
                // instead of the analysis-time clause, so the sheet never implies a just-now
                // live quote for a stale cached price. nil priceAsOf ⇒ unknown, falls through to
                // the existing analysis-time wording unchanged (never a false "not live" label).
                if let generatedAt = idea.generatedAt {
                    let staleAsOf = Self.staleAsOfPrice(idea.priceAsOf, now: Date())
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "clock.badge.exclamationmark").font(.system(size: mvFont11)).foregroundStyle(.secondary)
                        Text(staleAsOf.map { "Price as of \($0.formatted(.relative(presentation: .named))) — not live." }
                             ?? (a.stopPrice != nil && a.targetPrice != nil
                                ? "Stop & Target computed at \(generatedAt.formatted(.relative(presentation: .named))) — recalculate before entry."
                                : "Analyzed \(generatedAt.formatted(.relative(presentation: .named))).")
                        )
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Multi-timeframe row promoted next to plan numerics (was at position 22).
                if let mtf = store.multiTimeframe[idea.symbol.uppercased()] {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: mtf.aligned ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: mvFont12)).foregroundStyle(mtf.aligned ? DS.Palette.successSoft : DS.Palette.warningSoft)
                        Text("Daily \(mtf.daily.rawValue) · Weekly \(mtf.weekly.rawValue)")
                            .font(.caption).foregroundStyle(.white)
                        Spacer()
                    }
                    Text(mtf.note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if ToolPolicy.isExternalAllowed
                           && !ProcessInfo.processInfo.arguments.contains("--qa")
                           && !mtfFetchCompleted.contains(idea.symbol.uppercased()) {
                    // Fetch is in progress — show spinner. Once the .task marks the symbol in
                    // mtfFetchCompleted the spinner is replaced by the unavailable fallback below,
                    // preventing a permanent spinner on network fetch failure.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(DS.Palette.accent)
                        Text("Checking the weekly timeframe…").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    // Either external access is off, --qa is set, OR the fetch completed without
                    // writing data (network failure / no history). All three paths land here.
                    Text("Weekly timeframe unavailable.").font(.caption2).foregroundStyle(.secondary)
                }

                // ── 7. "Why" rationale (moved above evidence pile) ────────
                if !a.rationale.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Why").font(.system(size: fontSectionHeader, weight: .semibold)).foregroundStyle(.white)
                        ForEach(Array(a.rationale.enumerated()), id: \.offset) { _, reason in
                            HStack(alignment: .top, spacing: 6) {
                                // Not tokenized: a fixed-size decorative bullet glyph (accessibilityHidden),
                                // not a label — Dynamic-Type scaling here would misalign it against the
                                // adjacent .caption text instead of conveying any information.
                                Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.secondary).padding(.top, 6)
                                    .accessibilityHidden(true)   // decorative bullet
                                Text(reason).font(.caption).foregroundStyle(DS.Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Why: \(a.rationale.joined(separator: ". "))")
                }

                // ── 8. Evidence: net-cost, EV + calibration tag, velocity/floor, backtest ─
                // "Evidence" header + Divider mirrors "Why" / "Exit plan" / "Context" treatment.
                // Gated on stop+target OR an active backtest panel — so a stop-less idea with a
                // running backtest doesn't render the backtest panel header-less between Why and Context.
                if (a.stopPrice != nil && a.targetPrice != nil) || store.backtestSymbol == idea.symbol {
                    Divider().opacity(0.2)
                    Text("Evidence").font(.system(size: fontSectionHeader, weight: .semibold)).foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                }
                if let stop = a.stopPrice, let target = a.targetPrice {
                    let costs = StockSageNetEdge.defaultCosts(forSymbol: idea.symbol)
                    // Same financing inputs netEVR/netVelocity/netCostFloorFlag already use — this
                    // line and the "why" it drives can never show a different net figure than what's
                    // actually driving the idea's rank elsewhere on the board (2026-07-02).
                    let (finRate, finDays) = StockSageExpectedValue.financingCostInputs(for: idea)
                    if let ne = StockSageNetEdge.evaluate(
                        entry: idea.price, stop: stop, target: target,
                        spreadBps: costs.spreadBps, slippageBps: costs.slippageBps, takerFeeBps: costs.takerFeeBps,
                        annualFinancingRate: finRate, holdDays: finDays,
                        winProb: StockSageExpectedValue.ev(conviction: a.conviction, entry: idea.price, stop: stop, target: target, calibration: store.convictionCalibration)?.winProbEstimate) {
                        let c = ne.costErodesEdge ? DS.Palette.warningSoft : DS.Palette.textSecondary
                        // F27 (factored): same logic as fullPlanText, now via the shared helper.
                        let financingNote = StockSageExpectedValue.financingNoteSuffix(rate: finRate, days: finDays)
                        // DISPLAY-only: crypto shows the engine's tier-aware LOW–HIGH band instead
                        // of the flat 70bps point (a thin alt is honestly 160–440bps); every other
                        // asset class is byte-identical to before. Does not touch `ne`/`costs`
                        // (still `defaultCosts`) — only this label text.
                        let costLabel = StockSageNetEdge.costsDisplayLabel(forSymbol: idea.symbol, advDollar: store.liquidity[idea.symbol.uppercased()]?.avgDollarVolume)
                        // Audit 2026-07-12 #1: when the crypto band's low > the flat cost `evaluate`
                        // actually priced (thin tier), disclose that the net below is optimistic vs
                        // the band the header states — the net figure stays at the ranking cost.
                        let costNote = StockSageNetEdge.costsDisplayNote(forSymbol: idea.symbol, advDollar: store.liquidity[idea.symbol.uppercased()]?.avgDollarVolume)
                        let pre = "After \(costLabel) costs\(financingNote): "
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "scissors").font(.system(size: mvFont11)).foregroundStyle(c)
                            // Gross→net fusion (UI wave #1): when both resolve, render as ONE Text unit
                            // — gross at reduced opacity, net at full — so they can't be read as two
                            // independent numbers. nil/non-positive net path is byte-identical to before.
                            (ne.netRR > 0
                                ? grossToNetText(
                                    prefix: pre + "R:R ", grossLabel: String(format: "%.1f:1 (gross)", ne.grossRR),
                                    netLabel: String(format: "%.1f:1 (net)", ne.netRR),
                                    suffix: ". \(ne.verdict)\(costNote)", font: .caption2, color: c)
                                : Text(pre + ne.verdict + costNote).font(.caption2).foregroundStyle(c))
                                .fixedSize(horizontal: false, vertical: true)
                                .help("Nets an asset-class round-trip spread+slippage estimate (crypto widest, FX/large-cap tightest) — and, for a short, the overnight borrow/margin cost of holding the expected duration — out of the reward:risk. Your real costs differ — wide-margin trades barely notice; thin scalps can lose the whole edge.")
                        }
                    }
                }
                if let stop = a.stopPrice, let target = a.targetPrice,
                   let ev = StockSageExpectedValue.ev(conviction: a.conviction, entry: idea.price, stop: stop, target: target, calibration: store.convictionCalibration) {
                    // F3 dedup (critique fleet #1): the standalone "Est. EV … (gross)" sentence
                    // printed the same ev.evR the ledger's Gross-expectancy row below prints —
                    // deleted. Its unique content (the "~N% est. win × R:R" annotation) now lives
                    // in the ledger row's label instead (see ledgerRow call below); the estimate
                    // caveat (.help(StockSageExpectedValue.caveat)) moved onto that row too so it
                    // isn't lost. The calibration chip stays exactly where it was, adjacent to the
                    // ledger.
                    // Always-visible measured/fitted/assumed tag directly under the EV line.
                    // F01/F02: the chip keys on the calibration METHOD (identity → "assumed"); nil-safe.
                    HStack(spacing: 6) {
                        calibrationChip
                    }
                    // UI wave #6: net-edge ledger. Itemizes ONLY the cost granularity
                    // StockSageNetEdge.evaluate() actually exposes — the shipped NetEdge result
                    // folds spread+slippage+taker-fee+financing into ONE aggregate cost
                    // (costPerShare/costAsPctOfReward); it does NOT expose separate legs. So this
                    // renders exactly 3 rows: gross expectancy (ev.evR, same figure as the EV line
                    // above), ONE deduction row labeled with the engine's own "round-trip costs"
                    // terminology (matching the R:R line's "After ~Nbps est. … costs" wording,
                    // ONLY appending the financing note when financingNoteSuffix is non-empty —
                    // never inventing a spread/fee split), and net expectancy (ne.netExpectancyR,
                    // same winProb as ev so the two rows are the same trade). Same cost inputs as
                    // the R:R fusion line above (line ~4983) — can't disagree with it. nil ⇒
                    // nothing new renders (no fabricated ledger).
                    if let stop = a.stopPrice, let target = a.targetPrice {
                        let costs = StockSageNetEdge.defaultCosts(forSymbol: idea.symbol)
                        let (finRate, finDays) = StockSageExpectedValue.financingCostInputs(for: idea)
                        if let ne = StockSageNetEdge.evaluate(
                            entry: idea.price, stop: stop, target: target,
                            spreadBps: costs.spreadBps, slippageBps: costs.slippageBps, takerFeeBps: costs.takerFeeBps,
                            annualFinancingRate: finRate, holdDays: finDays,
                            winProb: ev.winProbEstimate),
                           let netR = ne.netExpectancyR {
                            let financingNote = StockSageExpectedValue.financingNoteSuffix(rate: finRate, days: finDays)
                            // DISPLAY-only band for crypto — see costsDisplayLabel above; same
                            // reasoning, same non-crypto byte-identical fallback.
                            let costLabel = StockSageNetEdge.costsDisplayLabel(forSymbol: idea.symbol, advDollar: store.liquidity[idea.symbol.uppercased()]?.avgDollarVolume)
                            let deductionLabel = "Round-trip costs (\(costLabel))\(financingNote)"
                            let netColor = netR < 0 ? DS.Palette.dangerSoft : DS.Palette.successSoft
                            // F3 dedup: Gross-expectancy row label carries the "(~N% est. win ×
                            // R:R)" annotation the deleted standalone EV sentence used to print —
                            // its only content the ledger didn't already have. Same .help caveat
                            // that sentence carried, moved onto this row so it isn't lost.
                            let grossLabel = String(format: "Gross expectancy (~%.0f%% est. win × %.1f:1)",
                                                     ev.winProbEstimate * 100, ev.rewardR)
                            // F2 (owner-signed 2026-07-10): ADDITIVE per-order-minimum disclosure.
                            // The three rank-consistent rows above/below stay byte-identical (the
                            // 2026-07-02 no-divergence contract with netEVR); when the sizer knows
                            // the order AND flat per-order broker minimums LIFT the effective cost
                            // (intl tiers; see CostAssumption.perOrderMinimum), a fourth line says
                            // so at YOUR order size. nil on US/index/FX (minimum 0), unsized
                            // sizer, 0-share floors, or when bps already dominate.
                            let f2MinNote: String? = {
                                guard costs.perOrderMinimum > 0,
                                      let acct = StockSageInput.positiveAmount(sizerAccount),
                                      let rp = StockSageInput.percent(sizerRiskPct),
                                      let ps = sizedPosition(account: acct, riskFraction: rp / 100, symbol: idea.symbol, entry: idea.price, stop: stop),
                                      ps.shares > 0,
                                      let neSized = StockSageNetEdge.evaluate(
                                          entry: idea.price, stop: stop, target: target,
                                          spreadBps: costs.spreadBps, slippageBps: costs.slippageBps,
                                          takerFeeBps: costs.takerFeeBps,
                                          annualFinancingRate: finRate, holdDays: finDays,
                                          winProb: ev.winProbEstimate,
                                          perOrderMinimum: costs.perOrderMinimum,
                                          orderNotional: Double(ps.shares) * idea.price),
                                      neSized.costPerShare > ne.costPerShare + 1e-9 else { return nil }
                                let liftedBps = neSized.costPerShare / idea.price * 10_000
                                return String(format: "At your %d-share order, per-order broker minimums lift est. costs to ~%.0fbps — net R:R %.1f:1 at this size.",
                                              ps.shares, liftedBps, neSized.netRR)
                            }()
                            VStack(alignment: .leading, spacing: 3) {
                                ledgerRow(grossLabel, String(format: "%+.2fR", ev.evR), color: .white)
                                    .help(StockSageExpectedValue.caveat)
                                ledgerRow(deductionLabel, String(format: "−%.2fR", ev.evR - netR), color: DS.Palette.textSecondary)
                                ledgerRow("Net expectancy", String(format: "%+.2fR", netR), color: netColor)
                                // Audit 2026-07-12 #1: the deduction/net rows above are priced at the
                                // flat ranking cost; when the crypto band's low exceeds it, say the net
                                // is optimistic vs the band label. Empty (no row) on every non-thin case.
                                let cryptoOptimismSentence = StockSageNetEdge.costsOptimismSentence(forSymbol: idea.symbol, advDollar: store.liquidity[idea.symbol.uppercased()]?.avgDollarVolume)
                                if let cryptoOptimismSentence {
                                    Text(cryptoOptimismSentence)
                                        .font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let f2MinNote {
                                    Text(f2MinNote)
                                        .font(.caption2).foregroundStyle(DS.Palette.warningSoft)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.top, 2)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(String(format: "Gross expectancy %+.2fR (~%.0f%% estimated win rate times %.1f to 1 reward to risk), minus %@, net expectancy %+.2fR",
                                                       ev.evR, ev.winProbEstimate * 100, ev.rewardR, deductionLabel, netR)
                                                + (f2MinNote.map { ". " + $0 } ?? ""))
                        }
                    }
                }
                whyThisRankSection(idea)   // audit 2026-07-12 LANE 2: honest EV-rank decomposition
                if let vel = StockSageExpectedValue.velocity(for: idea, holds: velocityHolds, calibration: store.convictionCalibration) {
                    // F29: show gross velocity labeled + net when non-nil so the
                    // floor de-rank reason is traceable to an actual number shown on this screen.
                    // NEVER fabricate a net figure when netVelocity returns nil.
                    let netVel = StockSageExpectedValue.netVelocity(for: idea, holds: velocityHolds, calibration: store.convictionCalibration)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: mvFont11)).foregroundStyle(.secondary)
                        // Gross→net fusion (UI wave #1): when both resolve, render as ONE Text unit
                        // — gross at reduced opacity, net at full — so they can't be read as two
                        // independent numbers. nil net path renders the existing gross-only sentence
                        // byte-identically (no arrow, no placeholder).
                        (netVel != nil
                            ? grossToNetText(
                                prefix: "≈ ", grossLabel: String(format: "%+.3fR/day (gross)", vel),
                                netLabel: String(format: "%+.3fR/day (net)", netVel!),
                                suffix: " after est. costs (EV ÷ typical hold) — estimate.", font: .caption2, color: .secondary)
                            : Text(String(format: "≈ %+.3fR/day gross (EV ÷ typical hold) — faster turnover compounds faster. An estimate.", vel))
                                .font(.caption2).foregroundStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Honest floor label: shown verbatim when net EV/day (after est. costs) is
                    // below the 0.005R/day floor. The idea is de-ranked on the velocity board; this badge
                    // surfaces the reason so the re-ordering is transparent and auditable.
                    let vFloorFlag = StockSageExpectedValue.netCostFloorFlag(for: idea, holds: velocityHolds, calibration: store.convictionCalibration)
                    if hasFloorWarning && vFloorFlag.isDeranked {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.circle").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.warningSoft)
                            Text(vFloorFlag.badge + String(format: " — net EV/day after est. costs is under %.3fR/day; de-ranked on the velocity board.", StockSageExpectedValue.minNetEVPerDayFloor))
                                .font(.caption2).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                        }
                        .help(String(format: "Net EV/day after est. costs is under %.3fR/day — de-ranked on the velocity board. See the net-cost breakdown above.", StockSageExpectedValue.minNetEVPerDayFloor))
                    }
                }

                // Backtest panel (moved above action buttons so evidence precedes commitment).
                // Anchor for auto-scroll — fires when the run STARTS (backtestSymbol set synchronously).
                // Negative top-padding cancels the ~10px phantom VStack gap (cosmetic).
                Color.clear.frame(height: 0).id("backtestAnchor").padding(.top, -DS.Space.sm)
                if store.backtestSymbol == idea.symbol { backtestPanel }

                // ── 9. "Exit plan" labeled section ───────────────────────────────
                // Simplified to ladder/chandelier only: the regime-size caveat was
                // relocated to directly under the plan-numerics metrics row where it explains
                // the Regime size metric. hasExitPlanContent now guards only the actual exit content.
                //   • scale-out ladder: a.stopPrice != nil && a.targetPrice != nil
                //   • chandelier: store.trailingStop[symbol] != nil
                let hasExitPlanContent: Bool = {
                    if a.stopPrice != nil && a.targetPrice != nil { return true }
                    if store.trailingStop[idea.symbol.uppercased()] != nil { return true }
                    return false
                }()
                if hasExitPlanContent {
                    Divider().opacity(0.2)
                    Text("Exit plan").font(.system(size: fontSectionHeader, weight: .semibold)).foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                }

                // Scale-out ladder (bell buttons per rung to seed price alerts).
                if let stop = a.stopPrice, let target = a.targetPrice,
                   let ladder = StockSagePartialLadder.levels(entry: idea.price, stop: stop, target: target, rungs: 3) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "stairs").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.textSecondary)
                        VStack(alignment: .leading, spacing: 4) {
                            // Caption + "Arm all 3" button in the same row.
                            HStack(spacing: 8) {
                                Text("Scale-out (⅓ each) — blended +\(String(format: "%.1f", ladder.blendedExitR))R. Banks gains + cuts variance vs all-at-target; assumes each level fills.")
                                    .font(.caption2).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                // "Arm all 3" — loops all rungs through addPriceAlert using the same
                                // level-vs-price direction rule as the per-rung bells. Disabled once
                                // every rung has an existing armed alert (same alreadyArmed predicate).
                                let allArmed: Bool = ladder.rungs.allSatisfy { rung in
                                    let d: PriceAlert.Direction = rung.price > idea.price ? .above : .below
                                    return store.priceAlerts.contains(where: {
                                        $0.isArmed && $0.symbol == idea.symbol.uppercased()
                                        && $0.target == rung.price && $0.direction == d
                                    })
                                }
                                Button {
                                    for rung in ladder.rungs {
                                        let d: PriceAlert.Direction = rung.price > idea.price ? .above : .below
                                        store.addPriceAlert(symbol: idea.symbol, target: rung.price, direction: d)
                                    }
                                } label: {
                                    Text("Arm all 3").font(.system(size: mvFont10, weight: .medium))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(allArmed ? DS.Palette.accent : DS.Palette.textSecondary)
                                .disabled(allArmed)
                                .help(allArmed
                                      ? "All 3 scale-out price alerts are already armed."
                                      : "Arm price alerts at all 3 scale-out rungs in one tap — same direction rule as the per-rung bells.")
                                .accessibilityLabel(allArmed
                                                    ? "All 3 scale-out price alerts already armed"
                                                    : "Arm all 3 scale-out price alerts")
                            }   // end HStack (caption + Arm all 3)
                            ForEach(ladder.rungs.indices, id: \.self) { i in
                                let rung = ladder.rungs[i]
                                let dir: PriceAlert.Direction = rung.price > idea.price ? .above : .below
                                // Dedup — skip/disable when an identical armed alert already exists
                                // (mirrors the priceAlertsPanel duplicate check at line ~711).
                                // Exact Double equality on rung.price is intentional: it matches
                                // store.addPriceAlert's own dedup; a refreshed quote regenerates
                                // rungs with new prices, re-enabling the bell. (L)
                                let alreadyArmed = store.priceAlerts.contains(where: {
                                    $0.isArmed && $0.symbol == idea.symbol.uppercased()
                                    && $0.target == rung.price && $0.direction == dir
                                })
                                HStack(spacing: 6) {
                                    Text("\(adaptivePrice(rung.price)) (+\(String(format: "%.1f", rung.rMultiple))R)")
                                        .font(.caption2).foregroundStyle(DS.Palette.textSecondary)
                                    Spacer()
                                    Button {
                                        // K: pass raw idea.symbol — store normalizes to uppercase internally.
                                        store.addPriceAlert(symbol: idea.symbol, target: rung.price, direction: dir)
                                    } label: {
                                        Image(systemName: alreadyArmed ? "bell.fill" : "bell.badge")
                                            .font(.system(size: mvFont11))
                                            .foregroundStyle(alreadyArmed ? DS.Palette.accent : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(alreadyArmed)
                                    // F: dynamic .help and .accessibilityLabel based on armed state.
                                    .help(alreadyArmed
                                          ? "Price alert already armed at \(adaptivePrice(rung.price))"
                                          : "Alert at \(adaptivePrice(rung.price)) (+\(String(format: "%.1f", rung.rMultiple))R rung)")
                                    .accessibilityLabel(alreadyArmed
                                                        ? "Price alert already armed at \(adaptivePrice(rung.price))"
                                                        : "Set price alert at \(adaptivePrice(rung.price))")
                                }
                            }
                        }
                    }
                }

                // Chandelier / trailing stop exit (moved here from the risk-context area).
                if let ts = store.trailingStop[idea.symbol.uppercased()] {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.up.forward.circle").font(.system(size: mvFont11)).foregroundStyle(.secondary)
                        Text("Chandelier exit ~\(adaptivePrice(ts.level)) (highest high − \(String(format: "%.0f", ts.multiple))×ATR, \(String(format: "%.0f", ts.distancePct))% below) — a STARTING trailing level; move it up as new highs print, never down. An exit rule, not a target.")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Cluster-check result computed ONCE here and reused by both hasContextContent
                // and the child render below (~5782) — the FORMER "buy/strongBuy ⇒ renders" clause
                // over-approximated: checkDated returns nil whenever the portfolio has no OTHER
                // dated-return holdings to compare against (e.g. an empty portfolio), so the child
                // silently rendered nothing while the header still showed (orphan "Context" header,
                // audit 2026-07-08). Sharing this one optional means the predicate and the child
                // can never diverge again.
                let clusterResult: (check: ClusterCheck, skipped: Int)? = {
                    guard a.action == .buy || a.action == .strongBuy else { return nil }
                    let candDated = store.precheckDatedReturns[idea.symbol.uppercased()] ?? []
                    let heldDated = portfolio.positions.compactMap { p -> (symbol: String, returns: [(date: Date, ret: Double)])? in
                        guard let dr = store.precheckDatedReturns[p.symbol.uppercased()], !dr.isEmpty else { return nil }
                        return (p.symbol, dr)
                    }
                    return StockSageClusterCheck.checkDated(
                        candidate: idea.symbol, candidateReturns: candDated, holdings: heldDated)
                }()

                // ── 10. "Context" labeled section ────────────────────────────────
                // Gate the Divider+header on whether at least one child will actually render.
                // Derived from the real child guards:
                //   • earnings (non-buy path): action != buy/strongBuy && earnings[symbol]?.isWarning
                //   • asset-class risk note: StockSageGlossary.assetClassRiskNote(symbol) != nil
                //   • portfolio precheck: precheck[symbol]?.verdict != .noHoldings
                //   • what-if concentration: !portfolio.positions.isEmpty
                //   • cluster check: clusterResult != nil (SAME optional the child renders from)
                //   • liquidity: liquidity[symbol] != nil
                //   • seasonality: seasonality[symbol] != nil (inner stat/samples guard in child)
                let hasContextContent: Bool = {
                    let sym = idea.symbol.uppercased()
                    if a.action != .buy && a.action != .strongBuy,
                       let ep = store.earnings[sym], ep.isWarning { return true }
                    if StockSageGlossary.assetClassRiskNote(for: idea.symbol) != nil { return true }
                    if let pc = store.precheck[sym], pc.verdict != .noHoldings { return true }
                    if !portfolio.positions.isEmpty { return true }
                    if clusterResult != nil { return true }
                    if store.liquidity[sym] != nil { return true }
                    if store.seasonality[sym] != nil { return true }
                    return false
                }()
                if hasContextContent {
                    Divider().opacity(0.2)
                    Text("Context").font(.system(size: fontSectionHeader, weight: .semibold)).foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                }

                // Earnings (sell/reduce path fallback — buy-family earnings already shown above gate).
                if a.action != .buy && a.action != .strongBuy {
                    if let ep = store.earnings[idea.symbol.uppercased()], ep.isWarning {
                        earningsWarningRow(ep)
                    }
                }

                // Asset-class risk note
                if let note = StockSageGlossary.assetClassRiskNote(for: idea.symbol) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.warningSoft)
                        Text(note).font(.caption2).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Portfolio precheck
                if let pc = store.precheck[idea.symbol.uppercased()], pc.verdict != .noHoldings {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: pc.isWarning ? "exclamationmark.triangle.fill"
                              : (pc.verdict == .diversifying ? "checkmark.seal.fill" : "circle.grid.2x2.fill"))
                            .font(.system(size: mvFont11))
                            .foregroundStyle(pc.isWarning ? DS.Palette.danger
                                             : (pc.verdict == .diversifying ? DS.Palette.successSoft : DS.Palette.textSecondary))
                        Text(pc.note).font(.caption2)
                            .foregroundStyle(pc.isWarning ? DS.Palette.dangerSoft : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // What-if concentration (class + sector). Audit 2026-07-12 pass-3: FX-convert to USD
                // (mirror the allocation panel) — summing SAR/JPY/EUR holdings at 1:1 with USD makes the
                // "% of book" and the >60% CONCENTRATED warning point at the wrong currency's holdings.
                // holdingValue already pence-normalizes; the × rate adds cross-currency conversion.
                // Untracked-FX holdings are excluded (no rate) rather than summed 1:1 — same as allocation.
                let whatIfFX = fxRatesToUSD
                let whatIfHoldings = portfolio.positions.compactMap { p -> (symbol: String, value: Double)? in
                    guard let rate = whatIfFX[conversionCurrencyForSymbol(p.symbol)] else { return nil }
                    return (symbol: p.symbol,
                            value: holdingValue(p.symbol, perShare: currentPrice(p.symbol) ?? p.costBasis, shares: p.shares) * rate)
                }
                if !whatIfHoldings.isEmpty {
                    let bookTotal = whatIfHoldings.reduce(0) { $0 + $1.value }
                    let sizedNotional: Double? = {
                        if let stop = a.stopPrice, let acct = parsedAccount, let rf = parsedRiskFraction,
                           let ps = sizedPosition(account: acct, riskFraction: rf, symbol: idea.symbol, entry: idea.price, stop: stop) {
                            // Normalize pence-quoted symbols (.L/.JO) to major-unit value so
                            // the what-if concentration check isn't ~100× overstated.
                            return StockSageCurrency.majorUnitValue(symbol: idea.symbol, rawValue: ps.notional)
                        }
                        return nil
                    }()
                    // Cap to cash actually deployable — the sizer's notional can be leveraged.
                    let addValue = StockSageWhatIf.proposedAddValue(
                        sizedNotional: sizedNotional, account: parsedAccount, bookTotal: bookTotal)
                    let impact = StockSageWhatIf.addingHolding(symbol: idea.symbol, addedValue: addValue, to: whatIfHoldings)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: impact.isWarning ? "exclamationmark.triangle.fill" : "chart.pie.fill")
                            .font(.system(size: mvFont11)).foregroundStyle(impact.isWarning ? DS.Palette.danger : .secondary)
                        Text(impact.note).font(.caption2)
                            .foregroundStyle(impact.isWarning ? DS.Palette.dangerSoft : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Surface a SECTOR concentration warning only when it newly crosses
                    // (the class line above already covers the common case).
                    let sectorImpact = StockSageWhatIf.addingHolding(symbol: idea.symbol, addedValue: addValue,
                                                                     to: whatIfHoldings, classify: StockSageSector.sector)
                    if sectorImpact.isWarning {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: mvFont11)).foregroundStyle(DS.Palette.danger)
                            Text("By sector — " + sectorImpact.note).font(.caption2)
                                .foregroundStyle(DS.Palette.dangerSoft).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // Cluster check (concentration-in-disguise check — moved from buy-block to Context).
                // F14 (2026-07-02): correlates DATE-ALIGNED real daily returns cached by
                // refreshPrecheck (the same fetch the sibling precheck row above uses — no extra
                // network), NOT positional ~2-day down-sampled sparks. Positional pairing across
                // calendars (Tadawul/US, 24/7 crypto vs 5-day equity) compares returns from
                // DIFFERENT days, biasing toward 0 — this sheet could show a false-green "adds
                // diversification" while the precheck row disagreed. A pair with <5 overlapping
                // days is UNKNOWN and skipped; with no scorable pair nothing renders (honest
                // unknown — never a fabricated coefficient).
                if a.action == .buy || a.action == .strongBuy {
                    let heldDated = portfolio.positions.compactMap { p -> (symbol: String, returns: [(date: Date, ret: Double)])? in
                        guard let dr = store.precheckDatedReturns[p.symbol.uppercased()], !dr.isEmpty else { return nil }
                        return (p.symbol, dr)
                    }
                    let missingSeries = portfolio.positions.count - heldDated.count
                    if let (cc, overlapSkipped) = clusterResult {
                        // Show the verdict either way: a warning when it concentrates,
                        // an affirmation when it genuinely diversifies the checked subset.
                        // Suppress the green affirmation when holdings were skipped (no fetched
                        // series, or too few overlapping days) — we can't claim diversification
                        // on data we didn't check.
                        let uncheckedCount = missingSeries + overlapSkipped
                        let checkedCount = heldDated.count - overlapSkipped
                        let cColor = cc.isConcentrating ? DS.Palette.warningSoft : DS.Palette.textSecondary
                        let cIcon = cc.isConcentrating ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
                        let note: String = {
                            if !cc.isConcentrating && uncheckedCount > 0 {
                                return cc.note + " (among \(checkedCount) holdings with overlapping daily history — \(uncheckedCount) could not be checked)"
                            }
                            return cc.note
                        }()
                        if cc.isConcentrating || uncheckedCount == 0 {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: cIcon).font(.system(size: mvFont11)).foregroundStyle(cColor)
                                Text(note).font(.caption2).foregroundStyle(cColor).fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            // Partial coverage — show without the green checkmark to avoid over-affirming.
                            Text(note).font(.caption2).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // Liquidity
                if let liq = store.liquidity[idea.symbol.uppercased()] {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: liq.tier == .thin ? "drop.triangle.fill" : "drop.fill")
                            .font(.system(size: mvFont11))
                            .foregroundStyle(liq.tier == .thin ? DS.Palette.warningSoft : .secondary)
                        Text(liq.note).font(.caption2)
                            .foregroundStyle(liq.tier == .thin ? DS.Palette.warningSoft : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Seasonality
                if let s = store.seasonality[idea.symbol.uppercased()] {
                    // UTC, matching compute()'s bucketing — a LOCAL month can disagree near a
                    // boundary and highlight the wrong bucket's stat.
                    let m = StockSageSeasonality.currentMonth()
                    if let stat = StockSageSeasonality.stat(s, month: m), stat.samples > 0 {
                        // Sheet-lens HIGH (2026-07-09): this is the EXACT stat the TOM tilt reads —
                        // presenting it as pure context on the surface where the crowning gets
                        // audited hides a live rank input (the owner's KEEP is premised on
                        // disclosure). `seasonalityTiltFires` is the engine's own gate, so this
                        // clause can never drift from when the bonus actually fires; hold/avoid
                        // ideas take no tilt, so they get no claim.
                        let tiltFires = StockSageExpectedValue.seasonalityTiltFires(stat)
                            && idea.advice.action != .hold && idea.advice.action != .avoid
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "calendar").font(.system(size: mvFont11)).foregroundStyle(.secondary)
                            // Cached formatter — a fresh DateFormatter() per body eval is the
                            // verified hitch pattern (SWIFT_PITFALLS.md §11).
                            Text(stat.note(monthName: Self.timeFormatter.monthSymbols[m - 1])
                                 + (tiltFires ? " With the seasonal tilt on, this month stat nudges this name's EV-board rank (capped ±0.03; sign flips for sell ideas)." : ""))
                                .font(.caption2)
                                .foregroundStyle(stat.isReliable ? .secondary : DS.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // Bottom gap — .safeAreaInset(edge:.bottom) already insets the ScrollView
                // content on macOS 26.5, so the old 72px spacer was adding ~96px dead band.
                // A small gap is enough to visually separate content from the inset bar.
                Color.clear.frame(height: DS.Space.sm)
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: 680, alignment: .leading)   // cap content for readability
            .frame(maxWidth: .infinity)                  // …centered on wide windows
            } // end VStack / ScrollView content
            // ── Pinned verdict-bearing CTA bar ──────────────────────────────
            // Floats above the scroll, always reachable. Verdict chip is CONDITIONAL:
            // only buy-family ideas have a gate; Hold/Avoid show buttons only.
            .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()   // top hairline so content scrolls cleanly under the bar
                VStack(spacing: 6) {
                    // ── Button row ──
                    HStack(spacing: DS.Space.sm) {
                        if isLoggableIdea(a.action) {
                            Button { prefillTradeFromIdea(idea) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.pencil").font(.system(size: mvFont11, weight: .semibold))
                                    // Short label: the bar packs 3 buttons + the verdict chip into the
                                    // 440pt-minWidth sheet — long labels wrap mid-word (visual QA 2026-07-02).
                                    Text("Log trade").font(.system(size: mvFont11_5, weight: .semibold))
                                        .lineLimit(1).fixedSize()
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(DS.Palette.accent.opacity(0.9), in: Capsule())
                            }
                            .buttonStyle(LuxPressStyle())
                            .help("Prefill the trade journal with this idea's direction, entry, stop and target")
                        }

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fullPlanText(for: idea), forType: .string)
                            planCopied = true
                            Task { try? await Task.sleep(for: .seconds(2)); planCopied = false }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: planCopied ? "checkmark" : "doc.on.clipboard")
                                    .font(.system(size: mvFont11, weight: .semibold))
                                    .contentTransition(.symbolEffect(.replace))
                                // Fixed-width frame so the capsule width stays stable when the
                                // label transitions from "Copy plan" (9 chars) to "Copied" (6).
                                Text(planCopied ? "Copied" : "Copy plan")
                                    .font(.system(size: mvFont11_5, weight: .semibold))
                                    .frame(minWidth: 58, alignment: .leading)
                                    .lineLimit(1).fixedSize()
                                    .contentTransition(.opacity)
                            }
                            .foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Color.white.opacity(0.10), in: Capsule())
                            .overlay(Capsule().stroke(DS.Palette.surfaceStroke, lineWidth: 1))
                        }
                        .buttonStyle(LuxPressStyle())
                        .help("Copy a clean text trade plan (entry/stop/target/R:R/size/flags/scale-out) to the clipboard. Blocked setups are auto-skipped and exported as gate-status only.")

                        // Extension batch (2026-07-16): share/save the SAME plan text the Copy
                        // button produces (identical honesty flags — one source, no drift).
                        PlanShareButton(planText: fullPlanText(for: idea), symbol: idea.symbol, iconSize: mvFont11)

                        Button { Task { await store.runBacktest(symbol: idea.symbol) } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath").font(.system(size: mvFont11, weight: .semibold))
                                Text("Backtest 5y").font(.system(size: mvFont11_5, weight: .semibold))
                                    .lineLimit(1).fixedSize()
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Color.white.opacity(0.10), in: Capsule())
                            .overlay(Capsule().stroke(DS.Palette.surfaceStroke, lineWidth: 1))
                        }
                        .buttonStyle(LuxPressStyle()).disabled(store.isBacktesting)
                        .help("Run a 5-year backtest of the advisor's rules on this symbol — results appear in the Evidence section")

                        Spacer(minLength: 0)

                        // ── Verdict chip — buy-family only (gate doesn't exist for Hold/Avoid) ──
                        if a.action == .buy || a.action == .strongBuy {
                            let gateInputs = tradeGateInputs(for: idea)
                            // F04: was `?? 0.01` — an unparseable risk % silently rendered a fabricated
                            // "Clear"/"Caution" verdict in this PINNED bar the user relies on to place
                            // the trade. nil now renders an honest "set risk %" chip instead of a verdict.
                            if let chipGate = tradeGateVerdict(for: idea, inputs: gateInputs) {
                                let chipColor: Color = chipGate.decision == .clear ? DS.Palette.successSoft
                                    : (chipGate.decision == .caution ? DS.Palette.warningSoft : DS.Palette.dangerSoft)
                                let chipIcon = chipGate.decision == .clear ? "checkmark.shield.fill"
                                    : (chipGate.decision == .caution ? "exclamationmark.triangle.fill" : "xmark.shield.fill")
                                // Visual QA 2026-07-02: the bar can't fit 3 buttons + the full verdict
                                // phrase at the 440pt sheet floor ("Proceed with caution" truncated to
                                // "Proceed…"). The chip uses a COMPACT label — icon + tint carry severity,
                                // the full verdict stays in .help and the VoiceOver label, and the complete
                                // gate section above remains the authoritative wording.
                                // "Blocked" (2026-07-07): the Today family's ratified chip vocabulary.
                                // "Do NOT trade" (80pt ideal at 9pt) truncated to "Do NOT t…" in the 45pt
                                // slot at the sheet's NATURAL width (the sheet doesn't grow with the
                                // window) — visual-QA'd on the F04 + ux-wave-2 merges. "Blocked" fits;
                                // the full verdict wording stays in the gate section, .help and VoiceOver.
                                let chipCompact = chipGate.decision == .clear ? "Clear"
                                    : (chipGate.decision == .caution ? "Caution" : "Blocked")
                                // Font reverted to mvFont9 (NOT fontChipLabel, unlike every other chip on
                                // this surface): offscreen layout measurement at the 440pt sheet floor
                                // (392pt inner width) found the three CTA buttons incompressible at
                                // 97+100+110 + 4×10 gaps = 347pt, leaving only 45pt for this chip — an
                                // ideal width of 87pt at 10pt vs 80pt at 9pt. The 9→10pt bump moved the
                                // fit threshold ~7pt narrower and worsened truncation risk on the exact
                                // row that exists to surface a do-not-trade verdict.
                                Label(chipCompact, systemImage: chipIcon)
                                    .font(.system(size: mvFont9, weight: .semibold))
                                    .foregroundStyle(chipColor)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                    .help("\(chipGate.decision.rawValue) — \(chipGate.caveat)")
                                    .accessibilityLabel("Pre-trade gate: \(chipGate.decision.rawValue)")
                            } else {
                                // "Risk %" not "Set risk %": at the sheet's natural width the
                                // 45pt chip slot truncated the longer label to "…" (driven QA
                                // 2026-07-16) — same compact-vocabulary fix the verdict chip
                                // ratified; full instruction stays in .help and VoiceOver.
                                Label("Risk %", systemImage: "questionmark.circle")
                                    .font(.system(size: mvFont9, weight: .semibold))
                                    .foregroundStyle(DS.Palette.textSecondary)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                    .help("Enter risk % to see the pre-trade gate verdict.")
                                    .accessibilityLabel("Pre-trade gate: risk percent not set")
                            }
                        }
                    }
                    // ── Caveat (always visible — stronger than hiding it below the fold) ──
                    Text(a.caveat).font(.system(size: mvFont9)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.sm)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                // Frosted pinned bar (macOS 27 overhaul): the textbook material case —
                // a floating bar the evidence content scrolls beneath. Background-only
                // change: the visually-QA'd 440pt width budgets above are untouched.
                .background(.ultraThinMaterial)
            }
        } // end safeAreaInset closure
        // onChange fires when the run STARTS (Store sets backtestSymbol
        // synchronously at runBacktest entry) — scroll to the backtest anchor
        // at start so the user sees the spinner appear in place.
        .onChange(of: store.backtestSymbol) { _, sym in
            guard sym == idea.symbol else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                proxy.scrollTo("backtestAnchor", anchor: .top)
            }
        }
        // Prev/next step: the sheet stays presented (item-bound, updates in place), so the
        // scroll offset would carry over to the NEW idea with the header off-screen. Snap
        // to the top instantly (no animation — reorientation, not decoration). Fires only
        // on an in-place identity change; a fresh open presents at the top anyway.
        .onChange(of: idea.id) { _, _ in
            proxy.scrollTo("sheetTopAnchor", anchor: .top)
        }
        } // end ScrollViewReader (house pattern — proxy stays in scope for .onChange)
        .frame(minWidth: 440, maxWidth: 680, minHeight: 480)
        .background(
            // Sheet root stays owner-drawn (the QA snapshot path renders this view
            // outside a real .sheet, so it needs an opaque backing) — but the dead
            // grey becomes the canvas wash (macOS 27 overhaul).
            ZStack {
                DS.Gradient.bg
                RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
                    .fill(DS.Bezel.shellFill)
                RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
                    .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.modal, style: .continuous)
                .stroke(DS.Palette.surfaceStroke, lineWidth: 1)
        )
        .task(id: idea.symbol) {
            guard !ProcessInfo.processInfo.arguments.contains("--qa") else { return }
            // Invalidate any prior completion mark for THIS symbol FIRST — before the debounce
            // sleep, so a revisited symbol whose earlier fetch completed without data
            // (mtfFetchCompleted already contains it, multiTimeframe[sym] == nil) shows the
            // SPINNER for the whole debounce+fetch window, never the definitive "Weekly
            // timeframe unavailable" fallback: the sheet cannot both promise "in flight"
            // (spinner) and "definitively absent" for one symbol at once. (Removing before the
            // sleep is safe: if this task is then cancelled it simply re-fetches on next open —
            // the honest behavior; a symbol with data is untouched since its render keys on
            // multiTimeframe[sym] != nil, not the mark.)
            mtfFetchCompleted.remove(idea.symbol.uppercased())
            // Rapid-stepping debounce (prev/next nav) — fires ONLY on a STEP, never on the
            // dominant plain-open path: this task re-fires for EVERY symbol the .task(id:)
            // sees, and the body below issues SIX sequential store refreshes. A step is
            // lastSheetSymbol being non-nil AND different from this symbol (first-open has
            // lastSheetSymbol == nil; re-opening the SAME symbol, e.g. a SwiftUI re-render,
            // never debounces either). Sleep ~300ms first — if the user already stepped on,
            // .task(id:) has cancelled this task (Task.sleep throws CancellationError; try?
            // swallows it and the isCancelled guard bails), so a skipped-over symbol fires
            // ZERO refreshes.
            if let last = lastSheetSymbol, last != idea.symbol {
                try? await Task.sleep(for: .milliseconds(300))
            }
            // NAV-1: closing the sheet DURING the 300ms sleep doesn't cancel this task on some
            // dismissal paths (the sheet's own onChange resets lastSheetSymbol to nil, but
            // .task(id:) cancellation isn't guaranteed to race ahead of it) — without the
            // selectedIdea != nil check, the surviving task could overwrite that nil-reset right
            // back to this symbol, leaving the debounce state pointing at a sheet that's closed.
            guard !Task.isCancelled, selectedIdea != nil else { return }
            // Record the symbol only AFTER surviving cancellation — a cancelled step must not
            // write a stale lastSheetSymbol that could mis-trigger (or skip) the next debounce.
            lastSheetSymbol = idea.symbol
            await store.refreshMultiTimeframe(symbol: idea.symbol)
            // F31: guard the completion mark with Task.isCancelled. If the sheet was dismissed
            // mid-fetch the task is cancelled but execution continues past the await — inserting
            // into mtfFetchCompleted in that case would cause the NEXT open to skip the spinner
            // and flash "Weekly timeframe unavailable" while a new fetch is in flight.
            guard !Task.isCancelled else { return }
            mtfFetchCompleted.insert(idea.symbol.uppercased())
            // Same F31 logic BETWEEN each remaining refresh: a cancelled task keeps executing
            // past every await unless it checks — without these, stepping mid-chain lets the
            // rest of the OLD symbol's fetches run to completion behind the new sheet.
            await store.refreshPrecheck(symbol: idea.symbol)
            guard !Task.isCancelled else { return }
            await store.refreshEarnings(symbol: idea.symbol)
            guard !Task.isCancelled else { return }
            await store.refreshSeasonality(symbol: idea.symbol)
            guard !Task.isCancelled else { return }
            await store.refreshLiquidity(symbol: idea.symbol)
            guard !Task.isCancelled else { return }
            await store.refreshTrailingStop(symbol: idea.symbol)
        }
    }

    /// Step the OPEN detail sheet to the previous/next idea in board order (displayedIdeas —
    /// the same post-sort/filter order the board renders). The current index is re-resolved
    /// by id HERE, AT PRESS TIME: displayedIdeas mutates under background refresh, so an
    /// index captured at render time can be stale by the time the press lands. Unknown-id or
    /// out-of-range steps are ignored (the chevrons also disable at the ends, but a press can
    /// race a board mutation — ignoring is the safe half of the clamp). Setting selectedIdea
    /// updates the item-bound sheet IN PLACE (no dismiss) and re-fires .task(id: idea.symbol).
    private func stepSheet(_ delta: Int, from id: String) {
        // Re-check selectedIdea is still non-nil and re-resolve from ITS id, not the
        // render-time-captured `id` param: a key/chevron press can land inside the ~200-300ms
        // dismissal-window race after the user already closed the sheet (selectedIdea = nil),
        // and stepping from the stale captured id would re-present the sheet the user just
        // dismissed on a different idea.
        guard let cur = selectedIdea else { return }
        let ideas = displayedIdeas
        guard let j = SheetCandidateNavigation.neighborIndex(ids: ideas.map(\.id), currentID: cur.id, delta: delta) else { return }
        selectedIdea = ideas[j]
    }

    /// Chevron prev/next + "N of M" label for the detail-sheet header. The render-time index
    /// drives ONLY the disabled state and the label; the button ACTIONS re-resolve via
    /// stepSheet(_:from:). When the shown idea is not on the current board (opened from
    /// bestOpportunityCTA / alerts while a filter hides it, or refreshed away) both chevrons
    /// disable and NO label renders — never a fabricated position (honesty floor).
    @ViewBuilder private func sheetNavControls(_ idea: StockSageIdea) -> some View {
        let ids = displayedIdeas.map(\.id)
        HStack(spacing: 4) {
            Button { stepSheet(-1, from: idea.id) } label: {
                Image(systemName: "chevron.up").font(.system(size: mvFont12, weight: .semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(SheetCandidateNavigation.neighborIndex(ids: ids, currentID: idea.id, delta: -1) == nil)
            .help("Previous idea (⌥⌘↑)")
            .accessibilityLabel("Previous idea")
            // ⌥⌘-modified, not bare or ⌘-only: the sheet hosts live TextFields (journalField →
            // the sizer's Acct $/Risk % fields). Three collisions ruled out in order: (1) a bare
            // .upArrow would steal the fields' cursor-movement keys; (2) ⌘↑/⌘↓ alone would steal
            // AppKit's standard move-caret-to-start/end-of-document field-editor binding
            // (moveToBeginningOfDocument:/moveToEndOfDocument:), which fires whenever a sizer
            // field is focused; (3) ⌥⌘↑/⌥⌘↓ is not a standard field-editor or system binding
            // (checked against Apple's standard key bindings) so it is safe. House precedent:
            // X binds .cancelAction; CodeView binds ⌘-modified equivalents; this is the first
            // ⌥⌘ pair in the file.
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            if let label = SheetCandidateNavigation.positionLabel(ids: ids, currentID: idea.id) {
                Text(label)
                    .font(.system(size: mvFont10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Idea \(label), board order")
            }
            Button { stepSheet(+1, from: idea.id) } label: {
                Image(systemName: "chevron.down").font(.system(size: mvFont12, weight: .semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(SheetCandidateNavigation.neighborIndex(ids: ids, currentID: idea.id, delta: +1) == nil)
            .help("Next idea (⌥⌘↓)")
            .accessibilityLabel("Next idea")
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }

    /// Gross→net fusion (UI wave #1, plans/PLAN_2026-07-07_ui_wave_gemini.md item #1): renders
    /// "<prefix><gross> → <net><suffix>" as ONE Text unit — gross at reduced opacity (0.7), net at
    /// full opacity — so the two figures read as a single decayed→resolved quantity, never as two
    /// independent numbers. Both "(gross)"/"(net)" labels are baked into the caller's grossLabel/
    /// netLabel strings (honesty floor: adjacency strengthens the label, never replaces it). Only
    /// call this when both values have already resolved non-nil — the nil path is the caller's
    /// existing byte-identical gross-only branch.
    private func grossToNetText(prefix: String, grossLabel: String, netLabel: String, suffix: String,
                                 font: Font, color: Color) -> Text {
        let a: Text = Text(prefix).font(font).foregroundStyle(color)
        let b: Text = Text(grossLabel).font(font).foregroundStyle(color.opacity(0.7))
        let c: Text = Text(" → ").font(font).foregroundStyle(color)
        let d: Text = Text(netLabel).font(font).foregroundStyle(color)
        let e: Text = Text(suffix).font(font).foregroundStyle(color)
        // Text-in-Text interpolation preserves per-segment styling; the Text `+`
        // operator is deprecated on macOS 26.
        return Text("\(a)\(b)\(c)\(d)\(e)")
    }

    // UI wave #6: one row of the net-edge ledger — label left, value right (monospaced digits
    // so the R figures align down the column), matching this sheet's caption2/mvFont9 rhythm.
    private func ledgerRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(value).font(.system(size: mvFont11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    // F24: merged with the former summaryStat helper (uniform a11y is the audit's stated goal —
    // summaryStat's 3 call sites had no accessibility grouping; they now get ideaMetric's
    // accessibilityElement(children: .ignore) + combined label, matching every other call site).
    // The optional `sub` parameter reproduces summaryStat's rendering byte-for-byte (uppercased
    // label at mvFont8, bold white value at mvFont14, no minimumScaleFactor, plus the sub line)
    // whenever a caller passes it; every call site that omits `sub` renders exactly as the
    // original ideaMetric always has (label as-is at mvFont9, value at mvFont12_5/semibold/color,
    // minimumScaleFactor 0.75).
    private func ideaMetric(_ label: String, _ value: String, color: Color = .white,
                            sub: String? = nil, subColor: Color = DS.Palette.successSoft) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(sub != nil ? label.uppercased() : label)
                .font(.system(size: sub != nil ? mvFont8 : mvFont9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let sub {
                Text(value).font(.system(size: mvFont14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).lineLimit(1)
                Text(sub).font(.system(size: mvFont8)).foregroundStyle(subColor).lineLimit(1)
            } else {
                Text(value).font(.system(size: mvFont12_5, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sub != nil ? "\(label) \(value) \(sub!)" : "\(label) \(value)")
    }

    private func convictionMeter(_ value: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(height: 5)
                Capsule().fill(color)
                    .frame(width: max(4, geo.size.width * min(max(value, 0), 1)), height: 5)
            }
        }
        .frame(height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(min(max(value, 0), 1) * 100)) percent")
    }

    /// Signal strength as 5 DISCRETE ordinal blocks — a categorical rules-based rating, deliberately
    /// NOT a continuous bar or an N/100 fraction (owner-directed 2026-07-07: a "/100" denominator
    /// reads as P(win) — denominator neglect — which the DSR≈0 reality forbids). `value` 0…1 →
    /// filled = round(value·5). nil is handled by the caller (the meter simply isn't rendered).
    /// Pure count math for `signalBlocks` — extracted so it's unit-testable without
    /// rendering a View. Byte-identical to the inline computation it replaced:
    /// clamp to [0,1], scale by 5, round-half-away-from-zero (Double.rounded() default).
    static func signalBlockCount(_ value: Double) -> Int {
        let v = min(max(value, 0), 1)
        return Int((v * 5).rounded())
    }

    /// Per-card staleness predicate (POST2420-COPY item 1; extended round-3 honesty hunt for
    /// `priceAsOf`): stale if EITHER the analysis is over 4h old (`generatedAt`, same threshold
    /// as `StockSageStore.ideasIsStale`, keyed on the card's own analysis time instead of the
    /// board-level `ideasUpdated` — which only advances when the WHOLE scan commits, so during a
    /// streaming scan a freshly-merged card's `generatedAt` is recent even though `ideasUpdated`
    /// hasn't moved) OR the underlying PRICE is not live/current — a cache-served idea
    /// (`partitionByCacheFreshness`/`isCacheFreshForToday`, a same-UTC-day 429-avoidance reuse
    /// left untouched by this predicate) whose price bar is not from TODAY (UTC), e.g. a
    /// weekend/offline cache hit whose last bar is days old even though `generatedAt` reads
    /// "just now". Reuses the SAME UTC-day bucketing `StockSageScanChunking.utcDayKey` already
    /// defines, so "today" means the same thing everywhere in the engine. nil `generatedAt` or
    /// nil `priceAsOf` (older/test-built ideas, mirrors the DEG-03 as-of cue's nil handling
    /// below) → that axis alone never flags stale (HONESTY_FLOOR: unknown renders nothing, never
    /// a false badge).
    static func cardIsStale(generatedAt: Date?, now: Date, priceAsOf: Date? = nil) -> Bool {
        let analysisStale: Bool = {
            guard let generatedAt else { return false }
            return now.timeIntervalSince(generatedAt) > 4 * 3600
        }()
        let priceStale: Bool = {
            guard let priceAsOf else { return false }
            return StockSageScanChunking.utcDayKey(priceAsOf) != StockSageScanChunking.utcDayKey(now)
        }()
        return analysisStale || priceStale
    }

    /// Round-H: the PRICE-only half of `cardIsStale` — same utcDayKey mismatch the detail
    /// sheet's DEG-03 "not live" cue already computes inline (~5406-5411), factored out so
    /// `bestOpportunityCard`/`bestOpportunityCTA` can reuse the identical check instead of a
    /// third hand-copied closure. Returns `priceAsOf` itself (for the label's date) when stale,
    /// nil otherwise — including when `priceAsOf` itself is nil (HONESTY_FLOOR: unknown never
    /// flags stale).
    static func staleAsOfPrice(_ priceAsOf: Date?, now: Date) -> Date? {
        guard let priceAsOf, StockSageScanChunking.utcDayKey(priceAsOf) != StockSageScanChunking.utcDayKey(now)
        else { return nil }
        return priceAsOf
    }

    /// DISPLAY-ONLY per-idea provenance tag ("Yahoo · 12m" / "cached · 3h" / "sample") — the
    /// card already tells you the price STATE (live/stale/cached badges above); this adds the
    /// SOURCE, reusing the SAME three truths the top banner keys on (`isSampleData`,
    /// `loadedFromCache`) so a row can never contradict the banner. Sample and cache are
    /// GLOBAL board states — checked first, exactly mirroring `sampleBanner`/`cachedBanner`'s own
    /// precedence — so every row on a sample/cached board reads the same as the banner. Only the
    /// live path is per-idea: `priceAsOf` ages this ONE symbol's own last bar. Age uses the same
    /// m/h/d thresholds as `cachedBannerText`. nil `priceAsOf` on a live board → nil (HONESTY_FLOOR:
    /// unknown renders nothing, never a fabricated "0m").
    static func sourceTagLabel(isSampleData: Bool, loadedFromCache: Bool, priceAsOf: Date?, now: Date) -> String? {
        if isSampleData { return "sample" }
        if loadedFromCache { return "cached" }
        guard let priceAsOf else { return nil }
        let secs = now.timeIntervalSince(priceAsOf)
        let age: String
        if secs < 60 { age = "just now" }
        else if secs < 3600 { age = "\(Int(secs / 60))m" }
        else if secs < 86_400 { age = "\(Int(secs / 3600))h" }
        else { age = "\(Int(secs / 86_400))d" }
        return "Yahoo · \(age)"
    }

    private func signalBlocks(_ value: Double, color: Color) -> some View {
        let filled = Self.signalBlockCount(value)
        return HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(i < filled ? color : Color.white.opacity(0.10))
                    .frame(height: 6)
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(filled) of 5 signal blocks (rules-based, not a probability)")
    }

    private func actionColor(_ a: TradeAdvice.Action) -> Color {
        switch a {
        case .strongBuy, .buy: return DS.Palette.successSoft
        case .hold:            return DS.Palette.warningSoft
        case .avoid:           return Color.white.opacity(0.22)
        case .reduce, .sell:   return DS.Palette.danger
        }
    }

    /// Dark ink on the light pastel badges (success/warning), white on the darker
    /// red/grey ones — same legibility rule as `recTextColor`.
    private func actionTextColor(_ a: TradeAdvice.Action) -> Color {
        switch a {
        case .reduce, .sell, .avoid: return .white
        default:                     return Color(white: 0.06)   // darker ink → AA contrast on bright pastels
        }
    }

    /// Sparkline tint by net direction over the shown window.
    private func sparkColor(_ spark: [Double]) -> Color {
        guard let first = spark.first, let last = spark.last, first != 0 else { return DS.Palette.accent }
        let change = (last - first) / abs(first)
        if change > 0.001 { return DS.Palette.successSoft }   // up >0.1%
        if change < -0.001 { return DS.Palette.danger }       // down >0.1%
        return DS.Palette.textSecondary                        // effectively flat → neutral, not a fake "green gain"
    }

    /// OSS-borrow B2 (TradingView lightweight-charts "plot a trade" price-lines + series
    /// markers, adapted to the detail-sheet sparkline): stop/target dashed lines, entry→stop
    /// and entry→target translucent bands, and a last-bar marker for where the plan was
    /// computed against. Sheet chart ONLY — the card spark is deliberately untouched (too
    /// small for a legible overlay).
    ///
    /// ALL-OR-NOTHING: renders only when stop AND target AND a non-empty spark all resolve.
    /// A partial plan (e.g. stop but no target) would draw a half-geometry that misrepresents
    /// the plan, so it renders nothing instead — same honesty posture as the rest of the sheet
    /// (nil ⇒ no fabricated partial claim). `domain` is computed ONCE by the caller (ideaDetailSheet)
    /// and passed to BOTH the Sparkline Shape and this overlay — a single shared y-mapping, so
    /// they can never diverge (registration fix; previously each recomputed its own domain and
    /// disagreed whenever stop/target fell outside the spark's own min...max).
    @ViewBuilder
    private func tradePlanOverlay(_ idea: StockSageIdea, domain: (lo: Double, hi: Double)?) -> some View {
        if let stop = idea.advice.stopPrice, let target = idea.advice.targetPrice,
           !idea.spark.isEmpty,
           let domain {
            let entry = idea.price
            let stopY = 1 - SparkSeries.fraction(stop, in: domain)     // Sparkline draws 0→bottom, 1→top
            let targetY = 1 - SparkSeries.fraction(target, in: domain)
            let entryY = 1 - SparkSeries.fraction(entry, in: domain)
            GeometryReader { geo in
                let h = geo.size.height
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    // Translucent bands: entry→stop (danger) and entry→target (success).
                    // Built from the actual Y values, not a long/short assumption — for a
                    // sell-family idea stop > entry in price terms so stopY < entryY on
                    // screen, and the band still spans exactly entry↔stop either way.
                    Rectangle()
                        .fill(DS.Palette.danger.opacity(0.08))
                        .frame(width: w, height: abs(stopY - entryY) * h)
                        .offset(y: min(stopY, entryY) * h)
                    Rectangle()
                        .fill(DS.Palette.success.opacity(0.08))
                        .frame(width: w, height: abs(targetY - entryY) * h)
                        .offset(y: min(targetY, entryY) * h)

                    // Stop / target dashed lines with a compact trailing label. The LINE stays
                    // at its true fraction (honest position); the LABEL's y is clamped inside
                    // the frame so it never renders below/above the chart, then de-collided if
                    // clamping pushed both labels to the same edge (OSS-borrow B2 fix).
                    let labelH = tradePlanLabelHeight
                    let stopLabelY = SparkSeries.clampedLabelY(stopY * h, height: h, labelHeight: labelH)
                    let targetLabelY = SparkSeries.clampedLabelY(targetY * h, height: h, labelHeight: labelH)
                    let (stopFinalY, targetFinalY) = SparkSeries.deconflictedLabelYs(stopLabelY, targetLabelY, labelHeight: labelH, height: h)
                    tradePlanLine(y: stopY * h, labelY: stopFinalY, width: w, color: DS.Palette.dangerSoft, label: adaptivePrice(stop))
                    tradePlanLine(y: targetY * h, labelY: targetFinalY, width: w, color: DS.Palette.successSoft, label: adaptivePrice(target))

                    // Last-bar marker: the price the plan was computed against.
                    // L4 dedup (critique fleet #1): this whole overlay is .accessibilityHidden +
                    // .allowsHitTesting(false) below, so a .help/.accessibilityLabel here was dead
                    // (never hit-testable, never VoiceOver-reachable) — deleted. Coverage moved to
                    // the Sparkline container's .help (the hit-testable parent).
                    Circle()
                        .fill(DS.Palette.accent)
                        .frame(width: 6, height: 6)
                        .position(x: w, y: entryY * h)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)   // the sparkline's own accessibilityLabel above already covers high/low/trend
        }
    }

    /// One dashed stop/target line at `y` + its trailing price label at `labelY` (may differ
    /// from `y` when clamped/de-collided — see `clampedLabelY`/`deconflictedLabelYs`) within a
    /// `width`-wide overlay. Shared by tradePlanOverlay's stop and target lines.
    private func tradePlanLine(y: CGFloat, labelY: CGFloat, width: CGFloat, color: Color, label: String) -> some View {
        // .topLeading (not .leading) makes the Text's natural position top-left (top at y=0),
        // matching the semantics clampedLabelY/deconflictedLabelYs assume: labelY is the label's
        // vertical CENTER, so top = labelY - labelH/2. The Path is a greedy fill either way.
        // Sanity: h=64, lh=13 (mvFont9=9+4) — bottom case labelY=57.5 → top=51, bottom=64 (fits);
        // top case labelY=6.5 → top=0, bottom=13 (fits).
        ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: width, y: y))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            Text(label)
                .font(.system(size: mvFont9, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 2))
                .offset(x: 2, y: labelY - tradePlanLabelHeight / 2)
        }
    }

    /// Approximate rendered height of a trade-plan label chip (font + vertical padding),
    /// scaling with Dynamic Type via `mvFont9` so the clamp keeps tracking real text size.
    private var tradePlanLabelHeight: CGFloat { mvFont9 + 4 }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: DS.Space.sm) {
            ZStack {
                if reduceMotion {
                    // Reduce Motion: static halo (no breathing loop).
                    Circle()
                        .fill(DS.Palette.accent.opacity(0.14))
                        .frame(width: 52, height: 52)
                        .blur(radius: 14)
                        .allowsHitTesting(false)
                } else {
                    PhaseAnimator([0.10, 0.18, 0.10]) { opacity in
                        Circle()
                            .fill(DS.Palette.accent.opacity(opacity))
                            .frame(width: 52, height: 52)
                            .blur(radius: 14)
                            .allowsHitTesting(false)
                    } animation: { opacity in
                        opacity > 0.14
                            ? .spring(duration: 2.2, bounce: 0.06)
                            : .easeOut(duration: 1.8)
                    }
                }
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: mvFont22, weight: .light))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 50, height: 50)
                    .background(RadialGradient(colors: [DS.Palette.accent.opacity(0.18), DS.Palette.accent.opacity(0.05)],
                                               center: .center, startRadius: 0, endRadius: 25), in: Circle())
                    .overlay(Circle().stroke(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                                            startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: DS.Palette.accent.opacity(0.26), radius: 14, y: 3)
            }
            Text("No symbols tracked yet.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
    }
}

/// Sections shown inside the single Markets tab.
enum MarketSection: String, CaseIterable, Identifiable {
    case watchlist, ideas, all, heatmap, portfolio, alerts, briefing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .watchlist: return "Watchlist"
        case .ideas:     return "Ideas"
        case .all:       return "All"
        case .heatmap:   return "Heatmap"
        case .portfolio: return "Portfolio"
        case .alerts:    return "Alerts"
        case .briefing:  return "Briefing"
        }
    }
}

/// Watchlist ordering (Chat C feature). `apply` is pure → unit-tested.
enum MarketSort: String, CaseIterable, Identifiable {
    case feed, change, signal, symbol
    var id: String { rawValue }
    var title: String {
        switch self {
        case .feed:   return "Default"
        case .change: return "Top gainers"
        case .signal: return "Strongest signal"
        case .symbol: return "A–Z"
        }
    }
    /// Rank for the "strongest signal" sort: strong > buy/sell > hold.
    static func rank(_ r: StockSageRecommendation) -> Int {
        switch r {
        case .strongBuy, .strongSell: return 2
        case .buy, .sell:             return 1
        case .hold:                   return 0
        }
    }
    func apply(_ syms: [StockSageSymbol]) -> [StockSageSymbol] {
        switch self {
        case .feed:   return syms
        case .symbol: return syms.sorted { $0.symbol.localizedCaseInsensitiveCompare($1.symbol) == .orderedAscending }
        case .change: return syms.sorted { ($0.latest?.changePercent ?? 0) > ($1.latest?.changePercent ?? 0) }
        case .signal:
            return syms.sorted { a, b in
                let ra = StockSageSignalEngine.generateSignal(for: a).map { MarketSort.rank($0.recommendation) } ?? -1
                let rb = StockSageSignalEngine.generateSignal(for: b).map { MarketSort.rank($0.recommendation) } ?? -1
                if ra != rb { return ra > rb }
                return abs(a.latest?.changePercent ?? 0) > abs(b.latest?.changePercent ?? 0)
            }
        }
    }
}

/// Reusable disclaimer footer (reuses the canonical StockSageMini text).
struct MarketDisclaimerFooter: View {
    var body: some View {
        Text(StockSageMini.disclaimer)
            .font(.caption2).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Frosted footer bar (macOS 27 overhaul): board content scrolls beneath
            // it via normalBody's safeAreaInset; the hairline keeps the edge crisp.
            .background(.ultraThinMaterial)
            .overlay(Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1), alignment: .top)
    }
}

/// Purely presentational best-move order ticket — crimson flat-dark styling matching
/// every other Markets card (DS tokens, LuxPressStyle, no system glass per
/// research/DESIGN_RESEARCH_macOS27.md's "custom fills for brand/status" guidance).
/// Takes only already-computed/formatted values; owns layout only.
struct BestOpportunityActionCard: View {
    let symbol: String
    let actionLabel: String
    let actionColor: Color
    let actionTextColor: Color
    let isCrypto: Bool
    let entryText: String        // "Entry ~184.20"
    let stopText: String?        // "stop 178.50"
    let sizeText: String         // sized line OR "Set account to size…"
    let sizeIsWarning: Bool      // true when the sized notional exceeds the account
    let evText: String           // "Est. EV +0.62R (gross)"
    /// Hierarchy lens 2026-07-09: the pre-trade gate verdict for THIS order (pre-formatted
    /// label, e.g. "CAUTION"/"DO NOT TRADE") + its chip color — nil when risk % isn't set
    /// (honest-nil, F04). The most prescriptive card must not hide the app's own verdict.
    var gateLabel: String? = nil
    var gateColor: Color = .clear
    let caveatText: String       // MoneyVelocityCopy.bestOpportunity — the honesty tail
    let varianceText: String?    // crypto-only 24h range line; nil for equities
    /// Round-H: non-nil ⇒ entry/stop/size above are off a stale (prior-UTC-day) cache price —
    /// pre-formatted "⚠︎ Price as of … — not live; re-price before ordering." line, or nil when
    /// the price is live/unknown (HONESTY_FLOOR: unknown never flags stale). Defaulted nil so
    /// any other construction site stays valid without threading it through.
    var staleAsOfText: String? = nil
    let accessibilityText: String
    let onTap: () -> Void
    let onCopy: () -> Void
    var mvFont9: CGFloat = 9
    var mvFont10: CGFloat = 10
    var mvFont11: CGFloat = 11
    var mvFont12: CGFloat = 12
    var mvFont13: CGFloat = 13
    var mvFont15: CGFloat = 15

    private var tint: Color { isCrypto ? DS.Palette.warningSoft : DS.Palette.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: "bolt.fill").font(.system(size: mvFont12)).foregroundStyle(tint)
                        Text("Do this now").font(.system(size: mvFont11, weight: .bold)).foregroundStyle(.white)
                        Spacer()
                        Text(symbol).font(.system(size: mvFont15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        Text(actionLabel).font(.system(size: mvFont10, weight: .bold))
                            .foregroundStyle(actionTextColor)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(actionColor, in: Capsule())
                        if let gateLabel {
                            Text(gateLabel).font(.system(size: mvFont9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(gateColor, in: Capsule())
                                .lineLimit(1).fixedSize()
                        }
                    }
                    HStack(spacing: DS.Space.sm) {
                        Text(entryText).font(.system(size: mvFont13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        if let stopText {
                            Text(stopText).font(.system(size: mvFont13, weight: .semibold, design: .rounded)).foregroundStyle(DS.Palette.dangerSoft)
                        }
                        Spacer(minLength: 0)
                    }
                    // Round-H: entryText/sizeText above are a placeable order — flag it when
                    // off a stale (prior-UTC-day) cache price, same wording as the detail sheet.
                    if let staleAsOfText {
                        Text(staleAsOfText)
                            .font(.system(size: mvFont9)).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(sizeText)
                        .font(.system(size: mvFont9, weight: .medium))
                        .foregroundStyle(sizeIsWarning ? DS.Palette.warningSoft : DS.Palette.successSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(evText).font(.system(size: mvFont12, weight: .bold)).foregroundStyle(DS.Palette.successSoft)
                        Text(caveatText).font(.system(size: mvFont9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let varianceText {
                        Text(varianceText)
                            .font(.system(size: mvFont9, weight: .medium))
                            .foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DS.Space.sm).frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(LuxPressStyle())
            .accessibilityLabel(accessibilityText)
            HStack(spacing: 6) {
                Spacer()
                Button(action: onCopy) {
                    Label("Copy today's plan", systemImage: "checklist").font(.system(size: mvFont9, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(DS.Palette.accent)
                .help("Copy a checklist — best bet, the pre-trade gate verdict, and the size — to the clipboard. Estimates, not advice.")
            }
        }
    }
}


// Concrete improvement: EV badge in ideaCard now has accessibilityLabel (a11y gap fixed, DS tokens used, no hardcoded colors) - line ~2610

// MARK: - Backtest verdict color (significance-gated — AUDIT_FINDINGS_2 #1)

/// The green/red on a backtest metric IS a verdict ("this worked" / "this lost") — painting it
/// on a statistically meaningless sample over-claims. Below the significance bar every verdict
/// metric renders NEUTRAL (the same textSecondary the house uses for "estimate, not a realized
/// gain"), and the existing "treat as illustrative" caption carries the words. Top-level
/// (internal, not nested private) so `Salehman AITests` reaches it via @testable import —
/// the SheetCandidateNavigation testability pattern.
enum BacktestVerdict {
    // DISCLOSED mechanical fix vs the wave-2 plan text: the plan wrote `nonisolated`, but
    // DS.Palette tokens are MainActor-isolated (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor),
    // so the opt-out cannot compile. MainActor (the file default) preserves every pinned
    // behavior; the test target shares the same default isolation.
    static func metricColor(positive: Bool, significant: Bool) -> Color {
        guard significant else { return DS.Palette.textSecondary }
        // dangerSoft, not danger: every caller renders this at ~12.5pt (ideaMetric's value
        // Text) — the wave's own small-danger-TEXT-is-AA invariant applies here too.
        return positive ? DS.Palette.successSoft : DS.Palette.dangerSoft
    }
}

// MARK: - Detail-sheet prev/next candidate navigation (pure index math)

/// Pure resolution for the ideas detail-sheet prev/next stepper. Kept top-level (internal,
/// NOT nested private inside MarketsView) so `Salehman AITests` reaches it via
/// `@testable import StockSage`.
///
/// Board order = `displayedIdeas` (post sort/filter/search) — the SAME order the user sees.
/// The board mutates under background refresh, so callers pass a FRESH `ids` snapshot and
/// re-resolve at press time. nil means "cannot step": unknown id (the shown idea fell off
/// the board) or past either end. No wrap-around — clamping is the contract; the UI
/// disables the chevron.
enum SheetCandidateNavigation {
    /// 0-based index of the neighbor `delta` steps from `currentID` in `ids`, or nil
    /// (unknown id / out of range).
    static func neighborIndex(ids: [String], currentID: String, delta: Int) -> Int? {
        guard let i = ids.firstIndex(of: currentID) else { return nil }
        let j = i + delta
        return ids.indices.contains(j) ? j : nil
    }

    /// 1-based "N of M" position label, or nil when `currentID` is not on the board —
    /// honesty floor: never fabricate a position for an idea the board no longer shows.
    static func positionLabel(ids: [String], currentID: String) -> String? {
        guard let i = ids.firstIndex(of: currentID) else { return nil }
        return "\(i + 1) of \(ids.count)"
    }
}
