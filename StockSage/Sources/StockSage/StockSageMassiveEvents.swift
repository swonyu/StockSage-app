import Foundation
import CoreFoundation

/// M6 contracts: https://massive.com/docs/rest/partners/benzinga/{analyst-ratings,corporate-guidance}
/// and /docs/rest/stocks/{filings/8-k-disclosures,filings/form-4,corporate-actions/dividends}.
/// Provider observations only: never a target/EV/ranking input or an instruction to trade.
@MainActor
enum StockSageMassiveEvents {
    nonisolated static let pageLimit = 10
    nonisolated enum Feed: String, Codable, Sendable, CaseIterable {
        case filing8K, ratings, guidance, dividends, insider

        var path: String {
            switch self {
            case .filing8K: "/stocks/filings/8-K/vX/disclosures"
            case .ratings: "/benzinga/v1/ratings"
            case .guidance: "/benzinga/v1/guidance"
            case .dividends: "/stocks/v1/dividends"
            case .insider: "/stocks/filings/vX/form-4"
            }
        }
        var dateField: String {
            switch self {
            case .filing8K, .insider: "filing_date"
            case .ratings, .guidance: "date"
            case .dividends: "ex_dividend_date"
            }
        }
        var pluralTicker: Bool { self == .filing8K || self == .insider }
        var days: Int {
            switch self {
            case .filing8K, .ratings: 7
            case .guidance, .insider: 14
            case .dividends: 30
            }
        }
        var source: String {
            switch self {
            case .filing8K: "Massive/SEC 8-K"
            case .ratings: "Massive/Benzinga ratings"
            case .guidance: "Massive/Benzinga guidance"
            case .dividends: "Massive dividends"
            case .insider: "Massive/SEC Form 4"
            }
        }
        var kind: StockSageCatalystWatch.Kind {
            switch self {
            case .filing8K: .filing8K
            case .ratings: .ratingChange
            case .guidance: .guidanceChange
            case .dividends: .exDividend
            case .insider: .insiderTrade
            }
        }
        var caveat: String {
            switch self {
            case .filing8K: "Filed disclosure; category is provider-classified, not a verified prediction. Read the filing."
            case .ratings: "Analyst opinion, not StockSage's target or evidence of an edge. Target bases are not mixed."
            case .guidance: "Company guidance is not a result or a promise. Missing bounds do not establish withdrawal."
            case .dividends: "Ex-date is not proof of entitlement or cash received; confirm terms with the issuer and broker."
            case .insider: "Filing-lagged disclosure, not a live trade signal. P/S may be open-market or private transactions."
            }
        }
    }

