# Installed Mac retest — 25 September 2026

## Result

The owner's “test it” request was checked against the already running signed Release `f1ac1f7`, with checkout `55a5c068bb50a80fbf8911249d133d46c1b6490b`. No application code was changed or installed. The automated suite passed; manual inspection found one remaining low-severity wording issue, so this is not a claim that the UI is issue-free.

## Fresh executed checks

The canonical serial arm64 macOS test run passed **3,263 definitions / 4,253 executions / zero failures / five existing skips**, direct `xcodebuild test` exit **0**, in **333.391 seconds**. All **479 source/project/resource hashes** were unchanged before/after, manifest `f188f00e6726109d14d2e24da65ed471cbbaac0279337d25c8e539992b56f676`. The targeted layout, reentrant, publication, constraint and geometry diagnostic guard found no matching warnings. Five existing excessive-window warnings remain; existing SwiftUI navigation warnings are not claimed fixed.

The run excludes the existing opt-in `CalibrationPersistRunTests`, `LiveUniverseVerificationTests` and `StrategyBaselineMeasurementTests`; excluded tests are not counted as passes. Local result bundle/log/receipt: `work/scanner-news/installed-retest-full-20260925.xcresult`, `.log` and `-receipt.json` in the task workspace.

A separate read-only reviewer verified the installed strict signature and executable SHA-256 `097b19e48840d2b8c1c6ee2f6ae94a4de7fa45ff557a01f9bbb84317ccb18a33`; all 479 manifest files match the installed release's tested source. Changes since that application commit are documentation only.

## Installed interaction and preservation checks

- All nine primary destinations opened.
- Saved research displayed twenty manual runs; its method disclosure expanded and the sheet dismissed correctly.
- Saved research → Settings → Open model setup → native Back → Saved research passed twice. Server URL and Model fields were present in the existing main window.
- Both cap trackers remained enabled and Telegram paired, correctly waiting outside Monday–Friday 11:00–23:00 Asia/Riyadh. No settings were changed; secondary test windows were closed.
- The dated screener capture remained present with 530 Micro-filter matches. This is not a new capture or a verified tracked-eligible count.
- All **3,381** compared saved JSON/JSONL files remained byte-identical, with no added or removed files during the checks.

Local receipts: `work/test-20260925/installed-ui.json` and `result-summary.json`. Detailed fingerprint inventory stays private under the task workspace.

## Finding T01 — generic research hint contradicts completed setup

**Low severity, open:** the Micro cap and Large cap research headline still says “Set up Telegram and enable watching” when the tracker is already enabled and paired. The actual tracker card reports its state correctly; this is not evidence of lost pairing.

Root cause: `StockSageSameDayResearch.swift` initializes a generic status string for both Astra modes; `StockSageSameDayResearchPanel.swift` presents it separately from the corrected monitoring guidance. The earlier L12 repair covered the monitor's status and momentum status, not this research headline.

The smallest correction is state-neutral startup guidance pointing to tracking controls or a manual check. Dynamic status errors and the separate retained run blocker must remain visible. A future regression should render the full cap panel for both modes, including a retained blocker and subsequent dynamic error. This verification task records the issue without changing the installed application.

## Boundaries

No new model assessment, model startup, paid compute, manual provider connection probe, Telegram test message or broker action was performed. Existing automatic market-feed activity continued. The stored Gemma warning and dated Micro cap float-identity failure remain visible. Live research acceptance/delivery and provider completeness were not established. No iOS build, test or deployment ran.
