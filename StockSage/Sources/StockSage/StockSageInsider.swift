import Foundation

/// Insider transactions from SEC Form 4 — public, legally-disclosed filings.
///
/// Bounded SEC Table I review. Codes P/S include open-market OR private purchases/sales;
/// neither the transaction code nor an absent plan checkbox establishes trading intent.
/// Derivatives and other transaction codes remain excluded and counted explicitly.
enum StockSageInsider {

    /// Form 4 transaction codes. Case names are retained for source compatibility.
    /// Table I codes per SEC Form 4 instructions.
    enum Code: String, Sendable, Equatable {
        case openMarketPurchase = "P"   // reported open-market or private purchase
        case openMarketSale = "S"       // reported open-market or private sale
        case grant = "A"                // award/grant from the company
        case optionExercise = "M"       // exercise of a derivative — mechanical
        case taxWithholding = "F"       // shares withheld to cover tax
        case gift = "G"
        case other = "?"

        nonisolated init(rawCode: String) {
            self = Code(rawValue: rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()) ?? .other
        }

        /// Historical API name: selects P/S codes only; it does not establish discretion.
        nonisolated var isDiscretionary: Bool { self == .openMarketPurchase || self == .openMarketSale }
    }

    struct Transaction: Sendable, Equatable {
        let symbol: String
        let insiderName: String
        let officerTitle: String?
        let code: Code
        /// True = acquired, false = disposed (Form 4's A/D flag).
        let acquired: Bool
        let shares: Double
        /// nil when the filing omits a price (common for grants and some exercises).
        let pricePerShare: Double?
        /// `<transactionDate><value>YYYY-MM-DD</value></transactionDate>` — nil when the filing
        /// omits it. Added so a discretionary transaction can be offered to the catalyst narrator
        /// as a DATED citable source; never fabricated when absent (honesty floor).
        let date: Date?
        var accession: String? = nil
        var filingDate: Date? = nil
        var documentURL: URL? = nil
        var reportedRoles: [String] = []
        var planDisclosure: String = "Rule 10b5-1 plan disclosure unavailable"

        nonisolated var evidenceDescription: String {
            let transaction = date.map { "transaction date " + StockSageCatalystNarrator.sourceDay($0) } ?? "transaction date unavailable"
            let publication = filingDate.map { "filing date " + StockSageCatalystNarrator.sourceDay($0) } ?? "filing date unavailable"
            let roles = (reportedRoles + (officerTitle.map { [$0] } ?? [])).joined(separator: ", ")
            let price = pricePerShare.map { "price per share " + String($0) + " USD" } ?? "price per share unavailable"
            return "Code \(code.rawValue); \(shares) shares; \(price); \(transaction); \(publication); role: \(roles.isEmpty ? "unavailable" : roles); \(planDisclosure); accession: \(accession ?? "unavailable"). P/S includes open-market or private transactions; intent is not established."
        }
        nonisolated var dollarValue: Double? {
            guard let price = pricePerShare, price.isFinite, price >= 0,
                  shares.isFinite, shares > 0 else { return nil }
            let value = price * shares
            return value.isFinite ? value : nil
        }
    }

    /// What the bounded filing selection contained, including excluded other-code rows.
    struct Summary: Sendable, Equatable {
        let symbol: String
        let discretionary: [Transaction]
        /// Count of parsed Table I rows outside P/S; no conclusion about their intent.
        let nonDiscretionaryCount: Int
        var checkedAt: Date? = nil
        var reviewedFilings: Int = 0
        var availableFilings: Int? = nil

        nonisolated var coverageDescription: String {
            let check = checkedAt.map { "Checked " + $0.ISO8601Format() } ?? "Check time unavailable"
            let available = availableFilings.map { " of \($0) Form 4 filings in the returned SEC submissions page" } ?? ""
            return "\(check). Reviewed \(reviewedFilings) filings\(available), capped at \(StockSageInsider.maxFilingsPerSymbol). Table I P/S rows only; \(nonDiscretionaryCount) other-code rows excluded. This is not a date-bounded census or an intent signal."
        }

        nonisolated var netBuyValue: Double? {
            let vals = discretionary.compactMap { t -> Double? in
                guard let v = t.dollarValue else { return nil }
                return t.code == .openMarketPurchase ? v : -v
            }
            // The UI labels this as NET, not a subtotal of the priced rows.
            guard !vals.isEmpty, vals.count == discretionary.count else { return nil }
            let net = vals.reduce(0, +)
            return net.isFinite ? net : nil
        }
        nonisolated var isEmpty: Bool { discretionary.isEmpty && nonDiscretionaryCount == 0 }
    }

    nonisolated static let caveat =
        "Public SEC Form 4 disclosures. P/S codes report open-market or private purchases/sales; "
        + "they do not establish discretionary intent. Other codes and derivatives are excluded. "
        + "A reported Rule 10b5-1 checkbox describes the filing; an absent checkbox does not prove no plan. "
        + "Unvalidated as a predictive signal; inspect the original filing and footnotes."

