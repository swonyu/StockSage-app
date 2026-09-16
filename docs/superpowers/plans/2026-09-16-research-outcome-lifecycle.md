# Research Outcome Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete every new saved prediction at its first verified target or stop hit, or at its exact seventh/fourteenth Nasdaq session close when neither level is hit.

**Architecture:** Keep deterministic outcome logic inside `StockSageResearchHistory`, reuse the existing Massive adjusted-daily request and parser, and trigger the same bounded check from app activation and Saved Research. Version the new behavior per run so legacy schedules and evaluated receipts remain unchanged. The live quote stream is not consulted or modified.

**Tech Stack:** Swift 6, SwiftUI, Foundation, Swift Testing, existing Massive daily aggregate client. No new dependency, model request, broker action, background poller, or live-stream coupling.

## Global Constraints

- Work only in `/Users/saleh/StockSage-wt/research-pipeline-20260915`.
- New predictions use settled adjusted daily OHLC bars; the existing live-price stream remains untouched.
- A bar that reaches both target and stop resolves to `stopHit`.
- A gap through a terminal level uses the daily open as the observed outcome price.
- No hit before the horizon remains active; no hit at the horizon becomes `horizonClose`.
- Original predictions, evidence, levels, and existing evaluation receipts are immutable.
- Missing or invalid required bars fail closed; never substitute an adjacent session.
- Preserve external-access, sample-data, credential-revision, cancellation, storage, and 25-check-per-pass guards.
- Outcome measurements are research evaluation, not orders, fills, realized profit, or proof of predictive accuracy.

---

### Task 1: Versioned first-hit outcome engine

**Files:**
- Modify: `StockSage/Sources/StockSage/StockSageResearchHistory.swift`
- Test: `StockSageTests/StockSageResearchHistoryTests.swift`

**Interfaces:**
- Consumes: `Run`, `Prediction.levels`, `Observation.history`, `benchmarkDay(after:)`, `targetClose(for:)`.
- Produces: `OutcomePolicy.dailyBarFirstHit`, `Evaluation.TerminalKind`, `DailyBar`, and `evaluate(_:in:observation:now:)` receipts whose first terminal event is reproducible from stored bars.

- [ ] **Step 1: Add failing policy and first-hit tests**

Extend the existing `run` fixture with `levels: History.Levels? = nil` and `outcomePolicy: History.OutcomePolicy? = nil`, pass both to the prediction/run initializers, then add focused tests with explicit OHLC arrays:

```swift
private func dailyRun(horizon: History.Horizon = .week) -> History.Run {
    run(horizon: horizon, referencePrice: 100, policy: .nextTradingDateSessions,
        levels: .init(entry: 100, stop: 90, target: 120,
            at: date("2026-09-11T04:00:00Z"), basis: "Captured ATR scenario"),
        outcomePolicy: .dailyBarFirstHit)
}

@Test func firstTerminalBarWinsAndSameBarUsesStop() throws {
    let original = dailyRun()
    let targetFirst = History.evaluate(original.predictions[0], in: original,
        observation: dailyObservation(highs: [105, 121, 125], lows: [98, 95, 89]),
        now: date("2026-09-18T04:01:00Z"))
    #expect(targetFirst.terminalKind == .targetHit)

    let sameBar = History.evaluate(original.predictions[0], in: original,
        observation: dailyObservation(highs: [105, 121], lows: [98, 89]),
        now: date("2026-09-17T04:01:00Z"))
    #expect(sameBar.terminalKind == .stopHit && sameBar.sameBarStopFirst == true)
}
```

Also add separate tests for stop-before-target, gap below stop, gap above target, no hit before day seven, day-seven close, day-fourteen close, missing interior sessions, and invalid adjustment reference.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project StockSage.xcodeproj -scheme StockSage -configuration Debug -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -jobs 2 -derivedDataPath /private/tmp/stocksage-outcome-red -only-testing:StockSageTests/StockSageResearchHistoryTests
```

Expected: compilation fails because the new policy and terminal receipt fields do not exist.

- [ ] **Step 3: Add the minimal versioned data contract**

Add these nested types and optional fields. Use explicit `CodingKeys`, `init(from:)`, and `encode(to:)` for `Run` so absent legacy policy remains absent on round-trip:

```swift
nonisolated enum OutcomePolicy: Int, Codable, Sendable {
    case dailyBarFirstHit = 2
}

nonisolated struct DailyBar: Codable, Sendable, Equatable {
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
}

