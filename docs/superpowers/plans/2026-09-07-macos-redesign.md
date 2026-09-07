# StockSage macOS Redesign Implementation Plan

> **For agentic workers:** Use executing-plans inline. Owner requires all work in
> this task, without new tasks/subagents. Existing wt/coverage is already isolated.

**Goal:** Replace the cramped macOS board with a right-sidebar native workspace.

**Architecture:** MarketsView retains all stores, tasks and mutations. Desktop-only
chrome and section composition reuse existing working views; Chat shares logic but
gets a desktop transcript/composer layout. No additional dependencies or data layer.

**Tech Stack:** SwiftUI, AppKit Settings scene, Swift Testing, Xcode26.6.

## Global constraints

- Approved spec: docs/superpowers/specs/2026-09-07-macos-redesign-design.md.
- Minimum900×700; preferred1280×840; rail220/64pt; page1200pt; Chat860pt.
- Preserve iPhone rendering, financial logic and owner data. Qwen/automation remain off.
- Explicit staging, heredoc commits on wt/coverage; no pushes or real orders.
- Preserve nine MarketSection identities and existing Command-number assignments.
- Default Mac to Briefing-as-Home; explicit QA and iPhone destinations are unchanged.

## Task1: desktop navigation and page composition

Files: create StockSage/Sources/Views/StockSageDesktopNavigation.swift; modify
StockSage/Sources/Views/MarketsView.swift, StockSage/Sources/App/StockSageApp.swift,
StockSage/Sources/DesignSystem/DesignSystem.swift; extend
StockSageTests/MarketSectionNavigationTests.swift.

Interfaces: StockSageDesktopNavigation(selection:Binding<MarketSection>), owning a
macOS-only persisted collapsed flag; StockSageDesktop.sections:[MarketSection],
title(for:MarketSection)->String, shortcut(for:MarketSection)->Int,
sidebarWidth(collapsed:Bool)->CGFloat. No store observation in the sidebar.

- [ ] Add and execute desktop navigation contract tests (Mac-only):

```swift
@Test @MainActor func desktopDestinationsKeepEveryExistingRoute() {
    #expect(Set(StockSageDesktop.sections) == Set(MarketSection.allCases))
    #expect(StockSageDesktop.sections.count == MarketSection.allCases.count)
    #expect(StockSageDesktop.sections.first == .briefing)
    #expect(StockSageDesktop.title(for: .briefing) == "Home")
    #expect(StockSageDesktop.title(for: .all) == "Markets")
    for (index, section) in MarketSection.allCases.enumerated() {
        #expect(StockSageDesktop.shortcut(for: section) == index + 1)
    }
    #expect(StockSageDesktop.sidebarWidth(collapsed: true) == 64)
    #expect(StockSageDesktop.sidebarWidth(collapsed: false) == 220)
}
```

- [ ] Implement desktop metadata/sidebar, native SettingsLink, labelled selection,
  accessible collapse action and Reduce Motion/Transparency support. Exact ordering:

```swift
static let sections: [MarketSection] = [
    .briefing, .watchlist, .ideas, .all, .catalysts, .heatmap, .portfolio, .alerts, .chat
]
static func sidebarWidth(collapsed: Bool) -> CGFloat { collapsed ? 64 : 220 }
static func title(for section: MarketSection) -> String {
    switch section { case .briefing: "Home"; case .all: "Markets"; default: section.title }
}
static func shortcut(for section: MarketSection) -> Int {
    (MarketSection.allCases.firstIndex(of: section) ?? 0) + 1
}
```

- [ ] Wrap current iPhone scroll tree in its platform branch. On Mac render fixed
  heading/status, desktop page and trailing sidebar; keep current lifecycle modifiers
  on the common root so section switching cannot duplicate polling. Use the existing
  section switch for unchanged pages, Home composition for .briefing and full-height
  Chat for .chat. Set Mac's WindowGroup default destination/size explicitly.
- [ ] Separate Portfolio into Holdings/Journal/Paper/Analytics with existing components;
  move Ideas tools into disclosures. Do not change their bindings or computations.
- [ ] Apply neutral macOS-only canvas/card tokens, roomy typography and column widths.
  Preserve semantic colors and all stale/source/error labels. Keep all iPhone branches.
- [ ] Execute the focused navigation tests and compile the macOS app; inspect resulting
  diff for duplicated tasks, section reachability and controls displaced offscreen.

Focused command (unique artifact suffix per execution):

```sh
xcodebuild test -project StockSage.xcodeproj -scheme StockSage -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stocksage-codex-m1b.qzpbNS \
  -only-testing:StockSageTests/MarketSectionNavigationTests
```

Expected first run: compilation rejects missing desktop type; after implementation,
all old traversal and new desktop contracts pass. No owner state/network in tests.

## Task2: desktop Chat, review and complete gates

Files: modify StockSage/Sources/Views/StockSageChatSection.swift and HANDOFF.md;
update this plan and agent-docs/PIPELINE_TAKEOVER_2026-09-06.md with executed evidence.

Interfaces: retain StockSageChatSection(store:openModelSettings:). Extract private
conversation and composer view properties; send(), cancel(), sourceCard() and snapshot
methods retain their original semantics. Layout composition:

```swift
#if os(macOS)
VStack(spacing: 0) {
    ScrollView { conversation.padding(24).frame(maxWidth: 860) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    Divider()
    composer.padding(20).frame(maxWidth: 860)
}
#else
VStack(alignment: .leading, spacing: 16) { conversation; composer }.padding(16)
#endif
```

- [ ] Extract existing transcript/composer without duplicating StateObject or send tasks.
  Keep privacy copy accessible under an explicit disclosure on Mac, full text on iPhone.
  Keep failed/cancelled answers, provenance and clear-history confirmation unchanged.
- [ ] Run navigation and Chat focused suites; inspect both platform compilation branches.
- [ ] Run full canonical gates serially, Mac then iPhone17Pro(gate), using existing
  derived data and exclusions below. Never edit Swift while a gate is running.

```sh
xcodebuild test -project StockSage.xcodeproj -scheme StockSage -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stocksage-codex-m1b.qzpbNS \
  -skip-testing:StockSageTests/CalibrationPersistRunTests \
  -skip-testing:StockSageTests/LiveUniverseVerificationTests \
  -skip-testing:StockSageTests/StrategyBaselineMeasurementTests
```

Repeat with destination
`platform=iOS Simulator,id=3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA`.

- [ ] Inspect offline populated native UI when feasible: all nine routes, minimum/full
  window, rail toggle/shortcuts, four Portfolio tabs, Settings, long Chat and fixed input.
  Report any unavailable native check explicitly; do not claim screenshots from builds.
- [ ] Self-review diff, record exact test counts/artifacts and UI evidence, explicitly
  stage only this task's files, commit with required heredoc/coauthor, do not push.
  Keep previous app recoverable if installing; leave Qwen/automation off.
