import Foundation

// MARK: - StockSageQuoteService
//
// The live worldwide price feed the StockSage subsystem was always designed for
// (see `StockSageStore`'s doc: "When Chat A's Phase-2 Yahoo Finance feed lands,
// replace `seedSampleData()` with real fetches"). This is that feed.
//
// **Source:** Yahoo Finance's keyless `v8/finance/chart` endpoint — one of the
// few quote sources that needs no API key and covers virtually every exchange on
// Earth via symbol suffix (`.SR` Tadawul, `.L` LSE, `.T` Tokyo, `.HK` HKEX,
// `.NS` NSE India, `.AX` ASX, `.SA` B3 Brazil, `.PA` Euronext, `.DE` XETRA,
// `.SS` Shanghai, `.KS` KRX, `.TO` TSX, `^` = an index). Quotes are typically
// delayed ~15 min — the UI says so; we don't claim real-time.
//
// **Cost:** free / keyless, so it's safe under the app's local-first, never-spend
// `.auto` philosophy. It IS network, though, so every fetch is gated by
// `ToolPolicy.isExternalAllowed` (Web Access on AND Offline Mode off) — exactly
// the same gate the web/media tools honor.
enum StockSageQuoteService {

    /// A single live observation: the current market price and the prior session's
    /// close (the signal engine's % change is computed against this close, so a
    /// move here is a real one-day move, not a tick).
    struct LiveQuote: Sendable, Equatable {
        let symbol: String
        let price: Double
        let previousClose: Double
        /// The quote's own MARKET timestamp (Yahoo `regularMarketTime`), not our fetch time — so the
        /// UI can tell "live" from a days-old weekend/holiday close. nil when the feed omits it.
        let marketTime: Date?
        /// True when Yahoo returned no real previousClose (a brand-new listing) and `previousClose`
        /// was set to `price` as a flat placeholder. WITHOUT this flag that placeholder reads as a
        /// genuine 0%-move "hold" signal — it's actually "unevaluated," not "no move." Set precisely
        /// at the fallback site in `parseChart`, never inferred after the fact (a real ticker CAN
        /// legitimately have previousClose == price on a truly flat session).
        let isNewListing: Bool
        init(symbol: String, price: Double, previousClose: Double, marketTime: Date? = nil,
             isNewListing: Bool = false) {
            self.symbol = symbol; self.price = price
            self.previousClose = previousClose; self.marketTime = marketTime
            self.isNewListing = isNewListing
        }
    }

    /// Browser-like UA — Yahoo's public endpoints answer plain clients far more
    /// reliably with one set (same rationale as `MediaSearch.ua`).
    /// Internal (not private) so `StockSageEarnings` can share this single constant
    /// rather than duplicate it — a future UA fix lands in exactly one place (F39 2026-07-02).
    /// MediaSearch has its own copy outside the Markets fence; leave that untouched.
    nonisolated static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // MARK: Public fetch

    /// Fetch live quotes for many symbols concurrently (bounded fan-out so we
    /// don't open 46 sockets at once). Returns a map keyed by the **requested**
    /// symbol, uppercased — symbols the feed couldn't price are simply absent, so
    /// callers should treat a missing key as "no live data for this one" rather
    /// than an error. No-ops (returns `[:]`) when external access is disabled.
    static func fetchQuotes(for symbols: [String], concurrency: Int = 6) async -> [String: LiveQuote] {
        guard ToolPolicy.isExternalAllowed else { return [:] }
        guard !symbols.isEmpty else { return [:] }

        var out: [String: LiveQuote] = [:]
        // Process in fixed-size chunks; each chunk is a TaskGroup that resolves
        // before the next starts — caps concurrency without a semaphore.
        let chunks = stride(from: 0, to: symbols.count, by: max(1, concurrency)).map {
            Array(symbols[$0 ..< min($0 + concurrency, symbols.count)])
        }
        for chunk in chunks {
            let results: [LiveQuote] = await withTaskGroup(of: LiveQuote?.self) { group in
                for symbol in chunk {
                    group.addTask { await fetchOne(symbol) }
                }
                var acc: [LiveQuote] = []
                for await q in group where q != nil { acc.append(q!) }
                return acc
            }
            for q in results { out[q.symbol.uppercased()] = q }
        }
        return out
    }

    // MARK: One symbol

    private static func fetchOne(_ symbol: String) async -> LiveQuote? {
        // `^` (index marker) and other reserved chars must be percent-encoded.
        // Use .urlHostAllowed (stricter than .urlPathAllowed) so a symbol containing
        // '/' (e.g. a hypothetical BRK/B) doesn't silently rewrite the request path
        // segment — same set StockSageEarnings uses for the identical job (F38 2026-07-02).
        // No symbol in the curated universe contains '/', so live behavior is unchanged.
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=1d") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        guard let data = await get(req), let parsed = parseChart(data) else { return nil }
        // Preserve the symbol we *asked* for so it maps back to the curated market
        // label (Yahoo echoes its own canonical symbol, which can differ in case). Carry
        // marketTime through — dropping it silently disabled ALL downstream staleness/banner
        // honesty (quoteAsOf, per-row isStale) since fetchQuotes is built on fetchOne.
        return LiveQuote(symbol: symbol, price: parsed.price, previousClose: parsed.previousClose,
                         marketTime: parsed.marketTime, isNewListing: parsed.isNewListing)
    }

    /// GET a request, returning the 200 body. On a 429/503 (Yahoo's keyless endpoint
    /// rate-limits under load — the dominant failure mode as the universe grows), back
    /// off ~1.5s and retry ONCE before giving up. Any other status / transport error → nil.
    private nonisolated static func get(_ req: URLRequest) async -> Data? {
        for attempt in 0..<2 {
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return data }
            if (code == 429 || code == 503), attempt == 0 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }
            return nil
        }
        return nil
    }

    // MARK: Parsing (pure — unit-tested without the network)

    /// Decode Yahoo's `v8/chart` JSON into a `LiveQuote`. Best-effort and total:
    /// any shape it doesn't recognize (an error payload, a missing price, a
    /// zero/negative price) yields `nil` rather than throwing. Reads `previousClose`
    /// with a `chartPreviousClose` fallback (indices often carry only the latter).
    /// A non-positive or non-finite previousClose is treated exactly like a MISSING
    /// one (falls back to `price`, sets `isNewListing`) — never fabricated as a real 0%.
    static func parseChart(_ data: Data) -> LiveQuote? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let meta = results.first?["meta"] as? [String: Any],
              let symbol = meta["symbol"] as? String else { return nil }

        guard let price = number(meta["regularMarketPrice"]), price > 0 else { return nil }
        // A non-positive previousClose (a feed row carrying 0, or corrupt negative data) is exactly
        // as unusable as a missing one — L3-08: fabricates a flat 0.00% move / poisons %-change math
        // instead of an honest "can't judge yet." Route it through the SAME missing-previousClose
        // fallback rather than inventing a new sentinel.
        let realPreviousClose = (number(meta["previousClose"]) ?? number(meta["chartPreviousClose"]))
            .flatMap { $0 > 0 ? $0 : nil }
        // brand-new listing with no prior close → flat placeholder (isNewListing marks it as such,
        // NOT a genuine 0%-move hold signal).
        let previousClose = realPreviousClose ?? price
        // The quote's market time (Unix seconds) — lets the UI distinguish live from a stale close.
        let marketTime = number(meta["regularMarketTime"]).map { Date(timeIntervalSince1970: $0) }
        return LiveQuote(symbol: symbol, price: price, previousClose: previousClose, marketTime: marketTime,
                         isNewListing: realPreviousClose == nil)
    }

    // MARK: Candle history (for indicators / the advisor)

    /// Fetch ~1 year of daily OHLC bars for one symbol — enough for the 200-day
    /// trend and every indicator. `nil` on failure / when external access is off.
    nonisolated static func fetchHistory(_ symbol: String, range: String = "1y", interval: String = "1d") async -> StockSagePriceHistory? {
        guard ToolPolicy.isExternalAllowed else { return nil }
        // .urlHostAllowed for the same reason as fetchOne (F38 2026-07-02) — stricter set,
        // path-safe for all curated symbols, consistent with StockSageEarnings.fetchNextEarnings.
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=\(range)&interval=\(interval)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let data = await get(req) else { return nil }
        return parseHistory(data, symbol: symbol)
    }

    /// Per-slot stagger inside `fetchHistories`' TaskGroup (PLAN_2026-07-08_equity2000.md
    /// Stage 1 step 4): each task sleeps `slot index × historyPacingInterval` before firing
    /// its request, spreading a batch's requests instead of bursting all `concurrency` of
    /// them in the same instant. Tunable — raise it if a future universe size still draws
    /// 429s at this spacing; applies ONLY to history fetches (`fetchQuotes` is untouched —
    /// the plan scopes pacing to the heavier, more failure-prone bulk-history path).
    nonisolated static let historyPacingInterval: Duration = .milliseconds(120)

    /// Fetch candle histories for many symbols concurrently (bounded fan-out),
    /// keyed by uppercased requested symbol. `[:]` when external access is off.
    nonisolated static func fetchHistories(for symbols: [String], range: String = "1y", concurrency: Int = 6,
                               onProgress: ((Int) async -> Void)? = nil) async -> [String: StockSagePriceHistory] {
        guard ToolPolicy.isExternalAllowed, !symbols.isEmpty else { return [:] }
        var out: [String: StockSagePriceHistory] = [:]
        let chunks = stride(from: 0, to: symbols.count, by: max(1, concurrency)).map {
            Array(symbols[$0 ..< min($0 + concurrency, symbols.count)])
        }
        var completed = 0
        for chunk in chunks {
            let results: [StockSagePriceHistory] = await withTaskGroup(of: StockSagePriceHistory?.self) { group in
                for (slot, symbol) in chunk.enumerated() {
                    group.addTask {
                        if slot > 0 { try? await Task.sleep(for: historyPacingInterval * slot) }
                        return await fetchHistory(symbol, range: range)
                    }
                }
                var acc: [StockSagePriceHistory] = []
                for await h in group where h != nil { acc.append(h!) }
                return acc
            }
            for h in results { out[h.symbol.uppercased()] = h }
            completed += chunk.count
            await onProgress?(completed)
        }
        return out
    }

    /// Decode Yahoo `v8/chart` time-series JSON into a candle history. Yahoo emits
    /// `null` for non-trading gaps; those bars are dropped so the parallel arrays
    /// stay aligned and indicator math never meets a NaN. Newest bar LAST.
    nonisolated static func parseHistory(_ data: Data, symbol: String) -> StockSagePriceHistory? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let timestamps = result["timestamp"] as? [Any],
              let indicators = result["indicators"] as? [String: Any],
              let quote = (indicators["quote"] as? [[String: Any]])?.first,
              let opens = quote["open"] as? [Any],
              let highs = quote["high"] as? [Any],
              let lows = quote["low"] as? [Any],
              let closes = quote["close"] as? [Any] else { return nil }
        let volumes = (quote["volume"] as? [Any]) ?? []
        let n = timestamps.count
        guard n > 0, opens.count == n, highs.count == n, lows.count == n, closes.count == n else { return nil }

        var dt: [Date] = [], o: [Double] = [], h: [Double] = [], l: [Double] = [], c: [Double] = [], v: [Double] = []
        for i in 0..<n {
            // Reject non-positive OHLC — a 0/negative close from the feed would become latestClose
            // and feed price×shares / EV / sizing (mirrors parseChart's `price > 0`). Volume left
            // unguarded: 0 volume is legitimate for FX and indices.
            guard let ts = number(timestamps[i]),
                  let oo = number(opens[i]), oo > 0,
                  let hh = number(highs[i]), hh > 0,
                  let ll = number(lows[i]), ll > 0,
                  let cc = number(closes[i]), cc > 0 else { continue }
            dt.append(Date(timeIntervalSince1970: ts))
            o.append(oo); h.append(hh); l.append(ll); c.append(cc)
            v.append(i < volumes.count ? (number(volumes[i]) ?? 0) : 0)
        }
        guard c.count >= 2 else { return nil }
        return StockSagePriceHistory(symbol: symbol, dates: dt, opens: o, highs: h, lows: l, closes: c, volumes: v)
    }

    /// Coax a JSON numeric (Double / Int / NSNumber / numeric String) into a
    /// Double — `JSONSerialization` hands numbers back as `NSNumber`, and a few
    /// fields occasionally arrive as strings.
    private nonisolated static func number(_ any: Any?) -> Double? {
        let value: Double?
        switch any {
        case let d as Double:   value = d
        case let i as Int:      value = Double(i)
        case let n as NSNumber: value = n.doubleValue
        case let s as String:   value = Double(s)
        default:                value = nil
        }
        // Reject NaN / ±Inf so a non-finite field is dropped exactly like a null
        // bar — preserves the "indicator math never meets a NaN" invariant.
        guard let v = value, v.isFinite else { return nil }
        return v
    }
}

