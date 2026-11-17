import Foundation
import CoreFoundation

/// Dated accounting evidence, never an intraday signal or a qualification/ranking rule.
/// Massive v1 ratios are provider calculations. Statement amounts have no currency/scale tag in
/// v1, so cross-statement returns use the separately tagged SEC annual calculation instead.
/// Contracts: massive.com/docs/rest/stocks/fundamentals/{ratios,income-statements,balance-sheets,cash-flow-statements}
/// and massive.com/knowledge-base/article/what-fields-can-i-expect-from-massives-financials-api.
nonisolated enum StockSageFundamentals {
    static let maximumBytes = 1_048_576
    static let statementUnit = "provider reporting units (currency/scale not supplied)"
    private static let accountingNote = "Reported accounting is not adjusted for one-offs or commodity cycles; independently verified sector-peer comparisons are unavailable. Unreported statement concepts may be normalized to zero; zero is not proof of an absent expense or one-off. These dated measures are not intraday timing signals or return forecasts. Aggregate insider ownership is not calculated; float and bounded insider transactions do not establish insider ownership percentage."

    struct Input: Codable, Sendable, Equatable {
        let name: String
        let value: Double
        let unit: String
        let period: String
        let sourceURL: String
    }
    struct Metric: Codable, Sendable, Equatable {
        let key: String
        let label: String
        let value: Double?
        let unit: String
        let origin: String
        let formula: String
        let period: String
        let sourceURL: String
        var inputs: [Input] = []
        let note: String

        var displayValue: String {
            guard let value, value.isFinite else { return "Unavailable" }
            if unit == "fraction" {
                guard (value * 100).isFinite else { return "Unavailable" }
                return String(format: "%.2f%%", locale: Locale(identifier: "en_US_POSIX"), value * 100)
            }
            return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) + (unit == "multiple" ? "×" : " \(unit)")
        }
    }
    struct Source: Codable, Sendable, Equatable {
        let name: String
        let url: String
        let status: String
        let note: String
        let recordCount: Int
        var cik: String? = nil
    }
    struct Statement: Codable, Sendable, Equatable {
        let kind: String
        let timeframe: String
        let periodEnd: String
        let filingDate: String
        let fiscalYear: Int
        let fiscalQuarter: Int
        let cik: String?
        let amounts: [String: Double]
        let unit: String
        let sourceURL: String
    }
    struct Snapshot: Codable, Sendable, Equatable {
        let symbol: String
        let asOf: Date
        let retrievedAt: Date
        var providerRatios: [Metric]
        var calculated: [Metric]
        var statements: [Statement]
        var sources: [Source]
        var flags: [String]
        var notes: [String]

        init(symbol: String, asOf: Date, retrievedAt: Date, providerRatios: [Metric] = [],
             calculated: [Metric] = [], statements: [Statement] = [], sources: [Source] = [],
             flags: [String] = [], notes: [String] = []) {
            self.symbol = symbol; self.asOf = asOf; self.retrievedAt = retrievedAt
            self.providerRatios = providerRatios; self.calculated = calculated; self.statements = statements
            self.sources = sources; self.flags = flags; self.notes = notes
        }
        var metrics: [Metric] { providerRatios + calculated }
        var facts: [StockSageAIAssessment.EvidenceFact] {
            let unavailable = metrics.filter { $0.value == nil }.map(\.label).joined(separator: ", ")
            let summary = metrics.prefix(8).map { "\($0.label): \($0.displayValue) (\($0.origin); \($0.period))" }.joined(separator: "; ")
            var result: [StockSageAIAssessment.EvidenceFact] = [.init(key: "fundamentals.coverage",
                text: "\(symbol) company-quality coverage as of \(StockSageFundamentals.day(asOf)): \(metrics.filter { $0.value != nil }.count)/\(metrics.count) ratio slots available. Missing ratios: \(unavailable.isEmpty ? "none" : unavailable). \(summary). \(Self.coverageNote)",
                required: true, availability: .available, factClass: .coverageGap,
                source: "Captured Massive financials and SEC accounting evidence", observedAt: retrievedAt)]
            for metric in metrics.prefix(8) {
                result.append(.init(key: "fundamentals.\(metric.key)",
                    text: "\(symbol) \(metric.label): \(metric.displayValue). \(metric.origin); \(metric.period). Formula: \(metric.formula). \(metric.note)",
                    required: false, availability: metric.value == nil ? .missing : .available,
                    factClass: .fundamental, source: metric.sourceURL, observedAt: retrievedAt))
            }
            if !flags.isEmpty {
                result.append(.init(key: "fundamentals.accountingFlags", text: flags.prefix(4).joined(separator: " "),
                    required: false, availability: .available, factClass: .risk,
                    source: "Massive reported financial statements", observedAt: retrievedAt))
            }
            return result
        }
        private static var coverageNote: String { StockSageFundamentals.accountingNote }
    }

    enum Endpoint: String, CaseIterable, Sendable {
        case ratios, income = "income-statements", balance = "balance-sheets", cash = "cash-flow-statements"
        var url: String { StockSageMassive.host + "/stocks/financials/v1/" + rawValue }
        var label: String { "Massive " + rawValue.replacingOccurrences(of: "-", with: " ") }
        var limit: Int { self == .balance ? 16 : 1 }
    }
    struct Section: Sendable {
        var ratios: [Metric] = []
        var statements: [Statement] = []
        let source: Source
    }

    /// Four bounded v1 reads, then at most one tagged SEC company-facts read when v1 supplies a
    /// consistent issuer CIK. All responses belong to one captured credential/policy generation.
    static func collect(symbol: String, asOf: Date, access: StockSageMassive.Access = .init(),
                        transport: StockSageMassive.Transport? = nil,
                        secTransport: StockSageDisclosureService.Transport? = nil,
                        clock: @Sendable () -> Date = Date.init) async -> Snapshot {
        let captured = access.capture()
        let initial = clock()
        guard validSymbol(symbol), validDate(asOf), validDate(initial), asOf <= initial,
              !captured.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              captured.isCurrent() else {
            return unavailable(symbol: symbol, asOf: asOf, retrievedAt: validDate(initial) ? initial : asOf,
                               reason: "Financial collection unavailable: invalid capture, missing credentials, denied access or cancelled work.")
        }
        let sections = await withTaskGroup(of: (Endpoint, Section).self) { group in
            for endpoint in Endpoint.allCases {
                group.addTask {
                    let section = await fetch(endpoint, symbol: symbol, asOf: asOf, key: captured.key,
                                              allowed: captured.isCurrent, transport: transport)
                    return (endpoint, section)
                }
            }
            var result: [Endpoint: Section] = [:]
            for await (endpoint, section) in group { result[endpoint] = section }
            return result
        }
        guard captured.isCurrent() else {
            return unavailable(symbol: symbol, asOf: asOf, retrievedAt: clock(),
                               reason: "Financial collection discarded after cancellation or access changed.")
        }
        let ordered = Endpoint.allCases.compactMap { sections[$0] }
        var snapshot = Snapshot(symbol: symbol, asOf: asOf, retrievedAt: clock(),
            providerRatios: sections[.ratios]?.ratios.isEmpty == false ? sections[.ratios]!.ratios : missingRatios(reason: sections[.ratios]?.source.note ?? "Ratio source unavailable."),
            calculated: missingReturns(reason: "Massive v1 does not supply currency/scale tags for cross-statement calculations; tagged SEC annual inputs are required."),
            statements: ordered.flatMap(\.statements), sources: ordered.map(\.source),
            notes: [accountingNote, "Provider filing dates describe the most recent filing containing the data, which can include restatements. Date-only disclosure metadata cannot prove publication earlier within the capture day. Latest-only provider ratios are not a historical price reconstruction."])
        let ciks = Set(snapshot.sources.compactMap(\.cik))
        if ciks.count > 1 {
            return unavailable(symbol: symbol, asOf: asOf, retrievedAt: clock(),
                               reason: "Financial sources disagree on the issuer CIK; no cross-issuer evidence was accepted.")
        }
        snapshot.flags = accountingFlags(snapshot.statements)
        if let cik = ciks.first {
            let sec = await StockSageSECFundamentals.collect(for: symbol, expectedCIK: cik,
                transport: secTransport ?? StockSageDisclosureService.transport,
                allowed: captured.isCurrent, now: asOf)
            guard captured.isCurrent() else {
                return unavailable(symbol: symbol, asOf: asOf, retrievedAt: clock(),
                                   reason: "Financial collection discarded after cancellation or access changed.")
            }
            snapshot.calculated = sec.calculated
            snapshot.sources += sec.sources
            snapshot.notes += sec.notes
        } else {
            snapshot.sources.append(.init(name: "SEC annual company facts", url: "https://data.sec.gov/api/xbrl/companyfacts/",
                status: "unavailable", note: "No unambiguous provider issuer CIK was supplied; no SEC company-facts request was made.", recordCount: 0))
        }
        let finished = clock()
        guard validDate(finished), finished >= asOf else {
            return unavailable(symbol: symbol, asOf: asOf, retrievedAt: initial, reason: "Financial retrieval clock is invalid.")
        }
        return Snapshot(symbol: snapshot.symbol, asOf: snapshot.asOf, retrievedAt: finished,
            providerRatios: snapshot.providerRatios, calculated: snapshot.calculated, statements: snapshot.statements,
            sources: snapshot.sources, flags: snapshot.flags, notes: snapshot.notes)
    }

    private static func fetch(_ endpoint: Endpoint, symbol: String, asOf: Date, key: String,
                              allowed: @Sendable () -> Bool, transport: StockSageMassive.Transport?) async -> Section {
        func failed(_ status: String, _ note: String) -> Section {
            .init(source: .init(name: endpoint.label, url: endpoint.url, status: status, note: note, recordCount: 0))
        }
        guard allowed(), !Task.isCancelled else { return failed("cancelled", "Collection cancelled or access changed.") }
        var components = URLComponents(string: endpoint.url)!
        components.queryItems = [.init(name: endpoint == .ratios ? "ticker" : "tickers", value: symbol),
                                 .init(name: "limit", value: String(endpoint.limit))]
        if endpoint != .ratios {
            components.queryItems! += [.init(name: "period_end.lte", value: day(asOf)),
                                      .init(name: "filing_date.lte", value: day(asOf)),
                                      .init(name: "sort", value: "period_end.desc")]
            if endpoint != .balance { components.queryItems!.append(.init(name: "timeframe", value: "trailing_twelve_months")) }
        }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await StockSageMassive.response(for: request, maximumBytes: maximumBytes, transport: transport)
            guard allowed(), !Task.isCancelled else { return failed("cancelled", "Collection cancelled or access changed.") }
            guard response.statusCode == 200 else {
                return failed("http\(response.statusCode)", "Financial endpoint returned HTTP \(response.statusCode); this is missing evidence, not a negative company finding.")
            }
            return try parse(data, endpoint: endpoint, symbol: symbol, asOf: asOf)
        } catch {
            return failed(Task.isCancelled || !allowed() ? "cancelled" : "unavailable",
                          "Financial endpoint unavailable or returned invalid, oversized, mismatched or undated evidence.")
        }
    }

    /// Pure parser also validates fixtures and injected transport responses. Unknown provider fields
    /// are ignored; consumed fields must have their documented numeric/string shape.
    static func parse(_ data: Data, endpoint: Endpoint, symbol: String, asOf: Date) throws -> Section {
        guard validSymbol(symbol), validDate(asOf), !data.isEmpty, data.count <= maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "OK", let rows = root["results"] as? [[String: Any]],
              rows.count <= endpoint.limit else { throw URLError(.cannotParseResponse) }
        if let count = try number(root, "count"), count != Double(rows.count) { throw URLError(.cannotParseResponse) }
        if rows.isEmpty {
            return .init(source: .init(name: endpoint.label, url: endpoint.url, status: "missing",
                note: "No matching dated records were returned; absence is not evidence of financial health.", recordCount: 0))
        }
        let ciks = try Set(rows.compactMap { try cik($0["cik"]) })
        guard ciks.count <= 1 else { throw URLError(.cannotParseResponse) }
        var source = Source(name: endpoint.label, url: endpoint.url, status: "available",
            note: root["next_url"] == nil ? "Dated provider records captured." : "Only the bounded requested page was captured; earlier history was not fetched.",
            recordCount: rows.count, cik: ciks.first)
        if endpoint == .ratios { return .init(ratios: try parseRatio(rows[0], symbol: symbol, asOf: asOf), source: source) }
        var statements: [Statement] = [], identities: [String: Statement] = [:], duplicateCount = 0
        for row in rows {
            guard let tickers = row["tickers"] as? [String], tickers.contains(symbol), tickers.count <= 100,
                  let end = row["period_end"] as? String, date(end) != nil, end <= day(asOf),
                  let filed = row["filing_date"] as? String, date(filed) != nil, end <= filed, filed <= day(asOf),
                  let timeframe = row["timeframe"] as? String,
                  (endpoint == .balance ? ["quarterly", "annual"].contains(timeframe) : timeframe == "trailing_twelve_months"),
                  let year = try number(row, "fiscal_year"), year.rounded() == year, (1900...2200).contains(year),
                  let quarter = try number(row, "fiscal_quarter"), quarter.rounded() == quarter, (1...4).contains(quarter) else { throw URLError(.cannotParseResponse) }
            var amounts: [String: Double] = [:]
            for field in fields(endpoint) { if let value = try number(row, field) { amounts[field] = value } }
            let statement = Statement(kind: endpoint.rawValue, timeframe: timeframe, periodEnd: end, filingDate: filed,
                fiscalYear: Int(year), fiscalQuarter: Int(quarter), cik: try cik(row["cik"]), amounts: amounts,
                unit: statementUnit, sourceURL: endpoint.url)
            let identity = "\(end)|\(filed)|\(timeframe)"
            if let previous = identities[identity] {
                guard previous == statement else { throw URLError(.cannotParseResponse) }
                duplicateCount += 1
            } else { identities[identity] = statement; statements.append(statement) }
        }
        if duplicateCount > 0 {
            source = Source(name: source.name, url: source.url, status: source.status,
                note: source.note + " \(duplicateCount) duplicate rows with identical consumed fields were deduplicated; \(statements.count) distinct statements retained.",
                recordCount: source.recordCount, cik: source.cik)
        }
        return .init(statements: statements, source: source)
    }

    /// Shared with the manual screener: no request or credential access, exact requested issuer.
    static func parseRatio(_ row: [String: Any], symbol: String, asOf: Date) throws -> [Metric] {
        guard validSymbol(symbol), validDate(asOf), row["ticker"] as? String == symbol,
              let observed = row["date"] as? String, date(observed) != nil, observed <= day(asOf) else { throw URLError(.cannotParseResponse) }
        _ = try cik(row["cik"])
        let eps = try number(row, "earnings_per_share")
        let price = try number(row, "price")
        return try ratioDefinitions.map { definition in
            var value = try number(row, definition.key)
            var note = value == nil ? "The provider did not return this ratio; missing is not zero." : "Provider-calculated, not an app-adjusted measure; underlying ratio denominator amounts are not supplied in this response."
            if let supplied = value {
                guard definition.unit != "fraction" || (supplied * 100).isFinite else { throw URLError(.cannotParseResponse) }
                if (["price_to_earnings", "price_to_sales", "price_to_book"].contains(definition.key) && supplied <= 0)
                    || (definition.key == "debt_to_equity" && supplied < 0)
                    || (definition.key == "price_to_earnings" && eps != nil && eps! <= 0)
                    || (price != nil && price! <= 0 && definition.key.hasPrefix("price_to_")) {
                    value = nil; note = "Not meaningful: non-positive valuation denominator/price or an invalid leverage ratio."
                }
            }
            let inputs: [Input] = definition.key == "price_to_earnings" ? [
                price.map { Input(name: "provider ratio price", value: $0, unit: "provider price units", period: observed, sourceURL: Endpoint.ratios.url) },
                eps.map { Input(name: "provider point-in-time converted-share EPS (not reported basic/diluted EPS)", value: $0, unit: "provider price units per share", period: "TTM at \(observed)", sourceURL: Endpoint.ratios.url) }
            ].compactMap { $0 } : []
            return Metric(key: definition.key, label: definition.label, value: value, unit: definition.unit,
                origin: "Massive provider ratio", formula: definition.formula, period: "Provider TTM/latest balance basis; price date \(observed)",
                sourceURL: Endpoint.ratios.url, inputs: inputs, note: note)
        }
    }

    private static let ratioDefinitions: [(key: String, label: String, unit: String, formula: String)] = [
        ("price_to_earnings", "P/E", "multiple", "provider price / positive TTM point-in-time converted-share EPS"),
        ("price_to_sales", "P/S", "multiple", "provider price / revenue per share"),
        ("price_to_book", "P/B", "multiple", "provider price / book value per share"),
        ("return_on_assets", "ROA", "fraction", "provider net income / total assets"),
        ("return_on_equity", "ROE", "fraction", "provider net income / total shareholders' equity"),
        ("debt_to_equity", "Debt/equity", "multiple", "provider (current debt + long-term debt) / total shareholders' equity")
    ]
    private static func missingRatios(reason: String) -> [Metric] {
        ratioDefinitions.map { Metric(key: $0.key, label: $0.label, value: nil, unit: $0.unit,
            origin: "Massive provider ratio", formula: $0.formula, period: "Unavailable", sourceURL: Endpoint.ratios.url, note: reason) }
    }
    private static func missingReturns(reason: String) -> [Metric] {
        [Metric(key: "roce", label: "ROCE (operating income)", value: nil, unit: "fraction", origin: "App calculation",
                formula: "annual operating income / average beginning/end (assets − current liabilities)", period: "Unavailable",
                sourceURL: "https://data.sec.gov/api/xbrl/companyfacts/", note: reason),
         Metric(key: "roic", label: "ROIC (accounting return on invested capital)", value: nil, unit: "fraction", origin: "App calculation",
                formula: "annual operating income × (1 − effective tax rate) / average beginning/end (debt + equity − cash)",
                period: "Unavailable", sourceURL: "https://data.sec.gov/api/xbrl/companyfacts/",
                note: reason + " This is an accounting return, not shareholder ROI or a stock-price return.")]
    }
    private static func unavailable(symbol: String, asOf: Date, retrievedAt: Date, reason: String) -> Snapshot {
        let recordedAsOf = validDate(asOf) ? asOf : Date(timeIntervalSince1970: 0)
        let recordedAt = validDate(retrievedAt) ? retrievedAt : recordedAsOf
        return Snapshot(symbol: symbol, asOf: recordedAsOf, retrievedAt: recordedAt, providerRatios: missingRatios(reason: reason),
            calculated: missingReturns(reason: reason), sources: Endpoint.allCases.map {
                .init(name: $0.label, url: $0.url, status: "unavailable", note: reason, recordCount: 0)
            }, notes: [accountingNote, reason])
    }
    private static func accountingFlags(_ statements: [Statement]) -> [String] {
        var result: [String] = []
        if let income = statements.first(where: { $0.kind == Endpoint.income.rawValue }) {
            if let net = income.amounts["consolidated_net_income_loss"], net < 0 {
                result.append("Reported TTM consolidated net loss for period ending \(income.periodEnd).")
            }
            if let extraordinary = income.amounts["extraordinary_items"], extraordinary != 0 {
                result.append("Provider reports nonzero extraordinary items for \(income.periodEnd); no one-off adjustment has been applied.")
            }
        }
        if let cash = statements.first(where: { $0.kind == Endpoint.cash.rawValue }),
           let cfo = cash.amounts["net_cash_from_operating_activities"], cfo < 0 {
            result.append("Reported negative operating cash flow for TTM ending \(cash.periodEnd).")
            if let income = statements.first(where: { $0.kind == Endpoint.income.rawValue && $0.periodEnd == cash.periodEnd }),
               let net = income.amounts["consolidated_net_income_loss"], net > 0 {
                result.append("Positive reported earnings coexist with negative operating cash flow in the same TTM period; this is a cash-conversion warning, not proof of misconduct.")
            }
        }
        return result
    }
    private static func fields(_ endpoint: Endpoint) -> [String] {
        switch endpoint {
        case .income: return ["revenue", "operating_income", "income_before_income_taxes", "income_taxes",
                             "consolidated_net_income_loss", "net_income_loss_attributable_common_shareholders",
                             "extraordinary_items", "discontinued_operations", "interest_expense", "interest_income"]
        case .balance: return ["total_assets", "total_current_assets", "total_current_liabilities", "total_equity",
                              "total_equity_attributable_to_parent", "total_liabilities", "debt_current",
                              "long_term_debt_and_capital_lease_obligations", "cash_and_equivalents"]
        case .cash: return ["net_cash_from_operating_activities", "net_income", "purchase_of_property_plant_and_equipment",
                           "sale_of_property_plant_and_equipment", "net_cash_from_investing_activities", "net_cash_from_financing_activities"]
        case .ratios: return []
        }
    }
    private static func number(_ row: [String: Any], _ key: String) throws -> Double? {
        guard let raw = row[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw URLError(.cannotParseResponse)
        }
        return value.doubleValue
    }
    private static func cik(_ raw: Any?) throws -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let text = raw as? String, !text.isEmpty, text.count <= 10,
              text.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt64(text), value > 0 else {
            throw URLError(.cannotParseResponse)
        }
        return String(value)
    }
    private static func validSymbol(_ symbol: String) -> Bool {
        !symbol.isEmpty && symbol.utf8.count <= 16 && symbol.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }
    }
    private static func validDate(_ value: Date) -> Bool { value.timeIntervalSince1970.isFinite && value.timeIntervalSince1970 > 0 }
    private static func date(_ text: String) -> Date? {
        guard text.utf8.count == 10 else { return nil }
        let formatter = formatter()
        guard let value = formatter.date(from: text), formatter.string(from: value) == text else { return nil }
        return value
    }
    private static func day(_ date: Date) -> String { formatter().string(from: date) }
    private static func formatter() -> DateFormatter {
        let result = DateFormatter(); result.locale = Locale(identifier: "en_US_POSIX")
        result.calendar = Calendar(identifier: .gregorian); result.timeZone = TimeZone(secondsFromGMT: 0)
        result.dateFormat = "yyyy-MM-dd"; result.isLenient = false; return result
    }
}