    nonisolated struct Event: Codable, Sendable, Equatable {
        let id: String
        let symbol: String
        let feed: Feed
        let date: Date
        let headline: String
        let details: [String]
        let link: URL?
    }
    nonisolated struct Observation: Codable, Sendable, Equatable {
        nonisolated enum Outcome: String, Codable, Sendable { case answered, unavailable }
        let symbol: String
        let feed: Feed
        let checkedAt: Date
        let outcome: Outcome
        let event: Event?
        var failure: Failure? = nil
        var credentialRevision: String? = nil
        var key: String { symbol + "|" + feed.rawValue }

        func fresh(at now: Date, credentialRevision expected: String? = nil) -> Bool {
            // Dated successful facts survive rotation; a failed request cannot delay a new key.
            if outcome == .unavailable, let expected, credentialRevision != expected { return false }
            let age = now.timeIntervalSince(checkedAt)
            guard age.isFinite, age >= 0, age < (outcome == .answered ? 86_400 : 900) else { return false }
            // A selected ex-date can pass at midnight: re-query for the NEXT date, not an
            // empty-looking stale selection. The successful cache uses UTC calendar days.
            return outcome != .answered || floor(now.timeIntervalSince1970 / 86_400) == floor(checkedAt.timeIntervalSince1970 / 86_400)
        }
    }
    nonisolated struct RefreshKey: Equatable {
        let symbols: Set<String>
        let refreshedAt: Date?
        var credentialRevision: String? = nil
    }
    nonisolated enum Direction: String { case raised, lowered, unchanged, mixed, unknown }
    nonisolated static func statusLine(_ feed: Feed, observation: Observation?, now: Date) -> String {
        guard let observation else { return "\(feed.source): not checked." }
        guard observation.fresh(at: now) else { return "\(feed.source): stale check; current coverage unknown." }
        let date = StockSageCatalystWatch.dateStr(observation.checkedAt)
        guard observation.outcome == .answered else {
            return "\(feed.source): unavailable at \(date), not an empty result. "
                + (observation.failure?.message ?? "Failure reason not recorded; await the next due check.")
        }
        return "\(feed.source): checked \(date); " + (observation.event == nil
            ? "no qualifying event in the queried \(feed.days)-day window."
            : "one selected event; open the dated record for context.")
    }
    /// Only fixed categories and HTTP status codes may reach the UI/cache. Never retain raw
    /// response bodies, request URLs, headers, or localized errors (which may contain secrets).
    nonisolated enum Failure: Error, Codable, Sendable, Equatable {
        case http(Int), transport, timedOut, cooldown, externalAccessDisabled, cancelled, requestUnavailable
        case invalidPayload, incompleteResponse, responseTooLarge
        case conflictingTransactionDirection

        var message: String {
            switch self {
            case .http(let code): "HTTP \(code); provider request did not succeed."
            case .transport: "Network request failed or no HTTP response was received."
            case .timedOut: "Network request timed out."
            case .cooldown: "Provider access cooldown active; no new request sent."
            case .externalAccessDisabled: "External access is disabled; no request sent."
            case .cancelled: "Request cancelled."
            case .requestUnavailable: "Request not made: missing configuration or unsupported input."
            case .invalidPayload: "Response failed data validation."
            case .conflictingTransactionDirection: "Filing has conflicting purchase/sale and acquired/disposed fields; transaction direction is unverified."
            case .incompleteResponse: "Complete coverage unavailable: page/row limit or unsafe/repeated continuation; more data is required."
            case .responseTooLarge: "Response exceeds the 2 MB validation limit."
            }
        }
    }
    private nonisolated static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    nonisolated static func day(_ text: String) -> Date? {
        guard text.count == 10, let date = dayFormatter.date(from: text), dayFormatter.string(from: date) == text else { return nil }
        return date
    }
    /// `days` overrides the feed's catalyst window. Default nil keeps every existing caller
    /// unchanged. The override exists because the Chat EVIDENCE path and the Catalysts path want
    /// different things from the same rows: a catalyst is only interesting if it just happened,
    /// while "what do analysts currently say" is still worth showing a few weeks later, clearly
    /// dated. Sharing one 7-day window meant a month-quiet symbol looked like missing data.
    nonisolated static func inWindow(_ date: Date, feed: Feed, now: Date, days: Int? = nil) -> Bool {
        guard date.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite,
              let today = day(dayFormatter.string(from: now)) else { return false }
        let span = Double(max(0, days ?? feed.days))
        let offset = date.timeIntervalSince(today) / 86_400
        return feed == .dividends ? (0...span).contains(offset) : (-span...0).contains(offset)
    }

    /// Bounds move together or the result is mixed; midpoint arithmetic can conceal widening.
    /// Missing/invalid ranges are unknown, NEVER withdrawn. Negative EPS remains valid.
    nonisolated static func direction(lower: Double?, upper: Double?, previousLower: Double?, previousUpper: Double?) -> Direction {
        guard let lower, let upper, let previousLower, let previousUpper,
              [lower, upper, previousLower, previousUpper].allSatisfy(\.isFinite),
              lower <= upper, previousLower <= previousUpper else { return .unknown }
        if lower == previousLower && upper == previousUpper { return .unchanged }
        if lower >= previousLower && upper >= previousUpper { return .raised }
        if lower <= previousLower && upper <= previousUpper { return .lowered }
        return .mixed
    }