// MARK: - StockSagePriceHistory
//
// A daily OHLC candle history for one symbol (newest LAST) — the input the
// indicators + advisor consume. Parallel arrays (kept equal-length by the parser)
// make windows cheap to slice. Sendable so it crosses the fetch → main-actor hop.
struct StockSagePriceHistory: Sendable, Equatable {
    let symbol: String
    let dates: [Date]
    let opens: [Double]
    let highs: [Double]
    let lows: [Double]
    let closes: [Double]
    let volumes: [Double]

    nonisolated var count: Int { closes.count }
    nonisolated var latestClose: Double? { closes.last }
}

// MARK: - StockSageUniverse
//
// The "whole world" default watchlist: blue-chip names + benchmark indices across
// every inhabited continent, in Yahoo symbology. Saudi/Tadawul leads (the owner's
// home market); the rest spans the Americas, Europe, the Middle East, Asia and
// Oceania so the Markets tab is genuinely global out of the box. The `market`
// label (with a flag) is what the watchlist/heatmap show under each ticker, so
// regions stay visually grouped in feed order. Extend freely — every downstream
// layer is symbol-agnostic.
enum StockSageUniverse {
    // (friendly market label, tickers). Explicitly typed so the big literals
    // type-check cheaply (Swift's inference chokes on a bare tuple-array).
    //
    // TWO source tiers, kept as separate literals for provenance/labeling, but as of the
    // equity-2000 promotion (PLAN_2026-07-08_equity2000.md Stage 2, 2026-07-08) BOTH are
    // bulk-fetched/analyzed — the pre-promotion "catalogExtra is searchable-only, never
    // bulk-fetched" split no longer holds:
    //   • `groups`       — the curated Saudi-first CORE (~210 names). Still `worldwide[0]`'s
    //                      source, still what `StockSageUniverse.core`/`marketCount` key off
    //                      of, and still the monitor's own background-cycle scope (review
    //                      round-2 finding 1) — but no longer the WHOLE analyzed universe.
    //   • `catalogExtra` — the ~2,210-name discovery long-tail. PROMOTED: now bulk-fetched and
    //                      scanned exactly like `groups` (both feed `worldwide` — see its own
    //                      doc comment below), not just searchable/one-tap-addable.
    // Together they form `worldwide`/`catalog` (identical, deduped groups-first) — the full
    // 2,420-name analyzed + searchable universe.

