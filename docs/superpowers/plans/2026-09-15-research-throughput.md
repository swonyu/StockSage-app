# Research Throughput Implementation Plan

**Goal:** Reduce full-scan elapsed time without reducing coverage or weakening evidence validation.

**Architecture:** Probe the selected runtime's loaded-instance capacity, then run up to eight structured stock workers, following the selected runtime’s verified count. Each worker owns its capture and its sequential horizon assessments. Existing ranking runs only after every child joins.

**Tech Stack:** Swift concurrency, existing Swift Testing/native gates, LM Studio MLX 1.11 and existing Qwen3.5 9B 6-bit weights. No new dependency.

## Constraints

- Keep all 500 checks, NASDAQ eligibility, deadlines, immutable captures and final comparison semantics.
- Parent owns orchestration, builds, app/runtime operations and integration; delegated file ownership is explicit.
- Do not stop or replace the owner app until a tested signed candidate is ready and the owner approves loss of unsaved checks.

## Implementation and evidence

- [x] `StockSageLocalModelServer.swift` / existing tests: add `Probe.researchParallelism` defaulting to one. Reuse compatible-row and loaded-instance validation; a unique selected instance with a finite integral positive `config.parallel` selects that many workers, capped at eight. Unknown, malformed, duplicate or incompatible metadata remains serial. Exercise real `probe` with injected inventory before implementation.
- [x] `StockSageHorizonResearch.swift` / existing tests: preserve existing injected `analyze` overloads as serial defaults and route them through a capture-owning per-stock analysis factory. Add a dynamic bounded worker count resolved after preflight. A continuation test must first fail because the second stock cannot begin while the first waits. Then use a structured task group capped at eight (two in the bounded-concurrency regression), refill on completion, and join before ranking.
- [x] Verify out-of-order completion keeps symbol/evidence identity, both horizons reuse only their own capture, every listing is checked once per horizon, limits never exceed the requested capacity or eight, first completed raw results survive stop, late results/settings changes cannot publish, and new scans cannot overlap canceled children. Preserve existing full-scan ranking/history checks.
- [x] `StockSageResearchModesPanel.swift` / native tests: show every active ticker as Checking, retain completed-verdict precedence and bounded finite progress layout. Preserve All checks, filters, sidebar and scenario columns.
- [ ] Run focused red/green tests, independent review, then full Mac and iPhone simulator gates serially on frozen source. Retain nonzero executed counts and source manifests; build signed Release from that source.
- [ ] At the approved update point, benchmark sequential versus two, four and eight concurrent requests on the same local model and matched synthetic research/schema, alternating order to limit cache bias. Require all accepted outputs and report observed times/throughput. Keep the fastest stable setting; reject settings that fail correctness or do not improve throughput; diagnose rather than claim success.
- [ ] Preserve all four saved-record folders and preferences, install the signature-matched app with rollback, apply only the measured selected-model default, start the authorized new scan and visibly verify concurrent progress and preserved saved research.

Baseline metadata is recorded in the task work directory as `live-scan-timing.json`. Canonical gate runner: `/Users/saleh/Documents/Codex/2026-09-14/cp/work/research-pipeline/run-native-gate.py mac|ios <unique-name> [suite ...]`. Source worktree remains `/Users/saleh/StockSage-wt/research-pipeline-20260915` at the latest verified local commit.

The scheduler re-reads capacity on stock completion. After a downloaded model JIT-loads, production refreshes capacity once after its first accepted configured-model response; earlier gather failures do not consume that refresh. The exact-capacity, capture-isolation, cancellation, and cold-start focused gate executed 91 tests successfully (`throughput-export`). The opt-in synthetic benchmark exported sixteen real gather/assess requests with 25 facts each and 6,787–7,313 normalized input bytes. These measure first-attempt model throughput, not full-scan/provider elapsed time. Native final gates run with benchmark opt-in disabled.

Final frozen-source gates: Mac 2,555 passed / 2 optional skips / zero failures, 230 suites; iOS 27 simulator 2,484 passed / 1 benchmark opt-in skip / zero failures, 227 suites. Both source manifests match all 390 app/test/project files. Xcode 26.6 / SDK 26.5 built the tests that executed on macOS 27 and iOS 27; this is not Xcode 27 SDK or physical-device validation. The signed Release build is pending; runtime benchmarking and owner-approved replacement remain pending.
