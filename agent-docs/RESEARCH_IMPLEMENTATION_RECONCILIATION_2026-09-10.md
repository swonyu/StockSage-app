# Approved research → current implementation

September 10, 2026. Baseline `661a1bba68b4a835aeacdf6de7d18d909b43016f`,
`codex/qwen-chat-context`. This is an implementation/evidence ledger, not a claim
of profitable trading, complete market coverage, or current provider entitlement.
Parent is the only repository writer; four helpers inspect source and prepare
external candidate patches. No installed build or owner record is being replaced.

## Disposition

| Approved work | Current disposition / evidence boundary |
| --- | --- |
| Section 16 complete-history paper audit | Existing `StockSagePaperAudit` exports archive hashes, counts, exact bytes and missing-evidence disclosures. Reuse it; no second exporter. Prose decisions are not historical NBBO, causal IDs, component costs or portfolio returns. |
| Frozen prospective / walk-forward plans | Existing recorder, seal/check protocol and isolated tests implement the approved experiment. No new cohort, backfill, model tuning or strategy activation. Missing private fit files are now isolated in tests without changing the real digest check. |
| Day / short-horizon modes | Existing Day 101-candidate research loop and separate position monitor; manual 500-symbol 1–7 / 7–14 trading-day research-only scans. Scope and risk settings remain unchanged. |
| Qualified data / sessions / fills | Current native implementation retains distinct research, execution and NBBO age ceilings; pre/regular/after-hours and holiday/early-close rules; later-observation simulated fills, settlement and persistent protective exits. Offline checks are not live-market capacity or broker-fill certification. |
| Local Qwen / Chat | Existing local-only 4096-context Chat, whole-record offering and ID validation retained. This pass fixes evidence aging during inference and completed-cache model-settings round trips. Parsed IDs do not prove semantic truth or a trading edge. |
| Native navigation / Catalyst periods | Existing left sidebar and Today / This Week / This Month agenda retained. These views expose the observations the app holds, not a complete all-market event census. |
| Nine-product Massive/Benzinga evidence | Implemented from the approved `benzinga-evidence-design.md`: earnings, ratings, guidance, analyst insights, bull/bear cases, news, consensus and referenced analyst/firm metadata. Existing Massive credential and one bounded evidence owner; no direct Benzinga credential or EODHD reactivation. Synthetic checks are not live entitlement verification. |
| IBKR / Derayah readiness | Inspection only. Native paper and broker-paper formats/session policy are not interchangeable. Relay remains off; no account identity, permission, entitlement, real order or submission readiness inferred. |

## Verified defects addressed in this pass

- Daily-history transport, provider fallback and derived-cache publication now
  recheck cancellation/permission after suspension. No fallback continues a revoked request.
- Direct SEC Form 4 rejects conflicting P/S versus A/D flags, withholding the
  directional summary rather than publishing a misleading partial net.
- Full JSON backup reads checked committed journal, portfolio and watchlist
  sources before writing. Corrupt/wrong-type sources leave a previous backup intact;
  valid empty collections and decodable invalid closures remain exportable for recovery.
- Parent-app migration reports unreadable collections instead of empty/partial
  success. Tests use isolated suites, never the real parent-app preference domain.
- AI badge currency checks captured evidence age and model-settings revision;
  late inference/repair does not replace a prior record with expired evidence.
- The prospective recorder test suite uses temporary fit bytes plus the real
  digest check; changed bytes are still rejected. Production frozen code is untouched.
- Massive key edits and native web/offline policy edits carry opaque revisions.
  Unsampled revoke/restore round trips invalidate captured Benzinga research
  during transport or inference. The native connection action clears only cached
  401/402/403 outcomes, without clearing other evidence or throttling cooldowns.
- New product evidence is bounded by three admitted transports, a total 12-second
  deadline, one 20-row page, 2 MB native body cap and 500-entry memory-only cache.
  Cancellation, credentials, policy and dependent metadata all use the same owner.
