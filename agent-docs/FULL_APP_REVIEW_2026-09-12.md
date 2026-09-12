# StockSage full-app critique — current source and implementation ledger

Working review, 2026-09-12. This is not a claim that every runtime state, market,
device, or provider entitlement has been exercised. Baseline `ccee332` plus D4.

**Release update:** the subsequent owner-requested activity-ranked research selection is
also complete. The final combined-tree receipts are in **Research-selection follow-up**
below; they supersede the earlier gate counts for publication. The owner authorized commit,
merge to main and push. This does not authorize or claim installation of the running app.

## Assessment

The app already has strong evidence boundaries: explicit research versus paper
execution, dated source receipts, deterministic session/currency helpers, injected
services, and a large native test suite. The useful next work is to close gaps
where a view, cache, or asynchronous callback bypasses those boundaries—not add
more strategies or make more aggressive recommendations.

The critique found 22 actionable defects, concentrated in evidence provenance,
asynchronous ownership, persistence, and financial accounting. These are implemented
below; final platform receipts are recorded separately from implementation status.
Documentation and old audits were leads, not proof an old defect remained.

The most important design weakness was inconsistent enforcement at shared boundaries:
a fresh trade could carry an old closing-price basis; an old request could publish into
a new settings session; and a valid record could be replaced by another process's stale
copy. Fixing those boundaries is more valuable than adding screens or strategies.
The UI also needed to distinguish unknown, cached, incomplete, and paper-only values.

## Findings ledger

| ID | Severity | Finding / evidence | Status |
|---|---|---|---|
| U1 | P2 | Exact stale-boundary entry still looked fresh; malformed clock/decoded extreme dates were unsafe. | Fixed: equality/future/non-finite ages are stale; safe numeric conversion prevents age-label overflow. |
| U2 | P2 | Paper heat was ambiguous; unread paper-book counts appeared as zero. | Fixed: paper labels and optional unknown counts; backward decoding preserved. |
| U3 | P2 | Widget lacked cached-board provenance and used publication time as evidence time. | Fixed: supplied board time, cached/source metadata, no snapshot before a dated board. |
| T1 | P2 | Concurrent AppKit fixtures could become main-capable windows; earlier full UI failures did not reproduce alone. | Fixed fixture isolation; full-mac2 passed all affected UI checks. Capture appearance checked separately. |
| M1 | P2 | Massive credentials in ordinary preferences; CLI read that preference. | Fixed: verified Keychain migration, explicit save/remove, fail-closed errors; CLI environment only. Synthetic storage tests passed; owner Keychain not touched. |
| M2 | P2 | Token-limited schema repair could publish an accepted badge. | Fixed: completion metadata gates acceptance; incomplete draft remains identified. |
| M3 | P2 | Optional WhatsApp leads exceeded actual transport prompt allowance. | Fixed: fit whole-message prefix, preserve mandatory facts, disclose omissions and validate retained IDs. |
| M4 | P2 | Idle transport timeout was not a total request deadline. | Fixed: monotonic per-request deadline, prompt caller cancellation, late-result rejection. Actual worker retains its concurrency slot until it finishes. |
| M5 | P2 | Obsolete assessment retained/published into the settings session's slot. | Fixed: synchronous owner invalidation and post-await identity/cancellation guards, including repair and errors. |
| M6 | P2 | Catalyst Explain discarded completion metadata. | Fixed: detailed completion and explicit incomplete-draft status. |
| D1 | P1 | Streamed trade retained obsolete previous close; REST price ordering rejected its repair. | Fixed: separate baseline provenance/merge, supported-session carry only, unknown-aware signals/briefings/sorts. Reproduced old 100 → corrected 110 independently of latest trade. |
| D2 | P2 | Older competing earnings check could publish last. | Fixed: per-symbol request ownership and deterministic overlap test. |
| D3 | P2 | Cache file-save age was presented as price age. | Fixed: banner no longer equates the clocks; per-row source and observation age remain visible. |
| D4-cache | P2 | A 252-return calculation lost its required 253rd close. | Fixed: retention and cache version; actual boundary regression passed. |
| D5 | P2 | Fresh regime computation hid old/missing constituent evidence. | Fixed: dated sources, unchanged coverage floor, invalid-index retention, evidence expiry and UI disclosure. |
| D6 | P2 | Multi-timeframe/liquidity/trailing results never invalidated. | Fixed: refresh on visit, invalidate after completed scan, deny/clear obsolete results, per-key ownership; weekly coverage handles a Monday holiday. |
| D7 | P2 | Malformed SEC arrays became an answered-empty check. | Fixed: validate mandatory column shapes/dates and distinguish invalid payload from valid emptiness. |
| P1 | P1 | Competing closures overwrote each other, even during an unrelated save. | Fixed: persisted closure wins unless an explicit correction matches its original; deterministic conflict regressions passed. |
| P2 | P1 | Record stores lacked cross-process writer ownership. | Fixed: native advisory file lease before load/write, shared guard on mutation paths; separate-process contention test passed. |
| P3 | P2 | Off-catalog held positions could lose exit-history coverage. | Fixed: rotating bounded exit-only history supplementation; no watchlist/entry-scope expansion. |
| P4 | P2 | Minimum fees mixed major currency with raw pence/cents. | Fixed: canonical unit conversion; risk limits and fee tariff unchanged. |
| P5 | P2 | Severe gap costs could turn exit price nonpositive and erase the loss from statistics. | Fixed: positive gross fill plus explicit paper cost; P&L/R subtract once. Legacy decoding preserved; lossy CSV export rejected explicitly. |

