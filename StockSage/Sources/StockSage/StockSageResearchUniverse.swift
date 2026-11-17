import Foundation
import CoreFoundation

/// Research selection only; no model, record store or execution dependency.
nonisolated enum StockSageResearchUniverse {
    typealias Listing = StockSageHorizonResearch.Listing
    enum Failure: LocalizedError, Equatable {
        case unverifiedCalendar
        case sp500Unavailable

        var errorDescription: String? {
            switch self {
            case .unverifiedCalendar:
                "The NASDAQ trading calendar is verified only for 2026. The requested date or prior session is outside this build’s coverage; update the app before researching it."
            case .sp500Unavailable:
                "The S&P 500 reported-constituent list could not be verified. No combined Nasdaq + S&P 500 selection was made. Check web access and retry."
            }
        }
    }
    struct Receipt: Sendable, Equatable {
        let session: String
        let requestedAt: Date
        let returnedCount: Int
        let eligibleCount: Int
        let directoryCount: Int
        let partialSession: Bool
        var fallback = false
        let dollarVolume: [String: Double]
        var sp500: StockSageSP500Constituents.Provenance? = nil
        var summary: String {
            let boundary = dollarVolume.values.min().map {
                " \(dollarVolume.count < eligibleCount ? "Selection cutoff" : "Lowest selected activity"): \($0.formatted(.currency(code: "USD").notation(.compactName))) traded (volume × VWAP)."
            } ?? ""
            return "Activity session: \(session) ET\(partialSession ? " · session-to-date" : "") · \(dollarVolume.count) of \(eligibleCount) eligible selected from \(returnedCount) returned observations."
                + boundary
                + (fallback ? " Prior session used for wider verified coverage." : "")
                + (sp500.map { " S&P 500 reported membership: datasets/DataHub, sourced from Wikipedia; \($0.reportedCount) symbols retrieved \($0.retrievedAt.ISO8601Format()). No official membership effective date is supplied." } ?? "")
        }
        func detail(for symbol: String) -> String? {
            guard let value = dollarVolume[symbol] else { return nil }
            return "Selection activity: \(value.formatted(.currency(code: "USD").notation(.compactName))) traded (volume × VWAP) · \(session) ET. Not a Buy signal."
        }
    }
    struct Selection: Sendable {
        let listings: [Listing]
        var receipt: Receipt?
        init(_ listings: [Listing], receipt: Receipt? = nil) {
            self.listings = listings
            self.receipt = receipt
        }
    }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    private static var formatter: DateFormatter {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = calendar
        value.timeZone = calendar.timeZone
        value.dateFormat = "yyyy-MM-dd"
        value.isLenient = false
        return value
    }
    private static func date(_ session: String) -> Date? {
        guard let value = formatter.date(from: session), formatter.string(from: value) == session else { return nil }
        return value
    }
    private static func previousSession(before day: Date) -> Date? {
        for offset in 1...8 {
            guard let prior = calendar.date(byAdding: .day, value: -offset, to: day),
                  let schedule = StockSageMarketHours.nasdaqDay(at: prior) else { return nil }
            if schedule.trading { return prior }
        }
        return nil
    }
    static func sessions(at now: Date) throws -> (primary: String, previous: String?) {
        guard now.timeIntervalSince1970.isFinite else { throw URLError(.dataNotAllowed) }
        guard let schedule = StockSageMarketHours.nasdaqDay(at: now) else { throw Failure.unverifiedCalendar }
        let today = calendar.startOfDay(for: now)
        if schedule.trading, calendar.component(.hour, from: now) >= 4 {
            return (formatter.string(from: today), previousSession(before: today).map { formatter.string(from: $0) })
        }
        guard let prior = previousSession(before: today) else { throw Failure.unverifiedCalendar }
        return (formatter.string(from: prior), nil) // A closed-day run never walks back again for coverage.
    }

    // https://massive.com/docs/rest/stocks/aggregates/daily-market-summary (2026-09-12).
    static func request(key: String, session: String) -> URLRequest? {
        guard !key.isEmpty, let day = date(session), StockSageMarketHours.nasdaqDay(at: day)?.trading == true,
              let url = URL(string: StockSageMassive.host + "/v2/aggs/grouped/locale/us/market/stocks/\(session)?adjusted=true&include_otc=false") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// A non-Nasdaq listing needs its captured, ticker-specific membership receipt.
    static func eligibleListing(_ listing: Listing, through date: Date) -> Bool {
        listing.active && listing.locale == "us" && listing.market == "stocks" && listing.type == "CS"
            && listing.currency_name?.lowercased() == "usd" && !listing.name.isEmpty
            && StockSageHorizonResearch.validTicker(listing.ticker)
            && (listing.sp500Membership.map { $0.valid(for: listing.ticker, through: date) } ?? true)
            && (listing.primary_exchange == "XNAS"
                || (listing.sp500Membership != nil
                    && ["XNYS", "XASE", "ARCX", "BATS", "BATY", "EDGA", "EDGX"].contains(listing.primary_exchange ?? "")))
    }

    static func select(directory: [Listing], data: Data, session: String, at now: Date,
                       limit: Int = StockSageHorizonResearch.scanLimit,
                       sp500: StockSageSP500Constituents.Snapshot? = nil) throws -> Selection {
        guard now.timeIntervalSince1970.isFinite, let day = date(session), day <= now,
              (1...StockSageHorizonResearch.scanLimit).contains(limit),
              sp500.map({ $0.provenance.valid(through: now) && $0.symbols.count == $0.provenance.reportedCount }) ?? true,
              StockSageMarketHours.nasdaqDay(at: day)?.trading == true,
              directory.count <= 50_000, Set(directory.map(\.ticker)).count == directory.count,
              data.count <= 50_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", root["next_url"] == nil,
              let adjusted = root["adjusted"] as? NSNumber,
              CFGetTypeID(adjusted) == CFBooleanGetTypeID(), adjusted.boolValue,
              let count = StockSageMassive.int64(root["resultsCount"]), (0...50_000).contains(count) else {
            throw URLError(.cannotParseResponse)
        }
        let rows: [[String: Any]]
        if root["results"] == nil, count == 0 { rows = [] }
        else if let values = root["results"] as? [[String: Any]], values.count == count { rows = values }
        else { throw URLError(.cannotParseResponse) }
        let known = Dictionary(uniqueKeysWithValues: directory.map { ($0.ticker, $0) })
        var seen: Set<String> = []
        var ranked: [(listing: Listing, activity: Double)] = []
        for row in rows {
            guard let symbol = row["T"] as? String else { continue }
            guard seen.insert(symbol).inserted else { throw URLError(.cannotParseResponse) }
            guard var listing = known[symbol] else { continue }
            listing.sp500Membership = sp500?.membership(for: symbol)
            guard eligibleListing(listing, through: now),
                  row["otc"] == nil || (row["otc"] as? NSNumber).map({
                      CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue }) == true,
                  let ms = StockSageMassive.int64(row["t"]), ms > 0,
                  let volume = StockSageMassive.finite(row["v"]), volume > 0,
                  let vwap = StockSageMassive.finite(row["vw"]), vwap > 0,
                  (volume * vwap).isFinite else { continue }
            let stamp = Date(timeIntervalSince1970: Double(ms) / 1000)
            guard stamp <= now, calendar.isDate(stamp, inSameDayAs: day) else { continue }
            ranked.append((listing, volume * vwap))
        }
        ranked.sort { $0.activity != $1.activity ? $0.activity > $1.activity : $0.listing.ticker < $1.listing.ticker }
        let chosen = Array(ranked.prefix(limit))
        return Selection(chosen.map(\.listing), receipt: Receipt(session: session, requestedAt: now,
            returnedCount: rows.count, eligibleCount: ranked.count, directoryCount: directory.count,
            partialSession: calendar.isDate(day, inSameDayAs: now),
            dollarVolume: Dictionary(uniqueKeysWithValues: chosen.map { ($0.listing.ticker, $0.activity) }),
            sp500: sp500?.provenance))
    }

    @MainActor static func fetch(key: String, allowed: @MainActor () -> Bool, at now: Date = Date(),
        limit: Int = StockSageHorizonResearch.scanLimit, includeSP500: Bool = false,
        membershipClock: @MainActor () -> Date = Date.init,
        transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> Selection {
        let dates = try sessions(at: now)
        let directory = try await StockSageHorizonResearch.fetchUniverse(key: key, allowed: allowed, transport: transport)
        let membership: StockSageSP500Constituents.Snapshot?
        if includeSP500 {
            do { membership = try await StockSageSP500Constituents.fetch(allowed: allowed, clock: membershipClock, transport: transport) }
            catch {
                try Task.checkCancellation()
                guard allowed() else { throw CancellationError() }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                throw Failure.sp500Unavailable
            }
        } else { membership = nil }
        let selectedAt = max(now, membership?.provenance.retrievedAt ?? now)
        let session = URLSession(configuration: .ephemeral, delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        @MainActor func load(_ day: String) async throws -> Selection {
            try Task.checkCancellation()
            guard allowed() else { throw CancellationError() }
            guard let request = request(key: key, session: day) else { throw URLError(.badURL) }
            let response: (Data, URLResponse)
            if let transport { response = try await transport(request) }
            else { response = try await StockSageHTTP.data(for: request, session: session, maximumBytes: 50_000_000) }
            try Task.checkCancellation()
            guard allowed() else { throw CancellationError() }
            guard (response.1 as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return try select(directory: directory, data: response.0, session: day, at: selectedAt,
                              limit: limit, sp500: membership)
        }
        var selected = try await load(dates.primary)
        if selected.receipt!.eligibleCount < limit, let previous = dates.previous {
            do {
                var prior = try await load(previous)
                if prior.receipt!.eligibleCount > selected.receipt!.eligibleCount {
                    prior.receipt?.fallback = true
                    selected = prior
                }
            } catch {
                // Failed older evidence cannot erase usable current activity, but revocation
                // or cancellation must never turn into a fallback success.
                try Task.checkCancellation()
                guard allowed() else { throw CancellationError() }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                if selected.listings.isEmpty { throw error }
            }
        }
        guard !selected.listings.isEmpty else { throw URLError(.zeroByteResource) }
        return selected
    }
}
