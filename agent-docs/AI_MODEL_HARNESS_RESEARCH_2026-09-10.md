# A faster, better-grounded AI system for StockSage

## Executive recommendation

**Improve the harness first; retain Qwen3.5-9B MLX 6-bit as the baseline; add specialists only where a controlled comparison demonstrates a benefit.** Use the owner's paid Massive and Benzinga products as the evidence supply, deterministic code for prices, arithmetic and execution constraints, and a local language model for interpretation. Keep the fine-tuned 27B available for rollback, not permanently loaded alongside every new candidate.

There is no defensible single “best stock AI” across news sentiment, Arabic conversation, financial-statement extraction, forecasting and low-latency Mac inference. Those are different tasks. Finance benchmark scores do not establish profitable trading, and none of the evidence reviewed establishes reliable 5% weekly portfolio returns.

The most useful near-term additions to evaluate are **FinBERT for English sentiment**, **Qwen3 embeddings/reranking only if ordinary retrieval proves insufficient**, and **Fastino-Nemotron-3.5-Lightning-Finance as an optional, heavier filings-analysis challenger**. Chronos-2-Small and Kronos-Small belong in a separate, shadow-only forecasting experiment. Installing all of these simultaneously would work against the speed and responsiveness objective.

The stronger harness proposed here gives every research job a traceable lifecycle, preserves source coverage under the context budget, schedules inference across all app callers, validates claims rather than merely JSON formatting, and publishes useful partial evidence when a source or model fails. It does not loosen trading thresholds or fabricate successful checks.

This is a research report and proposed design, reviewed against the current source on **September 10, 2026**. It does **not** claim implementation, deployment, new live API verification, or new model-comparison runs. Public sources were checked during this research; benchmark claims are identified as author-reported or anecdotal where appropriate.

## 1. What is actually present locally

The inspected checkout is `/Users/saleh/StockSage-wt/qwen-context`, branch `codex/qwen-chat-context`, HEAD `d301176d645cce3fbf7b4836f394fd3961b52721`. It contains 54 pre-existing modified/deleted/untracked status entries, including unfinished model migration and unrelated UI/reliability work. This research has not modified them.

The current source has **six model-facing flows**: conversational chat, AI assessments, same-day paper research, manual horizon research, catalyst narration, and the new sentiment flow. They already converge on `StockSageLocalModelServer.completeDetailed`, directly or through its compatibility wrapper. This is the useful existing seam; a second independent model client would split ownership and diagnostics.

The inspected shared module already provides configuration validation, a non-redirecting ephemeral HTTP session, bounded responses, request cancellation/policy checks, typed diagnostics, and a settings revision protecting against A→B→A configuration changes. The unfinished LM Studio profile additionally checks returned model identity and successful completion, and applies a conservative input budget. These protections should be preserved, not claimed as missing.

Important current limitations and implementation seams:

| Observation from current source | Consequence for the proposed harness |
|---|---|
| All six flows converge on the same transport, but the assessment object's single-active-symbol guard is local to that flow. | Measure contention across callers; place any app-wide admission policy at the shared seam, not six separate locks. |
| Requests currently use non-streaming responses. | Existing transport cannot provide genuine per-token progress. Add stage progress immediately in the design; any future streaming requires incremental parsing, cancellation and publication tests. |
| Rich transport diagnostics are sometimes collapsed into generic unavailable messages by callers. | Preserve safe diagnostic categories through the UI; do not print raw server bodies or credentials. |
| The 9B budget uses normalized UTF-8 bytes as a sufficient token bound, including output/framing reserves. | It is conservative, not an exact tokenizer or proof of the runtime's effective context setting. Never substitute an optimistic bytes/4 estimate. |
| Paper/horizon callers can prepare up to 12,000 UTF-8 bytes of facts before reaching the stricter 9B guard. | Context selection needs a shared contract. A rejection can be correct while revealing mismatched caller budgets; reproduce real rejected payloads before changing behavior. |
| Benzinga already has nine product types, shared credentials, bounded caching and single-flight requests. | Extend and verify existing integration; do not build another paid-provider client or request a second key by default. |

Source anchors: [shared model client](/Users/saleh/StockSage-wt/qwen-context/StockSage/Sources/StockSage/StockSageLocalModelServer.swift:369), [paper caller](/Users/saleh/StockSage-wt/qwen-context/StockSage/Sources/StockSage/StockSagePaperAutomation.swift:884), [manual horizon caller](/Users/saleh/StockSage-wt/qwen-context/StockSage/Sources/StockSage/StockSageHorizonResearch.swift:287), [chat caller](/Users/saleh/StockSage-wt/qwen-context/StockSage/Sources/Views/StockSageChatSection.swift:481), [sentiment module](/Users/saleh/StockSage-wt/qwen-context/StockSage/Sources/StockSage/StockSageLocalSentiment.swift:91).

### Recorded speed recovery is real, but narrow

The saved local performance investigation reports a final **60.634 generated tokens/second median across three short cases**, versus 6.850 initially, using the same 9B 6-bit model. Warm time-to-first-token was 0.243–0.368 seconds. The original generic MLX runtime was restored. The strongest observed explanation was inadequate input power at low battery charge; the record explicitly does not isolate every thermal/OS confound or credit the NAX runtime for the recovery.

These are recorded controlled probes, not a fresh measurement during this research, a production p95, or an all-market throughput guarantee. The final probe unloaded its local model. The source also records an effective runtime context of 262,144 despite requesting 4,096; app input limits and server allocation are separate concerns. [Local performance evidence](/Users/saleh/StockSage-model-migration-20260910.w6pSJw/PERFORMANCE_DIAGNOSIS.md)

### Quality still needs work

