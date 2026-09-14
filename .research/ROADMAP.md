# StockSage research roadmap

Updated: 2026-09-14T02:13:40.568045Z

Owner: Codex Astra; primary task 01a09652-9a4a-7260-82a6-e949fe0c3dbc.
Branch: codex/research-quality-fixes; no main merges.

Ledger completion: 10/27 (37.0%). Includes existing R17 idle-unload safeguard; APP-FRESHNESS is an additional finished changelog item. Status describes verified scope, not investment accuracy.

Private report-delivery details omitted.

Current checkpoint:346a7ce pushed; R26 documentation correction complete, executable Swift text unchanged, fresh macOS build passed8.941s. R27 at2e37fd8 passed2,481 unique native tests /2,836 executions /one existing skip /zero failures, but remains partial. Synthetic required-fact retention4/6 before to6/6 after across six context budgets. Last local Q5 GGUF replay returned0/6 usable answers before and after; this is not an accuracy or speed gain. GPU broker is released/logged out; all remote setup instances preserved. Next: R14 verified model profile/preflight, R05 exact target comparison and R07 semantic support. No full-universe research, training or main merge.

| Order | Item | Status | Acceptance criterion |
|---|---|---|---|
| 1 | R06 Align numeric prose, schema and Unicode rules | implemented | Use one consistent output contract; test ASCII/Arabic digits, F/W citations and numeric listing identifiers across providers. |
| 2 | R13 Detect degenerate output before retrying | implemented | Replay FPS and length failures; bound retries, detect repeated junk, change the corrective action and expose terminal failure. |
| 3 | R09 Provider-to-model-to-UI coverage receipt | implemented | Assign a scan ID and record each listing transition/failure so provider totals, 499 model symbols and 500 UI checks reconcile. |
| 4 | R10 Durable per-attempt prompt and response receipts | implemented | Save each bounded attempt with source/model/config identity, timing, exact prompt/answer, validator outcome and UI decision. |
| 5 | R01 Stock-specific news passage selection | implemented | Select passages by symbol/company before truncation; replay multi-company articles and retain supporting facts. |
| 6 | R02 Markup cleanup and cross-feed deduplication | implemented | Normalize markup without changing numbers; merge duplicate stories across feeds with retained source IDs and dates. |
| 7 | R04 Horizon-aligned event validation | implemented | Tag inside/outside/unknown horizon using a market calendar and as-of date; pass AMD and KR counterexamples. |
| 8 | R03 Explicit instrument identity and ETF applicability | implemented | Preserve instrument type from provider to facts; ETF cases must not invent corporate earnings or analyst consensus. |
| 9 | R08 Analyst action versus consensus typing | partial | Expose typed action/consensus/date/currency fields with missing-state semantics; validate target claims against the correct record. |
| 10 | R27 Measure missing facts and evidence coverage | partial | Track required fact presence, citation support and missing/unknown states per symbol; test that prompt reduction preserves decision evidence. |
| 11 | R05 Deterministic price and target comparisons | not_implemented | Compute comparisons from typed prices/currencies and reject contradictory direction claims; test split/currency/date cases. |
| 12 | R07 Claim-to-citation support validation | not_implemented | Map each claim to supporting fact spans and fail unsupported citations; replay AMD F18 versus selected F6/F19. |
| 13 | R11 Research calibration and abstention replay | partial | Build an independently reviewed replay set, measure abstention and supported claims, and calibrate on data separate from evaluation. |
| 14 | R18 Chronological 7–14 day outcome benchmark | partial | Freeze recommendations at decision time; evaluate after the holding window against matched baselines with costs, temporal splits and uncertainty. |
| 15 | R26 Correct stale architecture/memory comments | implemented | Update documentation to reference the exact artifact config and host; label architecture estimates separately from measured allocation. |
| 16 | R16 Context allocation, cache and concurrency benchmark | partial | Record actual context/cache allocation and prefill/decode rates; compare identical prompts, concurrency and quantization without evidence loss. |
| 17 | R14 Portable model capability profile | partial | Record artifact/tokenizer/template/schema/tool/context/lifecycle capabilities; contract-test each supported provider and model. |
| 18 | R22 Model and quantization bakeoff | unverified | Replay the same frozen research packets; record artifact/config/hardware, throughput, factual errors, abstention and outcome methodology. |
| 19 | R25 Durable checkpoint and resume | unverified | Interrupt a frozen run and resume without duplicate/omitted listings, stale evidence or duplicate decisions; retain a complete receipt. |
| 20 | R15 Verified remote LM Link routing and lifecycle | partial | Verify actual host/GPU/RAM, route identity and ownership of load/unload; support remote research only through an explicit tested profile. |
| 21 | R20 Point-in-time RAG corpus | unverified | Version passages and availability timestamps; retrieve only evidence available at the decision time and measure recall/support versus the existing packet. |
| 22 | R21 Reranker evaluation | unverified | Compare symbol-specific relevance and citation support on frozen packets, including latency and adverse cases before deployment. |
| 23 | R12 Bounded model tools and hybrid retrieval | not_implemented | Compare supplied evidence and a typed allowlisted tool loop under equal data/token budgets; cap calls/retries and save tool receipts. |
| 24 | R23 Speculative decoding or MTP benchmark | unverified | Verify runtime support and acceptance rate; compare end-to-end latency, memory, output equality/quality and draft-model overhead. |
| 25 | R19 LoRA / QLoRA with verified provenance | unverified | Only after a repeatable behavior deficit: document base revision, adapter hash, data/license/splits and hyperparameters; beat held-out baseline without leakage. |
| 26 | R24 Distillation / DPO / full fine-tuning decision | unverified | Require provenance-clean teacher/preferences data, held-out gains over harness fixes and LoRA, resource budget and a rollback artifact. |
| 27 | R17 Maintain automatic idle unload | implemented | After a completed/cancelled local run, verify TTL or explicit unload, no inference worker and no open weight files; scope GPU figures to whole-machine allocation. |

