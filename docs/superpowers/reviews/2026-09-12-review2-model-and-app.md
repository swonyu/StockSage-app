# Second app/model reliability critique — September 12, 2026

## Scope and identity

Lead-owned implementation against `bd8ea9cd38ea3dc664f8d15f12b934dd5a599083` in
`/Users/saleh/StockSage-wt/opus-harness`, branch `claude/model-harness-2026-09-10`.
Three existing Astra reviewers performed bounded read-only reviews; the lead alone wrote
and ran the serial verification. Good-spender remains removed. Other worktrees are untouched.

At review start, the previously published source was installed at `/Applications/StockSageX.app`, executable
SHA256 `c8aee9dbb0d35ce3810f5e2c5eafc0e39e2f04718f1ecbb5d484df06e07d1353`.
Its installation receipt is
`/Users/saleh/Codex-Backups/stocksage-install-bd8ea9c.JiCFex/INSTALL_RECEIPT.md`.
That superseded the earlier HANDOFF entry's pre-install identity. The later R1–R10
installation is recorded under Installation and remaining acceptance below.

## Findings and implemented recommendations

| Finding | Real failure and correction |
|---|---|
| R1 — Research completion | The installed scan reported SPY `schema`, MU `unboundNumber`, and IWM `foreignNumber`, all with `finish=stop`. These were completed but invalid answers, not token exhaustion. Assessment requests now supply the verified LM Studio 9B endpoint a strict schema: required fields, offered evidence IDs, unchanged action choices and already-required qualitative prose. The Swift validator remains unchanged. |
| R2 — Recoverable missing citations | Horizon and paper research did not reuse the existing exact-opinion missing-evidence repair. They now use one shared bounded repair. It preserves action, reason and risk exactly, keeps the same evidence and original total deadline, and rejects changed, numeric, cancelled or obsolete drafts. Existing bounded output-limit recovery also forwards the same schema. Chat and Catalyst narrative requests keep their existing format. |
| R3 — Lost protective stop | A pending sell's request-time quote filter hid a valid post-open stop trigger that preceded that request. Held-position monitoring now sees that observation and retains its protective intent through ordinary order expiry/restart. Actual fills still require eligible post-request observations and unchanged pricing/size checks. |
| R4 — Duplicate-lot risk allocation | Risk parity treated each stored lot as another instrument. Reuse the existing holding aggregation before volatility sizing; splitting one holding into lots cannot increase its target weight. |
| R5 — Analytics book identity | The UI compared unique analyzed holdings with live lot count. It now compares captured symbol/share composition. Equivalent split lots are unchanged; replacement symbols or quantities with the same count correctly require re-analysis. |
| R6 — Multi-window chat data loss | Separate window sessions could overwrite replies and resurrect cleared history. One App-owned session is injected on Mac and iPhone. Task registration/cancellation is UUID-scoped; disappearing unrelated windows and late callbacks cannot cancel or restore another request. No history schema migration or global registry. |
| R7 — Partial insider totals | Unreadable transaction codes/quantities silently disappeared from the net. They now invalidate the summary. The bounded recent filing window includes Form 4/A and withholds unreconciled amended totals. Empty-summary copy describes transactions reviewed, not an invented absence of filings. |
| R8 — Expired earnings confirmation | Missing, future or expired check times could keep showing a confirmed date. Confirmation now observes the existing check TTL while preserving the scheduled date with a recheck caveat. That caveat also reaches narrative evidence and changes cached-explanation identity. |
| R9 — Missing displayed daily close | Valid historical closes disappeared whenever Qwen was not Buy/Strong Buy, because the table read optional scenario levels. Research results now retain a separate dated close, including model-validation failures. Stops/targets remain optional research scenarios, never orders. |
| R10 — Opaque validation errors | Shared failure summaries now explain invalid numbers, citations, changed repairs or incomplete format before the existing safe diagnostic metadata. Unsupported answers remain visibly unaccepted. |

The final paper review removed an over-strict intermediate guard on the *original* quote:
post-inference quote revalidation must still be allowed to obtain a fresh replacement.
Context and intraday evidence validity remain required throughout generation/repair;
quote admission, revalidation and actual-fill checks retain their existing distinct limits.

## Coverage and limits

- Market/research: reviewed provider identity, freshness/quiet-feed distinctions, REST/stream
  paths, daily history, dates, catalysts/news, insider parsing and relevant consumers. Current
  unchanged provider fixes were not reimplemented. This is not a new paid-entitlement audit.