Re-reading the saved comparison artifacts found **11/12 sentiment passes for both plain 9B and the FinGPT-prompt variant**, with the same adversarial Arabic negative example labeled positive. Thus, this local test does not demonstrate a FinGPT quality gain.

Saved plain-9B outputs also contain arithmetic and time errors: one expected gross/net calculation of 32.40/29.90 was answered 32.50/30.00; another response confused a five-minute observation age with five seconds; a midnight example produced inconsistent elapsed-time reasoning. These are concrete reasons to put calculations and timestamp comparisons in deterministic code, not reasons to claim the entire model is unusable. The comparison is too small to establish broad non-inferiority to the fine-tuned 27B.

The existing migration's quality, lifecycle, caller integration and installation gates remain open. Earlier macOS/iPhone receipts do not automatically certify the current dirty tree or this proposed harness. [Migration status](/Users/saleh/StockSage-wt/qwen-context/agent-docs/MODEL_MIGRATION_2026-09-10.md)

## 2. Candidate landscape: different winners for different jobs

Priority means **evaluation priority**, not permission to deploy unchecked weights. Sizes are publisher/model-card figures or explicitly identified artifact sizes, not measured peak memory on this Mac. Repository licenses and inherited base-model/weight licenses must be checked separately before use.

### General reasoning, retrieval and small-model candidates

| Candidate | Role and practical fit | Recommendation |
|---|---|---|
| **Qwen3.5-9B, MLX 6-bit** | Existing 9B baseline; downloaded artifact is about 8.22 GB decimal. Multilingual family; Apache-2.0 upstream. Local speed evidence exists, but app-specific quality gaps remain. | Keep while improving the harness and completing migration gates. [^1] |
| **Qwen3.5-4B** | Smaller same-family general challenger; Apache-2.0. Smaller does not imply equal arithmetic, Arabic or evidence-following quality. | First smaller challenger, tested against exactly the same tasks. [^2] |
| **Gemma 4 E4B** | Publisher describes 4.5B effective parameters but about 8B including embeddings; Apache-2.0. Not a literal 4B storage budget. | Second small/general challenger if compatible local packaging is available. [^3] |
| **Gemma 4 12B** | Quality-oriented dense challenger; Apache-2.0. More memory/work than the existing 9B is plausible, not measured. | Later quality comparison, not a speed promise. [^4] |
| **NVIDIA Nemotron 3 Nano 4B** | Approximately 3.97B hybrid model; publisher's supported-language statement is English; custom Nemotron license. | English-task challenger only; no assumed Arabic parity or MLX speed. [^5] |
| **Phi-4-mini-instruct** | Approximately 3.8B, MIT; multilingual support includes Arabic. | Useful small control, not preferred without local results. [^6] |
| **LFM2.5-1.2B-Instruct** | Very small general model under Liquid's model license. | Defer: deterministic routing is cheaper than loading an LLM just to pick a route. [^7] |
| **Qwen3.6-35B-A3B** | 35B total, 3B active MoE; Apache-2.0. Its efficiency does not remove full-weight residency. | Heavy optional comparison; do not confuse active parameters with memory. [^8] |
| **Qwen3-Embedding-0.6B** | Multilingual retrieval embeddings, Apache-2.0; not a conversational model. | Add only if measured retrieval misses justify it. [^9] |
| **Qwen3-Reranker-0.6B** | Multilingual query/document relevance model, Apache-2.0. | Conditional reranking of a short retrieved list, not every market item. [^10] |
| **Owner's fine-tuned 27B** | Existing locally held fallback with StockSage-specific training history. | Preserve untouched; use as a controlled comparator or requested slow review, not an automatic authority. |

### Finance specialists and frameworks

| Candidate | Evidence and restrictions | Recommendation |
|---|---|---|
| **ProsusAI/finbert** | Approximately 110M English positive/negative/neutral classifier. Official code repository is Apache-2.0; the inspected model card lacks a separate weight-license declaration. | Highest-priority narrow sentiment baseline after release-license confirmation. [^11] |
| **yiyanghkust/finbert-tone** | Separate 110M financial-language model; tone checkpoint trained on analyst-report sentences. Repository Apache-2.0; separate weight declaration not verified. | Compare with Prosus on the same English news/analyst dataset; choose one. [^12] |
| **FinGPT sentiment/multitask adapters** | Downloadable task adapters based on older ChatGLM/Llama-2 families. MIT adapter declarations do not remove base-model terms. | Reuse appropriate recipes; do not bolt a Llama-2 adapter onto Qwen3.5. [^13][^14] |
| **Fastino-Nemotron-3.5-Lightning-Finance** | New finance post-training with numerical-QA and extraction evidence. Nominal 30B-A3B base; community card reports roughly 32B total. Finance card declares Apache-2.0 while the linked base declares OpenMDW-1.1. | Most interesting heavier finance challenger; provenance, inherited terms and local quality first. [^15][^16][^17] |
| **Fin-R1** | Qwen2.5-7B-based financial reasoning model; public weights. Explicit release license was not verified from primary materials. | Defer deployment; task benchmarks alone do not clear licensing or transfer quality. [^18] |
| **“Fin-R1.5”** | No publisher-owned checkpoint/paper/license was established in the completed research. | Unverified, not an available dependency to put in the plan. |
| **FinMA / PIXIU** | Older LLaMA-based finance instruction research. Familiar-task sentiment gains do not imply numerical-QA or unseen-entity robustness; inspected checkpoint is gated. | Benchmark/reference material, not a preferred replacement. [^19] |
| **InvestLM** | LLaMA-65B-based adapter; project restricts use to non-commercial research. | Poor practical and licensing fit for this app. [^20] |
| **BloombergGPT** | 50B finance research; no official downloadable checkpoint was verified. | Not an installable local option. [^21] |
| **TradingAgents** | Multi-role trading research framework, not a single superior local model. | Borrow explicit evidence roles and review criteria; do not import its whole debate loop. [^22] |
| **FinRL / Qlib** | Reinforcement-learning / quantitative-research frameworks, not pretrained stock oracles. | Consult experimental methods; avoid a parallel trading/accounting stack. [^23][^24] |

