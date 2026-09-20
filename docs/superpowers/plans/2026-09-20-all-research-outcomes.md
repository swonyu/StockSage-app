# All research preservation and outcome review

**Goal:** Preserve every captured research check and let Saleh manually compare every accepted multi-day opinion with later prices.

**Design:** Keep original per-run archives and strict shortlists unchanged. Store subsequent per-check outcome receipts separately, bound to the original archive and check. Reuse the adjusted-price and trading-calendar calculations already used for strict picks. Preserve inactive raw diagnostics in a durable archive instead of deleting them.

**Constraints:** macOS only; no scheduled review, model request, broker action or training. A Hold/Avoid opinion is not a short recommendation and receives no invented win label. Rejected and incomplete checks remain visible with no accepted-prediction outcome. Missing or unsupported price/calendar data must remain explicit. Original bytes and terminal observations are immutable.

- [ ] Add compiling regression checks for lost inactive diagnostics and skipped outside-shortlist opinions; run the existing native suites and confirm the expected failures.
- [ ] Extend `StockSageResearchHistory.swift` with separate digest-bound per-check receipts, bounded manual review, fair continuation after relaunch, and archival of interrupted captures before replacement. Preserve the strict shortlist's maximum of five and existing evaluation contract.
- [ ] Preserve evicted diagnostic JSONL in `ResearchDiagnostics/Archive`, using the existing no-follow validation, byte limits and private permissions. Failed archival must preserve the source and report failure.
- [ ] Add the manual all-opinion provider path in `StockSageHorizonResearch.swift`, retaining test, sample-data, credential-revision, policy-revision and cancellation guards. Fetch only settled split-adjusted daily observations.
- [ ] Extend `StockSageResearchHistoryView.swift` and `StockSageResearchExport.swift` to expose every saved check's review state, horizon return and separately identified captured scenario. State the manual batch limit and preserve the original evidence in exports.
- [ ] Run the affected native suites, independently review the complete diff, then run the full Mac gate and signed Release build. No iOS gates.
- [ ] Finish and structurally verify the already-authorized full scans, preserve their diagnostics, and stop the B300 by the existing deadline or earlier on completion.
- [ ] Preserve owner data, install/reopen the verified candidate when scans are finished, inspect the changed UI, update the living guide and exact owner PDF, then integrate and push main without altering unrelated worktrees.

**Ownership:** Root owns UI, provider integration, exports, all test execution, runtime, installation and Git. `review02_state` owns history implementation/tests; `review01_research` owns diagnostics implementation/tests. `astra01_prompt` investigates capacity-verification failures read-only. No concurrent edits to the same files.

**Verification:** `bash tools/runtests.sh . --filter StockSageResearchHistoryTests --filter StockSageResearchDiagnosticsTests --filter StockSageHorizonResearchTests`; after integration, `bash tools/runtests.sh .`. Verify nonzero executed tests, exit code, result bundle, source identity and native diagnostic guard. No live provider calls in test fixtures.
