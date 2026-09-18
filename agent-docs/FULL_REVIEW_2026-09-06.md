# StockSage source, history and architecture review

Date: 2026-09-06. Reviewed source: **5bb544d**, integration branch
`review-followups-2026-09-06`. This is a frozen-source review, not a description
of every change concurrently landing on `wt/coverage`.

Status: **static source/test and exported-history review complete:** all 123
application/widget Swift files, all 167 test/support files, and the available
top-level conversation text described below. A bounded saved-model metadata check
is also complete, with readiness unproven as detailed below. Findings are not
implemented fixes. Do not
read this report's existence, a proposed test, or a historical PASS as shipping
evidence. No real trades, model jobs, app builds or pushes were performed here.

## Outcome

StockSage has substantial reusable analysis, risk, journaling, paper-trading,
market-data and narration code. It does **not** yet provide the requested Chat
conversation or verified Derayah execution at this reviewed revision. Several
integration defects make existing freshness, sizing, calibration and paper-result
claims unreliable on identifiable inputs. Connecting a broker or a larger model
without resolving those boundaries would carry those errors forward.

The goal remains real BUY/SELL/CANCEL/MODIFY, proactive information and Chat,
including owner-enabled policy-authorized automation. It is not being replaced
by permanent manual-only tickets. Massive Advanced is already purchased;
Benzinga Earnings was selected, Ratings and Corporate Guidance were confirmed
purchased. Other extras require an entitlement inventory, not another purchase.

The owner's 5% weekly **total-portfolio** aspiration is recorded, not validated
as a repeatable return. It is not a reason to increase risk, force trades, hide
unrealized losses, or count deposits as profits. A correct assistant fine-tune,
a passing broker sandbox and a profitable strategy require different evidence.

The corrected implementation contract is
[V3 architecture](CHAT_DERAYAH_ARCHITECTURE_2026-09-06.md). Pipelines4/5 now have a
separate Codex takeover task, `01a07765-5906-7100-907d-891c144c58b1`; this review
must not start duplicate writers or restart historical workflows.

## What was actually examined

- Frozen Git archive of5bb544d, independent of the live dirty checkout.
- UI reviewer: all24 assigned source/config files, including all10,093 lines of
  MarketsView;25 complete test/support files and identified dependencies.
- Network reviewer:29 complete source files and43 complete tests. Overlaps with
  the UI/engine reviewers are deduplicated in the aggregate.
- Engine reviewer: all75 assigned engine files and109 complete test/support
  files (31,056 lines combined).
- Mechanical union of the three full-read inventories: **123/123 Swift source
  files** under `StockSage/Sources` and `StockSageWidget`; **ification.
- Main read both test/build scripts, project/scheme/plists/entitlements, README,
  .gitignore, XcodeCloud manifest and HANDOFF. 167/167 Swift test
  files**, zero remaining. Full read is static
  understanding of the redacted representation, not dynamic verAlso the entire492-line historical
  AUTOTRADER draft and73-line iOS review. The other9 historical agent-documents
  were fully read by the document reviewer (5,213 lines), including the entire
  3,062-line July28 review.
-17 top-level Claude session snapshots exported2,584 user/assistant text records,
  3,417,532 text characters, with0 JSON parse-error lines. Exact duplicate text
  is accounted separately, not reread as independent evidence.
- All32 deduplicated ordinary-dialogue batches are read. The long July2–5 d87
  session is complete:1,037 distinct records read,178 duplicate occurrences
  accounted,1,215 total; final source line8879. All31 embedded worker-report
  batches and all23 context batches are also complete.
- This does **not** mean all raw tool calls, all563 nested worker logs, images,
  screenshots, or source-truncated notification text were read. It is the
  available top-level conversation text, with explicit limits. Live sessions
  may have additional text after the snapshot.

Review inputs and detailed call-path/test inventories are in
`/private/tmp/stocksage-review-20260906.i7mcHD/`: `ui-review.md`,
`network-review.md`, `math-review.md`, `tooling-review.md`, the history reports,
`history-inventory.json`, and `reading/manifest.json`. Private scratch files are
not a portable release artifact; the important findings are retained below.
Redaction is heuristic and is not proof that a dataset is secret-free.