### Forecasting candidates—not language models or market observations

| Candidate | Practical facts | Recommendation |
|---|---|---|
| **Ridge / LightGBM / XGBoost** | Classical statistical/tabular baselines with inexpensive inference; existing deterministic features can be reused. | Establish these and no-change baselines before a foundation-model sweep. [^25][^26] |
| **Chronos-2-Small** | Exact ID `autogluon/chronos-2-small`, about 28M parameters, Apache-2.0. General probabilistic forecasting. | First general forecasting challenger, shadow only. [^27] |
| **Chronos-2 / Chronos-Bolt** | Larger 120M Chronos-2 and smaller Bolt variants exist; family benchmarks are not US intraday profitability evidence. | Small model first; expand only for demonstrated value. [^28] |
| **Kronos-Small / Base** | Financial OHLCV sequence models, 24.7M / 102.3M plus tokenizer, MIT repository. Small/base context is 512 bars; large model is marked unreleased. | First finance-native forecasting challenger, shadow only. [^29] |
| **TimesFM** | Current 3.0 repository offers MLX, but its pretrained weights are restricted to non-commercial, non-production use. Repository explicitly distinguishes earlier ≤2.5 Apache-2.0 weights. | Do not choose 3.0 for shipped production just because the code is Apache or native MLX. [^30] |
| **Moirai-2.0-R-Small** | Compact forecasting release, model card CC-BY-NC-4.0. | Research reference; not an unrestricted production default. [^31] |
| **TiRex-2** | Small recurrent forecasting family, Apache-2.0 card. Apple deployment performance remains unmeasured. | Reserve candidate; no need to test every similar forecaster initially. [^32] |
| **Toto 2.0 22M** | Small member of an observability-oriented forecasting family, Apache-2.0 repository. Current 2.0 lacks the exogenous-variable/fine-tuning features described for legacy 1.0. | Lower priority than Chronos/Kronos for StockSage. [^33] |

### What FinGPT would—and would not—add

FinGPT is useful as an open finance workflow, dataset and adapter collection. Its sentiment releases and multitask adapter address distinct classification/extraction tasks. Project-reported scores against FinBERT vary materially by dataset; those comparisons are not a current head-to-head against Qwen3.5 on the owner's news mix. The multitask adapter's entity/relation labels also do not amount to complete, timestamped event extraction. [^13][^14]

StockSage's new `StockSageLocalSentiment` currently uses a FinGPT-derived prompt with the same Qwen endpoint. Describe it as a **FinGPT-style sentiment workflow**, not a separately loaded FinGPT model or a demonstrated accuracy upgrade. Keep original attribution. A small classifier earns its place by reducing validated per-document latency while maintaining sentiment quality, particularly negation, mixed-company stories and neutral-versus-insufficient distinctions.

Start the classifier comparison on CPU as well as any supported accelerator. A tiny classifier that competes with Qwen for unified-memory/GPU bandwidth can worsen the combined workload despite looking fast in isolation. Reuse a compatible existing runtime where possible; do not introduce several independent model servers simply to host several names.

### The strongest new finance lead: Fastino

Fastino's finance card reports substantial developer-evaluated gains over its base, including FinQA development accuracy increasing from **15.86% to 59.23%**, and SEC numerical extraction from **79.74% to 87.60%**. These are paired author results, not an independent comparison with Qwen, and development-set selection/exact deduplication do not prove absence of semantic or document-family leakage. [^15]

A community MLX 6-bit artifact is listed at **25.7 GB**. That is materially heavier than the current 9B before caches and macOS; nominal “3B active” does not make it a lightweight 3B download. Its card does not establish this Mac's speed, Arabic quality, or quantized preservation of the reported results. Confirm base/merge provenance, inherited terms, conversion revision and file hashes before an isolated trial. [^16][^17]

It could be useful for difficult English filing questions. It should not become the always-on sentiment engine, vote on every ticker, or replace the 9B merely because “Finance” is in its name.

## 3. What Reddit contributes—and what it cannot prove

Reddit was used to discover real-world failure modes and candidate leads, not to certify performance. Technical conclusions were cross-checked against official repositories, papers and runtime documentation.

| Discussion | Useful observation | Limitation and resulting action |
|---|---|---|
| “The 4B class of 2026 benchmark” | A home benchmark compared several small models, including finance questions. | The author reported 30/39 Qwen outputs empty/truncated under its thinking/output setup. This is not a fair model-quality ranking. Separate reasoning budget, final-answer completion and task score. [^34] |
| Homelab consolidation to one model | Multiple-model management can itself become a burden. | The reported machine was a 128GB Ryzen system, not this 48GB Mac. No throughput transfer. Keep a small active roster. [^35] |
| Backtesting LLMs / data leakage | A model can know later historical outcomes even if the prompt says to use only old information. | Prompt instructions do not remove pretrained knowledge. Use post-release forward observations and point-in-time source snapshots. [^36] |
| “Lesson: always backtest” | A reported attractive result disappeared after leakage was found. | Anecdotal outcome, useful failure mode. Perturb future bars and verify past features/decisions do not change. [^37] |
| LLM-written backtest warning | Close-derived signals can accidentally receive the return already realized in that same bar. | Shifting a column is not a complete execution model. Check when every feature became known and when an eligible fill could occur. [^38] |
| Qwen3.5-27B Q4 quantization comparison | Quantization comparisons can reveal distributional changes. | KL/perplexity-style differences are not the owner's financial-answer quality or hardware speed. Keep the approved 6-bit baseline while evaluating the whole task. [^39] |

