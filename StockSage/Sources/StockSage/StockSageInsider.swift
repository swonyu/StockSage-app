import Foundation

/// Insider transactions from SEC Form 4 — public, legally-disclosed filings.
///
/// WHY THIS EXISTS: the owner asked about material non-public information. That is insider
/// trading and is not something this app will ever touch. But everything that makes MNPI
/// valuable has a lawful public shadow, and this is the closest one: officers and directors are
/// REQUIRED to disclose their own trades within two business days, and acting on that disclosure
/// is entirely legal. Being fast on public information is the line; being early on private
/// information is the other side of it.
///
/// THE HONESTY PROBLEM THIS SOLVES, and the reason the transaction CODE is the centre of the
/// design: most Form 4 activity is not a market opinion. A naive feed reading "SVP disposed
/// 16,238 shares" sounds bearish; in the AAPL filing that line came from, the codes were M and F
/// — an option exercise and shares automatically withheld to pay the tax on it. The insider chose
/// nothing. Surfacing that as selling would be fabricating a signal out of payroll mechanics.
///
/// So only OPEN-MARKET decisions are surfaced: code P (bought with their own money) and code S
/// (sold into the market). Everything else is parsed, classified, and deliberately excluded — and
/// the UI says that exclusion happened, because "no insider activity" and "activity, none of it
/// discretionary" are different facts.
///
/// SCOPE: US only. The SEC publishes Form 4; Tadawul's insider disclosures live on the Saudi
/// exchange's own site in a different format and are not covered here.
enum StockSageInsider {

    /// Form 4 transaction codes, grouped by whether they represent a DECISION to trade.
    /// Table I codes per SEC Form 4 instructions.
    enum Code: String, Sendable, Equatable {
        case openMarketPurchase = "P"   // bought on the open market — own money, own choice
        case openMarketSale = "S"       // sold on the open market
        case grant = "A"                // award/grant from the company
        case optionExercise = "M"       // exercise of a derivative — mechanical
        case taxWithholding = "F"       // shares withheld to cover tax — the insider chose nothing
        case gift = "G"
        case other = "?"

        nonisolated init(rawCode: String) {
            self = Code(rawValue: rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()) ?? .other
        }

        /// Whether this code reflects a discretionary market decision. ONLY these are surfaced.
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
        nonisolated var dollarValue: Double? { pricePerShare.map { $0 * shares } }
    }

    /// What a symbol's recent filings actually contained — including what was excluded, so the
    /// UI can distinguish "nothing happened" from "things happened, none of them a decision".
    struct Summary: Sendable, Equatable {
        let symbol: String
        let discretionary: [Transaction]
        /// Count of parsed rows dropped because they were mechanical (grants, exercises, tax).
        let nonDiscretionaryCount: Int

        nonisolated var netBuyValue: Double? {
            let vals = discretionary.compactMap { t -> Double? in
                guard let v = t.dollarValue else { return nil }
                return t.code == .openMarketPurchase ? v : -v
            }
            return vals.isEmpty ? nil : vals.reduce(0, +)
        }
        nonisolated var isEmpty: Bool { discretionary.isEmpty && nonDiscretionaryCount == 0 }
    }

    nonisolated static let caveat =
        "SEC Form 4 filings — public disclosures officers and directors must file within two "
        + "business days. Only OPEN-MARKET purchases and sales are shown; option exercises, "
        + "grants and tax withholding are excluded because the insider chose nothing. "
        + "UNVALIDATED as a signal: no walk-forward test has been run on it."

    // MARK: - Parsing (pure — this is where the honesty lives)

