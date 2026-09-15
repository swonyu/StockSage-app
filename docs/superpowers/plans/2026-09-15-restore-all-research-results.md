# Restore all Mac Research results

**Goal:** Follow the owner's request to show all checks, including Hold and Avoid, with Stop and Target visible in the table.

**Design:** Restore the existing native search/menu filter pattern. Mac starts at All checks; Top 5 buys remains selectable and iOS retains its current layout. The shared visible-row projection owns table/search/inspector selection. Read scenario prices from captured result levels. Keep the NASDAQ universe, accepted-opinion validation, original saved predictions and review scheduling unchanged; new top-five selection follows the clarified comparison below.

**Files:** Research panel, horizon orchestration, comparison, history, associated native/test fixtures, and their explanatory copy. Reuse SwiftUI/AppKit and the existing local-model client/history file; no added dependency.

- [x] Reproduce missing Hold/Avoid rows and Stop/Target columns in the existing native Research fixture using Buy/Hold/Avoid/incomplete results.
- [x] Restore All/Top 5/Buy/Hold/Avoid/incomplete/unchecked filters, filter-aware search/empty copy, and captured Stop/Target columns; check stored opinion before global in-flight status.
- [x] Verify filters preserve raw scans and saved top-five snapshots; test selection and live detail updates. Retain the finite minimum-size and visible-progress checks.
- [x] Run the canonical Mac and iPhone simulator gates using `work/research-pipeline/run-native-gate.py`; review native screenshots at 900 and 1200 points. Build signed Release only from the source manifests that passed.
- [ ] Preserve owner data, install the verified app at the authorized update point, and verify the actual All checks table and scenario columns.

## Owner clarification: best five across all checks

The owner clarified that Top 5 means the strongest research from the entire checked universe, not the first five Buy/Strong Buy records or activity-order ties. Compare all eligible accepted Buy/Strong Buy cases only after every per-horizon check completes. A Buy may outrank a Strong Buy. Preserve raw checks and all captured prices.

- [x] Add a schema-validated local-model comparison of dated cases, risks, cited facts and coverage. Include every eligible candidate; whole-pool comparison when it fits, otherwise explicitly approximate bounded rounds. Never drop candidate packets to fit a prompt. Keep whole mandatory cases/risks; disclose omitted whole cited records.
- [x] Keep the top-five view pending through collection/comparison; malformed, failed or cancelled comparison has no activity-order fallback.
- [x] Save final comparison order and exact round inputs/outputs with immutable prediction evidence. Preserve older saved ordering with a legacy-method label. Save completed ranking failures honestly without fabricated picks.
- [x] Check late candidate selection, all-pool participation, malformed responses, budget failures, cancellation/settings changes, both horizons, saved reload and failure UI before platform gates.

Focused evidence: `all-results-ranking-focused` executed 142 tests across five suites, all passed. The native mixed-action fixture verifies all four rows, six columns, captured Stop/Target values, missing-value dashes, finite layout, and progress during collection and comparison at 900/1200 points. `research-ranking-fairness-red` separately reproduced optional-citation starvation (10 passed, one failed); correction precedes final gates.

The first full iPhone gate passed 2,475 tests and failed the populated Research fixture: its injected scan had no comparator and therefore showed the honest comparison-unavailable state. The fixture now supplies an explicit synthetic comparison receipt and asserts it succeeded. The final iPhone gate `all-results-ios-final` executed 2,476 tests with no failures. Production source was unchanged by this fixture correction. The Mac gate is repeated to keep both source manifests identical.

Final frozen-source gates: `all-results-mac-final` passed 2,547 tests with one opt-in diagnostic skipped; `all-results-ios-final` passed 2,476 tests. Both exited zero with no failed tests. Source manifests are identical. Independent read-only review found no blocking UI, history or cancellation defect. Signed Release build and owner-app installation remain the final operational steps.
