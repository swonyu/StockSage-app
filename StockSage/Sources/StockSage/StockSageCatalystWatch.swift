import Foundation

// MARK: - StockSageCatalystWatch
//
// Owner request (2026-09-06): a new tab that shows, for the same ideas as the Ideas tab, the
// KEY catalyst to watch and explains WHY — per-idea catalyst cards plus a date-ordered catalyst
// calendar. This file is the pure brief engine behind that tab (build step C1-engine): it never
// fetches anything itself, it only reads what the store already computed (earnings proximity +
// raw date, the volume-confirmed catalyst detector, the regime gauge, monthly seasonality) and
// turns the single most relevant one into idea-specific, deterministic copy. The "why" here is
// always engine rationale (this file, always present); an OPTIONAL on-device model-written
// paragraph is a later, separate step and is purely additive in the view layer.
//
// PRECEDENCE (first applicable wins as `primary`; every other applicable one becomes
// `secondary`, in this same order — a brief never gets re-sorted by "importance" after the
// fact, so it stays reproducible from its inputs alone):
//   1. earnings, severity .imminent or .soon  — event risk close enough to act on
//   2. a volume-confirmed move, any tier      — something already happened, today
//   3. earnings, severity .clear (known date) — on the calendar, not urgent yet
//   4. price at a recent high/low (StockSageIdea.recentExtreme)
//   5. the regime gauge, when it's risk-off (.crisis/.trendingBear) AND this idea is
//      long-biased — a long idea fighting a risk-off tape is a real tension worth naming
//   6. monthly seasonality, when the current month's stat is reliable and non-trivial
//   7. none of the above — say so honestly rather than inventing a catalyst
//
// Every string a viewer can read lives HERE, never assembled in a view, so a test can pin it
// verbatim (STYLE: "copy is the product"). Nothing here forecasts direction — every kind's copy
// describes what is scheduled or what already happened, per the house honesty floor.
enum StockSageCatalystWatch {

    // MARK: Kind / Weight

    enum Kind: String, Sendable, CaseIterable {
        case earnings, volumeMove, regime, extreme, seasonality, none
    }

    /// Attention weight — how urgently this item deserves a look. NOT a position-size signal.
    enum Weight: Int, Sendable, Comparable {
        case low, medium, high
        nonisolated static func < (lhs: Weight, rhs: Weight) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    // MARK: Item / Brief

    /// One catalyst, fully worded. `date` is set ONLY for a genuinely dated catalyst (earnings)
    /// — every other kind describes what just happened or what's true right now, not a date.
    struct Item: Sendable, Equatable, Identifiable {
        let symbol: String
        let kind: Kind
        let headline: String
        let date: Date?
        /// 1–3 idea-specific bullets — the engine's rationale, always present.
        let why: [String]
        /// What would confirm or invalidate this catalyst.
        let watch: String
        let weight: Weight
        /// Where this reading comes from, so a viewer can judge how much to trust it.
        let source: String
        let caveat: String?
        nonisolated var id: String { symbol + "|" + kind.rawValue }
    }

    /// The one catalyst to watch for an idea, plus every other one that also applied.
    struct Brief: Sendable, Equatable, Identifiable {
        let idea: StockSageIdea
        let primary: Item
        let secondary: [Item]
        nonisolated var id: String { idea.symbol }
        nonisolated var all: [Item] { [primary] + secondary }
    }

    // MARK: Inputs
    //
    // Everything the store already knows about ONE idea, gathered so `brief(for:inputs:)` stays
    // pure (no store access, no I/O). The store keeps a raw `earningsDates` dict and a derived
    // `earnings` proximity dict separately, so the caller forwards both; when only a date is
    // known (`earnings` nil), the engine derives severity itself via `StockSageEarnings`.
    struct Inputs: Sendable {
        let earnings: EarningsProximity?
        let earningsDate: Date?
        /// When the store last ASKED Yahoo calendarEvents for this symbol's earnings date and got
        /// none back (nil = never asked). Feeds the honesty-floor-required dated "none known as of
        /// <date>" record in `noneItem` — never invented, only ever the time we actually checked.
        let earningsCheckedAt: Date?
        let volumeMove: StockSageCatalyst.Signal?
        let regime: MarketRegime?
        let regimeGaugedAt: Date?
        let seasonality: MonthlySeasonality?
        let now: Date