- Model: inspected the actual local inventory and request/validation/recovery callers.
  Loaded model was Qwen3.5-9B MLX 6-bit; the 27B rollback models stayed available and untouched.
- Paper/persistence: reviewed pending orders, protected exits, cancellation/restart and related
  accounting/settlement boundaries. No strategy, risk, fees, fills, historical ledger or broker
  submission settings were changed to manufacture activity.
- UI: inspected the running Research results and their error details. Native Chat inspection
  then repeatedly failed with `Sky Computer Use native pipe closed before response`.
  The installed process remained alive; a bounded process sample did not show a main-thread
  hang. This is not enough to attribute the native-tool failure to the app or to sign off every
  tab/modal. Native component render tests cover changed presentation/ownership paths, but
  do not replace manual whole-app visual acceptance.
  A supported reset later restored Research inspection (187/500 checked, owner scan active).
  Entering Paper again broke the connection; screenshot retrieval failed too. No settings,
  scan or paper controls were changed. Updated native fixture images at 360 points were
  visually inspected: Hold and unaccepted-opinion details both retain the dated close, with
  readable wrapped text and no invented scenario levels. These are synthetic fixtures,
  explicitly not installed-app pixels or actual market observations.
- Broker: no submission enabled or exercised; IBKR relay remains off. No new keys, provisioning,
  network publication, paid resources, model download/training, main merge or push.

## Model evidence, not a quality guarantee