## Findings to address before relying on broker-ready decisions

Priorities refer to the stated reachable input/path. P1 means material data,
risk, privacy or accounting correctness; it does not mean an observed live loss.
Most witnesses are static counterexamples, not executed application tests.

### 1. One quote can have several competing versions — P1

`StockSageStore.swift:2111,2131,2455,2510,2624` accepts ticks, polls, targeted
refreshes and full refreshes without a common per-symbol time-order rule.
A delayed REST response or later scan chunk can replace a newer price. A stream
tick with no market timestamp is assigned `Date()`, manufacturing freshness.
Some paths require an existing board row, so portfolio/journal-only tracked
symbols can be subscribed successfully while their updates are discarded.

Use one accepted-observation merge rule for every ingestion path, retaining
instrument/provider, actual market time, receipt time, correction identity,
coverage and missing-data status. Analysis publication must not overwrite newer
quote state. Test reverse arrival, tick-versus-REST, off-board holdings, partial
coverage, nil/future timestamps, session rollover and reconnect. A correction
message is a separate policy case, not automatically an ordinary newer trade.
Source findings N03–N06; these requirements also apply to the Massive migration.

### 2. Thin-sample probability can exceed its promised prior ceiling — P1

`StockSageConvictionCalibration.swift:95,116,703,717` clamps a thin fallback at
bin midpoints but answers queries with a constant bin value. With30 alternating
outcomes, conviction0.50 selects midpoint0.75 and yields0.5225 versus the prior
at the query of0.465. Under a2:1 payoff scenario this raises EV from0.395R to
0.5675R without validation. Arithmetic and branches were checked; the complete
calibration API was not executed in this review.

The correction belongs at the fallback query/envelope, preserving provenance.
Do not indiscriminately clamp a separately validated empirical map. Test both
sides of every bin edge for thin sample sizes. The old July approval resolved
the intended policy, not this missed discretization case. Finding M1.

### 3. Claimed out-of-sample calibration can use future outcomes — P1

`StockSageConvictionCalibration.swift:575,783,823,851` sorts trades then drops
their timing information and skips a fixed record count. A training trade
opened earlier but closed after a test prediction can supply its future result.
Close-date ordering alone also does not establish when a test trade was opened.

Carry prediction and label-availability times through the split; purge outcomes
unavailable at each validation cutoff, keeping simultaneous date groups together.
Test overlapping positions across symbols. This concerns calibration selection,
not an allegation that the base backtest's next-open entry reads future bars.
Finding M2. Open-at-end marks and inconsistent journal closure states also enter
fits as realized labels (`:792,807`); separate finalized and censored outcomes
and enforce coherent closure at import/restore/add boundaries. Finding M3.

### 4. Net EV/day can exceed gross because the horizons differ — P1

`StockSageExpectedValue.swift:193,321,470` applies hold-time inflation to gross
velocity but not net. A source-derived example has0.74R gross,0.727R net,
10-day hold and1.5 inflation: gross0.04933R/day versus net0.0727R/day. Positive
costs did not improve the opportunity; inconsistent denominators did. Existing
net≤gross tests use empty sparks, where this inflation is1.

Reuse one horizon in net/gross ranking and same-basket weekly presentation.
Test erratic sparks, zero-cost equality and nonnegative-cost monotonicity.
The particular hold-time approximation still needs separate economic validation.
Finding M4; source table13bps is an assumption, not a verified broker fee.

### 5. A sized plan can be CLEAR despite failing sized costs — P1

`StockSageDecisionSnapshot.swift:193,218,247` computes the gate/EV before sizing,
then adds a costFails reason after minimum fees without updating those values.
A synthetic one-share EUR example gives unsized netRR2.846 but sized netRR0.282
and EV−1R under the current cost table. The same decision can display incompatible
conclusions. `StockSageTodayPlan` then ranks by that stale gate.

Compute one quantity/FX/fee-aware cost result and derive every gate, ratio, EV,
rank and export from it. Revalidate after any input change. Finding M8.

### 6. Missing FX becomes one-for-one sizing — P1