        init(earnings: EarningsProximity? = nil, earningsDate: Date? = nil, earningsCheckedAt: Date? = nil,
             volumeMove: StockSageCatalyst.Signal? = nil, regime: MarketRegime? = nil,
             regimeGaugedAt: Date? = nil, seasonality: MonthlySeasonality? = nil, now: Date) {
            self.earnings = earnings; self.earningsDate = earningsDate; self.earningsCheckedAt = earningsCheckedAt
            self.volumeMove = volumeMove; self.regime = regime
            self.regimeGaugedAt = regimeGaugedAt; self.seasonality = seasonality; self.now = now
        }
    }

    /// English month names, fixed — never the viewer's locale (a French/Arabic device must not
    /// change what a pinned test string reads).
    private nonisolated static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// Fixed-locale, fixed-timezone (UTC) date formatting — every date string this file (and the
    /// view, which calls this too) renders MUST use this, never the viewer's local time zone.
    /// `bucket(for:)` below buckets a date's "today/tomorrow/this week" by UTC calendar day, so a
    /// headline formatted in local time can read "7 Sep" under a "Today" bucket that was decided
    /// against UTC's "6 Sep" (fix pass 2026-09-06: a Riyadh, UTC+3, viewer saw exactly this for an
    /// after-close US earnings timestamp). One shared style keeps bucketing and display in sync,
    /// and keeps the string locale-independent for pinned tests (mirrors `monthNames` above).
    private nonisolated static let dateFormatStyle = Date.FormatStyle(
        date: .abbreviated, time: .omitted,
        locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!)

    nonisolated static func dateStr(_ date: Date) -> String { date.formatted(dateFormatStyle) }

    nonisolated static let caveat =
        "Rules-based: earnings dates from Yahoo, volume moves from cached history, the regime "
        + "gauge and multi-year monthly seasonality. Describes what is scheduled or just happened "
        + "— never what happens next. Educational, not financial advice."

    // MARK: brief(for:inputs:)

    nonisolated static func brief(for idea: StockSageIdea, inputs: Inputs) -> Brief {
        var earningsSlot1: Item?
        var earningsSlot3: Item?
        // Guard mirrors the store's own F32 eviction boundary (StockSageStore.deriveEarningsProximity):
        // a date more than 24h in the past is a report that already happened, not a catalyst to
        // watch. Without this guard, once the store's DERIVED `earnings` dict evicts a stale date
        // (F32), this engine falls back to the raw, never-pruned `earningsDates` and re-derives via
        // `StockSageEarnings.proximity`, whose `max(0, days)` floor turns "3 days ago" back into
        // "0 days" / `.imminent` — resurrecting exactly the bug F32 fixed (fix pass 2026-09-06).
        if let date = inputs.earningsDate, date.timeIntervalSince(inputs.now) >= -86_400 {
            let daysUntil = inputs.earnings?.daysUntil
                ?? StockSageEarnings.proximity(now: inputs.now, earnings: date).daysUntil
            let severity = inputs.earnings?.severity ?? StockSageEarnings.severity(daysUntil: daysUntil)
            let item = earningsItem(idea: idea, date: date, daysUntil: daysUntil, severity: severity)
            switch severity {
            case .imminent, .soon: earningsSlot1 = item
            case .clear:           earningsSlot3 = item
            }
        }

        let volumeSlot = inputs.volumeMove.map { volumeMoveItem(idea: idea, signal: $0) }

        let extremeSlot: Item? = {
            // `SparkSeries.Extreme` has no raw value, so its synthesized Equatable conformance is
            // MainActor-isolated under this module's default isolation — switch/pattern-match
            // instead of `==` so this stays callable from a nonisolated context.
            guard let extreme = idea.recentExtreme else { return nil }
            switch extreme {
            case .atHigh, .atLow: return extremeItem(idea: idea, extreme: extreme)
            case .neither:        return nil
            }
        }()

        let regimeSlot: Item? = {
            guard let regime = inputs.regime,
                  regime.state == .crisis || regime.state == .trendingBear else { return nil }
            let action = idea.advice.action
            guard action == .buy || action == .strongBuy || action == .hold else { return nil }
            return regimeItem(idea: idea, regime: regime, gaugedAt: inputs.regimeGaugedAt)
        }()

        let seasonalitySlot: Item? = {
            guard let seasonality = inputs.seasonality else { return nil }
            let month = StockSageSeasonality.currentMonth(asOf: inputs.now)
            guard let stat = StockSageSeasonality.stat(seasonality, month: month),
                  stat.isReliable, abs(stat.avgReturn) >= 0.01 else { return nil }
            return seasonalityItem(idea: idea, month: month, stat: stat)
        }()

        let candidates = [earningsSlot1, volumeSlot, earningsSlot3, extremeSlot, regimeSlot, seasonalitySlot]
            .compactMap { $0 }
        guard let primary = candidates.first else {
            return Brief(idea: idea, primary: noneItem(idea: idea, checkedAt: inputs.earningsCheckedAt), secondary: [])
        }
        return Brief(idea: idea, primary: primary, secondary: Array(candidates.dropFirst()))
    }