LM Studio documents schema-constrained `/v1/chat/completions` output and its MLX implementation
in [Structured output](https://lmstudio.ai/docs/developer/openai-compat/structured-output).
The local capability was tested rather than inferred from the documentation.

One initial synthetic probe completed with four required fields, 65 tokens, no reasoning tokens,
and 8.13 seconds. A subsequent interleaved four-case comparison used the **same** loaded model,
temperature, 192-token initial allowance, instructions and evidence for each plain/schema pair.
All eight responses completed normally and passed the actual unchanged Swift validator; all
four paired actions matched (Hold). Captured synthetic replies are pinned in
`StockSageAIAssessmentTests.capturedSchemaComparisonPassesTheUnchangedSwiftValidator`.

Cases include mixed trends, earnings gap risk, missing news, and untrusted text requesting
guaranteed returns. They contain no owner accounts, keys or real trading observations.
Plain runs took 2.58–12.31 seconds; constrained runs took 1.86–14.76 seconds. The owner scan was
also active, so these are not isolated throughput benchmarks or evidence of a speedup.
Both variants already passed this small fixture set; it does not measure the production
incomplete-rate reduction, financial accuracy, profit, or comprehensive quality equivalence.
Membership validation does not prove every qualitative inference is factually justified.

**No honest implementation can promise that an offline server, missing market data, cancellation,
or malformed answer will always yield a complete high-quality opinion.** The change prevents
avoidable format errors and attempts bounded recovery; it never relabels partial/unsupported
answers as completed financial opinions. No endless retries, weaker validator or fallback model.

## Verification receipt

Artifacts: `/private/tmp/stocksage-review2-20260912.3sHFBU`.

- `research-red`: real model caller lacked schema/repair before implementation.
- `recovery-safety-red`: protective-stop reproduction failed before its fix; research recovery
  and negative controls passed in that run.
- `review-red3`: 69 tests/5 suites, 13 issues reproducing stale confirmation, partial insider
  totals/amendment handling and split-lot risk. Earlier two attempts failed compilation and
  are explicitly not semantic regression evidence.
- `chat-red`: original two-window test reproduced overwrite/resurrection in three assertions.
- `display-red`: 84 tests/3 suites, four issues reproducing daily-close loss and false/missed
  portfolio-composition changes. Chat ownership passed after its fix.
- `focused-green`: 297 total / 296 passed / one existing opt-in skip / zero failed,
  12 suites, 71.459 test seconds, xcodebuild exit 0 (confirmed from the result bundle).
  This preceded the final removal of the excessive original-quote guard; full gates below
  must validate the final source, not merely reuse this focused result.

Final full-platform receipts (Xcode 26.6 / 17F113, Mac host macOS 27.0):

| Gate | Result from final result bundle | Swift Testing duration |
|---|---|---|
| `macos-release.xcresult`, Mac arm64 | 2,409 passed / 1 existing opt-in skip / 0 failed, 227 suites; xcodebuild exit 0 | 94.969 s |
| `iphone-release.xcresult`, iPhone 17 Pro (gate), iOS 26.5 simulator | 2,328 passed / 0 skipped / 0 failed, 223 suites; xcodebuild exit 0 | 78.608 s |

Final app/source/test/widget aggregate SHA256, unchanged across both gates:
`9f5dac27c3cc6c79879efa3e6da32fbff4ec17b21f7fca4561f90e72cf7032fb`.
The final changes after the earlier passing pair were test-only: render the independently
observed close on Hold/rejected results and assert rejected opinions retain it. Both complete
gates were rerun rather than claiming the earlier result covered the new tests.

Commands used `xcodebuild test -project StockSage.xcodeproj -scheme StockSage
-configuration Debug -parallel-testing-enabled NO`, unique result bundles under the artifact
directory, and the README's three exclusions only: `CalibrationPersistRunTests`,
`LiveUniverseVerificationTests`, `StrategyBaselineMeasurementTests`.
Destinations were `platform=macOS,arch=arm64`, then
`platform=iOS Simulator,id=3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA`.
DerivedData was `/private/tmp/stocksage-d4-codex-KfDey5/mac` then its `ios` sibling.
Unset `STOCKSAGE_PAPER_DIAGNOSTICS`, `STOCKSAGE_PAPER_RESPONSE_REPLAY`,
`STOCKSAGE_PAPER_PROCESS_DEATH` and all three `SIMCTL_CHILD_` counterparts.
The existing process-death subprocess opt-in remained skipped in the native Mac host.
No extra exclusions or opt-in file sentinels. Simulator restored to its initial Shutdown state.
These are executed native gates, not merely `tools/gate.sh` typechecks, Xcode 27 SDK tests,
physical-iPhone verification or a fresh live-provider audit. Existing compiler warnings remain.

Exact final Mac-tested candidate:
`/private/tmp/stocksage-review2-20260912.3sHFBU/Mac-release-StockSageX.app`.
Executable SHA256 `5be7474b21fbe2240f1ad051fbd39eefee8eb58821bb9f168da5ab6c94a335ec`.
Copied from the final Mac gate's product; executable byte comparison and strict/deep signature
verification passed. The earlier `Mac-tested-StockSageX.app` is NOT the final candidate:
the later relink changed the executable, so a separate exact final copy was retained.
Native synthetic images inspected and retained as `research-hold-360.png` and
`research-unaccepted-360.png`. Temporary artifacts can be removed by OS cleanup; this receipt
and regression sources are the durable record in the worktree.

Whitespace verification passed. A bounded credential-pattern scan of added diff lines and new
review/plan documents returned zero matches; this is not a historical-secret audit.

The first full Mac run (`macos.xcresult`) found one older Massive/Benzinga fixture that
expected a current estimated label without supplying its check time. Production supplies
that time. The fixture now passes the synthetic resolution timestamp; no exclusion was added.

## Installation and remaining acceptance

**Later installation update:** owner authorized stopping the old scan and normal Quit/install.
Installed and reopened the exact candidate above, PID58100, executable hash confirmed,
strict/deep signature and recursive checksum comparison passed. Receipt and recoverable
old build: `/Users/saleh/Codex-Backups/stocksage-review2-install-20260912.Aoqdkx/INSTALL_RECEIPT.md`.
Saved paper/Chat JSON and protected preferences/automation remained unchanged. The old scan
was intentionally stopped at410/500; its temporary results do not persist through quit.
Home/Research inspected; fresh scan observed at2/500, two accepted Hold results and no
incomplete at that snapshot. Installer did not press Run; its origin was not established.
Remaining all-tab acceptance and whole-scan quality metrics are still open. No commit/push.

The following paragraph records the earlier pre-install state:

At that earlier point the edits were not installed. The running user-started 500-stock scan was not an installer-owned
job; it was not cancelled to replace the binary. The working previous build and prior reversible
backup remain intact. Finish native visual acceptance and coordinate a normal quit before
substituting the verified candidate. No force quit or restoration over current state.

Read-only comparison during this review: three protected preference keys unchanged; saved paper
account and chat JSON byte-identical to the prior install backup; paper automation choice unchanged.
That is a bounded record-preservation check, not a claim that every cache/preference is identical.
No commit, push or merge was performed during implementation/installation. The owner subsequently
requested publication to main; see the later publication verification in HANDOFF.md.
