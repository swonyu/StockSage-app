import Foundation

/// Descriptive completed-minute context only; no setup gate, price forecast, breadth or VWAP claim.
nonisolated enum StockSageMomentum {
    static let durations = [1, 5, 15]
    static let maximumAge: TimeInterval = 180
    typealias Minute = StockSageMassiveTicks.Minute
    typealias Intraday = StockSageMassiveTicks.Intraday

    enum Status: String, Codable, Sendable, Equatable {
        case available, unavailable, unverified, stale, gap
    }
    struct Window: Codable, Sendable, Equatable, Identifiable {
        let minutes: Int
        let start: Date?
        let end: Date?
        let startClose: Double?
        let endClose: Double?
        /// Percentage, not fraction: one percent is 1.0.
        let percent: Double?
        let status: Status
        let note: String
        let sessionLabel: String
        var id: Int { minutes }
    }
    struct Series: Codable, Sendable, Equatable {
        let symbol: String
        let capturedAt: Date
        let asOf: Date?
        let bars: [Minute]
        let verifiedMinutes: Bool
        let status: Status
        let note: String
        let sessionLabel: String
        let returns: [Window]
    }
    struct Relative: Codable, Sendable, Equatable, Identifiable {
        let minutes: Int
        let proxySymbol: String
        let start: Date?
        let end: Date?
        let stockPercent: Double?
        let proxyPercent: Double?
        let differencePercentagePoints: Double?
        let status: Status
        let note: String
        let sessionLabel: String
        var id: Int { minutes }
    }
    struct VolumeAcceleration: Codable, Sendable, Equatable {
        let start: Date?
        let end: Date?
        let latestFiveMinuteVolume: Double?
        let precedingFiveMinuteVolumes: [Double]
        let meanPrecedingVolume: Double?
        let multiple: Double?
        let status: Status
        let note: String
    }
    enum Direction: String, Codable, Sendable, Equatable { case rising, falling }
    struct Trigger: Codable, Sendable, Equatable {
        let symbol: String
        let direction: Direction
        let returnFraction: Double
        let volumeMultiple: Double
        /// End of the latest completed minute, not the request/capture time.
        let at: Date
        let profile: StockSageMicrocapScreen.Profile
        let start: Date
        let startClose: Double
        let endClose: Double
        var facts: [StockSageAIAssessment.EvidenceFact] {
            [StockSageMomentum.fact(key: "technical.momentum.heavy", text:
                "Descriptive \(profile.rawValue) heavy-momentum alert for \(symbol): \(direction.rawValue), five-minute close change \(StockSageMomentum.number(returnFraction * 100)) percent from \(startClose) USD at \(start.ISO8601Format()) to \(endClose) USD at \(at.ISO8601Format()); latest five-minute share volume is \(StockSageMomentum.number(volumeMultiple)) times the mean of the preceding three nonoverlapping five-minute windows. All twenty completed minutes had positive reported volume. Unvalidated alert defaults: absolute five-minute change at least \(profile == .microcap ? "three" : "one") percent and volume multiple at least three. These are dated candle references, not live quotes, an entry/stop/target, institutional participation or a qualified Buy.",
                status: .available, at: at)]
        }
    }
    struct Market: Codable, Sendable, Equatable {
        let capturedAt: Date
        let spy: Series
        let qqq: Series
        let note: String
        var sessionLabel: String { StockSageMomentum.sessionLabel(at: capturedAt) }
        var facts: [StockSageAIAssessment.EvidenceFact] {
            [StockSageMomentum.fact(key: "technical.momentum.market.coverage", text: note,
                status: .available, at: capturedAt)] + [spy, qqq].map {
                    StockSageMomentum.seriesFact($0, key: "technical.momentum.market.\($0.symbol)")
                }
        }
        /// Recheck an older scan-wide capture at the moment it is offered to an assessment.
        func facts(at now: Date) -> [StockSageAIAssessment.EvidenceFact] {
            let checked = [("SPY", spy), ("QQQ", qqq)].map { expected, value -> Series in
                let input = value.asOf.map { Intraday(facts: [], asOf: $0, bars: value.bars, verifiedMinutes: value.verifiedMinutes) }
                let consistent = StockSageMomentum.validDate(capturedAt) && capturedAt <= now && value.capturedAt == capturedAt
                    && value.symbol == expected
                let result = StockSageMomentum.series(symbol: expected, intraday: consistent ? input : nil, now: now,
                    reason: "Original market capture provenance is unavailable or inconsistent.")
                return Series(symbol: result.symbol, capturedAt: value.capturedAt, asOf: result.asOf,
                    bars: result.bars, verifiedMinutes: result.verifiedMinutes, status: result.status,
                    note: result.note + " Age rechecked at \(StockSageMomentum.safeDate(now).ISO8601Format()); original capture time is unchanged.",
                    sessionLabel: result.sessionLabel, returns: result.returns)
            }
            return [StockSageMomentum.fact(key: "technical.momentum.market.coverage", text: note,
                status: .available, at: capturedAt)] + checked.map {
                    StockSageMomentum.seriesFact($0, key: "technical.momentum.market.\($0.symbol)")
                }
        }
    }
    struct Stock: Codable, Sendable, Equatable {
        let symbol: String
        let capturedAt: Date
        let series: Series
        let volumeAcceleration: VolumeAcceleration
        let vsSPY: [Relative]
        let vsQQQ: [Relative]
        var facts: [StockSageAIAssessment.EvidenceFact] {
            [StockSageMomentum.seriesFact(series, key: "technical.momentum.stock"),
             StockSageMomentum.fact(key: "technical.momentum.volume", text: "\(symbol) completed-minute volume acceleration: \(volumeAcceleration.note)",
                  status: volumeAcceleration.status, at: volumeAcceleration.end)]
                + [vsSPY, vsQQQ].map { windows in
                    let proxy = windows.first?.proxySymbol ?? "unknown"
                    let lines = windows.map { value in
                        guard let stock = value.stockPercent, let reference = value.proxyPercent,
                              let difference = value.differencePercentagePoints,
                              let start = value.start, let end = value.end else {
                            return "\(value.minutes)-minute relative return unavailable: \(value.note)"
                        }
                        return "\(value.minutes)-minute exact close boundaries \(start.ISO8601Format()) to \(end.ISO8601Format()), \(value.sessionLabel): stock \(StockSageMomentum.number(stock)) percent, \(proxy) \(StockSageMomentum.number(reference)) percent, difference \(StockSageMomentum.number(difference)) percentage points."
                    }
                    return StockSageMomentum.fact(key: "technical.momentum.relative.\(proxy)",
                        text: "\(symbol) versus \(proxy), captured \(capturedAt.ISO8601Format()). " + lines.joined(separator: " ")
                            + " Relative change is descriptive, not alpha, a trade signal or entire-market breadth.",
                        status: windows.contains { $0.status == .available } ? .available : .unavailable,
                        at: windows.compactMap(\.end).max())
                }
        }
        /// Recompute age/aligned intervals without collecting or renewing the original stock capture.
        func facts(at now: Date, market: Market) -> [StockSageAIAssessment.EvidenceFact] {
            let consistent = StockSageMomentum.validDate(capturedAt) && capturedAt <= now
                && series.capturedAt == capturedAt && series.symbol == symbol
            let input = series.asOf.map {
                Intraday(facts: [], asOf: $0, bars: series.bars, verifiedMinutes: series.verifiedMinutes)
            }
            let checked = StockSageMomentum.stock(symbol: symbol, intraday: consistent ? input : nil,
                                                   market: market, now: now)
            let originalClock = Series(symbol: checked.series.symbol, capturedAt: capturedAt,
                asOf: checked.series.asOf, bars: checked.series.bars,
                verifiedMinutes: checked.series.verifiedMinutes, status: checked.series.status,
                note: checked.series.note + " Age rechecked at \(StockSageMomentum.safeDate(now).ISO8601Format()); original capture time is unchanged.",
                sessionLabel: checked.series.sessionLabel, returns: checked.series.returns)
            return Stock(symbol: symbol, capturedAt: capturedAt, series: originalClock,
                volumeAcceleration: checked.volumeAcceleration, vsSPY: checked.vsSPY, vsQQQ: checked.vsQQQ).facts
        }
        func heavyMomentum(profile: StockSageMicrocapScreen.Profile, now: Date = Date()) -> Trigger? {
            guard StockSageMomentum.validDate(capturedAt), capturedAt <= now, series.capturedAt == capturedAt, series.symbol == symbol,
                  let end = series.asOf, series.verifiedMinutes else { return nil }
            let checked = StockSageMomentum.series(symbol: symbol,
                intraday: .init(facts: [], asOf: end, bars: series.bars, verifiedMinutes: true), now: now)
            let volume = StockSageMomentum.volume(checked)
            guard let change = checked.returns.first(where: { $0.minutes == 5 }),
                  let percent = change.percent, let start = change.start, let at = change.end,
                  let first = change.startClose, let last = change.endClose,
                  let multiple = volume.multiple, volume.status == .available, multiple >= 3,
                  abs(percent) >= (profile == .microcap ? 3 : 1) else { return nil }
            return .init(symbol: symbol, direction: percent > 0 ? .rising : .falling,
                returnFraction: percent / 100, volumeMultiple: multiple, at: at, profile: profile,
                start: start, startClose: first, endClose: last)
        }
    }

    /// One proxy pair per caller-owned refresh. Preserves the original access generation in children.
    @MainActor static func collect(now: Date, access: StockSageMassive.Access = .init(),
                        transport: StockSageMassive.Transport? = nil,
                        clock: @MainActor () -> Date = Date.init) async -> Market {
        let captured = access.capture()
        guard validDate(now), !captured.key.isEmpty, captured.isCurrent() else {
            return market(spy: nil, qqq: nil, now: safeDate(now), reason: "Momentum unavailable: access is disabled, credentials are missing or work was cancelled.")
        }
        let fixed = StockSageMassive.Access(key: { captured.key }, credentialRevision: { nil },
            policyRevision: { nil }, allowed: captured.isCurrent)
        async let spy = intraday(symbol: "SPY", now: now, access: fixed, transport: transport)
        async let qqq = intraday(symbol: "QQQ", now: now, access: fixed, transport: transport)
        let (s, q) = await (spy, qqq)
        let finished = clock()
        guard captured.isCurrent(), validDate(finished), finished >= now else {
            return market(spy: nil, qqq: nil, now: safeDate(finished), reason: "Momentum unavailable: access changed, capture clock was invalid or work was cancelled; proxy responses were discarded.")
        }
        return market(spy: s, qqq: q, now: finished)
    }

    /// Candle-only adapter for watcher-owned stock refreshes; no trade/condition fallback requests.
    static func intraday(symbol: String, now: Date, access: StockSageMassive.Access,
                         transport: StockSageMassive.Transport? = nil) async -> Intraday? {
        let captured = access.capture()
        guard validDate(now), sessionBounds(at: now) != nil, StockSageMassive.covers(symbol),
              !captured.key.isEmpty, captured.isCurrent() else { return nil }
        let fixed = StockSageMassive.Access(key: { captured.key }, credentialRevision: { nil },
            policyRevision: { nil }, allowed: captured.isCurrent)
        let prefix = "/v2/aggs/ticker/\(symbol)/range/1/minute/"
        let minuteOnly: StockSageMassive.Transport = { request in
            guard captured.isCurrent(), request.url?.host == "api.massive.com",
                  request.url?.path.hasPrefix(prefix) == true else { throw URLError(.unsupportedURL) }
            let response = try await StockSageMassive.response(for: request,
                maximumBytes: StockSageMassiveTicks.maximumBytes, transport: transport)
            guard captured.isCurrent() else { throw CancellationError() }
            return (response.0, response.1)
        }
        let value = await StockSageMassiveTicks.intradayFacts(symbol: symbol,
            from: now.addingTimeInterval(-3600), now: now, access: fixed, transport: minuteOnly)
        return captured.isCurrent() ? value : nil
    }

    /// Pure capture seam, also used for saved synthetic/native fixtures.
    static func market(spy: Intraday?, qqq: Intraday?, now: Date, reason: String? = nil) -> Market {
        .init(capturedAt: safeDate(now), spy: series(symbol: "SPY", intraday: spy, now: now, reason: reason),
              qqq: series(symbol: "QQQ", intraday: qqq, now: now, reason: reason),
              note: (reason.map { $0 + " " } ?? "") + "SPY and QQQ are ETF price proxies, not entire-market breadth. Returns use completed split-adjusted one-minute closes only, not live prices, executable quotes or VWAP. Pre-market/regular/post-market context is labeled; a scheduled session is not proof of continuous trading. Missing, stale or interrupted intervals are unavailable, never zero.")
    }

    static func stock(symbol: String, intraday: Intraday?, market: Market, now: Date) -> Stock {
        let value = series(symbol: symbol, intraday: intraday, now: now)
        return .init(symbol: symbol, capturedAt: safeDate(now), series: value, volumeAcceleration: volume(value),
            vsSPY: relative(stock: value, proxy: market.spy, expected: "SPY", marketAt: market.capturedAt, now: now),
            vsQQQ: relative(stock: value, proxy: market.qqq, expected: "QQQ", marketAt: market.capturedAt, now: now))
    }

    private static func volume(_ series: Series) -> VolumeAcceleration {
        func unavailable(_ note: String) -> VolumeAcceleration {
            .init(start: nil, end: series.asOf, latestFiveMinuteVolume: nil, precedingFiveMinuteVolumes: [],
                meanPrecedingVolume: nil, multiple: nil, status: .unavailable, note: note)
        }
        guard series.verifiedMinutes, let end = series.asOf, series.bars.count >= 20 else {
            return unavailable("Twenty verified consecutive completed positive-volume minutes are required; no estimate or zero was substituted.")
        }
        let bars = Array(series.bars.suffix(20)), start = end.addingTimeInterval(-1200)
        guard bars.enumerated().allSatisfy({ index, bar in
            bar.at == start.addingTimeInterval(Double(index) * 60) && bar.volume.isFinite && bar.volume > 0
        }) else { return unavailable("A gap or zero-volume minute prevents the twenty-minute volume comparison.") }
        let sums = (0..<4).map { block in bars[(block * 5)..<(block * 5 + 5)].reduce(0) { $0 + $1.volume } }
        let mean = (sums[0] + sums[1] + sums[2]) / 3
        guard sums.allSatisfy(\.isFinite), mean.isFinite, mean > 0, (sums[3] / mean).isFinite else {
            return unavailable("Volume arithmetic is not finite or its baseline is not positive.")
        }
        let multiple = sums[3] / mean
        return .init(start: start, end: end, latestFiveMinuteVolume: sums[3], precedingFiveMinuteVolumes: Array(sums.prefix(3)),
            meanPrecedingVolume: mean, multiple: multiple, status: .available,
            note: "Window \(start.ISO8601Format()) to \(end.ISO8601Format()): latest five minutes \(sums[3]) shares; preceding three nonoverlapping five-minute totals \(sums[0]), \(sums[1]), \(sums[2]) shares, mean \(mean); ratio \(number(multiple)) times. Not time-matched daily RVOL or unique shares traded.")
    }

    private static func series(symbol: String, intraday: Intraday?, now: Date, reason: String? = nil) -> Series {
        func unavailable(_ status: Status, _ note: String, asOf: Date? = nil) -> Series {
            .init(symbol: symbol, capturedAt: safeDate(now), asOf: asOf.flatMap { validDate($0) ? $0 : nil },
                bars: [], verifiedMinutes: false, status: status, note: note, sessionLabel: sessionLabel(at: now),
                returns: durations.map { empty($0, status: status, note: note) })
        }
        guard validDate(now), StockSageHorizonResearch.validTicker(symbol), let bounds = sessionBounds(at: now) else {
            return unavailable(.unavailable, "No supported same-date trading session or valid capture clock.")
        }
        guard let intraday else { return unavailable(.unavailable, reason ?? "Verified completed minute candles were not supplied.") }
        guard intraday.verifiedMinutes else {
            return unavailable(.unverified, "Unverified candles or individual-trade fallback cannot establish minute momentum.", asOf: intraday.asOf)
        }
        guard validDate(intraday.asOf), intraday.asOf <= now,
              intraday.maximumAge.isFinite, intraday.maximumAge > 0,
              (2...200).contains(intraday.bars.count) else {
            return unavailable(.unverified, "Minute capture boundaries or verification metadata are invalid.")
        }
        guard now.timeIntervalSince(intraday.asOf) <= min(maximumAge, intraday.maximumAge) else {
            return unavailable(.stale, "Completed minute snapshot is older than the allowed age (at most 180 seconds).", asOf: intraday.asOf)
        }
        let bars = intraday.bars
        for index in bars.indices {
            let bar = bars[index], t = bar.at.timeIntervalSince1970
            guard validDate(bar.at), t.truncatingRemainder(dividingBy: 60) == 0,
                  index == 0 || bars[index - 1].at < bar.at,
                  bar.at >= bounds.open, bar.at.addingTimeInterval(60) <= bounds.close,
                  bar.at.addingTimeInterval(60) <= now,
                  [bar.open, bar.high, bar.low, bar.close].allSatisfy({ $0.isFinite && $0 > 0 }),
                  bar.low <= min(bar.open, bar.close), bar.high >= max(bar.open, bar.close),
                  bar.volume.isFinite, bar.volume >= 0 else {
                return unavailable(.unverified, "Minutes are unsorted, duplicated, malformed, incomplete or outside the same New York session date.")
            }
        }
        guard bars.last?.at.addingTimeInterval(60) == intraday.asOf else {
            return unavailable(.unverified, "The claimed observation time does not equal the last completed-minute boundary.")
        }
        let bounded = bars.filter { $0.at >= now.addingTimeInterval(-3600) }
        let windows = durations.map { window($0, bars: bounded, end: intraday.asOf) }
        let status: Status = windows.contains { $0.status == .available } ? .available : .gap
        let note = "\(bounded.count) verified candles in the bounded last hour. Only intervals with every required positive-volume minute have returns."
        return .init(symbol: symbol, capturedAt: now, asOf: intraday.asOf, bars: bounded,
            verifiedMinutes: true, status: status, note: note,
            sessionLabel: sessionLabel(at: intraday.asOf.addingTimeInterval(-1)), returns: windows)
    }

    private static func window(_ minutes: Int, bars: [Minute], end: Date) -> Window {
        let start = end.addingTimeInterval(-Double(minutes) * 60)
        let expectedStart = start.addingTimeInterval(-60)
        let values = bars.filter { $0.at >= expectedStart && $0.at < end }
        guard values.count == minutes + 1, values.first?.at == expectedStart,
              values.last?.at.addingTimeInterval(60) == end,
              values.enumerated().allSatisfy({ offset, bar in
                  bar.at == expectedStart.addingTimeInterval(Double(offset) * 60) && bar.volume > 0
              }), let first = values.first, let last = values.last else {
            return empty(minutes, status: .gap, note: "Exact endpoint candles and every intervening positive-volume minute are required.", start: start, end: end)
        }
        let percent = (last.close / first.close - 1) * 100
        guard percent.isFinite else { return empty(minutes, status: .unverified, note: "Return arithmetic is not finite.", start: start, end: end) }
        return .init(minutes: minutes, start: start, end: end, startClose: first.close, endClose: last.close,
            percent: percent, status: .available, note: "Close-to-close change; prices are not executable fills.",
            sessionLabel: intervalSession(start: start, end: end))
    }

    private static func relative(stock: Series, proxy: Series, expected: String, marketAt: Date, now: Date) -> [Relative] {
        func unavailable(_ note: String, status: Status = .unavailable) -> [Relative] {
            durations.map { .init(minutes: $0, proxySymbol: expected, start: nil, end: nil,
                stockPercent: nil, proxyPercent: nil, differencePercentagePoints: nil,
                status: status, note: note, sessionLabel: "Unavailable") }
        }
        guard validDate(marketAt), marketAt <= now, validDate(proxy.capturedAt), proxy.capturedAt == marketAt,
              proxy.symbol == expected, proxy.verifiedMinutes, let proxyEnd = proxy.asOf,
              stock.verifiedMinutes, let stockEnd = stock.asOf else {
            return unavailable("Verified matching stock/proxy captures are unavailable.")
        }
        // Revalidate saved proxy inputs at the stock's assessment clock; never renew old observations.
        let checked = series(symbol: expected,
            intraday: .init(facts: [], asOf: proxyEnd, bars: proxy.bars, verifiedMinutes: true), now: now)
        guard checked.verifiedMinutes else { return unavailable(checked.note, status: checked.status) }
        let proxyTimes = Set(checked.bars.map { $0.at.addingTimeInterval(60) })
        guard let commonEnd = stock.bars.map({ $0.at.addingTimeInterval(60) })
            .filter({ $0 <= min(stockEnd, proxyEnd) && proxyTimes.contains($0) }).max(),
            (0...maximumAge).contains(now.timeIntervalSince(commonEnd)) else {
            return unavailable("No exact shared completed-minute end boundary within 180 seconds.", status: .stale)
        }
        return durations.map { minutes in
            let a = window(minutes, bars: stock.bars, end: commonEnd)
            let b = window(minutes, bars: checked.bars, end: commonEnd)
            guard a.start == b.start, a.end == b.end, let x = a.percent, let y = b.percent, (x - y).isFinite else {
                return .init(minutes: minutes, proxySymbol: expected, start: a.start, end: commonEnd,
                    stockPercent: nil, proxyPercent: nil, differencePercentagePoints: nil, status: .gap,
                    note: "Stock and proxy both need complete positive-volume coverage on exactly the same interval.",
                    sessionLabel: a.sessionLabel)
            }
            return .init(minutes: minutes, proxySymbol: expected, start: a.start, end: commonEnd,
                stockPercent: x, proxyPercent: y, differencePercentagePoints: x - y, status: .available,
                note: "Stock percentage change minus ETF percentage change on identical boundaries; not a breadth measure.",
                sessionLabel: a.sessionLabel)
        }
    }

    private static func empty(_ minutes: Int, status: Status, note: String, start: Date? = nil, end: Date? = nil) -> Window {
        .init(minutes: minutes, start: start, end: end, startClose: nil, endClose: nil, percent: nil,
            status: status, note: note, sessionLabel: start.flatMap { s in end.map { intervalSession(start: s, end: $0) } } ?? "Unavailable")
    }
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "America/New_York")!; return value
    }
    private static func sessionBounds(at now: Date) -> (open: Date, close: Date)? {
        guard validDate(now), let day = StockSageMarketHours.nasdaqDay(at: now), day.trading,
              let open = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: now),
              let close = calendar.date(bySettingHour: day.extendedClose, minute: 0, second: 0, of: now) else { return nil }
        return (open, close)
    }
    static func sessionLabel(at date: Date) -> String {
        guard validDate(date), StockSageMarketHours.nasdaqDay(at: date) != nil else { return "Session unavailable" }
        let phase = StockSageMarketHours.nasdaqState(at: date, calendar: calendar).phase
        switch phase {
        case .preMarket: return "Pre-market"
        case .open: return "Regular session"
        case .afterHours: return "Post-market"
        case .closingAuction: return "Closing auction"
        case .closed: return "Scheduled closed"
        }
    }
    private static func intervalSession(start: Date, end: Date) -> String {
        let first = sessionLabel(at: start.addingTimeInterval(-1)), last = sessionLabel(at: end.addingTimeInterval(-1))
        return first == last ? first : first + " → " + last
    }
    private static func validDate(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 > 0 }
    private static func safeDate(_ date: Date) -> Date { validDate(date) ? date : Date(timeIntervalSince1970: 0) }
    private static func number(_ value: Double) -> String { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value) }
    private static func fact(key: String, text: String, status: Status, at: Date?) -> StockSageAIAssessment.EvidenceFact {
        .init(key: key, text: text, required: true, availability: status == .available ? .available : .missing,
              factClass: .technical, source: "Massive split-adjusted one-minute aggregates / StockSage exact-interval calculations",
              observedAt: at.flatMap { validDate($0) ? $0 : nil })
    }
    private static func seriesFact(_ series: Series, key: String) -> StockSageAIAssessment.EvidenceFact {
        let detail = series.returns.map { value in
            guard let result = value.percent, let start = value.start, let end = value.end else {
                return "\(value.minutes)-minute return unavailable: \(value.note)"
            }
            return "\(value.minutes)-minute close-to-close change \(number(result)) percent, exact boundaries \(start.ISO8601Format()) to \(end.ISO8601Format()), \(value.sessionLabel)."
        }.joined(separator: " ")
        return fact(key: key, text: "\(series.symbol) completed-minute momentum, captured \(series.capturedAt.ISO8601Format()). \(series.note) \(detail)",
                    status: series.status, at: series.asOf)
    }
}