    // MARK: Per-kind copy — every string lives here so a test can pin it verbatim.

    private nonisolated static func earningsItem(idea: StockSageIdea, date: Date, daysUntil: Int,
                                                 severity: EarningsProximity.Severity) -> Item {
        let dateStr = Self.dateStr(date)
        let headline = "Earnings in ~\(daysUntil) day\(daysUntil == 1 ? "" : "s") (\(dateStr))"
        let action = idea.advice.action
        let isLongBiased = action == .buy || action == .strongBuy || action == .hold
        let stop = idea.advice.stopPrice
        var why: [String] = []
        if isLongBiased {
            if let stop {
                let pct = (stop - idea.price) / idea.price * 100
                why.append(
                    "A protective stop is an intraday promise — an earnings gap can open straight "
                    + "through the stop at \(StockSageCurrency.adaptivePrice(stop)) "
                    + "(\(String(format: "%.1f%%", pct)) from \(StockSageCurrency.adaptivePrice(idea.price))), "
                    + "so the risk sized at entry is not the risk held through the report.")
                if let target = idea.advice.targetPrice {
                    why.append(
                        "Stop \(StockSageCurrency.adaptivePrice(stop)) and target "
                        + "\(StockSageCurrency.adaptivePrice(target)) are fixed levels; after the print, "
                        + "re-check reward:risk at the new price.")
                }
            } else {
                why.append("No stop is attached to this idea, so an overnight gap has no defined exit — size for that or wait.")
            }
        } else {
            why.append("A report can reverse a weak tape as easily as extend it; the \(action.rawValue) read describes the trend, not the print.")
        }
        let watch = (isLongBiased && stop != nil)
            ? "Before \(dateStr): decide to hold through with reduced size or step aside. After: does the first close respect the stop?"
            : "Before \(dateStr): decide to hold through with reduced size or step aside. After: read the first close for direction — there is no stop level to test it against."
        let weight: Weight
        switch severity {
        case .imminent: weight = .high
        case .soon:     weight = .medium
        case .clear:    weight = .low
        }
        return Item(symbol: idea.symbol, kind: .earnings, headline: headline, date: date, why: why,
                   watch: watch, weight: weight, source: "Yahoo calendarEvents", caveat: nil)
    }

    private nonisolated static func volumeMoveItem(idea: StockSageIdea, signal: StockSageCatalyst.Signal) -> Item {
        let headline = "\(String(format: "%.1f", signal.rvol))× volume, "
            + "\(String(format: "%+.1f%%", signal.priceChangePct)) on the latest cached bar — "
            + "\(signal.tier.rawValue.capitalized)"
        var why = ["Order flow confirmed that something happened; the direction is a description, not a forecast — the same spike marks a takeover and a collapse."]
        if signal.likelyMechanicalFlow {
            why.append("Average dollar volume is large enough that this may be passive/index flow rather than information.")
        }
        let watch = idea.advice.stopPrice != nil
            ? "Follow-through next session versus a reversal; a close through the stop invalidates the idea, not the catalyst."
            : "Follow-through next session versus a reversal."
        let weight: Weight
        switch signal.tier {
        case .major:       weight = .high
        case .significant: weight = .medium
        case .notable:     weight = .low
        }
        return Item(symbol: idea.symbol, kind: .volumeMove, headline: headline, date: nil, why: why,
                   watch: watch, weight: weight, source: "on-disk history (latest bar)", caveat: StockSageCatalyst.caveat)
    }

