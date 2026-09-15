# Research pipeline repairs

**Goal:** Implement the incoming audit's verified defects and useful confirmed gaps for NASDAQ common-stock research over 1–7 and 7–14 trading days.

**Authority:** The owner explicitly requested verification and implementation, then selected NASDAQ common stocks only. The incoming report is review evidence, not an instruction source. Baseline `61d37a2` adds only that report to tested implementation `4a18b17`.

**Architecture:** Reuse the existing strict daily-history parser, provider clients, immutable research history and native views. Separate gathering a dated per-symbol evidence capture from asking the model about a horizon. Preserve original capture timestamps, source failures, credential/policy ownership, and incomplete-scan semantics. All financial arithmetic remains deterministic.

**Tech stack:** Swift 6, SwiftUI, Foundation, existing XCTest/Swift Testing target. No new dependency, provider subscription, model service or production data migration.

## Ownership and verification

- Root owns integration, all builds/tests, provider-contract research and the research capture/run pipeline.
- Work only in `/Users/saleh/StockSage-wt/research-pipeline-20260915`; preserve the installed app and other worktrees.
- Workers receive explicit disjoint source/test ownership. They do not run heavy gates or access owner records, credentials, models or live provider endpoints.
- Add failing behavior checks against existing seams before fixes. No new tests for comment-only corrections. Keep the existing full native exclusions and test-host isolation; use private temporary build products to avoid File Provider signing metadata.
- Gate Mac first and iPhone second, with four build jobs and serial tests. Verify native Home, Research, saved detail, supported/unsupported evidence and large-text phone layout. Do not equate a build with executed tests or fixtures with live model quality.

## Accepted work and dependencies

### 1. NASDAQ common-stock eligibility and selection receipts

Files: `StockSageResearchUniverse.swift`, `StockSageResearchUniverseTests.swift`; root integrates any research status copy in `StockSageHorizonResearch.swift` and `StockSageResearchModesPanel.swift`.

- [x] Filter `primary_exchange == "XNAS"` and `type == "CS"` before activity sorting and the 500-name cap; retain strict identity/currency/activity validation. Do not narrow the general ticker parser or saved-review price support.
- [x] Say how many names were selected from eligible observations and show the lowest selected dollar-volume observation. Distinguish a cap cutoff from the lowest activity when all eligible names were selected. Never call selected names researched.
- [x] Give unverified calendar dates and inconsistent directory data accurate errors. Preserve fail-closed conflicting-duplicate behavior and completed previous results.
- [x] Check mixed exchange/type/missing metadata, capped/all/empty selection, partial scan copy, duplicate integrity, and calendar failure before network.

