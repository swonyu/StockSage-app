import Foundation
import CoreFoundation

/// Public market-data screening only. Model execution and publication belong to SameDayResearch.
nonisolated enum StockSageMicrocapScreen {
    typealias Listing = StockSageHorizonResearch.Listing
    typealias Minute = StockSageMassiveTicks.Minute
    static let policyVersion = "microcap-1-cap50-300m-float20m-gap10-rvol5-20sessions-float90days"
    static let detailLimit = 24
    static let floatMaximumAge: TimeInterval = 90 * 86_400
    static let maximumDirectoryCount = 50_000
    enum Status: String, Codable, Sendable { case passed, excluded, unavailable, unassessed }
    enum Failure: LocalizedError { case unavailable(String)
        var errorDescription: String? { if case .unavailable(let text) = self { return text }; return nil }
    }
    struct Reference: Codable, Sendable, Equatable {
        let marketCap: Double
        let requestedDate: String
        let retrievedAt: Date
    }
    struct FloatRecord: Codable, Sendable, Equatable {
        let shares: Double
        let effectiveDate: Date
    }
    struct SessionClose: Codable, Sendable, Equatable {
        let date: String
        let close: Double
        let retrievedAt: Date
    }
    struct Session: Codable, Sendable, Equatable { let open: Date; let close: Date }
    struct Window: Codable, Sendable, Equatable {
        let cutoff: Date
        let current: Session
        /// Oldest to newest, exactly twenty verified preceding trading sessions.
        let previous: [Session]
    }
    struct Measurements: Codable, Sendable, Equatable {
        let openingGap: Double
        let relativeVolume: Double
        let volume: Double
        let baselineVolume: Double
        let baselineSessions: Int
        let momentum: Double
        let annualizedVolatility: Double
        let openingPrice: Double
        let previousRegularClose: Double
        let previousRegularCloseDate: String
        let previousRegularCloseRetrievedAt: Date
        let latestRegularPrice: Double
        let observedAt: Date
    }
    struct Row: Codable, Sendable, Equatable, Identifiable {
        let symbol: String
        let name: String
        var status: Status
        var note: String
        var observedAt: Date
        var marketCap: Double? = nil
        var marketCapRequestedDate: String? = nil
        var referenceRetrievedAt: Date? = nil
        var freeFloat: Double? = nil
        var floatEffectiveDate: Date? = nil
        var activity: Double? = nil
        var activityRetrievedAt: Date? = nil
        var openingGap: Double? = nil
        var relativeVolume: Double? = nil
        var volume: Double? = nil
        var baselineVolume: Double? = nil
        var baselineSessions: Int = 0
        var momentum: Double? = nil
        var annualizedVolatility: Double? = nil
        var openingPrice: Double? = nil
        var previousRegularClose: Double? = nil
        var previousRegularCloseDate: String? = nil
        var previousRegularCloseRetrievedAt: Date? = nil
        var latestRegularPrice: Double? = nil
        var id: String { symbol }
    }
    struct Result: Codable, Sendable, Equatable {
        let policyVersion: String
        let startedAt: Date
        let cutoff: Date
        let finishedAt: Date
        let directoryCount: Int
        let detailedCount: Int
        let unassessedCount: Int
        let rows: [Row]
        let blocker: String?
        func facts(for symbol: String) -> [StockSageAIAssessment.EvidenceFact] {
            guard let row = rows.first(where: { $0.symbol == symbol && $0.status == .passed }),
                  let cap = row.marketCap, let float = row.freeFloat, let floatDate = row.floatEffectiveDate,
                  let gap = row.openingGap, let rvol = row.relativeVolume, let volume = row.volume,
                  let baseline = row.baselineVolume, let momentum = row.momentum,
                  let volatility = row.annualizedVolatility else { return [] }
            func fact(_ key: String, _ text: String, _ kind: StockSageAIAssessment.FactClass,
                      at: Date?) -> StockSageAIAssessment.EvidenceFact {
                .init(key: key, text: text, required: true, availability: .available, factClass: kind,
                      source: "Massive public market data / StockSage deterministic microcap screen", observedAt: at)
            }
            return [
                fact("technical.microcap.classification", "Microcap screen for \(symbol): active Nasdaq US USD common shares. Market cap \(cap) USD from ticker-reference date request \(row.marketCapRequestedDate ?? "unknown"), retrieved \(row.referenceRetrievedAt?.ISO8601Format() ?? "unknown"); provider supplies no separate market-cap effective timestamp. Free float \(float) shares, effective \(floatDate.ISO8601Format()); maximum permitted float age ninety days. Outstanding shares were not substituted for float.", .fundamental, at: row.referenceRetrievedAt),
                fact("technical.microcap.activity", "Completed regular-session minutes through \(cutoff.ISO8601Format()): volume \(volume), mean volume over the same exchange-local window in twenty preceding verified sessions \(baseline), relative volume \(rvol)x. Opening gap from the preceding dated Massive daily open-close regular close \(gap * 100) percent; reference session \(row.previousRegularCloseDate ?? "unknown"), retrieved \(row.previousRegularCloseRetrievedAt?.ISO8601Format() ?? "unknown"). Not an official auction-price guarantee; after-hours close was not substituted. Float turnover \(volume / float)x is reported volume divided by float, not unique shares or investor identity.", .technical, at: row.observedAt),
                fact("technical.microcap.motion", "First regular minute open to latest completed-minute close momentum \(momentum * 100) percent. Annualized historical minute-close volatility proxy \(volatility * 100) percent from the final regular-session minute on twenty preceding dates (nineteen log returns, 252 periods per year), not official daily or auction closes. Last measured minute \(row.observedAt.ISO8601Format()).", .technical, at: row.observedAt),
                fact("technical.microcap.policy", "Passed unvalidated screening rules only: market cap fifty through three hundred million USD inclusive, free float below twenty million shares, opening gap at least ten percent and time-matched relative volume at least five times. This is not a qualified Buy, proof of institutional demand or guaranteed performance. Level 2 depth is unavailable; current halt and LULD-band status are unknown. Quotes, same-day catalyst, scenario and final freshness checks remain required.", .risk, at: cutoff)
            ]
        }
    }
    struct Selection: Sendable {
        let listings: [Listing]
        let receipt: Result
        let activity: [String: Double]
    }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    private static var formatter: DateFormatter {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX"); value.calendar = calendar
        value.timeZone = calendar.timeZone; value.dateFormat = "yyyy-MM-dd"; value.isLenient = false
        return value
    }
    private static func day(_ value: Date) -> String { formatter.string(from: value) }
    private static func date(_ value: String) -> Date? {
        guard value.utf8.count == 10, let parsed = formatter.date(from: value), day(parsed) == value else { return nil }
        return parsed
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func noNextPage(_ root: [String: Any]) -> Bool {
        root["next_url"] == nil || root["next_url"] is NSNull || (root["next_url"] as? String) == ""
    }
    private static func session(on date: Date) -> Session? {
        guard let schedule = StockSageMarketHours.nasdaqDay(at: date), schedule.trading,
              let open = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: date),
              let close = calendar.date(bySettingHour: schedule.regularClose, minute: 0, second: 0, of: date) else { return nil }
        return .init(open: open, close: close)
    }
    static func window(at now: Date) throws -> Window {
        guard now.timeIntervalSince1970.isFinite, let current = session(on: now) else {
            throw Failure.unavailable("No current regular session in the verified 2026 Nasdaq calendar.")
        }
        let cutoff = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        let elapsed = cutoff.timeIntervalSince(current.open)
        guard elapsed >= 1800, cutoff < current.close.addingTimeInterval(-300) else {
            throw Failure.unavailable("Screening needs thirty completed regular-session minutes and stops five minutes before the scheduled close.")
        }
        var previous: [Session] = []
        for offset in 1...60 {
            guard let prior = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)),
                  StockSageMarketHours.nasdaqDay(at: prior) != nil else {
                throw Failure.unavailable("Twenty prior sessions are outside the verified 2026 calendar.")
            }
            guard let value = session(on: prior) else { continue }
            guard value.open.addingTimeInterval(elapsed) <= value.close else {
                throw Failure.unavailable("A preceding early-close session cannot supply the same cutoff window; no substitute session was used.")
            }
            previous.append(value)
            if previous.count == 20 { break }
        }
        guard previous.count == 20 else { throw Failure.unavailable("Twenty comparable trading sessions are unavailable.") }
        return .init(cutoff: cutoff, current: current, previous: Array(previous.reversed()))
    }
    static func classify(_ listing: Listing, reference: Reference?, float: FloatRecord?, at now: Date) -> Row {
        var row = Row(symbol: listing.ticker, name: listing.name, status: .unavailable,
            note: "Market cap or dated free float is unavailable; missing values are not zero.",
            observedAt: now.timeIntervalSince1970.isFinite ? now : Date(timeIntervalSince1970: 0),
            marketCap: reference.flatMap { $0.marketCap.isFinite ? $0.marketCap : nil }, marketCapRequestedDate: reference?.requestedDate,
            referenceRetrievedAt: reference.flatMap { $0.retrievedAt.timeIntervalSince1970.isFinite ? $0.retrievedAt : nil },
            freeFloat: float.flatMap { $0.shares.isFinite ? $0.shares : nil },
            floatEffectiveDate: float.flatMap { $0.effectiveDate.timeIntervalSince1970.isFinite ? $0.effectiveDate : nil })
        guard listing.active, listing.market == "stocks", listing.locale == "us",
              listing.primary_exchange == "XNAS", listing.type == "CS",
              listing.currency_name?.lowercased() == "usd", !listing.name.isEmpty,
              StockSageHorizonResearch.validTicker(listing.ticker) else {
            row.status = .excluded; row.note = "Not a verified active Nasdaq US USD common share."; return row
        }
        guard now.timeIntervalSince1970.isFinite, let float, float.shares.isFinite,
              float.shares > 0, float.shares.rounded(.towardZero) == float.shares,
              float.effectiveDate.timeIntervalSince1970.isFinite,
              (0...floatMaximumAge).contains(now.timeIntervalSince(float.effectiveDate)) else {
            row.note = "Free float or its effective date is missing, invalid, future-dated or older than the ninety-day policy. Market cap may remain unqueried."; return row
        }
        guard float.shares < 20_000_000 else {
            row.status = .excluded; row.note = "Free float is not below twenty million shares. Market cap was not required for this exclusion and may be unqueried."; return row
        }
        guard let reference, reference.marketCap.isFinite, reference.marketCap > 0,
              reference.retrievedAt.timeIntervalSince1970.isFinite, reference.retrievedAt <= now,
              reference.requestedDate == day(now), date(reference.requestedDate) != nil,
              day(reference.retrievedAt) == reference.requestedDate else {
            row.note = "A finite positive market cap from today's dated ticker-reference request is unavailable."; return row
        }
        guard (50_000_000...300_000_000).contains(reference.marketCap) else {
            row.status = .excluded; row.note = "Market cap is outside the inclusive fifty-to-three-hundred-million USD band."; return row
        }
        row.status = .unassessed
        row.note = "Cap and float rules passed; detailed gap and twenty-session RVOL have not been assessed."
        return row
    }
    static func detailSymbols(rows: [Row], activity: [String: Double]) -> [String] {
        rows.filter { $0.status == .unassessed && (activity[$0.symbol].map { $0.isFinite && $0 > 0 } ?? false) }
            .sorted { let a = activity[$0.symbol]!, b = activity[$1.symbol]!; return a != b ? a > b : $0.symbol < $1.symbol }
            .prefix(detailLimit).map(\.symbol)
    }
    static func measure(_ bars: [Minute], in window: Window, previousClose: SessionClose? = nil,
                        hasSplit: Bool = false) throws -> Measurements {
        guard !hasSplit else { throw Failure.unavailable("A reported split or stock dividend makes float/history share basis ambiguous; no adjusted substitute was guessed.") }
        guard try self.window(at: window.cutoff) == window, !bars.isEmpty, bars.count < 50_000,
              Set(bars.map(\.at)).count == bars.count,
              bars.allSatisfy({ bar in
                  [bar.at.timeIntervalSince1970, bar.open, bar.high, bar.low, bar.close, bar.volume].allSatisfy(\.isFinite)
                    && bar.at.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0
                    && bar.at >= window.previous[0].open && bar.at.addingTimeInterval(60) <= window.cutoff
                    && bar.low > 0 && bar.low <= min(bar.open, bar.close) && bar.high >= max(bar.open, bar.close)
                    && bar.volume >= 0
              }) else { throw Failure.unavailable("Minute observations are incomplete, duplicated, future-dated or malformed.") }
        let ordered = bars.sorted { $0.at < $1.at }
        let elapsed = window.cutoff.timeIntervalSince(window.current.open)
        var volumes: [Double] = [], closes: [Double] = []
        for prior in window.previous {
            let matched = ordered.filter { $0.at >= prior.open && $0.at < prior.open.addingTimeInterval(elapsed) }
            guard !matched.isEmpty,
                  let close = ordered.first(where: { $0.at == prior.close.addingTimeInterval(-60) && $0.volume > 0 }) else {
                throw Failure.unavailable("A prior matched session or exact final regular-session minute is missing; absence was not counted as zero.")
            }
            volumes.append(matched.reduce(0) { $0 + $1.volume }); closes.append(close.close)
        }
        guard let previousClose, let previous = window.previous.last,
              previousClose.date == day(previous.open), previousClose.close.isFinite, previousClose.close > 0,
              previousClose.retrievedAt.timeIntervalSince1970.isFinite,
              previousClose.retrievedAt >= window.cutoff,
              day(previousClose.retrievedAt) == day(window.cutoff) else {
            throw Failure.unavailable("The preceding dated regular-session close is unavailable; a final-minute or after-hours price was not substituted.")
        }
        let current = ordered.filter { $0.at >= window.current.open && $0.at < window.cutoff }
        guard let open = current.first, open.at == window.current.open, open.volume > 0,
              let last = current.last(where: { $0.volume > 0 }), window.cutoff.timeIntervalSince(last.at) <= 180,
              let volatility = StockSageIndicators.annualizedVolatility(closes), volatility.isFinite else {
            throw Failure.unavailable("The exact opening minute, a fresh completed minute or the preceding regular close is unavailable.")
        }
        let volume = current.reduce(0) { $0 + $1.volume }
        let baseline = volumes.reduce(0, +) / 20
        let gap = open.open / previousClose.close - 1, rvol = volume / baseline, momentum = last.close / open.open - 1
        guard [volume, baseline, gap, rvol, momentum].allSatisfy(\.isFinite), volume > 0, baseline > 0 else {
            throw Failure.unavailable("The twenty-session volume baseline is zero or non-finite; relative volume is unavailable.")
        }
        return .init(openingGap: gap, relativeVolume: rvol, volume: volume, baselineVolume: baseline,
            baselineSessions: 20, momentum: momentum, annualizedVolatility: volatility, openingPrice: open.open,
            previousRegularClose: previousClose.close, previousRegularCloseDate: previousClose.date,
            previousRegularCloseRetrievedAt: previousClose.retrievedAt,
            latestRegularPrice: last.close, observedAt: last.at)
    }
    /// Only this exact endpoint may receive the captured credential on subsequent pages.
    static func floatRequest(key: String, next: String? = nil) -> URLRequest? {
        guard !key.isEmpty, (next?.utf8.count ?? 0) <= 8192,
              let parts = URLComponents(string: next ?? StockSageMassive.host + "/stocks/vX/float?limit=5000&sort=ticker.asc"),
              parts.scheme == "https", parts.host == "api.massive.com", parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.path == "/stocks/vX/float",
              parts.queryItems?.allSatisfy({ ["limit", "sort", "cursor"].contains($0.name) }) == true,
              let url = parts.url else { return nil }
        return authorized(url, key: key)
    }
    private static func authorized(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }
    static func referenceRequest(symbol: String, date: String, key: String) -> URLRequest? {
        guard StockSageHorizonResearch.validTicker(symbol), self.date(date) != nil, !key.isEmpty,
              var parts = URLComponents(string: StockSageMassive.host + "/v3/reference/tickers/\(symbol)") else { return nil }
        parts.queryItems = [.init(name: "date", value: date)]
        return parts.url.map { authorized($0, key: key) }
    }
    /// Dedicated regular-session close; the API's afterHours field is deliberately unused.
    static func closeRequest(symbol: String, date: String, key: String) -> URLRequest? {
        guard StockSageHorizonResearch.validTicker(symbol), let value = self.date(date),
              StockSageMarketHours.nasdaqDay(at: value)?.trading == true, !key.isEmpty,
              let url = URL(string: StockSageMassive.host + "/v1/open-close/\(symbol)/\(date)?adjusted=true") else { return nil }
        return authorized(url, key: key)
    }
    static func parseClose(_ data: Data, symbol: String, date: String, retrievedAt: Date) throws -> SessionClose {
        guard data.count <= 1_000_000, let requested = self.date(date), requested < retrievedAt,
              retrievedAt.timeIntervalSince1970.isFinite,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", root["symbol"] as? String == symbol,
              root["from"] as? String == date, let close = number(root["close"]), close > 0 else {
            throw Failure.unavailable("Daily open-close did not supply the requested ticker, prior session and finite regular close.")
        }
        // The documented response need not echo adjusted. The exact authorized request and
        // response URL bind adjusted=true; reject an explicit contradictory echo if supplied.
        if let raw = root["adjusted"] {
            guard let adjusted = raw as? NSNumber, CFGetTypeID(adjusted) == CFBooleanGetTypeID(), adjusted.boolValue else {
                throw Failure.unavailable("Daily open-close contradicted the requested split-adjusted contract.")
            }
        }
        return .init(date: date, close: close, retrievedAt: retrievedAt)
    }
    static func minuteRequest(symbol: String, window: Window, key: String) -> URLRequest? {
        guard StockSageHorizonResearch.validTicker(symbol), !key.isEmpty, let first = window.previous.first,
              first.open.timeIntervalSince1970.isFinite, window.cutoff.timeIntervalSince1970.isFinite,
              first.open < window.cutoff, (try? self.window(at: window.cutoff)) == window else { return nil }
        let from = Int64(first.open.timeIntervalSince1970 * 1000)
        let to = Int64(window.cutoff.timeIntervalSince1970 * 1000) - 1
        guard let url = URL(string: StockSageMassive.host + "/v2/aggs/ticker/\(symbol)/range/1/minute/\(from)/\(to)?adjusted=true&sort=asc&limit=50000") else { return nil }
        return authorized(url, key: key)
    }
    static func parseFloats(_ data: Data) throws -> (records: [String: FloatRecord], next: String?, count: Int) {
        guard data.count <= 8_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", let rows = root["results"] as? [[String: Any]], rows.count <= 5000 else {
            throw Failure.unavailable("Float coverage payload is malformed or exceeds the page bound.")
        }
        let next: String?
        if noNextPage(root) { next = nil }
        else if let value = root["next_url"] as? String, !value.isEmpty { next = value }
        else { throw Failure.unavailable("Float pagination is malformed.") }
        var records: [String: FloatRecord] = [:], seen: Set<String> = []
        for row in rows {
            guard let symbol = row["ticker"] as? String, StockSageHorizonResearch.validTicker(symbol),
                  seen.insert(symbol).inserted else { throw Failure.unavailable("Float records have missing or duplicate ticker identity.") }
            // Missing fields remain unavailable for that ticker, never outstanding shares or zero.
            guard let shares = number(row["free_float"]), shares > 0, shares.rounded(.towardZero) == shares,
                  let text = row["effective_date"] as? String, let effective = date(text) else { continue }
            records[symbol] = .init(shares: shares, effectiveDate: effective)
        }
        return (records, next, rows.count)
    }
    static func parseReference(_ data: Data, listing: Listing, requestedDate: String, retrievedAt: Date) throws -> Reference {
        guard data.count <= 1_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", let row = root["results"] as? [String: Any],
              row["ticker"] as? String == listing.ticker, row["market"] as? String == "stocks",
              row["locale"] as? String == "us", row["primary_exchange"] as? String == "XNAS",
              row["type"] as? String == "CS", (row["currency_name"] as? String)?.lowercased() == "usd",
              let active = row["active"] as? NSNumber, CFGetTypeID(active) == CFBooleanGetTypeID(), active.boolValue,
              let cap = number(row["market_cap"]), cap > 0,
              retrievedAt.timeIntervalSince1970.isFinite, date(requestedDate) != nil,
              day(retrievedAt) == requestedDate else {
            throw Failure.unavailable("Dated market cap or matching Nasdaq common-share metadata is unavailable.")
        }
        return .init(marketCap: cap, requestedDate: requestedDate, retrievedAt: retrievedAt)
    }
    static func parseMinutes(_ data: Data, symbol: String, window: Window) throws -> [Minute] {
        guard data.count <= 16_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", root["ticker"] as? String == symbol, noNextPage(root),
              let adjusted = root["adjusted"] as? NSNumber, CFGetTypeID(adjusted) == CFBooleanGetTypeID(), adjusted.boolValue,
              let count = StockSageMassive.int64(root["resultsCount"]), (1..<50_000).contains(count),
              let queried = StockSageMassive.int64(root["queryCount"]), queried >= count, queried < 50_000,
              let rows = root["results"] as? [[String: Any]], rows.count == count else {
            throw Failure.unavailable("Complete split-adjusted minute history is unavailable, paginated or at the base-aggregate limit.")
        }
        var bars: [Minute] = [], previous: Date?
        for row in rows {
            guard let ms = StockSageMassive.int64(row["t"]), ms > 0, ms % 60_000 == 0,
                  let open = number(row["o"]), let high = number(row["h"]), let low = number(row["l"]),
                  let close = number(row["c"]), let volume = number(row["v"]),
                  low > 0, low <= min(open, close), high >= max(open, close), volume >= 0 else {
                throw Failure.unavailable("A minute bar has invalid time, price or volume.")
            }
            let at = Date(timeIntervalSince1970: Double(ms) / 1000)
            guard let first = window.previous.first, at >= first.open, at.addingTimeInterval(60) <= window.cutoff,
                  previous.map({ at > $0 }) ?? true else { throw Failure.unavailable("Minute bars are duplicated, unordered or outside the requested completed window.") }
            bars.append(.init(at: at, open: open, high: high, low: low, close: close, volume: volume)); previous = at
        }
        return bars
    }
    static func parseActivity(_ data: Data, on session: String, at now: Date) throws -> [String: Double] {
        guard data.count <= StockSageMassive.marketMaximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", noNextPage(root),
              let adjusted = root["adjusted"] as? NSNumber, CFGetTypeID(adjusted) == CFBooleanGetTypeID(), adjusted.boolValue,
              let count = StockSageMassive.int64(root["resultsCount"]), (0...50_000).contains(count) else {
            throw Failure.unavailable("Complete current-session activity coverage is unavailable.")
        }
        let rows: [[String: Any]]
        if count == 0, root["results"] == nil { rows = [] }
        else if let value = root["results"] as? [[String: Any]], value.count == count { rows = value }
        else { throw Failure.unavailable("Current-session activity count is inconsistent.") }
        var result: [String: Double] = [:], seen: Set<String> = []
        for row in rows {
            guard let symbol = row["T"] as? String, seen.insert(symbol).inserted else {
                throw Failure.unavailable("Current-session activity has missing or duplicate ticker identity.")
            }
            guard let ms = StockSageMassive.int64(row["t"]), ms > 0,
                  let volume = number(row["v"]), volume > 0, let vwap = number(row["vw"]), vwap > 0,
                  (volume * vwap).isFinite else { continue }
            let stamp = Date(timeIntervalSince1970: Double(ms) / 1000)
            guard stamp <= now, day(stamp) == session else { continue }
            result[symbol] = volume * vwap
        }
        return result
    }
    private enum HTTPFailure: Error { case status(Int) }
    private static func note(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "Screen interrupted or data-access generation changed; no new assessment was authorized." }
        if case HTTPFailure.status(let status) = error { return "Massive returned HTTP \(status); coverage was not verified." }
        if let failure = error as? Failure { return failure.localizedDescription }
        return "Market data could not be retrieved or validated within the bounded request contract."
    }
    private static func stopsCollection(_ error: Error) -> Bool {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return true }
        if case HTTPFailure.status(let value) = error { return value == 401 || value == 403 }
        return false
    }
    @MainActor static func select(key: String, allowed: @escaping @MainActor () -> Bool,
        now: Date = Date(), clock: @escaping @MainActor () -> Date = Date.init,
        transport: StockSageMassive.Transport? = nil) async -> Selection {
        let started = now.timeIntervalSince1970.isFinite ? now : Date(timeIntervalSince1970: 0)
        var cutoff = started, directory: [Listing] = [], rows: [Row] = [], activity: [String: Double] = [:], detailed = 0
        @MainActor func checkAccess() throws {
            try Task.checkCancellation()
            guard allowed(), !key.isEmpty else { throw CancellationError() }
            let value = clock()
            guard value.timeIntervalSince1970.isFinite, value >= started else {
                throw Failure.unavailable("The capture clock changed or is invalid; no current screen was completed.")
            }
        }
        @MainActor func load(_ request: URLRequest?, maximum: Int) async throws -> Data {
            try checkAccess()
            guard let request else { throw Failure.unavailable("The provider request or ticker cannot be represented by the verified endpoint contract.") }
            let (data, response) = try await StockSageMassive.response(for: request, maximumBytes: maximum, transport: transport)
            try checkAccess()
            guard response.statusCode == 200 else { throw HTTPFailure.status(response.statusCode) }
            return data
        }
        @MainActor func finish(_ blocker: String?) -> Selection {
            let end = clock()
            let validEnd = end.timeIntervalSince1970.isFinite && end >= started
            let issue = blocker ?? (validEnd ? nil : "The capture clock became invalid.")
            let receipt = Result(policyVersion: policyVersion, startedAt: started, cutoff: cutoff,
                finishedAt: validEnd ? end : started, directoryCount: directory.count, detailedCount: detailed,
                unassessedCount: rows.filter { $0.status == .unassessed }.count, rows: rows, blocker: issue)
            let passed = Set(issue == nil ? rows.filter { $0.status == .passed }.map(\.symbol) : [])
            return .init(listings: directory.filter { passed.contains($0.ticker) }.sorted {
                let a = activity[$0.ticker] ?? 0, b = activity[$1.ticker] ?? 0
                return a != b ? a > b : $0.ticker < $1.ticker
            }, receipt: receipt, activity: activity.filter { passed.contains($0.key) })
        }
        do {
            try checkAccess(); _ = try window(at: now)
            // Keep the existing directory parser/pagination bound; also validate response identity
            // and byte count on injected and real transports before it sees the page.
            let guarded: StockSageMassive.Transport = { request in
                let (data, response) = try await StockSageMassive.response(for: request, maximumBytes: 4_000_000, transport: transport)
                return (data, response)
            }
            let all = try await StockSageHorizonResearch.fetchUniverse(key: key, allowed: allowed, transport: guarded)
            directory = all.filter { $0.primary_exchange == "XNAS" }
            guard !directory.isEmpty else { throw Failure.unavailable("No Nasdaq listings were supplied by the completed directory response.") }
            guard directory.count <= maximumDirectoryCount else { throw Failure.unavailable("The Nasdaq directory exceeds the supported record bound.") }
            rows = directory.map { .init(symbol: $0.ticker, name: $0.name, status: .unavailable,
                note: "Reference classification has not completed; eligibility is unknown.", observedAt: started) }
            var floats: [String: FloatRecord] = [:], next: String?, pages: Set<URL> = [], floatCount = 0
            repeat {
                guard let request = floatRequest(key: key, next: next), let url = request.url,
                      pages.insert(url).inserted, pages.count <= 10 else {
                    throw Failure.unavailable("Float coverage pagination is unsafe, repeated or exceeds ten pages; no partial classification was accepted.")
                }
                let page = try parseFloats(await load(request, maximum: 8_000_000))
                floatCount += page.count
                guard floatCount <= maximumDirectoryCount else { throw Failure.unavailable("Float directory exceeds fifty thousand records.") }
                for (symbol, value) in page.records {
                    guard floats[symbol] == nil else { throw Failure.unavailable("Float coverage repeats a ticker across pages.") }
                    floats[symbol] = value
                }
                next = page.next
            } while next != nil

            let capturedFloats = floats
            @MainActor func classifyAt(_ index: Int) async throws -> (Int, Row) {
                try checkAccess()
                let listing = directory[index], checkedAt = clock(), value = capturedFloats[listing.ticker]
                var row = classify(listing, reference: nil, float: value, at: checkedAt)
                // Float-first exclusion is explicit; it never invents an out-of-band market cap.
                guard row.status != .excluded, let value, value.shares > 0, value.shares < 20_000_000,
                      (0...floatMaximumAge).contains(checkedAt.timeIntervalSince(value.effectiveDate)) else { return (index, row) }
                do {
                    let requested = day(checkedAt)
                    let data = try await load(referenceRequest(symbol: listing.ticker, date: requested, key: key), maximum: 1_000_000)
                    let retrieved = clock()
                    let reference = try parseReference(data, listing: listing, requestedDate: requested, retrievedAt: retrieved)
                    row = classify(listing, reference: reference, float: value, at: retrieved)
                } catch {
                    if stopsCollection(error) { throw error }
                    row.note = note(error)
                }
                return (index, row)
            }
            try await withThrowingTaskGroup(of: (Int, Row).self) { group in
                var nextIndex = 0
                while nextIndex < min(4, directory.count) {
                    let index = nextIndex; nextIndex += 1
                    group.addTask { @MainActor @Sendable in try await classifyAt(index) }
                }
                while let (index, row) = try await group.next() {
                    rows[index] = row
                    if nextIndex < directory.count {
                        try checkAccess(); let index = nextIndex; nextIndex += 1
                        group.addTask { @MainActor @Sendable in try await classifyAt(index) }
                    }
                }
            }
            try checkAccess()
            // Slow reference collection cannot consume the completed-minute freshness window.
            let measuredWindow = try window(at: clock()); cutoff = measuredWindow.cutoff
            let activityData = try await load(StockSageResearchUniverse.request(key: key, session: day(cutoff)), maximum: StockSageMassive.marketMaximumBytes)
            let activityAt = clock()
            activity = try parseActivity(activityData, on: day(cutoff), at: activityAt)
            for index in rows.indices where rows[index].status == .unassessed {
                rows[index].activity = activity[rows[index].symbol]; rows[index].activityRetrievedAt = activityAt
                if rows[index].activity == nil {
                    rows[index].status = .unavailable
                    rows[index].note = "Cap and float passed, but current-session dollar activity is unavailable. Prior-session activity was not substituted."
                }
            }
            let chosen = Set(detailSymbols(rows: rows, activity: activity))
            let indices = rows.indices.filter { chosen.contains(rows[$0].symbol) }
            for index in rows.indices where rows[index].status == .unassessed && !chosen.contains(rows[index].symbol) {
                rows[index].note = "Cap and float passed; gap/RVOL unassessed because only the twenty-four highest current-session dollar-activity candidates receive detailed collection."
            }
            let classifiedRows = rows
            @MainActor func detailedAt(_ index: Int) async throws -> (Int, Row) {
                var row = classifiedRows[index]
                do {
                    try checkAccess()
                    guard let floatDate = row.floatEffectiveDate, let oldest = measuredWindow.previous.first else {
                        throw Failure.unavailable("Float or comparison-window provenance is unavailable.")
                    }
                    let since = min(floatDate, oldest.open)
                    let splitData = try await load(StockSageMassiveSplits.request(symbol: row.symbol, since: since, now: cutoff, key: key), maximum: 2_000_000)
                    let splits = try StockSageMassiveSplits.parse(splitData, symbol: row.symbol, since: since, now: cutoff)
                    guard splits.events.isEmpty else {
                        throw Failure.unavailable("A split or stock dividend occurred across the float/history basis window; comparison is unavailable.")
                    }
                    guard let previous = measuredWindow.previous.last else {
                        throw Failure.unavailable("The preceding session could not be verified.")
                    }
                    let previousDate = day(previous.open)
                    let closeData = try await load(closeRequest(symbol: row.symbol, date: previousDate, key: key), maximum: 1_000_000)
                    let previousClose = try parseClose(closeData, symbol: row.symbol, date: previousDate, retrievedAt: clock())
                    let data = try await load(minuteRequest(symbol: row.symbol, window: measuredWindow, key: key), maximum: 16_000_000)
                    let bars = try parseMinutes(data, symbol: row.symbol, window: measuredWindow)
                    let value = try measure(bars, in: measuredWindow, previousClose: previousClose)
                    row.openingGap = value.openingGap; row.relativeVolume = value.relativeVolume
                    row.volume = value.volume; row.baselineVolume = value.baselineVolume; row.baselineSessions = value.baselineSessions
                    row.momentum = value.momentum; row.annualizedVolatility = value.annualizedVolatility
                    row.openingPrice = value.openingPrice; row.previousRegularClose = value.previousRegularClose
                    row.previousRegularCloseDate = value.previousRegularCloseDate
                    row.previousRegularCloseRetrievedAt = value.previousRegularCloseRetrievedAt
                    row.latestRegularPrice = value.latestRegularPrice; row.observedAt = value.observedAt
                    if value.openingGap >= 0.10 && value.relativeVolume >= 5 {
                        row.status = .passed; row.note = "Passed unvalidated cap, float, opening-gap and time-matched RVOL rules. Not a qualified pick; depth unavailable and halt/band status unknown."
                    } else {
                        row.status = .excluded; row.note = "Opening gap is below ten percent or twenty-session time-matched RVOL is below five times; measured values are retained."
                    }
                } catch {
                    if stopsCollection(error) { throw error }
                    row.status = .unavailable; row.note = note(error)
                }
                return (index, row)
            }
            try await withThrowingTaskGroup(of: (Int, Row).self) { group in
                var nextIndex = 0
                while nextIndex < min(4, indices.count) {
                    let index = indices[nextIndex]; nextIndex += 1
                    group.addTask { @MainActor @Sendable in try await detailedAt(index) }
                }
                while let (index, row) = try await group.next() {
                    rows[index] = row; detailed += 1
                    if nextIndex < indices.count {
                        try checkAccess(); let index = indices[nextIndex]; nextIndex += 1
                        group.addTask { @MainActor @Sendable in try await detailedAt(index) }
                    }
                }
            }
            try checkAccess()
            return finish(nil)
        } catch {
            return finish(note(error))
        }
    }
}