    private static let groups: [(label: String, tickers: [String])] = [
        // ── Home market first (owner directive: Aramco / Tadawul leads the universe) ──
        ("🇸🇦 Tadawul (TASI)",     ["2222.SR", "1120.SR", "7010.SR", "2010.SR", "1180.SR", "2350.SR",
                                    // ── Expansion (2026-06-27): verified large/mid-cap TASI constituents.
                                    //    Aramco (2222.SR) stays first; all below are appended after it.
                                    // Banks
                                    "1010.SR", "1060.SR", "1150.SR", "1080.SR", "1140.SR",
                                    // Materials / Petrochem
                                    "1211.SR", "2020.SR", "2290.SR", "2380.SR", "2330.SR",
                                    // Telecom
                                    "7020.SR", "7030.SR",
                                    // Consumer / Food
                                    "2280.SR", "4190.SR", "6010.SR",
                                    // Utilities / Transport
                                    "5110.SR", "4030.SR",
                                    // Healthcare
                                    "4013.SR", "4014.SR",
                                    // Insurance
                                    "8010.SR", "8210.SR",
                                    // Cement
                                    "3030.SR"]),
        // ── United States (mega/large cap, by sector) ──
        ("🇺🇸 US Mega-cap Tech",   ["AAPL", "MSFT", "NVDA", "GOOGL", "AMZN", "META", "AVGO", "TSLA", "ORCL", "AMD"]),
        ("🇺🇸 US Semis & Hardware", ["INTC", "QCOM", "TXN", "MU", "AMAT", "ADI", "LRCX", "KLAC", "CSCO", "IBM"]),
        ("🇺🇸 US Software",        ["CRM", "ADBE", "NOW", "INTU", "PANW", "SNPS", "CDNS", "NFLX"]),
        ("🇺🇸 US Financials",      ["JPM", "BAC", "WFC", "GS", "MS", "C", "BLK", "SCHW", "AXP", "V", "MA"]),
        ("🇺🇸 US Health",          ["UNH", "JNJ", "LLY", "PFE", "MRK", "ABBV", "TMO", "ABT", "DHR", "AMGN"]),
        ("🇺🇸 US Consumer",        ["HD", "MCD", "NKE", "SBUX", "COST", "WMT", "PG", "KO", "PEP", "DIS"]),
        ("🇺🇸 US Energy & Industrials", ["XOM", "CVX", "COP", "BA", "CAT", "GE", "HON", "UPS", "RTX", "LMT"]),
        ("📊 ETFs (broad & sector)", ["SPY", "QQQ", "DIA", "IWM", "VTI", "XLK", "XLF", "XLE", "XLV", "GLD", "SLV", "TLT"]),
        // ── International (blue chips by exchange) ──
        ("🇬🇧 London (LSE)",       ["SHEL.L", "AZN.L", "HSBA.L", "ULVR.L", "BP.L", "GSK.L"]),
        ("🇩🇪 Frankfurt (XETRA)",  ["SAP.DE", "SIE.DE", "ALV.DE", "BMW.DE"]),
        ("🇫🇷 Paris (Euronext)",   ["MC.PA", "OR.PA", "AIR.PA", "TTE.PA"]),
        ("🇯🇵 Tokyo (TSE)",        ["7203.T", "6758.T", "9984.T", "8306.T"]),
        ("🇭🇰 Hong Kong (HKEX)",   ["0700.HK", "9988.HK", "3690.HK"]),
        ("🇨🇳 Shanghai (SSE)",     ["600519.SS"]),
        ("🇰🇷 Seoul (KRX)",        ["005930.KS", "000660.KS"]),
        ("🇮🇳 Mumbai (NSE)",       ["RELIANCE.NS", "TCS.NS", "INFY.NS", "HDFCBANK.NS"]),
        ("🇹🇼 Taiwan (TWSE)",      ["2330.TW", "2317.TW"]),
        ("🇸🇬 Singapore (SGX)",    ["D05.SI", "O39.SI"]),
        ("🇦🇺 Sydney (ASX)",       ["BHP.AX", "CBA.AX", "CSL.AX"]),
        ("🇧🇷 São Paulo (B3)",     ["PETR4.SA", "VALE3.SA", "ITUB4.SA"]),
        ("🇲🇽 Mexico (BMV)",       ["AMXB.MX", "WALMEX.MX"]),
        ("🇨🇦 Toronto (TSX)",      ["RY.TO", "SHOP.TO", "ENB.TO"]),
        // ROG.SW removed 2026-07-09: persistent HTTP 404 on this service's own fetch path
        // (retried + re-probed 5× same-day — dead on Yahoo, NOT a throttle), so it failed
        // every live scan and only ever contributed to the "couldn't be fetched" line.
        // Found by the (otherwise superseded) universe-1024 verification lane.
        ("🇨🇭 Zurich (SIX)",       ["NESN.SW", "NOVN.SW"]),
        ("🇳🇱 Amsterdam (Euronext)", ["ASML.AS", "ADYEN.AS"]),
        ("🇪🇸 Madrid (BME)",       ["SAN.MC", "IBE.MC", "ITX.MC"]),
        ("🇮🇹 Milan (Borsa)",      ["ENI.MI", "ISP.MI", "RACE.MI"]),
        ("🇸🇪 Stockholm (OMX)",    ["VOLV-B.ST", "ERIC-B.ST"]),
        ("🇦🇪 Dubai (DFM)",        ["EMAAR.AE", "DEWA.AE"]),   // Yahoo .AD/.DU don't price; ADX names (FAB/ADCB/ADNOC/ALDAR) have no working Yahoo code — DFM .AE is the only reliable UAE format (verified live 2026-06-27)
        ("🇶🇦 Qatar (QSE)",        ["QNBK.QA", "IQCD.QA", "QIBK.QA", "MARK.QA"]),
        ("🇪🇬 Egypt (EGX)",        ["COMI.CA"]),
        ("🇿🇦 Johannesburg (JSE)", ["NPN.JO", "AGL.JO"]),
        ("🌍 World indices",       ["^GSPC", "^IXIC", "^DJI", "^RUT", "^VIX", "^FTSE", "^GDAXI", "^FCHI", "^STOXX50E", "^N225", "^HSI", "^NSEI", "^TWII", "^STI", "^BVSP", "^AXJO", "^GSPTSE", "^TASI.SR"]),
        // Forex (Yahoo `=X` pairs) — trades ~24×5; SAR included for the owner's home currency.
        ("💱 Forex (24×5)",        ["EURUSD=X", "GBPUSD=X", "USDJPY=X", "USDSAR=X", "USDCNY=X", "AUDUSD=X", "USDCAD=X", "USDCHF=X"]),
        // Crypto (Yahoo `-USD`) — trades 24/7 and is far more volatile than equities.
        ("₿ Crypto (24/7)",        ["BTC-USD", "ETH-USD", "SOL-USD", "XRP-USD", "BNB-USD", "ADA-USD", "DOGE-USD", "AVAX-USD", "DOT-USD", "LINK-USD"]),
    ]