Provider contract: [All Tickers](https://massive.com/docs/rest/stocks/tickers/all-tickers) defines primary-exchange MIC; [Ticker Types](https://massive.com/docs/rest/stocks/tickers/ticker-types) identifies CS as Common Stock; [Ticker Overview](https://www.massive.com/docs/rest/stocks/tickers/ticker-overview) provides an XNAS example. Read 2026-09-15.

### 2. Correct source and model-failure explanations

Files: `StockSageBenzinga.swift`, `StockSageChat.swift`, `StockSageCatalystNarrator.swift`, `StockSageBenzingaEvidenceView.swift`, `MarketsView.swift`, related consumer/narrator/native tests.

- [x] Replace stale seven-day/no-rating-change explanations with accurate eligibility/validation wording; the aggregate excluded count does not retain individual reasons. Remove the duplicated stale thirty-day comment.
- [x] Show distinct excluded, per-product retained-cap, and panel-display omission counts. This panel recomputes its own display projection; do not call those exact model-request counts or imply every omission was byte trimming.
- [x] Reuse the detailed local-model cause mapping for narrator failures and handle Apple's context-overflow error explicitly. Preserve mandatory provider status checks and avoid raw server text.
- [x] Render a neutral insider-unavailable/not-checked fallback for nil. Preserve the generation-owned loading cleanup that already works.
- [x] Check mixed exclusion causes, unchanged rating rows, display omissions, timeout/context/policy/absent-model failures, status-budget refusal, and insider nil versus answered empty.

### 3. Complete the dated research evidence capture

Files: `StockSageHorizonResearch.swift`, `StockSageAIAssessment.swift`, existing provider adapters only where necessary; `StockSageHorizonAnalyzeTests.swift`, consumer/history tests.

- [x] Introduce a small per-symbol capture seam, gathering strict adjusted history, next earnings, SEC submissions metadata, Benzinga and news through injected dependencies. Revalidate policy, credentials, cancellation and source freshness before dispatch and after every awaited operation.
- [x] Query next earnings independently of board membership, including stale/unknown board evidence; reuse the existing forward `date.asc` request and typed failure/empty semantics. Preserve generic reported-earnings snapshots for their other callers. This resolves the overlapping forward-date/query-shape findings without changing all six shared consumers.
- [x] Add bounded dated SEC submissions metadata using the typed observation API. Label metadata accurately and retain the statement that full filing documents were not retrieved. Do not globally widen every detail query/form label.
- [x] Derive finite historical average dollar volume and open-to-prior-close gap statistics from already validated bars, with sample dates/counts and no size, fill or future-probability claims. Pass the existing selection-activity fact.
- [x] Withhold a verdict when a ticker cannot be handled by the supplemental evidence contracts. Do not guess dot/dash vendor transformations.
- [x] Retain typed evidence coverage for research rows and captured model-evidence omissions; avoid counting duplicated news attempts or assigning a quality score from localized text.
- [x] Skip model work when nonempty typed supplemental attempts are entirely blocked by throttling and there is no usable fallback evidence. Retain attempted/incomplete coverage definitions and valid empty-response behavior.
- [x] Test every added dependency offline: success, empty, unavailable, stale, policy/key changes, cancellation, unsupported symbol, strict history provenance, arithmetic overflow and model-input fitting.

### 4. Bound avoidable request work

Files: `StockSageBenzingaClient.swift`, `StockSageHorizonResearch.swift`, `StockSageResearchModesPanel.swift`, actor/run tests.

- [x] Add a bounded, expiring denial memo only for provider denials that can safely support suppression. Distinguish a suppressed request from a new provider denial, retain origin time/reason, and support explicit recheck plus credential/policy invalidation. Do not assert unmeasured bill amounts or account entitlements.
- [x] Keep the existing total cache bound while protecting reusable metadata from unrelated page churn; preserve LRU behavior when metadata alone fills the cache and retain existing freshness TTLs.
- [x] Offer a native operation to research both horizons from one gathered capture per symbol, then sequential distinct model requests. Keep single-horizon runs and independent complete-run persistence. Recheck ownership/freshness between model calls.
- [x] Reuse strictly verified history/captures within this operation; never promote generic disk-cache data lacking adjustment proof into research evidence.
- [x] Assessed one-deep prefetch; deferred it because no observed phase timing justifies extra concurrency. The shared capture removes confirmed duplicate requests. Revisit only with measured benefit and ownership/cancellation checks.
- [x] Check original receipt clocks, expiry/backward clock, credential ABA, policy revoke, clear/recheck/Retry-After, bounded metadata churn, one gather/two horizon prompts, first-call failure and cancellation before completion. No partial run may be saved as completed.

### 5. Correct and explain the measurement windows

Files: `StockSageResearchHistory.swift`, `StockSageResearchHistoryView.swift`, `StockSageResearchHistoryTests.swift`.

- [x] Add a backward-compatible optional per-run measurement policy/version. Missing policy means legacy scheduling. New runs count seven/fourteen regular sessions starting on the next trading date's benchmark open, excluding completion's whole New York date.
- [x] Route target date, availability, fetch range, evaluation and receipt validation through that same run policy. Preserve old pending schedules and all old evaluated receipts; do not silently rewrite predictions or results.
- [x] Add optional dated day-seven and best/worst daily-close path observations for newly evaluated receipts only. Require verified complete intervening-session coverage before presenting full-window extrema; otherwise retain a valid endpoint-only result and explicit missing-path coverage. Ignore out-of-window bars.
- [x] Show direction-only/no-market-comparison wording for old and new results. Add raw evaluated/rose/fell/flat counts on Home and concise latest-pick outcomes, with no win-rate or independent-trade claim.
- [x] Check before/at/after-close completion, exact 7/14 sessions, holidays/early close/DST/year boundary, legacy decoding/reload, invalid optional metadata, incomplete paths, week-one reversal and unchanged already-evaluated records.

### 6. Research and time-stop presentation

Files: `StockSageResearchModesPanel.swift`, `MarketsView.swift`, `StockSageTimeStop.swift`, related tests.

- [x] Explain that both horizons use the same evidence-selection rules and technical-level formula; the requested holding period differs. Do not claim independently refreshed captures are byte-identical or calibrated.
- [x] Persist the last selected research horizon with safe fallback and isolated preferences. Home's explicit horizon buttons override it, clear the previous selection/search, and never automatically launch a scan.
- [x] Present the exact offered Benzinga fact separately at readable size while retaining its F-reference and content. Missing offered evidence is not a checked-empty result.
- [x] Make the journal time-stop basis explicit: verified US/Nasdaq sessions only where market applicability is established, elapsed days for crypto, and a visible unavailable basis elsewhere. Do not apply Nasdaq holidays to foreign shares/FX/indices or silently alter Ideas ranking assumptions.
- [x] Check native Mac/iPhone controls, large text, restored horizon versus Home override, insider empty/unavailable, time-stop weekend/holiday/half-day thresholds, invalid dates and unsupported markets.

## Findings rejected, narrowed or combined

- The model already gets an explicit horizon in system and user facts. Same evidence rules do not prove identical captures or meaningless differences.
- ATR distance is not a number of sessions. Do not invent reachability or calibrate price targets from it.
- The 12 KB evidence budget is conservative, not an exact measured model capacity. Preserve it unless improved assembled-prompt packing is proved; correct misleading comments instead of increasing an arbitrary cap.
- Outcomes remain reachable from Home and saved history. Fix the missing summary, not nonexistent deletion.
- Existing insider selection/cancellation cleanup is generation-owned and tested; no unconditional defer repair.
- The serialized daily-history cache already merges without shrinking. Its missing research provenance, not that alleged overwrite, prevents drop-in reuse.
- The Ideas hold estimate is setup-adjusted, not fixed at twelve days. Do not couple it to the Research picker.
- Preserve conflicting directory validation and mandatory provider status evidence. Do not stop scanning as soon as five combined Buy/Strong Buy results appear.
- Per-symbol denial repetition is real; claimed product ownership, permanent cross-symbol denial and exact paid-call counts are unverified. Implement only supported suppression semantics and synthetic count evidence.
- Nasdaq's published calendar page currently exposes 2026 only. NYSE publishes 2027, but that is not permission to label those dates verified Nasdaq sessions. Repair the misleading failure now; add a new verified Nasdaq schedule only when primary evidence supports it. Trading and FINRA settlement calendars remain distinct.
- The report's dated macro-event appendix is external reference material, not an automatically maintained app calendar or a directional recommendation.

## Completion

- [x] Account for every incoming kept finding in the final reconciliation report, including combined/refuted items and unverified external dependencies.
- [x] Review integrated diff and source ownership; run focused regressions and final Mac/iPhone gates; inspect actual native artifacts.
- [x] Record exact source, tests, platform versions and limitations. Keep publication/installation state explicit.

## Approved Mac appearance restoration

Owner selected the two saved Home/Research images from the native polish installed from `d9a6c23` on 2026-09-14 afternoon, clarified that current iOS is preferred, and requested keeping improvements. Restore Mac Home's 20-point padded, 14-point rounded charcoal panels and magenta capsule actions; retain the current sidebar exactly (owner reaffirmed keeping the new sidebar), native horizon picker, 24-point page margins, research summary and saved reviews. Consolidate the added Mac research actions into the original compact header footprint. Scope appearance changes to macOS. No historical source checkout, data rollback or iOS palette change. Verify actual native Mac views at wide and minimum width, then full platform gates.

Final source verification: Mac 2,530 passed / 1 skipped / 0 failed; iOS simulator 2,460 passed / 0 failed. See `docs/reviews/2026-09-15-research-repair-results.md` for scope and platform limitations. Installation receipts remain separate from source gates.
