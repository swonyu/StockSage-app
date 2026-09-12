# StockSage current-app critique and reliability implementation

Date: 2026-09-12. Lead is sole repository writer and test owner.
Baseline: `claude/model-harness-2026-09-10` at `ccee332`, linked worktree
`/Users/saleh/StockSage-wt/opus-harness`. Preserve the four unfinished D4 paths.

## Design and boundaries

Improve the existing app's truthfulness and reliability at the shared source of
each defect. Reuse native controls, canonical currency/session/freshness helpers,
and existing tests. No redesign for novelty, extra dependencies, or duplicated
business logic. Read-only reviewers cover data/research, model/settings, and
paper/persistence; the lead covers UI, regression gates, and integration.

Keep research and simulated execution distinct. Preserve the 60% breadth floor,
cap-suppressed alert refire behavior, normal extended sessions, research-only
multi-day modes, model/risk/strategy parameters, and frozen historical records.
Do not enable broker submission, relay, live diagnostics, or paid services.
Do not push, merge, replace the running app, or write owner preferences/records
as part of testing. D4 remains unwired. A source gate is not an installed-build receipt.

## Execution checklist

- [x] Establish branch, dirty paths, processes, current handoff and baseline.
  Previous full Mac run: 2,326 tests, 226 suites, three issues. Focused replay:
  73 tests in six suites passed; the earlier issues are not assumed production bugs.
- [x] Audit each major subsystem and trace proposed defects through real callers.
  Keep findings, evidence, rejected hypotheses and limits in
  `agent-docs/FULL_APP_REVIEW_2026-09-12.md`.
- [x] Reproduce material findings using synthetic records and injected dependencies.
  First immediate regression: exact widget stale-boundary assertion in
  `StockSageTests/StockSageWidgetSnapshotTests.swift` must fail before the fix.
  Review the widget writer in `MarketsView.swift` and widget rendering together;
  preserve backward decoding and distinguish paper/unknown/cached data.
- [x] Apply root fixes in small batches. Reuse each subsystem's existing tests;
  add cancellation, timestamp, decoding and boundary cases where relevant.
  Do not treat reviewer suggestions as verified until source and a check agree.
- [x] Resolve the full-suite UI/test interference without skipping functional tests
  or weakening production checks. Re-run full macOS tests and then iPhone tests,
  serialized, plus the repository compile gate. Opt-in network/research diagnostics
  remain excluded as documented in README.
- [x] Obtain independent review of the final diff; address actionable findings.
  Update the handoff with exact commands/artifacts, test totals, source identity,
  unchanged installed-app status, and explicit unverified items.

## Verification paths

Evidence: `/private/tmp/stocksage-full-review-20260912-6Oi5VM/`.
Reuse only lead-owned build caches under `/private/tmp/stocksage-d4-codex-KfDey5/`.
Native test command: `xcodebuild test -project StockSage.xcodeproj -scheme StockSage
-configuration Debug -destination 'platform=macOS,arch=arm64'
-parallel-testing-enabled NO` with explicit isolated DerivedData and unique result bundle.
iPhone destination: `3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA`.
Canonical compile-only gate: `tools/gate.sh . all` with isolated TMPDIR.
Do not claim an iOS 27 or installed-app gate from Xcode 26.6/iOS 26.5 results.

Direct native UI inspection currently failed because the CUA native pipe closed.
Continue source and synthetic native-component testing; retry the supported UI
connection before finalizing and report any remaining visual verification limit.

## Completion receipt

22 source-verified findings implemented; prior D4 preserved. Final macOS: 2,356 tests /
225 suites passed. Final iPhone 17 Pro (gate), iOS 26.5: 2,281 tests / 221 suites passed.
Canonical compile/typecheck: macos=OK ios=OK tests=OK, exit 0. Python: 17 passed,
one optional LightGBM test skipped. Full artifacts and non-cumulative receipts are in
the critique and `HANDOFF-CODEX-2026-09-12.md`.

The supported native UI connection still failed before inspection. An offscreen workspace
capture's mixed appearance remains unverified in the installed app; ineffective fixture
experiments were removed. No replacement app, commit, push, live verification, credential
operation on owner storage, or historical-record edit was performed. Source gates do not
certify installation, live provider/model performance, all pixels or future runtime states.

Subsequent owner-authorized follow-up completed activity-ranked multi-day research selection.
The combined tree passes 2,365 Mac tests / 226 suites, 2,290 iPhone tests / 222 suites,
strict Mac/iOS/test-source compilation and 17 Python tests (one optional skip). See the
latest handoff receipt. The owner now authorizes commit, merge to main and push; the earlier
no-publication boundary above describes the review stage, not this newer instruction.