extension Evaluation {
    enum TerminalKind: String, Codable, Sendable {
        case targetHit, stopHit, horizonClose
    }
}
```

Add `let outcomePolicy: OutcomePolicy?` to `Run` and an initializer argument defaulting to nil. Add optional `terminalKind`, `terminalAt`, `outcomePrice`, `adjustedEntry`, `adjustedStop`, `adjustedTarget`, `dailyBars`, and `sameBarStopFirst` to `Evaluation`. New `snapshot` values set `.dailyBarFirstHit`; decoded legacy runs leave it nil.

- [ ] **Step 4: Implement the pure chronological decision**

Keep the loop private and deterministic:

```swift
private nonisolated static func terminalEvent(
    bars: [DailyBar], stop: Double, target: Double, horizonEnded: Bool
) -> (kind: Evaluation.TerminalKind, bar: DailyBar, price: Double, sameBar: Bool)? {
    for bar in bars {
        let stopHit = bar.low <= stop
        let targetHit = bar.high >= target
        if stopHit && targetHit {
            return (.stopHit, bar, bar.open <= stop ? bar.open : stop, true)
        }
        if stopHit { return (.stopHit, bar, bar.open <= stop ? bar.open : stop, false) }
        if targetHit { return (.targetHit, bar, bar.open >= target ? bar.open : target, false) }
    }
    guard horizonEnded, let last = bars.last else { return nil }
    return (.horizonClose, last, last.close, false)
}
```

Build the complete expected session-date list from benchmark through the latest settled date capped at the horizon. Reject gaps. Compute the adjustment ratio from the fresh adjusted close on `prediction.referenceDate` divided by `prediction.referencePrice`, then apply it to captured entry, stop, and target. Require adjusted stop < adjusted entry < adjusted target. Before the horizon, return a nonterminal `.notDue` receipt when no event exists. At the horizon, create `.evaluated` with `horizonClose`. A new-policy prediction without complete levels/reference data skips first-hit classification and may finalize only from a complete horizon path.

- [ ] **Step 5: Validate receipts by recomputation**

Extend `valid(_:run:)` so a daily-policy evaluated receipt must have:

```swift
evaluation.terminalKind != nil
evaluation.terminalAt == evaluation.dailyBars?.last?.date
evaluation.outcomePrice == recomputed.price
evaluation.sameBarStopFirst == (recomputed.sameBar ? true : nil)
evaluation.adjustedStop == prediction.levels.map { $0.stop * ratio }
evaluation.adjustedTarget == prediction.levels.map { $0.target * ratio }
```

Recompute the first terminal event from stored OHLC bars. Reject missing interior dates, invalid OHLC invariants, future bars, a terminal date after the scheduled horizon, or any mismatch. Keep the legacy endpoint validator unchanged when `run.outcomePolicy == nil`.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run the Task 1 command with `-derivedDataPath /private/tmp/stocksage-outcome-green-1`.

Expected: all `StockSageResearchHistoryTests` pass, including the new first-hit tests and existing legacy byte-preservation tests.

- [ ] **Step 7: Commit**

```bash
git add StockSage/Sources/StockSage/StockSageResearchHistory.swift StockSageTests/StockSageResearchHistoryTests.swift
git commit -m "Evaluate saved picks at first target or stop"
```

---

### Task 2: Fetch only settled sessions and check active predictions

**Files:**
- Modify: `StockSage/Sources/StockSage/StockSageHorizonResearch.swift`
- Modify: `StockSage/Sources/StockSage/StockSageResearchHistory.swift`
- Test: `StockSageTests/StockSageHorizonResearchTests.swift`
- Test: `StockSageTests/StockSageResearchHistoryTests.swift`

**Interfaces:**
- Consumes: `OutcomePolicy`, `reviewEnd(for:now:)`, `dailyHistoryRequest`, `parseResearchHistory`, existing ownership closures.
- Produces: `reviewEnd(for:now:) -> Date?`, a policy-aware `fetchReviewObservation`, and `checkActive` that evaluates at most 25 pending predictions per pass.

- [ ] **Step 1: Add failing settled-window request tests**

Add offline transport tests asserting the exact Massive path. For a daily-policy week run checked on September 18, the request begins on the saved reference date and ends on the latest fully ended New York session; it must not request the future day-seven date:

```swift
#expect(request.url?.path.contains("/2026-09-11/2026-09-17") == true)
```

Add tests for midday New York, just before/after midnight, weekend, holiday, horizon cap, cancellation, changed credential revision, unadjusted payload, and a legacy run retaining its endpoint-only request window.

- [ ] **Step 2: Run fetch tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project StockSage.xcodeproj -scheme StockSage -configuration Debug -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -jobs 2 -derivedDataPath /private/tmp/stocksage-outcome-red-2 -only-testing:StockSageTests/StockSageHorizonResearchTests -only-testing:StockSageTests/StockSageResearchHistoryTests
```

