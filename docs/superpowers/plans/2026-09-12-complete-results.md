# StockSage complete-results implementation plan

> **For agentic workers:** Use executing-plans for lead-owned changes and read-only task
> review. Existing checkout is isolated; no duplicate writer or nested worktree.

**Goal:** Remove reproduced causes of incomplete results and implement every confirmed,
authorized finding from this review, with explicit coverage and final verification.

**Architecture:** Repair existing shared boundaries and native consumers. Keep model facts,
financial eligibility and persistent record ownership separate; no new framework or model.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Foundation URLSession, Swift Testing, LM Studio REST.

## Global constraints

- Worktree /Users/saleh/StockSage-wt/opus-harness, baseline ca0708f90680bfc0eefe7c09ca032ea767b81e74.
- Good-spender removed. Lead owns writes, GUI, tests and installation; reviewers read only.
- Preserve strategy/risk thresholds, source timestamps, validators, records and rollback models.
- No real orders, broker relay, paid provisioning or merge. Owner subsequently authorized
  commit/push of the reviewed changes to origin/claude/model-harness-2026-09-10 on September 12.
- Artifacts /private/tmp/stocksage-reliability-20260912.ZYOL3y; full gates serial, final tree frozen.

## Task 1 — Resolve compatible model copies correctly

Files: StockSage/Sources/StockSage/StockSageLocalModelServer.swift and
StockSageTests/StockSageModelDownloadTests.swift (all relative to the worktree above).

Interfaces: retain probe/managedInventory/verifiedContext/unloadOnQuit APIs; no caller changes.

- [x] Add synthetic duplicate-inventory regression using the installed fixture twice, one
  unloaded and the other holding a single instance matching qwen3.5-9b. Assert probe.hasModel,
  no download POST, verifiedContext == 71680, and one selected unload POST followed by empty
  inventory. Reverse row order. Negative controls: conflicting quantization, duplicate
  instance identity, malformed instance arrays, other model instance not unloaded.
- [x] Run xcodebuild test with only-testing:StockSageTests/StockSageModelDownloadTests,
  existing Mac DerivedData, unique duplicate-red result/log. Require failures on those assertions.
- [x] Change compatibility from exactly one matching row to nonempty/all compatible rows;
  flatten loaded_instances of matching rows for context and selected-model cleanup; require
  unique responding ID and reject conflicting/malformed data. Keep custom-model ambiguity guard.
- [x] Run the same suite green plus LocalModelServerTests. Inspect diff with a read-only reviewer.

## Task 2 — Prevent avoidable token-limited output

- [x] Observe a bounded synthetic request with the installed local model and report only
  finish/usage/byte counts (no owner facts, prompts or drafts in diagnostics).
- [x] Trace each model caller's reserved output, schema and validation. Record confirmed
  cause before adding a recovery task with its exact API/test boundary to this plan.
- [x] Keep existing truncated-output rejection and captured-evidence ownership in every case.

## Task 3 — Complete subsystem and screen critique

Confirmed source paths to reproduce/fix (reviewers did not execute tests):

- N3: QuoteService.number bridges JSON booleans into prices/bars. Add parser regressions;
  reject CFBoolean before bridging, preserving numeric strings.
- N4: Massive/Yahoo history relabel explicit mismatched ticker identities; snapshot case-folds
  distinct provider symbols. Test wrong-symbol bars and case collisions; validate at parser boundary.
- N5: Earnings/events authorization denial persists across credential changes. Reuse opaque
  credential revision, retain same-key backoff and reject obsolete responses.
- N6: Live stream does not reconcile credential revision. Add revision to lifecycle ownership,
  reset before reconnect and reject obsolete callbacks.
- N7: Ordinary price-alert saves overwrite unreadable storage. Preserve raw storage, refuse
  mutation, expose actionable failure and retain draft input. Test cold and mid-session corruption.
- N8: Idea notification batch captures mute preference before awaiting. Recheck per item without
  replaying muted crossings or forgetting accepted notification accounting.
- N9: Journal target parse failure becomes optional nil. Only blank means omitted; reuse the
  input helper and block typed invalid target before Save.
- N10: An optional US benchmark removes non-US holding days from general portfolio risk
  statistics. Align the benchmark only for beta; preserve holding returns for other metrics.
- N11: Multiple storage lots of one instrument count as separate analytics holdings and
  manufacture perfect self-correlation. Aggregate existing holdings by instrument before analytics.

- [x] Triage all three read-only reviews against current callers and tests; mark false positives
  and policy choices separately, and add one red/fix/green task per confirmed root cause.
- [ ] Inspect native Home, Research (both horizons/details), Paper, Chat, Watchlist, Ideas,
  Markets, Catalysts, Heatmap, Portfolio subpages, Alerts and Settings; expand relevant details
  without modifying records or starting trading. Record unavailable UI paths explicitly.
- [x] Implement actionable confirmed usability failures with existing native controls and tests.

## Task 4 — Verify and install

- [x] Independent source review of final changes; resolve material findings before gates.
- [x] Run full Mac then iPhone tests with only README canonical opt-in exclusions; preserve
  exact Mac-tested bundle before iPhone build. Run compile/Python checks where applicable.
- [ ] Recheck source hash and native changed screens, normal-Quit/install/reopen only after
  all acceptance gates pass; preserve rollback and compare protected historical state.
- [x] Record exact results, coverage limits, installed identity and remaining external constraints.

## Findings/progress ledger

| ID | Finding | Status |
|---|---|---|
| N1 | Compatible duplicate LM inventory rejects available/loaded model and cleanup | Live metadata + red/green regression; implemented |
| N2 | Token-limited output without bounded recovery | Synthetic local baseline stop/86 output tokens; bounded recovery and expanded failure/deadline cases pass final gates |
| N3/N4 | Boolean numeric admission and explicit ticker identity mismatch | Parser regressions red/green; implemented |
| N5/N6 | Obsolete credential denial, cached failure and live connection ownership | Revision-scoped fixes plus launch/locked-storage/view-recreation followups reviewed; final gates passed |
| N7 | Corrupt alert storage overwritten, accepted delivery forgotten on error | Corruption, repeated feedback and recovery regressions red/green; final gates passed |
| N8/N9 | Mid-batch mute ignored; malformed optional journal target accepted | Red/green regression; implemented |
| N10/N11 | Benchmark calendar erases holding losses; duplicate-lot self-correlation | Real Store assembly seam red/green; implemented without changing stored positions |
| UI | Full native screen coverage | Research/Home observed; CUA pipe failed opening Paper |

Final Mac gate: 2400 passed / 1 explicit opt-in skip / 0 failed,227 suites. Final iPhone gate:
2320 passed / 0 skipped / 0 failed,223 suites. Source aggregate stable across both; see
`../reviews/2026-09-12-reliability-review.md` for exact receipts and toolchain.

The installed application is unchanged. Remaining acceptance: native all-tab/changed-modal
inspection and reversible installation. Repeated CUA reset/exact-installed-path retries still
fail with `native pipe closed before response`; no alternate GUI bypass was used. Do not turn
passing tests or source review into a claim that all current app screens have been exercised.

Publication follow-up: the owner authorized completing the recommendations and committing/
pushing. Source publication does not waive visual acceptance for installation. The supported
inspection route still failed after a fresh reset; retain the running app and preserved
candidate. The release rerun and publication boundary are recorded in the review receipt.