`StockSagePositionSizer.swift:71,85` collapses USD and unknown foreign conversion
into the same nil fallback. A synthetic EURUSD2 fixture with aUSD10,000 account
and1% risk produces10 rather than5 shares when FX is absent: twice the intended
USD risk. Other rates cause undersizing instead; neither is a correct known risk.

Represent USD explicitly as1 and missing/invalid foreign FX as unevaluable,
including rate as-of and minor units. Existing tests intentionally preserve the
compatibility fallback; they must change with the contract rather than be treated
as proof the monetary claim is correct. UI fallback paths have the same issue.
Finding M9 and UI FX follow-up.

### 7. An unwired allocation helper violates its group cap — P2

`StockSageCapitalAllocator.swift:365,405,430` first caps new-idea book weight,
then redistributes a held-name concentration excess into those same new names.
One held name and five new names can end at80% new weight after initially
enforcing10%. Here the variable maxHeat serves a new-book/churn constraint,
not measured aggregate stop-loss heat; those concepts must not be conflated.

**Reachability correction:** production-source caller search finds no invocation
of `rebalanceToEdge`. The shipped MarketsView rebalance uses `store.riskParity`
and `StockSageRebalance.plan`, not this helper. This is a retained/tested helper
defect and a hazard before future wiring, **not an established current UI
allocation breach**. Its initial P1 classification was too broad and is corrected.

Enforce all final constraints together, preserving cash or reporting infeasibility.
Test the simultaneous group/name-cap case, not each constraint separately.
Do not change the separate shipped rebalance path based on this witness. M7.

### 8. Paper corporate-action handling can corrupt reported results — P1

`StockSagePaperTrader.swift:75–141,304` loses still-open rebased records between
marking and persistence: only closes/new opens survive the step result. A split
can leave stored entry100 marked at50 and show−5R instead of a rebased0R.
Separately, if the supplied history starts after entry, the first future bar is
used as an entry basis. A real adverse gap100→50 can be inferred as a split and
move the stop90→45, hiding that loss in the simulation.

Require a real entry basis and corporate-action/adjustment evidence; missing
history is unknown. Persist legitimate open-record updates by ID. Merely
persisting the present heuristic would make its false corrections durable.
Test both genuine splits and no-split truncated-history gaps. Findings M5/M6.

### 9. HTTP200 is not an authoritative no-earnings answer — P1

`StockSageEarnings.swift:117,126,171`, `StockSageEODHDCalendar.swift:49,106` and
`StockSageStore.swift:1933` conflate malformed payloads with valid empty results.
An error envelope/schema drift can erase a known date and suppress rechecking.
Model valid-empty, unavailable and malformed separately; preserve last-known
evidence with degraded status. Test the transport→parser→record chain. N09.

The non-US projection path additionally labels fiscal quarter-end extrapolation
as expected earnings, without a reporting lag. A projected period boundary is
not an announcement estimate. Preserve event semantics and date ranges. N11.

### 10. Insider fields can be attached to the wrong transaction — P1

`StockSageInsider.swift:111,121` extracts optional XML fields into separate arrays,
then joins by position. If transactionA omits price/date, it can inherit B's
values. Parse transaction nodes as records and retain filing/owner/table identity.
Test two transactions with asymmetric missing fields. The proposed full parser
runtime check was blocked before execution; this is a source-derived witness.
N12. Also avoid caching transient CIK lookup failure for the entire process,
and replace the separate unsynchronized map's data-race exposure. N20.

### 11. Offline policy and credential boundaries are incomplete — P1

`StockSageLiveStream.swift:151,218,281`, local model probes/completion and the
calendar availability probe bypass the global external-access policy. A warning
that facts may leave the device is not enforcement of Offline Mode. Gate initial
requests, retries/reconnects and work after awaits; cancel remote work on revocation.
Define the intentional loopback exception separately. N02.

`StockSageEODHD.swift:25` contains an embedded account credential fallback.
Its current validity was not tested. An override does not remove the bundled
literal. A tracked old source archive `.review-tmp/src.tar.gz` includes an EODHD
source entry; contents were not extracted, so a duplicate secret there remains
possible, not verified. Revocation/rotation is separate from source cleanup.
No credential values belong in logs, prompts, reports, or commits. N01/tooling.