Expected: request-window and active-check assertions fail because review remains horizon-only.

- [ ] **Step 3: Add the settled review boundary**

Implement a calendar helper that starts with the New York date strictly before `now` and walks backward through the verified Nasdaq schedule. Cap the result at `targetClose(for:)`:

```swift
nonisolated static func reviewEnd(for run: Run, now: Date) -> Date? {
    guard run.outcomePolicy == .dailyBarFirstHit else { return targetClose(for: run) }
    let priorDate = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
    // Walk backward to the latest verified trading date and return min(latest, target date).
}
```

Availability for daily-policy runs becomes due after the first whole monitoring date ends. Legacy availability continues to wait until the horizon date ends.

- [ ] **Step 4: Make the existing fetch policy-aware**

For daily policy, request from `prediction.referenceDate` through `reviewEnd`. For legacy policy, retain benchmark-through-target behavior. Require `fetchedAt` after the requested end date is settled, not after the future horizon. Continue to use one adjusted Massive series and the existing 2 MB response cap.

- [ ] **Step 5: Generalize the bounded checker**

Rename `checkDue` to `checkActive` and select predictions whose policy-aware availability is `.due`. Persist only `.evaluated` or `.dataUnavailable` receipts; a valid no-hit `.notDue` result stays pending without a terminal record. Preserve sort order, the 25-item cap, cancellation checks before and after every await, and credential/policy ownership supplied by the caller.

Use explicit summary copy:

```swift
lastCheckSummary = "Checked \(checked) active prediction\(checked == 1 ? "" : "s")."
    + (completed > 0 ? " \(completed) completed." : "")
    + (remaining > 0 ? " \(remaining) remain for another pass." : "")
```

- [ ] **Step 6: Run focused tests and verify GREEN**

Run the Task 2 command with `-derivedDataPath /private/tmp/stocksage-outcome-green-2`.

Expected: all selected history and horizon tests pass with zero network access.

- [ ] **Step 7: Commit**

```bash
git add StockSage/Sources/StockSage/StockSageHorizonResearch.swift StockSage/Sources/StockSage/StockSageResearchHistory.swift StockSageTests/StockSageHorizonResearchTests.swift StockSageTests/StockSageResearchHistoryTests.swift
git commit -m "Check active research outcomes on settled sessions"
```

---

### Task 3: One shared automatic/manual trigger

**Files:**
- Modify: `StockSage/Sources/StockSage/StockSageHorizonResearch.swift`
- Modify: `StockSage/Sources/App/StockSageApp.swift`
- Modify: `StockSage/Sources/Views/StockSageResearchHistoryView.swift`
- Test: `StockSageTests/StockSageHorizonResearchTests.swift`
- Test: `StockSageTests/StockSageResearchHistoryTests.swift`

**Interfaces:**
- Consumes: `StockSageResearchHistory.checkActive`, `fetchReviewObservation`, `StockSageStore.shared`, `StockSageResearchHistory.shared`.
- Produces: `checkSavedOutcomes(history:store:) async` used by both foreground activation and the Saved Research button.

- [ ] **Step 1: Add failing ownership and trigger tests**

Extract the caller wiring into one testable function with injected key, revision, clock, and fetch. Verify zero fetches for tests, sample data, disabled external tools, missing credentials, cancellation, and changed credential revision. Verify one foreground event cannot overlap an in-progress check because `history.isChecking` remains the single-flight guard.

- [ ] **Step 2: Run focused tests and verify RED**

Run the Task 2 focused command with `-derivedDataPath /private/tmp/stocksage-outcome-red-3`.

Expected: new trigger tests fail because only the Saved Research view currently owns the check closure.

- [ ] **Step 3: Reuse one shared caller**

Add a single helper beside the existing review fetch:

```swift
@MainActor
static func checkSavedOutcomes(history: StockSageResearchHistory, store: StockSageStore) async {
    guard !StockSageStore.isRunningTests, ToolPolicy.isExternalAllowed,
          !store.isSampleData, StockSageMassive.isConfigured else { return }
    let key = StockSageMassive.apiKey
    let revision = StockSageMassive.credentialRevision()
    let allowed = {
        !Task.isCancelled && ToolPolicy.isExternalAllowed && !store.isSampleData
            && StockSageMassive.apiKey == key
            && StockSageMassive.credentialRevision() == revision
    }
    await history.checkActive(allowed: allowed) { prediction, run in
        await fetchReviewObservation(prediction: prediction, run: run, key: key, allowed: allowed)
    }
}
```

