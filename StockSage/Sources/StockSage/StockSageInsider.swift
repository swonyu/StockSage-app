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
        nonisolated var dollarValue: Double? {
            guard let price = pricePerShare, price.isFinite, price >= 0,
                  shares.isFinite, shares > 0 else { return nil }
            let value = price * shares
            return value.isFinite ? value : nil
        }
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
            // The UI labels this as NET, not a subtotal of the priced rows.
            guard !vals.isEmpty, vals.count == discretionary.count else { return nil }
            let net = vals.reduce(0, +)
            return net.isFinite ? net : nil
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
        func all(_ pattern: String, in text: String) -> [String] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
            let ns = text as NSString
            return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
                ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let symbol = tag("issuerTradingSymbol"), !symbol.isEmpty else { return nil }
        let name = tag("rptOwnerName") ?? "Unknown"
        let title = tag("officerTitle")

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
            guard let rawCode = all("<transactionCode>(.*?)</transactionCode>", in: row).first else { continue }
            let code = Code(rawCode: rawCode)
            guard code.isDiscretionary else { excluded += 1; continue }
            // Catalyst citations render shares as Int; reject values that would trap there.
            guard let qty = value("transactionShares").flatMap(Double.init), qty.isFinite,
                  qty > 0, qty < Double(Int.max) else { continue }
            let price = value("transactionPricePerShare").flatMap(Double.init).flatMap {
                $0.isFinite && $0 >= 0 ? $0 : nil
            }
            let date = value("transactionDate").flatMap { day.date(from: $0) }
            let acquired = value("transactionAcquiredDisposedCode")
                .map { $0.uppercased() == "A" } ?? (code == .openMarketPurchase)
            discretionary.append(Transaction(symbol: symbol.uppercased(), insiderName: name,
                                             officerTitle: title, code: code, acquired: acquired,
                                             shares: qty, pricePerShare: price, date: date))
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

    /// Recent open-market insider activity for one US symbol. nil when external access is off
    /// (gated by `ToolPolicy.isExternalAllowed` — fix pass 2026-09-06: this feed hit the network
    /// unconditionally before, the only one of the app's SEC feeds that did), the symbol is not
    /// SEC-listed, or the filings cannot be read — never an empty summary standing in for
    /// "unknown". The gate is the FIRST line, before any `await`/network call — a pure,
    /// synchronous seam a test can exercise without ever reaching the network.
    nonisolated static func recentActivity(for symbol: String,
        lookup: @Sendable (String) async -> String? = { await cik(for: $0) },
        transport: StockSageDisclosureService.Transport = StockSageDisclosureService.transport,
        allowed: @Sendable () -> Bool = { ToolPolicy.isExternalAllowed }) async -> Summary? {
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
            // Summary has no partial-coverage field: an unreadable selected filing
            // could reverse the net or invalidate a "no activity" claim.
            else { return nil }
            summaries.append(parsed)
        }
        guard !Task.isCancelled, allowed(), !summaries.isEmpty else { return nil }
        return merge(summaries, symbol: symbol)
    }

    /// Merge per-filing summaries for one symbol.
    nonisolated static func merge(_ summaries: [Summary], symbol: String) -> Summary {
        Summary(symbol: symbol.uppercased(),
                discretionary: summaries.flatMap(\.discretionary),
                nonDiscretionaryCount: summaries.reduce(0) { $0 + $1.nonDiscretionaryCount })
    }
}