    private nonisolated static func extremeItem(idea: StockSageIdea, extreme: SparkSeries.Extreme) -> Item {
        let spanPart = idea.recentExtremeSpan.map { "\($0)-day" } ?? "recent"
        var why = ["Price sits at the edge of its recent range."]
        if let q = idea.momentumQuality {
            why.append("Short-horizon momentum quality \(String(format: "%.2f", q))/1 — a read on how hot the move is, not a probability.")
        }
        // Structural switch, not `==` — see the note at the `extremeSlot` call site.
        let label: String
        let watch: String
        switch extreme {
        case .atHigh:
            label = "high"
            watch = "A new high extends the setup; a close back inside the range, or through the stop, ends it."
        default:
            label = "low"
            watch = "A new low extends the setup; a close back inside the range, or through the stop, ends it."
        }
        return Item(symbol: idea.symbol, kind: .extreme, headline: "At the \(spanPart) \(label)",
                   date: nil, why: why, watch: watch, weight: .medium, source: "1-year history", caveat: nil)
    }

    private nonisolated static func regimeItem(idea: StockSageIdea, regime: MarketRegime, gaugedAt: Date?) -> Item {
        let why = ["A board-wide risk gauge, not a read on this name: it biases size ×\(String(format: "%.2f", regime.sizingBias)); it does not predict direction."]
        let gaugedStr = gaugedAt.map { Self.dateStr($0) } ?? "not yet"
        let watch = "A change in the gauge (last read \(gaugedStr)) changes the size, not the idea."
        let weight: Weight = regime.state == .crisis ? .high : (regime.state == .trendingBear ? .medium : .low)
        return Item(symbol: idea.symbol, kind: .regime, headline: regime.state.rawValue, date: nil, why: why,
                   watch: watch, weight: weight, source: "regime gauge", caveat: regime.caveat)
    }

    private nonisolated static func seasonalityItem(idea: StockSageIdea, month: Int, stat: MonthlySeasonality.MonthStat) -> Item {
        let name = monthNames[month - 1]
        let headline = "\(name) tendency \(String(format: "%+.1f%%", stat.avgReturn * 100)) (n=\(stat.samples))"
        return Item(symbol: idea.symbol, kind: .seasonality, headline: headline, date: nil,
                   why: [stat.note(monthName: name)],
                   watch: "A weak, backward-looking tilt; do not size on it.", weight: .low,
                   source: "1-year+ history", caveat: "Not a forecast.")
    }

    /// Two honest shapes, never a middle ground: `checkedAt == nil` means this symbol was never
    /// asked yet, so the copy says exactly that; `checkedAt` present means Yahoo calendarEvents
    /// WAS asked (at that instant) and returned nothing, so it becomes a real, DATED record
    /// (`date: checkedAt`, never `Date()`) — a negative result, not an absence of information.
    private nonisolated static func noneItem(idea: StockSageIdea, checkedAt: Date?) -> Item {
        guard let checkedAt else {
            return Item(symbol: idea.symbol, kind: .none, headline: "No dated catalyst on file", date: nil,
                why: ["Next earnings date not available for this name — not fetched yet, or the source declined.",
                      "No volume-confirmed move on the latest cached bar."],
                watch: "Re-check after the next full refresh.", weight: .low, source: "—", caveat: nil)
        }
        return Item(symbol: idea.symbol, kind: .none,
            headline: "No known catalyst as of \(Self.dateStr(checkedAt))", date: checkedAt,
            why: ["Next earnings date requested from Yahoo calendarEvents — none returned"],
            watch: "Re-check after the next full refresh.", weight: .low,
            source: "Yahoo calendarEvents (no date returned)", caveat: nil)
    }