## Coverage / limits

- Market/research: reviewed streaming/REST merges, timestamps, cache and baseline provenance,
  screening consumers, earnings/catalysts, SEC parsing and derived-study freshness.
- Qwen/harness/settings/security: reviewed prompt fitting, validation, transport deadlines,
  cancellation/reconfiguration, completion metadata and credential persistence.
- Paper/session/accounting/persistence: reviewed closure conflicts, exit-history recovery,
  fee units, loss accounting, record leases and restore/import boundaries. Existing native
  fill/session/settlement tests remain part of the full gates; their passing status does
  not prove executable live fills or profitability.
- UI/navigation/accessibility/widget/test isolation: source/caller review plus synthetic
  native interaction/render checks. No speculative navigation redesign in this batch.
- Three independent read-only reviewers completed bounded source reviews; no remaining
  verified must-fix findings in their final data, model and accounting scopes.
- Broker: source search found no executable broker adapter/submission client in this
  checkout. Onboarding says the app prepares orders but never places them. Broker names
  in help, cost comments and the IBKR stock symbol are not integration readiness.
  No adapter/relay was enabled or exercised.
- Live APIs, actual fills, model quality/profitability, owner-data recovery: no new
  claims from offline checks. No owner records, credentials or API calls used.
- Running app: `/Applications/StockSageX.app` remains intact; it is not assumed
  to match this worktree. Native UI connection failed before inspection.

## Evidence

- D4 receipt: `HANDOFF-CODEX-2026-09-12.md` appendix; prior evidence under
  `/private/tmp/stocksage-d4-codex-KfDey5/`.
- Current focused baseline: `ui-baseline.log` / `ui-baseline.xcresult` under
  `/private/tmp/stocksage-full-review-20260912-6Oi5VM/`: 73 tests, six suites, passed.

## Integration checkpoint — September 12, 17:30 local

Historical checkpoint only: the current table and final integration receipt supersede
these intermediate statuses.

- Implemented and focused-green: U1–U3, M1–M6, D2/D3/D4-cache/D7, P1/P2/P4/P5.
- P3 exit-only supplemental history implemented. Rotation passed; its initial stop fixture
  lacked the required entry bar. Corrected to a two-bar fixture; subsequent exit checks passed.
- D5 input-date validation and source disclosure implemented. Coverage, expiry, and retained
  prior result assertions passed; corrected one test's nil-versus-false assertion and rerunning.
- D1 reproduced: a newer streamed trade kept previous close 100 after REST supplied 110.
  Metadata/carry-forward/independent baseline repair now implemented; focused replay underway.
- D6 and T1 remain implementation/integration work. Final full platform gates and visual review
  have not yet run on this diff. No final all-app verification claim.

Evidence under the root above:

- `evidence-green`: 79 tests / four suites passed; widget green: seven tests passed.
- `lifecycle-accounting`: 173 tests / eight suites passed.
- `writer-ownership`: 156 tests / seven suites passed (temporary test-only entitlement override).
- `kernel-ownership2`: 93 tests / three suites passed with normal signing, including a separate
  OS process contending on the exact temporary record-lock file and the native paper account.
- `baseline-red`: three tests / two issues reproduced the stale-close repair failure.