- Chat, assessment, paper/manual research and Catalyst explanations use immutable
  product snapshots. Published, updated and checked timestamps remain separate;
  a shared news cutoff avoids dropping a boundary article merely because checks
  completed later. Analyst targets never replace quotes or satisfy intraday evidence.
- Prompt budgeting preserves all nine product statuses and omits only whole
  optional records, with counts. Oversize mandatory facts are rejected before
  model dispatch, not silently converted into undisclosed provider gaps.
- Existing details, Catalyst and Chat views show native evidence disclosures,
  separate availability states and retained source records. No new dashboard,
  trading worker, journal mutation or historical snapshot rewrite.

Backup source reads are sequential UserDefaults reads, not a new cross-process
transaction or a power-loss guarantee. External programs bypassing the in-app
settings setter cannot have an unsampled A→B→A change detected retrospectively.

## Final verification

Artifacts: `/Users/saleh/StockSage-reconcile-20260910.gNvfUH`.

- Research baseline: 46 definitions, seven missing-private-fit errors, reproduced
  in both Python environments. Corrected suite: 47 passed in the existing LightGBM
  runtime; plain system Python passes with two optional LightGBM tests skipped.
- Behavioral REDs: Qwen 48 definitions / 46 issues; backup 72 combined definitions /
  27 backup issues; history/SEC 48 combined definitions / 30 issues. Compiler success
  preceded these failures. All fixtures are synthetic, with transport injection.
- Combined GREEN: 96 definitions across five suites, zero issues, xcodebuild exit 0.
- Post-restart OS verified macOS27.0/26A428; selected command-line toolchain remains
  Xcode26.6/17F113. The owner's Xcode27 Beta remains open and unchanged.
- Benzinga integrated GREEN4: 157 tests, nine suites, zero issues, exit0. Real
  native body-cap/deadline boundary plus synthetic parser/client/consumer checks.
- Further behavioral RED3: 26 tests / three suites / 44 issues reproducing budget
  loss, unauthorized cache retention and unsampled native policy round trips.
- Native offscreen 360/760-point view fixtures rendered; narrow product status and
  multilingual evidence-card captures inspected. Not installed-app interaction proof.
- Final focused GREEN:164 tests/nine suites/0issues/exit0. Replaced a fixed-yield
  test wait with the existing bounded admission wait before full verification.
- Fresh Python research rerun:47 passed/2.473s/exit0 in the existing LightGBM runtime.
- Full Mac:2166 passed, one existing opt-in skip, zero failed;204 suites/71.047s.
  Runtime macOS27.0/26A428, Xcode26.6/17F113. Full iPhone17Pro(gate), iOS26.5/23F77:
  2111 passed, zero skipped/failed;203 suites/65.193s. Both xcodebuild exits0.
  Counts are test definitions, not expanded parameter runs.
- Strict Mac module emission61s, iPhone emission56s, full test-source typecheck91s;
  each exit0, aggregate macos=OK ios=OK tests=OK. Typechecking is not test execution.
- Prescribed exclusions unchanged: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Normal Mac gate
  skips opt-in process-death acceptance; it was not re-executed in this pass.
- 383 tracked/untracked source/build-input hashes, path inventories and the complete
  dirty diff remained unchanged throughout gates. Installed executable/dylib hashes
  are unchanged; simulator is Shutdown. Full runner overall exit0.
- Final scoped independent reviews found no remaining production blocker. Current
  candidate is in `/Users/saleh/StockSage-fixes-20260910.bFAFrT/derived-macos/Build/Products/Debug/StockSageX.app`.
  No installation, new commit/push, model start or owner record mutation.
- Exact receipts: `full-gates/` and `POST_RESTART_RESULT.md` in the artifact root;
  inspected native fixtures retained in `ui-checks/`. Existing nonfatal compiler
  warnings remain. No Xcode27 SDK or physical-iPhone verification claimed.

No new historical observations, prices, fills, profitability, live entitlement or
completed verification are fabricated to fill a research gap.
