# StockSage reliability critique and implementation receipt

## Scope and identity

Owner requested a whole-app critique followed by implementation, specifically avoiding
token-limit failures and incomplete results. Work is local to
`/Users/saleh/StockSage-wt/opus-harness`, branch `claude/model-harness-2026-09-10`,
base `ca0708f90680bfc0eefe7c09ca032ea767b81e74`. Lead owns all writes and gates;
supporting reviewers are read-only. Good-spender remains removed.

The implementation plan is `../plans/2026-09-12-complete-results.md`.
Raw test receipts are under `/private/tmp/stocksage-reliability-20260912.ZYOL3y`.
The results below are executed test evidence. The later publication rerun is recorded
separately; neither source review nor source publication is an installation receipt.

## Confirmed defects and corrections

| ID | Defect | Correction and regression boundary |
|---|---|---|
| N1 | Two compatible native inventory entries made the selected model appear unusable and prevented selected-instance cleanup | Require all matching entries to satisfy the existing strict profile, combine unique loaded instance IDs, reject conflicting or ambiguous metadata; test both row orders and negative controls |
| N2 | A confirmed output-token limit had no controlled recovery | One same-evidence retry with doubled output reservation, only if it fits the original context/deadline; never splice a partial financial answer or accept a truncated verdict; test repeated cutoff, empty cutoff, settings change, timeout, HTTP error, wrong model and insufficient loaded context |
| N3 | Foundation bridged JSON booleans to numeric quotes/history | Reject CFBoolean at the shared numeric boundary; keep legitimate numeric strings supported |
| N4 | Explicit wrong-symbol history could be relabeled; snapshot case folding could conflate provider symbols | Check explicit response identities against requests; preserve case-sensitive provider identity at snapshot admission |
| N5 | A rejected old API key could suppress a replacement key, including cached catalyst failures | Scope denials and pending response ownership to an opaque credential revision; make failed observations due for a new revision; recheck US earnings without deleting previously observed facts |
| N6 | Existing wildcard connection survived credential replacement | Reconcile on settings/task startup and check connection revision across authentication, publication, reference refresh, watchdog and retry |
| N7 | Normal price-alert mutations could overwrite unreadable storage; accepted notifications could lose their in-memory latch on write failure | Read committed storage before edits, preserve corrupt bytes, expose failure, retain accepted delivery, reconcile recovered storage and suppress repeated identical background warnings |
| N8 | Muting idea alerts during an asynchronous batch did not stop subsequent sends | Recheck current preference per item, retain accepted-delivery accounting and advance muted crossing baselines |
| N9 | A malformed typed target became an omitted optional target | Only blank input means omitted; validate nonempty target text with the existing positive/profit-side rules |
| N10 | Optional US benchmark alignment erased non-US holding days from general risk statistics | Use holding-day alignment for holding risk; intersect the benchmark calendar only for beta |
| N11 | Multiple lots of one instrument created duplicate analytics holdings and self-correlation | Aggregate using the existing holding-by-symbol helper before fetching/assembling analytics; preserve stored lots |

No strategy thresholds, risk limits, historical trading records, model weights, quantization,
live/fill freshness cutoffs or broker-submission controls were changed to increase activity.

## Review coverage and limits

Source review covered model lifecycle and callers, provider identity/freshness and credential
paths, catalyst/research evidence, paper/session/accounting invariants, alert persistence and
notification lifecycle, portfolio analytics, and navigation/settings consumers. Bounded
independent reviews found the defects above; they are not proof that every possible defect
in the repository has been discovered.

Native GUI inspection reached Research and Home. Research exposed its one-shot horizon,
empty state and market-data caveat; Home exposed briefing/context navigation. The computer-use
native connection then failed with `native pipe closed before response`, including subsequent
reconnection attempts. Paper, Chat, Watchlist, Ideas, Markets, Catalysts, Heatmap, Portfolio,
Alerts, Settings and expanded detail interactions are **not signed off visually in this task**.
Source inspection and synthetic component tests must not be substituted for those pixels.

The scope does not establish live exchange coverage/latency, every paid entitlement, real
market-hours reconnect behavior, financial prediction quality, physical-iPhone behavior,
VoiceOver usability or a profitability target. A connected quiet/weekend feed is not evidence
of a recent trade for every symbol. No real-money order or broker relay was enabled.

## Avoiding incomplete model results

Token-limit errors cannot be eliminated by promise or by accepting the prefix of an answer.
The implemented sequence is: capture evidence/settings, reserve prompt plus output, request
the selected model, inspect finish/identity, optionally retry once within the same deadline,
verify loaded context, then run the existing caller's evidence/schema checks. A final failure
remains an explicit failure, not an invented Buy/Hold result.

A bounded synthetic request to the installed 9B profile completed with `finish=stop`, 86 output
tokens and zero reasoning tokens. That verifies one plumbing sample, not stock-analysis quality
or reliable latency under sustained load. No model replacement or speculative decoding change
was justified by that observation. Large results should continue through the existing bounded
per-symbol research pipeline, not one enormous all-market prompt.

## Remaining recovery boundary

During unreadable alert storage, accepted-delivery latches are held in memory and corrupt
bytes are preserved. When valid storage becomes readable, the latch must be persisted before
normal monitoring resumes. An abrupt process loss *before storage recovery* is not claimed
to provide exactly-once notification delivery; UserDefaults is not a transactional delivery
journal. No automatic restoration or history rewriting was performed to conceal that limit.

## Final verification