    // MARK: - Parsing (pure — this is where the honesty lives)

    /// Extract the discretionary transactions from one Form 4 XML document.
    /// Returns nil for an unparseable Form 4 or contradictory discretionary direction.
    nonisolated static func parseForm4(_ xml: String) -> Summary? {
        func tag(_ t: String) -> String? {
            guard let m = xml.range(of: "<\(t)>(.*?)</\(t)>", options: [.regularExpression, .caseInsensitive])
            else { return nil }
            let inner = String(xml[m])
                .replacingOccurrences(of: "<\(t)>", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "</\(t)>", with: "", options: .caseInsensitive)
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func all(_ pattern: String, in text: String) -> [String] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
            let ns = text as NSString
            return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
                ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let symbol = tag("issuerTradingSymbol"), !symbol.isEmpty else { return nil }
        let names = all("<rptOwnerName>(.*?)</rptOwnerName>", in: xml)
        let name = names.isEmpty ? "Unknown" : names.joined(separator: "; ")
        let title = all("<officerTitle>(.*?)</officerTitle>", in: xml).joined(separator: "; ")
        func reported(_ tagName: String) -> Bool {
            all("<\(tagName)>(.*?)</\(tagName)>", in: xml).contains { ["true", "1"].contains($0.lowercased()) }
        }
        let roles = [("isOfficer", "officer"), ("isDirector", "director"),
                     ("isTenPercentOwner", "ten-percent owner"), ("isOther", "other reporting relationship")]
            .filter { reported($0.0) }.map { $0.1 }
        let plan: String
        switch tag("aff10b5One")?.lowercased() {
        case "true", "1": plan = "Rule 10b5-1 checkbox reported for this filing; consult transaction footnotes"
        case "false", "0": plan = "Rule 10b5-1 checkbox not checked; discretionary intent is not established"
        default: plan = "Rule 10b5-1 plan disclosure unavailable"
        }

        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]

        var discretionary: [Transaction] = []
        var excluded = 0
        // Table I only: a derivative contract is not a share trade. Keep optional fields
        // inside their transaction; independent document-wide arrays shift when a value is absent.
        // ponytail: unprefixed SEC Table I only; use XMLParser if namespaced vocabularies are added.
        for row in all("<nonDerivativeTransaction\\b[^>]*>(.*?)</nonDerivativeTransaction>", in: xml) {
            func value(_ field: String) -> String? {
                all("<\(field)>\\s*<value>(.*?)</value>", in: row).first
            }
            guard let rawCode = all("<transactionCode>(.*?)</transactionCode>", in: row).first else { return nil }
            guard !rawCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let code = Code(rawCode: rawCode)
            guard code.isDiscretionary else { excluded += 1; continue }
            // Keep finite fractional quantities; no integer truncation in evidence rendering.
            guard let qty = value("transactionShares").flatMap(Double.init), qty.isFinite,
                  qty > 0, qty < Double(Int.max) else { return nil }
            let price = value("transactionPricePerShare").flatMap(Double.init).flatMap {
                $0.isFinite && $0 >= 0 ? $0 : nil
            }
            let date = value("transactionDate").flatMap { day.date(from: $0) }
            let side = value("transactionAcquiredDisposedCode")?.uppercased()
            // A disputed row can reverse the net: withhold this summary, not just that row.
            guard side == nil || side == (code == .openMarketPurchase ? "A" : "D") else { return nil }
            let acquired = side.map { $0 == "A" } ?? (code == .openMarketPurchase)
            discretionary.append(Transaction(symbol: symbol.uppercased(), insiderName: name,
                                             officerTitle: title.isEmpty ? nil : title, code: code, acquired: acquired,
                                             shares: qty, pricePerShare: price, date: date,
                                             reportedRoles: roles, planDisclosure: plan))
        }
        return Summary(symbol: symbol.uppercased(), discretionary: discretionary,
                       nonDiscretionaryCount: excluded)
    }

    // MARK: - Fetch (SEC EDGAR — free, public, no key)

    /// SEC requires a descriptive User-Agent on every request; unidentified traffic is blocked.
    nonisolated static let userAgent = StockSageDisclosureService.ua
    /// SEC asks for <= 10 requests/second. One symbol costs 3 hops, so this is fetched ON DEMAND
    /// (opening an idea), never swept across the 901-name board.
    nonisolated static let maxFilingsPerSymbol = 6

    /// Both SEC screens share the actor-owned, successful-only ticker cache.
    nonisolated static func cik(for symbol: String) async -> String? {
        guard !symbol.contains(".") else { return nil } // Preserve existing foreign-listing exclusion.
        return await StockSageDisclosureService.CIKMap.shared.cik(for: symbol)
    }