    // Discovery long-tail — PROMOTED (Stage 2, 2026-07-08): now bulk-fetched/analyzed exactly
    // like `groups` (see the header comment above `groups`), not just searchable/addable.
    // Real, liquid Yahoo tickers; if one ever fails to price, the caller says so honestly.
    private static let catalogExtra: [(label: String, tickers: [String])] = [
        // SQ removed 2026-07-09: persistent HTTP 404 (Block, Inc. trades as XYZ now — already
        // in catalogExtra and verified fetchable, so coverage is unchanged). Found by the
        // full-catalog CFNetwork sweep: the ONLY corpse among 2,419 symbols.
        ("🇺🇸 US Tech & Growth",   ["GOOG", "MRVL", "ON", "MCHP", "NXPI", "SNOW", "PLTR", "CRWD", "DDOG", "ZS", "NET", "WDAY", "TEAM", "DELL", "HPQ", "UBER", "ABNB", "COIN", "PYPL", "SHOP", "MDB", "DOCU", "ROKU", "PINS"]),
        ("🇺🇸 US Financials+",     ["SPGI", "MCO", "ICE", "CME", "COF", "USB", "PNC", "TFC", "BX", "KKR", "APO", "MET", "PRU", "AIG", "TRV"]),
        ("🇺🇸 US Health+",         ["VRTX", "REGN", "BMY", "GILD", "CVS", "MDT", "ISRG", "ZTS", "SYK", "BDX", "HCA", "CI", "ELV", "BSX", "MRNA"]),
        ("🇺🇸 US Consumer+",       ["LOW", "TGT", "TJX", "BKNG", "PM", "MDLZ", "CL", "EL", "KHC", "GIS", "KMB", "MNST", "YUM", "CMG", "MAR"]),
        ("🇺🇸 US Energy/Industrial+", ["EOG", "SLB", "PSX", "MPC", "VLO", "OXY", "WMB", "KMI", "DE", "MMM", "GD", "NOC", "FDX", "EMR", "ETN", "ITW", "PH"]),
        ("🇺🇸 US Comms/Utility/Materials", ["T", "VZ", "TMUS", "CMCSA", "CHTR", "NEE", "DUK", "SO", "D", "LIN", "SHW", "FCX", "NEM", "APD", "DOW"]),
        ("🇺🇸 US Real Estate",     ["PLD", "AMT", "EQIX", "SPG", "O", "CCI", "PSA", "WELL"]),
        ("📊 ETFs+ (broad/intl/bond)", ["VOO", "VEA", "VWO", "EFA", "EEM", "XLY", "XLP", "XLI", "XLU", "XLB", "XLRE", "XLC", "SMH", "SOXX", "ARKK", "USO", "HYG", "LQD", "VNQ", "SCHD", "DVY", "IEF", "AGG", "BND", "EWJ", "FXI", "EWZ", "INDA"]),
        ("🇬🇧 London+",            ["BARC.L", "LLOY.L", "VOD.L", "RIO.L", "BATS.L", "DGE.L", "NWG.L", "TSCO.L"]),
        ("🇩🇪 Frankfurt+",         ["BAS.DE", "BAYN.DE", "VOW3.DE", "MBG.DE", "DTE.DE", "DBK.DE", "IFX.DE", "ADS.DE"]),
        ("🇫🇷 Paris+",             ["SAN.PA", "BNP.PA", "SU.PA", "AI.PA", "EL.PA", "CS.PA"]),
        ("🇯🇵 Tokyo+",             ["6861.T", "9433.T", "6098.T", "7974.T", "8035.T", "4063.T"]),
        ("🇭🇰 Hong Kong+",         ["0941.HK", "1299.HK", "0005.HK", "0388.HK", "1810.HK"]),
        ("🇨🇳 Shanghai+",          ["601318.SS", "600036.SS", "601888.SS"]),
        ("🇰🇷 Seoul+",             ["005380.KS", "035420.KS"]),
        ("🇮🇳 Mumbai+",            ["ICICIBANK.NS", "BHARTIARTL.NS", "SBIN.NS", "HINDUNILVR.NS"]),
        ("🌏 Asia-Pacific+",       ["2454.TW", "U11.SI", "NAB.AX", "WBC.AX", "WES.AX"]),
        ("🌎 Americas+",           ["BBDC4.SA", "GFNORTEO.MX", "TD.TO", "CNR.TO", "BN.TO"]),
        ("🇪🇺 Europe+",            ["UBSG.SW", "ZURN.SW", "INGA.AS", "PRX.AS", "BBVA.MC", "UCG.MI", "ATCO-A.ST", "INVE-B.ST"]),
        ("💱 Forex+",              ["NZDUSD=X", "EURGBP=X", "EURJPY=X", "GBPJPY=X"]),
        ("₿ Crypto+",              ["MATIC-USD", "LTC-USD", "BCH-USD", "ATOM-USD", "UNI-USD", "ETC-USD", "NEAR-USD", "APT-USD"]),
        // ── 2000-stock expansion (2026-07-07): live-sourced (Nasdaq screener, mktcap-ranked),
        //    EVERY symbol verified fetchable via the app's Yahoo v8 path (2001 checked, 6 dropped).
        //    PROMOTED into the analyzed universe (PLAN_2026-07-08_equity2000.md Stage 2,
        //    2026-07-08): these names now join the Find-Ideas scan via `worldwide` —
        //    no longer "search-only, not auto-fetched" as originally landed.
        ("🇺🇸 US Technology (2000-expansion)", ["SPCX", "TSM", "GOOGM", "GOOGN", "ASML", "ARM", "SNDK", "APH", "WDC", "SAP", "STX", "APP", "VRT", "PDD", "FTNT", "ASX", "NTES", "DASH", "ALAB", "NOK", "MSI", "MPWR", "COHR", "UMC", "STM", "TEL", "HPE", "NBIS", "FLEX", "CRDO", "CRWV", "XYZ", "INFY", "ADSK", "CBRS", "RBLX", "CLS", "MCHPP", "BIDU", "RDDT", "GFS", "ROP", "ERIC", "JBL", "MSTR", "STRF", "UI", "NTAP", "TWLO", "VEEV", "STRC", "Q", "CW", "SMCIP", "OTIS", "HUBB", "P", "OKTA", "FSLR", "MTSI", "ZM", "TSEM", "VRSN", "STRK", "STRD", "IOT", "QNT", "CTSH", "WIT", "SNX", "FLUT", "LSCC", "SITM", "IONQ", "RBRK", "AMKR", "CDW", "TOST", "SMCI", "GEN", "SSNC", "IREN", "TTMI", "NVMI", "CHKP", "PTC", "NTNX", "LOGI", "DOCN", "LDOS", "TYL", "AUR", "DT", "VICR", "U", "SMTC", "RMBS", "FROG", "AEIS", "SANM", "GWRE", "VSAT", "GDDY", "CACI", "FIG", "WULF", "PL", "TEM", "SIMO", "ALGM", "JKHY", "ARW", "HUBS", "VIAV", "BSY", "AAOI", "COMP", "SWKS", "FORM", "MANH", "TTD", "ABTC", "SAIL", "YMM", "FDS", "MTCH", "MXL", "MBLY", "QBTS", "SNAP", "ENS", "QRVO", "YOU", "CRUS", "BILI", "TTAN", "MRCY", "PLXS", "SLAB", "MQ", "SATA", "VSH", "HNGE", "AVT", "NAVN", "BB", "PAYC", "DBX", "PCOR", "CAMT", "ACMR", "BZ", "DSGX", "KLIC", "GLBE", "APPF", "S", "CVLT", "GDS", "PSN", "PATH", "PCTY", "INGM", "ESTC", "DUOL", "RGTI", "ENPH", "NICE", "ACIW", "OTEX", "QLYS", "GTLB", "DOX", "ZETA", "VRNS", "PEGA", "KVYO", "SRAD", "MARA", "NTSK", "OCTV", "SAIC", "SYNA", "UCTT", "LIF", "WAY", "TENB", "EPAM", "PI", "DIOD", "IPGP", "ACLS", "DOCS", "AXTI", "CLBT", "ONDS", "POWI", "BILL", "LFTO", "BOX", "MNDY", "OLED", "LASR", "NVTS", "OSIS", "JOYY", "XNDU", "PPLI", "AMBA", "SEDG", "FA", "PENG", "TDC", "QTWO", "CCC", "ICHR", "VECO", "RNG", "ADEA", "CARG", "AGYS", "DSC", "BHE", "PONY", "SOUN", "NTCT", "MGNI", "BRZE", "NIQ", "WK", "FSLY", "RUM", "GRND", "FRSH", "VISN", "WIX", "KC", "RGTIW", "KD", "INFQ", "NYAX", "STNE", "PAGS", "AVPT", "IMOS", "CMCM", "HIMX", "ALRM", "DJT", "INOD", "PDFS", "RAMP", "VNET", "SPSC", "PLUS", "ATHM", "INTA", "QUBT", "VERX"]),
        ("🇺🇸 US Finance (2000-expansion)", ["HSBC", "RY", "MUFG", "SAN", "TD", "SMFG", "IBKR", "UBS", "BBVA", "HDB", "CB", "PGR", "MFG", "BMO", "HOOD", "IBN", "BNS", "CM", "BNY", "BCS", "ING", "LYG", "ITUB", "MRSH", "NWG", "AON", "DB", "MFC", "NU", "AJG", "ALL", "AFL", "FITB", "HBANL", "BMNP", "STT", "NDAQ", "AMP", "IX", "RKT", "SLF", "HBANM", "CBRE", "KB", "HBANZ", "ARES", "BSBR", "HIG", "BAP", "BBD", "HBAN", "PUK", "ACGL", "MTB", "SHG", "NTRS", "HBANP", "RJF", "BBDO", "CFG", "CINF", "AFRM", "CBOE", "WTW", "NMR", "WRB", "RF", "SYF", "TROW", "KEY", "MKL", "FCNCA", "LPLA", "PFG", "TW", "L", "SOFI", "BRO", "EFX", "BCH", "BPYPM", "EWBC", "BEN", "INVH", "BPYPP", "BPYPO", "CRCL", "BEKE", "AEG", "TPG", "BPYPN", "CG", "BSAC", "TRU", "JLL", "PNFP", "WF", "BNT", "OWL", "EG", "RGA", "APOS", "KKRS", "UNM", "ALLY", "PS", "VLYPN", "CRBG", "KLAR", "CNA", "AIZ", "SLMBP", "VLYPO", "RNR", "FUTU", "EVR", "VLYPP", "GL", "EQH", "ARCC", "FNF", "CET", "WBS", "IVZ", "FHN", "ERIE", "AFG", "CSGP", "HUT", "SF", "SEIC", "JEF", "WTFC", "UMBF", "RYAN", "BPOP", "ZION", "CIB", "ONB", "ORI", "GLXY", "SSB", "HLI", "CFR", "VIRT", "SNEX", "ONBPP", "ONBPO", "AMG", "PRI", "COLB", "FRHC", "WAL", "CIFR", "BMNR", "VOYA", "RIOT", "CBSH", "PB", "BOKF", "XP", "GGAL", "AXS", "VLY", "CHYM", "KNSL", "PRH", "PRS", "THG", "JXN", "FIGR", "LNC", "GJS", "TRNO", "CORZ", "CORZZ", "FAF", "OMF", "PJT", "CACC", "GBCI", "IFS", "FNB", "MAAS", "ACGLO", "FSV", "UBSI", "ACT", "MORN", "ABCB", "FLG", "MCY", "HWC", "LMND", "BMA", "AUB", "AVAL", "SEZL", "CGABL", "ESNT", "MTG", "PFH", "SIGI", "ENVA", "HOMB", "ASB", "AX", "VCTR", "RLI", "ACGLN", "MC", "OZK", "OBDC", "WTM", "BGC", "EBC", "STEP", "PIPR", "CORZW", "RDN", "DAVE", "CIGI", "ATHS", "TFSL", "FFIN", "GPGI", "MRX", "HASI", "OPEN", "CNO", "MAIN", "LAZ", "NNI", "SLM", "SFBS", "IBOC", "MRP", "FULT", "NP", "TCBI", "HLNE", "HCXY", "FHI", "PFSI", "OXLCM", "OXLCN", "OXLCZ", "UCB", "BBAR", "OXLCL", "HGTY", "CATY", "OXLCO", "MKTX", "FBP", "INDB", "CNS", "PDI", "WSFS", "CVBF", "BLSH", "MIAX", "RNST", "BWIN", "WSBC", "BANF", "BULL", "FIBK", "CII", "PLMR", "FG", "UNMA", "XXI", "BHF", "AGO", "ASBA", "FHB", "GNW", "FFBC", "BKU", "MCHB", "CBU", "NAN", "NIC", "UWMC", "NTRSO", "FULTP", "BTDR", "CLSK", "AB", "HG", "CURB", "VAC", "GBDC", "PRK", "ETOR", "SFNC", "BOH", "CSQ", "UPST", "CRVL", "CWK", "SBCF", "BANC", "NMIH", "FGN", "VTMX", "PFS", "SII", "HTGC", "EEFT", "APAM", "FBK", "KEEL", "ARX", "FSK", "SPNT", "UE", "WT", "AAMI", "WAFD", "NMRK", "GCMG", "FRME", "TRMK", "ZIONP", "TOWN", "TBBK", "GDV", "CUBI", "FBNC", "NBTB", "BBT", "INTR", "BUSE", "WSBCO", "SKWD", "NTB", "EFSC", "SLDE", "LCLN", "HCI", "SYBT", "BANR", "HAPN", "HTH", "CLBK", "NWBI", "MBIN", "BUSEP", "HMN", "AGM", "BLX", "PLGO", "OFG", "FCF"]),
        ("🇺🇸 US Consumer Discretionary (2000-expansion)", ["BABA", "UL", "SPOT", "MELI", "ACN", "ECL", "HLT", "CVNA", "RCL", "BAM", "ORLY", "URI", "ROST", "PCAR", "WBD", "SE", "DAL", "RELX", "FAST", "BKR", "EA", "EBAY", "AZO", "TTWO", "VIK", "MSCI", "DHI", "HLN", "LYV", "UAL", "SYY", "TRI", "CCL", "KVUE", "TKO", "JD", "RYAAY", "CPNG", "QSR", "EXPE", "ASTS", "LVS", "SUNB", "CASY", "FICO", "TPR", "ECHO", "PPG", "FISV", "AER", "INIO", "CPRT", "FTI", "WSM", "TCOM", "DG", "IHG", "PHM", "LUV", "XPO", "SW", "ONON", "DLTR", "CPAY", "DRI", "CHD", "OMC", "USFD", "SNA", "FIS", "RBA", "GPN", "LEN", "SN", "PKG", "AMCR", "ROL", "DKS", "BURL", "ULTA", "AS", "APG", "H", "FDXF", "NVR", "MGA", "PFGC", "GPC", "BIP", "BR", "LTM", "SGI", "BBY", "NWS", "AKAM", "QXO", "WSO", "GRAB", "TSCO", "WCC", "GNRC", "YUMC", "ARMK", "DECK", "NWSA", "RRX", "TOL", "SWK", "WMG", "RPM", "GIB", "TME", "BWA", "UHAL", "DKNG", "HTHT", "PAC", "AVY", "APTV", "LULU", "MOD", "W", "TXRH", "AIT", "PAG", "ALLE", "MGM", "BROS", "NYT", "CLX", "AAL", "WMS", "BIPJ", "BJ", "CART", "HAS", "SCI", "AYI", "PSO", "MUSA", "SIRI", "GSAT", "PAYP", "GME", "DPZ", "AGX", "R", "WYNN", "FCFS", "LLYVK", "FIVE", "ALSN", "GIL", "LEVI", "LLYVA", "MSGS", "ASR", "TTC", "LTH", "IT", "ALV", "ACM", "CNM", "BLDR", "NCLH", "CHWY", "AOS", "BIRK", "LGN", "CAVA", "FRO", "SSD", "TTEK", "HQY", "DDS", "STN", "POOL", "EAT", "Z", "ZG", "RTO", "RSI", "AXTA", "BAH", "SGHC", "BIPH", "ECG", "KMX", "ETSY", "KEX", "MHK", "LAD", "GAP", "GOLF", "RRR", "TMHC", "LEA", "VSEC", "LKQ", "BYD", "BBUC", "VIPS", "NOV", "AN", "MMYT", "CPA", "GATX", "CROX", "M", "CHDN", "GTX", "VSXY", "MATX", "FND", "CZR", "WH", "IBP", "RUSHB", "WFRD", "PSMT", "URBN", "GXO", "LYFT", "MDA", "RUSHA", "SON", "ALK", "CAR", "REYN", "FTDR", "OMAB", "AMTM", "SPHR", "ADT", "MTH", "GNTX", "WEX", "STUB", "RELY", "MTN", "GLNG", "PTRN", "SEI", "HRB", "XMTR", "SITE", "G", "GBTG", "CHH", "UNF", "IEP", "BOOT", "CMBT", "EQPT", "TNL", "FCN", "FELE", "WING", "SKY", "CVCO", "DLO", "BBWI", "ATAT", "DOO", "RXO", "OPLN", "ELF", "BRC", "ANDG", "ATMU", "CAAP", "INSW", "TPC", "DORM", "BFH", "LION", "OLLI", "PLNT", "EXLS", "HGV", "FOUR", "WHD", "ANF", "BFAM", "GEO", "PLBL", "SKYW", "MHO", "IPAR", "CHEF", "ABG", "MANU", "CAKE", "STNG", "MAT", "WPP", "KBH", "MNSO", "YETI", "PII", "BATRA", "ZGN", "KFY", "MSGE", "HAFN", "PAY", "GPI", "CNK", "RHI", "AZUL", "AAP", "TDW", "NSIT", "BATRK", "CALY", "GRBK", "COLM", "SIG", "RH", "GPK", "ASH", "BWLP", "CSAN", "HNI", "EXPO", "PHIN", "MMS", "HWKN", "SBLK", "ASO", "UAA", "SHOO", "PK", "VC", "ZIM", "MGRC", "TRMD", "UA", "PENN", "DAN", "PATK", "UNFI", "OSW", "AEO", "DHT", "WLYB", "SAH", "CENT", "WLY", "HOG", "BCC", "ASTH", "ABM", "PTON", "LCII", "AERO", "TNET", "WU", "DRVN", "BLBD", "WHR", "CALX", "VVX", "FBYD", "PAYO", "TNK", "CENTA", "DNOW", "SHAK", "CMPR", "DAC", "CTOS", "MCRI", "JBLU", "FLYW", "NMM", "EZPW", "CPRI", "BKE", "CHA", "ALGT", "MLCO", "AIN", "BOBS", "NIPG", "ECO", "SHO"]),
        ("🇺🇸 US Health Care (2000-expansion)", ["AZN", "NVS", "NVO", "BTI", "MO", "GSK", "SNY", "MCK", "COR", "ARGX", "MDLN", "CAH", "EW", "HUM", "BTSGU", "IDXX", "ALNY", "TEVA", "NTRA", "RVMD", "ONC", "IQV", "ALC", "RPRX", "CNC", "RMD", "BIIB", "GEHC", "ILMN", "DXCM", "PHG", "ROIV", "WST", "INSM", "DGX", "BNTX", "LH", "UTHR", "INCY", "GH", "BDRX", "STE", "VTRS", "ULS", "GMAB", "THC", "NBIX", "ZBH", "ASND", "MEDP", "JAZZ", "BBIO", "DVA", "COO", "EXEL", "BTSG", "IONS", "SOLV", "ALGN", "FMS", "ICLR", "SNN", "ELAN", "PEN", "AXSM", "SMMT", "MDGL", "ARWR", "RDY", "MOH", "BAX", "ABVX", "BMRN", "CRL", "TECH", "PODD", "KRYS", "GMED", "CYTK", "EHC", "APGE", "HSIC", "CORT", "NUVL", "ENSG", "HALO", "APLD", "UHS", "OSCR", "KYMR", "IBRX", "ALKS", "HIMS", "PRAX", "GKOS", "TGTX", "PTGX", "PCVX", "QGEN", "RGEN", "IMVT", "SYRE", "RYTM", "MIRM", "PACS", "PTCT", "LQDA", "COGT", "LNTH", "MSA", "SRRK", "LGND", "CHE", "TWST", "CGON", "BLCO", "BLTE", "CRSP", "TFX", "ERAS", "XENE", "STVN", "BLLN", "RDNT", "AMRX", "TVTX", "CELC", "LEGN", "DNTH", "MANE", "SHC", "ALHC", "CAI", "ORKA", "INDV", "GRFS", "DFTX", "KNSA", "VCYT", "LIVN", "VKTX", "NVST", "CRNX", "ACAD", "TNGX", "EWTX", "MMED", "MMSI", "LFST", "IRTC", "TLX", "DNLI", "NAMS", "CON", "ICUI", "GPCR", "CPRX", "DYN", "RCUS", "BKD", "BEAM", "RLAY", "WRBY", "OGN", "ALMS", "PBLS", "IDYA", "ADPT", "PRVA", "HAE", "NHC", "OPCH", "RARE", "ARQT", "ITGR", "ELVN", "RLX", "KLRA", "CLDX", "GRAL", "IRON", "TARS", "VERA", "ACHC", "RGC", "MBX", "SUPN", "IMNM", "ESTA", "CLOV", "SLBT", "QURE", "BCRX", "SLS", "TRVI", "NTLA", "NRIX", "NKTR", "XRAY", "TMDX", "AXGN", "PGNY", "TAK", "BHVN", "MLYS", "VCEL", "LMAT", "HTFL", "ABCL", "KOD", "PBH", "PHVS", "PRKS", "MD", "AGIO", "SGRY", "GENB", "BFLY", "ZLAB", "HRMY", "ADMA", "OCUL", "UFPT", "RXRX", "KARD", "RVMDW", "AVAH"]),
        ("🇺🇸 US Industrials (2000-expansion)", ["TM", "UNP", "GLW", "HWM", "TT", "PWR", "ADP", "CMI", "RACE", "CSX", "JCI", "CP", "HONA", "TDG", "CNI", "NSC", "CRH", "CTAS", "BRKRP", "GM", "GWW", "FIX", "TER", "CARR", "LHX", "F", "KEYS", "AME", "RKLB", "ROK", "NUE", "HEI", "AXON", "MT", "FER", "GRMN", "ODFL", "HMC", "WAB", "VMC", "PAYX", "ESLT", "WAT", "A", "MLM", "EME", "STLD", "IR", "NTR", "CRS", "TDY", "MTZ", "TECK", "AMRZ", "DOV", "TS", "XYL", "SYM", "ATI", "JBHT", "MTD", "RIVN", "NVT", "MKSI", "FWONK", "FTAI", "VRSK", "RL", "FOXA", "FWONA", "VLTO", "CHRW", "ENTG", "STRL", "EXPD", "IFF", "SQM", "FOX", "LII", "FTV", "RBC", "RS", "DD", "ARXS", "MAIR", "CX", "BWXT", "ZTO", "NXT", "CF", "RGLD", "LYB", "ITT", "PKX", "STLA", "IEX", "BALL", "NDSN", "MAS", "WSE", "TXT", "ALB", "CLH", "J", "ONTO", "JHX", "CSL", "LECO", "CNH", "IESC", "AA", "XPEV", "DY", "ZBRA", "LI", "CR", "CCK", "RVTY", "NIO", "MLI", "GGG", "WTS", "TRMB", "PNR", "KNX", "EMBJ", "DRS", "OC", "SPXC", "HII", "TFII", "CGNX", "PSKY", "SAIA", "HL", "VMI", "SOLS", "DCI", "ESI", "SARO", "KTOS", "GTLS", "TKR", "WLK", "FLS", "BRKR", "OSK", "AAON", "AVAV", "JOBY", "AGCO", "GGB", "TX", "ZWS", "FSS", "MIDD", "ATR", "TEX", "BIO", "EMN", "RAL", "JBTM", "HXL", "LOAR", "XE", "NEU", "VFS", "NPO", "FLR", "ACA", "AVTR", "KRMN", "CMC", "LSTR", "MYRG", "GTES", "AWI", "MSM", "EXP", "MOS", "ST", "SSRM", "ICL", "GVA", "VFC", "MWH", "SNDR", "TFPM", "ROAD", "TV", "ESAB", "AIR", "NXST", "PRM", "MTRN", "BCPC", "SXT", "VSNT", "CE", "ALH", "BC", "TXG", "VVV", "PRIM", "SLGN", "REZI", "KNF", "KTB", "WSC", "KBR", "CECO", "CENX", "SIM", "AZZ", "CSW", "HRI", "CBT", "FLY", "BDC", "BETA", "BMI", "BCO", "GFF", "MDU", "SEB", "MIR", "CSTM", "LUNR", "VNT", "ACHR", "THO", "MWA", "AADX", "SMG", "SXI", "ITRI", "KAI", "HAYW", "AVNT", "PVH", "SMR", "UUUU", "CDNL", "LEU", "TTAM", "MEOH", "WDFC", "ARCB", "OUST", "FUL", "ATRO", "YSS", "CXT", "PSNY", "USLM", "KALU", "DCO", "POWWP", "TRN", "AMBP", "HUBG", "ATS", "FTAIM", "COHU", "KWR", "EFXT", "CC", "HSAI", "HLIO", "RDW", "WOR", "CHRN", "KMT", "LCID", "WERN", "NGVT", "BWNB", "DXPE", "ROG", "NWL", "NN", "AEHR", "ANDE", "OLN", "GRC", "AVEX", "ALG"]),
        ("🇺🇸 US Real Estate (2000-expansion)", ["BN", "DLR", "VTR", "IRM", "EXR", "AGNCN", "AGNCO", "AGNCZ", "AGNCP", "AGNCM", "VICI", "AGNCL", "AVB", "EQR", "BNJ", "BNH", "EDU", "SBAC", "ESS", "KIM", "WY", "NLY", "MAA", "LAMR", "HST", "WPC", "SUI", "DOC", "REG", "OHI", "UDR", "AGNC", "ELS", "GLPI", "AMH", "CPT", "EGP", "BXP", "FRT", "AHR", "LINE", "CTRE", "BRX", "ADC", "CUBE", "NNN", "ARE", "FR", "RHP", "REXR", "JAN", "VNO", "STAG", "MAC", "HR", "EPRT", "RYN", "STWD", "KRG", "OUT", "LAUR", "TAL", "PECO", "FRMI", "RITM", "GHC", "CUZ", "SBRA", "COLD", "KRC", "EPR", "SKT", "HHH", "CVSA", "DHCNI", "CDP", "REGCP", "REGCO", "LOPE", "BNL", "IRT", "APLE", "LRN", "NHI", "SLG", "HIW", "NSA", "JOE", "LXP", "RWTO", "RWTN", "CXW", "BXMT", "DBRG", "DX", "AKR", "MPT", "IVT", "UTI", "FCPT", "UNIT", "MFAO", "MFAN", "DRH", "ADAMI", "ADAMM", "PMTU", "PRDO", "DHC", "ADAML", "ADAMN", "ARR", "PEB", "DEI", "NTST"]),
        ("🇺🇸 US Consumer Staples (2000-expansion)", ["BUD", "SONY", "CTVA", "CCEP", "ABEV", "DEO", "FMX", "KDP", "ADM", "HSY", "KR", "STZ", "BG", "TSN", "MKC", "HRL", "JBS", "COKE", "SJM", "MICC", "SFD", "DAR", "PRMB", "CELH", "SFM", "TAP", "ACI", "PPC", "CPB", "CAG", "LW", "INGR", "KOF", "TBBB", "CALM", "POST", "COCO", "KN", "MZTI", "FIZZ", "TR", "FRPT", "GRDN"]),
        ("🇺🇸 US Energy (2000-expansion)", ["SHEL", "BHP", "TTE", "ENB", "PBR", "BP", "BE", "CNQ", "EQNR", "E", "SU", "MPLX", "IMO", "FANG", "DVN", "CVE", "WDS", "EQT", "EC", "TPL", "HAL", "PBA", "WWD", "EXE", "YPF", "PAA", "PR", "OVV", "VNOM", "FPS", "SUN", "DINO", "APA", "AR", "LFUS", "POWL", "RRC", "SOBO", "RIG", "SSL", "VIST", "SM", "CHRD", "MTDR", "NE", "PBF", "LB", "VAL", "HESM", "PAGP", "CNX", "MGY", "MUR", "CRC", "HCC", "CRK", "CNR", "WBI", "OII", "LBRT", "PLUG", "SUNC", "PTEN", "DK", "CLMT", "EROC", "ARLP", "HP", "MGEE", "PARR", "CRGY", "GPOR", "BKV", "CVI", "BSM", "BTE", "DKL", "NESR", "BTU", "EROK", "WTTR", "SDRL", "TALO", "MNR"]),
        ("🇺🇸 US Utilities (2000-expansion)", ["WM", "CEG", "NGG", "EPD", "AEP", "TRP", "ET", "RSG", "CIEN", "SRE", "TRGP", "SOMN", "OKE", "VST", "ETR", "LNG", "XEL", "EXC", "PCG", "WCN", "ED", "PEG", "WEC", "PPLC", "DTE", "AEE", "CQP", "NRG", "AXIA", "ATO", "FTS", "EIX", "CNP", "FE", "ES", "PPL", "VG", "AWK", "CMS", "BEP", "SOJC", "NI", "SOJD", "SBS", "EVRG", "LNT", "AQNB", "SOJE", "DUKB", "TLN", "FN", "WES", "KEP", "EMA", "DTM", "GFL", "BEPC", "SREA", "PNW", "ENLT", "WTRG", "AM", "AES", "OGE", "EMP", "EAI", "ENJ", "OKLO", "ELPC", "IDA", "FRVO", "KNTK", "UGI", "NFG", "BEPJ", "ORA", "CMSD", "CMSC", "SWX", "AROC", "CMSA", "TXNM", "ENIC", "CWST", "UGP", "POR", "CIG", "KGS", "NJR", "BKH", "BIPC", "OGS", "SR", "ENO", "PAM", "BEPI", "TGS", "EE", "AQN", "DTW", "NWE", "ELC", "BEPH", "TAC", "CWEN", "OTTR", "USAC", "KEN", "DTG", "DTB", "AVA", "AWR", "CWT", "CPK", "CTRI", "HTO", "HE", "CEPU", "RNW"]),
        ("🇺🇸 US Materials (2000-expansion)", ["SCCO", "RIO", "AEM", "VALE", "B", "WPM", "CCJ", "AU", "FNV", "GFI", "KGC", "IP", "PAAS", "CDE", "AGI", "HMY", "SUZ", "IAG", "MP", "HBM", "EGO", "AG", "EQX", "BVN", "NXE", "SBSW", "FBIN", "OR", "CLF", "LPX", "BTG", "WFG", "UEC", "TREX", "UFPI", "ALM", "USAR", "ORLA", "SKE", "CGAU", "SA", "DNN", "AYA", "NG", "ERO", "PPTA", "FSM", "TGB", "EXK", "MTX", "SVM", "HYMC"]),
        ("🇺🇸 US Telecom (2000-expansion)", ["CCZ", "ANET", "TBB", "AMX", "LITE", "VIV", "CHT", "VOD", "FFIV", "BCE", "RCI", "TU", "TIGO", "TLK", "SKM", "TIMB", "ESE", "KT", "DPC", "LUMN", "TEO", "IRDM", "TKC", "LBRDK", "LBRDA", "LILAP", "EXTR", "TDS", "VEON", "PHI", "LBTYB", "KYIV", "LBTYA", "LBTYK", "LBRDP", "AD", "IHS", "DGII", "ATEN"]),
        ("🇺🇸 US Other (2000-expansion)", ["BRK-A", "BRK-B", "GEV", "FERG", "KSPI", "TPGXL", "CAE", "CBC", "IDCC", "NOVT", "OGC", "AUGO", "OTF", "DLB", "QS", "BELFB", "EMAT", "GEF", "NATL", "ARIS", "FLNC", "RUN", "AAUC", "BELFA", "VGNT", "DBD", "NMFCZ", "BGSI", "NOVTU", "TE", "ATKR", "PBI"]),
    ]

