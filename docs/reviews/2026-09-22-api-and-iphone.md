# API connections and physical iPhone build — 22 September 2026

Owner requested verification after launching the Mac build, then explicitly requested building and running the phone app. The latter resumes iOS build/installation for this request; no widget feature work was requested.

## Mac credentials and actual connectivity

The running Mac executable is the DMG build `2f711da`, verified by SHA-256 `0a6f63139870f3e9fa8a632decf8adcd256fa3baedcf87e4467baa7e958d0fa9`. The older copy in Applications was not replaced. Native Settings → Test connection returned HTTP 200 with an AAPL snapshot. The existing native SIP stream was receiving trades and quotes.

The owner approved macOS Keychain access. The same saved Massive key was used in memory for bounded, read-only requests to `api.massive.com`; no credential was printed or saved in receipts. All 22 endpoint checks below returned HTTP 200 with the expected top-level data shape. Samples generally request one record. This proves access for these routes now, not complete data coverage, schema validation, redistribution permission or research readiness. No model research or orders were started.

| Endpoint family | HTTP | Sample latency, ms |
| --- | --- | --- |
| Snapshot | 200 | 557 |
| Daily history | 200 | 510 |
| Trade | 200 | 520 |
| Quote | 200 | 525 |
| News | 200 | 585 |
| Dividends | 200 | 521 |
| Splits | 200 | 555 |
| SEC 8-K via Massive | 200 | 536 |
| SEC Form 4 via Massive | 200 | 527 |
| Benzinga Earnings | 200 | 700 |
| Benzinga Guidance | 200 | 547 |
| Benzinga Ratings | 200 | 909 |
| Benzinga Analyst insights | 200 | 653 |
| Benzinga Bull bear | 200 | 549 |
| Benzinga Analysts | 200 | 515 |
| Benzinga Firms | 200 | 519 |
| Benzinga Consensus | 200 | 772 |
| Benzinga News | 200 | 1629 |
| Fundamentals ratios | 200 | 529 |
| Fundamentals income-statements | 200 | 581 |
| Fundamentals balance-sheets | 200 | 550 |
| Fundamentals cash-flow-statements | 200 | 544 |

Median sample latency was 548 ms (range 510–1,629 ms). These sequential single-request observations are not a throughput benchmark. The first audit-only consensus URL omitted the required ticker path and returned 404; the correct `/benzinga/v1/consensus-ratings/AAPL` route returned 200. Application source already uses the correct path.

- RunPod credentials authenticate a read-only pod listing. The accessible account has no running GPU or Gemma pod; no compute was started.
- StockSage's configured `127.0.0.1:18080` endpoint is unreachable. LM Studio at 1234 responds but its inventory has no Gemma. Account authentication does not establish model availability.
- Telegram has no saved bot token on this Mac. No verification or delivery request was sent.
- No SEC contact email is saved. Direct SEC requests were not repeated; the Massive 8-K and Form 4 routes passed independently.
- iPhone credentials are device-local and are not established by these Mac checks.

## Physical iPhone

Release source `8df6d22` compiled successfully and passed `codesign --verify --deep --strict`. Installed on the connected iPhone 16 Pro Max, iOS 27. Existing bundle ID `com.salman.StockSageX` and developer team are preserved through a local external xcconfig. Repository signing settings are untouched. An initial manual-signing attempt correctly refused Xcode-managed profiles; the retry uses their existing automatic-signing configuration.

Local logs and sanitized receipts: `/Users/salman/Documents/Codex/StockSage-Builds-2026-09-22/iphone-verification/`.

The initial manual-signing failure was resolved without changing tracked project settings. The successful Release build has one existing unused-local warning in `StockSageAllocationOptimizer.swift`. Binary SHA-256: `696a4dc912586e926831ea19aa1f5689c4c9a7b5392a7f14ef5fe8fdc5e2176f`. Source identity is recorded externally from repository HEAD and unchanged source diff; the custom Info.plist stamp was not emitted by Xcode. This build required compiling the existing widget dependency, but widget behavior and its app-group access were not tested.

Installation succeeded. The foreground launch request was denied by iOS with `Locked`: the phone needs owner unlock. The main app process was not running at the follow-up check (only its widget process). No uninstall, phone credential copy or source change was performed. Validation is a Release build/signature/install check, not a new native unit-test pass or completed runtime smoke test.

Guide edition 41: concise PDF renders to ten pages, all rendered pages reviewed. Prior local editions are preserved. The exact owner PDF path under `/Users/saleh` is absent on this Mac; replacement remains pending, and no PDF was sent.