Coordination: .research/continuation-state.json is timestamped task ownership. Spark fallback stocksage-spark-fallback-continuation checks every 30 minutes and can take over only when main Codex capacity is exhausted and the primary task is not running. Preserve any live owner. Changelog monitor ACTIVE; app updater PAUSED. Updates and mail after major completed checkpoints. Keep report, roadmap and generated receipts unstaged.

## Typed analyst target checkpoint — 2026-09-14

R05 is implemented for typed analyst target comparisons and R08 target validation is complete. The contract is exact-record, revision, field, amount, currency, date, basis, and optional direction; it fails closed for contradictory or mismatched claims. R07 semantic claim-to-citation support remains open. Completion is now 12/27 (44.4%).

## Coordination checkpoint — 2026-09-14 01:08 UTC

Commit `41e893c` pushed and remote-ref equality verified; main unchanged. Spark helper/docs now committed; 18 tool regressions passed (11 ownership, 7 replay guards). Scheduled fallback ACTIVE; live ordinary usage still allowed so no takeover triggered. R08 remains prepared/unvalidated. Full benchmark values remain in the single HTML report; local load routing and context discrepancies are under investigation.

## Evidence coverage checkpoint — 2026-09-14T01:53:57.851187+00:00

Commit `2e37fd8` pushed; remote branch equals local HEAD and main unchanged. Full macOS gate: 2,481 unique passed / 2,836 executions / one existing skip / zero failures. New six-budget synthetic packing checkpoint retains all required facts 4/6 before → 6/6 after; 2K/3K retain 11/12 → 12/12. No model calls or investment-accuracy claim. R27 remains partial: reference presence is not semantic support, and broader consumer/failure receipt coverage remains open. Report r34 contains full values; email receipt saved. Zero local models, both remote setup instances preserved.

## Documentation checkpoint — 2026-09-14T02:13:40.568045Z

R26 completed from exact artifact config and host inspection; current model comments corrected, historical run documentation dated, estimates explicitly separate from allocation measurements. No executable change or claimed memory/speed gain. Commit346a7ce; fresh build passed8.941s. Completion10/27(37.0%). Report35 and verified Sent receipt include full values; no generated artifacts staged. R05 investigation confirmed a typed quote/record/field/basis contract is needed; no unsafe prose matching or unused helper was added. R14 supported settings research is ongoing.

## Status verification — 2026-09-14T02:16:27.426236Z

Local report36 refreshed only changed LM Studio logs and passed static validation. Benchmark values and10/27 completion unchanged from delivered report35. Live remote refs:fix branch346a7ce;main62d99cf unchanged. Broker available;StockSage logged out;zero local models andtwo remote setup instances preserved. R14 review: native inventory can verify artifact/instance/context but has no documented device identity; model.yaml thinking variable is template-dependent, not a verified OpenAI request switch. Avoid rejecting all unloaded JIT models or all reasoning-only retry candidates without a compatibility experiment. No new executable changes or inference in this status checkpoint.