    // ── OWNER DIRECTIVE (2026-07-16): "ONLY KEEP TADAWUL AND NASDAQ" ────────────────────────
    // The live universe is restricted to Tadawul (`.SR`) + NASDAQ-listed US names. The full
    // curated `groups`/`catalogExtra` literals are KEPT below as the historical source of truth
    // (rollback = delete this filter); `build(_:)` — the single choke point every accessor
    // (`worldwide`/`catalog`/`core`) routes through — applies the filter, so all views of the
    // universe stay consistent. NASDAQ membership is BAKED (the app carries no per-symbol
    // exchange metadata): classified 2026-07-16 against AlphaVantage LISTING_STATUS (state=
    // active, 14,189 rows; sanity anchors AAPL/MSFT/QQQ→NASDAQ, JPM/SPY/BRK-B→NYSE). Of the
    // prior universe's 2,218 US names: 872 NASDAQ (kept), 1,341 other-exchange (dropped),
    // 5 not in the active listing (AYA, BMNP, GOOGM, GOOGN, STRD — dropped). Everything else
    // (other countries, crypto, FX, indices, non-NASDAQ ETFs) leaves the universe. FX needed
    // for SAR conversions is fetched as INFRA by StockSageStore (never an idea/feed row);
    // ^GSPC/^VIX regime+benchmark fetches are direct-by-symbol and unaffected.
    nonisolated static let nasdaqListed: Set<String> = [
        "AAL", "AAOI", "AAON", "AAPL", "ABCL", "ABNB", "ABTC", "ABVX", "ACAD", "ACGL",
        "ACGLN", "ACGLO", "ACHC", "ACIW", "ACLS", "ACMR", "ACT", "ADAMI", "ADAML", "ADAMM",
        "ADAMN", "ADBE", "ADEA", "ADI", "ADMA", "ADP", "ADPT", "ADSK", "AEHR", "AEIS",
        "AEP", "AFRM", "AGIO", "AGNC", "AGNCL", "AGNCM", "AGNCN", "AGNCO", "AGNCP", "AGNCZ",
        "AGYS", "AKAM", "ALAB", "ALGM", "ALGN", "ALGT", "ALHC", "ALKS", "ALM", "ALMS",
        "ALNY", "ALRM", "AMAT", "AMBA", "AMD", "AMGN", "AMKR", "AMRX", "AMZN", "ANDE",
        "APA", "APGE", "APLD", "APP", "APPF", "ARCB", "ARCC", "ARGX", "ARLP", "ARM",
        "ARQT", "ARWR", "ARXS", "ASML", "ASND", "ASO", "ASTH", "ASTS", "ATAT", "ATRO",
        "AUGO", "AUR", "AVAH", "AVAV", "AVGO", "AVPT", "AVT", "AXGN", "AXON", "AXSM",
        "AXTI", "BANF", "BANR", "BATRA", "BATRK", "BBIO", "BCPC", "BCRX", "BDRX", "BEAM",
        "BELFA", "BELFB", "BGC", "BHF", "BIDU", "BIIB", "BILI", "BKNG", "BKR", "BLBD",
        "BLLN", "BLTE", "BMRN", "BND", "BNTX", "BOKF", "BPOP", "BPYPM", "BPYPN", "BPYPO",
        "BPYPP", "BRKR", "BRKRP", "BRZE", "BSY", "BTDR", "BTSG", "BTSGU", "BULL", "BUSE",
        "BUSEP", "BWIN", "BZ", "CACC", "CAI", "CAKE", "CALM", "CAMT", "CAR", "CARG",
        "CART", "CASY", "CATY", "CBC", "CBRS", "CBSH", "CCC", "CCEP", "CDNL", "CDNS",
        "CDW", "CECO", "CEG", "CELC", "CELH", "CENT", "CENTA", "CENX", "CG", "CGABL",
        "CGNX", "CGON", "CHA", "CHDN", "CHEF", "CHKP", "CHRD", "CHRN", "CHRW", "CHTR",
        "CHYM", "CIFR", "CIGI", "CINF", "CLBK", "CLBT", "CLDX", "CLMT", "CLOV", "CLSK",
        "CMCSA", "CME", "CMPR", "COCO", "COGT", "COHU", "COIN", "COKE", "COLB", "COLM",
        "COO", "CORT", "CORZ", "CORZW", "CORZZ", "COST", "CPB", "CPRT", "CPRX", "CRDO",
        "CRNX", "CROX", "CRSP", "CRUS", "CRVL", "CRWD", "CRWV", "CSCO", "CSGP", "CSQ",
        "CSX", "CTAS", "CTSH", "CVBF", "CVCO", "CVLT", "CWST", "CYTK", "CZR", "DASH",
        "DAVE", "DBX", "DDOG", "DFTX", "DGII", "DHC", "DHCNI", "DIOD", "DJT", "DKNG",
        "DLO", "DLTR", "DNLI", "DNTH", "DOCU", "DOO", "DORM", "DOX", "DPZ", "DRH",
        "DRS", "DRVN", "DSC", "DSGX", "DUOL", "DVY", "DXCM", "DXPE", "DYN", "EA",
        "EBAY", "EBC", "ECHO", "EEFT", "EFSC", "ELVN", "EMAT", "ENLT", "ENPH", "ENSG",
        "ENTG", "EQIX", "EQPT", "ERAS", "ERIC", "ERIE", "ESLT", "ESTA", "ETOR", "EVRG",
        "EWBC", "EWTX", "EXC", "EXE", "EXEL", "EXLS", "EXPE", "EXPO", "EXTR", "EZPW",
        "FA", "FANG", "FAST", "FBNC", "FBYD", "FCFS", "FCNCA", "FELE", "FER", "FFBC",
        "FFIN", "FFIV", "FHB", "FIBK", "FIGR", "FISV", "FITB", "FIVE", "FIZZ", "FLEX",
        "FLNC", "FLY", "FLYW", "FORM", "FOX", "FOXA", "FRHC", "FRME", "FRMI", "FROG",
        "FRPT", "FRSH", "FRVO", "FSLR", "FSLY", "FSV", "FTAI", "FTAIM", "FTDR", "FTNT",
        "FULT", "FULTP", "FUTU", "FWONA", "FWONK", "GBDC", "GCMG", "GDS", "GEHC", "GEN",
        "GENB", "GFS", "GGAL", "GH", "GILD", "GLBE", "GLNG", "GLPI", "GLXY", "GMAB",
        "GNTX", "GOOG", "GOOGL", "GPCR", "GRAB", "GRAL", "GRFS", "GSAT", "GTLB", "GTX",
        "HALO", "HAPN", "HAS", "HBAN", "HBANL", "HBANM", "HBANP", "HBANZ", "HIMX", "HLNE",
        "HON", "HONA", "HOOD", "HQY", "HRMY", "HSAI", "HSIC", "HST", "HTFL", "HTHT",
        "HTO", "HUBG", "HUT", "HWC", "HWKN", "HYMC", "IBKR", "IBOC", "IBRX", "ICHR",
        "ICLR", "ICUI", "IDCC", "IDXX", "IDYA", "IEF", "IEP", "IESC", "ILMN", "IMNM",
        "IMOS", "IMVT", "INCY", "INDB", "INDV", "INIO", "INOD", "INSM", "INTA", "INTC",
        "INTR", "INTU", "IONS", "IPAR", "IPGP", "IRDM", "IREN", "IRON", "IRTC", "ISRG",
        "ITRI", "JAZZ", "JBHT", "JBLU", "JD", "JKHY", "JOYY", "KALU", "KARD", "KC",
        "KDP", "KEEL", "KHC", "KLAC", "KLIC", "KLRA", "KMB", "KNSA", "KOD", "KRYS",
        "KSPI", "KTOS", "KYIV", "KYMR", "LAMR", "LASR", "LAUR", "LBRDA", "LBRDK", "LBRDP",
        "LBTYA", "LBTYB", "LBTYK", "LCID", "LECO", "LEGN", "LFST", "LFTO", "LFUS", "LGN",
        "LGND", "LI", "LIF", "LILAP", "LIN", "LINE", "LITE", "LIVN", "LKQ", "LLYVA",
        "LLYVK", "LMAT", "LNT", "LNTH", "LOGI", "LOPE", "LPLA", "LQDA", "LRCX", "LSCC",
        "LSTR", "LULU", "LUNR", "LYFT", "MAAS", "MANH", "MAR", "MARA", "MAT", "MBIN",
        "MBLY", "MBX", "MCHB", "MCHP", "MCHPP", "MCRI", "MDB", "MDGL", "MDLN", "MDLZ",
        "MEDP", "MELI", "MEOH", "META", "MGEE", "MGNI", "MGRC", "MIDD", "MIRM", "MKSI",
        "MKTX", "MLCO", "MLYS", "MMED", "MMSI", "MMYT", "MNDY", "MNST", "MORN", "MPWR",
        "MQ", "MRCY", "MRNA", "MRVL", "MRX", "MSFT", "MSTR", "MTCH", "MTSI", "MU",
        "MWH", "MXL", "MYRG", "MZTI", "NAMS", "NATL", "NAVN", "NBIS", "NBIX", "NBTB",
        "NDAQ", "NDSN", "NESR", "NFLX", "NICE", "NIPG", "NKTR", "NMFCZ", "NMIH", "NMRK",
        "NN", "NOVT", "NOVTU", "NRIX", "NSIT", "NTAP", "NTCT", "NTES", "NTLA", "NTNX",
        "NTRA", "NTRS", "NTRSO", "NTSK", "NUVL", "NVDA", "NVMI", "NVTS", "NWBI", "NWE",
        "NWL", "NWS", "NWSA", "NXPI", "NXST", "NXT", "NYAX", "OCTV", "OCUL", "ODFL",
        "OKTA", "OLED", "OLLI", "OMAB", "ON", "ONB", "ONBPO", "ONBPP", "ONC", "ONDS",
        "OPCH", "OPEN", "ORKA", "ORLY", "OSIS", "OSW", "OTEX", "OTTR", "OUST", "OXLCL",
        "OXLCM", "OXLCN", "OXLCO", "OXLCZ", "OZK", "PAA", "PAGP", "PANW", "PATK", "PAYO",
        "PAYP", "PAYX", "PBLS", "PCAR", "PCTY", "PCVX", "PDD", "PDFS", "PECO", "PEGA",
        "PENG", "PENN", "PEP", "PFG", "PGNY", "PHVS", "PI", "PLBL", "PLMR", "PLTR",
        "PLUG", "PLUS", "PLXS", "PODD", "PONY", "POOL", "POWI", "POWL", "POWWP", "PPC",
        "PPLI", "PPTA", "PRAX", "PRDO", "PRVA", "PSKY", "PSMT", "PSNY", "PTC", "PTCT",
        "PTEN", "PTGX", "PTON", "PTRN", "PYPL", "QCOM", "QLYS", "QNT", "QQQ", "QRVO",
        "QS", "QUBT", "QURE", "RARE", "RDNT", "REG", "REGCO", "REGCP", "REGN", "RELY",
        "REYN", "RGC", "RGEN", "RGLD", "RGTI", "RGTIW", "RIOT", "RIVN", "RKLB", "RLAY",
        "RMBS", "RNW", "ROAD", "ROIV", "ROKU", "ROP", "ROST", "RPRX", "RRR", "RUM",
        "RUN", "RUSHA", "RUSHB", "RVMD", "RVMDW", "RXRX", "RYAAY", "RYTM", "SAIA", "SAIC",
        "SAIL", "SANM", "SATA", "SBAC", "SBCF", "SBLK", "SBRA", "SBUX", "SEDG", "SEIC",
        "SEZL", "SFD", "SFM", "SFNC", "SGRY", "SHC", "SHOO", "SHOP", "SIGI", "SIMO",
        "SIRI", "SITM", "SKWD", "SKYW", "SLAB", "SLBT", "SLDE", "SLM", "SLMBP", "SLS",
        "SMCI", "SMCIP", "SMH", "SMMT", "SMTC", "SNDK", "SNEX", "SNPS", "SNY", "SOFI",
        "SOLS", "SOUN", "SOXX", "SPCX", "SPSC", "SRAD", "SRRK", "SSNC", "SSRM", "STEP",
        "STLD", "STNE", "STRC", "STRF", "STRK", "STRL", "STX", "SUPN", "SWKS", "SYBT",
        "SYM", "SYNA", "SYRE", "TARS", "TBBK", "TCBI", "TCOM", "TEAM", "TECH", "TEM",
        "TENB", "TER", "TFSL", "TGTX", "TIGO", "TLN", "TLT", "TLX", "TMDX", "TMUS",
        "TNGX", "TOWN", "TPG", "TPGXL", "TRI", "TRMB", "TRMD", "TRMK", "TROW", "TRVI",
        "TSCO", "TSEM", "TSLA", "TTAN", "TTD", "TTEK", "TTMI", "TTWO", "TVTX", "TW",
        "TWST", "TXG", "TXN", "TXRH", "UAL", "UBSI", "UCTT", "UFPI", "UFPT", "ULTA",
        "UMBF", "UNIT", "UPST", "URBN", "USAR", "USLM", "UTHR", "VC", "VCEL", "VCTR",
        "VCYT", "VECO", "VEON", "VERA", "VERX", "VFS", "VIAV", "VICR", "VISN", "VKTX",
        "VLY", "VLYPN", "VLYPO", "VLYPP", "VNET", "VNOM", "VOD", "VRNS", "VRSK", "VRSN",
        "VRTX", "VSAT", "VSEC", "VSNT", "VTRS", "WAFD", "WAY", "WBD", "WDAY", "WDC",
        "WDFC", "WERN", "WFRD", "WING", "WIX", "WMG", "WMT", "WSBC", "WSBCO", "WSC",
        "WSE", "WSFS", "WTFC", "WTW", "WULF", "WWD", "WYNN", "XE", "XEL", "XENE",
        "XMTR", "XNDU", "XP", "XRAY", "Z", "ZBRA", "ZG", "ZION", "ZIONP", "ZLAB",
        "ZM", "ZS"
    ]

