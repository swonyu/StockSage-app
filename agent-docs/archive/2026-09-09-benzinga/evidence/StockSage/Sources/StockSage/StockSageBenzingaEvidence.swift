import Foundation
import CoreFoundation
import CryptoKit

/// Massive's nine Benzinga contracts, pinned 2026-09-09; see the scoped handoff.
/// A recent sample for research. None of these types can become an executable quote.
@MainActor
enum StockSageBenzingaEvidence {
    nonisolated static let responseByteLimit = 2_000_000
    nonisolated static let pageLimit = 20
    nonisolated static let retainedLimit = 3

    nonisolated enum Product: String, CaseIterable, Sendable {
        case earnings, guidance, ratings, analystInsights, bullsBears, analysts, firms, consensus, news
        var path: String {
            switch self {
            case .earnings: "/benzinga/v1/earnings"
            case .guidance: "/benzinga/v1/guidance"
            case .ratings: "/benzinga/v1/ratings"
            case .analystInsights: "/benzinga/v1/analyst-insights"
            case .bullsBears: "/benzinga/v1/bulls-bears-say"
            case .analysts: "/benzinga/v1/analysts"
            case .firms: "/benzinga/v1/firms"
            case .consensus: "/benzinga/v1/consensus-ratings"
            case .news: "/benzinga/v2/news"
            }
        }
        var source: String { "Massive/Benzinga \(rawValue)" }
        var isReference: Bool { self == .analysts || self == .firms }
        var cacheSeconds: TimeInterval {
            switch self {
            case .news: 30
            case .consensus: 7_200
            case .analysts, .firms: 86_400
            default: 300
            }
        }
        var caveat: String {
            switch self {
            case .earnings: "Reported figures and estimates are separate; date confirmation does not prove release."
            case .ratings: StockSageMassiveEvents.Feed.ratings.caveat
            case .guidance: StockSageMassiveEvents.Feed.guidance.caveat
            case .consensus: "Aggregated analyst opinions; target currency and source update time are not supplied."
            case .analystInsights: "Attributed analyst opinion; price target is not a quote or app recommendation."
            case .bullsBears: "Benzinga bull/bear arguments are source opinions, not app recommendations."
            case .analysts: "Provider-calculated historical analyst metrics, not verified future performance."
            case .firms: "Reference identity only; firm currency does not establish a rating's currency."
            case .news: "Selected untrusted news text; absence is not evidence that nothing happened."
            }
        }
    }
    nonisolated enum State: String, Sendable { case available, empty, unavailable, partial }
    nonisolated enum Failure: Error, Sendable, Equatable {
        case http(Int), transport, timedOut, cooldown, policyDenied, cancelled, configurationChanged
        case requestUnavailable, invalidPayload, responseTooLarge, notRequested, missingReference
        var message: String {
            switch self {
            case .http(let status): "HTTP \(status)"
            case .transport: "Transport failed"
            case .timedOut: "Request timed out"
            case .cooldown: "Provider cooldown active"
            case .policyDenied: "External access disabled"
            case .cancelled: "Request cancelled"
            case .configurationChanged: "Configuration changed"
            case .requestUnavailable: "Unsupported input or missing configuration"
            case .invalidPayload: "Response failed validation"
            case .responseTooLarge: "Response exceeded 2 MB"
            case .notRequested: "Not checked"
            case .missingReference: "No documented reference ID in retained evidence; not queried"
            }
        }
    }
    nonisolated struct SourceTime: Sendable, Equatable {
        enum Precision: String, Sendable { case day, instant }
        let raw: String
        let value: Date
        let precision: Precision
    }
    nonisolated struct Provenance: Sendable, Equatable {
        let product: Product
        let symbol: String
        let recordID: String
        /// Hash of the original JSON row: revisions remain distinct even if the excerpt is unchanged.
        let revisionID: String
        let eventTime: SourceTime?
        let updatedTime: SourceTime?
        let checkedAt: Date
        var provider: String { "Massive/Benzinga" }
    }
    nonisolated struct Earnings: Sendable, Equatable {
        let fiscalPeriod: String?
        let fiscalYear: Int?
        let dateStatus: String?
        let currency: String?
        let epsMethod: String?
        let revenueMethod: String?
        let actualEPS: Double?
        let estimatedEPS: Double?
        let actualRevenue: Double?
        let estimatedRevenue: Double?
        let epsSurprise: Double?
        let revenueSurprise: Double?
        let notes: String?
        var hasReportedFigures: Bool { actualEPS != nil || actualRevenue != nil }
    }
    nonisolated struct GuidanceRange: Sendable, Equatable {
        let lower: Double?
        let upper: Double?
        let previousLower: Double?
        let previousUpper: Double?
        let estimate: Double?
        let method: String?
        func direction(currency: String?) -> StockSageMassiveEvents.Direction {
            guard currency != nil, ["gaap", "adj", "ffo"].contains(method ?? "") else { return .unknown }
            return StockSageMassiveEvents.direction(lower: lower, upper: upper,
                previousLower: previousLower, previousUpper: previousUpper)
        }
    }
    nonisolated struct Guidance: Sendable, Equatable {
        let fiscalPeriod: String?
        let fiscalYear: Int?
        let currency: String?
        let releaseType: String?
        let eps: GuidanceRange
        let revenue: GuidanceRange
        let notes: String?
    }
    nonisolated struct AnalystOpinion: Sendable, Equatable {
        let analystID: String?
        let firmID: String?
        let ratingID: String?
        let analyst: String?
        let firm: String?
        let rating: String?
        let previousRating: String?
        let action: String?
        let currency: String?
        let priceTarget: Double?
        let previousPriceTarget: Double?
        let adjustedPriceTarget: Double?
        let previousAdjustedPriceTarget: Double?
        let excerpt: String?
    }
    nonisolated struct BullsBears: Sendable, Equatable {
        let bull: String?
        let bear: String?
    }
    nonisolated struct Analyst: Sendable, Equatable {
        let name: String
        let firmID: String?
        let firmName: String?
        let averageReturnPercent: Double?
        let successRatePercent: Double?
        let totalRatings: Int?
    }
    nonisolated struct Firm: Sendable, Equatable {
        let name: String
        let currency: String?
    }
    nonisolated struct Consensus: Sendable, Equatable {
        let rating: String?
        let ratingValue: Double?
        let strongBuy: Int
        let buy: Int
        let hold: Int
        let sell: Int
        let strongSell: Int
        let ratingsContributors: Int
        let targetContributors: Int
        let meanTarget: Double?
        let lowTarget: Double?
        let highTarget: Double?
    }
    nonisolated struct News: Sendable, Equatable {
        let title: String
        let author: String
        let excerpt: String?
        let link: URL?
    }
    nonisolated enum Payload: Sendable, Equatable {
        case earnings(Earnings), guidance(Guidance), rating(AnalystOpinion), insight(AnalystOpinion)
        case bullsBears(BullsBears), analyst(Analyst), firm(Firm), consensus(Consensus), news(News)
        /// Parent may wrap existing Catalyst observations without changing their selection rules.
        case companyEvent(StockSageMassiveEvents.Event)
    }
    nonisolated struct Record: Sendable, Equatable, Identifiable {
        let provenance: Provenance
        let payload: Payload
        let incomplete: Bool
        var id: String { provenance.product.rawValue + ":" + provenance.recordID + ":" + provenance.revisionID }
        var analystID: String? {
            switch payload { case .rating(let v), .insight(let v): v.analystID; default: nil }
        }
        var firmID: String? {
            switch payload {
            case .rating(let v), .insight(let v): v.firmID
            case .analyst(let v): v.firmID
            default: nil
            }
        }
    }
    nonisolated struct Observation: Sendable, Equatable {
        let product: Product
        let symbol: String
        let checkedAt: Date?
        let state: State
        let records: [Record]
        let failure: Failure?
        let rejectedCount: Int
        let omittedCount: Int
        let hasMore: Bool
        var summary: String {
            "\(product.source): \(state.rawValue); \(records.count) retained, \(omittedCount) omitted, "
            + "\(rejectedCount) rejected\(hasMore ? "; more pages not fetched" : ""). "
            + (checkedAt.map { "Checked \($0.ISO8601Format()). " } ?? "")
            + (failure.map { $0.message + ". " } ?? "") + "Recent sample only."
        }
        static func unavailable(_ product: Product, symbol: String, checkedAt: Date? = nil,
                                failure: Failure) -> Self {
            .init(product: product, symbol: symbol.uppercased(), checkedAt: checkedAt, state: .unavailable,
                  records: [], failure: failure, rejectedCount: 0, omittedCount: 0, hasMore: false)
        }
    }
    nonisolated struct Snapshot: Sendable, Equatable {
        let symbol: String
        let capturedAt: Date
        let observations: [Observation]
        init(symbol: String, capturedAt: Date, observations: [Observation]) {
            self.symbol = symbol.uppercased(); self.capturedAt = capturedAt
            self.observations = Product.allCases.map { product in
                observations.first { $0.product == product && $0.symbol == symbol.uppercased() }
                    ?? .unavailable(product, symbol: symbol, failure: .notRequested)
            }
        }
        subscript(_ product: Product) -> Observation { observations[Product.allCases.firstIndex(of: product)!] }
        /// References enrich records by IDs only. A firm's currency is never copied to targets.
        func analyst(for record: Record) -> Analyst? {
            guard let id = record.analystID else { return nil }
            for ref in self[.analysts].records where ref.provenance.recordID == id {
                if case .analyst(let analyst) = ref.payload { return analyst }
            }
            return nil
        }
        func firm(for record: Record) -> Firm? {
            guard let id = record.firmID else { return nil }
            for ref in self[.firms].records where ref.provenance.recordID == id {
                if case .firm(let firm) = ref.payload { return firm }
            }
            return nil
        }
    }