### 12. Detail rendering owns the wrong asynchronous work — P2

`MarketsView.swift:5521,5702,9357` puts targeted quote/SEC fetching inside card
metrics only when priceAsOf is missing. Card rendering can assign selectedIdea,
while normal timestamped detail sheets never run that refresh. The sheet holds
a value copy; ticks update the board but not that selection. SEC results are
unkeyed and can be shown for a different symbol after an out-of-order completion.

Own these effects at the selected-detail boundary, key results by symbol/version,
guard completion identity, and choose an explicit live-versus-frozen price policy.
Rendering a list card must not navigate. UI02.

## Other source-backed findings and required regression checks

These remain real work; grouping them here does not mean they were fixed or
excluded from the full review. References identify the reviewed source revision.

| Finding | Evidence / smallest useful regression |
|---|---|
| Personal Watchlist rejects curated names | MarketsView4135→Store542 rejects universe membership; Browse marks them tracked. Favorite AAPL without duplicating the universe. UI01 |
| Custom removal is not durable | Store574/cache load403 and canceled scan714 retain/resurrect rows or ideas. Remove→relaunch offline and remove→partial-scan→cancel. N07/N16 |
| Cache saves pre-heal state | Store2607,2639,2660 serializes the captured pre-await array. Poll→heal→save→reload must retain the accepted final quote. N08 |
| Targeted refresh loses new-listing metadata | Store2500/2510 omits the reconciliation used elsewhere. Test flag set and clear alongside accepted quote ordering. N21 |
| Wrong source labels / lost date ranges | Idea source hardcodedYahoo at MarketsView9642; CatalystWatch282 and brief construction omit real source/range. Preserve provenance end-to-end. N10/UI08 |
| Numeric fence is not semantic grounding | CatalystNarrator177,199,209 allows swapped values/signs/units and unsupported word-only claims. Source text can contain instructions. Use typed source-bound facts and deterministic monetary rendering. N13 |
| Narration expires independently of its facts | CatalystsSection513 caches by symbol only. Old explanation must not appear under a changed plan, date or model configuration. N14/UI14 |
| Cancel leaves detached analysis running | Store600,885,1138; QuoteService202. Test parent, explicit and watchdog cancellation through the real task tree. N15 |
| Failed watchlist alert enqueue consumes dedupe | Monitor263–278 differs from the core path. First mocked send false, second true must retry when policy permits. N17 |
| Deleted/muted alert can fire after an await | Monitor298–340 captures old armed state. Recheck ID/version/preferences before enqueue. N18 |
| Hysteresis differs after restart | NotificationBudget62 prunes cooldown records while95 retains hysteresis in memory. Compare fresh versus continuing instance at31minutes. N19 |
| iOS monitor opt-out is not durable | App82 starts on foreground despite view toggle stop. Persist desired state separately from actual running state. UI04 |
| Full restore applies only trades | MarketsView2751/2813 ignores restored holdings/favorites while wording says ALL. Test restore into actual isolated stores, not codec roundtrip only. UI03 |
| CSV interchange rejects CRLF/exponents | JournalCSVImport136 treats Swift Character CRLF incorrectly; export String(Double) may produce1e-06 rejected by human-input parser. Standard-library witnesses executed; import API not executed. M10 |
| CSV dedupe misses repeated rows in one batch | JournalCSVImport36 compares only existing journal. Maintain an accepted-row seen set. It is not a lossless backup schema. M10 follow-up |
| Cross-instance deletions resurrect | Portfolio47/66,Journal1010/1032,PaperTrader318/338 merge stale arrays without tombstones. Two isolated instances: delete then append must not revive deleted records. M11 |
| Optional Kelly costs omit the losing outcome | Kelly73 subtracts roundtrip costs from wins but leaves losses at−1R. A synthetic p0.4/reward2R/cost0.25R gives true net EV−0.05R while the helper permits a positive stake. Non-nil-cost production use was not established; this is a helper contract defect, not a claim about the default live sizing path. M12 |
| Monte Carlo runs during Portfolio rendering | MarketsView2966 invokes10,000×100 simulation steps; cache relevant journal/risk inputs outside body. No measured hitch duration claimed. UI05 |
| Widget labels paper risk as account risk | MarketsView6559 uses paper positions and raw mixed currencies; real widget102 lacks paper qualifier. Select/label the right book and convert units. UI06 |
| Widget fresh timestamp hides old inputs | Snapshot stampsDate without price/analysis age or completeness, only updated on ideasUpdated. Test fresh publication of a five-day-old quote. UI07 |
| VoiceOver gives different strength semantics | MarketsView4448 still says a percentage while visible4382 says ordinal4/5. Share visible/spoken rules-based representation. UI09 |
| Phone close form exceeds available width | MarketsView3687 minimum fields/gaps exceed375-point content before button; runtime layout not captured. Test compact/accessibility sizes. UI10 |
| Navigation swipe covers horizontal scrollers | MarketsView995 simultaneous drag also covers Ideas/Catalyst strips. Verify gesture ownership on-device. UI11 |
| Invalid optional target silently becomes nil | MarketsView3519/3551: nonblank invalid target skips validation. Blank allowed; malformed nonblank rejected. UI12 |
| Executable-only includes unknown size | TodayActionsCard192 only rejects present zero; nil survives clear/caution gate. Require known positive size, not just a discipline badge. UI13 |
| Live ticks trigger success haptics | MarketsView566 watches lastUpdated, which Store2146 changes per stream flush. Test no success haptic for background ticks. UI15 |
| Menu ticker setting has no scene consumer | Settings46 persists a switch while App97 parks MenuBarExtra. Hide/label unavailable rather than silently resurrect parked code. UI16 |
| Test runner masks failure | tools/runtests.sh44–45 prints runner7 then returns wrapper0. Exact-tail shell reproduction executed; fix saved status and final exit. T1 |
| Invalid gate mode passes with all stages skipped | tools/gate.sh accepts typo, exits0 and SKIP/SKIP/SKIP. Actual script invoked with invalid mode, no build. Validate modes. T2 |
| Test output/storage isolation is weak | runtests uses repo basename and persistent shared test-home/cache paths. head80 can terminate log consumption. Concurrent isolation and full-log checks needed. T3 |
| A stale test opt-in can write real calibration | CalibrationPersistRunTests18 checks a fixed global sentinel, then fetches and saves to the default preferences domain. A broad suite can therefore perform network/state-changing work if that file remains. Isolate measurement jobs and persistence; neither sentinel state nor the test was exercised here. Math test-reading T1 |
| Process-global test flags can leak between suites | BacktestParityTests230 mutates relativeStrengthEnabled without the lock pattern used for TOM. Synchronous test bodies do not establish cross-suite isolation. Static hazard, not a reproduced flake. |