    /// The universe-membership rule: Tadawul (`.SR`) or baked-NASDAQ. Everything else is out.
    nonisolated static func isAllowedUniverseSymbol(_ symbol: String) -> Bool {
        let up = symbol.uppercased()
        return up.hasSuffix(".SR") || nasdaqListed.contains(up)
    }

    private static func build(_ gs: [(label: String, tickers: [String])]) -> [StockSageSymbol] {
        gs.flatMap { g in
            g.tickers.filter(isAllowedUniverseSymbol).map { StockSageSymbol(symbol: $0, market: g.label) }
        }
    }

    /// Equity-2000 promotion (PLAN_2026-07-08_equity2000.md Stage 2): the analyzed universe
    /// grows from the curated `groups` core to `groups` + the `catalogExtra` long-tail, so the
    /// Find-Ideas scan covers the full catalog instead of only the bulk-fetched core. Same
    /// dedup as `catalog` below (first occurrence wins) — groups come first in the flat-map so
    /// a symbol listed in both keeps its GROUPS market label and groups-first ordering
    /// (Aramco/Saudi-first invariant preserved: `groups`' first ticker is still `worldwide[0]`).
    static let worldwide: [StockSageSymbol] = {
        var seen: Set<String> = []
        var out: [StockSageSymbol] = []
        for s in build(groups) + build(catalogExtra) where seen.insert(s.symbol.uppercased()).inserted {
            out.append(s)
        }
        return out
    }()