The practical lesson is to measure **correct, supported answers per minute**, including failures and queueing. A high decode rate with truncated reasoning or incorrect figures is not a win. Financial QA benchmarks such as FinanceBench and the broader FinBen suite are useful task catalogs, but their protocols and dates matter; neither substitutes for StockSage's own evidence and execution tests. [^40][^41]

## 4. Paid API products remain the foundation

The owner reports paid **Massive Advanced and Benzinga products**, and explicitly selected the Massive/Benzinga credential route rather than adding a separate direct Benzinga key. That preference does not prove the purchasing channel or current entitlement for every individual product. Do not replace paid evidence with scraped headlines or ask the owner to repurchase access. The current Swift integration already has `earnings`, `guidance`, `ratings`, `analystInsights`, `bullsBearsSay`, `news`, `analysts`, `firms` and `consensusRatings`.

| Evidence | Use in the harness | Truthfulness requirement |
|---|---|---|
| Massive trades and NBBO quotes | Market observations, freshness, spread and existing deterministic simulation checks. | Market timestamp is not HTTP retrieval time; quote/trade eligibility remains distinct from research freshness. [^42] |
| Benzinga news | Source-backed event extraction and ticker-specific narrative/sentiment. | Preserve publisher, publication/update time and URL. Optional missing article body is not a model failure or license to invent one. [^43] |
| Earnings | Upcoming/reported events, actual versus estimate where supplied. | Preserve projected versus confirmed status, fiscal period, publication/availability time. [^44] |
| Guidance | Stated management ranges and revisions. | The official endpoint documents a two-hour update cadence; do not advertise every product as tick-speed. Keep GAAP/adjusted/FFO distinctions. [^45] |
| Ratings, insights, bulls/bears, analyst/firm directories, consensus | Attributed analyst opinion and cross-reference metadata. | Opinion, price target and consensus are not calibrated win probability or StockSage's own verified forecast. [^46][^47][^48] |

An entitlement/health view should distinguish **purchased (owner-reported)**, **authenticated**, **endpoint authorized**, **checked with results**, **checked empty**, **stale**, **rate-limited**, **not checked** and **failed**. A successful basic stocks request does not certify all add-ons. This research made no authenticated paid API calls and does not certify account entitlements, streaming delay, redistribution rights or complete coverage.

Reuse existing provider request limits and caches. The inspected Benzinga client bounds each query to one 20-row page, with three admitted transports, a 12-second overall deadline and a 500-entry memory cache. Those are intentional bounded requests, **not an exhaustive all-market news archive**. Add controlled pagination only for a defined completeness requirement, preserving rate limits, cancellation and per-page timestamps. Never silently equate the first page with all available data.

Keep credentials in the existing secure credential path. The app attaches them to provider requests; models receive sanitized records and source IDs, not headers, token-bearing URLs or account secrets. Do not put keys in prompts, training, diagnostics or this report. Check the provider agreement separately before storing paid article bodies in a durable evaluation/training corpus; API access does not by itself grant every reuse right.

## 5. The stronger StockSage harness

### Recommended approach and alternatives

**Recommended: one shared local research module with deterministic orchestration and selectively invoked specialists.** It builds on the existing Swift transport, provider clients and validators. This concentrates behavior behind a small interface rather than making each caller implement retries, context packing, cancellation and error translation again.

The minimal alternative is better prompts around the existing 9B. That is cheaper initially but cannot, by itself, fix cross-caller queueing, source omissions or incomplete lifecycle diagnostics. The maximal alternative is a TradingAgents-style committee with several resident generators and debate rounds. It may support experimental research, but adds work, correlated opinions and memory pressure before demonstrating value on this Mac. Keep it out of the normal path. Simple routed workflows and careful tool/context design are supported engineering patterns; adopting them does not require a framework dependency. [^22][^49][^50]

```text
Paid Massive/Benzinga + permitted filings + current app records
                            |
          normalized, timestamped, source-linked evidence
                            |
          deterministic selection / arithmetic / context
                            |
        +-------------------+-----------------------+
        |                   |                       |
   small sentiment      Qwen 9B analyst       shadow forecasting
   only when useful     shared GPU schedule   no execution authority
        |                   |                       |
        +---------- claim and freshness validation -+
                            |
             cited result + gaps + truthful progress

Existing feed ingestion, paper accounting and protective exits
run independently; they never wait for a language-model response.
```

The interface should accept a typed research request—task, symbol/entity scope, horizon, language, settings/policy revision and request identity—and return progress plus a typed result. Internally it reuses current modules; it is not a new cloud gateway, plugin bus or general-purpose shell agent.

### 5.1 Evidence before inference

Normalize records once, keeping source identity, affected entity, event time, publication time, provider-availability time when supplied, local first-observed time, latest retrieval time, fiscal period, units, revision and quality state. These timestamps are not interchangeable: a historical publication timestamp does not prove that a backfilled record was available to StockSage then. A later retrieval does not make an old event new; an amended filing or corrected news item must invalidate affected analysis.

Maintain distinct typed values for verified observations, deterministic derived figures, attributed third-party opinions, generated hypotheses and unavailable fields. A model forecast cannot become a quote by passing through a generic number field. Sentiment about a supplier is not automatically sentiment about its customer.

External articles, filings and user-imported group messages are untrusted evidence, not instructions. Allowlisted tools must ignore embedded requests to reveal keys, execute commands, change strategy or contact arbitrary hosts. The model may request more relevant evidence; application code validates the ticker, scope, URL destination, budget and permissions.

