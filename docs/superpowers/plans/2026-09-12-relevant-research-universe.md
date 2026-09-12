# Date-Relevant Research Universe Implementation Plan

> For agentic workers: use executing-plans for this bounded continuation. Lead remains
> sole writer/test owner; existing reviewers are read-only. No installation.
> The owner subsequently authorized commit, merge to main and push after verification.

**Goal:** Replace alphabetical 500-name selection with a dated, activity-ranked universe.
**Architecture:** One date-bound bulk selection helper feeds the existing manual scan;
the scan keeps its selection receipt alongside results. Reuse reference pagination,
HTTP bounds, currency/symbol validation, and the market calendar.
**Tech stack:** Swift 6, Foundation/URLSession, SwiftUI, Swift Testing; no new dependency.

## Global constraints

Preserve all 22 prior fixes and D4; same isolated worktree and branch. Research-only,
up to 500, one manual worker, no automatic repeating multi-day scan, no paper/model/risk
policy changes. No live calls, owner-record edits, secret output, paid resources,
or replacement of the installed app. Test heavy gates serially.

## Task 1 — Observable, dated selection

Files: create `StockSage/Sources/StockSage/StockSageResearchUniverse.swift` and
`StockSageTests/StockSageResearchUniverseTests.swift`.

Interfaces: `StockSageResearchUniverse.Selection` contains `[StockSageHorizonResearch.Listing]`
and optional `Receipt` (date, source/coverage and selected dollar activity). Its convenience
initializer accepts fixture listings without claiming a real source receipt.
`select(directory:data:session:at:) throws -> Selection` is pure.
`fetch(key:allowed:at:transport:) async throws -> Selection` reuses directory pagination
and enforces cancellation/settings ownership around bounded bulk requests.

- [x] RED: ranking fixture with alphabetical AAA at $100 activity and ZZZ at $900 must
  yield `["ZZZ", "AAA"]`; 501 reversed-activity rows must exclude the least active, not ZZZ.
  Run against the old directory-order path and record its failure before changing it.
- [x] Add date fixtures: Saturday Sept 12 → Friday Sept 11; Labor Day Sept 7 → Sept 4;
  before 04:00 ET → previous trading day; unsupported year → no selection. Inject the clock.
- [x] Add parser cases: count/adjustment/status mismatch, duplicates, wrong date/units,
  future timestamp, zero/non-finite/missing activity, unknown USD, OTC and share-class names.
- [x] Implement the native calendar walk (bounded eight prior dates), fixed URL request,
  pure descending rank and bounded transport. Retain only one session's activity per selection.
- [x] GREEN: injected current-day shortage uses a wider prior session with its real date;
  current coverage ≥500 makes no fallback request; failed fallback does not discard usable
  current observations; cancelled/revoked requests never publish or make later requests.

## Task 2 — Integrate scan receipt and truthful controls

Files: `StockSageHorizonResearch.swift`, `StockSageResearchModesPanel.swift`, existing
`StockSageHorizonResearchTests.swift` and `StockSageChatTests.swift`.

- [x] Make the preflight closure return `Selection`; keep the 500 cap after ranking and
  store its receipt only after acceptance. Production preflight calls the new bulk selector.
  Mechanical fixture adaptation: `universe: { names }` → `universe: { .init(names) }`.
- [x] Pin preservation of prior selection/date after failed/cancelled preflight, and both
  horizons consuming ranked order without changing one-shot/cancellation behavior.
- [x] Replace both alphabetical UI descriptions with activity/source/date language. Show
  the receipt and per-stock selection activity; do not label a popularity rank a Buy signal.
- [x] Run focused universe/horizon/chat regressions; inspect synthetic narrow controls.
  Obtain a read-only review, then run complete Mac/iPhone gates on the final Swift diff.
- [x] Update the new feature receipt and parent handoff. Distinguish earlier review gates,
  new gates and unchanged installed-app state; no claims of live ranking verification.

Native gate commands follow README with isolated lead-owned DerivedData and new evidence
bundles under `/private/tmp/stocksage-full-review-20260912-6Oi5VM/`; only the three README
opt-in research/network suites are excluded. Canonical final compile: `tools/gate.sh . all`.

## Implementation evidence

- `relevance-red`: the mechanically extracted alphabetical-prefix selector failed the
  activity regression with four issues (including selecting S00000 instead of S00500).
  It has been replaced, not retained as a production fallback.
- `relevance-focused3`: 71 tests / three suites passed, exit 0, 8.464 s. Initial focused
  attempts caught a Swift Testing closure-macro Sendable error and an old message assertion;
  both were corrected before this pass. Regression coverage includes absent activity fields,
  invalid/future timestamps, adjustment/count errors, duplicate invalid copies, empty results,
  fallback cancellation and both horizons consuming the ranked order.
- Read-only independent review of source/integration found no remaining material issue.
- `relevance-full-mac`: 2,365 tests / 226 suites passed, exit 0, 86.004 s.
- `relevance-full-ios`: 2,290 tests / 222 suites passed, exit 0, 70.306 s.
- `relevance-compile-gate.log`: `GATE repo=. macos=OK ios=OK tests=OK`, exit 0;
  Mac emit 78 s, iOS emit 71 s, test-source typecheck 135 s. These are compile checks,
  separate from the executed native suites above.
- `relevance-python-tools.log`: 18 discovered, 17 passed / one optional LightGBM skip,
  exit 0, 0.162 s (`python3 -m unittest test_intraday_research` from `tools/`). The first
  root-directory invocation could not import the sibling module; no test ran in that attempt.
- Receipt clocks are named `requestedAt`, not response-received or market-observation time.
  No live grouped-market summary, owner Keychain or model was queried in this work.
- Synthetic research workspace capture includes the selection date/activity in its inspector.
  It still exhibits the earlier documented mixed-appearance offscreen rendering problem;
  this does not provide a live installed-app visual signoff.

All implementation/verification steps are complete. Final source aggregate hash:
`37e28663854f5e16144f1b9fe5231378635828de8027a47840d2ba2727eaeb11`.
Owner-authorized publication: commit the reviewed 74 source/test/documentation paths,
fast-forward the clean existing main worktree to the identical tested tree, then push main
and the working branch to `swonyu/StockSage-app`. No installation or unrelated-worktree edit.
