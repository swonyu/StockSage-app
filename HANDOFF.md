# HANDOFF — StockSage-app (written 2026-09-06 05:55 +03, session fe29f7aa, Claude Fable 5.1)

## Pipeline 4 M2 — 2026-09-06 20:00 +03, Codex single-session takeover

Owner stopped the separate pipeline task; its uncommitted M2 changes were
preserved and completed on `wt/coverage`. Massive replaces the active EODHD
stream/quote route; Yahoo remains the fallback. The stream consumes every event
in a batch, preserves authorization across informational statuses, handles send
failures, and cancels stale connection callbacks/retries. Auth alone does not
prove delivery: per-symbol coverage expires 45 seconds after the last accepted
trade. Status publication changes only on transitions, with a one-second expiry
timer; Store price writes retain their 500 ms coalescing.

All quote ingress paths now share ordering/validation: full refresh, targeted,
monitor/gap polls, stream flushes and scan publication cannot rewind a dated
price. Undated seeds remain unknown, corrupt future cache values can recover,
off-board ideas update without creating board rows, and row UUIDs survive polls.

Canonical `xcodebuild test`, separate result bundles, parallel testing disabled:

- macOS arm64: **1,649 passed, 0 failed**, bundle
  `/private/tmp/stocksage-m2-broad-macos-20260906-1956.xcresult`.
- iPhone 17 Pro (gate), iOS 26.5: **1,649 passed, 0 failed**, bundle
  `/private/tmp/stocksage-m2-broad-ios-20260906-1957.xcresult`.
- Both explicitly exclude `CalibrationPersistRunTests`,
  `LiveUniverseVerificationTests`, `StrategyBaselineMeasurementTests` (opt-in
  network/measurement jobs). Zero skips among selected tests; excluded suites
  are not claimed tested. Counts independently read with `xcresulttool`.
- One earlier expanded-test attempt failed compilation on a fixture typo and
  executed no tests; corrected before the focused and broad successful runs.

Not yet verified: live endpoint smoke, per-observation provenance UI, NBBO/tape,
same-millisecond sequence ordering, remaining M3–M6, pipeline 5, final integration.
Continue via `agent-docs/PIPELINE_TAKEOVER_2026-09-06.md`. No push or real order.

Written early under the good-spender `⚠ APPROACHING LIMIT` directive (projection only — this
session is the sole spend in the 7-day window; the EWMA is a read-burst artefact).

## Environment blocker — RESOLVED 09:44 +03 (licence accepted; `xcodebuild`, `/usr/bin/git`, Homebrew work again)
Until 09:44 +03 Xcode 26.6 (17F113) had an unaccepted licence, so `/usr/bin/git`, `xcodebuild`, `xcrun`
and `brew` all refused with "You have not agreed to the Xcode license agreements". Everything below
about "tests NOT run" refers to commits made before that. The iOS 26.5 simulator platform (~8 GB)
was still downloading at 09:49 +03 (owner-approved) — the iOS `xcodebuild test` leg is pending it.

Workarounds used while it was blocked (kept — they are fast gates in their own right):
- git: call `/Applications/Xcode.app/Contents/Developer/usr/bin/git` directly.
- compile gate: `swiftc -typecheck` on `StockSage/Sources/**` for BOTH platforms — script at the
  session scratchpad `tc_stocksage.sh macos|ios` (flags mirror the pbxproj: Swift 6, MainActor
  default isolation, MemberImportVisibility, 26.5 targets). Baseline at 02ab1a0: clean on both,
  ~40 s each. Superseded the same day by `tools/gate.sh` (emit-module, both platforms + test-target
  type-check) and **`tools/runtests.sh`, which EXECUTES the whole Swift Testing suite without xcodebuild**
  (swiftc-built testable dylib + Testing.framework runner, throwaway HOME). `xcodebuild … test` itself
  still needs the licence; commits before 09:30 +03 say "tests NOT run" because the runner did not exist yet.