For a genuine multi-step question, permit a **bounded research loop**: identify the missing fact, request one of the existing read-only evidence operations, inspect its typed result, and answer or identify the remaining gap. Start with a maximum of two follow-up evidence rounds, adjustable only after task evaluation—not an unbounded autonomous agent. Ordinary questions use the already-compiled evidence and need no planning call. Expose only the relevant operations: permitted news/filing lookup, earnings/guidance lookup, historical observations, current observations and deterministic calculations. The model gets no shell, arbitrary HTTP, credential lookup or broker submission tool. A failure to find evidence is a valid terminal state, not a reason to invent it.

### 5.2 A context compiler, not a giant prompt

Keep stable instructions first and changing evidence afterward. Select by task and time, not by whichever provider finished first. Reserve space for source coverage, observation ages, missing-data states, the user's question and the final answer budget. Trim duplicated prose before dropping mandatory facts; if the complete minimum cannot fit, return a specific context-budget result rather than silently erasing a product or a risk disclosure.

Start retrieval with exact ticker/entity/time filters and existing search. If a local document index is necessary, SQLite FTS5/BM25 is the first candidate. Add Qwen embeddings only after measuring missed semantic matches; rerank only the bounded shortlist if it improves precision. No separate vector database is justified by the current evidence. [^9][^10][^51]

Keep the owner's normal 4K request target while distinguishing it from model maximum context and runtime allocation. Query a supported tokenizer interface if available; otherwise preserve the conservative guard and report underutilization. Long filings should be queried by relevant sections with provenance, not dumped into a larger context by default. Never silently compact financial facts into unsupported paraphrases.

### 5.3 Shared inference admission and real cancellation

Instrument all six callers before setting concurrency. The starting operational policy is **one heavy local generator**, bounded pending work, interactive priority with fairness for background research, and duplicate-job coalescing. The coalescing identity includes every answer-affecting input: task, normalized question, entity scope, horizon, language, evidence revision, model/prompt revision, settings/policy revision and relevant account-state revision. Do not share results across different portfolio or permission contexts. Each subscriber retains separate ownership: cancelling one subscriber does not cancel a shared job another valid subscriber still needs. “One generator” does not forbid measured continuous batching within that loaded model.

Compare concurrency 1 versus 2, then 4 only if helpful, on mixed interactive/background tasks. Select on interactive p95, total verified throughput, memory pressure and cancellation behavior—not raw aggregate tokens alone. Never occupy a scarce inference slot while waiting on a slow HTTP source. Publish completed evidence and revisit a delayed optional source when it arrives; incomplete mandatory evidence must remain explicit.

Cancel queued work immediately when obsolete. Propagate cancellation to in-flight transport, reject late responses, and verify whether the server actually stops computation before admitting replacement work as if the GPU were free. Model-off, settings changes, app quit and network-policy changes must invalidate work consistently. A stale completion must never overwrite a newer selection or resurrect an old paper proposal.

LM Studio's older parallel-request page still says MLX support is forthcoming, whereas its **June 5, 2026** MLX article documents continuous batching for vision-model requests and cache changes. That discrepancy is exactly why capability probes and installed-version evidence outrank assumptions. The vendor's reported throughput gains used an M3 Max, a different model and specified parallel workload; they are not a promise for StockSage. [^52][^53]

### 5.4 Model lifecycle and capability checks

Pin model artifact, quantization, tokenizer/template, runtime version and capability receipt. Test model identity, JSON output support, normal finish, context behavior and cancellation on that exact combination. Avoid repeated full model discovery before every small request when a short-lived, revision-bound capability result is valid; invalidate on failures/settings changes. Measure whether discovery actually contributes noticeable latency before optimizing it.

Reuse the existing lifecycle/TTL work. Warm the primary model during an explicit active research run, release it according to the approved idle/stop policy, and never unload someone else's LM Link model. Keep 27B rollback artifacts and preferences recoverable. Do not overwrite working runtime packages to force speculative features.

**Speculative decoding remains disabled for the inspected installed path.** The local investigation found the Qwen package selects `BatchedVisionModelKit`, while that runtime's speculative loader rejects batched models. A generic API argument or MTP config field does not prove support or presence of draft weights. Revisit only after an exact compatible runtime/package is available; then compare accepted draft tokens, net latency, memory and output quality. [Local investigation](/Users/saleh/StockSage-model-migration-20260910.w6pSJw/PERFORMANCE_DIAGNOSIS.md), [^54]

### 5.5 Typed outputs and claim validation

Use schema-constrained output where the exact runtime supports it; otherwise parse and validate a short, explicit format. Schema validity is only structural. LM Studio documents JSON-schema output, but its availability on the chosen model/runtime still needs a smoke test. [^55]

Validate each financial claim against **entity + field + value + unit + period + source**, anchored to an actual provider field or document span/table location. A model's self-reported tuple cannot validate itself. A number appearing somewhere in the prompt does not prove it belongs to the correct company or metric. Derive arithmetic using existing deterministic helpers with explicit rounding; validate dates with calendars/time zones, not model prose. Permit legitimate calculated results only when their inputs and operation are recorded. Causal explanations without independently supported evidence remain labeled interpretations even when their JSON and citations are structurally valid.

Separate extraction confidence, source coverage and statistical forecast uncertainty. None is a probability that a trade will win. Neutral sentiment must not hide a failed fetch, unsupported language or insufficient evidence. Quoted analyst targets stay attributed opinions. General educational explanations need not be suppressed merely for using an illustrative number; they must be clearly separated from real market/account claims.

A bounded repair can correct formatting or unsupported claims using the same evidence. It must not keep retrying until a desired Buy answer appears. If validation still fails, show validated facts and a precise limitation, not invented success or a forced verdict. Keep paper entry/exit constraints authoritative and unchanged.

### 5.6 Recovery without infinite work