Saved Research calls this helper. Its action label becomes **Check active results**.

- [ ] **Step 4: Trigger once per foreground activation**

Add a state revision to `StockSageApp` and a cross-platform active-scene trigger:

```swift
@State private var researchReviewRequest = 0

.onChange(of: scenePhase, initial: true) {
    if scenePhase == .active { researchReviewRequest &+= 1 }
}
.task(id: researchReviewRequest) {
    guard researchReviewRequest > 0 else { return }
    await StockSageHorizonResearch.checkSavedOutcomes(
        history: .shared, store: .shared)
}
```

Keep the existing iOS monitor start/stop behavior. Do not add timers, background tasks, quote subscriptions, or model calls.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the Task 2 command with `-derivedDataPath /private/tmp/stocksage-outcome-green-3`.

Expected: all selected tests pass; test hosts and sample mode perform zero external fetches.

- [ ] **Step 6: Commit**

```bash
git add StockSage/Sources/StockSage/StockSageHorizonResearch.swift StockSage/Sources/App/StockSageApp.swift StockSage/Sources/Views/StockSageResearchHistoryView.swift StockSageTests/StockSageHorizonResearchTests.swift StockSageTests/StockSageResearchHistoryTests.swift
git commit -m "Refresh active research outcomes on app foreground"
```

---

### Task 4: Honest outcome and aggregate UI

**Files:**
- Modify: `StockSage/Sources/StockSage/StockSageResearchHistory.swift`
- Modify: `StockSage/Sources/Views/StockSageResearchHistoryView.swift`
- Test: `StockSageTests/StockSageResearchHistoryTests.swift`
- Test: `StockSageTests/StockSageNativeComponentTests.swift`

**Interfaces:**
- Consumes: terminal receipt fields and `HomeSummary`.
- Produces: terminal-kind counts and readable Active/Target hit/Stop hit/Horizon close/Data unavailable presentation on Mac and iPhone.

- [ ] **Step 1: Add failing summary and copy tests**

Add terminal fixtures and assert:

```swift
#expect(summary.targetHits == 1)
#expect(summary.stopHits == 1)
#expect(summary.horizonCloses == 1)
#expect(StockSageResearchHistoryView.outcomeSummary(stopReceipt).hasPrefix("Stop hit"))
```

Add geometry/accessibility checks that the button reads **Check active results**, terminal labels remain visible at accessibility text sizes, and a same-bar stop disclosure is scroll-reachable.

- [ ] **Step 2: Run UI-focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project StockSage.xcodeproj -scheme StockSage -configuration Debug -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -jobs 2 -derivedDataPath /private/tmp/stocksage-outcome-red-4 -only-testing:StockSageTests/StockSageResearchHistoryTests -only-testing:StockSageTests/StockSageNativeComponentTests
```

Expected: terminal count and copy assertions fail.

- [ ] **Step 3: Render terminal outcomes**

Extend `HomeSummary` with `targetHits`, `stopHits`, and `horizonCloses`. Count only `.evaluated` daily-policy receipts; keep legacy rose/fell/flat counts for old receipts. Present:

```swift
switch evaluation.terminalKind {
case .targetHit: "Target hit"
case .stopHit: "Stop hit"
case .horizonClose: "Horizon close"
case nil: legacyDirectionLabel
}
```

Show terminal date, adjusted entry/stop/target, observed outcome price, provider/fetch time, and the existing direction-only disclosure. For `sameBarStopFirst == true`, show: **“The daily bar reached both levels; intraday order is unavailable, so the conservative stop-first rule was applied.”**

Home reports target hits, stop hits, and horizon closes as separate counts. It does not label their ratio a win rate until a later measured-statistics design defines a denominator and comparison basis.

- [ ] **Step 4: Run UI-focused tests and verify GREEN**

Run the Task 4 command with `-derivedDataPath /private/tmp/stocksage-outcome-green-4`.

Expected: history and native component tests pass.

- [ ] **Step 5: Commit**

```bash
git add StockSage/Sources/StockSage/StockSageResearchHistory.swift StockSage/Sources/Views/StockSageResearchHistoryView.swift StockSageTests/StockSageResearchHistoryTests.swift StockSageTests/StockSageNativeComponentTests.swift
git commit -m "Show target stop and horizon outcomes"
```

---

### Task 5: Compatibility, gates, and release evidence

**Files:**
- Modify: `README.md`
- Create: `docs/reviews/2026-09-16-research-outcome-lifecycle-results.md`
- Test: `StockSageTests/StockSageResearchHistoryTests.swift`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: regression proof, platform gates, and an explicit install/push handoff without changing owner data during tests.

- [ ] **Step 1: Add final compatibility regressions**

Encode a legacy run and receipt with new keys removed, decode and re-encode it, and require byte equality under `.sortedKeys`. Persist a new target-hit receipt, reopen the file, attempt a later stop receipt, and require the original target receipt to remain unchanged. Corrupt each optional terminal field in turn and require the store to preserve the original bytes and report an error.

- [ ] **Step 2: Run all focused outcome tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project StockSage.xcodeproj -scheme StockSage -configuration Debug -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -jobs 2 -derivedDataPath /private/tmp/stocksage-outcome-focused -only-testing:StockSageTests/StockSageResearchHistoryTests -only-testing:StockSageTests/StockSageHorizonResearchTests -only-testing:StockSageTests/StockSageNativeComponentTests
```