    // MARK: - Catalyst calendar

    enum Bucket: String, CaseIterable, Sendable {
        case today, tomorrow, thisWeek, later, undated
        /// A dated "none known as of <checkedAt>" negative record — major fix 2026-09-06.
        /// `checkedAt` is WHEN WE ASKED, not an event date, so it must never share `.today` (or
        /// any real-event bucket) with an actual catalyst: since `checkedAt` ≈ now for every
        /// freshly-swept symbol, `refreshEarningsForTracked`'s ~901-name daily sweep used to
        /// flood `.today` with negative records that sorted (ascending date) AHEAD of every real
        /// catalyst due today. Ordered last in `allCases` so it always renders as its own
        /// trailing section, never interleaved with the real-event buckets above it.
        case checkedNoCatalyst
        nonisolated var title: String {
            switch self {
            case .today:             return "Today"
            case .tomorrow:          return "Tomorrow"
            case .thisWeek:          return "This week"
            case .later:             return "Later"
            case .undated:           return "No date on file"
            case .checkedNoCatalyst: return "Checked — no catalyst"
            }
        }
    }

    struct CalendarEntry: Sendable, Equatable, Identifiable {
        let bucket: Bucket
        let item: Item
        let idea: StockSageIdea
        /// True only for a dated "none known as of <date>" record (`item.kind == .none`) — pure
        /// data so the view can style it apart from a real catalyst without re-deriving `kind`.
        let isNegativeRecord: Bool
        nonisolated var id: String { item.id }
    }

    /// UTC gregorian — bucketing must not shift with the viewer's time zone (a trader in Tokyo
    /// and one in New York should see the same "today"/"tomorrow" split for the same date).
    private nonisolated static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private nonisolated static func bucket(for date: Date, now: Date, calendar: Calendar) -> Bucket {
        let startNow = calendar.startOfDay(for: now)
        let startDate = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startNow, to: startDate).day ?? 0
        switch days {
        case ..<1:  return .today
        case 1:     return .tomorrow
        case 2...7: return .thisWeek
        default:    return .later
        }
    }

    /// Every DATED item of every brief, earliest first (ties broken by symbol) and bucketed vs
    /// `now`; then each brief's UNDATED primary — when it's an actual catalyst, not `.none` —
    /// at the end, strongest weight first. Two passes over `briefs`, never re-sorted after —
    /// deterministic for the same input every time.
    nonisolated static func calendar(_ briefs: [Brief], now: Date, calendar: Calendar = utcCalendar) -> [CalendarEntry] {
        var dated: [(date: Date, entry: CalendarEntry)] = []
        var undated: [(weight: Weight, entry: CalendarEntry)] = []
        for brief in briefs {
            // A dated "none known as of <date>" record (checkedAt set) IS a real, dated entry —
            // included below — but its date is WHEN WE ASKED, not an event, so it routes to the
            // dedicated `.checkedNoCatalyst` bucket instead of `bucket(for:)`'s real-event
            // buckets (major fix 2026-09-06). Only an UNDATED `.none` (below) is excluded
            // entirely, since it says nothing was ever checked.
            for item in brief.all {
                if let date = item.date {
                    let isNegative = item.kind == .none
                    let b = isNegative ? Bucket.checkedNoCatalyst : bucket(for: date, now: now, calendar: calendar)
                    dated.append((date, CalendarEntry(bucket: b, item: item, idea: brief.idea, isNegativeRecord: isNegative)))
                }
            }
            if brief.primary.date == nil, brief.primary.kind != .none {
                undated.append((brief.primary.weight,
                                CalendarEntry(bucket: .undated, item: brief.primary, idea: brief.idea, isNegativeRecord: false)))
            }
        }
        dated.sort { $0.date != $1.date ? $0.date < $1.date : $0.entry.item.symbol < $1.entry.item.symbol }
        undated.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.entry.item.symbol < $1.entry.item.symbol }
        return dated.map(\.entry) + undated.map(\.entry)
    }
}