    nonisolated static func request(_ feed: Feed, symbol: String, now: Date, key: String, limit: Int = 100) -> URLRequest? {
        guard StockSageMassive.covers(symbol), !key.isEmpty, (1...100).contains(limit),
              now.timeIntervalSince1970.isFinite,
              var parts = URLComponents(string: StockSageMassive.host + feed.path) else { return nil }
        let first = feed == .dividends ? now : now.addingTimeInterval(-Double(feed.days) * 86_400)
        let last = feed == .dividends ? now.addingTimeInterval(Double(feed.days) * 86_400) : now
        parts.queryItems = [
            .init(name: feed.pluralTicker ? "tickers" : "ticker", value: symbol.uppercased()),
            .init(name: feed.dateField + ".gte", value: dayFormatter.string(from: first)),
            .init(name: feed.dateField + ".lte", value: dayFormatter.string(from: last)),
            .init(name: "sort", value: feed.dateField + (feed == .dividends ? ".asc" : ".desc")),
            .init(name: "limit", value: String(limit))]
        guard let url = parts.url else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Single-response callers must still prove completeness; only fetch follows continuations.
    /// `windowDays` widens the recency window and `requireMateriality` keeps or drops the
    /// ratings "must be a change" rule. Both default to today's behaviour; only the Chat evidence
    /// path overrides them. See `inWindow`.
    nonisolated static func parse(_ data: Data, feed: Feed, symbol: String, now: Date,
                                  windowDays: Int? = nil, requireMateriality: Bool = true) throws -> Event? {
        let page = try parsePage(data, feed: feed, symbol: symbol, now: now,
                                 windowDays: windowDays, requireMateriality: requireMateriality)
        guard page.next == nil else { throw Failure.incompleteResponse }
        return page.event
    }
    private nonisolated static func parsePage(_ data: Data, feed: Feed, symbol: String, now: Date,
                                              windowDays: Int? = nil,
                                              requireMateriality: Bool = true) throws -> (event: Event?, next: String?) {
        guard data.count <= 2_000_000 else { throw Failure.responseTooLarge }
        guard StockSageMassive.covers(symbol), now.timeIntervalSince1970.isFinite,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", let rows = root["results"] as? [Any] else {
            throw Failure.invalidPayload
        }
        guard rows.count <= 100 else { throw Failure.incompleteResponse }
        var next: String?
        if let raw = root["next_url"], !(raw is NSNull) {
            guard let text = raw as? String else { throw Failure.invalidPayload }
            next = text.isEmpty ? nil : text
        }
        var events: [Event] = []
        for value in rows {
            guard let row = value as? [String: Any] else { throw Failure.invalidPayload }
            let tickers = feed.pluralTicker ? row["tickers"] as? [String] : (row["ticker"] as? String).map { [$0] }
            guard tickers?.map({ $0.uppercased() }).contains(symbol.uppercased()) == true,
                  let text = row[feed.dateField] as? String, let date = day(text) else { throw Failure.invalidPayload }
            guard inWindow(date, feed: feed, now: now, days: windowDays) else { continue }
            if let event = try event(row, feed: feed, symbol: symbol.uppercased(), date: date,
                                     requireMateriality: requireMateriality) { events.append(event) }
        }
        return (selected(events, feed: feed), next)
    }
    private nonisolated static func selected(_ events: [Event], feed: Feed) -> Event? {
        events.min {
            if $0.date != $1.date { return feed == .dividends ? $0.date < $1.date : $0.date > $1.date }
            // Stable content tie-break also handles multiple disclosures/transactions in a filing.
            return ($0.id + $0.headline + $0.details.joined()) < ($1.id + $1.headline + $1.details.joined())
        }
    }

