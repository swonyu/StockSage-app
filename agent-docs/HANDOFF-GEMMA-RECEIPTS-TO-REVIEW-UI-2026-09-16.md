# Tested Gemma receipts for Claude review UI — 2026-09-16

Owner-directed split: Codex owns Gemma/backend; Claude owns review UI in `claude/review-ui-20260916`. This checkpoint is based on `1239c6cf5a5acbb8fbdc5edb7f752bc3c7d290bd`. No app installation, push, merge, prompt change or sampling change is part of this handoff.

## Completed

- `StockSageAIAssessment.InferenceProfile` records requested model/prompt/schema/packet identity, temperature, context, initial/reserved output limits, endpoint category and retry reason. Seed and top-p remain nil because the server owns them. Comparable cohort does not promise deterministic output.
- Actual accepted/rejected assessments publish the existing shadow `QualityReport`, preserving original model opinions and recording the facts actually offered. Pre-model data failures remain data unavailable.
- Fresh insider extraction uses the evidence context's completed timestamp instead of the earlier scan-start timestamp. Rejected/interrupted opinions still retain original insider source evidence and offered fact classes.
- New `Prediction` and `CompletedCheck` records retain optional `inferenceProfile`, `qualityReport`, `evidenceReceipt`, `qualification`, fact classes and full `insiderEvidence` (`StockSageMassiveEvents.Observation`) plus `insiderCoverage`.
- `Prediction.hasRecordedInsiderEvidence` distinguishes absent historical metadata. Use `insiderEvidence.insiderEvents` or its legacy `event` for original IDs, links and optional typed `event.insider` purchase/sale details. `CompletedCheck.hasRecordedInsiderTransactions` separately preserves legacy key presence, including round trips through Result.
- `completedScan(runID:)` returns only the exact retained run. It returns nil when that run's detailed checkpoint has been replaced; old predictions retain their own source evidence.
- Saved source outcome/status, first-event/list identity and omission pairing are checked. Prediction evidence/qualification and inference-profile packet identity use the same validation boundaries as completed checks. Ranking v3 is accepted by the existing history validator.

## UI semantics

`qualityReport.classCounts` counts fitted, actually offered facts. `evidenceReceipt.classCounts` counts the original captured packet before fitting. `facts.count == evidenceReceipt.offeredKeys.count` on the actual request path; original packet counts need not equal either count.

Insider evidence must be prominent. Show transactions, roles, dates, links, source status and omitted-record counts. Preserve plan disclosures without inferring motive. An answered empty P/S query means no qualifying purchases/sales returned in that queried window, never "no insider activity." A legacy untyped event is still recorded evidence. Missing archived metadata is not an empty confirmed query. Do not call uncited facts counterevidence.

Do not backfill nil historical Prediction fields from a different record. The exact matching completed check can be separately labeled original capture provenance. Shadow verified/unverified are evidence-output checks, not a calibrated probability or proof that a stock strategy works.

## Verification

Native macOS: 246 passed, 0 failed, 2 skipped (248 total), seven suites.
- Result: `/Users/saleh/Documents/Codex/2026-09-16/t/work/gemma-integrity-green.xcresult`
- Summary: `/Users/saleh/Documents/Codex/2026-09-16/t/work/gemma-integrity-green-summary.json`

Native iOS 27 simulator `CC923127-11DD-4234-A379-457A667E9D4F`: 246 passed, 0 failed, 2 skipped (248 total), same suites.
- Result: `/var/folders/b1/tvm3jn711kq48mcrc1skxdn80000gn/T/stocksage-gemma-ios.zha9v9jx/result.xcresult`
- Summary: `/Users/saleh/Documents/Codex/2026-09-16/t/work/gemma-ios-temp-summary.json`
- First iOS attempt under Documents failed in widget CodeSign before tests because generated files received FinderInfo/file-provider metadata. Temporary derived data resolved it; source/signing settings unchanged.

Suites: HorizonAnalyze, ResearchHistory, AIAssessment, LocalModelServer, RunPodGemma, ResearchDiagnostics, ResearchRanking. Skipped opt-in tests: syntheticThroughputPayloadExportAndValidation and validateSuppliedRecoveryCheckpoint. These are focused executed tests, not the full release gate.

The source/status and saved-prediction consistency tests first failed with seven assertions, then passed after the shared validation fix. Independent final read-only review found no remaining correctness blockers. `git diff --check` passed.

## Next owner

Claude may integrate this commit into its UI branch and proceed with Tasks 6/23. Codex releases the heavy-build/test lease with its explicit handoff message. Claude remains sole UI writer; avoid backend schema edits or broad agent fan-out. Retain the owner's 10:00 GMT+3 daily-delivery requirement; the existing Codex heartbeat prepares at 06:00 and delivers at 10:00, while Mac/Codex are awake. A fresh scheduled delivery and the new UI remain unverified. Walk-forward benchmark and speed adoption remain unfinished separate plan work; this receipt makes no accuracy or speed-improvement claim.
