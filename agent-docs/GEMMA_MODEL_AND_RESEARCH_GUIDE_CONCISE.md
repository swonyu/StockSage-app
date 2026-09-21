# Gemma in StockSage: model, evidence, and research

Prepared for **Saleh**

**Living edition 35 · Updated 21 September 2026, 05:08 Asia/Riyadh.**

This concise Mac guide covers how Gemma works in StockSage, which data reaches it, how picks qualify, and what remains unverified. Scanner-linked news is **implemented and verified offline**; **9861561 remains installed** with the SEC contact setting. Earlier evidence remains dated; the installation does not establish new model or market readiness. iOS and widgets remain on hold.

The PDF is limited to **20 pages including the cover and contents**. Detailed release history, stock case studies, source identities and verification receipts remain in the [full technical reference](../agent-docs/GEMMA_MODEL_AND_RESEARCH_GUIDE.md). The shorter guide preserves the important operating rules and limitations; it is not an investment recommendation.

### Start here on Mac

1. Save the Massive key in Settings and check source freshness before using a quote or result.
2. For Gemma, inspect the model connection in Library → Events & model setup, then explicitly run the desired research horizon.
3. For Micro cap or Large cap, load Stock screener’s daily ratios, pair Telegram, and enable each tracker. Recheck those controls after restarting.
4. Read the captured date, missing evidence and qualification status. Saved rankings and model labels do not automatically authorize a trade.
## 1. What the model names actually identify

This edition is dated **21 September 2026**. Section 13 separates historical checks from the current installation and UI verification; neither establishes new model or delivery readiness.

| Name | Meaning |
| --- | --- |
| Gemma 4 31B | Selected dense model, approximately 30.7 billion parameters. |
| `it` / QAT | Google's instruction-tuned and quantization-aware-training lineage; neither was performed by StockSage. |
| Q4_0 / GGUF | Selected four-bit deployment artifact, distinct from the upstream half-precision release. Caches and every tensor are not necessarily four-bit. |
| `google/gemma-4-31b-qat` | Application identity; a server advertising the name does not prove its weight bytes. |