Keychain implementation uses macOS's existing file-based Keychain/system application ACL;
iOS retains non-synchronized Data Protection storage. No new Mac entitlement or provisioning
is required. Reads denied by Keychain fail closed, and legacy preferences are deleted only
after verified migration. Actual owner Keychain interaction remains untested.
Sources: [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains),
[Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/).

Compatibility limits: old binaries do not participate in the new advisory record lease,
and do not understand the new gross-fill/separate-paper-cost field. Do not run two versions
against owner records or claim an old binary will account for new paper closes correctly.
Historical records have not been rewritten. The normal quit/reopen handover needs a separate
authorized installation receipt. The current installed binary remains unchanged.
No new commits, pushes, installations or historical-record edits.

## Final integration receipt

All 22 ledger items are implemented locally. The prior D4 portfolio-widget fix remains
preserved and deliberately unwired. No model weights, trade-activity thresholds, risk
limits, historical records, strategy research or broker capabilities were changed.

Final native/compile gates run serially. Evidence root remains
`/private/tmp/stocksage-full-review-20260912-6Oi5VM/`.

| Gate | Artifact stem | Result |
|---|---|---|
| Full macOS, final Swift diff | `full-mac-final2` | **2,356 tests / 225 suites passed**, 91.066 s test execution, exit 0. |
| Full iPhone 17 Pro (gate), iOS 26.5 | `full-ios-final` | **2,281 tests / 221 suites passed**, 71.264 s test execution, exit 0. |
| Canonical compile/typecheck | `compile-gate-final` | **macos=OK, ios=OK, tests=OK**, exit 0; 84 s / 75 s / 140 s respectively. Separate from executed tests. |
| Offline Python research tool | `python-research.log` | 18 discovered: **17 passed, one optional LightGBM test skipped**, 0.314 s, exit 0. Includes explicit environment-only credential regression. |

Native gates exclude only the README's opt-in `CalibrationPersistRunTests`,
`LiveUniverseVerificationTests` and `StrategyBaselineMeasurementTests`. No functional
test was skipped to hide a failure. The first broad Mac run (`full-mac2`) had two
outdated cached-source string expectations; corrected to retain observation age.
`full-mac-final` then passed 2,354 tests. The additional widget invalid-clock regression
failed with two issues (`widget-invalid-red`) before the final guarded formatter;
the final Mac count includes both new timestamp tests. Counts above are not cumulative.

### Visual evidence and explicitly unverified work

- Synthetic native controls, navigation, focus, accessibility, wrapping and motion checks
  execute in the Mac suite. The compact 360-point research controls were inspected and
  readable. This is fixture evidence, not an installed-app inspection.
- The 1200×800 offscreen research workspace capture contains mixed appearance: white
  GroupBox backing and unreadable labels despite some correctly dark native controls.
  Independent source review found the production root declares dark mode and did not
  verify a production color override. Two isolated capture experiments (explicit SwiftUI
  dark environment/probe, then scoped AppKit drawing appearance) each passed 46 tests but
  did not resolve the screenshot. Those ineffective experimental changes were removed;
  no speculative production color patch was kept. **Live workspace pixels remain unverified.**
- Retrying the supported connection to `/Applications/StockSageX.app` still returned
  `Sky Computer Use native pipe closed before response`. No forced restart, global
  appearance setting or replacement of the owner's running app was used to work around it.
- Actual owner Keychain migration, provider entitlements/live freshness, model quality or
  throughput, widget-gallery behavior, device installation and real fills were not tested.
- Tested toolchain: Xcode 26.6 (17F113) on macOS 27.0; iPhone gate targets iOS 26.5.
  This does not certify an iOS 27 runtime or a physical iPhone.

### Preserved policy and compatibility limits

- Deadlines are per HTTP probe/completion, not one promised end-to-end assessment latency.
  A transport that ignores cancellation holds its actual concurrency slot until it returns;
  its late output cannot publish into a replacement owner.
- Provider previous-close provenance records the quote carrying that field, not an invented
  exchange closing-event timestamp. Unsupported/missing session evidence stays unknown.
  This batch does not certify live corporate-action adjustments or quiet-symbol baselines.
- D5 discloses stale/partial regime evidence without inventing a new allocation policy:
  existing conservative sizing behavior and the 60% breadth coverage floor are preserved.
