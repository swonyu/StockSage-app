import Foundation
import CoreFoundation
import CryptoKit

/// Pure Massive/Benzinga evidence. No transport, preferences, cache or trading mutations.
/// Contracts: docs/superpowers/specs/2026-09-09-benzinga-evidence-design.md.
enum StockSageBenzinga {
    nonisolated enum Product: String, CaseIterable, Codable, Sendable {
        case earnings, guidance, ratings, analystInsights, bullsBearsSay
        case news, analysts, firms, consensusRatings

        var label: String {
            switch self {
            case .earnings: "Earnings"
            case .guidance: "Guidance"
            case .ratings: "Ratings"
            case .analystInsights: "Insights"
            case .bullsBearsSay: "Bull/Bear"
            case .news: "News"
            case .analysts: "Analysts"
            case .firms: "Firms"
            case .consensusRatings: "Consensus"
            }
        }
        var cacheTTL: TimeInterval {
            switch self {
            case .news: 30
            case .analysts, .firms: 86_400
            case .consensusRatings: 7_200
            default: 300
            }
        }
        fileprivate var metadata: Bool { self == .analysts || self == .firms }
        fileprivate var path: String {
            switch self {
            case .analystInsights: "/benzinga/v1/analyst-insights"
            case .bullsBearsSay: "/benzinga/v1/bulls-bears-say"
            case .news: "/benzinga/v2/news"
            case .consensusRatings: "/benzinga/v1/consensus-ratings"
            default: "/benzinga/v1/" + rawValue
            }
        }
        fileprivate var dateField: String {
            self == .news ? "published" : self == .bullsBearsSay ? "last_updated" : "date"
        }
        fileprivate var sort: String? {
            switch self {
            case .guidance: "date.desc"
            case .bullsBearsSay: "ticker.desc"
            case .news: "published.desc"
            case .analysts: "full_name.asc"
            case .firms: "name.asc"
            case .consensusRatings: nil
            default: "last_updated.desc"
            }
        }
    }

    nonisolated struct Query: Hashable, Codable, Sendable {
        let product: Product
        let subject: String
        let from: String?
        let through: String?
    }

    /// Provider-supplied analyst fields kept separately from presentation prose. `nil` means the
    /// returned record omitted that field; query-level absence remains represented by `Page.status`.
    nonisolated struct AnalystEvidence: Equatable, Codable, Sendable {
        nonisolated enum TargetField: String, Codable, Sendable {
            case ratingCurrent, ratingPrevious, insight, consensus, low, high

            var label: String {
                switch self {
                case .ratingCurrent: "rating original-basis current target"
                case .ratingPrevious: "rating original-basis previous target"
                case .insight: "insight target"
                case .consensus: "consensus target"
                case .low: "consensus low target"
                case .high: "consensus high target"
                }
            }
        }
        nonisolated struct Target: Equatable, Codable, Sendable {
            let field: TargetField
            let amount: Decimal
        }

        let action: String?
        let consensus: String?
        /// Provider event date when that endpoint supplies one. Consensus currently supplies none.
        let date: String?
        /// Target currency only. A firm-directory currency is never copied here.
        let currency: String?
        let targets: [Target]
    }

    nonisolated struct Record: Identifiable, Equatable, Codable, Sendable {
        let id: String
        let vendorID: String?
        let revision: String
        let product: Product
        let symbol: String?
        let source: String
        let date: String?
        let time: String?
        let timeZone: String?
        let published: String?
        let lastUpdated: String?
        let headline: String
        let details: [String]
        let excerpt: String?
        /// Digest of the complete news title/body/link used only for conservative story merging.
        /// It is optional for backwards-compatible captured records.
        var contentFingerprint: String? = nil
        let bullCase: String?
        let bearCase: String?
        let link: URL?
        let analystIDs: [String]
        let firmIDs: [String]
        let ratingIDs: [String]
        /// Optional so captures created before typed analyst fields remain decodable.
        var analystEvidence: AnalystEvidence? = nil

        /// Never substitutes a local check clock or slices a numeric field to fit a prompt.
        var sourceText: String {
            var lines = [source + (symbol.map { " · " + $0 } ?? "") + " · provider claim"]
            if let date {
                lines.append("date " + date + (time.map { " " + $0 + " " + (timeZone ?? "zone unknown") } ?? ""))
            } else if let time { lines.append("time " + time + " " + (timeZone ?? "zone unknown")) }
            if let published { lines.append("published " + published) }
            if let lastUpdated { lines.append("updated " + lastUpdated) }
            if date == nil && published == nil && lastUpdated == nil { lines.append("source time unknown") }
            lines.append(headline)
            lines += details
            if let analystEvidence {
                let fields = [
                    analystEvidence.action.map { "action " + $0 },
                    analystEvidence.consensus.map { "consensus " + $0 },
                    analystEvidence.date.map { "provider date " + $0 },
                    "target currency " + (analystEvidence.currency ?? "not supplied")
                ].compactMap { $0 }
                let targetFields = analystEvidence.targets.map(\.field.label).joined(separator: "; ")
                lines.append("Analyst provenance: same provider record; " + fields.joined(separator: "; ")
                             + (targetFields.isEmpty ? "." : "; target fields " + targetFields + "."))
            }
            if let excerpt { lines.append(excerpt) }
            if product == .bullsBearsSay {
                lines.append("Bull: " + (bullCase ?? "not supplied"))
                lines.append("Bear: " + (bearCase ?? "not supplied"))
            }
            return lines.joined(separator: "\n")
        }
    }