Use a finite job lifecycle: queued, fetching, waiting for a specific source, ready, generating, validating, complete/partial, cancelled/obsolete, or failed with an actionable category. Optional-source failure need not erase useful verified results. Authentication/entitlement failures are not retried like transient transport errors; rate limits respect provider guidance; transient retries are bounded with backoff.

Capture one overall deadline from the existing task policy, including queueing, source collection, generation and repair. The initial declared source plan defines the initial request-attempt allowance; permit at most four additional evidence attempts across the two follow-up rounds. Retries consume the same attempt allowance, not a hidden extra budget. Cap heavy generative turns at four total: at most two follow-up evidence requests, one original answer and one repair; ordinary jobs use one answer turn. Classifier work is bounded by unique records in the same source plan. Unchanged evidence cannot restart generation; optional late results update the evidence view, with any material re-analysis admitted as an explicit new/coalesced job. Stop at the first exhausted deadline or attempt/generation cap and retain a truthful partial result.

For long owner-started scans, reuse existing persistence to checkpoint **research work**, not rewrite trading history. Record completed symbols and evidence/model versions. After restart, interrupted inference becomes interrupted—not complete—and any resumed result reacquires relevant evidence. Do not duplicate historical paper decisions, fills or accounting writes. Recovery tests must cover disk-full/corrupt-state paths and a second process trying to own the same scan.

No full event-sourcing framework, distributed queue, Redis or always-on extra backend is needed for this single-Mac research workflow. Add durable state only where a real long-running task would otherwise lose progress.

### 5.7 Useful UI, not cosmetic progress

Show per-check stage, elapsed time and reason for waiting. Use determinate progress for known work such as “38 of 101 checks complete”; use an indeterminate indicator for generation whose remaining token count is unknown. Do not invent a percentage from elapsed time.

If token streaming is added later, it must not publish unvalidated financial claims as verified while the rest of the answer is still arriving. Stream progress immediately; release financial content only through the chosen validation contract. A fast first token and a fast first verified result are separate measurements.

Publish independent completed checks as they land. Keep a visible pending list and automatically update a waiting item when its source arrives. Distinguish “no matching item in the checked window,” “not checked,” “source denied,” “waiting for model” and “model answer not verified.” Preserve Retry, Cancel and source inspection without making the user interpret raw diagnostics.

Keep the approved mode semantics: 101-check continuous day research and manual, bounded 500-stock 1–7/7–14-day research-only scans. No change to position risk, thresholds, execution authority or freshness rules is implied by a faster harness.

### 5.8 Evaluation is part of the harness

Store redacted request identity, task, evidence snapshot/hash, provider statuses, model/runtime/prompt versions, phase timings, token counts, finish category, validation outcomes and cancellation outcome. Retain permitted evidence fixtures separately; hashes alone do not allow replay without the underlying permitted content. Never log bearer tokens, raw credential-bearing URLs or hidden reasoning as a prerequisite for debugging.

Use deterministic graders for arithmetic, source mappings, timestamps, permissions and lifecycle outcomes. Use blinded human/rubric checks for nuance, Arabic and explanatory usefulness. A model judging itself is not sufficient ground truth. Separate capability experiments from regression gates and evaluate actual resulting state, not just an agent's “done” message. These distinctions follow established agent-evaluation practice. [^56]

Learn from failures through **reviewed, versioned changes** to prompts, examples and retrieval. Do not automatically train on raw chat, trade outcomes or model-generated self-critiques. Context-engineering research suggests potential gains, but its benchmark results do not justify an unreviewed self-modifying trading system. [^57]

## 6. Evaluation plan: prove speed and quality together

### Freeze comparisons before tuning

Create a small development set for debugging and a separately held-out, versioned acceptance set. A practical proposed starting point is **200 held-out cases** across English/Arabic sentiment, entity-specific event extraction, filing QA, arithmetic, age/session reasoning, evidence gaps, malicious source text, and multi-step follow-up questions. Keep document revisions, syndicated news copies and translated twins in the same split. Existing known failures are regression cases, not fresh unseen evidence.

Use the same evidence and scoring rubric across models. Record thinking mode, final-output budget, quantization, runtime, temperature, seed where supported and actual finish. Repeat nondeterministic cases rather than mistaking one lucky answer for improvement. A truncated/empty answer counts against task success even when its visible tokens are fast.

| Dimension | Required measurement or gate |
|---|---|
| Financial facts | Exact entity/field/unit/period mapping and deterministic numeric grading; no regression in known critical cases. |
| Sentiment | Per-language macro-F1, confusion matrix, ambiguous/insufficient handling and entity attribution; do not hide Arabic behind a combined score. |
| Retrieval | Recall of necessary source spans and completeness-state preservation, followed by answer faithfulness. |
| Latency | Queue, source fetch, cold load, prefill/TTFT, decode, validation and total p50/p95 separately. |
| Efficiency | Correct supported answers/minute, peak process memory, system pressure, swap deltas and app responsiveness. |
| Lifecycle | Cancellation, settings A→B→A, quit/restart, sleeping/waking, timeout, malformed/oversized result, wrong model and context overflow. |
| Paid sources | Per-product receipt without secrets; denied/empty/stale/partial are distinct; revisions invalidate affected caches. |
| Trading isolation | Existing deterministic monitoring/exits/accounting continue during model load, long generation, failure and restart; no new execution authority. |

Run latency trials under recorded power and workload conditions, with both warm and cold cases. Use at least 30 representative mixed requests per setting as an initial performance sample; increase if variance prevents a decision. Test normal app use, not just a silent machine or one 91-token answer.

Define acceptable quality differences before opening holdout results. Critical money/time/source/permission regressions fail outright. For subjective task quality, report paired uncertainty and treat an inconclusive comparison as inconclusive—not “no loss.” Only adopt a smaller model if it improves the relevant latency/throughput measure while satisfying the agreed quality criteria. No finite test proves universal quality preservation.