## Repo state at handoff
- `main` = 02ab1a0, **16 commits ahead of origin/main, unpushed** (all iPhone UI work, Jul 28–29).
- Worktree `~/StockSage-uiwork` on `ios-colour-overhaul` at the same commit, clean.
- Work branch for this session: `review-followups-2026-09-06` (off 02ab1a0).
- Backlog source of truth: `agent-docs/REVIEW_2026-07-28_claude.md` (Part 6 staged plan; Part 3
  UI list). `agent-docs/IOS_REVIEW_2026-07-27.md` is fully FIXED — not a queue.

## Done this session (branch `review-followups-2026-09-06`, 3 commits, tree clean, NOT merged, NOT pushed)
- d21cec5 — review #2 "Open heat"→"Planned heat X% of Y% cap" (honesty-critical), #8 iPhone sheet
  detents + grabber (detail sheet .medium/.large, Settings + Browse .large), #10 Reduce-Motion gates on
  the LIVE pulse and refresh spinner, #17c dead `fontMicro` removed.
- 0aac115 — review #7 `.touchHitArea()` on 13 icon/text-only controls (hit shape only, no layout
  change); #9 21 hardcoded font literals → @ScaledMetric tokens in MarketsTodayActionsCard,
  ExecutionQualityPanel, MarketSessionClockView (byte-identical at default Dynamic Type).
- ba82689 — Q3 `defer { isRefreshing = false }` for the whole refresh cycle; Q6 `addSymbol` passes
  `marketTime`; Q7 `quoteAsOf` max-merge; C2 rebalance sort symbol tiebreak.
Every commit: swiftc -typecheck clean on BOTH platforms; tests NOT run (licence). Skipped on purpose:
the #7 stepper relocation to the bottom bar (structural), Q8 (must follow Q4), and every owner-decision item.

## Batch 2 — 2026-09-06 08:30 +03 (workflow wf_02b04e3a-62a: 16 items, 7 isolated worktrees, 29 agents, 76 min)
All 16 items landed and were cherry-picked onto this branch in dependency order (cache → store → stream →
eodhd → fixture → ui2 → ui), `tools/gate.sh all` green after EVERY group (emit-module macOS + iOS +
test-target type-check). Tests still NOT executed (licence). Each group had an adversarial two-lens review;
every blocker/major was fixed in a `fixup(...)` commit except one the fix pass correctly rejected (the
reviewer flagged Q8 landing before Q4 inside the ui worktree — the merge order lands Q4 first).

| Item | Commit(s) | Note |
|---|---|---|
| Q4 marketTime in quote cache Entry | d131554 | review: clean |
| Q1 heal sweep scoped + capped + backoff | 2be3bd2, a73444f | keeps existing `healBatchCap`/`marketIsTrading` gate (superset); pure `healCandidates` pinned by 6 tests |
| Q9 mirror sweep prices onto ideas | 988da1f, 3bf5994 | fixup: `mergeLiveQuote` no longer fabricates `asOf: Date()` — nil stays unknown |
| P3 O(1) `symbolIndex` | 91d32c3 | also rebuilt in addSymbol/removeSymbol (review omitted them) |
| Q5 stream auth classifier + watchdog | 084b16f, 98690dc | fixup: MarketsView now OBSERVES the stream so the LIVE dot redraws |
| Q10 EODHD parser parity | 22ab017, 1f49ccb | fixup: `parseRealTime([String: Any])` overload so the isFinite guard is testable |
| P2 fixture real spark + clique alloc | 299f009, 45f50bc, 9c79c8f, 80a109c | fixup: per-idea varied spark (a shared spark made a degenerate all-1.0 clique) |
| UI#5 fontCaveat / section header 15 | d25ad97 | 3 calibration labels re-pointed (review said 2) |
| UI#13 iOS watchlist remove + reason | 864129a | |
| UI#15 ideasHeader two tiers | b613ec0 | analysis-timestamp line left untouched (one ternary, always visible) |
| UI#16 minWidth fields + wrap | 4140e3a, 37ffd0d | fixup: 4 other widened-field rows also wrapped |
| UI#6 dangerSoft badges + text sweep | 02a95c3 | static `actionColorForTest` seams + guard test |
| UI#3 ViewThatFits metric rows | c591a18 | 5 rows split (idea card exact per review; 4 others minimal) |
| UI#4 `.explain()` shim | 93c6ede | ~13 honesty-bearing `.help` sites converted; sheet stop line not found by text |
| Q8 banner fail-closed | 774522d | shared `MarketsView.freshnessStale(asOf:now:)` |

