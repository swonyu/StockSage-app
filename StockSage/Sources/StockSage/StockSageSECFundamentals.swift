import Foundation
import CoreFoundation

nonisolated enum StockSageSECFundamentals {
    struct Snapshot: Codable, Sendable, Equatable {
        let calculated: [StockSageFundamentals.Metric]
        let sources: [StockSageFundamentals.Source]
        let notes: [String]
    }

    @concurrent static func collect(for symbol: String, expectedCIK: String? = nil,
                        map: StockSageDisclosureService.CIKMap = .shared,
                        transport: @escaping StockSageDisclosureService.Transport = StockSageDisclosureService.transport,
                        allowed: @escaping @Sendable () -> Bool = { ToolPolicy.isExternalAllowed },
                        now: Date = Date()) async -> Snapshot {
        guard !Task.isCancelled, allowed() else {
            return unavailable("SEC annual fundamentals were not requested because access is disabled or cancelled.")
        }
        let candidate: String?
        if let expectedCIK { candidate = expectedCIK }
        else { candidate = await map.cik(for: symbol, allowed: allowed) }
        guard let candidate, let cik = normalizedCIK(candidate) else {
            return unavailable("No verified issuer CIK is available for the SEC annual calculation.")
        }
        let url = companyFactsURL(cik)
        let result = await StockSageDisclosureService.fetch(url, transport: transport, allowed: allowed)
        func failed(_ failure: StockSageDisclosureService.RequestFailure) -> Snapshot {
            unavailable("SEC annual fundamentals unavailable: " + failure.message, url: url.absoluteString)
        }
        guard !Task.isCancelled else { return failed(.cancelled) }
        guard allowed() else { return failed(.accessDisabled) }
        switch result {
        case .success(let data): return parse(data, cik: cik, now: now)
        case .failure(let failure): return failed(failure)
        }
    }

    /// Company Facts contains only standard-taxonomy, entity-wide facts, but can
    /// repeat a period in later filings. Never mix filings, currencies or periods,
    /// sum quarterly/YTD figures, or treat a missing debt/lease concept as zero.
    /// https://www.sec.gov/search-filings/edgar-application-programming-interfaces
    static func parse(_ data: Data, cik: String, now: Date) -> Snapshot {
        guard let cik = normalizedCIK(cik) else { return unavailable("Invalid issuer CIK.") }
        let url = companyFactsURL(cik).absoluteString
        guard now.timeIntervalSince1970.isFinite, data.count <= StockSageDisclosureService.maximumResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issuer = number(root["cik"]), issuer > 0, issuer < 10_000_000_000,
              issuer.rounded() == issuer, UInt64(issuer) == UInt64(cik),
              let facts = root["facts"] as? [String: Any], let gaap = facts["us-gaap"] as? [String: Any]
        else { return unavailable("SEC Company Facts is oversized, malformed, lacks US-GAAP facts, or does not match the requested issuer.", url: url) }

        let cutoff = day(now)
        let tags = ["OperatingIncomeLoss", "Assets", "LiabilitiesCurrent", "DebtCurrent",
            "LongTermDebtNoncurrent", "FinanceLeaseLiabilityNoncurrent", consolidatedEquityTag,
            "CashAndCashEquivalentsAtCarryingValue", "IncomeTaxExpenseBenefit", pretaxTag]
        var records: [Fact] = []
        var inspectedRecords = 0
        let dateParser = formatter()
        for tag in tags {
            guard let concept = gaap[tag] as? [String: Any], let units = concept["units"] as? [String: Any] else { continue }
            for (unit, raw) in units {
                guard let rows = raw as? [[String: Any]] else { continue }
                inspectedRecords += rows.count
                guard inspectedRecords <= 200_000 else {
                    return unavailable("SEC Company Facts exceeded the 200,000 supported-concept record safety limit; no partial calculation was returned.", url: url)
                }
                for row in rows {
                    if let fact = Fact(tag: tag, unit: unit, row: row, cutoff: cutoff, dateParser: dateParser) { records.append(fact) }
                }
            }
        }
        // Choose the newest annual period BEFORE testing capital or units. An
        // unmeaningful latest year must not become an attractive older ratio.
        let annual = records.filter { $0.tag == "OperatingIncomeLoss" && $0.isAnnual }
        guard let end = annual.map(\.end).max(),
              let filed = annual.filter({ $0.end == end }).map(\.filed).max() else {
            return unavailable("No annual US-GAAP operating-income period with an eligible 10-K filing on or before the capture date was found. No TTM or quarterly estimate was substituted.", url: url)
        }
        let candidates = annual.filter { $0.end == end && $0.filed == filed }
        guard Set(candidates.map(\.accession)).count == 1,
              Set(candidates.compactMap(\.start)).count == 1,
              let chosen = candidates.first, let start = chosen.start,
              let startDate = date(start) else {
            return unavailable("The latest annual period has ambiguous filing or fiscal-period identity.", url: url)
        }
        let beginning = day(startDate.addingTimeInterval(-86_400))
        let period = "Annual \(start)–\(end); filed \(filed)"
        let source = filingURL(cik: cik, accession: chosen.accession)
        func read(_ tag: String, start: String? = nil, end: String) -> Fact? {
            let matching = records.filter {
                $0.tag == tag && $0.unit == "USD" && $0.start == start && $0.end == end
                    && $0.accession == chosen.accession && $0.filed == filed && $0.form == chosen.form
            }
            guard !matching.isEmpty, matching.allSatisfy({ $0.value != nil }),
                  Set(matching.compactMap(\.value)).count == 1 else { return nil }
            return matching.first
        }
        func input(_ fact: Fact) -> StockSageFundamentals.Input {
            .init(name: "us-gaap:\(fact.tag)", value: fact.value!, unit: "USD",
                  period: fact.start.map { "\($0)–\(fact.end)" } ?? fact.end, sourceURL: source)
        }
        var roce = metric("roce", period: period, source: source,
            note: "Unavailable: matching USD operating income and beginning/end assets and current liabilities are required from the same annual filing.")
        var roic = metric("roic", period: period, source: source,
            note: "Unavailable: matching USD tax, pretax income, explicit current debt, noncurrent debt, noncurrent finance leases, consolidated equity including noncontrolling interests, and cash are required. Parent-only equity is not substituted; missing components are not zero.")
        if let op = read("OperatingIncomeLoss", start: start, end: end),
           let a0 = read("Assets", end: beginning), let a1 = read("Assets", end: end),
           let l0 = read("LiabilitiesCurrent", end: beginning), let l1 = read("LiabilitiesCurrent", end: end) {
            let retained = [op, a0, l0, a1, l1].map(input)
            let c0 = a0.value! - l0.value!, c1 = a1.value! - l1.value!
            let mean = c0 / 2 + c1 / 2
            let value = op.value! / mean
            if a0.value! > 0, a1.value! > 0, l0.value! >= 0, l1.value! >= 0,
               c0 > 0, c1 > 0, mean.isFinite, value.isFinite {
                roce = metric("roce", value: value, period: period, source: source, inputs: retained,
                    note: "Historical annual operating-income return on average capital employed. Operating income is not asserted to equal EBIT. No one-off, commodity-cycle or sector normalization was performed.")
            } else {
                roce = metric("roce", period: period, source: source, inputs: retained,
                    note: "Unavailable: assets and both capital-employed balances must be positive and current liabilities nonnegative. The latest annual period was retained; no older positive year was substituted.")
            }
        }

        // DebtCurrent includes current debt and lease obligations; do not also
        // add LongTermDebtCurrent or current lease amounts. Noncurrent finance
        // leases are separately required because LongTermDebtNoncurrent excludes
        // lease obligations. No additional lease/investment adjustments are made.
        // Consolidated OperatingIncomeLoss requires consolidated equity, never
        // parent-only StockholdersEquity or a sum of overlapping equity totals.
        // https://xbrl.fasb.org/impdocs/OCI_TIG/othercompincome.htm
        if let op = read("OperatingIncomeLoss", start: start, end: end),
           let tax = read("IncomeTaxExpenseBenefit", start: start, end: end),
           let pretax = read(pretaxTag, start: start, end: end) {
            let balanceTags = ["DebtCurrent", "LongTermDebtNoncurrent", "FinanceLeaseLiabilityNoncurrent",
                consolidatedEquityTag, "CashAndCashEquivalentsAtCarryingValue"]
            let b0 = balanceTags.compactMap { read($0, end: beginning) }
            let b1 = balanceTags.compactMap { read($0, end: end) }
            if b0.count == balanceTags.count, b1.count == balanceTags.count {
                let retained = ([op, tax, pretax] + b0 + b1).map(input)
                let v0 = b0.map { $0.value! }, v1 = b1.map { $0.value! }
                let capital0 = v0[0] + v0[1] + v0[2] + v0[3] - v0[4]
                let capital1 = v1[0] + v1[1] + v1[2] + v1[3] - v1[4]
                let mean = capital0 / 2 + capital1 / 2
                let rate = tax.value! / pretax.value!
                let value = op.value! * (1 - rate) / mean
                if op.value! > 0, pretax.value! > 0, rate.isFinite, (0...1).contains(rate),
                   v0.allSatisfy({ $0 >= 0 }), v1.allSatisfy({ $0 >= 0 }), v0[3] > 0, v1[3] > 0,
                   capital0 > 0, capital1 > 0, mean.isFinite, value.isFinite {
                    roic = metric("roic", value: value, period: period, source: source, inputs: retained,
                        note: "Annual ROIC proxy uses consolidated operating income after the reported effective tax rate, average debt plus consolidated equity including noncontrolling interests less cash, and the listed debt/finance-lease tags. It is not a normalized tax rate, investment return forecast, or sector comparison; no further lease or investment adjustments are made.")
                } else {
                    roic = metric("roic", period: period, source: source, inputs: retained,
                        note: "Unavailable: positive operating/pretax income, positive consolidated equity and invested capital, nonnegative debt/cash, and an effective tax rate between zero and one are required. No normalized tax assumption was substituted.")
                }
            }
        }
        let metrics = [roce, roic]
        return Snapshot(calculated: metrics, sources: [.init(name: "SEC annual Company Facts", url: url,
            status: metrics.allSatisfy({ $0.value != nil }) ? "answered"
                : (metrics.contains(where: { $0.value != nil }) ? "partial" : "unavailable"),
            note: "Matched \(chosen.form) \(chosen.accession), \(period). Explicit USD standard-taxonomy entity-wide facts; no TTM reconstruction.",
            recordCount: records.count)], notes: [
                "SEC calculations use the latest eligible annual period, not current intraday profitability. Company Facts filing dates have day precision, not acceptance timestamps.",
                "Missing custom tags, units, beginning balances or debt components remain unavailable. These figures do not establish normalized earnings, insider ownership, sector-relative quality or same-day price direction."
            ])
    }

    private static let pretaxTag = "IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest"
    private static let consolidatedEquityTag = "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"

    private struct Fact {
        let tag: String, unit: String, start: String?, end: String, filed: String, accession: String, form: String
        let value: Double?
        let isAnnual: Bool

        init?(tag: String, unit: String, row: [String: Any], cutoff: String, dateParser: DateFormatter) {
            guard let end = row["end"] as? String, StockSageSECFundamentals.date(end, using: dateParser) != nil,
                  let filed = row["filed"] as? String, StockSageSECFundamentals.date(filed, using: dateParser) != nil, filed <= cutoff, filed >= end,
                  let accession = row["accn"] as? String,
                  accession.range(of: #"^[0-9]{10}-[0-9]{2}-[0-9]{6}$"#, options: .regularExpression) != nil,
                  let form = row["form"] as? String, ["10-K", "10-K/A"].contains(form),
                  row["fp"] as? String == "FY" else { return nil }
            let start = row["start"] as? String
            if row["start"] != nil && (start == nil || StockSageSECFundamentals.date(start!, using: dateParser) == nil) { return nil }
            self.tag = tag; self.unit = unit; self.start = start; self.end = end
            self.filed = filed; self.accession = accession; self.form = form
            self.value = StockSageSECFundamentals.number(row["val"])
            if let start, let first = StockSageSECFundamentals.date(start, using: dateParser), let last = StockSageSECFundamentals.date(end, using: dateParser) {
                self.isAnnual = (350...380).contains(Int(last.timeIntervalSince(first) / 86_400) + 1)
            } else { self.isAnnual = false }
        }
    }

    private static func metric(_ key: String, value: Double? = nil, period: String = "Unavailable",
                               source: String, inputs: [StockSageFundamentals.Input] = [], note: String) -> StockSageFundamentals.Metric {
        .init(key: key, label: key == "roce" ? "Operating-income ROCE (annual)" : "ROIC proxy (annual)",
            value: value, unit: "fraction", origin: "Calculated from SEC annual USD facts",
            formula: key == "roce" ? "Operating income / average(beginning and ending assets − current liabilities)"
                : "Consolidated operating income × (1 − income tax / pretax income) / average(beginning and ending current debt + noncurrent debt + noncurrent finance leases + consolidated equity including noncontrolling interests − cash)",
            period: period, sourceURL: source, inputs: inputs, note: note)
    }

    private static func unavailable(_ reason: String, url: String = "https://www.sec.gov/search-filings/edgar-application-programming-interfaces") -> Snapshot {
        .init(calculated: [metric("roce", source: url, note: reason), metric("roic", source: url, note: reason)],
              sources: [.init(name: "SEC annual Company Facts", url: url, status: "unavailable", note: reason, recordCount: 0)],
              notes: [reason])
    }

    private static func normalizedCIK(_ raw: String) -> String? {
        guard (1...10).contains(raw.utf8.count), raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt64(raw), value > 0, value < 10_000_000_000 else { return nil }
        let digits = String(value)
        return String(repeating: "0", count: 10 - digits.count) + digits
    }

    private static func companyFactsURL(_ cik: String) -> URL {
        URL(string: "https://data.sec.gov/api/xbrl/companyfacts/CIK\(cik).json")!
    }

    private static func filingURL(cik: String, accession: String) -> String {
        "https://www.sec.gov/Archives/edgar/data/\(UInt64(cik)!)/\(accession.replacingOccurrences(of: "-", with: ""))/\(accession)-index.html"
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func date(_ text: String, using parser: DateFormatter? = nil) -> Date? {
        guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = parser ?? formatter()
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    private static func day(_ date: Date) -> String { formatter().string(from: date) }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
