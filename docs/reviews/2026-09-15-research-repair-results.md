# StockSage research and UI repair reconciliation

Status: source implementation and final native gates passed. Signed Mac packaging and installation verification are in progress.

Working branch: `codex/research-pipeline-fixes-20260915`, based on `61d37a2` (which adds the incoming research audit to `4a18b17`). Work stays in the isolated `research-pipeline-20260915` worktree. The installed app has not been replaced by this batch.

The owner's product choices are retained: Home first, NASDAQ-listed common stocks only, up to five accepted Buy/Strong Buy opinions per 1–7 or 7–14 trading-day horizon, and immutable saved predictions for later review. No intraday strategy, long-term mandate, broker submission, model activation or automatic repeat scan was added.

## Research findings

The rows below account for the incoming research audit's kept findings and overlapping claims. "Implemented" describes source changes, not predictive validation or an executed release gate.

| Incoming finding | Verified disposition and change |
|---|---|
| Forward earnings never reaches a research idea | Implemented a research-local forward check independent of board membership, preserving confirmed/projected and answered-empty/unavailable/not-requested distinctions. |
| Existing Benzinga earnings request asks for recent revisions | Kept that historical product for its existing consumers; research additionally uses the existing 400-day `date.asc` forward adapter. These are different questions. |
| Evidence depends on board membership without disclosure | Added dated, typed source coverage beside results and in the exact model context. Unique company feed checks remain visible as answered, stale, unavailable or unchecked. No invented coverage score. |
| Dot/dash/digit-bearing symbols still receive opinions without supplemental evidence | Kept broad listing/history parsing; withhold a research opinion when the supplemental contracts cannot handle the ticker. No guessed vendor transformation. |
| No SEC EDGAR evidence | Added bounded submissions metadata for five recent 8-K/10-Q/10-K/6-K/20-F identities and dates. Full filing contents are explicitly not retrieved or interpreted. |
| No tradability fact despite available volume | Added finite historical average close-times-volume, with sample count and dates. It is not a spread, position-size limit or fill guarantee. |
| No gap evidence despite available opens | Added historical absolute open-to-prior-close gap mean and maximum, with dates/count. It is not a future probability or stop-fill estimate. |
| Stale 30-day ratings comment | Corrected the comment to the existing 45-day policy. |
| Research ignores NASDAQ restriction | Filter XNAS before activity ordering and the 500-name cap. |
| ETFs take research slots | Require CS before ranking/capping; unknown instrument type does not pass. |
| Repeated product denials | Added short bounded 401 suppression with original subject/time and explicit recheck. 402/403 remain query-scoped; the audit's claimed subscription ownership and bill totals are unverified. |
| 2027 calendar failure blames credentials | Added an explicit unsupported-calendar error. No unverified Nasdaq dates were invented. |
| No eligible fraction/activity cutoff | Receipt shows selected count versus eligible observed names and lowest selected activity; distinguishes a cap cutoff from an uncapped selection. Selection does not mean completed research. |
| Duplicate directory abort blamed on Massive settings | Identical rows were already accepted; conflicting identities still fail closed. Corrected the generic explanation rather than weakening integrity. |
| Excluded records blamed on a seven-day rating window | Corrected aggregate eligibility/validation wording across chat and evidence presentation. Individual rejection causes are not retained. |
| Apple narrator context overflow missing | Added the explicit overflow explanation. A guessed Apple token budget is not imposed. |
| 12 KB context cap wastes a claimed precise capacity | The precise capacity claim is unsupported. Retained the conservative bound, mandatory status facts and whole-record fitting; concise research facts precede optional long excerpts. |
| Narrator still uses legacy four-bucket failures | Reused the existing detailed local-model cause map. |
| Journal time stop mixes elapsed and trading days | Added explicit completed Nasdaq-session counting for dated Nasdaq membership, elapsed days for crypto, and an unavailable basis elsewhere. No position-specific plan is inferred. |
| Both horizons have identical evidence | Independent old captures are not necessarily identical. Added a deliberate "Research both horizons" operation that gathers once per stock and makes separate sequential horizon requests. |
| Same ATR levels imply horizon-optimized targets | Retained the deterministic scenario formula and explicitly disclose that it is neither horizon-calibrated nor a reachability forecast. |
| One endpoint cannot distinguish week-one from week-two movement | New evaluations can retain a complete dated daily-close path and seventh-session/best/worst closes. Missing interior sessions keep an endpoint-only result with explicit missing path. |
| Horizon selection not persisted | Persist the last supported horizon; invalid values fall back safely. Explicit Home actions override it and clear old selection/search without starting research. |
| Outcome is a comparison with zero, not the market | Label results direction-only and state that no market comparison exists. Raw rose/fell/flat counts are not win rates or independent trade counts. |
| Completed outcomes vanish from Home | Added observed direction counts and recent pick outcomes to the daily summary. Saved history remains reachable. |
| Insider nil renders nothing | Added a neutral unavailable/not-checked message while retaining answered-empty wording and generation-owned loading cleanup. |
| Evidence panel collapses omission causes | Separate excluded, retained-cap and display omission counts. Do not label panel omissions as exact model-request omissions. |
| Exact offered Benzinga fact is unreadable | Display the captured F-numbered fact separately at readable size. Never reconstruct a historical prompt from newer data. |
| Research refetches a year despite disk cache | Generic disk cache lacks required adjustment provenance. Reuse the strict capture within a two-horizon operation; do not upgrade unverified cache bytes into research. |
| Both horizons duplicate a whole evidence pass | Addressed by the shared capture operation; each completed horizon retains its own saved run and cancellation boundary. |
| Metadata evicted by per-symbol page churn | Preserve fresh reusable metadata within the existing 500-page bound; metadata-only use still obeys LRU. |
| Network evidence not prefetched during model work | Not added: no observed timing evidence justifies extra concurrency. Shared capture removes the confirmed duplicate pass while keeping one model worker and bounded providers. |
| Throttling still sends evidence-free names to Qwen | Skip model work when nonempty supplemental attempts are all throttled/access-blocked and no usable news, forward earnings, SEC or company fallback was obtained. Valid empty answers remain distinct from failure. |