    /// Recent reported P/S insider activity for one US symbol. nil when external access is off
    /// (gated by `ToolPolicy.isExternalAllowed` — fix pass 2026-09-06: this feed hit the network
    /// unconditionally before, the only one of the app's SEC feeds that did), the symbol is not
    /// SEC-listed, or the filings cannot be read — never an empty summary standing in for
    /// "unknown". The gate is the FIRST line, before any `await`/network call — a pure,
    /// synchronous seam a test can exercise without ever reaching the network.
    nonisolated static func recentActivity(for symbol: String,
        lookup: @Sendable (String) async -> String? = { await cik(for: $0) },
        transport: StockSageDisclosureService.Transport = StockSageDisclosureService.transport,
        allowed: @Sendable () -> Bool = { ToolPolicy.isExternalAllowed },
        now: Date = Date()) async -> Summary? {
        guard !Task.isCancelled, allowed() else { return nil }
        guard let cik = await lookup(symbol),
              let subsURL = URL(string: "https://data.sec.gov/submissions/CIK\(cik).json"),
              let data = await StockSageDisclosureService.get(subsURL, transport: transport, allowed: allowed),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filings = obj["filings"] as? [String: Any],
              let recent = filings["recent"] as? [String: Any],
              let forms = recent["form"] as? [String],
              let accessions = recent["accessionNumber"] as? [String], forms.count == accessions.count
        else { return nil }

        let filingDates = recent["filingDate"] as? [String]
        guard recent["filingDate"] == nil || filingDates?.count == forms.count else { return nil }
        let form4Indices = forms.indices.filter { forms[$0] == "4" || forms[$0] == "4/A" }
        let selectedIndices = Array(form4Indices.prefix(maxFilingsPerSymbol))
        let form4Window = selectedIndices.map { (forms[$0], accessions[$0]) }
        // An amendment can replace an earlier trade, not add another one. The bounded
        // summary cannot reconcile replacements yet; do not publish the original net.
        guard !form4Window.contains(where: { $0.0 == "4/A" }) else { return nil }
        let form4Accessions = form4Window.map { $0.1 }
        guard !form4Accessions.isEmpty else {
            return Summary(symbol: symbol.uppercased(), discretionary: [], nonDiscretionaryCount: 0, checkedAt: now, availableFilings: form4Indices.count)
        }

        var summaries: [Summary] = []
        let numericCIK = String(Int(cik) ?? 0)
        for (offset, acc) in form4Accessions.enumerated() {
            let bare = acc.replacingOccurrences(of: "-", with: "")
            guard let idxURL = URL(string: "https://www.sec.gov/Archives/edgar/data/\(numericCIK)/\(bare)/index.json"),
                  let idxData = await StockSageDisclosureService.get(idxURL, transport: transport, allowed: allowed),
                  let idx = try? JSONSerialization.jsonObject(with: idxData) as? [String: Any],
                  let dir = idx["directory"] as? [String: Any],
                  let items = dir["item"] as? [[String: Any]],
                  let xmlName = items.compactMap({ $0["name"] as? String })
                      .first(where: { $0.hasSuffix(".xml") && !$0.contains("index") }),
                  let docURL = URL(string: "https://www.sec.gov/Archives/edgar/data/\(numericCIK)/\(bare)/\(xmlName)"),
                  let docData = await StockSageDisclosureService.get(docURL, transport: transport, allowed: allowed),
                  let xml = String(data: docData, encoding: .utf8),
                  let parsed = parseForm4(xml), parsed.symbol == symbol.uppercased()
            // An unreadable selected filing could reverse the net. Preserve the fail-closed
            // complete-selection requirement; coverage metadata does not excuse a partial net.
            else { return nil }
            let day = ISO8601DateFormatter(); day.formatOptions = [.withFullDate]
            let filed = filingDates.flatMap { day.date(from: $0[selectedIndices[offset]]) }
            let rows = parsed.discretionary.map { row in
                var result = row
                result.accession = acc; result.filingDate = filed; result.documentURL = docURL
                return result
            }
            summaries.append(Summary(symbol: parsed.symbol, discretionary: rows,
                                     nonDiscretionaryCount: parsed.nonDiscretionaryCount))
        }
        guard !Task.isCancelled, allowed(), !summaries.isEmpty else { return nil }
        var result = merge(summaries, symbol: symbol)
        result.checkedAt = now
        result.reviewedFilings = summaries.count
        result.availableFilings = form4Indices.count
        return result
    }

    /// Merge per-filing summaries for one symbol.
    nonisolated static func merge(_ summaries: [Summary], symbol: String) -> Summary {
        Summary(symbol: symbol.uppercased(),
                discretionary: summaries.flatMap(\.discretionary),
                nonDiscretionaryCount: summaries.reduce(0) { $0 + $1.nonDiscretionaryCount })
    }
}