### Forecasting requires a different experiment

Start with a no-change/naive forecast and simple regularized/tabular baselines. Compare Chronos-Small and Kronos-Small on frozen walk-forward splits using bars and news that were actually available at each decision time. Handle corporate-action adjustments, missing bars, sessions, delisted symbols and revised data explicitly. A newly released model may already know older market periods through pretraining; forward shadow collection is stronger evidence than prompting it to forget.

Measure calibration/interval coverage, error and directional skill separately. If later evaluating an unchanged paper strategy, include contemporaneous executable quotes, spread, displayed size, slippage assumptions, fees, opportunity timing and outages. Forecast accuracy, simulated P&L and real execution are different results. Do not alter thresholds to rescue a preferred model or restart a large parameter sweep without a prespecified experimental question.

## 7. Proposed implementation sequence

These are approval-ready work packages, not completed changes. Keep one repository writer/integrator; use bounded read-only reviews. Model benchmarks and heavy platform gates run serially to avoid confounding measurements and overloading the Mac.

| Package | Deliverable | Exit gate |
|---|---|---|
| **A. Protect and finish the baseline** | Preserve dirty work and 27B; reconcile current 9B migration, known quality failures and lifecycle behavior. | Existing acceptance criteria pass, or baseline remains explicitly unpromoted. No silent replacement. |
| **B. Harness tracing and source coverage** | Phase timings across six callers, paid-product state propagation, bounded context compiler and exact source mapping. | Deterministic fixtures prove no source-status loss, secret leakage, stale acceptance or incorrect numeric mapping. |
| **C. Scheduling and recovery** | Shared admission/coalescing, fair interactive priority, bounded retries, cancellation and research restart checkpoints where needed. | Mixed-load and failure tests pass; monitoring/exits unaffected; measured end-to-end benefit. |
| **D. First specialist trial** | Prosus FinBERT versus tone baseline and current FinGPT-prompt flow on licensed English fixtures. | Rights/packaging confirmed; task quality passes; actual latency benefit. Arabic stays on a tested path. |
| **E. Retrieval and stronger-analysis trials** | FTS5 first; embeddings/reranker only for measured gaps. Compare Qwen4B/Gemma E4B; isolated Fastino trial for hard English filing QA. | Blinded task comparison and memory/lifecycle gates; retain only useful winners. |
| **F. Shadow forecasting** | Classical baseline versus Chronos/Kronos, with immutable experimental manifests. | Point-in-time/causality tests pass; results remain research-only. No strategy activation. |
| **G. User-visible delivery** | Honest per-check progress, partial results, source inspection and actionable failures; reversible local app replacement. | Required current-tree macOS/iPhone gates, relevant UI inspection, state/history preservation and rollback verification. |

Packages B/C are the main answer to the request for a much better harness. They should improve reliability and visibility even if **no new model wins**. Package E is not an obligation to install every candidate; stop at the first approach that demonstrably meets the task.

## 8. Decisions and limitations

The proposed scope for owner approval is: **harness-first, local-first, existing paid feeds, unchanged 6-bit baseline, conditional specialists, forecasting in shadow, 27B rollback preserved**. This research stage has not downloaded models, changed repository code, made authenticated probes or replaced the app. Those implementation actions follow design approval and the applicable existing acceptance gates. The proposed design does not authorize real orders, paid cloud resources, new subscriptions, pushes, historical-record edits, or an autonomous strategy-changing feedback loop.

Not verified in this research: live account entitlements or endpoint health; the current running model/app's complete behavior; sustained production latency; quality parity with 27B; new candidate performance on this Mac; model weight-license questions called out above; current production suitability of community conversions; or any profitability advantage. Candidate inventories and vendor claims are not completed installation receipts.

No StockSage source, settings, model weights or installed app were changed for this report. No new models were downloaded. The final production model roster should be an experimental result, not a collection chosen by name, popularity or the number of agents involved.

## Sources

Primary sources are preferred for technical claims. Reddit entries are explicitly anecdotal. Local links above identify inspected project evidence; external sources below were accessed during this research on September 10, 2026.