    /// Same trust boundary as MassiveTicks: bearer auth never follows an arbitrary vendor URL.
    private nonisolated static func nextRequest(_ next: String, feed: Feed, key: String,
                                                pagesLoaded: Int, visited: Set<String>) -> URLRequest? {
        guard pagesLoaded < pageLimit, !visited.contains(next), next.utf8.count <= 8_192,
              !key.isEmpty, let parts = URLComponents(string: next),
              parts.scheme == "https", parts.host == "api.massive.com",
              parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.percentEncodedPath == feed.path,
              !(parts.queryItems ?? []).contains(where: { $0.name.lowercased() == "apikey" }),
              let url = parts.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private nonisolated static func number(_ row: [String: Any], _ key: String) throws -> Double? {
        guard let value = row[key], !(value is NSNull) else { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
            throw Failure.invalidPayload
        }
        return n.doubleValue
    }
    private nonisolated static func text(_ row: [String: Any], _ key: String, limit: Int = 120) -> String? {
        guard let raw = row[key] as? String else { return nil }
        let clean = StockSageNewsService.boundedText(raw, limit: limit)
        return clean.isEmpty ? nil : clean
    }
    private nonisolated static func amount(_ value: Double) -> String {
        String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private nonisolated static func currency(_ row: [String: Any]) -> String? {
        guard let c = row["currency"] as? String, c.utf8.count == 3,
              c.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return c
    }
    nonisolated static func sourceLink(_ raw: Any?, feed: Feed) -> URL? {
        guard let url = StockSageNewsService.safeLink(raw), url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return nil }
        if feed.pluralTicker { return ["www.sec.gov", "sec.gov"].contains(host) ? url : nil }
        return host == "benzinga.com" || host.hasSuffix(".benzinga.com") ? url : nil
    }
    private nonisolated static func event(_ row: [String: Any], feed: Feed, symbol: String, date: Date,
                                          requireMateriality: Bool = true) throws -> Event? {
        let dateText = StockSageCatalystWatch.dateStr(date)
        let idKey = feed.pluralTicker ? "accession_number" : (feed == .dividends ? "id" : "benzinga_id")
        // Benzinga IDs can be strings or integral numbers; never stringify an arbitrary object.
        let numericID = try numberID(row[idKey])
        guard let id = text(row, idKey) ?? numericID else { throw Failure.invalidPayload }
        var details = ["\(feed.source) · \(dateText)."]
        let headline: String
        let link = sourceLink(row[feed.pluralTicker ? "filing_url" : "benzinga_news_url"], feed: feed)
        switch feed {
        case .filing8K:
            headline = "8-K filed · \(dateText)"
            if let category = text(row, "primary_category") { details.append("Provider category: \(category).") }
            if let excerpt = text(row, "supporting_text", limit: 220) { details.append("Filing excerpt (untrusted text): \(excerpt)") }
        case .ratings:
            guard let firm = text(row, "firm") else { throw Failure.invalidPayload }
            let action = text(row, "rating_action") ?? "not supplied"
            let changed = ["downgrades", "upgrades", "reinstates", "assumes", "initiates_coverage_on",
                           "terminates_coverage_on", "removes", "suspends", "firm_dissolved"].contains(action)
            let target = try number(row, "price_target"), previous = try number(row, "previous_price_target")
            if let target, target <= 0 { throw Failure.invalidPayload }
            if let previous, previous <= 0 { throw Failure.invalidPayload }
            let targetChanged = target != nil && previous != nil && target != previous
            // A catalyst must be a CHANGE, so "maintains"/"reiterates" with an unchanged target is
            // correctly not news. As Chat EVIDENCE the same row is useful: it is what a named firm
            // currently says, and the reader can see its date. Hence the opt-out.
            guard changed || targetChanged || !requireMateriality else { return nil }
            headline = "Analyst update · \(dateText)"
            details.append("\(firm): \(action.replacingOccurrences(of: "_", with: " ")); rating \(text(row, "previous_rating") ?? "not supplied") → \(text(row, "rating") ?? "not supplied").")
            if let target, let previous, let c = currency(row) {
                details.append("Analyst price target (original basis): \(c) \(amount(previous)) → \(c) \(amount(target)); not an app target.")
            } else { details.append("Comparable original-basis price targets/currency not supplied.") }
        case .guidance:
            guard let period = text(row, "fiscal_period", limit: 12), let year = try number(row, "fiscal_year"),
                  year.rounded() == year, (1900...2200).contains(year) else { throw Failure.invalidPayload }
            headline = "Company guidance update · \(dateText)"
            details.append("Fiscal \(period) \(Int(year)); \(text(row, "release_type") ?? "release type not supplied").")
            for metric in ["eps", "revenue"] {
                let lo = try number(row, "min_\(metric)_guidance"), hi = try number(row, "max_\(metric)_guidance")
                let oldLo = try number(row, "previous_min_\(metric)_guidance"), oldHi = try number(row, "previous_max_\(metric)_guidance")
                if let lo, let hi, lo > hi { throw Failure.invalidPayload }
                if let oldLo, let oldHi, oldLo > oldHi { throw Failure.invalidPayload }
                if metric == "revenue", [lo, hi, oldLo, oldHi].compactMap({ $0 }).contains(where: { $0 < 0 }) { throw Failure.invalidPayload }
                let method = text(row, metric + "_method")
                let compatible = (metric == "eps" ? ["gaap", "ffo", "adj"] : ["gaap", "adj"]).contains(method ?? "")
                let dir = compatible && currency(row) != nil ? direction(lower: lo, upper: hi, previousLower: oldLo, previousUpper: oldHi) : .unknown
                if let lo, let hi, let oldLo, let oldHi, let c = currency(row), compatible {
                    details.append("\(metric.uppercased()) (\(method!)): \(dir.rawValue), \(c) \(amount(oldLo))–\(amount(oldHi)) → \(c) \(amount(lo))–\(amount(hi)).")
                } else { details.append("\(metric.uppercased()): comparison unknown; compatible bounds, method or currency missing.") }
            }
        case .dividends:
            guard let cash = try number(row, "cash_amount"), cash > 0, let c = currency(row) else { throw Failure.invalidPayload }
            headline = "Ex-dividend · \(dateText)"
            details.append("Declared cash amount: \(c) \(amount(cash)) per share.")
            if let pay = row["pay_date"] as? String {
                guard let payDate = day(pay), payDate >= date else { throw Failure.invalidPayload }
                details.append("Pay date: \(StockSageCatalystWatch.dateStr(payDate)); not cash received.")
            }
        case .insider:
            if row["record_type"] as? String == "holding" { return nil }
            guard let code = row["transaction_code"] as? String else { throw Failure.invalidPayload }
            guard code == "P" || code == "S" else { return nil }
            // Live Form 4 rows use non_derivative (GILD, 2026-09-07); docs use non-derivative.
            guard let security = row["security_type"] as? String,
                  ["derivative", "non-derivative", "non_derivative"].contains(security) else { throw Failure.invalidPayload }
            guard security != "derivative" else { return nil }
            guard let tx = row["transaction_date"] as? String, let txDate = day(tx), txDate <= date,
                  let shares = try number(row, "transaction_shares"), shares > 0,
                  let owner = text(row, "owner_name"),
                  let form = row["form_type"] as? String, ["4", "4/A"].contains(form) else { throw Failure.invalidPayload }
            if let side = row["transaction_acquired_disposed"] as? String,
               side != (code == "P" ? "A" : "D") {
                throw ["A", "D"].contains(side) ? Failure.conflictingTransactionDirection : .invalidPayload
            }
            headline = "Form \(form) \(code == "P" ? "purchase" : "sale") filed · \(dateText)"
            let price = try number(row, "transaction_price_per_share")
            if let price, price < 0 { throw Failure.invalidPayload }
            details.append("\(owner)\(text(row, "officer_title").map { " (\($0))" } ?? ""): \(amount(shares)) shares on \(StockSageCatalystWatch.dateStr(txDate))\(price.map { " at reported USD \(amount($0))/share" } ?? "; price not supplied").")
            details.append(form == "4/A" ? "Amendment, not an additional transaction." : "One reported transaction; not an aggregate of all insider activity.")
            if let plan = row["aff_10b5_one"], !(plan is NSNull) {
                guard let flag = plan as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw Failure.invalidPayload }
                details.append(flag.boolValue ? "Reported under a Rule 10b5-1 plan." : "No Rule 10b5-1 plan reported in this record.")
            } else { details.append("Rule 10b5-1 plan status not supplied.") }
        }
        return Event(id: id, symbol: symbol, feed: feed, date: date, headline: headline, details: details, link: link)
    }