Final source/test/widget aggregate SHA-256:
`1b7d22e4ec8ff2976258e6647615a42b4b64a22c15a1a95268290543ee111a12`.
Computed over sorted tracked/untracked, nonignored files in `StockSage/Sources`,
`StockSageTests` and `StockSageWidget`. Branch/HEAD unchanged.

| Verification | Exact result | Artifact |
|---|---|---|
| Final macOS gate | Xcode 26.6 (17F113), macOS 27.0 host; 2,400 passed, 1 explicitly disabled opt-in test, 0 failed; 227 suites; Swift Testing elapsed 79.516 s; process exit 0 | `mac-final.xcresult`, `mac-final.log` |
| iPhone 17 Pro (gate) | iOS 26.5 simulator `3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA`; 2,320 passed, 0 skipped/failed; 223 suites; Swift Testing elapsed 71.034 s; process exit 0 | `iphone-final.xcresult`, `iphone-final.log` |
| Offline Python research tools | 48 discovered; 46 passed, 2 optional LightGBM tests skipped; 0.501 s | `python-offline.log` |
| Shell test-runner exit propagation | Expected success and failure both preserved; self-check exit 0 | Executed `tools/test_runtests_status.sh` |
| Independent final source reviews | Provider/model/alert/analytics follow-up findings resolved on read-only recheck; not execution proof | Lead integration in this working tree |
| Mac-tested bundle | Strict/deep code-signature verification passed; preserved separately before the iPhone build | `Mac-tested-StockSageX.app` |

Both native gates use only the README exclusions: CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. The Mac opt-in skip is
`abruptChildDeathAtBeforeAccountCommitReleasesLeaseAndRecoversOneFill`, which explicitly
requires the standalone testrunner and must not run inside the Xcode app test host. It is not
counted as passed. Optional LightGBM runtimes were not installed for this task.

Earlier failed red runs prove regression sensitivity, not release acceptance. The first
credential/lifecycle builds exposed test integration compile errors (argument label, nested
Testing macro, missing Combine import); those were corrected. `lifecycle-green2` executed
140 tests across eight suites successfully. `alert-recovery-red` later failed four targeted
assertions before the final correction. `mac-full` was deliberately interrupted, exit 75,
when a reviewer follow-up required a source change; only `mac-final` is release evidence.

The retained candidate executable SHA-256 is
`c308fe2bfaacc3b92a8892784433e719b47e352a9510095962683036c98c415d`.
The running `/Applications/StockSageX.app` remains the previous build, executable SHA-256
`ee3de94d6b8b53d818d2cc059ac0f823d7131172623a87dc44655fcec62c2e11`.
It has not been quit, replaced or relaunched. Native whole-app visual acceptance remains
incomplete because the inspection connection failed; do not claim an installed update.
No commit, push or merge occurred during that review pass. The owner subsequently authorized
source publication; installation remains gated by the unfinished visual checks.

## Authorized publication follow-up — September 12

The owner requested completion of the recommendations and authorized commit/push. Publication
is scoped to the reviewed N1–N11 changes and these receipts on
`origin/claude/model-harness-2026-09-10`, remote `https://github.com/swonyu/StockSage-app.git`.
The separate dirty app checkout and all other worktrees are preserved; no main merge,
force-push, historical-record edit, provider/model replacement or broker action is included.

The source aggregate still matches the value above. Native UI inspection was retried using
the exact installed app path and again after resetting the supported inspection connection;
both returned `Sky Computer Use native pipe closed before response`. The running installed
app is therefore retained unchanged. Source publication does not waive the missing native
screen/changed-modal acceptance or claim every external request can always succeed.

Fresh publication verification on that unchanged source (Xcode 26.6/17F113, serial):

| Check | Executed result |
|---|---|
| macOS 27.0 | 2400 passed, 1 existing opt-in skip, 0 failed; 227 suites, 79.685 test seconds; xcodebuild exit 0 |
| iPhone 17 Pro (gate), iOS 26.5 | 2320 passed, 0 skipped/failed; 223 suites, 69.642 test seconds; xcodebuild exit 0 |
| Offline research tools | 48 discovered, 46 passed, 2 optional LightGBM skips; 0.412 seconds |
| Runner exit propagation | Success and expected failure retained their exit codes; self-check exit 0 |
| Outgoing diff / new documents | Bounded credential-pattern scan: zero matches; not a historical-secret audit |
| Whitespace and identity | git diff --check passed; source aggregate unchanged before/after both gates |

Native commands used `xcodebuild test -project StockSage.xcodeproj -scheme StockSage
-configuration Debug -parallel-testing-enabled NO` with the same three README exclusions
listed above. Destinations were `platform=macOS,arch=arm64` then
`platform=iOS Simulator,id=3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA`; DerivedData paths were
`/private/tmp/stocksage-d4-codex-KfDey5/mac` and `/private/tmp/stocksage-d4-codex-KfDey5/ios`.
Paper diagnostics, response replay and process-death opt-ins, including simulator-forwarded
forms, were explicitly unset. Counts are test definitions, not expanded parameter cases.

Fresh artifacts: `/private/tmp/stocksage-publication-20260912.vcm7U3/{macos,iphone}.xcresult`
and matching logs. The newly Mac-tested bundle is retained as `Mac-tested-StockSageX.app`
in that directory; strict/deep code-signature verification passed, executable SHA-256:
`c8aee9dbb0d35ce3810f5e2c5eafc0e39e2f04718f1ecbb5d484df06e07d1353`.
The older tested candidate remains separately preserved. No native gate/test host remained
after the runs; installed app PID 40068 and its previous executable hash were unchanged.

Still open: native all-tab/changed-modal inspection, then the reversible normal-Quit,
backup/install/reopen and protected-record comparison. No installed-update claim is made.