Additional defects found while implementing:

- New saved runs count seven/fourteen full sessions starting on the next trading date. Optional policy metadata preserves old pending schedules and every existing evaluated receipt.
- The forward earnings adapter now bounds response memory, rejects a mismatched response URL, and ignores the old unqualified 24-hour denial gate. Suppressed requests carry no invented provider-check time.
- A completed first horizon is retained and saved even when the last second-horizon request is cancelled. Late cancelled results are discarded.
- Explicit recheck of an earlier overlapping rolling-news query must replace its exact pending flight, without cancelling the other query.
- Mixed news fallback results remain partial, with the contributing check date. SEC acceptance time can precede the displayed filing date; publicly accepted metadata is not rejected merely because that date is the next business day.
- Captures are invalid after a backward clock crosses their final capture boundary or after credential/policy ownership changes.

Already-refuted claims remain refuted: stop after the first five combined opinions; widen every global SEC query; treat ATR as a day count; assume every denial proves an unowned account product; replace the validated duplicate guard; describe all missing rows as context trimming; or equate deterministic arithmetic with predictive skill.

Provider contracts used: [Massive All Tickers](https://massive.com/docs/rest/stocks/tickers/all-tickers), [Ticker Types](https://massive.com/docs/rest/stocks/tickers/ticker-types), and [Benzinga earnings](https://massive.com/docs/rest/partners/benzinga/earnings). These establish request/identity semantics, not the owner's present entitlements or model quality.

## Approved Mac appearance

The owner identified the afternoon 2026-09-14 Mac design in `StockSage-polished-home.png` and `StockSage-polished-research.png`, confirmed those two images, and asked to keep the improvements, the current iOS design, and the new Mac sidebar exactly as it is. The publication receipt ties that visual reference to `d9a6c23`. This supersedes conflicting visual recommendations in the incoming audit.

Mac Home now uses the reference's rounded charcoal panel treatment for due reviews and each horizon, with magenta capsule actions. The native sidebar, charcoal palette and page spacing already matched that build. Research keeps its native segmented picker, table and inspector; the added dual-horizon and history actions fit a compact adaptive header. New research content, saved outcomes, callbacks and qualification text are retained. These appearance changes are conditional on macOS, with iOS kept as approved.

## UI audit reconciliation

The incoming UI audit and eleven supplied screenshots were copied into this branch under `docs/reviews/`. Its claims were checked against current source and earlier native receipts; its proposed workstreams were not treated as instructions that override the owner.

| Area | Disposition |
|---|---|
| W8 stale setup/handoff documents | Stamp six obsolete agent documents as historical, preserve their bodies, add a review/documentation index and extend README's source map. Do not recreate obsolete helper files or manually add synchronized target members. |
| W0 visual infrastructure | Reuse the existing isolated native Mac/iPhone capture suites. Extend the phone matrix to actual Ideas, Heatmap and opened Ideas detail at standard and accessibility text sizes. The claim that no native UI/contrast tests existed was false. |
| W1 visible breakages | Reflow badges/chips and compact metric groups, separate phone Search from scrollable filters, expose primary scan action first, enlarge Heatmap tiles with text, and use a full detail sheet at accessibility sizes. The unchanged caveat is scroll-reachable rather than covering the entire viewport. |
| W2 type | Use matching Dynamic Type role anchors, a native relative panel heading, readable qualifiers and monospaced changing numbers. Numeric tokens were already private; a mass naming migration adds no user-visible correctness. |
| W3 color | Use the readable magenta foreground token for text/icons, neutral ink for base-size values, preserve the darker control fill, strengthen the low-contrast Avoid signal blocks, and delete unused duplicate/dead color components. The claimed universal perceptual threshold for card fills is unsupported; opaque charcoal surfaces remain shared. |
| W4 components | Reuse native adaptive layouts and existing metric/chip helpers. Remove the unused Card/Eyebrow shells rather than migrating dozens of unrelated surfaces into a new component layer. Disabled custom controls gain visible disabled state. |
| W5 caveat/product hierarchy | Remains owner decision work. No qualification is removed and neither AI nor technical rules is described as predictively validated. |
| W6 navigation, shortcuts and window minimum | Remains decision work. Home-first and existing routes/keys are preserved. |
| W7 rendering | Verify each alleged hot path. Reuse one filtered Ideas projection for header/board/export, avoid irrelevant symbol-list churn in a whole-market subscription key, use set identity for company-check symbols, and keep numeric transitions shorter than quote publication intervals. Diagnostics retain the latest raw report while limiting routine view notifications to once per second; failure changes and recovery notify immediately. Broader cost claims require measurements. |

## Verification and release status

Final source passed the native gates on 2026-09-15:

| Gate | Passed | Failed | Skipped |
|---|---:|---:|---:|
| Mac, `final-mac-spacing` | 2,530 | 0 | 1 |
| iPhone simulator, `final-ios` | 2,460 | 0 | 0 |

Xcode 26.6 (17F113), macOS/iOS SDK 26.5; execution on macOS 27 (26A428) and a task-owned iPhone 17 Pro simulator running iOS 27 (24A5423a). These are not Xcode 27 SDK or physical-iPhone release receipts. The canonical live/persistence/strategy measurement suites were excluded; the opt-in abrupt-child-death diagnostic was skipped. Tests ran serially with four build jobs.

Both gates recorded a SHA-256 manifest before building. The Release build checks those manifests against current source before packaging. Native Mac Home/Research were inspected at 900 and 1300 points, including their real navigation, saved results, inspector and controls. The screenshots caught a narrow-window Saved research button clipping issue; a native geometry regression failed before the Mac-only button-size fix and passed in the final full gate. iPhone research, Home, Ideas, Heatmap and an actually opened Ideas detail were inspected at standard and accessibility text sizes, including the scroll-reachable full caveat.

Initial failing regressions were executed for NASDAQ selection, full-session scheduling, evidence/narrator failures, metadata churn, denial policy, shared scans and forward earnings. Compiler/test-fixture corrections are recorded separately from behavior failures in the native logs.

No live provider account, model inference, broker, relay or owner prediction store is needed by the new tests. Synthetic tests verify software contracts; they do not establish forecast accuracy, present data entitlements, real-world speed gains or physical-device VoiceOver behavior.