Expected: selected suites pass with zero failures and no live provider calls.

- [ ] **Step 3: Run the full Mac gate**

Run the canonical Mac command with unique DerivedData and result bundle paths:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project StockSage.xcodeproj -scheme StockSage -configuration Debug -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -jobs 4 -derivedDataPath /private/tmp/stocksage-outcome-final-mac -resultBundlePath /private/tmp/stocksage-outcome-final-mac.xcresult
```

Expected: all Mac tests pass apart from documented skips; record exact totals from the result bundle.

- [ ] **Step 4: Run the full iPhone gate**

Use the available iOS 27 parity simulator `23E420EF-11AB-4623-ADED-46F528468665`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project StockSage.xcodeproj -scheme StockSage -configuration Debug -destination 'platform=iOS Simulator,id=23E420EF-11AB-4623-ADED-46F528468665' -parallel-testing-enabled NO -jobs 4 -derivedDataPath /private/tmp/stocksage-outcome-final-ios -resultBundlePath /private/tmp/stocksage-outcome-final-ios.xcresult
```

Expected: all iPhone tests pass apart from documented skips; record the resolved device, OS, and exact totals.

- [ ] **Step 5: Run source and compile gates**

Run:

```bash
TMPDIR=/private/tmp/stocksage-outcome-gate bash tools/gate.sh /Users/saleh/StockSage-wt/research-pipeline-20260915 all
```

Expected: macOS, iOS, and test compile/typecheck gates report OK.

- [ ] **Step 6: Inspect the signed local build without mutating saved history**

Create a fresh release directory, then build the exact tested clean commit:

```bash
STOCKSAGE_RELEASE_DIR="$(mktemp -d /private/tmp/stocksage-outcome-release.XXXXXX)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project StockSage.xcodeproj -scheme StockSage -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$STOCKSAGE_RELEASE_DIR/DerivedData" -jobs 4 CODE_SIGN_IDENTITY='Apple Development' CONFIGURATION_BUILD_DIR="$STOCKSAGE_RELEASE_DIR/Release" build
codesign --verify --deep --strict "$STOCKSAGE_RELEASE_DIR/Release/StockSageX.app"
```

Before replacement, quit StockSage, copy `/Applications/StockSageX.app` and `/Users/saleh/Library/Application Support/StockSage/ResearchHistory` into a new mode-700 rollback directory under `/Users/saleh/Documents/Codex/2026-09-14/cp/work/research-outcome-release/`, and hash both source and backup trees. Stage the candidate with `ditto`, verify its signing requirement matches the installed app, atomically rename the old and staged bundles, then require the owner-history hash to remain unchanged. Open Saved Research and verify Active, Target hit, Stop hit, Horizon close, same-bar disclosure, and **Check active results** using isolated render fixtures; do not inject fixtures into owner history. Confirm the installed bundle manifest and tested commit in the release receipt.

- [ ] **Step 7: Write release evidence**

Update `README.md` to describe first-hit completion and write `docs/reviews/2026-09-16-research-outcome-lifecycle-results.md` with commit IDs, focused/full test totals, artifact paths, inspected states, installed-app identity, and limitations. State clearly that predictive accuracy requires future saved outcomes.

- [ ] **Step 8: Commit the evidence**

```bash
git add README.md docs/reviews/2026-09-16-research-outcome-lifecycle-results.md StockSageTests/StockSageResearchHistoryTests.swift
git commit -m "Document verified research outcome lifecycle"
```

- [ ] **Step 9: Integration handoff**

Confirm the worktree is clean and show commits relative to `main`. Merge, push, and install only under the owner's existing integration/release authorization, after all gates pass and the exact tested head remains unchanged.