The recorded artifact is `gemma-4-31B-it-QAT-Q4_0.gguf`, approximately **17.65 GB**, from a pinned community distribution. The historical inventory and remote hash checks identify that file; Google's releases establish its upstream lineage, not identical community-distribution bytes. Its advertised 256K context is not the application's serving budget. [Google instruction-tuned release](https://huggingface.co/google/gemma-4-31B-it), [Google QAT release](https://huggingface.co/google/gemma-4-31B-it-qat-q4_0-gguf).

## 2. Upstream training: what is documented and what remains unknown

Google's report describes web, code and image pretraining, a January 2025 pretraining cutoff, filtering, instruction tuning, post-training and QAT formats. The selected 31B variant supports text/images, not audio; StockSage research supplies **text only**. Filtering and quantization goals do not guarantee accurate financial reasoning or unchanged quality on every task.

The reviewed material does not disclose a complete reproducible recipe: every dataset mixture, optimizer schedule, reward stage and quantization-calibration detail remains unestablished. It does not establish stock-selection specialization. [Technical report](https://arxiv.org/html/2607.02770v2), [model card](https://ai.google.dev/gemma/docs/core/model_card_4).

**StockSage performs inference, not model training.** Downloading weights, replaying requests, retaining outcomes, calculating prices and supplying an earlier opinion do not update weights or create an adapter.

## 3. What StockSage adds at inference time

The app selects dated provider observations, calculates numerical references, assembles bounded evidence, requests an opinion, validates the response, applies independent qualification and preserves results—including failures.

Gemma receives supplied text; it does not collect provider data or operate a broker. Separate Astra cap modes use the restricted Codex boundary below. **All entry, stop, target and scoring arithmetic belongs to app code.** Model prose cannot override failed gates. Native acceptance, citation support, automated quality, strict qualification and profitable outcomes are different claims.

[Request and completion boundary](../StockSage/Sources/StockSage/StockSageLocalModelServer.swift), [evidence and validation](../StockSage/Sources/StockSage/StockSageAIAssessment.swift).

## 4. Local and hosted runtime contracts

| Route | Required boundary |
| --- | --- |
| Managed local Gemma | Loopback port 1234; verified LM Studio GGUF identity, unique loaded instance, serving context and one worker. |
| Managed hosted Gemma | Loopback port 18080 through a private SSH tunnel; canonical model plus verified serving properties. Processing occurs off-device. |
| Cap-mode Astra | `gpt-6-astra`, Ultra, through the owner's existing Codex subscription; separate from Gemma and API-key billing. |

Managed Gemma normally requests **16,384 context tokens**. Hosted fortnight requests containing an eligible prior require verified **24,576-token** capacity before transmission. Missing, ambiguous or undersized capacity blocks acceptance; no silent replacement model is used. A successful generation can still fail its bounded post-response capacity check; diagnostics preserve both stages.

The local loading preset can enable launch loading; preparation itself is not research. Quitting cancels work and attempts local unloading, but does not stop a remote pod. The completed hosted run used four workers, within the owner's maximum of sixteen, and the pod was stopped, not terminated, on 20 September. Previous permission does not authorize another paid run.

**Performance history:** the same twenty-four native-exported requests took **117.546 seconds** in the baseline replay and **67.876 seconds** with the selected four-worker cuBLAS profile, about **1.73× throughput**, short of the requested 4×. Replay excludes fresh gathering and app scheduling. Later paired native assessment-to-acceptance median was **8.954 seconds** for twenty-four observed replies, excluding earlier collection/queue work. Neither result guarantees complete-stock latency, quality equivalence or profitable decisions.

**Micro cap and Large cap are separate Astra modes.** Full setups retain common catalyst, liquidity, quote and scenario gates. Micro cap requires Nasdaq common shares, $50–300 million capitalization, float below twenty million shares, opening gap at least 10%, and time-matched RVOL at least 5× twenty prior sessions. Large cap requires at least $10 billion, with no ceiling, on eligible Nasdaq/reported-S&P listings; Micro cap float/gap/RVOL thresholds do not apply. Each setup scan details at most twenty-four candidates.

Enabled watching runs weekdays **11:00–23:00 Riyadh**, while the app is open and the Mac awake. Regular-session setup checks wait **150 seconds after the preceding cycle**. Separate five-second stream intake covers every dated eligible cap-group symbol, requiring twenty consecutive completed positive-volume minutes after admission/gaps and independent REST confirmation of prospective events. Coverage/detail rows differ; backlog, stale or missing data is not zero. Queues cannot guarantee every event is reviewed before its 180-second expiry.

Heavy momentum requires an absolute five-minute return of at least **3% for Micro cap or 1% for Large cap**, plus five-minute volume at least **3× the mean of the preceding three nonoverlapping five-minute windows**. Both upward and downward moves can trigger; these are unvalidated thresholds, not proof of institutions, a squeeze or a catalyst.

Heavy-momentum alerts and Astra reviews can occur during premarket within that window. They are descriptive: missing news, fundamentals and eligible quotes remain explicit; checks stay **unqualified with no trade levels**. Telegram observation and review-summary attempts are separately deduplicated; unknown delivery outcomes do not automatically retry.

Codex verifies authentication/configuration/catalog and restricts permissions/tools; it can inherit owner instructions, so this is not a context-free or zero-file-access guarantee. The app copies no OAuth credential. A synthetic adapter succeeded; installed stock Astra research and Telegram delivery remain unverified. On 21 September both trackers were restored, enabled, paired and paused before the 11 AM tracking window. [Codex boundary](../StockSage/Sources/StockSage/StockSageCodexResearch.swift), [watcher](../StockSage/Sources/StockSage/StockSageMicrocapMonitor.swift).

## 5. API-to-Gemma wiring: what can reach each request

Source wiring, successful access, facts offered after fitting and facts actually cited are separate evidence. A settings toggle or populated table proves neither model delivery nor use.

| Source | Where it reaches research |
| --- | --- |
| Massive directory/activity and adjusted daily history | All three Gemma modes; daily background is not intraday confirmation. |
| Massive completed minutes and eligible NBBO | Same-day and full cap setups; longer horizons use daily-close references. The live tape is not continuously streamed into Gemma. |
| Massive/Benzinga news, ratings, guidance and related products | Bounded public background; generic news can provide fallback excerpts. Analyst targets remain attributed opinions. |
| Dedicated forward earnings | Fresh horizon holding-window check, separate from board-cache earnings. |
| SEC submissions and fresh Form 4 observations | Research filing identities/dates and insider transactions; metadata links do not mean full filings were read. |
| DataHub/Wikipedia reported S&P membership | Multi-day and applicable cap selection, not an official index feed or direct opinion fact. |
| Massive fundamentals and SEC Company Facts | Full Astra cap setups and explicit Company quality; not automatically added to Gemma horizons, Chat or momentum-only reviews. |
| Yahoo / EODHD | Yahoo supports some board fallbacks, not dedicated horizon collection; EODHD is disabled. |
| Local WhatsApp excerpts | Optional Chat/manual individual-assessment leads, marked unverified; not collected by the three research gatherers. |

Chat uses selected symbols and its own bounded enrichment, not an entire universe scan. Broker/account/journal/credential fields are excluded from app-created research snapshots. User-entered text is a separate boundary; selected excerpts can leave the device with hosted inference.

Stock screener offers editable cap, P/E, ROA and debt/equity filters, with Micro cap and Large cap presets. Those display filters do not change the fixed cap-tracking qualification rules. Fifty displayed rows per page and twenty-four detailed setup candidates are separate from all-eligible-symbol momentum coverage.

**Scanner-linked news — verified offline; not installed:** **Open matched news → Load matched news** requests up to five selected excerpts within seven days for every financial/search match, beyond displayed rows. Four rolling symbol workers share the existing three-request HTTP limit. Adverse headlines remain; source/article dates, check times and per-symbol Coverage distinguish captured, partial, unavailable, pending and not-checked results. This is a bounded sample, not a complete news census. Filter/search changes and ratios reload invalidate the in-memory capture. No model assessment, watcher or trade starts. Morning briefing and richer live filters remain next-stage work; no macro calendar, live cumulative-volume input, paid Pro AI, squawk or Chat integration is added. [Matched-news source](../StockSage/Sources/StockSage/StockSageScreenerNews.swift).

Company quality preserves dated provider P/E, P/S, P/B, ROA, ROE and debt/equity. Annual app-calculated ROCE/ROIC require consistent, explicitly USD-tagged SEC inputs and valid capital denominators; they are not shareholder returns or automatic one-off adjustments. Missing inputs remain unavailable. The previous build's AAPL Company quality check on 21 September at 01:28:45 Riyadh explicitly showed **SEC returned HTTP 403** for both annual ROCE and ROIC. Successful Massive responses do not prove successful SEC calculations. The installed diagnostic update distinguishes rejected requests, timeouts, oversized responses and cancellation; unavailable values remain unavailable.

**Installed SEC contact setting:** a separate public probe at **21 September, 02:07 Riyadh** returned HTTP 403 with an undeclared-automated-tool page. The fallback header names a GitHub handle without an email; [SEC guidance](https://www.sec.gov/about/webmaster-frequently-asked-questions) documents an application name and contact email. This is not proof of the rejection's sole cause. Installed build **9861561** adds **Settings → Data sources → SEC contact email** on Mac. Save/Remove changes a local preference; typing and saving make no request. Valid saved contact is included in shared SEC headers on later requests; invalid or absent contact retains the earlier header. Reopen Company quality for a fresh check. The actual email stays outside code/PDF. No contact email was entered during installation checks; the owner deferred live SEC access verification.

**Annual formula boundary:** operating-income ROCE divides annual operating income by the opening/closing average of **assets minus current liabilities**. The ROIC proxy divides operating income after the reported effective tax rate by the opening/closing average of **debt and finance leases plus consolidated equity including noncontrolling interests, minus cash**. Consistent opening/closing balance dates are required; missing debt is not zero, and parent-only equity cannot replace consolidated equity. These measures are not normalized EBIT, TTM returns, sector rankings or forecasts.

[Public gatherer](../StockSage/Sources/StockSage/StockSageHorizonResearch.swift), [fundamentals](../StockSage/Sources/StockSage/StockSageFundamentals.swift). Missing, denied, stale or omitted data must never become “no news,” “no insider activity” or “no earnings risk.”

## 6. Evidence and output contracts

Facts retain stable keys, attribution, dates, availability and coverage gaps. Insider evidence means public reported transactions with source/date, role and plan disclosures where available; it does not provide secret information or authenticate a rumor. Packets record offered/omitted material and a digest; duplicate IDs invalidate them. Whole optional records may be removed during fitting; required records must fit or the request fails.

Every stock opinion has exactly **`action`, `reason`, `risk`, `evidence`**. Actions are Strong Buy, Buy, Hold, Avoid, Reduce or Sell. Evidence must contain existing unique fact IDs. Reason/risk are concise qualitative prose without numerical prices, dates, probabilities or scores. The default generation order is reason → risk → evidence → action.

Native checks reject invalid structure/types, references, prose and certain unsupported claims. Managed Gemma also requires expected identity, complete `stop` and serving-capacity verification. These finite checks cannot prove that a citation entails the claim or that the model interpreted it correctly.

Gemma uses temperature **0.2**, no pinned seed or `top_p`, non-streaming and requested non-thinking behavior. Initial output is **192 tokens**, with one eligible output-limit restart at **384**; explicit incomplete-check retry starts at 384 and may restart at 768. Recovery shares the original **90-second deadline**. Citation-format repair preserves the draft action/reason/risk. These Gemma budgets are not Astra settings.

Current evidence fits the unchanged 16K baseline first, reserving actual recovery output. Its 12,000-byte projection target and conservative fitting heuristic are not an exact-tokenizer guarantee. Saved profiles record actual context/output budgets and omission provenance. [Validation and fitting](../StockSage/Sources/StockSage/StockSageAIAssessment.swift).

## 7. Exactly how the three manual workflows differ

| Workflow | Evidence and output |
| --- | --- |
| Same-day | First twenty-four of up to five hundred Nasdaq selections; today's catalyst, completed minutes and eligible fresh quote; one qualified winner or blocker. |
| 1–7 trading days | Up to 1,500 unique eligible Nasdaq/reported-S&P stocks; daily evidence, deterministic five and separate strict comparison. |
| 7–14 trading days | Same selection ceiling, longer confirmation/target history; independent rankings and strict comparison. |

Selection ranks dated volume × VWAP, not financial merit. Unsupported exchanges, OTC, non-common shares and unverified currencies are excluded. Fresh reported membership is fetched without provider credentials; failure blocks combined selection. Captured membership provenance remains attached. Dotted symbols may be selected yet lack supported supplemental evidence, producing explicit no-opinion checks.

Same-day uses a captured ask entry ceiling, recent-minute stop and prior-window high target, with spread-adjusted reward/risk at least two. It requires sufficient regular-session minutes and today's usable catalyst. The selected winner receives a fresh quote check against frozen levels; failure does not silently substitute another candidate. Multi-day entry references are completed adjusted closes, not executable offers; code derives distinct daily stop/target windows. Longer lookbacks do not extend the holding horizon.

A same-day Buy must cite available recent completed-minute evidence and news/filing evidence published on the same New York date. At least thirty completed regular-session minutes are required; entry publication stops five minutes before regular close. The displayed current pick requires a final verified quote at most five seconds old. Candidate expiry is the earliest of background capture plus 300 seconds, minute evidence plus 180 seconds, or regular close minus 300 seconds. Display refresh does not renew captured evidence.

**Run Both processes each stock week first, checkpoints it, then assesses fortnight.** Only a natively validated week opinion can supply a prior; verified quality and passed strict gates are not required. It must match ticker, canonical model, selection, scan start and configuration. It preserves original prose, identity, quality and strict status—even unverified quality or failed strict gates. Separate quoted JSON makes it untrusted interpretation; current evidence remains authoritative and disagreement is allowed. Old citation IDs do not become current facts.

Current fitted facts/order/schema remain unchanged before adding prior context. Insufficient capacity or inability to fit a supplied prior blocks the request; it is not silently discarded. If no usable prior exists, independent fortnight assessment is allowed with a saved unavailable note. Format-only repair does not resend prior JSON. Prepared metadata alone is not proof of transmission or acceptance.

**Resume Both preserves each horizon independently**, including existing failures and completed-week ranking/time. It does not retroactively add priors to old checks or search unrelated historical runs. Comparison-only retry reuses captured checks; incomplete-check retry is separate. All 1,500 checks per horizon were preserved in the completed 20 September run; completion did not mean every check yielded an accepted opinion or strict pick. [Scheduling and prior admission](../StockSage/Sources/StockSage/StockSageHorizonResearch.swift).
## 8. Strict qualification and the two Top 5 paths

**An accepted model response, verified evidence quality and a qualified trade scenario are different results.** Native validation checks the response contract; it cannot establish that every conclusion is supported or profitable.

The week/fortnight strict screen requires an original Buy/Strong Buy and all applicable measured gates: verified identity, USD basis, access and timing; sufficient completed bars; close above SMA20; positive selected-horizon return; recent three-bar volume at least 1.5× the preceding twenty-bar average; and positive ATR14. Levels must satisfy `stop < entry < target`, reward/risk ≥2, stop distance ≤3 ATR, and target distance ≤3 ATR for week or ≤6 ATR for fortnight. Fresh earnings evidence must establish a date outside the holding window. An offered, cited catalyst must also qualify: news within 3/7 elapsed days or public insider filing within 7/14 elapsed days for week/fortnight respectively. Future timestamps fail; missing earnings timing does not mean no risk.

These are **unvalidated strategy assumptions**, not a probability or financial edge. App code supplies numerical references; Gemma and analyst targets do not set them. [Qualification rules](../StockSage/Sources/StockSage/StockSageResearchQualification.swift).

| Output | Meaning |
| --- | --- |
| Deterministic Top 5 | App scoring puts qualified candidates first, then usable nonqualified rows, preserving original actions and failed gates. At most five actual usable checks; no invented opinions. Historical return, confluence, catalysts, volume, freshness, insider evidence and penalties contribute to the score. |
| Strict model comparison | Gemma compares eligible candidates only. The accepted result contains `min(5, eligibleCount)` unique captured symbols. It can fail or have no eligible names; multi-round comparison is approximate and grouping-dependent. |

The deterministic ranking and scoring clock are saved independently of strict comparison. Refresh, retry or relaunch does not recompute them using today's time. Legacy missing rankings remain disclosed. A failed comparison never erases original checks or turns fallback rows into strict predictions. [Saved ranking](../StockSage/Sources/StockSage/StockSageTopFiveRanking.swift).

## 9. Buy, stop, target, and saved outcomes

Entry, stop and target are **dated app-calculated scenario references**, not fills, forecasts or orders. Stops cannot guarantee an exit price. Mac research shows the original entry separately from the captured daily close; missing entry stays unavailable.

In **Saved research**, **Review strict comparison picks** evaluates accepted comparison picks. **Review all saved opinions** processes up to **25 due accepted opinions per press**, including Hold/Avoid and nonshortlisted Buys; persisted attempt times prevent repeated early rows from monopolizing later batches. Rejected or incomplete checks remain visible without invented accepted outcomes. Both actions are manual and call no model or broker.

All-opinion records separate the next-session-open-to-seventh/fourteenth-session-close return from any valid original long scenario. A scenario can terminate before the full-horizon measurement completes. Hold/Avoid receives no invented directional win or short-trade interpretation. Missing sessions, unverified adjustments and changed access remain explicit; original checks, rankings and completed measurements are not overwritten.

New outcome policy 3 orders a known opening stop/target crossing first. If the open lies between the levels and the daily bar later touches both, it conservatively records stop first because intrabar order is unknown. Earlier policies retain their recorded semantics. These measurements use verified settled, split-adjusted observations; they are not realized P&L. [Outcome implementation](../StockSage/Sources/StockSage/StockSageResearchHistory.swift).

## 10. Persistence, privacy, and manual operation

| Record | Retention and limits |
| --- | --- |
| Horizon checks and outcomes | Originals have no automatic age/count/aggregate expiry; full-check archives and separate digest-bound all-opinion files have 48 MiB limits, with a 4 MiB run index. Limits fail saves rather than delete prior evidence. Unverifiable outcomes block combined export. |
| Diagnostics and interrupted captures | Inactive JSONL moves to permanent Archive storage before eviction from the 128 MiB/4,096-context hot index. Each context remains capped at 1 MiB, with text/response truncation at 24,000 bytes. Replaced checkpoints retain exact original bytes. Archival failure retains originals and blocks replacement. |
| Same-day and cap research | Saved receipts retain captured evidence, opinions and failures; save failure blocks publication. Descriptive momentum never acquires a fabricated qualified scenario. |
| Chat and temporary state | Sent history is locally retained until explicit clearing, within 2,000,000 bytes; requests use at most 24 eligible turns. Drafts, standalone screener/details, stream warm-up and event queues remain in memory. |

Permanent retention cannot recover previously deleted/truncated bytes or provide unlimited disk. Storage errors mean durability is unproven. Diagnostic prompts/replies can contain private text despite omitted headers and endpoint URLs. Future relaunches require renewed cap classification, explicit tracker enabling and stream warm-up.

**WhatsApp:** open **Library → WhatsApp messages** or the Chat button. Paste 1–2,500 characters with an exact ticker, set the actual original message date, and optionally supply a source label up to 300 characters. Saving preserves existing metadata and dates; invalid/corrupt storage is not replaced. The local store permits 10,000 messages/5,000,000 bytes. Retrieval offers at most three distinct matching texts from the last 30 elapsed days to Chat/manual individual assessment—not the three Gemma scan collectors. These are unverified excerpts, not instructions or authenticated sources. Saving does not connect WhatsApp or run a model. [Import contract](../StockSage/Sources/StockSage/StockSageResearchLeads.swift).

A later hosted request can transmit selected private excerpts, questions and conversation off-device; local inference still requires internet access for providers. Do not paste secrets. Gemma scans/outcome reviews remain manual. Separately authorized cap watchers may assess fresh events and send Telegram alerts; they do not enable orders or legacy paper automation. Telegram tokens use Keychain; pairing is private-chat and token-bound. Unknown delivery outcomes are not automatically retried.

## 11. Other model surfaces have different contracts

| Surface | Boundary |
| --- | --- |
| Chat | General analysis/evidence contract; old conversation is not current evidence. Number-bearing prose is an unverified draft. Context is clamped to verified runtime capacity. |
| Individual assessment | Separate explicit request and in-memory cache; a fresh quote does not refresh its captured opinion. |
| Catalyst explanation | Selected-server and Apple FoundationModels routes are distinct; Apple's model is not Gemma. |
| Headline sentiment | Positive/negative/neutral classification, not a recommendation. |
| Legacy paper helper | Preserved implementation does not authorize activation. |

## 12. Limits and how to interpret failures

| State | Interpretation |
| --- | --- |
| Missing/stale/unauthorized evidence | A gap, not absence of risk. |
| Rejected output or failed capacity verification | No accepted opinion; HTTP completion alone is insufficient. |
| No strict candidates | Inspect nonqualified rankings without treating them as Buys. |
| Historical result or older data after interruption | Read original dates; this is not a successful fresh scan. |
| Storage failure | Do not assume the result will survive reopening. |

The published trading calendar covers 2026; unsupported years remain unavailable. Daily-bar completeness can lag regular close. Semantic correctness, comprehensive API coverage, definitive earlier crash causality, a financial edge and a general 30-second guarantee remain unproven. A faster replay or valid JSON is not quality validation.

## 13. Existing tests and the verification boundary

| Current addition | Verification status |
| --- | --- |
| Scanner-linked news: verified offline | Full Mac gate: **3,224 definitions / 4,167 executions / zero failures / five skips**, direct exit 0 and unchanged source manifest. Native controls and narrow-layout captures passed; five excessive-window-count warnings remain in the full suite. Release/ZIP pending; no installation or live news access claim. Installed `9861561` remains separate. |

**Historical installed baseline, verified 20 September 2026.** Signed arm64 Release **92be0b2** passed **3,216 test definitions / 4,135 parameter executions / zero failures / five skips**, with build/test exit 0 and targeted native diagnostic guard 0. The source manifest matched before and after testing. Installation/reopening checks preserved **20 saved runs and 3,068 compared saved files**, preferences, IDs and the active record image.

**Previous installed build, 21 September:** reviewed code **d0e42cb** passed **3,217 test definitions / 4,146 executions / zero failures / five existing skips**, including the new SEC failure cases. Source hashes and the targeted native diagnostic guard passed. The 11-case regression failed on the old code before the fix. This improves diagnostics; installed SEC access still returned **HTTP 403**. Its signed Mac Release and ZIP passed verification. It was installed and reopened at **01:27 Riyadh**, preserving **20 saved runs and all 3,068 compared saved files**, checked preferences, IDs and the active record image. The full UI suite still logged excessive-window-count warnings also present in the earlier baseline.

**Current installed build 9861561:** the final full Mac gate passed **3,220 definitions / 4,163 executions / zero failures / five skips**, with unchanged source hashes and targeted native diagnostic guard 0. The request regression first failed against the old header. Native checks verified unsaved drafts, normalized Save, invalid-draft preservation, fresh-view reload and Remove using synthetic data. The signed arm64 Release build and extracted ZIP verification also passed. The suite still reported framework/compiler warnings. It was installed at **02:43 Riyadh** and reopened by **02:44 Riyadh**, preserving **20 saved runs, all 3,068 compared files, checked preferences, IDs and the active record image**. The SEC field passed installed accessibility and visual checks. The owner deferred live SEC access verification; no contact was entered.

The completed Gemma scans retained **1,500 checks each**, not 1,500 accepted opinions: week **1,475 accepted/25 incomplete**, one strict-qualified candidate and comparison pick BWIN; fortnight **1,436 accepted/64 incomplete**, eleven strict-qualified candidates but a failed comparison because complete candidate context could not fit. Both deterministic Top 5 records remain saved. Scan completion does not turn a raw Buy into a qualified setup.

On the previous build, the screener passed both cap presets, AAPL search and Company quality; both annual SEC metrics showed the explicit HTTP 403 reason. The current build reloaded daily ratios at **02:44:38 Riyadh**: **4,989 provider rows / 316 invalid / 3,680 supported listings**, with 526 Micro cap matches. Both trackers were restored, enabled, Telegram paired and correctly paused before 11 AM. Settings was closed after inspection; the main app remains open. This does not verify in-window readiness or event delivery. iOS/widget work remains paused.

Source review, offline tests, synthetic inference, installed UI, actual stock research and successful delivery are separate evidence. Targeted guard success does not establish absence of every framework warning.

## 14. Reproducibility checklist and remaining questions

Preserve original evidence and dates, offered/omitted/cited facts, model profile and raw attempts, validation/quality flags, strict policy, saved scoring clock, comparison protocol, numeric basis and outcome policy. Prior-context delivery requires its own transport record. Today's API responses cannot recreate yesterday's capture, and model text is not promised byte-identical.

Installed runtime **9861561** identifies the verified current Mac build; **d0e42cb** and **92be0b2** are historical. The quit flow reported model unloading unconfirmed, so successful unloading is not established. The [full technical guide](../agent-docs/GEMMA_MODEL_AND_RESEARCH_GUIDE.md) retains detailed receipts, source links and historical failures omitted here. PDF publication needs its own source/PDF-bound receipt and preserved previous copy.

Still unverified: live all-matching warm-up/gap handling, an installed stock Astra assessment, Telegram event delivery, and successful live SEC annual ROCE/ROIC calculations. Pairing is not delivery; a delivery test needs explicit approval. The completed Gemma scans and stopped pod do not prove prediction accuracy, final billing or storage disposition. No 4× speed, universal latency or profitability claim follows.