- Legacy exit supplementation is bounded and rotates across missing held symbols; it is not
  a claim that every symbol receives a new bar on every scan. Missing observations are not fills.
- Kernel record leases are advisory: old versions that ignore them can still conflict.
  Multi-key backup restoration remains non-crash-atomic. Older binaries do not understand
  newly modeled paper-close costs; do not use them as an accounting-compatible rollback for
  records newly written by this version. Existing historical records were not rewritten.

Source identity: branch `claude/model-harness-2026-09-10`, HEAD
`ccee3329b92e90b7e1029f37d56e838878fef720`, plus this local uncommitted diff.
Aggregate SHA-256 of sorted per-file hashes for Swift/Python/gate sources under
`StockSage/Sources`, `StockSageTests`, `StockSageWidget`, and `tools`:
`ac2058f33b67d670bfe59d8dde625b5617aee646d3ede77885eed7e93f103ac5`.
The installed executable remains `/Applications/StockSageX.app/Contents/MacOS/StockSageX`,
SHA-256 `003d801f764e80412731877e9a69b6e846f8cfa8bf2d37614d611a191302ea31`.
It was not replaced or relaunched by this review, and it is not claimed to contain these fixes.

Final integrity checks: source aggregate hash unchanged after the native and compile gates;
`git diff --check` passed. HEAD/branch unchanged, 67 local modified/untracked paths including
the preserved D4 work, no staged changes. No gate process left running at handoff. Existing
compiler warnings remain (including already-enabled Swift flags and test-fixture warnings);
this is a passing-gate receipt, not a warning-free-code claim.

## Research-selection follow-up and combined release gate

Owner requested date-relevant/popular stocks instead of the alphabetical 500. Both manual
multi-day modes now rank eligible USD listings by observed traded dollar volume from
Massive's dated market summary before capping at 500. Activity is a disclosed popularity
proxy, not social sentiment or a Buy recommendation. Existing news/Benzinga/Qwen analysis
follows selection; no model/risk/strategy parameter or day-paper behavior was changed.

New York dates, supported holidays and the 04:00 boundary select the current or preceding
trading session. A thin current session may use the previous session only if eligible
coverage is wider. No mixing sessions, arbitrary hot-stock list or alphabetical padding.
Malformed/empty requests retain the earlier scan; cancellation and settings revisions
prevent stale publication. The panel and details retain the actual selection date/coverage.
The existing published calendar supports 2026; later unsupported dates fail closed.

Evidence root: `/private/tmp/stocksage-full-review-20260912-6Oi5VM/`.

| Final combined-tree gate | Result | Artifact stem |
|---|---|---|
| macOS arm64 | **2,365 tests / 226 suites passed**, 86.004 s, exit 0 | `relevance-full-mac` |
| iPhone 17 Pro (gate), iOS 26.5 | **2,290 tests / 222 suites passed**, 70.306 s, exit 0 | `relevance-full-ios` |
| Canonical compile/typecheck | **macos=OK ios=OK tests=OK**, exit 0; 78 s / 71 s / 135 s | `relevance-compile-gate.log` |
| Python offline research | **17 passed / one optional LightGBM skip** of 18, 0.162 s, exit 0 | `relevance-python-tools.log` |

Same three README opt-in exclusions, toolchain and platform limits as the prior receipt.
Focused selection/horizon/chat: 71 tests / three suites passed. The old alphabetical-prefix
implementation failed the initial ranking regression with four issues. Independent read-only
source review found no remaining material finding. Complete boundaries/artifacts are in
`docs/superpowers/plans/2026-09-12-relevant-research-universe.md`.

Final source aggregate SHA-256, unchanged across native and compile gates:
`37e28663854f5e16144f1b9fe5231378635828de8027a47840d2ba2727eaeb11`.
Mac-tested bundle passed strict/deep signature verification; the installed executable hash
remains the prior `003d801f…02ea31`, and PID 18128 was still running untouched.
The synthetic workspace screenshot includes the new activity detail but retains the earlier
mixed-appearance capture limitation. Live provider ranking, owner Keychain migration, model
quality/latency, physical-device behavior and installed-app pixels remain unverified.

All 74 reviewed source/test/documentation paths are included in the authorized publication;
no owner credentials, logs, model binaries or trading-history files are included. Main is
eligible for a non-destructive fast-forward of the identical tested tree. Preserve the
unrelated edits in `/Users/saleh/StockSage-app` and all existing worktrees.