    /// Distinct exchanges/regions covered by the bulk-fetched core — surfaced in the live
    /// banner ("N market groups"). Deliberately stays `groups.count` (NOT `worldwide`'s group
    /// count) after the equity-2000 promotion: every banner string pairs it with
    /// `worldwide.count` right beside it ("N market groups (M names)"), so the honest total
    /// universe size is already shown separately — this stays the honest count of curated,
    /// always-live-quoted groupings, not a claim about catalogExtra's group structure.
    // Post-restriction (2026-07-16): the honest count of groups that still carry ≥1 kept
    // name (Tadawul + the US sector groups' NASDAQ subsets) — `groups.count` (35) would
    // overstate coverage ~2.3× after the Tadawul+NASDAQ restriction.
    static let marketCount: Int = groups.filter { g in g.tickers.contains(where: isAllowedUniverseSymbol) }.count

    /// The curated Saudi-first CORE only (`groups`, pre-promotion's whole universe) — no dedup
    /// needed (`groups` alone has no cross-list collisions to resolve, unlike `worldwide`/`catalog`
    /// which also merge in `catalogExtra`). Exposed for the monitor's background auto-cycle
    /// (StockSageMonitor review round-2 finding 1): scoping the ~45s unattended loop to this
    /// ~210-name core + the user's watchlist, instead of Stage 2's full 2,420-name `worldwide`,
    /// avoids pulling the whole promoted universe unpaced on every cycle (feed-cooldown risk).
    /// User-initiated paths (the manual refresh button, the Find-Ideas scan) are UNCHANGED and
    /// still use `worldwide` — this accessor exists only for the background-cycle scope.
    static let core: [StockSageSymbol] = build(groups)