    nonisolated enum Failure: Error, Equatable, Codable, Sendable {
        case invalidQuery, missingCredential, unauthorized, entitlement
        case throttled, transport, timedOut, cancelled, policyDenied
        case obsoleteCredential, malformed, oversized, http(Int)
        case priorAuthenticationRejection(subject: String, checkedAt: Date)

        fileprivate var tag: String {
            switch self {
            case .invalidQuery: "bad query"
            case .missingCredential: "no key"
            case .unauthorized: "auth"
            case .priorAuthenticationRejection(let subject, let checkedAt): "not requested; prior authentication rejection for \(subject) at \(checkedAt.ISO8601Format())"
            case .entitlement: "entitlement"
            case .throttled: "throttled"
            case .transport: "network"
            case .timedOut: "timeout"
            case .cancelled: "cancelled"
            case .policyDenied: "disabled"
            case .obsoleteCredential: "obsolete"
            case .malformed: "malformed"
            case .oversized: "oversized"
            case .http(let code): (100...599).contains(code) ? "HTTP\(code)" : "HTTP error"
            }
        }
    }
    nonisolated enum Status: Equatable, Codable, Sendable {
        case notChecked, answered, partial
        case unavailable(Failure)
    }
    nonisolated struct Page: Equatable, Codable, Sendable {
        let query: Query
        let checkedAt: Date
        let credentialGeneration: String?
        let status: Status
        let records: [Record]
        let excludedCount: Int
        let hasMore: Bool
    }
    nonisolated struct Snapshot: Equatable, Codable, Sendable {
        let symbol: String
        let capturedAt: Date
        let credentialGeneration: String?
        let pages: [Page]
        let omittedRecordCount: Int

        /// Cache pages may contain twenty rows; a persisted capture never keeps >3/product.
        init(symbol: String, capturedAt: Date, credentialGeneration: String?,
             pages: [Page], omittedRecordCount: Int = 0) {
            self.symbol = symbol
            self.capturedAt = capturedAt
            self.credentialGeneration = credentialGeneration
            var counts: [Product: Int] = [:]
            var omitted = max(0, omittedRecordCount)
            self.pages = pages.map { page in
                let room = max(0, 3 - counts[page.query.product, default: 0])
                let records = Array(page.records.prefix(room))
                counts[page.query.product, default: 0] += records.count
                omitted = StockSageBenzinga.addCount(omitted, page.records.count - records.count)
                return Page(query: page.query, checkedAt: page.checkedAt,
                            credentialGeneration: page.credentialGeneration, status: page.status,
                            records: records, excludedCount: page.excludedCount, hasMore: page.hasMore)
            }
            self.omittedRecordCount = omitted
        }
        private enum CodingKeys: String, CodingKey {
            case symbol, capturedAt, credentialGeneration, pages, omittedRecordCount
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let symbol = try values.decode(String.self, forKey: .symbol)
            let capturedAt = try values.decode(Date.self, forKey: .capturedAt)
            let generation = try values.decodeIfPresent(String.self, forKey: .credentialGeneration)
            let pages = try values.decode([Page].self, forKey: .pages)
            let omitted = try values.decodeIfPresent(Int.self, forKey: .omittedRecordCount) ?? 0
            var counts: [Product: Int] = [:]
            guard pages.count <= 13, omitted >= 0, capturedAt.timeIntervalSince1970.isFinite,
                  pages.allSatisfy({ page in
                      counts[page.query.product, default: 0] += page.records.count
                      if case .unavailable(.priorAuthenticationRejection(let subject, let at)) = page.status {
                        guard at.timeIntervalSince1970.isFinite, at.timeIntervalSince1970 > 0,
                              at <= page.checkedAt,
                              StockSageBenzinga.valid(.init(product: page.query.product, subject: subject, from: nil, through: nil)),
                              page.records.isEmpty else { return false }
                    }
                    return counts[page.query.product, default: 0] <= 3
                          && page.excludedCount >= 0 && page.checkedAt.timeIntervalSince1970.isFinite
                          && page.checkedAt <= capturedAt && StockSageBenzinga.valid(page.query)
                          && page.records.allSatisfy { $0.product == page.query.product }
                  }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Invalid Benzinga capture bounds."))
            }
            // Decode exact captured fields. Never trim/coerce persisted historical records.
            self.symbol = symbol
            self.capturedAt = capturedAt
            self.credentialGeneration = generation
            self.pages = pages
            self.omittedRecordCount = omitted
        }
    }
    nonisolated struct Projection: Equatable, Codable, Sendable {
        let statusLines: [String]
        let records: [Record]
        /// Records the capture KEPT but this request did not send: the per-product cap plus any
        /// byte-budget trimming. Deliberately unchanged in meaning — `notEligibleCount` is the
        /// separate bucket that used to be invisible.
        let omittedRecordCount: Int
        /// Returned rows excluded by date, identity, eligibility or value validation.
        /// Individual exclusion reasons are not retained; unchanged ratings can be eligible.
        var notEligibleCount: Int = 0
        /// The share of `omittedRecordCount` caused by the 3-records-per-product storage cap.
        var cappedRecordCount: Int = 0
        /// Optional for decoding historical receipts created before applicability filtering.
        var inapplicableRecordCount: Int? = nil
        var trimmedRecordCount: Int { max(0, omittedRecordCount - cappedRecordCount - (inapplicableRecordCount ?? 0)) }
        var text: String {
            (["Massive/Benzinga sample; unverified claims, not execution prices. Missing is not none."]
             + statusLines + records.map { "[" + $0.id + "] " + $0.sourceText }
             + ["Omitted records: \(omittedRecordCount)",
                "Not eligible at capture: \(notEligibleCount) (eligibility, date or validation; individual reasons not retained); "
                + "capped per product: \(cappedRecordCount); retained records not shown: \(trimmedRecordCount)."]
             + ((inapplicableRecordCount ?? 0) > 0 ? ["Withheld for instrument applicability: \(inapplicableRecordCount ?? 0)."] : []))
                .joined(separator: "\n")
        }
    }