    /// Extract the discretionary transactions from one Form 4 XML document.
    /// Returns nil only when the document is not a parseable Form 4.
    nonisolated static func parseForm4(_ xml: String) -> Summary? {
        func tag(_ t: String) -> String? {
            guard let m = xml.range(of: "<\(t)>(.*?)</\(t)>", options: [.regularExpression, .caseInsensitive])
            else { return nil }
            let inner = String(xml[m])
                .replacingOccurrences(of: "<\(t)>", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "</\(t)>", with: "", options: .caseInsensitive)
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func all(_ pattern: String) -> [String] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
            let ns = xml as NSString
            return re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map {
                ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let symbol = tag("issuerTradingSymbol"), !symbol.isEmpty else { return nil }
        let name = tag("rptOwnerName") ?? "Unknown"
        let title = tag("officerTitle")

        let codes = all("<transactionCode>(.*?)</transactionCode>")
        let ad = all("<transactionAcquiredDisposedCode>\\s*<value>(.*?)</value>")
        let shares = all("<transactionShares>\\s*<value>(.*?)</value>")
        let prices = all("<transactionPricePerShare>\\s*<value>(.*?)</value>")
        let dates = all("<transactionDate>\\s*<value>(.*?)</value>")
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]

        var discretionary: [Transaction] = []
        var excluded = 0
        for (i, rawCode) in codes.enumerated() {
            let code = Code(rawCode: rawCode)
            guard code.isDiscretionary else { excluded += 1; continue }
            guard i < shares.count, let qty = Double(shares[i]), qty > 0 else { continue }
            // Price/date arrays can be SHORTER than the code array (rows that omit them are
            // absent, not misaligned), so a positional read past the end must yield nil rather
            // than another row's value.
            let price = i < prices.count ? Double(prices[i]) : nil
            let date = i < dates.count ? day.date(from: dates[i]) : nil
            let acquired = i < ad.count ? ad[i].uppercased() == "A" : (code == .openMarketPurchase)
            discretionary.append(Transaction(symbol: symbol.uppercased(), insiderName: name,
                                             officerTitle: title, code: code, acquired: acquired,
                                             shares: qty, pricePerShare: price, date: date))
        }
        return Summary(symbol: symbol.uppercased(), discretionary: discretionary,
                       nonDiscretionaryCount: excluded)
    }

    // MARK: - Fetch (SEC EDGAR — free, public, no key)

    /// SEC requires a descriptive User-Agent on every request; unidentified traffic is blocked.
    nonisolated static let userAgent = "StockSageX/1.0 (personal research; contact via GitHub swonyu)"
    /// SEC asks for <= 10 requests/second. One symbol costs 3 hops, so this is fetched ON DEMAND
    /// (opening an idea), never swept across the 901-name board.
    nonisolated static let maxFilingsPerSymbol = 6

    private nonisolated static func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// ticker -> zero-padded CIK. The map is ~10k entries and changes rarely, so it is fetched
    /// once per launch and held.
    private nonisolated(unsafe) static var cikCache: [String: String] = [:]

    nonisolated static func cik(for symbol: String) async -> String? {
        let key = symbol.uppercased()
        if let hit = cikCache[key] { return hit }
        guard !symbol.contains("."),                     // .SR and other foreign listings: not SEC
              let url = URL(string: "https://www.sec.gov/files/company_tickers.json"),
              let data = await get(url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return nil }
        var map: [String: String] = [:]
        for (_, row) in obj {
            guard let t = row["ticker"] as? String, let c = row["cik_str"] as? Int else { continue }
            map[t.uppercased()] = String(format: "%010d", c)
        }
        cikCache = map
        return map[key]
    }

    /// Recent open-market insider activity for one US symbol. nil when external access is off
    /// (gated by `ToolPolicy.isExternalAllowed` — fix pass 2026-09-06: this feed hit the network
    /// unconditionally before, the only one of the app's SEC feeds that did), the symbol is not
    /// SEC-listed, or the filings cannot be read — never an empty summary standing in for
    /// "unknown". The gate is the FIRST line, before any `await`/network call — a pure,
    /// synchronous seam a test can exercise without ever reaching the network.
    nonisolated static func recentActivity(for symbol: String) async -> Summary? {
        guard ToolPolicy.isExternalAllowed else { return nil }
        guard let cik = await cik(for: symbol),
              let subsURL = URL(string: "https://data.sec.gov/submissions/CIK\(cik).json"),
              let data = await get(subsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filings = obj["filings"] as? [String: Any],
              let recent = filings["recent"] as? [String: Any],
              let forms = recent["form"] as? [String],
              let accessions = recent["accessionNumber"] as? [String]
        else { return nil }

        let form4Accessions = zip(forms, accessions)
            .filter { $0.0 == "4" }
            .prefix(maxFilingsPerSymbol)
            .map { $0.1 }
        guard !form4Accessions.isEmpty else {
            return Summary(symbol: symbol.uppercased(), discretionary: [], nonDiscretionaryCount: 0)
        }

        var summaries: [Summary] = []
        let numericCIK = String(Int(cik) ?? 0)
        for acc in form4Accessions {
            let bare = acc.replacingOccurrences(of: "-", with: "")
            guard let idxURL = URL(string: "https://www.sec.gov/Archives/edgar/data/\(numericCIK)/\(bare)/index.json"),
                  let idxData = await get(idxURL),
                  let idx = try? JSONSerialization.jsonObject(with: idxData) as? [String: Any],
                  let dir = idx["directory"] as? [String: Any],
                  let items = dir["item"] as? [[String: Any]],
                  let xmlName = items.compactMap({ $0["name"] as? String })
                      .first(where: { $0.hasSuffix(".xml") && !$0.contains("index") }),
                  let docURL = URL(string: "https://www.sec.gov/Archives/edgar/data/\(numericCIK)/\(bare)/\(xmlName)"),
                  let docData = await get(docURL),
                  let xml = String(data: docData, encoding: .utf8),
                  let parsed = parseForm4(xml)
            else { continue }
            summaries.append(parsed)
        }
        guard !summaries.isEmpty else { return nil }
        return merge(summaries, symbol: symbol)
    }

    /// Merge per-filing summaries for one symbol.
    nonisolated static func merge(_ summaries: [Summary], symbol: String) -> Summary {
        Summary(symbol: symbol.uppercased(),
                discretionary: summaries.flatMap(\.discretionary),
                nonDiscretionaryCount: summaries.reduce(0) { $0 + $1.nonDiscretionaryCount })
    }
}
