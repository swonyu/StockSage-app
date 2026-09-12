import Foundation

// MARK: - StockSageDisclosureService
//
// "Has this been disclosed yet?" — the public-filing timeline for a symbol.
//
// **Why this exists.** Material information has a lifecycle: it starts inside the
// company (material, non-public — trading on it is illegal), and at one specific
// instant it becomes public. That instant is a filing's ACCEPTANCE time at the SEC.
// This service reports that instant and nothing else. It is a *disclosure clock*,
// not a signal: it answers "is this already public?", never "what is about to happen."
//
// **Source:** `data.sec.gov/submissions/CIK##########.json` — the SEC's own
// submissions feed. Keyless, free, and authoritative (it IS the disclosure record,
// not a vendor's copy of it). One request per symbol; the CIK map is fetched once.
//
// **Why not EDGAR full-text search.** `efts.sec.gov` searches document TEXT and
// cannot tell you a filing's 8-K item codes. The submissions feed carries `items`
// and `acceptanceDateTime` directly, which is exactly — and only — what a
// disclosure clock needs.
//
// **Cost:** free / keyless, so it is safe under the app's local-first, never-spend
// `.auto` philosophy. It IS network, so every fetch is gated by
// `ToolPolicy.isExternalAllowed`, like every other feed in this subsystem.
//
// SEC's access policy requires a declared User-Agent identifying the client; we
// send one. Fetches are on demand and bounded; this client does not implement a
// process-wide SEC rate limiter and must not claim that it does.
enum StockSageDisclosureService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    nonisolated static let maximumResponseBytes = 4 * 1_024 * 1_024
    nonisolated static let session = URLSession(configuration: .ephemeral,
        delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)
    nonisolated static func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await StockSageHTTP.data(for: request, session: session, maximumBytes: maximumResponseBytes)
    }

    /// Shared by both SEC consumers, including every Form 4 index/document hop.
    nonisolated static func get(_ url: URL, transport: Transport = Self.transport,
        allowed: @Sendable () -> Bool = { ToolPolicy.isExternalAllowed }) async -> Data? {
        guard !Task.isCancelled, allowed(), validURL(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await transport(request),
              !Task.isCancelled, allowed(), data.count <= maximumResponseBytes,
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == url else { return nil }
        return data
    }

    nonisolated private static func validURL(_ url: URL) -> Bool {
        url.scheme == "https" && ["www.sec.gov", "data.sec.gov"].contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil
    }

    /// One public filing. `acceptedAt` is the moment it became public — the field
    /// that matters — which is NOT the same as `filingDate` (a filing accepted at
    /// 17:40 ET carries the next business day as its filing date).
    struct Filing: Sendable, Equatable, Identifiable {
        let accessionNumber: String
        let form: String            // "8-K", "10-Q", "4", ...
        let filingDate: Date
        /// When the SEC accepted it = when it became public. nil if the feed omits it.
        let acceptedAt: Date?
        /// 8-K item codes, e.g. ["2.02", "9.01"]. Empty for forms that have none.
        let items: [String]
        let documentURL: URL?

        var id: String { accessionNumber }

        /// Plain-language reading of the 8-K item codes, for the ones that carry
        /// the most price-relevant news. Unknown codes are passed through as-is
        /// rather than guessed at — an unlabeled code is honest, a wrong label is not.
        var itemDescriptions: [String] {
            items.map { Self.itemNames[$0] ?? "Item \($0)" }
        }

        /// SEC 8-K item taxonomy (subset). Deliberately partial: these are the items
        /// whose disclosure most often moves a price. Codes outside the map render
        /// as "Item X.XX" — see `itemDescriptions`.
        static let itemNames: [String: String] = [
            "1.01": "Material agreement entered",
            "1.02": "Material agreement terminated",
            "1.03": "Bankruptcy or receivership",
            "2.01": "Assets acquired or disposed",
            "2.02": "Earnings released",
            "2.03": "Direct financial obligation created",
            "2.04": "Obligation accelerated",
            "2.05": "Exit or disposal costs",
            "2.06": "Material impairment",
            "3.01": "Delisting notice / listing rule failure",
            "4.01": "Auditor changed",
            "4.02": "Prior financials no longer reliable",
            "5.01": "Change in control",
            "5.02": "Director or officer change",
            "5.07": "Shareholder vote results",
            "7.01": "Reg FD disclosure",
            "8.01": "Other material event",
            "9.01": "Exhibits",
        ]
    }

    /// SEC asks that automated clients identify themselves. This is not optional
    /// politeness — undeclared clients get blocked.
    /// `nonisolated` so the nested `CIKMap` actor can read it off the main actor —
    /// same reason `StockSageQuoteService.ua` is nonisolated.
    nonisolated static let ua = "StockSageX/1.0 (personal research; contact via GitHub swonyu)"

    // MARK: CIK lookup

    /// ticker (uppercased) -> zero-padded 10-digit CIK. Retain successful maps for
    /// this process; failures are retryable, never cached as an authoritative absence.
    /// ponytail: overlapping cold lookups may each load; coalesce if request volume warrants it.
    actor CIKMap {
        static let shared = CIKMap()
        private var map: [String: String]?
        private let transport: Transport
        init(transport: @escaping Transport = StockSageDisclosureService.transport) {
            self.transport = transport
        }

        func cik(for symbol: String, allowed: @Sendable () -> Bool = { ToolPolicy.isExternalAllowed }) async -> String? {
            guard !Task.isCancelled, allowed(), !symbol.isEmpty, symbol.utf8.count <= 32 else { return nil }
            if map == nil {
                guard let loaded = await Self.load(transport: transport, allowed: allowed),
                      !Task.isCancelled, allowed() else { return nil }
                map = loaded
            }
            return map?[symbol.uppercased()]
        }

        private static func load(transport: Transport, allowed: @Sendable () -> Bool) async -> [String: String]? {
            guard let url = URL(string: "https://www.sec.gov/files/company_tickers.json"),
                  let data = await StockSageDisclosureService.get(url, transport: transport, allowed: allowed),
                  // The file is a JSON object keyed by row index, not an array.
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
                  !raw.isEmpty else { return nil }
            var out: [String: String] = [:]
            for row in raw.values {
                guard let ticker = row["ticker"] as? String, !ticker.isEmpty, ticker.utf8.count <= 32,
                      let number = row["cik_str"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let cik = row["cik_str"] as? Int, cik > 0, cik < 10_000_000_000 else { return nil }
                let digits = String(cik)
                out[ticker.uppercased()] = String(repeating: "0", count: 10 - digits.count) + digits
            }
            return out
        }
    }

    // MARK: Public fetch

    /// What a filings check actually DID. `recentFilings` cannot express this: a policy denial,
    /// a dead network and "this company filed no 8-K in the window" all arrive as `[]`, and a UI
    /// that renders the first two as the third states a check it never made.
    struct FilingsObservation: Sendable, Equatable {
        enum Outcome: Sendable, Equatable { case answered, unavailable(Failure) }
        /// Only fixed categories may reach the UI — never a raw error, URL or response body.
        /// `get` collapses status codes, transport errors and oversize bodies into one nil, so
        /// this taxonomy says exactly what is knowable here and no more.
        enum Failure: Sendable, Equatable {
            case externalAccessDisabled, cancelled, noCIK, unreachable, invalidPayload
            var message: String {
                switch self {
                case .externalAccessDisabled: StockSageMassiveEvents.Failure.externalAccessDisabled.message
                case .cancelled: StockSageMassiveEvents.Failure.cancelled.message
                case .noCIK: "No SEC CIK for this ticker, or the CIK map could not be loaded; no filings were read."
                case .unreachable: "The SEC submissions request did not return a usable response."
                case .invalidPayload: StockSageMassiveEvents.Failure.invalidPayload.message
                }
            }
        }
        let checkedAt: Date
        let outcome: Outcome
        let filings: [Filing]
    }

    /// Recent public filings for a symbol, newest first, WITH the outcome of the check.
    ///
    /// Never throws. An `.answered` observation with an empty `filings` means "we looked and found
    /// nothing in the window" — still not proof that nothing was filed. Every other outcome is
    /// `.unavailable`, which callers must render as a failed check, never as a negative result,
    /// and must not cache as a completed one.
    static func recentFilingsObservation(for symbol: String,
                                         forms: Set<String> = ["8-K"],
                                         limit: Int = 20,
                                         map: CIKMap = .shared,
                                         transport: @escaping Transport = Self.transport,
                                         allowed: @Sendable () -> Bool = { ToolPolicy.isExternalAllowed },
                                         now: Date = Date()) async -> FilingsObservation {
        func unavailable(_ failure: FilingsObservation.Failure) -> FilingsObservation {
            FilingsObservation(checkedAt: now, outcome: .unavailable(failure), filings: [])
        }
        guard !Task.isCancelled else { return unavailable(.cancelled) }
        guard allowed() else { return unavailable(.externalAccessDisabled) }
        guard limit > 0, !forms.isEmpty else { return unavailable(.noCIK) }
        guard let cik = await map.cik(for: symbol, allowed: allowed),
              let url = URL(string: "https://data.sec.gov/submissions/CIK\(cik).json")
        else {
            if Task.isCancelled { return unavailable(.cancelled) }
            return unavailable(allowed() ? .noCIK : .externalAccessDisabled)
        }
        guard let data = await get(url, transport: transport, allowed: allowed) else {
            if Task.isCancelled { return unavailable(.cancelled) }
            return unavailable(allowed() ? .unreachable : .externalAccessDisabled)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filings = validatedFilings(root, cik: cik, forms: forms, limit: limit) else {
            return unavailable(.invalidPayload)
        }
        return FilingsObservation(checkedAt: now, outcome: .answered,
                                  filings: filings)
    }

    /// Thin wrapper kept UNCHANGED in signature and contract: `hasDisclosure` calls it, and
    /// StockSageSECRequestTests:153 asserts `.isEmpty` on failure. Anything that must tell a
    /// failed check from an empty one uses `recentFilingsObservation` instead.
    static func recentFilings(for symbol: String,
                              forms: Set<String> = ["8-K"],
                              limit: Int = 20,
                              map: CIKMap = .shared,
                              transport: @escaping Transport = Self.transport,
                              allowed: @Sendable () -> Bool = { ToolPolicy.isExternalAllowed }) async -> [Filing] {
        guard !Task.isCancelled, allowed(), limit > 0, !forms.isEmpty else { return [] }
        guard let cik = await map.cik(for: symbol, allowed: allowed),
              let url = URL(string: "https://data.sec.gov/submissions/CIK\(cik).json")
        else { return [] }

        guard let data = await get(url, transport: transport, allowed: allowed),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return parseFilings(root, cik: cik, forms: forms, limit: limit)
    }

    /// Pure parse of a submissions payload — no network, so it can be unit-tested.
    /// Split out of `recentFilings` for exactly that reason: the column-oriented
    /// layout and the accession-number path quirk are where this silently breaks.
    nonisolated static func parseFilings(_ root: [String: Any],
                                         cik: String,
                                         forms: Set<String> = ["8-K"],
                                         limit: Int = 20) -> [Filing] {
        validatedFilings(root, cik: cik, forms: forms, limit: limit) ?? []
    }

    /// nil means a malformed/partial feed, not an answered empty selection.
    nonisolated static func validatedFilings(_ root: [String: Any], cik: String,
                                            forms: Set<String>, limit: Int) -> [Filing]? {
        guard limit > 0, let filings = root["filings"] as? [String: Any],
              let recent = filings["recent"] as? [String: Any],
              let formCol = recent["form"] as? [String],
              let accCol = recent["accessionNumber"] as? [String],
              let dateCol = recent["filingDate"] as? [String],
              formCol.count == accCol.count, formCol.count == dateCol.count,
              !formCol.contains(where: { $0.isEmpty }), !accCol.contains(where: { $0.isEmpty })
        else { return nil }

        // The feed is column-oriented: parallel arrays sharing one index.
        let acceptCol = recent["acceptanceDateTime"] as? [String] ?? []
        let itemsCol = recent["items"] as? [String] ?? []
        let docCol = recent["primaryDocument"] as? [String] ?? []

        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        guard dateCol.allSatisfy({ day.date(from: $0).map { day.string(from: $0) } == $0 }) else { return nil }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        // SEC stamps acceptance with fractional seconds ("2026-07-30T20:30:28.000Z"), which a
        // bare .withInternetDateTime formatter returns nil for — so `acceptedAt` was nil for
        // EVERY filing and the disclosure clock silently fell back to the filing DATE. Both
        // formatters are kept: .withFractionalSeconds alone returns nil on a bare-seconds stamp.
        let fracStamp = ISO8601DateFormatter()
        fracStamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var out: [Filing] = []
        let n = formCol.count
        for i in 0..<n where forms.contains(formCol[i]) {
            guard let filed = day.date(from: dateCol[i]) else { continue }
            let acc = accCol[i]
            let items = i < itemsCol.count
                ? itemsCol[i].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                : []
            // Document URL wants the accession number stripped of dashes in the path
            // but intact in the filename — an EDGAR quirk, not a typo.
            var docURL: URL?
            if i < docCol.count, !docCol[i].isEmpty {
                let bare = acc.replacingOccurrences(of: "-", with: "")
                docURL = URL(string: "https://www.sec.gov/Archives/edgar/data/\(Int(cik) ?? 0)/\(bare)/\(docCol[i])")
            }
            out.append(Filing(
                accessionNumber: acc,
                form: formCol[i],
                filingDate: filed,
                acceptedAt: i < acceptCol.count
                    ? (fracStamp.date(from: acceptCol[i]) ?? stamp.date(from: acceptCol[i])) : nil,
                items: items,
                documentURL: docURL))
            if out.count >= limit { break }
        }
        return out
    }

    /// What the UI must say alongside any filing it renders. This is a DISCLOSURE CLOCK: it
    /// reports the instant something became public, never what the news means or where the price
    /// goes next. It also cannot prove a negative — an empty result means "nothing found in the
    /// window we looked at", never "this company has disclosed nothing".
    nonisolated static let caveat =
        "SEC 8-K filings — the moment news became public, not a prediction of what it does to the "
        + "price. Absence of a filing here is not evidence that nothing was filed."

    /// How long ago a filing became public, in the plain words a person would use. `nil` when the
    /// feed omitted the acceptance time — the field that carries the actual disclosure instant —
    /// because guessing it from the filing DATE would be wrong by up to a business day (a filing
    /// accepted 17:40 ET carries the NEXT day as its filing date).
    nonisolated static func publicFor(_ filing: Filing, now: Date = Date()) -> String? {
        guard let at = filing.acceptedAt else { return nil }
        let secs = now.timeIntervalSince(at)
        guard secs >= 0 else { return nil }              // clock skew: say nothing, never "in -2h"
        let hours = Int(secs / 3600)
        if hours < 1 { return "just now" }
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return days == 1 ? "yesterday" : "\(days)d ago"
    }

    /// The one question this service exists to answer: is there a public filing for
    /// `symbol` at or after `date`?
    ///
    /// Use it to check whether something a user heard about has actually been
    /// disclosed yet. A `false` means "no filing found in the window we looked at" —
    /// it is NOT a determination that the information is non-public, and must never
    /// be presented as clearance to trade on anything.
    static func hasDisclosure(for symbol: String, since date: Date) async -> Bool {
        await recentFilings(for: symbol).contains { ($0.acceptedAt ?? $0.filingDate) >= date }
    }
}
