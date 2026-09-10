# Native Workspaces Implementation Plan

> **For agentic workers:** Use executing-plans for parent-owned serial implementation; use read-only supporting review. Steps use checkbox syntax. The existing isolated worktree is verified and must not be replaced.

**Goal:** Replace custom navigation with native Apple containers and expose reliable, understandable research workflows.

**Architecture:** MarketsView remains the single lifecycle owner. Navigation and details consume the existing route, store and service state; they create no data engine. Retain transient drafts and research selection above route replacement.

**Tech Stack:** Swift 6, SwiftUI, AppKit/UIKit native-host tests, Swift Testing, existing Xcode26.6 and27 toolchains. No new dependency.

## Global constraints

Preserve the existing 41 dirty records, HEAD661a1bba, all historical records, original nine route raw values/shortcuts, Day101/manual500 rules, 60-second research versus ten-second fill qualification. No installed-app replacement, pushes, real orders, broker relay or model start. Sole writer/heavy tester remains this task. iPhone paper execution is not enabled.

## Task 1 — Native navigation and separate workflows

Files: `StockSage/Sources/Views/StockSageDesktopNavigation.swift`, `MarketsView.swift`, `StockSageChatSection.swift`; `StockSageTests/MarketSectionNavigationTests.swift`.

- [ ] Add a native-host assertion that the actual desktop navigation contains `NSTableView`; current custom sidebar must fail it.
- [ ] Add destination assertions using `MarketSection(rawValue: "research")` and `MarketSection(rawValue: "paper")`; they must currently return nil and fail the new expectation.
- [ ] Run the section suite before changes using the exact focused command below; inspect assertion failures.
- [ ] Append cases, retaining original enum prefix. Implement `NavigationSplitView { StockSageDesktopNavigation(selection: $section) } detail: { desktopContent }` with a native List. Keep shortcut construction bounded to `MarketSection.allCases.prefix(9)`.
- [ ] Change content into `page(for section: MarketSection)` so each native phone tab renders its own route. Remove drawer overlays and both custom navigation gestures. Keep common lifecycle modifiers outside all tab contents.
- [ ] Move the existing manual panel to Research and Day101 panel to Paper Trading. On iPhone show an explicit paper availability message, without Start or an invented remote balance. Rename Portfolio page display using a title property; raw value stays `Paper`.
- [ ] Run focused section and Chat tests, then inspect Mac/iPhone native-host layouts and route selection.

## Task 2 — Persistent presentation and honest research detail

Files: `StockSage/Sources/Views/StockSageResearchModesPanel.swift`, `StockSage/Sources/StockSage/StockSageChat.swift`, `StockSageChatSection.swift`, `StockSagePaperAutomationPanel.swift`; `StockSageTests/StockSageChatTests.swift`, `StockSageHorizonResearchTests.swift`, `StockSagePaperAutomationTests.swift`.

- [ ] Reproduce draft loss with the production Chat view: set composer text, remove/reinsert its view with the same session, assert retained text.
- [ ] Retain a transient `@Published var draft = ""` in `StockSageChatSession`, bind the real composer to it, and keep clear/send behavior explicit. Do not encode the draft as a saved turn.
- [ ] Retain manual horizon, search, Buy-only and selected symbol via a small presentation state binding owned by MarketsView. Keep service state in `StockSageHorizonResearch.shared`.
- [ ] Replace the below-table detail with `.inspector(isPresented:)` on Mac and a native compact sheet on iPhone, reusing `resultDetail`. Bind presentation to a currently visible selection. Use scenario labels and visible 500-alphabetical-listings text.
- [ ] Assert `monitoringLabel(running: true, at: openSession)` contains `enabled`, not `active`; implement the wording-only correction and show the Pause consequence visibly.
- [ ] Run focused regression suites and inspect captured data values/labels, incomplete/filtered-empty states, inspector dismissal, draft retention and no render-time action callbacks.

## Task 3 — Platform verification and delivery evidence

- [ ] Run full macOS and iPhone26.5 tests serially, with three documented exclusions only.
- [ ] Run `bash tools/gate.sh /Users/saleh/StockSage-wt/qwen-context all` in a unique temporary artifact directory.
- [ ] Build/test using `DEVELOPER_DIR=/Users/saleh/Downloads/Xcode-beta.app/Contents/Developer` on Mac27 and a dedicated iPhone17Pro iOS27 simulator. Record any beta/compiler incompatibility separately from app failures.
- [ ] Run independent read-only diff review; fix material findings, rerun affected gates.
- [ ] Record source/build identity, exact counts, inspected screenshots and remaining live/device/accessibility limitations in the artifact report and HANDOFF. No installation or push.

### Focused command

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project /Users/saleh/StockSage-wt/qwen-context/StockSage.xcodeproj -scheme StockSage \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /Users/saleh/StockSage-fixes-20260910.bFAFrT/derived-macos \
  -only-testing:StockSageTests/MarketSectionNavigationTests
```

Use unique result bundles/logs under `/Users/saleh/StockSage-native27-20260910.jhR6DG`; never overwrite prior receipts. The full gate commands mirror `/Users/saleh/StockSage-reconcile-20260910.gNvfUH/run-final-gates.sh` with new artifacts. Prior receipts are comparison context, not a substitute for rerunning changed sources.