    /// Fixed HTTPS origin and header-only Massive authentication. No caller-controlled URL/filter.
    nonisolated static func request(_ product: Product, symbol: String, referenceID: String? = nil,
                                    key: String) -> URLRequest? {
        guard validSymbol(symbol), !key.isEmpty, key.utf8.count <= 4_096,
              !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              product.isReference ? validID(referenceID) : referenceID == nil else { return nil }
        let symbol = symbol.uppercased()
        var parts = URLComponents(string: StockSageMassive.host + product.path + (product == .consensus ? "/" + symbol : ""))!
        var query = [URLQueryItem(name: "limit", value: String(pageLimit))]
        if product.isReference { query.append(.init(name: "benzinga_id", value: referenceID)) }
        else if product != .consensus {
            query.append(.init(name: product == .news ? "tickers" : "ticker", value: symbol))
            query.append(.init(name: "sort", value: product == .news ? "published.desc" : "last_updated.desc"))
        }
        parts.queryItems = query
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Wrong/missing root results never means empty. Bad rows are independently rejected.
    /// No next_url is retained or followed, so hostile continuations cannot receive credentials.
    nonisolated static func parse(_ data: Data, product: Product, symbol: String,
                                  referenceID: String? = nil, checkedAt: Date) -> Observation {
        func failed(_ failure: Failure) -> Observation {
            .unavailable(product, symbol: symbol, checkedAt: checkedAt, failure: failure)
        }
        guard data.count <= responseByteLimit else { return failed(.responseTooLarge) }
        guard validSymbol(symbol), checkedAt.timeIntervalSince1970.isFinite,
              product.isReference ? validID(referenceID) : referenceID == nil,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", let rows = root["results"] as? [Any] else { return failed(.invalidPayload) }
        var more = false
        if let next = root["next_url"], !(next is NSNull) {
            guard let next = next as? String else { return failed(.invalidPayload) }
            more = !next.isEmpty
        }
        var records: [Record] = [], rejected = 0
        for raw in rows.prefix(pageLimit) {
            do {
                guard let row = raw as? [String: Any] else { throw Failure.invalidPayload }
                let record = try parseRow(row, product: product, symbol: symbol.uppercased(),
                                          referenceID: referenceID, checkedAt: checkedAt)
                if !records.contains(where: { $0.id == record.id }) { records.append(record) }
            } catch { rejected += 1 }
        }
        // Source time remains optional; the local check is never used for sorting source events.
        records.sort {
            let left = $0.provenance.eventTime?.value ?? $0.provenance.updatedTime?.value ?? .distantPast
            let right = $1.provenance.eventTime?.value ?? $1.provenance.updatedTime?.value ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
        let omitted = max(0, records.count - retainedLimit) + max(0, rows.count - pageLimit)
        let retained = Array(records.prefix(retainedLimit))
        let partial = more || omitted > 0 || rejected > 0 || retained.contains(where: \.incomplete)
        let state: State = rows.isEmpty && !more ? .empty : (retained.isEmpty ? .unavailable : (partial ? .partial : .available))
        return .init(product: product, symbol: symbol.uppercased(), checkedAt: checkedAt, state: state,
                     records: retained, failure: state == .unavailable ? .invalidPayload : nil,
                     rejectedCount: rejected, omittedCount: omitted, hasMore: more)
    }

    private nonisolated static func parseRow(_ row: [String: Any], product: Product, symbol: String,
                                            referenceID: String?, checkedAt: Date) throws -> Record {
        if !product.isReference {
            if product == .news {
                guard let tickers = row["tickers"] as? [String], tickers.map({ $0.uppercased() }).contains(symbol) else { throw Failure.invalidPayload }
            } else {
                guard let ticker = row["ticker"] as? String, ticker.uppercased() == symbol else { throw Failure.invalidPayload }
            }
        }
        let id: String
        if product == .consensus { id = symbol }
        else if product == .news {
            guard let number = try integer(row, "benzinga_id"), number >= 0 else { throw Failure.invalidPayload }
            id = String(number)
        } else {
            guard let value = try identifier(row, "benzinga_id") else { throw Failure.invalidPayload }
            id = value
        }
        if product.isReference && id != referenceID { throw Failure.invalidPayload }
        let eventTime: SourceTime?
        switch product {
        case .earnings, .ratings, .guidance, .analystInsights: eventTime = try sourceTime(row, "date", day: true)
        case .news: eventTime = try sourceTime(row, "published", day: false)
        default: eventTime = nil
        }
        let update = product == .consensus ? nil : try sourceTime(row, "last_updated", day: false)
        if product == .news {
            guard let eventTime, eventTime.value <= checkedAt,
                  let update, update.value >= eventTime.value, update.value <= checkedAt else { throw Failure.invalidPayload }
        }
        if let update, update.value > checkedAt { throw Failure.invalidPayload }
        if let date = eventTime, product != .earnings, date.value > checkedAt { throw Failure.invalidPayload }
        if [.earnings, .ratings, .guidance].contains(product), eventTime == nil { throw Failure.invalidPayload }
        let payload: Payload
        var incomplete = false
        switch product {
        case .earnings:
            let status = try text(row, "date_status", limit: 20)
            guard status == nil || ["confirmed", "projected"].contains(status!) else { throw Failure.invalidPayload }
            let eps = try number(row, "actual_eps"), revenue = try nonnegative(row, "actual_revenue")
            // A future calendar row with purported actuals is contradictory, not a released result.
            if let date = eventTime, date.value > checkedAt, eps != nil || revenue != nil { throw Failure.invalidPayload }
            payload = .earnings(.init(fiscalPeriod: try text(row, "fiscal_period", limit: 16),
                fiscalYear: try year(row), dateStatus: status, currency: try currency(row),
                epsMethod: try text(row, "eps_method", limit: 24)?.lowercased(),
                revenueMethod: try text(row, "revenue_method", limit: 24)?.lowercased(),
                actualEPS: eps, estimatedEPS: try number(row, "estimated_eps"), actualRevenue: revenue,
                estimatedRevenue: try nonnegative(row, "estimated_revenue"), epsSurprise: try number(row, "eps_surprise"),
                revenueSurprise: try number(row, "revenue_surprise"), notes: try text(row, "notes")))
        case .guidance:
            payload = .guidance(.init(fiscalPeriod: try text(row, "fiscal_period", limit: 16), fiscalYear: try year(row),
                currency: try currency(row), releaseType: try text(row, "release_type", limit: 32),
                eps: try range(row, metric: "eps"), revenue: try range(row, metric: "revenue"), notes: try text(row, "notes")))
        case .ratings, .analystInsights:
            let opinion = try AnalystOpinion(
                analystID: product == .ratings ? identifier(row, "benzinga_analyst_id") : nil,
                firmID: identifier(row, "benzinga_firm_id"),
                ratingID: product == .analystInsights ? identifier(row, "benzinga_rating_id") : id,
                analyst: product == .ratings ? text(row, "analyst", limit: 120) : nil,
                firm: text(row, "firm", limit: 120), rating: text(row, "rating", limit: 80),
                previousRating: product == .ratings ? text(row, "previous_rating", limit: 80) : nil,
                action: text(row, "rating_action", limit: 80), currency: product == .ratings ? currency(row) : nil,
                priceTarget: positive(row, "price_target"),
                previousPriceTarget: product == .ratings ? positive(row, "previous_price_target") : nil,
                adjustedPriceTarget: product == .ratings ? positive(row, "adjusted_price_target") : nil,
                previousAdjustedPriceTarget: product == .ratings ? positive(row, "previous_adjusted_price_target") : nil,
                excerpt: text(row, product == .ratings ? "notes" : "insight"))
            guard opinion.firm != nil || opinion.analyst != nil || opinion.firmID != nil else { throw Failure.invalidPayload }
            guard opinion.rating != nil || opinion.priceTarget != nil || opinion.excerpt != nil else { throw Failure.invalidPayload }
            payload = product == .ratings ? .rating(opinion) : .insight(opinion)
        case .bullsBears:
            let bull = try text(row, "bull_case"), bear = try text(row, "bear_case")
            guard bull != nil || bear != nil else { throw Failure.invalidPayload }
            incomplete = bull == nil || bear == nil
            payload = .bullsBears(.init(bull: bull, bear: bear))
        case .analysts:
            guard let name = try text(row, "full_name", limit: 120) else { throw Failure.invalidPayload }
            let success = try number(row, "overall_success_rate")
            if let success, !(0...100).contains(success) { throw Failure.invalidPayload }
            payload = .analyst(.init(name: name, firmID: try identifier(row, "benzinga_firm_id"),
                firmName: try text(row, "firm_name", limit: 120), averageReturnPercent: try number(row, "overall_avg_return"),
                successRatePercent: success, totalRatings: try integer(row, "total_ratings")))
        case .firms:
            guard let name = try text(row, "name", limit: 120) else { throw Failure.invalidPayload }
            payload = .firm(.init(name: name, currency: try currency(row)))
        case .consensus:
            let counts = try ["strong_buy_ratings", "buy_ratings", "hold_ratings", "sell_ratings", "strong_sell_ratings",
                              "ratings_contributors", "price_target_contributors"].map { key -> Int in
                guard let count = try integer(row, key) else { throw Failure.invalidPayload }; return count
            }
            guard counts.prefix(5).reduce(0, +) == counts[5] else { throw Failure.invalidPayload }
            let low = try positive(row, "low_price_target"), high = try positive(row, "high_price_target"), mean = try positive(row, "consensus_price_target")
            if let low, let high, low > high { throw Failure.invalidPayload }
            if let mean, let low, mean < low { throw Failure.invalidPayload }
            if let mean, let high, mean > high { throw Failure.invalidPayload }
            if counts[6] == 0, low != nil || high != nil || mean != nil { throw Failure.invalidPayload }
            let value = try number(row, "consensus_rating_value")
            if let value, !(1...5).contains(value) { throw Failure.invalidPayload }
            let rating = try text(row, "consensus_rating", limit: 24)
            if let rating, !["strong_buy", "buy", "hold", "sell", "strong_sell"].contains(rating) { throw Failure.invalidPayload }
            payload = .consensus(.init(rating: rating, ratingValue: value, strongBuy: counts[0], buy: counts[1], hold: counts[2],
                sell: counts[3], strongSell: counts[4], ratingsContributors: counts[5], targetContributors: counts[6],
                meanTarget: mean, lowTarget: low, highTarget: high))
        case .news:
            guard let title = try text(row, "title", limit: 240), let author = try text(row, "author", limit: 120) else { throw Failure.invalidPayload }
            // Preserve a bounded excerpt; markup remains untrusted plain text, never rendered HTML.
            let teaser = try text(row, "teaser"), body = try text(row, "body")
            payload = .news(.init(title: title, author: author, excerpt: teaser ?? body,
                                 link: StockSageNewsService.safeLink(row["url"])))
        }
        let canonical = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        let revision = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        return Record(provenance: .init(product: product, symbol: symbol, recordID: id, revisionID: revision,
                       eventTime: eventTime, updatedTime: update, checkedAt: checkedAt), payload: payload, incomplete: incomplete)
    }

    private nonisolated static func validID(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    private nonisolated static func validSymbol(_ value: String) -> Bool {
        StockSageMassive.covers(value) && value.utf8.count <= 16
            && value.uppercased().utf8.allSatisfy { (65...90).contains($0) }
    }
    private nonisolated static func identifier(_ row: [String: Any], _ key: String) throws -> String? {
        guard let raw = row[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String, validID(value) else { throw Failure.invalidPayload }; return value
    }
    private nonisolated static func text(_ row: [String: Any], _ key: String, limit: Int = 400) throws -> String? {
        guard let raw = row[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else { throw Failure.invalidPayload }
        let clean = StockSageNewsService.boundedText(value, limit: limit - 1)
        return clean.isEmpty ? nil : clean
    }
    private nonisolated static func number(_ row: [String: Any], _ key: String) throws -> Double? {
        guard let raw = row[key], !(raw is NSNull) else { return nil }
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw Failure.invalidPayload }
        return n.doubleValue
    }
    private nonisolated static func nonnegative(_ row: [String: Any], _ key: String) throws -> Double? {
        let n = try number(row, key); if let n, n < 0 { throw Failure.invalidPayload }; return n
    }
    private nonisolated static func positive(_ row: [String: Any], _ key: String) throws -> Double? {
        let n = try number(row, key); if let n, n <= 0 { throw Failure.invalidPayload }; return n
    }
    private nonisolated static func integer(_ row: [String: Any], _ key: String) throws -> Int? {
        guard let n = try number(row, key) else { return nil }
        guard n >= 0, n <= 9_007_199_254_740_991, n.rounded() == n else { throw Failure.invalidPayload }; return Int(n)
    }
    private nonisolated static func year(_ row: [String: Any]) throws -> Int? {
        let y = try integer(row, "fiscal_year"); if let y, !(1900...2200).contains(y) { throw Failure.invalidPayload }; return y
    }
    private nonisolated static func currency(_ row: [String: Any]) throws -> String? {
        guard let raw = row["currency"], !(raw is NSNull) else { return nil }
        guard let c = raw as? String, c.utf8.count == 3, c.utf8.allSatisfy({ (65...90).contains($0) }) else { throw Failure.invalidPayload }; return c
    }
    private nonisolated static func sourceTime(_ row: [String: Any], _ key: String, day: Bool) throws -> SourceTime? {
        guard let raw = row[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String, value.utf8.count <= 64 else { throw Failure.invalidPayload }
        if day {
            guard let date = StockSageMassiveEvents.day(value) else { throw Failure.invalidPayload }
            return .init(raw: value, value: date, precision: .day)
        }
        // Require explicit timezone and full seconds; keep original offset and fractional precision.
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d{1,9})?(Z|[+-]([01]\d|2[0-3]):[0-5]\d)$"#, options: .regularExpression) != nil,
              StockSageMassiveEvents.day(String(value.prefix(10))) != nil else { throw Failure.invalidPayload }
        let format = ISO8601DateFormatter()
        format.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = format.date(from: value) else { throw Failure.invalidPayload }
        return .init(raw: value, value: date, precision: .instant)
    }
    private nonisolated static func range(_ row: [String: Any], metric: String) throws -> GuidanceRange {
        let lo = try number(row, "min_\(metric)_guidance"), hi = try number(row, "max_\(metric)_guidance")
        let oldLo = try number(row, "previous_min_\(metric)_guidance"), oldHi = try number(row, "previous_max_\(metric)_guidance")
        let estimate = try number(row, "estimated_\(metric)_guidance")
        if let lo, let hi, lo > hi { throw Failure.invalidPayload }
        if let oldLo, let oldHi, oldLo > oldHi { throw Failure.invalidPayload }
        if metric == "revenue", [lo, hi, oldLo, oldHi, estimate].compactMap({ $0 }).contains(where: { $0 < 0 }) { throw Failure.invalidPayload }
        return .init(lower: lo, upper: hi, previousLower: oldLo, previousUpper: oldHi, estimate: estimate,
                     method: try text(row, metric + "_method", limit: 24)?.lowercased())
    }
}
