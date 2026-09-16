# Research outcome lifecycle — verification results

Date: 2026-09-16

Status: implemented and gated. Every saved prediction created from now on completes at its
**first verified target or stop session**, or at its exact seventh/fourteenth Nasdaq session
close. Existing saved runs, their endpoint-only receipts and their stored bytes are unchanged.

Worktree: `/Users/saleh/StockSage-wt/research-pipeline-20260915`.
Base: `aeb9dab` (Use the latest ended daily session without rewriting saved research).
Spec: `docs/superpowers/specs/2026-09-16-research-outcome-lifecycle-design.md`.
Plan: `docs/superpowers/plans/2026-09-16-research-outcome-lifecycle.md`.

## Commits

| Commit | Task |
|---|---|
| `f93e941` | Evaluate saved picks at first target or stop |
| `6057363` | Check active research outcomes on settled sessions |
| `2ef2be3` | Refresh active research outcomes on app foreground |
| `50a031c` | Show target stop and horizon outcomes |
| _(this file's commit)_ | Document verified research outcome lifecycle |

## What changed

- `Run` carries an optional versioned `outcomePolicy`. New snapshots set `dailyBarFirstHit` (2);
  an absent value decodes as the existing endpoint policy and is never inferred. An unknown raw
  value throws while decoding.
- `Evaluation` gains optional `terminalKind` (`targetHit` / `stopHit` / `horizonClose`),
  `terminalAt`, `outcomePrice`, `adjustmentRatio`, `adjustedEntry` / `adjustedStop` /
  `adjustedTarget`, `dailyBars` and `sameBarStopFirst`. `targetCloseAt` still holds the scheduled
  horizon close even when a prediction finishes early, so the original window is preserved.
- The decision is a pure chronological scan of settled adjusted daily bars. A bar reaching both
  levels resolves to `stopHit` with `sameBarStopFirst`; a bar that gaps through a level is observed
  at its daily open; otherwise the captured level is the outcome price.
- Captured entry/stop/target are rebased by the freshly adjusted close on the saved reference date
  divided by the immutable saved reference price. The original prediction is never rewritten.
- `reviewEnd` stops each request at the latest wholly ended New York session, capped at the
  horizon, and the window starts at the saved reference date so the ratio and the monitoring path
  come from one adjusted series.
- `checkActive` stores only `evaluated` or `dataUnavailable` receipts. A verified no-hit result
  before the horizon leaves the prediction active with no stored receipt; the store itself refuses
  to persist one.
- `checkSavedOutcomes` is the single caller for both the Saved Research action and one foreground
  activation, with the external-access, sample-data, credential-revision, cancellation, storage and
  25-per-pass guards preserved. No timer, background task, quote subscription or model call.

## Verification

### Focused

`-only-testing:StockSageTests/StockSageResearchHistoryTests`,
`StockSageTests/StockSageHorizonResearchTests`, `StockSageTests/StockSageIOSPresentationTests`
on `platform=macOS,arch=arm64`, DerivedData `/private/tmp/stocksage-outcome-focused`:

**121 tests in 2 suites passed** (the iPhone presentation suite is `#if os(iOS)` and runs in the
iPhone gate). Zero network access; every observation is an offline fixture or an injected transport.

Required spec cases, each with its own test:

| Case | Test |
|---|---|
| target on an earlier session beats a later stop | `firstTerminalBarWinsAndSameBarUsesStop` |
| stop on an earlier session beats a later target | `stopBeforeTargetAndGapsUseTheSessionOpen` |
| both levels in one bar resolve to stop | `firstTerminalBarWinsAndSameBarUsesStop` |
| gap below stop / above target use the session open | `stopBeforeTargetAndGapsUseTheSessionOpen` |
| no hit completes at exactly session 7 or 14 | `noHitStaysActiveUntilTheExactHorizonSessionClose` |
| no hit before the horizon remains active | `noHitStaysActiveUntilTheExactHorizonSessionClose`, `activeChecksStoreOnlyTerminalOrUnavailableReceipts` |
| missing interior session cannot finalize | `missingInteriorSessionCannotEstablishFirstHitOrder` |
| holidays, early closes and DST preserve session counts | `verifiedSessionCountsSurviveHolidaysEarlyClosesAndDaylightChange` |
| completed receipts cannot be rewritten | `terminalReceiptsValidateByRecomputationAndCannotBeRewritten` |
| legacy runs retain endpoint-only results and exact encoding | `legacyRunsKeepEndpointOnlyReceiptsAndEncoding`, `legacyRunsAndEndpointReceiptsRoundTripByteIdentically` |
| triggers honour cancellation, credential revision, sample data, external access | `sharedOutcomeTriggerOnlyFetchesUnderEveryOwnershipGate`, `oneForegroundActivationCannotOverlapAnInProgressCheck` |
| Mac and iPhone Saved Research render every terminal state at accessibility sizes | `savedResearchRendersEveryTerminalOutcomeAtAccessibilitySizes` |
| corporate-action rebasing and a failed ratio | `splitAdjustsCapturedLevelsAndAnUnverifiedRatioFailsClosed` |
| corrupted terminal fields preserve the owner's bytes | `corruptedTerminalReceiptsPreserveOriginalBytesAndReportAnError` |

### Mac gate

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project StockSage.xcodeproj -scheme StockSage -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -jobs 4 \
  -derivedDataPath /private/tmp/stocksage-outcome-final-mac \
  -resultBundlePath /private/tmp/stocksage-outcome-final-mac.xcresult
```

`** TEST SUCCEEDED **` — result bundle reports **2707 total, 2704 passed, 0 failed,
3 skipped, 0 expected failures**, 237 suites, 107.9 s. The three skips are the pre-existing
documented ones: `abruptChildDeathAtBeforeAccountCommitReleasesLeaseAndRecoversOneFill`,
`syntheticThroughputPayloadExportAndValidation`, `validateSuppliedRecoveryCheckpoint`.
Artifact: `/private/tmp/stocksage-outcome-final-mac.xcresult`.

### iPhone gate

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project StockSage.xcodeproj -scheme StockSage -configuration Debug \
  -destination 'platform=iOS Simulator,id=23E420EF-11AB-4623-ADED-46F528468665' \
  -parallel-testing-enabled NO -jobs 4 \
  -derivedDataPath /private/tmp/stocksage-outcome-final-ios \
  -resultBundlePath /private/tmp/stocksage-outcome-final-ios.xcresult
```

`** TEST SUCCEEDED **` — result bundle reports **2636 total, 2634 passed, 0 failed,
2 skipped, 0 expected failures**, 234 suites, 120.8 s. Resolved device: **iPhone 17 Pro**,
iOS Simulator **27.0** (build 24A5423a), arm64, udid `23E420EF-11AB-4623-ADED-46F528468665`.
Artifact: `/private/tmp/stocksage-outcome-final-ios.xcresult`.

`savedResearchRendersEveryTerminalOutcomeAtAccessibilitySizes` passes with both arguments
(normal and accessibility text sizes), rendering Target hit, Stop hit, Horizon close, Active,
the adjusted scenario levels, the observed outcome price, the verified bar path, the same-bar
stop-first disclosure, the **Check active results** label, and Home's three separate counts.

Three defects were found by these gates and fixed before the final run, all in this change's own
new test and copy — each is recorded here rather than silently corrected:

1. The "always active" render fixture captured its reference and levels *after* the run's
   completion date. `valid(run)` correctly refused to record it. Fixed in the fixture.
2. Home's ready-line copy had been changed to "…is active and ready to check.", which broke the
   existing `homeSummaryOpensSavedPredictionsAndTheRequestedResearchHorizon` assertion. That
   wording was not required by the spec, so the copy was reverted rather than the assertion edited.
3. The aggregate terminal counts were asserted inside the Saved Research sheet, but they render on
   the Home summary card. The assertions were moved to a Home render via `captureWorkspace`.

### Source and compile gates

```
TMPDIR=/private/tmp/stocksage-outcome-gate bash tools/gate.sh \
  /Users/saleh/StockSage-wt/research-pipeline-20260915 all
```

```
[macos] emit-module rc=0 in 69s
[ios]   emit-module rc=0 in 61s
[tests] typecheck   rc=0 in 141s
GATE repo=research-pipeline-20260915 macos=OK ios=OK tests=OK
```

Swift 6, `-default-isolation MainActor`, `-strict-concurrency=complete`, with the project's six
upcoming features enabled. `-emit-module` is used rather than `-typecheck`, so SIL-stage Swift 6
isolation diagnostics run too.

### Signed local Release build

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project StockSage.xcodeproj -scheme StockSage -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$STOCKSAGE_RELEASE_DIR/DerivedData" -jobs 4 \
  CODE_SIGN_IDENTITY='Apple Development' \
  CONFIGURATION_BUILD_DIR="$STOCKSAGE_RELEASE_DIR/Release" build
codesign --verify --deep --strict "$STOCKSAGE_RELEASE_DIR/Release/StockSageX.app"
```

`** BUILD SUCCEEDED **`; `codesign --verify --deep --strict` exited 0 with no output.
Build directory: `/private/tmp/stocksage-outcome-release.EhaCe8/Release/StockSageX.app`.

- `Identifier=SA.StockSage`
- `TeamIdentifier=WY272L3F3N`
- designated requirement: `identifier "SA.StockSage" and anchor apple generic and certificate
  leaf[subject.CN] = "Apple Development: saleh alayed (PTQGDMQ2Z5)" and certificate
  1[field.1.2.840.113635.100.6.2.1]`

**The installed app was NOT replaced and owner data was NOT touched.** The plan's step staged this
bundle over `/Applications/StockSageX.app`; installing is a deployment, which this session was
explicitly instructed not to perform. `/Applications/StockSageX.app` and
`~/Library/Application Support/StockSage/ResearchHistory` were only read, never written, copied or
backed up. Terminal-state inspection was done through the isolated SwiftUI render fixtures in the
iPhone gate above, so no fixture ever entered the owner's saved research. Installing this build
remains an owner-authorised step.

## Limitations

- These outcomes measure a **captured scenario on settled daily bars**. They are not orders, fills,
  an execution price, realized profit or a broker/paper action. Nothing in this change places,
  simulates or records a trade.
- Daily aggregates cannot establish intraday order. A session that reaches both levels is recorded
  as a stop by a deliberately conservative convention; the real intraday sequence is unknown and
  the receipt says so.
- A gap through a level uses that session's daily open, which is a daily-bar observation, not a
  guaranteed fill.
- Daily aggregates may include qualifying extended-hours trades. Dividends, fees, financing and
  execution costs are excluded.
- `targetHit`, `stopHit` and `horizonClose` are reported as three separate counts. They are not a
  win rate: saved predictions can overlap, so they are not independent trades, and still-active and
  unavailable predictions are excluded from the denominator.
- **No predictive accuracy is established by this change.** Every prediction saved before today
  carries the endpoint-only policy and is unaffected. Measuring whether the engine predicts anything
  requires future saved runs to reach their first hit or horizon, out of sample, after costs.
- The verified Nasdaq schedule covers 2026 only. A run whose horizon would extend past that fails
  closed rather than guessing dates.
- Saved research remains a separate local file that normal backup does not cover.

## Integration handoff

Not merged, not pushed, not installed. The worktree is clean and carries the four
implementation commits plus this evidence commit ahead of `main` (`aeb9dab`). Merging, pushing and
installing the signed build remain the owner's call.