[^1]: [Qwen3.5-9B official model card](https://huggingface.co/Qwen/Qwen3.5-9B).
[^2]: [Qwen3.5-4B official model card](https://huggingface.co/Qwen/Qwen3.5-4B).
[^3]: [Gemma 4 E4B official model card](https://huggingface.co/google/gemma-4-E4B).
[^4]: [Gemma 4 12B official model card](https://huggingface.co/google/gemma-4-12B).
[^5]: [NVIDIA Nemotron 3 Nano 4B official card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16).
[^6]: [Phi-4-mini-instruct official model card](https://huggingface.co/microsoft/Phi-4-mini-instruct).
[^7]: [LFM2.5-1.2B-Instruct official model card](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct).
[^8]: [Qwen3.6-35B-A3B official model card](https://huggingface.co/Qwen/Qwen3.6-35B-A3B).
[^9]: [Qwen3-Embedding-0.6B official model card](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B).
[^10]: [Qwen3-Reranker-0.6B official model card](https://huggingface.co/Qwen/Qwen3-Reranker-0.6B).
[^11]: [Prosus FinBERT code and license](https://github.com/ProsusAI/finBERT); [checkpoint card](https://huggingface.co/ProsusAI/finbert).
[^12]: [HKUST FinBERT project](https://github.com/yya518/FinBERT); [finbert-tone checkpoint](https://huggingface.co/yiyanghkust/finbert-tone).
[^13]: [FinGPT official repository and adapter/task inventory](https://github.com/AI4Finance-Foundation/FinGPT).
[^14]: [FinGPT multitask Llama-2-7B adapter card](https://huggingface.co/FinGPT/fingpt-mt_llama2-7b_lora).
[^15]: [Fastino-Nemotron-3.5-Lightning-Finance official card and evaluation](https://huggingface.co/fastino/Fastino-Nemotron-3.5-Lightning-Finance).
[^16]: [Community Fastino finance MLX 6-bit conversion](https://huggingface.co/nicolasembleton/Fastino-Nemotron-3.5-Lightning-Finance-MLX-6bit).
[^17]: [Fastino merge provenance](https://huggingface.co/fastino/Fastino-Nemotron-3.5-Lightning-Finance/blob/main/merge-provenance.json); [NVIDIA base model and license](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16).
[^18]: [Fin-R1 official model card](https://huggingface.co/SUFE-AIFLM-Lab/Fin-R1); [Fin-R1 paper](https://arxiv.org/abs/2503.16252).
[^19]: [PIXIU NeurIPS paper](https://proceedings.nips.cc/paper_files/paper/2023/file/6a386d703b50f1cf1f61ab02a15967bb-Paper-Datasets_and_Benchmarks.pdf); [FinMA checkpoint](https://huggingface.co/TheFinAI/finma-7b-nlp).
[^20]: [InvestLM official repository and restrictions](https://github.com/AbaciNLP/InvestLM).
[^21]: [BloombergGPT paper](https://arxiv.org/abs/2303.17564).
[^22]: [TradingAgents official repository](https://github.com/TauricResearch/TradingAgents); [research paper](https://arxiv.org/abs/2412.20138).
[^23]: [FinRL official repository](https://github.com/AI4Finance-Foundation/FinRL).
[^24]: [Qlib official repository](https://github.com/microsoft/qlib).
[^25]: [LightGBM official repository](https://github.com/lightgbm-org/LightGBM).
[^26]: [XGBoost official repository](https://github.com/dmlc/xgboost).
[^27]: [Chronos-2-Small official model card](https://huggingface.co/autogluon/chronos-2-small).
[^28]: [Chronos forecasting official repository](https://github.com/amazon-science/chronos-forecasting).
[^29]: [Kronos official repository and model table](https://github.com/shiyu-coder/Kronos).
[^30]: [TimesFM official repository and version-specific weight-license notice](https://github.com/google-research/timesfm).
[^31]: [Moirai-2.0-R-Small official model card](https://huggingface.co/Salesforce/moirai-2.0-R-small).
[^32]: [TiRex-2 official model card](https://huggingface.co/NX-AI/TiRex-2).
[^33]: [Toto official repository and version-specific capabilities](https://github.com/DataDog/toto).
[^34]: [Reddit: The 4B class of 2026 benchmark](https://www.reddit.com/r/LocalLLaMA/comments/1sxch39/the_4b_class_of_2026_benchmark/).
[^35]: [Reddit: Consolidating a homelab model setup](https://www.reddit.com/r/LocalLLaMA/comments/1s4p922/consolidated_my_homelab_from_3_models_down_to_one/).
[^36]: [Reddit: Backtesting LLMs and data leakage](https://www.reddit.com/r/algotrading/comments/1r3wzbv/backtesting_llms_discussion_about_data_leakage/).
[^37]: [Reddit: Lesson—always backtest](https://www.reddit.com/r/algotrading/comments/1srv5ks/lesson_always_backtest/).
[^38]: [Reddit: LLM-written backtests and timing leakage](https://www.reddit.com/r/algotrading/comments/1tpren4/letting_an_llm_write_your_backtest_check_for_this/).
[^39]: [Reddit: Qwen3.5-27B Q4 quantization comparison](https://www.reddit.com/r/LocalLLaMA/comments/1rk5qmr/qwen3527b_q4_quantization_comparison/).
[^40]: [FinanceBench paper](https://arxiv.org/abs/2311.11944).
[^41]: [FinBen paper](https://arxiv.org/abs/2402.12659).
[^42]: [Massive stock WebSocket quotes](https://massive.com/docs/websocket/stocks/quotes).
[^43]: [Massive Benzinga news](https://massive.com/docs/rest/partners/benzinga/news).
[^44]: [Massive Benzinga earnings](https://massive.com/docs/rest/partners/benzinga/earnings).
[^45]: [Massive Benzinga corporate guidance](https://massive.com/docs/rest/partners/benzinga/corporate-guidance).
[^46]: [Massive Benzinga analyst insights](https://massive.com/docs/rest/partners/benzinga/analyst-insights).
[^47]: [Massive Benzinga bulls/bears commentary](https://massive.com/docs/rest/partners/benzinga/bulls-bears-say).
[^48]: [Massive Benzinga product integration overview](https://www.massive.com/blog/build-a-real-time-financial-news-and-analyst-intelligence-dashboard-with-massive-benzinga).
[^49]: [Anthropic: Building effective agents, December 19, 2024](https://www.anthropic.com/engineering/building-effective-agents).
[^50]: [Anthropic: Effective context engineering, September 29, 2025](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents).
[^51]: [SQLite FTS5 and BM25 documentation](https://www.sqlite.org/fts5.html).
[^52]: [LM Studio parallel-request documentation](https://lmstudio.ai/docs/app/advanced/parallel-requests).
[^53]: [LM Studio MLX agentic-workload improvements, June 5, 2026](https://lmstudio.ai/blog/mlx-engine-agentic-workloads).
[^54]: [LM Studio speculative decoding documentation](https://lmstudio.ai/docs/app/advanced/speculative-decoding).
[^55]: [LM Studio structured-output documentation](https://lmstudio.ai/docs/developer/openai-compat/structured-output).
[^56]: [Anthropic: Demystifying evals for AI agents, January 9, 2026](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents).
[^57]: [Agentic Context Engineering research](https://arxiv.org/abs/2510.04618).