## Economic evidence is still separate from engineering correctness

- A source-provided probability of any positive exit is not necessarily the
  probability of attaining the entire target. Time exits/gaps break the simple
  two-outcome payoff interpretation. Treat EV as a scenario until the event,
  horizon and conditional net payoffs are validated.
- StrategyBacktest's trial count describes strategy variants, but its
  varTrialSharpe input uses dispersion across symbols. A zero variance produces
  no selection haircut. Cross-symbol dependence and overlapping trades are not
  removed by a square-root-n statistic. These are validation-model limitations,
  not measured live error rates.
- Forward paper trials=1 assumes a frozen, prospectively selected cohort.
  Retuning or selecting the best strategy after observation still counts as
  selection. Preserve prediction, data, model and policy versions.
- Closed-only and mark-inclusive paper averages are different populations,
  not guaranteed bounds on final results. Simulated costs are estimates; they
  do not reproduce queue position, market impact, settlement or actual fills.
- A5% weekly target needs cash-flow-adjusted whole-account equity, open marks,
  base-currency conversion, fees, drawdown, losing weeks and uncertainty. Do not
  annualize a few good trades or a favorable sandbox into dependable income.
- The examined history does not establish a profitable deployed strategy.
  Conversely, finite failed studies do not prove all future alpha impossible.
  Retain failed research and test new hypotheses on point-in-time holdouts.