Minor review findings left OPEN on purpose (small, do after tests can run): Q5 ping has no pong deadline and
`armWatchdog()` re-allocates per frame; Q1 evaluates `marketIsTrading` for every row before the scope filter;
Q1 backoff `before` lookup is a linear scan (could use `symbolIndex`); the same O(n) `currentPrice` scan
still exists in MarketsRiskAllocationSection (unwired file) and `fxRateAge`; `capTruncates` passes the cap
as a literal 40.

Also this session: `tools/gate.sh` (95b54e2) committed as the licence-blocked compile gate; Ollama 0.33.3 +
`qwen3.8` (27B) installed on this Mac for the new Catalysts tab's optional local explanation backend
(see the Catalysts section once it lands).

## wt/ui — 2026-09-06 09:20 +03 (worktree /Users/saleh/StockSage-wt/ui, branch wt/ui, base e619739) — restored 09:58, dropped by mistake at 09:50
Two commits, `tools/gate.sh all` green after each (macos=OK ios=OK tests=OK; tests type-checked, NOT
executed — licence). good-spender was turned ON for good mid-run (user directive, saved to memory).

| Commit | What |
|---|---|
| 648c425 (wt/ui 4cfa3f9) | fixup(UI#6): the 9 realized-stats + risk-analytics ideaMetric sites → dangerSoft via a new static seam `MarketsView.signedMetricColor(positive:positiveColor:)`, pinned by `SignedMetricColorTests` (BacktestVerdictColorTests.swift) |
| dd578ae (wt/ui 1d2637c) | fixup(UI#6): the remaining 17 small-text raw-danger sites (+2 mixed-helper consumers: `hc` heat text, healthColor verdict text) across MarketsView + MarketsRiskAllocationSection; 25 icon/fill/stroke/background sites keep raw danger. Sonnet diff review: APPROVE, 1 minor (watchlist arrow icon inherits dangerSoft with its text) |

Owner call, NOT changed: white text on a raw-danger FILL — STOP TRADING banner (~3316), "Confirm close"
button (~3631), "DO NOT TRADE" chips (~5877 and ~6998 → BestOpportunityActionCard:9881). Same 3.41:1
class UI#6 fixed on the sell badge, but these are stop/destructive surfaces where the red fill is the
convention — decide badge treatment (pastel fill + dark ink) vs keep.
RESOLVED 2026-09-06 09:35 +03 — owner approved; landed as 0897fea (badgeInk + gateChipColor seams, test-pinned, gate green).

Landed on review-followups-2026-09-06 as 648c425 + dd578ae (cherry-picked clean, gate re-run there —
see merge_gate.log). Licence accepted 2026-09-06 09:44 +03; canonical gate run at 09:47 +03: macOS build OK, macOS
test OK — 1,426 tests in 166 suites passed (Swift Testing, 14.2 s; first EXECUTED run since Jul 29).
iOS leg BLOCKED at first: Xcode 26.6 needs the iOS 26.5 simulator platform (the 27.0 beta runtime is
not an eligible destination); owner approved `xcodebuild -downloadPlatform iOS` (~8 GB) at 09:49 +03.
Next: iOS leg result (see merge_gate.log), then push. Spend (good-spender estimate): run closed at $28.27 vs $3.00 est (9.42x OVER — ~30 Fable-tier
classifier agents ran inside an ultracode workflow before it was stopped on the good-spender directive).

## Catalysts tab — NEW (owner request 2026-09-06, workflows wf_3c5d578a-629 + wf_41e9e30c-825; 10 commits cba3f92..d382cc0)
"A new tab that shows, for the same ideas as the Ideas tab, the key catalyst to watch and explains why" —
BOTH per-idea cards AND a date-ordered calendar; the why is engine rationale always, plus an OPTIONAL
model-written paragraph on tap (owner chose "both" / "both").

| Piece | File | Notes |
|---|---|---|
| Engine | `StockSage/Sources/StockSage/StockSageCatalystWatch.swift` | pure; precedence earnings(imminent/soon) → volume move → earnings(clear) → range extreme → risk-off regime (long ideas only) → reliable seasonality → none; every string lives here; UTC-fixed dates; past earnings (>24h) never shown |
| Narrator | `StockSageCatalystNarrator.swift` | routes over Apple FoundationModels (on-device) and the local server; facts list → ≤80 words, ticker-only, no new numbers; foreign-number guard withholds output; every paragraph labelled with its SOURCE + model |
| Local server client | `StockSageLocalModelServer.swift` | Ollama native `/api/chat` (think:false, num_ctx 4096) or OpenAI-compatible `/v1/chat/completions`; probe; backends auto / on-device only / local server only / off; loopback default; non-loopback WARNS FIRST (banner + per-card) |
| View | `StockSage/Sources/Views/CatalystsSection.swift` | header (mode picker, regime line, always-visible caveat, sample-data label, "Explanation model" settings), lazy cards, calendar buckets Today/Tomorrow/This week/Later/No date on file; earnings fetched for ≤30 shown ideas, ≤4 parallel; 8-K filings on tap (US) |
| Wiring | `MarketsView.swift` (d49a903) | `MarketSection.catalysts` between Ideas and All, icon calendar.badge.clock, `CatalystsSection(ideas: displayedIdeas, store: store) { selectedIdea = $0 }` — same projected board, same order |
| Tests | `StockSageCatalystWatchTests` (12), `…NarratorTests` (13), `…LocalModelServerTests` (9), `CatalystsSectionTests` (3), `…PropertyTests` (11, 52,500-combination oracle sweep) | all EXECUTED green via `tools/runtests.sh` |

Reviews: tab review found 2 blockers (past earnings shown as imminent; calendar dropped the RVOL "unvalidated"
caveat) + 2 majors (UTC vs local day; eager cards) — fixed f098044. Backend review found 2 blockers (LAN warning not
visible at the Explain action; label named the CURRENT model setting, not the generating one) + 1 major (auto
fallback untested) — fixed 39ec0d0/3410c82.

Local model on this Mac (owner "okay"): Ollama 0.33.3 standalone under `~/.local/opt/ollama`, LaunchAgent
`com.ollama.serve` on 127.0.0.1:11434 (keep-alive 24h), model `qwen3.8` (27B Q4_K_M, MTP speculative decoding on).
Measured: quiet Mac 15–53 tok/s ≈ 3–10 s per paragraph; with Swift compilers running 7–11 tok/s. MLX 4-bit + MTP
drafter via mlx-vlm was ~1.3× faster steady-state (3.7–6.3 s) — NOT made the default; venv at `~/.local/venvs/mlx`,
34 GB of A/B artefacts (Ollama tag `qwen3.8:27b-mlx`, HF cache) left on disk for the owner to delete or keep.

## EXECUTED test results
**Canonical `xcodebuild -scheme StockSage -destination 'platform=macOS' … test` on the tab branch (rebased onto
5c547f1), 2026-09-06 09:53 +03: `✔ Test run with 1476 tests in 171 suites passed after 26.920 seconds` — ** TEST
SUCCEEDED ** (n=1,476 executed, 0 failed).** iOS leg: pending the 26.5 simulator platform download (other session).

tools/runtests.sh (macOS arm64, 09:40 +03), before the licence was accepted:
`✔ Test run with 1474 tests in 170 suites passed after 29.967 seconds` on d382cc0's tree (n=1,474 executed, 0 failed).
Earlier the same runner passed 1,446/1,446 on d49a903 (batch 2 + tab wiring) and 33/33 on the catalyst suites.
Not executed: SwiftUI rendering (no simulator/app run), the Apple on-device model path (needs an Apple
Intelligence device), live Yahoo/SEC/Ollama network paths beyond the read-only Ollama probes.

Canonical gate on BOTH platforms at HEAD 5b3f2a4 (2026-09-06 10:01 +03, wt/ui session): macOS test
1,476/1,476 in 171 suites; iOS test 1,476/1,476 in 171 suites on an iPhone 17 Pro simulator (iOS 26.5
23F77, platform downloaded 09:49–09:54 +03, 8.52 GB). HEAD unchanged during the run. Not pushed.
Uncommitted `StockSage.xcodeproj/project.pbxproj` reorder (104+/91−, no semantic change) left for its owner.

## Next actions
1. Owner: `sudo xcodebuild -license accept`, then the canonical `xcodebuild … test` on macOS AND the iOS 27
   simulator (the runner covers macOS only; iOS is emit-module-checked). Open the app: Ideas → Catalysts tab,
   both modes; tap Explain with Apple Intelligence on; set Backend = Local server with Ollama running.
2. Merge `review-followups-2026-09-06` → `main` when green; push `main` (was 16 ahead before this branch).
3. Backlog: the minor review findings listed under Batch 2 above; remaining OPEN review items are the
   owner-decision ones (Q11, C1 wording, M1 retention, UI#11 iPad, UI#1 crown, F1 dead engines) + P2-memo
   (allocator memo, `StockSageStore` + `MarketsView` capitalAllocationCard), UI#3's remaining rows if any.
4. Decide on the MLX server as default (needs a launch agent; ~1–2 s faster per tap) and on deleting the 34 GB
   of A/B model files.
5. The background sweep session's work (`wt/ui`) is ALREADY on this branch (648c425, dd578ae, 0897fea —
   see the wt/ui section above); its worktree `~/StockSage-wt/ui` can be removed once it has run the
   iOS test leg and pushed.

## W4 — local-model retrieval-first internet access (2026-09-06, worktree cov-w4, branch wt/cov-w4)
Citable sources for the on-tap Catalyst "Explain" paragraph: EODHD news (`StockSageNewsService`,
new), the last 8-K (`StockSageDisclosureService`, existing), and insider Form 4 activity
(`StockSageInsider`, existing — now also gated by `ToolPolicy.isExternalAllowed`, closing the one
feed in this subsystem that hit the network unconditionally). `StockSageCatalystNarrator.facts(for:sources:)`
appends one numbered `[n] YYYY-MM-DD <source>: <title> — <snippet> (<link>)` line per source; the
model may cite `[n]` and both the existing number fence AND the new `citationsValid(_:sourceCount:)`
gate must pass before a response is shown as `.text` — otherwise `.withheld`. US/NASDAQ-only via
`StockSageEODHD.covers`, matching the sibling SAHMK/Tadawul task being cancelled (12:57 +03 scope
change) — nothing here touches Tadawul or `.SR` symbols.

**EODHD news cost**: `/api/news` is billed 5 API calls per request PLUS 5 more per ticker named in
the request — one call for one symbol therefore spends 10 calls against the 100k/day EODHD
allowance, separate from and in addition to the existing quote path's per-symbol cost.

**Privacy**: tapping "Explain" now also sends the symbol to eodhd.com (news) and sec.gov (8-K
filings, insider Form 4 trades) directly from the device, in addition to whichever narrator
backend (on-device Apple Intelligence or the local server) answers the paragraph. The Catalysts
tab header states this unconditionally, alongside the existing non-loopback warning.

Gate: `GATE repo=cov-w4 macos=OK ios=OK tests=OK`. Tests: filtered StockSageInsiderTests 10/10,
StockSageNewsService 12/12, StockSageCatalystNarratorTests 23/23; unfiltered suite 1,551/1,551
tests in 177 suites, 0 failed (tools/runtests.sh, EXECUTED, 65.3s). No network hit in any test —
all fixtures are hand-derived pure-parse inputs; `ToolPolicy.override` gating test uses the
pre-existing `ToolPolicyTestLock` seam.
