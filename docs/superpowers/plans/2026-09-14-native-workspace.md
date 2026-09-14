# Native Workspace Implementation Plan

**Goal:** Deliver the owner's polished native Mac direction across the existing StockSage workflows.

**Architecture:** Presentation changes in existing SwiftUI views. Native split view and inspector remain window-owned; stores, asynchronous work and financial decisions are unchanged. Lead owns integration, tests and install.

**Tech Stack:** Existing SwiftUI/AppKit, Xcode 26.6, no dependencies.

## Global constraints

Follow the adjacent 2026-09-14 design spec. Preserve dirty work and all financial, persistence and lifecycle invariants. No builds/tests from delegated writers. Build artifacts under /private/tmp. No push or commit of unrelated pending work.

## Implementation

- [x] Lead: reshape Research controls/status/results/footer in StockSageResearchModesPanel.swift. Native Table gets available height; a stable three-column table shows symbol/opinion/close while scenario levels remain in inspector. Reuse existing action/filter/detail helpers; preserve iPhone behavior.
- [x] Lead: refine desktop Home and shared chrome in MarketsView.swift and native row scale in StockSageDesktopNavigation.swift. Preserve all view lifecycle modifiers, feed branching and bounded text. Reuse briefing/regime/catalyst components.
- [x] Paper writer: StockSagePaperAutomationPanel.swift only. Reorganize existing render helpers into a legible account workspace, exact values/warnings/actions retained.
- [x] Chat writer: StockSageChatSection.swift only. Refine Mac reading hierarchy and evidence surfaces, exact session/composer behavior and iPhone UI retained.
- [x] Lead/reviewer: inspect integrated diff against the spec and existing functional test contracts; add a focused layout regression only for new adaptive behavior.
- [x] Lead: run canonical serial xcodebuild test for Mac then iPhone simulator with the three documented opt-in suites excluded. Inspect failures and result summaries. Exercise native render fixtures for wide/narrow/inspector and warning states.
- [x] Lead: preserve state and previous app, install exact tested candidate reversibly, visually inspect actual Home/Research/Paper/Chat plus remaining routes at wide/minimum sizes, verify keyboard navigation and retained drafts without sending requests. Record identity, test counts and screenshots in outputs; update HANDOFF.

Validation note: a fixed SwiftUI root frame in the native fixture conflicted with macOS inspector expansion. The fixture now uses a resizable viewport, real inspector and native sidebar policy, settling plus one resize, and checks table height/column fit. Native opening expansion is bounded by the inspector width; a requested 900-point window can expand to 1260. The original three opt-in test exclusions are unchanged. The full Mac run exposed a pre-existing alert test that read standard preferences; it now uses the established isolated-budget fixture pattern without production changes.

Completed: both final frozen gates passed (Mac2415/1skip/0fail; iPhone2335/0skip/0fail), exact tested app installed reversibly, all11 destinations plusSettings inspected, normal/narrow critical paths and native keyboard/draft checks verified. No additional production changes after gates. Receipt: /Users/saleh/Documents/Codex/2026-09-14/cp/outputs/StockSage-native-redesign-2026-09-14.md.