    nonisolated static func request(for query: Query, key: String) -> URLRequest? {
        guard valid(query), !key.isEmpty, key.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              var parts = URLComponents(string: StockSageMassive.host + query.product.path
                + (query.product == .consensusRatings ? "/" + query.subject.uppercased() : "")) else { return nil }
        var items = [URLQueryItem(name: "limit", value: "20")]
        if query.product != .consensusRatings {
            items.append(.init(name: query.product.metadata ? "benzinga_id" : query.product == .news ? "tickers" : "ticker",
                               value: query.product.metadata ? query.subject : query.subject.uppercased()))
        }
        if let sort = query.product.sort { items.append(.init(name: "sort", value: sort)) }
        if let from = query.from { items.append(.init(name: query.product.dateField + ".gte", value: from)) }
        if let through = query.through { items.append(.init(name: query.product.dateField + ".lte", value: through)) }
        parts.queryItems = items
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        return request
    }

    nonisolated static func parse(_ data: Data, query: Query, checkedAt: Date,
                                  credentialGeneration: String?, companyName: String? = nil) -> Page {
        func failed(_ failure: Failure) -> Page {
            Page(query: query, checkedAt: checkedAt, credentialGeneration: credentialGeneration,
                 status: .unavailable(failure), records: [], excludedCount: 0, hasMore: false)
        }
        guard valid(query), checkedAt.timeIntervalSince1970.isFinite else { return failed(.invalidQuery) }
        guard data.count <= 2_000_000 else { return failed(.oversized) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", let rows = root["results"] as? [Any],
              rows.count <= 20 else { return failed(.malformed) }
        var more = false
        if let next = root["next_url"], !(next is NSNull) {
            guard let next = next as? String else { return failed(.malformed) }
            more = !next.isEmpty
        }
        var records: [Record] = [], seen = Set<String>(), excluded = 0
        for value in rows {
            do {
                guard let row = value as? [String: Any],
                      let record = try parseRecord(row, query: query, checkedAt: checkedAt,
                                                   companyName: companyName) else {
                    excluded += 1; continue
                }
                if seen.insert(record.id).inserted { records.append(record) }
            } catch { excluded += 1 }
        }
        return Page(query: query, checkedAt: checkedAt, credentialGeneration: credentialGeneration,
                    status: more || excluded > 0 ? .partial : .answered,
                    records: records, excludedCount: excluded, hasMore: more)
    }

    /// How far back Chat evidence will look for analyst ratings, as opposed to the 7 days that
    /// define a ratings CATALYST.
    ///
    /// Forty-five, not thirty, and the extra fortnight is not padding. Analyst coverage refreshes
    /// around earnings, so a quiet stretch between reports routinely exceeds a month: the owner's
    /// own RKLB capture had its freshest action 31 days old, which a 30-day window would have
    /// missed by a single day — reproducing the very "no analyst evidence" answer this change
    /// exists to fix. Forty-five covers roughly half a reporting cycle.
    ///
    /// The cost is that a reader may see a six-week-old opinion. That is bounded rather than
    /// hidden: every record carries its own date into the prompt, the model is told the evidence
    /// is dated, and the status line now says how many records were skipped for being older.
    nonisolated static let ratingsEvidenceDays = 45

    nonisolated static func projection(_ snapshot: Snapshot, maximumUTF8Bytes: Int, maximumRecords: Int = 27,
                                       excludingProducts: Set<Product> = []) -> Projection? {
        guard maximumUTF8Bytes >= 0, snapshot.capturedAt.timeIntervalSince1970.isFinite else { return nil }
        func usable(_ page: Page) -> Bool {
            guard page.credentialGeneration == snapshot.credentialGeneration,
                  page.checkedAt.timeIntervalSince1970.isFinite, page.checkedAt <= snapshot.capturedAt,
                  valid(page.query),
                  page.query.product.metadata || page.query.subject.uppercased() == snapshot.symbol.uppercased() else { return false }
            return page.status == .answered || page.status == .partial
        }
        let candidates = snapshot.pages.filter { usable($0) && !excludingProducts.contains($0.query.product) }.flatMap { page in
            page.records.filter { record in
                record.product == page.query.product && (record.product.metadata
                    ? record.vendorID == page.query.subject
                    : record.symbol == snapshot.symbol.uppercased())
            }
        }
        let total = snapshot.pages.reduce(0) { addCount($0, $1.records.count) }
        func make(_ selected: [Record]) -> Projection {
            let lines = Product.allCases.map { product -> String in
                if excludingProducts.contains(product) {
                    return product.label + ": not applicable to supplied instrument; corporate records withheld"
                }
                let pages = snapshot.pages.filter { $0.query.product == product }
                let shown = selected.filter { $0.product == product }.count
                let count = candidates.filter { $0.product == product }.count
                let state: String
                if pages.isEmpty { state = "unchecked" }
                else if pages.contains(where: { $0.credentialGeneration != snapshot.credentialGeneration }) { state = "obsolete" }
                else if pages.contains(where: { !$0.checkedAt.timeIntervalSince1970.isFinite || $0.checkedAt > snapshot.capturedAt }) { state = "bad clock" }
                else if pages.contains(where: { !valid($0.query) || (!product.metadata && $0.query.subject.uppercased() != snapshot.symbol.uppercased()) }) { state = "bad query" }
                else if pages.allSatisfy({ $0.status == .notChecked }) { state = "unchecked" }
                else if let failure = pages.compactMap({ page -> Failure? in
                    if case .unavailable(let failure) = page.status { return failure }; return nil
                }).first {
                    state = pages.contains(where: usable) ? "partial" : failure.tag
                } else if pages.contains(where: { $0.status == .partial || $0.status == .notChecked }) { state = "partial" }
                else { state = count == 0 ? "empty" : "ok" }
                return product.label + ": " + state + (count > 0 ? " \(shown)/\(count)" : "")
            }
            return Projection(statusLines: lines, records: selected,
                              omittedRecordCount: addCount(snapshot.omittedRecordCount, max(0, total - selected.count)),
                              notEligibleCount: snapshot.pages.reduce(0) { addCount($0, $1.excludedCount) },
                              cappedRecordCount: snapshot.omittedRecordCount,
                              inapplicableRecordCount: excludingProducts.isEmpty ? nil : snapshot.pages
                                .filter { excludingProducts.contains($0.query.product) }
                                .reduce(0) { addCount($0, $1.records.count) })
        }
        var selected: [Record] = []
        guard make(selected).text.utf8.count <= maximumUTF8Bytes else { return nil }
        func offer(_ record: Record) {
            guard selected.count < maximumRecords, !selected.contains(where: { $0.id == record.id }),
                  selected.filter({ $0.product == record.product }).count < 3 else { return }
            let next = selected + [record]
            if make(next).text.utf8.count <= maximumUTF8Bytes { selected = next }
        }
        // One record/product first; no product's three records monopolize the first pass.
        for index in 0..<3 {
            for product in Product.allCases where !product.metadata {
                let rows = candidates.filter { $0.product == product }
                if index < rows.count { offer(rows[index]) }
            }
        }
        for product in [Product.analysts, .firms] {
            let referenced = Set(selected.flatMap { product == .analysts ? $0.analystIDs : $0.firmIDs })
            for record in candidates where record.product == product {
                if let id = record.vendorID, referenced.contains(id) { offer(record) }
            }
        }
        return make(selected)
    }

    private nonisolated enum Invalid: Error { case row }
    private nonisolated static func addCount(_ first: Int, _ second: Int) -> Int {
        let a = max(0, first), b = max(0, second)
        return a > Int.max - b ? Int.max : a + b
    }
    private nonisolated static func validID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 256
            && text.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
    }
    nonisolated static func valid(_ query: Query) -> Bool {
        if query.product.metadata {
            return validID(query.subject) && query.from == nil && query.through == nil
        }
        guard query.subject.utf8.count <= 32, StockSageMassive.covers(query.subject),
              query.subject.uppercased().utf8.allSatisfy({ (65...90).contains($0) }) else { return false }
        var limits: [Decimal] = []
        for value in [query.from, query.through].compactMap({ $0 }) {
            if query.product == .news || query.product == .bullsBearsSay {
                guard let parsed = instant(value) else { return false }; limits.append(parsed)
            } else {
                guard let parsed = day(value) else { return false }; limits.append(Decimal(parsed.timeIntervalSince1970))
            }
        }
        return limits.count != 2 || limits[0] <= limits[1]
    }
    private nonisolated static func day(_ value: String) -> Date? {
        guard value.utf8.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }
    private nonisolated static func instant(_ value: String) -> Decimal? {
        StockSageNewsService.publicationDate(value)?.instant
            ?? day(value).map { Decimal($0.timeIntervalSince1970) }
    }
    private nonisolated static func inBounds(_ value: String?, query: Query) -> Bool {
        guard query.from != nil || query.through != nil else { return true }
        guard let value, let date = instant(value) else { return false }
        if let lower = query.from.flatMap(instant), date < lower { return false }
        if let upper = query.through.flatMap(instant), date > upper { return false }
        return true
    }
    private nonisolated static func raw(_ row: [String: Any], _ key: String) throws -> String? {
        guard let value = row[key], !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw Invalid.row }
        return string
    }
    private nonisolated static func text(_ row: [String: Any], _ key: String, limit: Int = 120) throws -> String? {
        guard let string = try raw(row, key) else { return nil }
        let bounded = StockSageNewsService.boundedText(string, limit: limit)
        let value = bounded.count <= limit ? bounded
            : StockSageNewsService.boundedText(string, limit: max(0, limit - 1))
        return value.isEmpty ? nil : value
    }
    private nonisolated static func identifier(_ row: [String: Any], _ key: String) throws -> String? {
        guard let value = try raw(row, key) else { return nil }
        guard validID(value) else { throw Invalid.row }
        return value
    }
    private nonisolated static func number(_ row: [String: Any], _ key: String) throws -> Double? {
        guard let value = row[key], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { throw Invalid.row }
        return number.doubleValue
    }
    /// Parses the provider's numeric text directly so typed monetary fields do not pass through `Double`.
    private nonisolated static func decimal(_ row: [String: Any], _ key: String) throws -> Decimal? {
        guard let value = row[key], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              let decimal = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        else { throw Invalid.row }
        return decimal
    }
    private nonisolated static func integer(_ row: [String: Any], _ key: String) throws -> Int? {
        guard let value = try number(row, key) else { return nil }
        // Avoid lossy identifier/count conversion or trapping Int casts.
        guard value >= 0, value <= 9_007_199_254_740_991, value.rounded() == value else { throw Invalid.row }
        return Int(value)
    }
    private nonisolated static func digest(_ row: [String: Any]) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func update(_ row: [String: Any], _ key: String, at now: Date) throws -> String? {
        guard let value = try raw(row, key) else { return nil }
        guard let parsed = StockSageNewsService.publicationDate(value),
              parsed.instant <= Decimal(now.timeIntervalSince1970) else { throw Invalid.row }
        return value
    }

    private nonisolated static func parseRecord(_ row: [String: Any], query: Query, checkedAt: Date,
                                                companyName: String? = nil) throws -> Record? {
        let product = query.product
        let symbol = product.metadata ? nil : query.subject.uppercased()
        if !product.metadata {
            if product == .news {
                guard let symbols = row["tickers"] as? [String],
                      symbols.map({ $0.uppercased() }).contains(symbol!) else { throw Invalid.row }
            } else if product == .consensusRatings {
                // The official consensus ticker is optional; a present mismatch is not.
                if let ticker = try raw(row, "ticker"), ticker.uppercased() != symbol { throw Invalid.row }
            } else {
                guard let ticker = try raw(row, "ticker"), ticker.uppercased() == symbol else { throw Invalid.row }
            }
        }
        let vendorID: String?
        if product == .consensusRatings { vendorID = nil }
        else if product == .news {
            guard let id = try integer(row, "benzinga_id") else { throw Invalid.row }
            vendorID = String(id)
        } else {
            guard let id = try identifier(row, "benzinga_id") else { throw Invalid.row }
            vendorID = id
        }
        if product.metadata && vendorID != query.subject { throw Invalid.row }
        let revision = try digest(row)
        let localID = try digest(["subject": query.subject.uppercased(), "from": query.from ?? "", "through": query.through ?? ""])
        let id = product.rawValue + ":" + (vendorID ?? "local-" + localID) + ":" + revision
        let date: String?
        if [.earnings, .guidance, .ratings, .analystInsights].contains(product) {
            guard let value = try raw(row, "date"), let parsed = day(value),
                  product == .earnings || parsed <= checkedAt else { throw Invalid.row }
            date = value
        } else { date = nil }
        let time = date == nil ? nil : try raw(row, "time")
        if let time, time.range(of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$"#, options: .regularExpression) == nil { throw Invalid.row }
        let updated = product == .consensusRatings ? nil : try update(row, "last_updated", at: checkedAt)
        let published = product == .news ? try update(row, "published", at: checkedAt) : nil
        let clock = product == .news ? published : product == .bullsBearsSay ? updated : date
        if product != .consensusRatings && !inBounds(clock, query: query) { throw Invalid.row }
        let analystIDs = try identifier(row, "benzinga_analyst_id").map { [$0] } ?? []
        let firmIDs = try identifier(row, "benzinga_firm_id").map { [$0] } ?? []
        let ratingIDs = try identifier(row, "benzinga_rating_id").map { [$0] } ?? []
        var headline = product.label, details: [String] = []
        var excerpt: String?, contentFingerprint: String?, bull: String?, bear: String?, link: URL?
        var analystEvidence: AnalystEvidence?
        let currency = try raw(row, "currency")
        if let currency, currency.utf8.count != 3 || !currency.utf8.allSatisfy({ (65...90).contains($0) }) { throw Invalid.row }
        func fields(_ names: [(String, String)]) throws {
            for (key, label) in names {
                if let value = try number(row, key) { details.append(label + ": " + String(value)) }
            }
        }
        // A negative surprise is a legitimate miss; a negative revenue amount is not.
        if product == .earnings {
            for key in ["actual_revenue", "estimated_revenue", "previous_revenue"] {
                if let value = try number(row, key), value < 0 { throw Invalid.row }
            }
        }
        if product == .guidance, let value = try number(row, "estimated_revenue_guidance"), value < 0 { throw Invalid.row }
        let targets = product == .consensusRatings
            ? ["consensus_price_target", "low_price_target", "high_price_target"]
            : product == .analystInsights ? ["price_target"] : []
        for key in targets {
            if let value = try number(row, key), value <= 0 { throw Invalid.row }
        }
        if product == .consensusRatings,
           let low = try number(row, "low_price_target"), let high = try number(row, "high_price_target"),
           low > high { throw Invalid.row }
        switch product {
        case .earnings:
            let actualEPS = try number(row, "actual_eps"), actualRevenue = try number(row, "actual_revenue")
            let hasActual = actualEPS != nil || actualRevenue != nil
            if hasActual, let date, let event = day(date), event > checkedAt { throw Invalid.row }
            headline = hasActual ? "Reported earnings" : "Earnings schedule; results not supplied"
            let status = try raw(row, "date_status")
            if let status, status != "confirmed" && status != "projected" { throw Invalid.row }
            details.append("Schedule: " + (status ?? "confirmation unknown") + "; not a beat claim.")
            let period = try text(row, "fiscal_period", limit: 12) ?? "unknown"
            let year = try integer(row, "fiscal_year").map { String($0) } ?? "unknown"
            details.append("Fiscal: " + period + " " + year + "; currency " + (currency ?? "unknown"))
            details.append("EPS basis: " + (try text(row, "eps_method") ?? "unknown")
                           + "; revenue basis: " + (try text(row, "revenue_method") ?? "unknown"))
            try fields([("actual_eps", "Actual EPS"), ("actual_revenue", "Actual revenue"),
                        ("estimated_eps", "Estimated EPS"), ("estimated_revenue", "Estimated revenue"),
                        ("previous_eps", "Previous EPS"), ("previous_revenue", "Previous revenue"),
                        ("eps_surprise", "EPS surprise"), ("eps_surprise_percent", "EPS surprise %"),
                        ("revenue_surprise", "Revenue surprise"), ("revenue_surprise_percent", "Revenue surprise %")])
        case .guidance, .ratings:
            let feed: StockSageMassiveEvents.Feed = product == .ratings ? .ratings : .guidance
            let envelope = try JSONSerialization.data(withJSONObject: ["status": "OK", "results": [row]])
            // Chat EVIDENCE, not a catalyst. The feed's 7-day window and its change-only rule exist
            // so Catalysts surfaces things that just happened; borrowing them here meant a symbol
            // with no rating action in a week produced zero analyst evidence and a disclosure that
            // read like missing data. Ratings evidence therefore uses ratingsEvidenceDays and keeps
            // "maintains"/"reiterates" rows, which carry their own date into the prompt so the
            // model can see they are weeks old. Guidance keeps the feed's own window: it is
            // genuinely an event, not a standing opinion.
            let event = try StockSageMassiveEvents.parse(
                envelope, feed: feed, symbol: symbol!, now: checkedAt,
                windowDays: product == .ratings ? StockSageBenzinga.ratingsEvidenceDays : nil,
                requireMateriality: product != .ratings)
            guard let event else { return nil }
            headline = event.headline
            details = event.details
            link = event.link
            details.append(feed.caveat)
            if product == .ratings {
                let targets = [
                    try decimal(row, "price_target").map { AnalystEvidence.Target(field: .ratingCurrent, amount: $0) },
                    try decimal(row, "previous_price_target").map { AnalystEvidence.Target(field: .ratingPrevious, amount: $0) }
                ].compactMap { $0 }
                analystEvidence = AnalystEvidence(action: try text(row, "rating_action"), consensus: nil,
                                                   date: date, currency: currency, targets: targets)
            }
            if product == .guidance {
                try fields([("estimated_eps_guidance", "Analyst EPS estimate"), ("estimated_revenue_guidance", "Analyst revenue estimate")])
            }
        case .analystInsights:
            headline = "Analyst insight"
            excerpt = try text(row, "insight", limit: 400)
            guard excerpt != nil else { throw Invalid.row }
            if let firm = try text(row, "firm") { details.append("Firm: " + firm) }
            if let rating = try text(row, "rating") { details.append("Rating: " + rating) }
            let action = try text(row, "rating_action")
            if let action { details.append("Action: " + action) }
            try fields([("price_target", "Analyst target; currency " + (currency ?? "unknown"))])
            let targets = try decimal(row, "price_target").map {
                AnalystEvidence.Target(field: .insight, amount: $0)
            }.map { [$0] } ?? []
            analystEvidence = AnalystEvidence(action: action, consensus: nil, date: date,
                                               currency: currency, targets: targets)
        case .bullsBearsSay:
            headline = "Bull and bear cases"
            bull = try text(row, "bull_case", limit: 400)
            bear = try text(row, "bear_case", limit: 400)
            guard bull != nil || bear != nil else { throw Invalid.row }
        case .news:
            guard let rawTitle = try raw(row, "title"),
                  let rawAuthor = try raw(row, "author"), published != nil, updated != nil,
                  let url = try raw(row, "url"), !url.isEmpty else { throw Invalid.row }
            let title = StockSageNewsService.boundedText(
                StockSageNewsService.normalizedNewsText(rawTitle), limit: 240)
            let author = StockSageNewsService.boundedText(
                StockSageNewsService.normalizedNewsText(rawAuthor), limit: 120)
            guard !title.isEmpty, !author.isEmpty else { throw Invalid.row }
            headline = title
            details = ["Author: " + author]
            link = StockSageNewsService.safeLink(url)
            let body = try raw(row, "body")
            let teaser = try raw(row, "teaser")
            let rowCompanyName = companyName ?? (row["company_name"] as? String)
                ?? (row["companyName"] as? String) ?? (row["company"] as? String)
            if let body {
                let selected = StockSageNewsService.selectNewsPassage(from: body, symbol: symbol,
                                                                       companyName: rowCompanyName, limit: 400)
                excerpt = selected.isEmpty ? nil : selected
            }
            if excerpt == nil, let teaser {
                let selected = StockSageNewsService.selectNewsPassage(from: teaser, symbol: symbol,
                                                                       companyName: rowCompanyName, limit: 400)
                excerpt = selected.isEmpty ? nil : selected
            }
        case .analysts:
            headline = try text(row, "full_name") ?? "Analyst name not supplied"
            if let firm = try text(row, "firm_name") { details.append("Affiliation: " + firm) }
            details.append("Vendor statistics; not independently validated.")
            try fields([("overall_avg_return", "Vendor average return"), ("overall_avg_return_percentile", "Return percentile"),
                        ("overall_success_rate", "Vendor success rate"), ("smart_score", "Vendor smart score"),
                        ("total_ratings", "Total ratings"), ("total_ratings_percentile", "Ratings percentile")])
        case .firms:
            headline = try text(row, "name") ?? "Firm name not supplied"
            if let currency { details.append("Firm currency: " + currency + "; not target denomination.") }
        case .consensusRatings:
            headline = "Analyst consensus; " + (query.from == nil && query.through == nil ? "all-history window" : "requested ratings window")
            if let from = query.from { details.append("Ratings from: " + from) }
            if let through = query.through { details.append("Ratings through: " + through) }
            for (key, label) in [("strong_buy_ratings", "Strong buy"), ("buy_ratings", "Buy"),
                                 ("hold_ratings", "Hold"), ("sell_ratings", "Sell"),
                                 ("strong_sell_ratings", "Strong sell"),
                                 ("ratings_contributors", "Rating contributors"), ("price_target_contributors", "Target contributors")] {
                guard let count = try integer(row, key) else { throw Invalid.row }
                details.append(label + ": " + String(count))
            }
            if let value = try number(row, "consensus_rating_value"), !(1...5).contains(value) { throw Invalid.row }
            let consensus = try text(row, "consensus_rating")
            if let consensus { details.append("Consensus: " + consensus) }
            try fields([("consensus_rating_value", "Rating value"),
                        ("consensus_price_target", "Consensus target; currency unknown"),
                        ("low_price_target", "Low target; currency unknown"), ("high_price_target", "High target; currency unknown")])
            let targets = [
                try decimal(row, "consensus_price_target").map { AnalystEvidence.Target(field: .consensus, amount: $0) },
                try decimal(row, "low_price_target").map { AnalystEvidence.Target(field: .low, amount: $0) },
                try decimal(row, "high_price_target").map { AnalystEvidence.Target(field: .high, amount: $0) }
            ].compactMap { $0 }
            analystEvidence = AnalystEvidence(action: nil, consensus: consensus, date: nil,
                                               currency: nil, targets: targets)
        }
        if [.earnings, .guidance, .ratings].contains(product) {
            excerpt = try text(row, "notes", limit: 400)
        }
        if product == .news {
            let body = try raw(row, "body") ?? ""
            let fullContent = StockSageNewsService.normalizedNewsText(body).isEmpty
                ? (try raw(row, "teaser") ?? "") : body
            contentFingerprint = StockSageNewsService.newsStoryFingerprint(title: try raw(row, "title") ?? headline, content: fullContent,
                                                                            link: try raw(row, "url"))
        }
        return Record(id: id, vendorID: vendorID, revision: revision, product: product,
                      symbol: symbol, source: "Massive/Benzinga " + product.label,
                      date: date, time: time, timeZone: time == nil ? nil : product == .ratings ? "UTC" : product == .earnings ? "EST" : nil,
                      published: published, lastUpdated: updated, headline: headline, details: details,
                      excerpt: excerpt, contentFingerprint: contentFingerprint, bullCase: bull, bearCase: bear, link: link,
                      analystIDs: analystIDs, firmIDs: firmIDs, ratingIDs: ratingIDs,
                      analystEvidence: analystEvidence)
    }
}