    /// The full searchable directory: now IDENTICAL to `worldwide` post-promotion (both are
    /// groups+catalogExtra deduped groups-first) — kept as a distinct name because callers use
    /// `catalog` for search/discovery semantics and `worldwide` for "the analyzed universe";
    /// same dedup (first occurrence wins, so a core symbol keeps its core market label).
    static let catalog: [StockSageSymbol] = {
        var seen: Set<String> = []
        var out: [StockSageSymbol] = []
        for s in build(groups) + build(catalogExtra) where seen.insert(s.symbol.uppercased()).inserted {
            out.append(s)
        }
        return out
    }()

    /// Case-insensitive catalog search for the add-ticker autocomplete: exact match
    /// first, then prefix, then substring, then a market-label hit. Pure + bounded.
    static func search(_ query: String, limit: Int = 8) -> [StockSageSymbol] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !q.isEmpty else { return [] }
        var scored: [(sym: StockSageSymbol, score: Int)] = []
        for s in catalog {
            let sym = s.symbol.uppercased()
            let score: Int
            if sym == q { score = 0 }
            else if sym.hasPrefix(q) { score = 1 }
            else if sym.contains(q) { score = 2 }
            else if s.market.uppercased().contains(q) { score = 3 }
            else { continue }
            scored.append((s, score))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score < $1.score : $0.sym.symbol.count < $1.sym.symbol.count }
            .prefix(limit).map(\.sym)
    }
}