## Comparison with Claude's earlier autonomous-trader draft

`agent-docs/AUTOTRADER_2026-07-28.md` is492 lines of **proposal text and code
blocks**, not a shipped StockSageBroker/AutoTrader implementation. It is useful
evidence that automation was part of the goal before this session.

| Draft claim / design | Review correction |
|---|---|
| No Saudi broker has any API; Tadawul must remain manual forever | Derayah's official Open API page markets order/account capabilities. Individual access, instruments and actual contract still require confirmation; do not invent a universal impossibility. |
| Reading positions makes the cycle idempotent | It has no durable pending-order identity/reservation, does not use its openOrders method, and writes the local book only after POST returns. A lost response/restart can duplicate submission. |
| A successful close can delete its local open date | closePosition swallows the request error with try?; caller then deletes the record. Preserve unknown/pending close and reconcile the broker acknowledgment. |
| Daily new-order cap survives operation | openedToday is in memory. Restart loses the cap; pending entries and partial fills are not modeled. |
| Every manual risk gate also applies | Proposed openQualifying does not run TradeGate/CapitalAllocator/LossLimit or reserve aggregate pending exposure; comments are not enforcement. |
| SecureField means protected credentials | Draft reads secrets from UserDefaults and returns raw error bodies. Use an actual secret boundary and redacted errors. |
| A cost-adjusted paper figure is what would really have been earned | It is a simulated estimate using an assumed cost table, not a real-money counterfactual or measured execution result. |
| A Mac loop is continuous execution | Sleep, network loss and process death still interrupt it; broker-side protections and durable reconciliation need independent design. |

The newer Gemini/Claude documents improve separation but introduce other errors:
AWS me-central-1 is UAE, not Riyadh; numeric allowlists do not prove truth;
App Attest is not proof that a particular confirmation screen was seen; guessed
Derayah headers/endpoints/fees are not a contract. V3 corrects these, separates
manual from policy-authorized automation, and keeps risk-reduction available
when new exposure is disabled. Primary-source references are in V3.

## What the Claude history changes about the plan

1. **Do not lose the original goal.** The July dialogue repeatedly asks for an
   economically useful app; d1ce source2750 explicitly requests unattended
   buying/selling. Later assistant manual-only formulations are not a revocation
   of that request. Direct18:24 clarification confirms it.
2. **Do not carry stale gates forward.** July2–5 records contain parked decisions;
   July9 source1362 lifts them and source1208 says KEEP TOM. Current code has the
   thin-identity policy, net weekly fields and Saudi60bps assumptions. A new
   defect in those implementations is not a reason to pretend approval never
   happened, nor does approval prove profitable behavior.
3. **Do not confuse repositories.** The July work was in parent Salehman AI;
   standalone StockSage was copied out later. A parent commit or training answer
   does not prove the standalone app contains the change. Wrong-app Settings
   guidance in the September transcript illustrates this directly.
4. **Do not treat plans as shipments.** Universe plans, an embedded AutoTrader
   proposal, pure-helper tests, empty-watchlist screenshots and an unexecuted
   review are not working features or populated-data UI verification.
5. **Do not turn summaries into measurements.** Examples include initial local
   training-memory assurances later contradicted by OOM, a gradients check that
   compared patched code with itself, corrected synthetic rows after validators
   passed, and loss comparisons across changing datasets. Model selection needs
   a frozen, matched held-out evaluation rather than a success narrative.
6. **Do not confuse activity with progress.** The long July thread contains many
   repeated power/CI supervision messages. The finite research results are useful;
   repeated unchanged status does not add evidence or implement a missing feature.
7. **Do not assume secrets were rotated.** History reports cleanup of a separate
   Salehman AI bearer token in tracked exports/docs; rotation remains unconfirmed
   in the reviewed records. Repository cleanup and actual revocation are different.
8. **Read completion claims with their unfinished checklists.** The July27
   IMPLEMENTATION_SUMMARY calls four tasks complete, while CLAUDE_HANDOFF says
   features are not integrated and tests are disabled. QUICK_START's22-test
   output is explicitly expected output, not an observed run. The July28 review
   is more specific, but its proposed patches and benchmarks are not shipment
   receipts. Current source, rather than either headline, determines status.