    private nonisolated static func numberID(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull), !(value is String) else { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue.rounded() == n.doubleValue else { throw Failure.invalidPayload }
        return n.stringValue
    }

    private static func gateKey(_ feed: Feed) -> String { "stocksage.massive.\(feed.rawValue).authenticationUnavailableUntil.v2" }
    private static func available(_ feed: Feed, now: Date, defaults: UserDefaults = .standard) -> Bool {
        StockSageMassiveEarnings.isAvailable(unavailableUntil: StockSageMassiveCredential.denialUntil(gateKey(feed), defaults: defaults), now: now)
    }
    /// One status-only probe per due feed BEFORE the four-wide sweep; nil means HTTP200,
    /// not validated data. Preserve the same safe reason on every skipped symbol.
    static func probe(_ feed: Feed) async -> Failure? {
        if case .failure(let failure) = await get(feed, symbol: "AAPL", now: Date(), limit: 1) { return failure }
        return nil
    }
    static func fetch(_ feed: Feed, symbol: String, now: Date = Date()) async -> Observation {
        let revision = StockSageMassive.credentialRevision()
        var result = await fetch(feed, symbol: symbol, now: now, key: StockSageMassive.apiKey) {
            await get(feed, request: $0, now: Date(), revision: revision)
        }
        result.credentialRevision = revision ?? ""
        return result
    }
    /// Injectable transport keeps the real request/response path testable without credentials or network.
    static func fetch(_ feed: Feed, symbol: String, now: Date, key: String,
                      load: (URLRequest) async -> Result<Data, Failure>) async -> Observation {
        guard var request = request(feed, symbol: symbol, now: now, key: key) else {
            return observation(.failure(.requestUnavailable), feed: feed, symbol: symbol, now: now)
        }
        // ponytail: 10 sequential pages, 100 rows/page, 2MB TOTAL per symbol/feed.
        // Raise only on measured need; a cap/error never publishes a partial or checked-empty result.
        var visited: Set<String> = []
        var bytes = 0
        var best: Event?
        do {
            for pageIndex in 0..<pageLimit {
                guard !Task.isCancelled else { throw Failure.cancelled }
                if let url = request.url?.absoluteString { visited.insert(url) }
                let data = try await load(request).get()
                guard !Task.isCancelled else { throw Failure.cancelled }
                guard data.count <= 2_000_000 - bytes else { throw Failure.responseTooLarge }
                bytes += data.count
                let page = try parsePage(data, feed: feed, symbol: symbol, now: now)
                best = selected([best, page.event].compactMap { $0 }, feed: feed)
                guard let next = page.next else {
                    return Observation(symbol: symbol, feed: feed, checkedAt: now, outcome: .answered, event: best)
                }
                guard let next = nextRequest(next, feed: feed, key: key, pagesLoaded: pageIndex + 1, visited: visited) else {
                    throw Failure.incompleteResponse
                }
                request = next
            }
            throw Failure.incompleteResponse
        } catch {
            return observation(.failure(error as? Failure ?? .invalidPayload), feed: feed, symbol: symbol, now: now)
        }
    }
    nonisolated static func observation(_ response: Result<Data, Failure>, feed: Feed, symbol: String, now: Date) -> Observation {
        do {
            let event = try parse(response.get(), feed: feed, symbol: symbol, now: now)
            return Observation(symbol: symbol, feed: feed, checkedAt: now, outcome: .answered, event: event)
        } catch {
            return Observation(symbol: symbol, feed: feed, checkedAt: now, outcome: .unavailable,
                               event: nil, failure: error as? Failure ?? .invalidPayload)
        }
    }
    private static func get(_ feed: Feed, symbol: String, now: Date, limit: Int = 100) async -> Result<Data, Failure> {
        let revision = StockSageMassive.credentialRevision()
        return await get(feed, request: request(feed, symbol: symbol, now: now, key: StockSageMassive.apiKey, limit: limit), now: now, revision: revision)
    }
    static func get(_ feed: Feed, request: URLRequest?, now: Date, revision: String?, defaults: UserDefaults = .standard,
                    allowed: () -> Bool = { ToolPolicy.isExternalAllowed },
                    transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> Result<Data, Failure> {
        guard allowed() else { return .failure(.externalAccessDisabled) }
        guard !Task.isCancelled, revision == StockSageMassive.credentialRevision(defaults) else { return .failure(.cancelled) }
        guard available(feed, now: now, defaults: defaults) else { return .failure(.cooldown) }
        guard let request else {
            return .failure(.requestUnavailable)
        }
        do {
            let (data, response) = try await (transport ?? { try await session.data(for: $0) })(request)
            guard !Task.isCancelled, revision == StockSageMassive.credentialRevision(defaults) else { return .failure(.cancelled) }
            guard allowed() else { return .failure(.externalAccessDisabled) }
            guard let response = response as? HTTPURLResponse else { return .failure(.transport) }
            if let until = StockSageMassiveEarnings.availabilityOutcome(statusCode: response.statusCode, now: Date()) {
                StockSageMassiveCredential.recordDenial(until, gate: gateKey(feed),
                    revision: revision, defaults: defaults)
            }
            return response.statusCode == 200 ? .success(data) : .failure(.http(response.statusCode))
        } catch {
            if Task.isCancelled { return .failure(.cancelled) }
            return .failure((error as? URLError)?.code == .timedOut ? .timedOut : .transport)
        }
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}

/// Independent versioned cache beside catalyst_records_v1.json; no legacy earnings schema change.
nonisolated struct StockSageCompanyEventCache: Codable {
    var entries: [StockSageMassiveEvents.Observation]
    private static func diskURL() -> URL? {
        StockSageCatalystRecordCache.diskURL()?.deletingLastPathComponent().appendingPathComponent("company_events_v1.json")
    }
    static func load(from url: URL? = nil) -> Self? {
        guard let url = url ?? diskURL(),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_000_000,
              let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(Self.self, from: data),
              cache.entries.count <= 10_000,
              cache.entries.allSatisfy({ record in
                  guard StockSageMassive.covers(record.symbol), record.checkedAt.timeIntervalSince1970.isFinite else { return false }
                  guard let event = record.event else { return true }
                  return record.outcome == .answered && event.symbol == record.symbol && event.feed == record.feed
                      && event.date.timeIntervalSince1970.isFinite && event.id.utf8.count <= 256
                      && event.headline.utf8.count <= 1_024 && event.details.count <= 6
                      && event.details.allSatisfy { $0.utf8.count <= 2_048 }
                      && (event.link == nil || StockSageMassiveEvents.sourceLink(event.link?.absoluteString, feed: event.feed) == event.link)
              }) else { return nil }
        return cache
    }
    @discardableResult func save(to url: URL? = nil) -> Bool {
        guard entries.count <= 10_000, let url = url ?? Self.diskURL(),
              let data = try? JSONEncoder().encode(self), data.count <= 16_000_000 else { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }
}
