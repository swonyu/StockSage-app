# StockSage Swift concurrency audit — 20 September 2026

## Scope and identity

macOS implementation from committed main
`cc124f0143ca1cbfe5e590ac2142153d5990886c`, isolated branch
`codex/swift-concurrency-20260920`. Checkout:
`/Users/saleh/Documents/Codex/2026-09-20/stocksage-swift-concurrency/work/stocksage-concurrency`.
Common Git directory: `/Users/saleh/StockSage-app/.git`.
The active integration checkout and reserved momentum/stream files were not edited.
The parent task owns integration, publication, the combined full Mac gate and any
separately authorized installation. iOS and widgets remain on hold.

## Compiler and settings

Observed locally: Xcode 27.0 (`27A266a`), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`), macOS deployment floor 26.5.
Effective app Debug and Release settings before changes:
`SWIFT_VERSION=6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, and
`SWIFT_APPROACHABLE_CONCURRENCY=YES`; strict checking was not explicitly recorded.

Swift 6 language mode already enables complete concurrency checking. This change
records `SWIFT_STRICT_CONCURRENCY=complete` explicitly for the macOS SDK in app and
test Debug/Release configurations. It preserves the language mode, actor defaults,
deployment floor and widget settings. The compiler version and language mode are
different settings: the installed 6.4 compiler builds Swift 6 mode.
[Apple build-setting reference](https://developer.apple.com/documentation/xcode/build-settings-reference),
[Swift 6.4 release](https://www.swift.org/blog/swift-6.4-released/).

No warning suppression, new unchecked escape, preconcurrency import, or unsafe
isolation annotation was added. The standalone compile gate already supplies
`-strict-concurrency=complete`; it is not a substitute for executed native tests.

## Complete declaration inventory

The baseline has zero `@preconcurrency` declarations, nine active
`@unchecked Sendable` declarations, and five `nonisolated(unsafe)` globals.
Two further unchecked declarations belong only to the archived review below.

| Declaration | Disposition and invariant |
| --- | --- |
| `StockSageQuoteService.YahooCooldown` | Retain one documented unchecked framework boundary. The SDK rejects checked conformance because `UserDefaults?` is not Sendable, although Foundation explicitly documents concurrent use. Its own deadline is now `Mutex<Date?>`; deadline extension and persistence share one critical section, so a shorter response cannot overwrite a longer deadline. Caller reuse of defaults remains supported. |
| `StockSageCodexResearch.Buffer` | Checked Sendable; one Mutex holds bytes, overflow and EOF. Callbacks append synchronously and snapshots are atomic. Existing stdout/stderr caps and ordering remain. |
| `StockSageBreadthCoverageTests.Counter` | Checked Sendable; one Mutex holds count and permission, preserving atomic revoke/count updates from task-group workers. |
| `StockSageStockScreenerTests.ChangingKey` | Checked Sendable; one Mutex holds read count and replacement threshold, preserving synchronous credential-revision fixtures. |
| `StockSageStockScreenerTests.Revision` | Checked Sendable; a Mutex protects its string. |
| `BenzingaBodyProtocol` | Retain Foundation URLProtocol conformance restatement. No mutable instance state; shared counters already use Mutex. Synchronous byte delivery; intentional incomplete response tests cancellation. |
| `MassiveBodyProtocol` | Retain Foundation URLProtocol conformance restatement. No additional stored state or asynchronous callbacks; native offline size-bound fixture. |
| `ModelBodyProtocol` | Same stateless Foundation boundary; covers actual/declared/understated response lengths. |
| `QuoteBodyProtocol` | Same stateless Foundation boundary; covers exact and excessive response lengths. |
| Archived `ReviewProtocol` and `ReviewProtocol.Counters` | Preserved historical reproduction, excluded from application and current tests. Its unchecked state and scheduling are not endorsed as a current pattern. |

Foundation's installed `NSUserDefaults.h` explicitly permits using the same object
from multiple threads or tasks. Keeping this narrow existing assertion is preferable
to disguising the shared object as a `sending` transfer into Mutex or adding an
unsafe stored property. [UserDefaults contract](https://developer.apple.com/documentation/foundation/userdefaults).

The five unsafe globals become four Mutex-backed synchronous properties
(`ToolPolicy.override`, `relativeStrengthEnabled`, `turnOfMonthEnabled`,
`candidateSelectorEnabled`) and one ordinary MainActor store property
(`qaSuppressPersistedCalibration`). Defaults remain nil, false, true, true and false.
Per-access locking does not make a complete test's save/mutate/assert/restore
transaction atomic; existing transaction locks remain. The legacy QA property has
no current writer and is read only by the MainActor store getter.

## Dispatch, ordering and lifetimes

The active baseline has two `DispatchTime.now()` calls, both for elapsed model
request diagnostics. They become `SuspendingClock` durations, preserving uptime's
exclusion of system sleep. The independently injected `ContinuousClock` deadline
remains unchanged. The active source contains no explicit DispatchQueue, group,
semaphore, source, work item or C dispatch scheduling calls.
[Apple clock semantics](https://developer.apple.com/videos/play/wwdc2022/110355/).

Foundation FileHandle readability callbacks remain a justified native I/O boundary.
They collect bytes directly into bounded synchronized state; they never launch one
Task per chunk, mutate UI state, or enqueue work behind an unbounded mailbox. The
MainActor process owner retains cancellation, deadlines, nonblocking stdin, output
validation and publication. This is not a claim that Foundation itself avoids GCD.
The callback API still has Foundation's documented I/O exception semantics; this
refactor does not replace the entire process transport.

Cancellation now maps to the existing interrupted outcome. `stopAll()` invalidates
the generation, captures owned Process objects and signals them synchronously;
its returned task allows a 100 ms grace period, kills remaining captured children,
and waits at most one additional second. One cancellation-independent cleanup task
replaces repeated detached sleep tasks. A child that outlasts the bound remains
registered for a later shutdown attempt and blocks new assessment admission.

App quit closes admission synchronously and waits for this result before replying
to AppKit, including when no local-model unload configuration exists. Failure
keeps the app open; cancelling model unload restores both admission states.
Successful cleanup confirms the captured children exited. It does **not** join
every research owner task, final receipt write or scratch-directory cleanup; no
broader persistence-completion guarantee is claimed.

The only explicit queued GCD work is
`agent-docs/archive/2026-09-09-benzinga/production-review/agent-docs/checks/benzinga_stream_review.swift:30`.
Its archive README excludes it from current targets/gates; the consolidation
manifest requires original bytes. SHA-256 remains
`78094a037a9efd901ac1452e22087450be394c5a2ae2deb30b0b7f52adbf99c9`.
Changing this timing-dependent historical reproduction would invalidate its receipt.

## Verification receipt

The source-level configuration assertion failed before the four settings were
added and passed after. The first native compile rejected YahooCooldown's checked
UserDefaults storage, directly establishing the retained framework exception.
The supported code compiled after retaining it. A compiler region-checker
limitation in an explicitly MainActor task-group closure was resolved by letting
the child await the existing MainActor entry point; no isolation escape was added.

Focused RED (`work/focused-red-5/result.xcresult`): native Xcode exit 65,
16 test definitions, 14 passed, two failed. The failures were exactly the wrong
cancellation message and a SIGTERM-ignoring child alive after `stopAll()` returned.
All other process-cap, byte-order, EOF and cooldown cases passed.

First focused GREEN (`work/focused-green/result.xcresult`): native Xcode exit 0,
208 definitions in 14 affected suites, zero failed or skipped. Independent Astra
Ultra review then identified the rare still-running-child registry edge; it was
corrected before the final focused gate. Final receipt is recorded below.

Final focused GREEN (`work/focused-green-final/result.xcresult`): exit 0,
**208 definitions in 14 suites, zero failed, zero skipped**, 20:42 Asia/Riyadh.
The five native UI diagnostic guards were clean. The final 464-file app/test/project
manifest was unchanged through the gate, SHA-256
`14aacc7ea166336032a6d4b3641ce1ddfc91102cfdd8163cdc8fc43e859c1be8`.
Both independent Astra Ultra reviewers found the lifecycle registry issue; the
final source review confirmed it resolved with no remaining actionable finding.

Effective `xcodebuild -showBuildSettings -json` was rechecked after the final gate
for **both targets in both configurations**: complete checking, Swift 6.0 mode,
MainActor default, approachable concurrency YES and macOS floor 26.5 in all four.
This is Release configuration inspection, not a Release build claim.

Artifact paths above are relative to
`/Users/saleh/Documents/Codex/2026-09-20/stocksage-swift-concurrency`, not the
source checkout. Each gate directory contains `run.log`, `exit.txt`, `summary.json`
and `result.xcresult`. The exact task-owned command wrapper is
`work/run-mac-gate.sh`. The final invocation was:

```sh
bash work/run-mac-gate.sh focused-green-final \
  -only-testing:StockSageTests/StockSageCodexResearchTests \
  -only-testing:StockSageTests/StockSageYahooCooldownTests \
  -only-testing:StockSageTests/StockSageBreadthCoverageTests \
  -only-testing:StockSageTests/StockSageStockScreenerTests \
  -only-testing:StockSageTests/StockSageQuoteTransportTests \
  -only-testing:StockSageTests/StockSageLocalModelServerTests \
  -only-testing:StockSageTests/StockSageMassiveTests \
  -only-testing:StockSageTests/StockSageBenzingaClientTests \
  -only-testing:StockSageTests/ToolPolicyTests \
  -only-testing:StockSageTests/WebToolsDisabledReasonTests \
  -only-testing:StockSageTests/StockSageBacktestParityTests \
  -only-testing:StockSageTests/StockSageTomGateTests \
  -only-testing:StockSageTests/StockSageCalibrationSelectorTests \
  -only-testing:StockSageTests/StockSageConvictionCalibrationTests
```

All runs use the canonical hosted macOS tests, arm64 Debug, four build jobs and
parallel test execution disabled. They scrub the seven opt-in environment triggers
and their `SIMCTL_CHILD_`/`TEST_RUNNER_` forms, and exclude only the established
CalibrationPersistRunTests, LiveUniverseVerificationTests and
StrategyBaselineMeasurementTests sentinel suites. No live model, provider,
Telegram, broker, or paid infrastructure calls were made. Test defaults use unique
synthetic domains and native child tests run fixed local fixtures only.

FileProvider repeatedly injected FinderInfo into generated products under
Documents, causing signing failures before test execution. The task-owned Derived
Data was moved to `/private/tmp/stocksage-concurrency-01a0bfce-derived` with its
original `work/derived` path symlinked, and only generated-product extended
attributes were removed. Signing checks and project signing settings were retained.
The installed app was not replaced or restarted; only native test hosts ran.

The parent owns the pending combined full Mac gate and any installation. These
focused tests are not represented as full-suite or installed-app verification.

## Living source-guide update proposal

After coordinated integration, add a concurrency paragraph to the living guide's
implementation/verification section: Swift 6.4 compiler, Swift 6 language mode,
explicit complete checking for macOS, checked Mutex state, retained Foundation
boundaries and verified process cleanup behavior. Copy the final combined Mac gate
counts and source identity from the parent's receipt. Keep implemented, tested and
installed status separate; do not infer provider, model or research readiness.

Preserve the exact four-key model schema, prompt/sampling contract, numeric and
qualification gates, saved research and pairing. The parent should bump the living
edition and preserve/regenerate the owner's PDF at its existing path. This task
does not overwrite the shared guide or PDF.

## Attached blueprint assessment

The owner's attached “Stockage” blueprint describes a Node/Express/Mongoose
encrypted-storage service, not this Swift stock-research app. Its backend,
cryptography and Core Data migration sections provide no basis for changing
StockSage's architecture or persistence.

Its useful guidance is to use checked concurrency boundaries, short synchronous
Mutex critical sections, and explicit cancellation/lifetime handling. Revalidate
the assumptions that can change across suspension—generation, policy, freshness
and ownership of publication—rather than mechanically rechecking every value.
Mutex does not replace actors for asynchronous workflows, and `sending` transfers
a disconnected isolation region rather than making shared references Sendable.
[SE-0433 Mutex](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0433-mutex.md),
[SE-0430 transfer](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md).

Swift 6.4's asynchronous defer and cancellation shields are real. However, the
installed SDK declares both `withTaskCancellationShield` overloads available only
on Apple OS 27.0 and later; this project supports macOS 26.5. Do not adopt them
unconditionally or raise the deployment floor for this refactor. Cancellation
remains cooperative, shielding does not guarantee cleanup succeeds, and detached
work cannot guarantee survival after app termination.
[SE-0504 shields](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0504-task-cancellation-shields.md),
[SE-0493 async defer](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0493-defer-async.md).

The blueprint's absolute memory-safety, cleanup and agent-mastery promises are not
verification evidence. Keep compiler diagnostics, independent review, runnable
regressions and exact-source native gates as the acceptance criteria. Its
unsubstantiated test-performance assertions do not justify replacing the current
hosted test runner or weakening the owner-state guards.

The second attached reference has concrete counterexamples to its promises:
`QuotaManager` never increments its generation or validates amount/balance, so
its post-await guard cannot prevent overdrawing quota. `CryptoKey.deinit` only
prints a wiping message; it does not erase memory. `try? context.save()` discards
persistence failures. These samples should not be copied into this app.