9. **Preserve later scope changes.** W2_DROPPED records the owner's13:37 +03
   decision to drop Tadawul real-time tracking. Do not restore it as an unfinished
   requirement simply because an earlier design asked for every stock live.
   Projections, negative observations and fiscal periods remain distinct from
   confirmed announcements regardless of a provider subscription.

## Verification and implementation order

### Saved model readiness — inspected19:18–19:20 +03

The intended local folder `/Users/saleh/models/salehman-qwen38-27b` exists but
was incomplete at inspection: six finalized shards of twelve, a temporary
seventh, config/generation config/chat template, and no tokenizer/index in its
directory listing. No weights were loaded or examined. An existing transfer may
change that state; incompleteness is not proof the transfer stopped or failed.

**20:05 +03 update:** the owner forwarded Claude's completed-transfer report
(rsync exit0, matching size manifest, reported eval loss1.77). An independent
local directory listing now confirms18 files, including all12 finalized shards,
the safetensors index, tokenizer files, config and chat template. The earlier
partial-copy observation is superseded. No remote hash manifest or paired eval
was inspected here: matching sizes are not a byte-for-byte checksum proof, and
training loss alone does not establish superior answers or profitable trading.

The inspected training/runs directory contains a30-answer base evaluation with
nonempty replies and no matching adapter evaluation. All30 prompt texts match
the current46-prompt file;16 newer prompts lack baseline results there. Remote
results were not inspected. The current generator has a seed parameter, but old
rows do not capture enough version/decoding metadata to authenticate a matched
comparison. Consequently neither model superiority nor serving readiness is
established. StockSage's configured served name is separate from a folder path.

The private `model-readiness-review.md` records exact artifacts, hashes and
limitations. No training, inference, endpoint probes, SSH or Settings changes
were performed. Chat can be designed around the existing transport without
claiming the downloaded fine-tune is verified inference-ready or starting a
competing download/conversion. Conversion and model loading were not started.

### Application verification

Executed review checks: inventory/dedup arithmetic; source/test coverage union;
shell syntax; exact test-runner failure-propagation witness; gate invalid-mode
witness; small standard-library/arithmetic witnesses identified above. No full
application regression suite or populated-device UI run was performed.

HANDOFF reports canonical macOS and iPhone17Pro(gate) xcodebuild runs at3dd538f:
1,639 tests/183 suites on each platform. Original log paths were located, but a
read-only extraction was blocked by a local protection hook and was not bypassed.
Those counts remain **historical reported evidence**, not an independent rerun.
The fallback runner defect does not by itself invalidate canonical xcodebuild
results. Passing helper tests still cannot establish every async/UI interaction.

Implementation should proceed through these concrete seams, with failing cases
before corrections and final call-path checks afterward:

1. Accepted-observation/provenance semantics and provider migration: separate
   task4/5 owns this work and integration; no competing patch in this review tab.
2. Currency/size/cost/gate consistency, calibration timing, paper accounting and
   risk reservations: no broker-ready label based on contradictory/unknown data.
3. Reuse LocalModelServer/Catalyst/Briefing and MarketSection for Chat, extending
   bounded conversation state, source-bound facts, privacy, cancellation and
   proactive events; do not duplicate the model stack.
4. One durable order core for manual and policy-authorized operation. Explicit
   buy-open/sell-close/short/cover semantics; SELL advice alone is not that intent.
   Mock/replay first, actual Derayah sandbox only with the real supported contract.
5. Matched assistant evaluation and separate point-in-time strategy evaluation.
   No promise that more parameters or spending establishes a5% weekly edge.
6. Canonical macOS/iPhone gates, actual populated UI checks, recovery/security
   drills and explicit HANDOFF evidence before calling integrated delivery done.

This report is not production approval, a fee/legal determination, an assertion
of observed portfolio loss, or authorization for the assistant to trade. The
overall product goal remains incomplete until the requested app is implemented
and its behavior is verified, not merely described here.
