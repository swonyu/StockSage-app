# HANDOFF — StockSage-app (written 2026-09-06 05:55 +03, session fe29f7aa, Claude Fable 5.1)

## Connection probes belong to their request and settings (2026-09-07 07:11 +03)

N14/UI14 adjacent lifecycle fix. Manual and automatic probes previously wrote the
same result/spinner unconditionally after await. Behavior-preserving extraction
of those transitions into ConnectionProbeState gave a deterministic real-state
replay: `/private/tmp/stocksage-probe-freshness.LfMN6t/check` printed
oldReplyEnabledNewModel=true/newerRequestStillProbing=false, exit1. It also failed
--same-settings, --changed-before-start and --cancelled; --control (one matching,
uncancelled request) passed. The initial view regression was10pass/1fail.

Both callbacks now use the same small value-state boundary: each begin clears the
old result and owns a UUID; a superseded completion cannot publish OR clear the
newer's spinner. Current results/spinners match the selected settings even before
the next automatic task starts. Cancelled or settings-mismatched completions do
not publish. Task identity uses the existing settings array, not a delimiter-joined
string. Disappearance and automatic off/on-device selection invalidate state.
Manual Test connection still explicitly probes in those modes. Config is captured
before scheduling; probeServer takes it rather than rereading UserDefaults later.
All status text/color and Explain availability consume the filtered result.

All five replay modes now print `Connection probe freshness self-check ok`, exit0.
One regression covers old-before-new/old-after-new completion, same-setting overlap,
settings changes, cancellation, disappearance, successful control and nil config
(no I/O). Focused46/46 passed. Artifacts:
`/private/tmp/stocksage-probe-freshness-red-20260907.xcresult`,
`/private/tmp/stocksage-probe-freshness-green-20260907.xcresult`.
Final serial canonical macOS1771/1771 and iPhone17Pro(gate)1769/1769 passed,
exit0, zero selected failures/skips; same three opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Final bundles:
`/private/tmp/stocksage-probe-freshness-macos-20260907.xcresult`,
`/private/tmp/stocksage-probe-freshness-ios-20260907.xcresult`.

Tested Mac installed asPID24163; executable/debug-dylib cmp and strict deep
codesign passed. Previous app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-probe-freshness-20260907-0707.app`.
Native auto-probe and manual Test connection confirmed the saved local Qwen model
reachable/present with Explain available (AX plus populated screenshot). Offscreen
AX click scrolled the long list unexpectedly; native scrollbar setValue("0") and
small scrolls restored the viewport, then a visible coordinate click verified
the actual control again. No settings edits, synthetic UI responses or extra
Explain generations. Original QwenPID23631 unchanged. Races were replay-tested,
NOT forced by changing owner settings or slowing the real endpoint.

Inline review traced both callers and all three result consumers. This is request
ownership, not continuous server health monitoring or a wall-clock expiry policy.
No dependency, trade, push, credential access, cloud upload or model reload; main
worktree changes preserved and sibling task independently confirmed inactive.
Next bounded issue: Explain citation/number diagnostics (native PAA's unoffered
[1] currently surfaces as a financial-number failure). Semantic grounding,
independent API acceptance, full Chat and contract-gated P5 remain open.

## Explain facts retain quote source and market time (2026-09-07 06:57 +03)

N10/N14 bounded provenance fix. The shared narrator fact builder omitted the
quote provider and timestamp. A compiled production-module replay through
withLivePrice -> CatalystWatch.brief -> narrator.facts -> narrationRefreshReason
proved equal-price provider-only and timestamp-only changes incorrectly remained
current (both exit1); unchanged-input and price-only controls passed (exit0).
Harness: `/private/tmp/stocksage-quote-provenance.lO8RBo/check` (default,
--timestamp, --control, --price). Original regression24pass/1fail.

The existing shared fact builder now includes the source label and UTC market
timestamp with milliseconds, explicitly described as an observed snapshot, not
a live execution quote. Missing or nonfinite dates remain unknown; no scan-time
or wall-clock fallback. Both narrator backends and the existing freshness check
consume this line. The Original app facts disclosure is available for fresh as
well as stale results. No new model calls on ticks, cache, dependency or money
logic. All four original replays now print `Quote provenance self-check ok`, exit0.
Focused48/48 passed; regression covers all source alternatives, missing/invalid
metadata, unchanged inputs and subsecond/previous-day timestamp changes.
Red/green evidence: `/private/tmp/stocksage-quote-provenance-red-20260907.xcresult`,
`/private/tmp/stocksage-quote-provenance-green-20260907.xcresult`.

Final serial canonical macOS1770/1770 and iPhone17Pro(gate)1768/1768 passed,
exit0, zero selected failures/skips; same three opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Final gates include the disclosure change:
`/private/tmp/stocksage-quote-provenance-macos-20260907.xcresult`,
`/private/tmp/stocksage-quote-provenance-ios-20260907.xcresult`.

Tested Mac bundle installed asPID18562; executable/debug-dylib cmp and strict
deep codesign passed. Prior app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-quote-provenance-20260907-0651.app`.
One real native PAA Explain used the existing Qwen serverPID23631. Expanded
disclosure shows `Quote source: Massive SIP; market time: 2026-09-04T20:23:46.598Z`
and the not-live disclaimer (AX and populated screenshot inspected). Unsupported
[1] citation still leaves the full warned draft visible. No injected response,
owner-settings mutation, model reload, credentials, cloud upload, push or trade.
Main worktree's pre-existing changes remain untouched; sibling task stayed idle.

Inline review traced all four shared-facts callers and freshness publication.
This is millisecond snapshot identity, NOT nanosecond tick identity, wall-clock
expiry or semantic truth. Connection-probe settings freshness is the next bounded
lifecycle check; citation diagnostic ordering, semantic grounding, independent
API acceptance, full Chat and contract-gated P5 remain open.

## Explanation freshness includes request settings (2026-09-07 06:42 +03)

N14/UI14 bounded lifecycle fix. The generating-model label was ALREADY correct,
but the Catalyst Explain panel only compared fact strings; changing backend,
URL or model did not mark an old response stale. Diagnostic workflow first
extracted that existing display decision unchanged into narrationRefreshReason,
then exercised the production helper without changing owner preferences or
calling a model. `/private/tmp/stocksage-narration-settings.HJogxm/check`
reported settingsChanged=true/staleWarning=false, exit1; --control changed only
model-B back to model-A and passed. Regression9pass/1fail before the fix.

The panel now compares both original facts and the three request settings.
Stale text stays readable below "Previous explanation — not current", with an
Original app facts disclosure and its original numbered sources/model. It is
not relabelled as a fresh explanation. Footer wording says supplied facts
snapshot rather than facts above, which could now mean the changed live card.
Facts/settings/sources/result publish together after generation, not as partial
metadata before awaits. A settings change during source retrieval prevents the
pending call from silently using newly selected settings; a change during
generation leaves a stale snapshot. Cancellation clears the spinner via defer.
No new coordinator, dependency, request retry, model or persistent cache.

Original replay now prints `Narration settings freshness self-check ok`, exit0;
unchanged-settings control also passes. Test covers model, URL, all other backend
modes, missing metadata, changed facts and unchanged inputs. Focused47/47 passed:
`/private/tmp/stocksage-narration-settings-red-20260907.xcresult`,
`/private/tmp/stocksage-narration-settings-green-20260907.xcresult`.
Serial canonical macOS1769/1769 and iPhone17Pro(gate)1767/1767 passed, exit0,
zero selected failures/skips, same three opt-in exclusions (CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests):
`/private/tmp/stocksage-narration-settings-macos-20260907.xcresult`,
`/private/tmp/stocksage-narration-settings-ios-20260907.xcresult`.

Tested installed appPID13924; executable/debug-dylib cmp and strict deep codesign
passed. Normal quit initially met an open detail sheet; installer stopped before
any replacement, then normal sheet close/quit succeeded. Previous app recoverable:
`/Users/saleh/.Trash/StockSageX-pre-narration-settings-20260907-0639.app`.
Native PAA Explain at06:41 used existing QwenPID23631, no injected response:
failed-citation/numeric draft retained in full, prominent warning, exact generating
model and new snapshot footer visible in AX and a populated screenshot. Same
backend/URL/model settings confirmed; no owner settings or money inputs changed.
Live settings mutation and in-flight switching were NOT UI-smoked; settings
decisions use the isolated regression, async publication was reviewed inline.

This does not add wall-clock expiry, prove semantic grounding, or solve the
separate connection-probe freshness race. Next concrete review item: N10/N14,
quote provider/time are absent from narrator facts, so equal-price provenance
changes can escape fact-string invalidation. Primary AI, APIs and contract-gated
P5 retain their independent requirements. No push, real trades, credential access,
cloud upload or model reload; main worktree and stopped sibling task preserved.

## AI assessment checks selected evidence, not every offered fact (2026-09-07 06:26 +03)

N13 bounded source-grounding step. The primary badge parser displayed selected
F IDs but whitelisted numbers from ALL offered facts. A compiled production-module
replay with F1=AAPL revenue100 and F2=MSFT revenue200 accepted the false claim
"AAPL revenue200 (F1)" with evidence[F1]. Original replay exited1; changing ONLY
200→100 passed. The shared parser now checks numbers against selected facts and
requires inline F references to belong to the displayed evidence list. W references
remain bounded unverified group leads, never evidence or a numerical whitelist.
The prompt states the same contract; all six AI actions remain available.

Missing-evidence repair preflights other fields against all offered IDs WITHOUT
publishing those temporary IDs. Its one actual repair still has to pass selected
evidence validation and preserve the original action/reason/risk exactly. This
avoids falsely rejecting a legitimate quote from F2 merely because the old
temporary preflight used F1. Failed replies retain their original visible draft;
no bad record/badge is published, no extra repair for a four-key invalid reply.
No changes to rules, sizing, money, journal or execution paths.

Diagnostic/implementation workflow: regressions at parser AND real coordinator
failed first (10pass/3fail), then37/37 focused assessment/narrator tests passed.
The existing F13 citation fixture now actually selects F13; digit/reference and
private-group checks still pass. Original `/private/tmp/stocksage-grounding.GSpxE9/check`
now prints `Cited-fact numeric binding self-check ok`, exit0 (control also passed).
Artifacts: `/private/tmp/stocksage-cited-facts-red-20260907.xcresult`,
`/private/tmp/stocksage-cited-facts-green-20260907.xcresult`.
Serial canonical gates: macOS1768/1768 and iPhone17Pro(gate)1766/1766 passed,
zero selected failures/skips, same three opt-in exclusions (CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests):
`/private/tmp/stocksage-cited-facts-macos-20260907.xcresult`,
`/private/tmp/stocksage-cited-facts-ios-20260907.xcresult`.

Tested Mac bundle installed asPID9366; binary/debug-dylib cmp and strict deep
codesign passed. Previous bundle recoverable at
`/Users/saleh/.Trash/StockSageX-pre-cited-facts-20260907-0624.app`.
Actual auto-assessed PAA snapshot03:24:16Z rendered Buy, separate Rules Strong Buy,
with selectedF1,F2,F3,F4,F5,F6,F9,F14. Native AX and populated screenshot inspected:
50/200DMA,+16%,6months,ratio9 belong to citedF4;20.5% volatility to citedF5.
No injected response or extra generation request; original QwenPID23631 unchanged.
Account/risk inputs remained untouched. No push/trades/credentials/cloud upload.

Inline review traced both parse calls, repair, draft retention and evidence UI.
This is selected-fact NUMERIC MEMBERSHIP, not semantic entailment: a model can
still swap subjects/signs/units or values among multiple cited facts, or invent a
word-only claim. The older Explain numeric check still has its separate source
contract. N13 remains open for typed claim/source binding; no model-accuracy,
all-API, full-Chat or P5 completion claim. Main-worktree changes preserved.

## Explain retains failed output as an unverified draft (2026-09-07 06:08 +03)

Owner's explicit "never withhold" request also applies to the older Catalyst
Explain paragraph, not only the newer primary AI assessment. Both local-server
and on-device response paths previously discarded text/source and kept only a
withheld reason. Extracted their identical check into one real shared response
boundary, reproduced the loss, then replaced withheld with
unverified(text, generatingSource, reason). The existing UI renders the retained
plain/selectable text, a prominent failed-check warning, the generating model
label/caveats and the same numbered source list. It is NOT marked checked text,
promoted to app facts, or used to change primary badges, sizing or execution.
Unavailable transports/models remain unavailable; no fabricated draft/retry.

The tiny compiled production-module replay
`/private/tmp/stocksage-narrator-draft.sEJ9wn/check` exited1 with only a withheld
reason for an out-of-range citation. Changing ONLY[2]→[1] passed. After the fix,
the original input passes with exact text/source retained and a warning:
`Narrator visible-draft self-check ok`, exit0. No model/network/configuration
needed for this feedback loop. Regression covers both backends, foreign numbers,
out-of-range citations (where the number itself is a valid fact), and valid text.
Red23pass/1fail→33/33 focused narrator/view tests:
`/private/tmp/stocksage-narrator-draft-red-20260907.xcresult`
`/private/tmp/stocksage-narrator-draft-green-20260907.xcresult`.
Full serial macOS1765/1765, iPhone17Pro(gate)1763/1763 passed, exit0, zero
selected failures/skips; same three opt-in exclusions (CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests):
`/private/tmp/stocksage-narrator-draft-macos-20260907-0603.xcresult`
`/private/tmp/stocksage-narrator-draft-ios-20260907-0605.xcresult`.
Tested Mac bundle installed asPID5107; binary/debug-dylib comparison and strict
deep codesign passed. Previous app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-narrator-draft-20260907-0607.app`.

The diagnostic/implementation workflow fixed one shared result boundary rather
than disabling the guards in two backends. Numeric/citation checks still do NOT
prove semantic grounding, sign/subject/unit correctness or profitable analysis.
Existing changed-facts suppression remains; stale paragraphs are not silently
presented under new facts. This is Explain parity, not the full proactive Chat.
Native PAA Explain smoke at06:08–06:09 +03 used the EXISTING Qwen server/model
and actual app facts (no injected response). It generated an unoffered[1] citation;
the numeric check failed, but the complete paragraph remained visible beneath
"Unverified draft" with the exact local model path and caveats. Accessibility
text AND populated screenshot were inspected. This proves the real
request→shared-result→native-panel failed-check path, not improved semantic
accuracy or on-device FoundationModels generation. No response was rewritten.
No push, trades, key inspection, extra model, cloud upload, training or
main-worktree edits. Original QwenPID23631 unchanged; tested appPID5107.

## Pagination Store/UI acceptance completed (2026-09-07 06:07 +03)

Normal installed-app refresh (toolbar action, after the15-minute due window)
persisted answered Form4 observations for ALL nine former incompleteResponse
symbols at03:04:39–03:04:45Z. No cache editing/reset or synthetic timestamp.
Native CRWD card visibly shows5/5 current checks, a Form4 sale filedSeptember4,
and its expanded disclosure says Form4 checkedSeptember7 with one selected
event. This closes the request→parser→Store→UI acceptance gap recorded below.
The cache now has exactly two failures, SBLK/TEM conflictingTransactionDirection;
those source-data contradictions remain unresolved. No all-API/P5 completion claim.

## Company-event pagination implemented and live-replayed (2026-09-07 05:54 +03)

Actual CRWD HTTP200 response at02:41Z:149,572bytes/100rows plus next_url.
Offline replay failed incompleteResponse; removing ALL rows still failed;
removing ONLY next_url made the100 original rows pass. This isolated the
one-page coverage ceiling, not missing access or a malformed transaction.
Official continuation contract: https://massive.com/docs/rest/stocks/filings/form-4

The shared five-feed fetch now follows at most10 sequential pages,100rows/page,
2MB TOTAL, retaining the existing four-symbol Store concurrency. Each page
passes the same row/symbol/date/transaction validation. Only complete success
selects an event (latest, earliest upcoming for dividends). A later error,
oversize response, unsafe/repeated cursor or exhausted cap yields unavailable,
nil event, never a partial or checked-empty success. Single-response parse still
rejects continuation. Selection uses the same deterministic content tie-break.
Continuation requests reuse the MassiveTicks trust-boundary pattern: exact
HTTPS api.massive.com/feed path,443/default port, no userinfo/fragment/API-key
query, bounded URL length, header-only bearer, no redirects. Every production
page retains policy/cancellation/cooldown checks; cancellation after a response
also prevents publication. Probe stays status-only and one request.

Real installed-app fetches,02:51:17–02:51:32Z, all answered successfully:

| Symbol | Pages | Rows | Raw response bytes | Selected event |
|---|---:|---:|---:|---|
| CRWD | 2 | 139 | 207536 | yes |
| UTHR | 2 | 199 | 306269 | yes |
| NAVN | 2 | 136 | 228916 | yes |
| STX | 2 | 183 | 221196 | yes |
| CRNX | 2 | 103 | 213513 | no qualifying transaction |
| CBRS | 2 | 146 | 236072 | yes |
| FLYW | 2 | 111 | 265333 | yes |
| CHYM | 8 | 706 | 1748224 | yes |
| CLBK | 2 | 138 | 130246 | yes |

All real continuation URLs used the exact expected HTTPS host/path and only a
cursor query. Native fetch invoked through the app's Swift debugger context;
no key/header inspection or alternate credential path. Captured public pages
at parsePage, stripped request IDs and replaced cursor URLs with fixed markers.
Debugger detached/breakpoints removed. Private scratch:
`/private/tmp/stocksage-form4-pages.b8WfQx/{main.swift,check,capture.lldb}`.
`check --captured-pages` replays all24 pages OFFLINE, compares each entire
Observation against its native result (9/9 identical), prints
`Form 4 complete-pagination replay self-check ok`, exit0. Original one-page
`check` still exits1 intentionally; `--page-control` isolates the old guard.

Regression at the real injectable request/response seam:18pass/1fail before
paging,21/21 after. Covers all feeds, bad late rows/statuses, cursor security,
repeats,10-page completion/cap,100-row boundary, aggregate bytes/cancellation:
`/private/tmp/stocksage-form4-pages-red-20260907.xcresult`
`/private/tmp/stocksage-form4-pages-green-20260907.xcresult`.
Full serial macOS1764/1764 and iPhone17Pro(gate)1762/1762 passed, exit0, zero
selected failures/skips; same three opt-in exclusions (CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests):
`/private/tmp/stocksage-form4-pages-macos-20260907-0548.xcresult`
`/private/tmp/stocksage-form4-pages-ios-20260907-0550.xcresult`.
Tested Mac installed asPID98852; executable/debug-dylib comparisons and strict
deep codesign passed. Previous app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-form4-pages-20260907-0551.app`.

IMPORTANT acceptance boundary: the targeted live fetches do not write the Store.
At05:54 the ordinary app cache still has9 old incompleteResponse warnings from
05:48 checks, plus the2 genuine SBLK/TEM direction conflicts. Do NOT edit/delete
cache to manufacture success. Next verify the normal due refresh after06:03 +03,
then native Company feeds UI. Request/parser success is proved; new Store/UI
publication remains pending. Other API/Chat/P5 work is not declared complete.
Only coverage worktree changed; main files preserved, no push/trade/new model,
original QwenPID23631 unchanged. Inline review found no further blocker.

## Remaining Form4 validation failures are contradictory source filings (2026-09-07 05:32 +03)

SBLK and TEM do NOT have the prior security-spelling bug or a missing credential.
Two targeted read-only fetches ran through the installed app's own fetch path,
from its existing Swift debugger context. Captured only the public response at
the parser boundary (SBLK2,414bytes/2rows; TEM83,666bytes/48rows); removed request
IDs/cursor URLs, never inspected credentials. Debugger detached and all breakpoints
removed. No app settings, journal or cached observation was manually changed.

Offline original replay minimized each failure to one row: SBLK index1,
accession0002005037-26-000012, and TEM index46, accession0002113721-26-000016.
Both code the transaction S (sale) but label shares A (acquired). Changing ONLY
A→D makes the replay pass, but that control is NOT a correction authorized for
real data. The same S/A conflict appears in the primary filings themselves:
- SBLK: https://www.sec.gov/Archives/edgar/data/1386716/000200503726000012/xslF345X06/primary_doc.xml
- TEM issuer copy: https://investors.tempus.com/node/10586/html
- SEC interpretation233.03 says transaction codes and acquired/disposed labels
  must be consistent: https://www.sec.gov/rules-regulations/staff-guidance/corporation-finance-interpretations/exchange-act-section-16-related-rules-forms

Keep the rejection; do not invent purchase/sale direction or checked-empty status.
Added a fixed conflictingTransactionDirection failure category through the
existing response/cache/UI path instead of the unhelpful generic invalidPayload.
Unknown direction strings still get invalidPayload; no row/cap/entitlement bypass.
One regression pins P/D and S/A rejection, nil event, Codable preservation and
specific UI copy. Red17pass/1fail→focused18/18:
`/private/tmp/stocksage-form4-direction-red-20260907.xcresult`
`/private/tmp/stocksage-form4-direction-green-20260907.xcresult`.
`/private/tmp/stocksage-form4-remaining.MTlwKF/check --expect-conflict` also red→green
against BOTH untouched captured responses, keeping them unavailable with no
event. `--direction-control` is diagnostic-only; never writes the captured data.
The standalone harness loads no user configuration and performs no network I/O.

Full serial macOS1761/1761 and iPhone17Pro(gate)1759/1759 passed, exit0, zero
selected failures/skips; same three opt-in exclusions (CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests):
`/private/tmp/stocksage-form4-direction-macos-20260907-0530.xcresult`
`/private/tmp/stocksage-form4-direction-ios-20260907-0532.xcresult`.
Installed tested Mac bundle; executable/debug-dylib comparisons and strict deep
codesign passed. Prior app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-form4-direction-20260907-0533.app`.
Native SBLK expanded disclosure and screenshot show the specific conflict reason,
not generic validation or a missing-key message, and correctly retain4/5 checks.
Normal app refresh persisted conflictingTransactionDirection for TEM02:33:22Z
and SBLK02:33:24Z; cache now has exactly two conflicts plus nine incompleteResponse
failures. No cache reset or edit. Installed appPID94169, original Qwen unchanged.
The two source conflicts remain real unresolved data-quality failures, not API
successes. Next separate issue: the nine measured one-page/100-row limits.

## Form 4 live-schema mismatch fixed (2026-09-07 05:19 +03)

GILD was not missing API access: one bounded configured request returned HTTP200,
13,663 bytes and11 rows, but the production parser rejected seven rows. Live
`security_type` is `non_derivative`; the official Form4 docs say `non-derivative`:
https://massive.com/docs/rest/stocks/filings/form-4
Changing ONLY that field in the captured response made the replay pass. The
shared parser now accepts both exact spellings, still rejects unknown types,
and still excludes derivatives. No caps, credentials, retries, trading logic or
UI validation were relaxed. The diagnosing-bugs workflow isolated a provider
contract mismatch that the documentation-shaped fixture did not cover.

Evidence:
- `/private/tmp/stocksage-form4.vqNqtf/main.swift` and `check`: isolated compiled
  production-module request/response replay using existing app configuration.
  No key value/header was printed or exported. The private scratch capture keeps
  public filing data, strips request ID, replaces any pagination URL with a fixed
  marker, and freezes time. Offline original replay repeatedly exited1 with
  invalidPayload; field-only control passed. After fix the UNMODIFIED capture and
  all11 isolated rows pass, `Form 4 replay self-check ok`, exit0. This diagnostic
  is not itself native-consumer acceptance; that was verified separately below.
- Regression at the actual response→observation seam covers purchase/sale aliases,
  full event equality and unknown/derivative exclusions. Before fix16pass/1fail:
  `/private/tmp/stocksage-form4-red-20260907.xcresult`; after fix17/17:
  `/private/tmp/stocksage-form4-green-20260907.xcresult`.
- Full serial gates: macOS1760/1760 and iPhone17Pro(gate)1758/1758, exit0,
  zero selected failures/skips. Same three opt-in suite exclusions:
  CalibrationPersistRunTests, LiveUniverseVerificationTests,
  StrategyBaselineMeasurementTests.
  `/private/tmp/stocksage-form4-macos-20260907-0516.xcresult`
  `/private/tmp/stocksage-form4-ios-20260907-0517.xcresult`.
- Installed the tested macOS bundle; executable AND debug dylib comparisons and
  strict deep codesign verification passed. Prior app recoverable at
  `/Users/saleh/.Trash/StockSageX-pre-form4-fix-20260907-0517.app`.
- Native Catalysts GILD expanded disclosure/screenshot now shows5/5 current checks
  and a Form4 sale filed September2. App-owned cache independently records an
  answered Form4 check at2026-09-07T02:17:12Z. No manual cache edit.
- Normal installed-app refresh reduced Form4 invalidPayload285→2 (283 recovered).
  At05:19, SBLK and TEM still fail validation; nine remain incompleteResponse:
  CRWD,UTHR,NAVN,STX,CRNX,CBRS,FLYW,CHYM,CLBK. Do not label these empty/successful
  or assume the same cause. Diagnose those two payloads next, then the measured
  pagination ceiling. All other API acceptance and P5 remain open.

Only this worktree changed. Main's unrelated files preserved, no push/trade/new
model process; original Qwen PID23631 remains. Installed app PID88355. Temporary
debugger/probe attempts made no production edits; debugger detached, breakpoints
removed, and the offline replay above provided the actual red/green evidence.

## Demo-quote contamination and test-host isolation (2026-09-07 05:01 +03)

The "sample" header was NOT just a cosmetic label bug. The real quote cache held
902 entries: five sample rows (the exact startup seed set),35Yahoo,862MassiveSIP.
Sample quotes carried a fresh Date(), so the shared monotonic-clock guard rejected
genuine older market closes on those symbols. Full refresh preserved and cached the
demo rows; scan publication could copy their synthetic prices onto real histories.
The failure reproduces without XCTest, disk I/O or network; test pollution is not
required for this ordering bug. Unit-test hosts nevertheless had access to the real
default cache and launched the normal auto-refreshing Markets screen.

Fixed at shared seams, not by suppressing the source label:
- Quote/tick ordering now rejects explicitly sample incoming observations and
  ignores an existing sample clock when considering real data. Provenance flows
  through full/targeted/polled refreshes, streams, infraFX and scan publication.
  Genuine timestamp/sequence ordering and undated/future guards remain in place.
- Header clock/source selection excludes synthetic observations. The sample-only
  startup banner still exists; a mixed board cannot derive freshness from demos.
- Quote-cache extraction excludes samples; loading old contaminated files ignores
  only explicitly sample entries, preserving other values/dates and not rewriting
  on read. No manual cache deletion or price replacement was performed.
- Unit-test app hosts skip Markets startup and iOS telemetry/notification setup.
  Default quote-cache I/O is disabled under the existing test detector; explicit
  temporary-URL round trips remain enabled. This is not a claim that every other
  singleton/UserDefaults persistence path has been independently isolated.

Diagnosing-bugs evidence:
- `/private/tmp/stocksage-sample.9Pu3sd/main.swift`: fresh demo AAPL227.1 blocked
  real245 with a two-day-old timestamp, acceptedKeys empty, exit1. Removing only
  the demo timestamp made the control pass. After fix: real245/MassiveSIP accepted,
  `Sample recovery self-check ok`, exit0. Non-test default-cache access also passes.
- `/private/tmp/stocksage-sample-red-20260907.xcresult`:21pass/2fail before fix.
  Separate `/private/tmp/stocksage-sample-isolation-red-20260907.xcresult` failed
  the default-cache isolation regression before its guard. Focused57/57 green:
  `/private/tmp/stocksage-sample-focused2-20260907.xcresult`.
- Full serial gates: macOS1759/1759 and iPhone17Pro(gate)1757/1757, exit0,
  zero selected failures/skips. Same three opt-in exclusions (CalibrationPersistRun,
  LiveUniverseVerification, StrategyBaselineMeasurement test suites):
  `/private/tmp/stocksage-sample-final-macos-20260907-0456.xcresult`
  `/private/tmp/stocksage-sample-final-ios-20260907-0458.xcresult`.
  With the installed app normally quit, the owner's real quote-cache SHA256 stayed
  `58a4613c459e16c67dc2c246072b9a3ea449487aaf041d3ad75454c677e09bce` across both gates.
- Native normal launch after installation:902entries,864MassiveSIP+38Yahoo, ZERO
  samples. All five seed rows recovered through the normal provider refresh.
  AAPL/NVDA now have September4 market times; the three Saudi names September6.
  AX and screenshot show "Last quote · Yahoo · as of 6 Sep 2026 at 3:19PM" and
  amber "Last observed quote (not live)", replacing today's green sample stamp.
  M4 weekly consistency remains4.6Rnet/4.8Rgross. No sizing/alert/journal action.

Tested app installed at `/Applications/StockSageX.app`,PID83180; executable+dylib
comparisons and strict/deep codesign passed. Old app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-sample-fix-20260907-0500.app`; pre-recovery cache
copy at `/private/tmp/stocksage-sample.9Pu3sd/quote-cache-before.json` (outside git).
Original QwenPID23631 unchanged; no training, cloud upload, push or real trade.
Main worktree/pbxproj preserved. Next: remaining live per-route acceptance and
company-event/Form4 diagnosis, then model-news semantic checks/full Chat/P5.
Keep the existing15-minute same-task heartbeat; not overall completion.

## M4 — shared gross/net velocity horizon (2026-09-07 04:44 +03)

Fixed the full-review P1 where costs appeared to INCREASE daily/weekly returns.
Gross velocity already inflated hold time for variable absolute price moves;
net velocity, its actual ranking key, sized snapshots and turnover labels did not.
`velocityHoldDays(for:holds:)` now supplies that same positive, finite denominator
to all five paths. Weekly gross/net sums inherit it without changing their
same-basket/concentration contract. Fee numerators, short-borrow assumptions,
probability mapping and the existing dispersion heuristic are unchanged. This is
arithmetic consistency, not validation of a holding-time model or profitable edge.

Evidence from the diagnosing-bugs red/green workflow:
- Production-module replay: `/private/tmp/stocksage-m4.Dh1v2W/main.swift` (recompile
  against the current Debug dylib before running). Synthetic AAPL100/90/120,
  conviction1, spark[100,101,101,103]: gross .0222R/day, old net .03635R/day;
  same-stock weekly .111R gross versus .18175R net. Per-trade EV already fell
  correctly from .74R to .727R; constant-move control removed the mismatch.
  After fix: net .02181R/day, weekly .10905R, snapshot parity, exit0 and
  `M4 same-horizon self-check ok` (original exit1).
- Regression first failed on both actual ranking and the gross/net/cadence seam:
  `/private/tmp/stocksage-m4-red-macos-20260907.xcresult`, 4pass/2fail, exit65.
  Existing Jensen test previously checked only gross display, never rank order.
- Focused140/140, exit0: `/private/tmp/stocksage-m4-focused-macos-20260907.xcresult`.
  Covers uneven/constant/empty sparks, default/custom holds, sized and unsized
  snapshots, actual ranking and sized override, same-stock weekly sums, turnover,
  zero-cost primitive equality, unsupported classes and invalid hold inputs.
- Full serial gates: macOS1756/1756 and iPhone17Pro(gate)1754/1754, both exit0,
  zero selected failures/skips:
  `/private/tmp/stocksage-m4-final-macos-20260907-0441.xcresult`
  `/private/tmp/stocksage-m4-final-ios-20260907-0442.xcresult`
  Same three explicit opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Not live API
  acceptance or strategy-performance evidence. Only the known existing warnings.
- Native before/after AX and screenshots: main weekly net6.8R/gross4.8R becomes
  net4.6R/gross4.8R; fastest PAA net1.20 becomes .78R/day. 1080.SR detail now
  shows gross .221/net .180R/day, formerly net .265. Original account text and
  empty risk field left untouched; no copy, journal, alert or trading action.

Tested app installed as `/Applications/StockSageX.app`, PID76843. Executable AND
debug dylib comparisons and strict/deep codesign passed. Prior app normally quit
and preserved at `/Users/saleh/.Trash/StockSageX-pre-m4-20260907-0443.app`.
Qwen remains the original PID23631; no model reload/train/cloud upload. No pushes,
real orders or changes in the main worktree. Next: sample-header/test-cache
isolation, then remaining API/model-quality/P4/P5 work. Not overall completion;
the existing 15-minute heartbeat remains in this task.

## M8 — quantity-aware costs across sized decisions (2026-09-07 04:31 +03)

Fixed the reproduced minimum-fee disagreement without changing the fee table or
the model's opinions. DecisionSnapshot now sizes first, then derives net R:R,
net expectancy, net velocity, floor flag and cost-failure reason from ONE NetEdge.
Its gate rejects zero-share and non-positive sized expectancy; an unknown foreign
order size warns that minimums are unpriced. Missing FX still blocks, never 1:1.
Board/detail/CTA net displays and copied plans reuse that snapshot. Removed the
view-only invented $10,000/1% snapshot defaults. Unsized research ranking remains
the existing rules model; both Today's Plan ranking modes now apply sized costs
before top-N truncation. Gross fields remain labelled gross.

Single and multi-plan exports omit actionable terms for blocked rows. Allocation
and marginal-add checks re-evaluate costs at FINAL rounded shares after risk
limits. Rejected allocations leave their risk budget in cash, with named reasons;
no redistribution loop or new sizing strategy. Existing raw-quote-unit fee and
short-financing assumptions are retained and disclosed, not certified broker
tariffs. This does not establish that Derayah trading/API acceptance is ready.

Evidence:
- A standalone production-module replay in `/private/tmp/stocksage-m8.OzjDIX/`
  failed before the fix: one-share SAP.DE, entry100/stop95/target115, accountUSD600,
  risk1%, EURUSD1.1: snapshot2.773585R:R versus sized1.531646, CLEAR. Afterward it
  prints `M8 sized-cost self-check ok`, sized netEV0.648R and CAUTION.
- Stronger regression: SAP.DE100/99/103, accountUSD120, risk1%, EURUSD1.1,
  conviction0.9. Before: displayed2.076923 versus sized0.025641R:R, CLEAR despite
  costs. After: BLOCKED, netEV-1.672R, sized floor/ranking and status-only exports.
  `/private/tmp/stocksage-m8-red2-20260907.xcresult`: 9pass/1fail, exit65.
- `/private/tmp/stocksage-m8-focused3-20260907.xcresult`: 101/101, exit0. Covers
  size/FX changes, long/short financing, missing FX, zero shares, ranking max1,
  final-size allocation/add rejection and copied-plan parity. Initial test label
  typo and two integration compile errors were fixed before these passing runs.
- Native installed-build test at04:25: 1080.SR, temporary accountUSD10/risk1%,
  yielded1share, gateBLOCKED, netR:R-0.5 and netEV-5.70R, ~1204bps total estimated
  cost including minimums. Screenshot/AX verified; original account text and blank
  risk field restored. No journal, alert, real order or account connection made.
- Final broad gates, including the 64-bit share-count formatting regression:
  macOS1755/1755 and iPhone1753/1753, both exit0, zero selected failures/skips.
  `/private/tmp/stocksage-m8-final2-macos-20260907-0428.xcresult`
  `/private/tmp/stocksage-m8-final2-ios-20260907-0430.xcresult`
  Same three opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests and StrategyBaselineMeasurementTests. These runs
  do NOT claim live API acceptance or measured strategy performance.

The tested app replaced `/Applications/StockSageX.app`; old bundle recoverable at
`/Users/saleh/.Trash/StockSageX-pre-m8-20260907-0425.app`. Executable and debug dylib
comparisons plus strict/deep codesign passed. Original Qwen PID23631 unchanged;
no training, downloads or uploads. Main worktree/pbxproj untouched; no pushes.
Final formatting-only build installed after its macOS gate, process72465; the
preceding M8 bundle is recoverable at
`/Users/saleh/.Trash/StockSageX-pre-m8-format-20260907-0430.app`. Both binary
comparisons and strict/deep signature verification passed again. The one-share
native check above preceded only that 64-bit formatting correction.

Next: M4 gross/net projection horizon mismatch (still visible natively), then
sample-header/test-cache isolation and semantic news/model checks. Broker contract,
live per-route API acceptance, full Chat/iPhone serving and P5 remain open. The
15-minute heartbeat continues in this task; this is not overall completion.

## Final native research verification — 2026-09-07 03:57 +03

Final installed QCOM badge: **AI Hold**,03:55snapshot, RulesAvoid, exact4-bit
model ID, real news-source disclosure and3 private export leads. Visual screenshot
and AX both show the complete opinion, counter-case and provenance. AMZN03:47
and APP03:49 each rendered accepted Hold with3 private leads and news disclosures
in the preceding research build (only citation parsing changed afterward).
Quotes were dated September4, not live execution prices; no rating was forced.
Native main best-opportunity also showed PAA AIBuy versus RulesStrongBuy.

News-enriched QCOM exposed another false rejection: inline F13 was read as a
financial13 by the existing numeric tokenizer. Fixed in the shared assessment
parser, not in each view: validate F IDs against offered facts and W IDs against
the captured lead count, exclude only those identifiers from number comparison.
Unknown references and W-as-verified-evidence remain invalid. Regression was
9/10 passing and1 failed before fix, exit65. Final macOS1752/1752 and iPhone
1750/1750, exit0, same3 opt-in exclusions, zero selected failures/skips:
- `/private/tmp/stocksage-ai-inline-red-20260907-0349.xcresult`
- `/private/tmp/stocksage-ai-inline-final-macos-20260907-0350.xcresult`
- `/private/tmp/stocksage-ai-inline-final-ios-20260907-0352.xcresult`

Final install normally quit58374 and preserved that bundle in
`/Users/saleh/.Trash/StockSageX-pre-inline-20260907-0354.app`. Executable AND debug
dylib comparison and strict deep codesign passed; user data/settings preserved.
Qwen remains the original single process23631; no training or cloud upload.

Remaining quality findings are explicit: APP conflated different feed windows
with30days despite mechanical checks passing; QCOM repeats provider commentary
as fundamentals without an independent filing check. News often mentions the
target within another company's article. These are semantic/relevance evaluation
cases, not evidence of verified predictions. The main header still reports a
newer sample quote while these target quotes are genuine MassiveSIP; investigate
cache/test isolation separately, never manually rewrite caches to hide it.
M8 minimum-fee and M4 gross/net-horizon defects, all-route live API acceptance,
older narrator draft-display parity, full Chat/iPhone serving and P5 are still
open. Main worktree/pbxproj untouched, no real orders or pushes. Keep overnight
work in this one task; don't equate this feature release with overall completion.

## Primary Qwen assessments, news and private group leads — 2026-09-07 03:45 +03

Implemented owner02:19 Qwen-selected primary badges, then03:20 news/visible
drafts/private WhatsApp research. Separate AI records never mutate TradeAdvice
or sizing/EV/stops/execution. Shared Ideas/Catalysts/detail badges show AI action,
time and secondary Rules action; rankings, filters, widget and trade-plan exports
remain explicitly Rules-based. Global one-request ceiling, bounded top3 after
scan, selected detail and explicit Reassess; no per-tick model work or new server.
Existing news service supplies at most3 recent excerpts; failures/unknown dates
stay explicit. Exact model and fact/source disclosures are visible. Invalid model
output is a plain-text unverified draft, not hidden or promoted to a valid badge.
The older optional Catalyst narrator's withholding behavior is unchanged.

Both owner-provided WhatsApp exports imported locally:546messages(24+522),
private0600 index outside git, no source archive edits/extraction/upload/training.
Latest3 relevant distinct messages within30days are W-leads, outside F-facts and
the numeric whitelist. Sender/contact redaction is heuristic; identities/CFA
claims/performance remain unverified. Snapshot, NOT live WhatsApp. Timezone
Asia/Riyadh is explicitly assumed. Full limits/research references and refresh
instructions: `agent-docs/QWEN_RESEARCH_2026-09-07.md`.

QCOM root cause captured: valid three-key JSON omitted evidence. One format-only
repair preserves action/reason/risk exactly. The first real repair supplied four
valid references and hit an arbitrary three-reference cap; removed that display
cap, retaining offered-ID/uniqueness/size checks. Four-ID regression:8/10 passed,
2 failed on old code, exit65; final broad tests include both passing. Actual
original-response replay now exits0: Hold, original two sentences unchanged,
F3/F4/F5/F6. No retry-until-Buy, invented evidence or adjusted financial threshold.

Final gates: macOS1752/1752 and iPhone17Pro(gate), iOS26.5,1750/1750, both exit0,
no selected failures/skips. Same3 explicit opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests, StrategyBaselineMeasurementTests.
- `/private/tmp/stocksage-ai-citations-red-20260907-0340.xcresult`
- `/private/tmp/stocksage-ai-research-final-macos-20260907-0341.xcresult`
- `/private/tmp/stocksage-ai-research-final-ios-20260907-0343.xcresult`
- Earlier focused news/group tests67/67:
  `/private/tmp/stocksage-ai-research-focused-20260907-0333.xcresult`
- Local actual failure/replay harness and captured public facts:
  `/private/tmp/stocksage-ai-smoke.zpIGHz/diagnose.swift`, `QCOM-replay.json`.
- Importer `python3 tools/import_whatsapp_research.py --demo`: self-check ok.
Initial missing-interface tests failed at compile, not runtime. One mistaken
method-specific selector selected zero tests; it is NOT counted as passing proof.

Normally quit installed process48827 (close sheet before Cmd-Q), preserved only
the old bundle in `/Users/saleh/.Trash/StockSageX-pre-research-20260907-0346.app`,
copied the final tested macOS app to `/Applications/StockSageX.app`, verified both
executable and debug dylib byte-for-byte plus strict deep codesign, and opened it.
User data/preferences untouched. Existing Qwen process23631 remains unchanged.
Native final stock/source checks follow below. Main worktree untouched; no push
or real trades. Full Chat, secure iPhone serving, M8/M4 fixes, provider acceptance
and P5 remain open; green software gates do not establish a profitable strategy.

## Company-feed failure diagnostics — 2026-09-07 02:31 +03

Native GILD coverage showed four successful checks and an unavailable Form4
check; other symbols showed five. The specific cause is NOT established. The
shared request/parser previously discarded every failure, so this change retains
only a fixed typed category or HTTP status through Observation, disk Codable,
preflight sweep and the existing per-feed status line. No raw body, URL, header,
or localized error is retained. Valid-empty remains answered; pagination and
oversize responses remain unavailable with their existing limits, not partial
success. No new endpoint, retry, cap, timeout, credential access or UI screen.

New regression exercises13 failure cases, cache roundtrip, secret-like sentinel
exclusion, valid-empty and legacy records without the optional reason. The red
attempt failed to compile against the missing interface (zero tests ran), not a
runtime reproduction of GILD's failure. Focused16/16 passed; broad macOS1741/1741
and iPhone17Pro(gate)1739/1739 passed, exit0, no selected failures/skips. Same
three opt-in exclusions: CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Exact bundles:
- `/private/tmp/stocksage-api-reasons-red-20260907-0211.xcresult`
- `/private/tmp/stocksage-api-reasons-green-20260907-0218.xcresult`
- `/private/tmp/stocksage-api-reasons-macos-20260907-0223.xcresult`
- `/private/tmp/stocksage-api-reasons-ios-20260907-0230.xcresult`

Installed app still d4967a0; this diagnostics update is not installed yet. Main
worktree untouched. No pushes, actual trades or duplicate model/Stocks servers.
Owner02:19 requested Qwen set primary Buy/Strong Buy badges. Planned primary
AI assessment with model/data provenance, rules comparison, explicit missing/
invalid state, and unchanged deterministic risk/execution checks; not implemented
in this diagnostics commit. ORCL's live app cache already records confirmed
September10 earnings from Massive/Benzinga. Oracle's September2 official IR
announcement independently confirms September10,2026 after US market close.
No calendar/cache edit was needed; the date alone does not imply a positive return.

## Cited narrator provenance fixed — 2026-09-07 02:05 +03

Live SBLK/Qwen output reproduced a footer bug: any positive evidence count
discarded the backend/model captured on Result.text. Fixed the shared label
overload to append the listed evidence count to the existing source-aware label.
Generation, numeric/citation validation, and settings are unchanged. Singular
source wording is correct; zero/negative counts preserve the original label.

Revised the existing tests that pinned the generic footer; no new test suite.
The regression failed against the old implementation (22/23 passed, exit65),
then passed with the fix (23/23, exit0). Evidence bundles:
- `/private/tmp/stocksage-narrator-footer-red-20260907-0153.xcresult`
- `/private/tmp/stocksage-narrator-footer-green-20260907-0159.xcresult`
- macOS1740/1740, exit0: `/private/tmp/stocksage-narrator-footer-macos-20260907-0200.xcresult`
- iPhone17Pro(gate)1738/1738, exit0: `/private/tmp/stocksage-narrator-footer-ios-20260907-0202.xcresult`
Same three opt-in exclusions; no selected failures/skips in either final gate.

Quit the old installed process normally and replaced only the app bundle with
the tested macOS binary. Executable comparison and strict deep codesign passed.
Previous bundle is recoverable at
`/Users/saleh/.Trash/StockSageX-pre-footer-20260907-0204.app`; user data/preferences
were preserved. New installed process31018 observed. Qwen's existing loopback
server was left running; no duplicate server, new training, or real orders.
Owner02:02 reiterated every API must work: per-route native acceptance is next,
not a blanket success claim. Main worktree and other session remain untouched.

## Qwen converted and connected — 2026-09-07 01:50 +03

Owner01:41 approved the conversion/server startup that the previous note held
for approval. DONE: separate4-bit copy15.13GB,15shards,1847tensors; original BF16
untouched. Conversion exit0, measured4.76GB peak RSS, repeated saved-index checks
passed, overwrite attempt rejected. Added `tools/convert_qwen_mlx.py`, reusing
installed MLX loader/quantizer/writer, not installing/updating packages.

Server is RUNNING under the session-local launchctl job
`com.swonyu.stocksage.qwen-local` (PID23631), listener127.0.0.1:8765only. Native
StockSage Catalysts settings now use Local server only and exact model ID
`/Users/saleh/models/salehman-qwen38-27b-4bit`. Real model discovery passed,
synthetic stale-quote generation passed, and a real SBLK card rendered a
validated explanation citing Massive news. PAA's first response was withheld
by the unchanged numeric guard; that is recorded, not hidden as a success.

Full commands, limits, logs and stop/restart instructions:
`agent-docs/LOCAL_QWEN_2026-09-07.md`. No public/iPhone exposure, no automated
login/reboot startup, no trades, no cloud purchases. Do not start a second model
server or blindly relaunch conversion. Use launchctl remove for this exact job
when the owner requests unloading. Main worktree unchanged; installed app remains
the tested d7c84a0 build, not modified by these tooling/docs changes.

Remaining: per-route API acceptance; new Chat/proactive Qwen briefing; secured
iPhone serving; M8/M4 money-safety fixes and P5. Cited narrator footer omits model
name when sources>0 (header correctly shows selected local model)—follow up in
the shared label helper. No Swift changed this slice, so no redundant full build;
existing1740macOS/1738iOS gates still describe the installed app source.

## Owner-requested installed build replacement — 2026-09-07 01:36 +03

Owner01:34: open the new build and delete the old one. The active installed app
was a July28 executable, without the new API settings. Quit process18626 via
native Cmd-Q; verified no StockSage process remained before replacing anything.
Moved only `/Applications/StockSageX.app` to
`/Users/saleh/.Trash/StockSageX-old-20260907-0134.app` (recoverable; not purged).
Installed the existing tested macOS app from
`/private/tmp/stocksage-codex-m1b.qzpbNS/Build/Products/Debug/StockSageX.app`.
Executable cmp and codesign --verify --deep --strict passed. This is d7c84a0's
tested build:1740macOS/1738iOS, no new source changes or redundant builds.

Opened the new installed app, verified only process20169 running, and opened
Settings → Data sources. The existing saved Massive key appeared only as masked
secure text. Native Test connection returned:
`Connected — HTTP 200, AAPL snapshot parsed.`
No credentials were retrieved/revealed, no second socket/process deliberately
opened, no settings/portfolio/journal data deleted, and no model loaded. The
older PID11897 is no longer current. Main worktree remains untouched.

Separate01:32 presence-only shell check was denied again by PreToolUse; do not
retry or bypass it. Native snapshot testing is now possible and passed, so do
not keep calling every Massive route credential-blocked. Other endpoints still
require individual native verification; snapshot success is not add-on access,
store freshness, or live T/Q delivery proof. Updated API ledger holds evidence.
M8 tracing was paused for the owner's API/build request; no M8 edits made.

Owner01:37 additionally requested connecting all app AI features to Qwen. Local
inspection found `/Users/saleh/models/salehman-qwen38-27b/config.json` declares
Qwen3_5ForCausalLM/qwen3_5_text, bfloat16, no quantization config. No GGUF or other
quantized config found under the owner's models directory; no Ollama/MLX/vLLM
server process observed. Mac reports48GiB physical memory. Do not load the
51GB BF16 checkpoint directly. Quantization/server startup remains a distinct
resource decision under the owner's earlier save-RAM restriction; no conversion,
download, server startup, inference request or preference change performed here.

## N09 earnings API response classification — 2026-09-07 01:24 +03

Fixed the reviewed error/empty conflation without new network requests. The
actual EODHD parser reproduced it in a fast isolated CLI loop: a JSON error
object returned a non-nil zero-row list, which its fetch/chain treated as answered.
Unused networking/config dependencies were stubbed, not the parser. Red exited1
with `FAIL: malformed response became answered empty (0 rows)`; the same command
after the fix exited0 with `PASS: malformed unavailable, genuine empty answered`.
The final binary was rerun green after both platform gates.

Diagnostic-only command (run from this worktree; no key/network access):
```
xcrun swiftc StockSage/Sources/StockSage/StockSageEODHDCalendar.swift /private/tmp/stocksage-n09-repro.IskiBE/main.swift -o /private/tmp/stocksage-n09-repro.IskiBE/check && /private/tmp/stocksage-n09-repro.IskiBE/check
```

Yahoo's legacy fetch now delegates to its richer fetch. Both use the same
validated CalendarFetch outcome rather than wrapping a parser miss in answered.
The module container must exist and contain a single result without provider
errors. An explicit empty date list stays answered(nil); missing/partial ranges,
Boolean/non-finite/out-of-range epochs stay unavailable. Estimate flags require
an actual Boolean before a date can be called confirmed. Optional convenience
parsers delegate to this same core, eliminating the duplicated date extraction.

EODHD calendar/history and Yahoo history now return optional arrays: nil for
missing/error/partial, [] only for a valid explicit empty container. EODHD
calendar checks the requested symbol; date text round-trips to reject values
such as2026-02-30 instead of silently normalizing them. Date-field interpretations
and optional projections are unchanged; they are not newly live-verified.

Two new test functions and revised existing fixtures cover the real parsed
response→chain and refresh-stamp seams. Malformed replies cannot count as an
answered source or earn the24h checked timestamp; valid empties can. Old tests
explicitly encoding malformed-as-empty/partial-as-complete were changed to the
reviewed contract, with positive and genuinely empty controls retained.

Executed results, xcresulttool counts, serialized builds:
- Focused Earnings/EODHDCalendar/CatalystChain:56/56,exit0:
  `/private/tmp/stocksage-n09-focused-20260907-0121.xcresult`.
- FINAL macOS:1740/1740,exit0:
  `/private/tmp/stocksage-n09-broad-macos-20260907-0119.xcresult`.
- FINAL iPhone17Pro(gate),iOS26.5:1738/1738,exit0:
  `/private/tmp/stocksage-n09-broad-ios-20260907-0122.xcresult`.
All zero selected failures/skips, same opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. No compile correction required this slice.
All command handles finished; no temporary debug instrumentation in app source.

No liveAPI acceptance status changed: Yahoo429/SEC403 and authenticated access/
Derayah-contract blockers remain. Existing derived cache entries were not purged
or retroactively certified; prior malformed writes cannot be identified without
provider evidence and otherwise age through the existing TTL. No persistent
service, model load, retry-policy change, real order, unrelated worktree edit or
push. Work inline; other pipeline task verified unchanged/stopped at01:10.
Next is M8 sized minimum-fee/gate/EV/export consistency before P5 tickets.

## All-API acceptance audit — 2026-09-07 01:06 +03

Owner00:59 requires every integration to work. Reachable route/consumer/status
inventory and bounded live-probe evidence are in
`agent-docs/API_VERIFICATION_2026-09-07.md`. Six Yahoo chart/FX/calendar/history-
module GETs returned429; SEC ticker map with Disclosure's existing agent returned
403. No downstream SEC call, retry loop, proxy/header evasion, key access or
second socket. Default localhost Ollama discovery returned a transport error;
the owner's actual configured server and generation were NOT tested.

These probes used a small Python stdlib HTTP/JSON diagnostic, not the native
URLSession/parser/UI. Process exit0 only means the status collection completed;
it is explicitly NOT seven API passes. No payloads/keys/account details saved.
Massive/EODHD authenticated checks and the actual broker contract remain blocked.
The all-API requirement is not satisfied yet. Next independent API correction:
N09 malformed200→answered(nil), with regression at the response/chain seam;
then M8 minimum-fee/gate consistency before P5 tickets. No live order authority.

M9 code/tests were committed locally as60c8d3d before this read-only API audit.
No code changes since its1738/1736 canonical gates; audit changes are docs only.

## P5 prerequisite / M9 dated-FX checkpoint — 2026-09-07 01:01 +03

Completed the second M9 boundary on top of fd0ff0d. infraFX now retains an
existing StockSageQuote (price, marketTime, source), not a bare Double. A shared
resolver returns the selected rate WITH that observation's clock; known-source
rates within the existing72h app-planning ceiling take precedence, then newest
market time, then stable candidate order. Fetch time never establishes freshness.
USD remains identity1; sample, invalid/future timestamps, non-finite/non-positive
prices and unusable inverse conversions cannot become usable valuation rates.
New sizing additionally rejects old/undated/unknown-source observations.

The pure infra merge enforces the allowed symbol, matching payload symbol,
positive finite price and monotonic market clock. Empty/failed/rejected updates
preserve the last accepted observation without renewing its age. Undated first
responses remain unverified; valid incoming clocks can recover a corrupt future
stored date. Publishing checks cancellation and network policy after the await.
No extra request, timer, persistence format or dependency was introduced.

Every shipped size/plan/snapshot/allocator/detail/export caller still enters via
sizingFXRates, now requesting only eligible dated FX. Ordinary portfolio totals
can retain old/unknown rates with an explicit summary warning, and their rate-map
and missing-currency keys now use the same quote-leg currency as portfolioTotals.
The detached rate-age lookup is removed; a fresh inverse clock can no longer
validate an older direct price. Regression: USD100 risk /EUR10 stop distance
/EURUSD2 yields5 shares, selecting both the inverse rate and its actual clock.

Actual results (serialized xcodebuild; xcresulttool counts):
- Initial missing-interface RED compile failure,exit65,zero tests:
  `/private/tmp/stocksage-m9-dated-fx-red-20260907-0046.xcresult`.
- First implementation compile failed on a mixed numeric test array inferred as
  `[Any]`,exit65,zero tests. Fixed by typing it `[TimeInterval]`:
  `/private/tmp/stocksage-m9-dated-fx-focused-20260907-0050.xcresult`.
- Focused Currency+PositionSizer:40/40,zero failures/skips,exit0:
  `/private/tmp/stocksage-m9-dated-fx-focused-20260907-0051.xcresult`.
- FINAL macOS:1738/1738,zero selected failures/skips,exit0:
  `/private/tmp/stocksage-m9-dated-fx-broad-macos-20260907-0058.xcresult`.
- FINAL iPhone17Pro(gate),iOS26.5:1736/1736,zero selected failures/skips,exit0:
  `/private/tmp/stocksage-m9-dated-fx-broad-ios-20260907-0059.xcresult`.
  Same explicit opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Five new test
  functions, all build handles finished. Existing unused optimizer `lo` warning
  remains unrelated. Bundle suffixes are identifiers; xcresult records run times.

Scope limits:72h is a planning tolerance, NOT a verified broker FX quote. Legacy
journal-heat/valuation panels still need per-panel incomplete/stale disclosure
before becoming account-risk authority. MarketsRiskAllocationSection is preview-
only; its duplicate resolver was not changed or newly wired. No live provider,
populated new-build UI, model or broker-execution verification is claimed.

Owner00:59 added an explicit ALL-API acceptance requirement. The takeover plan
now tracks this independently of unit gates: real authenticated responses,
correct parsing/provenance and app behavior for every active route. Inventory
is in progress; existing credential-guard and missing Derayah-contract blockers
remain. No key access retry/bypass, local model load or real order was attempted.

Next: complete reachable API inventory and safe live checks, then M8 one coherent
quantity/minimum-fee-aware cost result for gate/EV/export before P5 tickets.
All work inline on wt/coverage; owner app/main worktree/credentials untouched.
No push.15-minute original-task heartbeat read back ACTIVE; good-spender OFF.

## P5 prerequisite / M9 missing-FX sizing checkpoint — 2026-09-07 00:37 +03

The shared sizer now represents USD explicitly as1 and missing/invalid foreign FX
as nil. Native stop-risk/notional units and pence conversion are retained. Finite
inputs that overflow derived notional/risk/account-percent no longer return an
unrenderable size. The view's duplicated plain-size fallback is removed, and its
direct/inverse FX resolver rejects non-finite/underflowed/overflowed conversions.

Snapshot, single Today plan and detail gate block missing FX. Ranked plans inherit
the block; Copy all now includes the failed-check reason, matching the rendered
and VoiceOver row. Detail sizing/copy and weekly-dollar qualifiers explain why
no size exists rather than pretending only account input or one-share flooring
is at fault. No return forecast or research edge was changed.

The allocator excludes missing-FX candidates BEFORE weighting/correlation/heat
allocation, reports sorted unpricedSymbols, and carries those omissions into the
visible and copied plan. It does not mislabel them as below the one-share minimum.
Retained (currently unwired) suggestAdd and optimizer helpers now use the same
currency-aware sizer. suggestAdd's existing symbol-less openTrades inputs must be
USD-normalized by callers; returned candidate amounts remain raw-native.

Regression evidence: the synthetic USD10,000 /1% /EUR100 entry /EUR90 stop case
returned10 shares without FX, although the supplied EURUSD2 fixture correctly
returns5. The shared-path regression additionally checks snapshot, single and
ranked exports, allocation, marginal sizing and the weekly-dollar warning.
Old tests explicitly pinning missing-SAR=USD were corrected to the reviewed
contract, not deleted. USD identity, actual SAR, pence, unknown suffix, FX quote
legs, invalid rates, minor-unit underflow and derived overflow remain covered.

Executed results (xcresulttool counts; serialized, no live provider requests):
- First narrow method selector executed ZERO tests despite exit0; discarded as
  evidence. `/private/tmp/stocksage-m9-fx-red-20260907-0024.xcresult`.
- Red full sizer suite:17 executed,16 passed/1 failed,exit65. The failing witness
  is the ten-share missing-FX fallback.
  `/private/tmp/stocksage-m9-fx-red-20260907-0026.xcresult`.
- Focused8 suites:212/212,0 failures/skips,exit0.
  `/private/tmp/stocksage-m9-fx-focused-20260907-0031.xcresult`.
- First broad macOS:1733/1733,exit0, before final Copy-all reason parity.
  `/private/tmp/stocksage-m9-fx-broad-macos-20260907-0031.xcresult`.
- FINAL broad macOS:1733/1733,0 selected failures/skips,exit0.
  `/private/tmp/stocksage-m9-fx-broad-macos-20260907-0034.xcresult`.
- FINAL iPhone17Pro(gate),iOS26.5:1731/1731,0 selected failures/skips,exit0.
  `/private/tmp/stocksage-m9-fx-broad-ios-20260907-0035.xcresult`.
  Same3 explicit opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests and StrategyBaselineMeasurementTests.
  All build handles finished; no compiler remains.4 new test functions overall.

M9 is NOT fully closed: infraFX still strips market timestamps, and the view's
age resolver is detached from the selected rate. Next fix keeps price/time paired
and withholds stale/undated/future/sample rates for NEW sizing; historical
portfolio valuation needs an explicit old/unknown-rate label instead. Numeric
validity is not freshness. Existing symbol-to-currency heuristics are not a
verified broker instrument contract. M8 sized-minimum-fee parity, P5 tickets,
actual Derayah integration and populated UI/provider smoke remain pending.

Work stayed inline on wt/coverage; owner app/main-worktree/credentials/model were
not touched, no new persistent services/workers/real trades, no push. The15-minute
original-task heartbeat was read back ACTIVE. Good-spender remains OFF. Xcode's
GUI rejection is recorded in the prior checkpoint; its command-line gates work.

## Pipeline 4 M6 company-event checkpoint — 2026-09-07 00:15 +03

Five Massive feeds now supply dated catalyst observations: Benzinga ratings and
guidance,SEC8-K,dividends and non-derivative Form4 P/S transactions. The new
provider/parser, versioned disk cache, native full-refresh/symbol-union task,
engine priority, card/calendar copy, source links and per-feed coverage are wired.
No trade decision/target/EV/ranking input was changed. Known/estimated urgent
earnings and urgent history projections precede the new reported events; the
other precedence/window details are in COVERAGE_DESIGN's M6 contract.

Unknown/malformed/partial/entitlement failures do not become checked-empty.
Successful daily records expire at UTC rollover; unavailable retries15min,
401/402/403 feed gates24h. Four-wide paced requests, one probe per due feed,
no new timer/dependency/socket. Atomic bounded cache survives relaunch and exposes
save failures; cancellation/generation guards prevent obsolete publication.
Guidance uses paired bounds (raised/lowered/equal/mixed/unknown), not a midpoint
guess or missing→withdrawn inference. Analyst targets retain their own basis and
opinion label. Form4 preserves transaction/filing dates, amendment/10b5-1 status,
and purchase-vs-private ambiguity. These are issuer-ticker-attributed records,
not a verified mapping to a particular share class or an aggregate insider book.
Past company reports go to Recently reported, not Today. SEC/Benzinga links are
HTTPS/host-validated; calendar VoiceOver includes provenance and caveats.
Changed brief facts suppress stale cached AI explanations; source caveats and
untrusted-text labels reach the optional narrator. No model was loaded or called.

Executed checks (serialized; xcresulttool counts, not log estimates):
- Red:1 test executed/failed,0 passed. Urgent projected earnings incorrectly
  followed volume. `/private/tmp/stocksage-m6-red-20260907-0003.xcresult` (exit65).
- First implementation compile failed, no tests executed: optional Item equality
  inherited MainActor conformance. Replaced nil equality with guard pattern matching.
  `/private/tmp/stocksage-m6-focus-20260907-0005.xcresult` (exit65).
- Focused:92/92,0 failures/skips,exit0.
  `/private/tmp/stocksage-m6-focus-20260907-0010.xcresult`.
- Final broad macOS:1729/1729,0 selected failures/skips,exit0.
  `/private/tmp/stocksage-m6-broad-macos-20260907-0011.xcresult`.
- Final broad iPhone17Pro(gate),iOS26.5:1727/1727,0 selected failures/skips,exit0.
  `/private/tmp/stocksage-m6-broad-ios-20260907-0012.xcresult`.
  Canonical broad exclusions remain CalibrationPersistRunTests,
  LiveUniverseVerificationTests and StrategyBaselineMeasurementTests (opt-in).
  Both build handles completed. All5 new SF Symbols also resolve via NSImage on
  macOS; this is an icon check, not a full populated UI inspection.

15 new tests include real contract keys, header-only auth, all5 copy/priority
pins,7/8d and14/15d and30/31d boundaries, numeric/partial failures, Form4 filtering,
source links, cache roundtrip/corrupt provenance, and changed narrator facts.
The new exhaustive grid covers3^5 feed states ×7 earnings states ×2 volume states
=3402 combinations; the independent157500-case legacy grid remains intact.
These are separate exhaustive domains, not a claimed Cartesian cross-product of
every old/new axis. No fixture test makes a network/key/Store.shared call.

Live entitlements/payloads and full populated UI remain unverified; the old
credential-access guard has no confirmed new state and was not bypassed/retried.
Owner requested Xcode GUI at00:04: normal app launch, explicit bundle launch and
native-app opening all failed; macOS reports kLSIncompatibleApplicationVersionErr
(-10664). Selected Xcode26.6 command-line builds still work on macOS27.0. No
installation/security changes were made. Existing owner app/binary/main-worktree
changes remain untouched. All work inline; good-spender OFF; no push or trades.
Next: P5 order core/tickets
against the approved V3 design, NOT the old script's silent rounding, guessed
broker schemas/scopes or permanent manual-only/Sahm restriction.

## Pipeline 4 M5b split-comparison checkpoint — 2026-09-06 23:29 +03

Open journal comparisons now require a complete dated Massive split check, then
rebase a disposable copy's entry/stop/target/shares together. Both urgent actions
and row P&L/R use that copy; original serialized journal, recorded fills, realized
accounting and calibration are unchanged. The source and multiplier appear in
the row and its explicit VoiceOver label. Two positions in one symbol now have
distinct action IDs. Invalid prices/terms cannot produce actions, nonfinite R
is withheld, and a crossed stop no longer falsely claims a realized loss.

Current `/stocks/v1/splits` API and execution-day semantics were checked against
Massive docs and its official Python SDK. New York execution-day entries are
already post-split, including premarket; only strictly later events apply.
Old/undated/future/pre-entry prices or marks predating an executed split withhold
comparisons. Shared equity freshness tolerance remains48h. Failure, partial or
ambiguous results remain unverified, not a negative corporate-action observation.
Ratio overflow, invalid dates, symbol mismatch and conflicting duplicates fail closed.

Only open covered US symbols are fetched, serially; native task cancellation and
generation guards reject obsolete sweeps. In-memory daily answers cover the
earliest open entry through today and expire at NY rollover or24h. No new timer,
dependency or owner-disk writes. Transient retry floor60s;401/402/403 gate24h.
One complete page/100-event ceiling; pagination withholds rather than truncates.
Full contract/budget and source links: COVERAGE_DESIGN's M5b section.

Closing limitation is explicit: never prefill a feed price unless verified
factor=1. A known non-unit split disables confirmation and preview in the old
close editor, pending explicit broker-basis reconciliation. Unknown-basis manual
closing remains available with an original-units warning and no quote prefill.
This is NOT split-aware realized accounting, cash-in-lieu handling, or support
for mergers/spinoffs/non-US corporate actions. Do not silently rewrite entries.

Verification (serialized builds; counts independently read with xcresulttool):
- Red:54 executed,52 passed/2 failed, exit65; invalid marks produced actions and
  the stop text claimed realization. `/private/tmp/stocksage-m5b-red-20260906-2315.xcresult`.
- First implementation build exit65 before tests: refresh-key Equatable inherited
  TradeRecord's main-actor isolation but was declared nonisolated. Removed that
  unnecessary isolation override; no changes to TradeRecord's conformance.
  `/private/tmp/stocksage-m5b-focus-20260906-2323.xcresult`.
- Focused:64/64, zero failures/skips, exit0.
  `/private/tmp/stocksage-m5b-focus-20260906-2325.xcresult`.
- Broad macOS:1714/1714, zero selected failures/skips, exit0.
  `/private/tmp/stocksage-m5b-broad-macos-20260906-2325.xcresult`.
- Broad iPhone17Pro(gate), iOS26.5:1712/1712, zero selected failures/skips,
  exit0. `/private/tmp/stocksage-m5b-broad-ios-20260906-2326.xcresult`.
  Same three explicit opt-in exclusions:CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests.

Hand-derived checks cover4:1,1:10, shorts, unchanged no-split math, multiple events,
NY same-day/premarket/UTC straddles, stale/missing marks, daily cache boundaries,
malformed/paginated data, overflow, header authentication, closing prefill gates
and byte-identical original record encoding. No network/key/Store.shared access
in these tests. Both platform handles completed; only docs changed afterward.

Live provider smoke and populated-screen/VoiceOver QA are still unverified; the
credential guard has no confirmed new state, so it was not retried/bypassed.
Owner app PID11897 and main worktree's unrelated files remain intact. No push,
orders, model load or new workers. Good-spender OFF per owner23:12 request.
Next M6: five endpoint contracts checked during the iPhone build; important
field-name/withdrawal corrections are in PIPELINE_TAKEOVER. No M6 code yet.

## Pipeline 4 M5 source-provenance checkpoint — 2026-09-06 23:03 +03

Prices now carry their actual parser/stream origin: Massive SIP, Massive daily
bars, Yahoo, Yahoo bars, dormant EODHD, or explicit sample. Optional metadata
survives accepted board/idea updates, off-board price retention, stream buffering,
history slicing and both cache round-trips. Older cache entries decode with
unknown origin; no owner cache/journal was migrated or rewritten by this work.
A newer unknown-source observation clears the old source, while stale/equal-time
unsequenced quotes cannot relabel an accepted price. Ordering rules, analysis
timestamps, stop/target levels and monetary calculations are unchanged.

Card price captions, signal rows and their explicit VoiceOver labels use actual
source plus market age. Global sample/cache precedence remains; cached known
sources stay visible. Future/nonfinite market times never read "just now".
The header/banner identify the SAME closeable-first observation (mixed providers
on an equal-time tie), not all901 names as live. Old intraday prices are called
last observed quotes, not incorrectly asserted to be the session close.

Shared macOS/iOS settings explain automatic Massive→Yahoo routing, delayed
fallback, local key storage/authenticated transmission, and the snapshot-only
scope of Test connection. No provider picker, credential-access workaround,
new networking/timer/dependency, purchase, risk-setting or model change.
EODHD quote retirement stays intact; residual news/calendar dependencies remain.

Code-derived budgets are corrected in COVERAGE_DESIGN:250-ticker snapshot chunks,
20-symbol rotating gap cap,30/60s foreground sleep with25s shared start floor,
900/1800s full sweeps plus separate monitor/manual/heal/FX/history traffic. The
old flat60calls/hour and one872-ticker request are not actual implementation.
An all872-name stream outage takes44 gap sweeps (~22min at ideal30s cadence plus
work time), not every name every30s. No rate/entitlement claim from live usage.

Verification (serialized builds; xcresulttool independently checks executed tests):
- Regression red:8 executed,6 passed/2 failed, exit65. Old formatter called an
  unknown-source observation Yahoo and a future observation "just now".
  `/private/tmp/stocksage-m5-red-20260906-2242.xcresult`.
- Focused implementation:75/75, zero failures/skips, exit0.
  `/private/tmp/stocksage-m5-focused-20260906-2255.xcresult`.
- Broad macOS:1702/1702, zero selected failures/skips, exit0.
  `/private/tmp/stocksage-m5-broad-macos-20260906-2258.xcresult`.
- Broad iPhone17Pro(gate), iOS26.5:1700/1700, zero selected failures/skips,
  exit0. Both platform build handles completed; no compiler remains.
  `/private/tmp/stocksage-m5-broad-ios-20260906-2300.xcresult`.
  Same three canonical opt-in exclusions:CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests.

The seven new pure tests cover provider parsing, accepted/rejected merge metadata,
scan retention, old/new quote/history cache reconstruction, real buildIdeas
publication and age/header text. They do not instantiate Store.shared or access
credentials, disk caches or network. Existing age tests now explicitly supply
Yahoo; expected minute/hour/day arithmetic is unchanged.

Live endpoint smoke and full populated-screen/VoiceOver interaction QA remain
unverified (see M4 credential-guard record). Owner app PID11897 and main worktree's
unrelated project.pbxproj/AGENTS/review files are preserved. The original-task
15-minute heartbeat is confirmed ACTIVE; no new tasks, push or actual trades.
Next:M5b split-basis guard. Both urgentActs and journalOpenRow call the shared
StockSageJournal.openActions; row P&L/R also compares against raw logged levels.
Use verified corporate-action evidence, not a price-jump heuristic; never rewrite
the owner's journal. Existing caution text is not a substitute for the guard.

## Pipeline 4 M4 news checkpoint — 2026-09-06 22:27 +03

Explain now requests Massive `/v2/reference/news` first, with the existing EODHD
news path as fallback only when no usable primary items are available. One
request per Explain, at most five articles within the preceding seven days,
newest first; at most one EODHD fallback request. No new timer, subscription,
pagination, dependency, model invocation trigger, or trading/ranking input.
The documented feed updates hourly, not live. An empty selection is never a
complete "no news" finding. Existing EODHD fallback budget:10 API credits/request.

Article ticker membership is required. Sentiment/reasoning must match the requested
ticker and a documented positive/negative/neutral label; missing/unknown/conflicting
insights are omitted. Provider/publisher, title, bounded excerpt, date and safe
link survive the actual NewsItem→CitedSource→prompt/UI path. Sentiment occupies
a second line under the SAME citation number, labelled provider commentary in
the UI. Both narrator backends retain the unchanged number/citation checks;
these are NOT semantic truth or predictive-edge checks. External source prose
is explicitly untrusted data, not instructions. No profitability claim.

Shared news boundary rejects future dates, invalid limits/windows and unsafe
links (non-HTTPS, userinfo, or URLs over2048 bytes). Titles/publishers/excerpts/
reasoning have whole-word budgets, avoiding truncated numeric tokens. Results
are deduplicated before limiting. Missing Massive status is allowed by its
optional schema; present non-OK/wrong-type status or malformed envelopes fall
through. HTTP200, external-access and cancellation checks surround requests;
redirects are disabled and Massive auth stays in the header. No secrets logged.

The source list now exposes publisher, excerpt and sentiment, even when narration
is withheld/unavailable. Prompt and UI share a POSIX/Gregorian UTC date formatter.
Native Link semantics remain; an explicit plain SwiftUI label fixed ImageRenderer's
unsupported native-link placeholder. The final actual component render at320pt
was inspected: `/private/tmp/stocksage-news-sources-320.png`. Synthetic component
QA only, not full populated-app, live-model or VoiceOver interaction verification.

Verified references:
- https://massive.com/docs/rest/stocks/news
- https://raw.githubusercontent.com/massive-com/client-python/master/massive/rest/reference.py
  (`list_ticker_news`: published_utc range modifiers and endpoint)

Verification (serialized xcodebuild; xcresulttool independently checked counts):
- Regression red:15 executed,12 passed/3 failed, exit65. Future date, unsafe link,
  unbounded snippet tests caught real existing defects.
  `/private/tmp/stocksage-m4-red-20260906-2156.xcresult`.
- First implementation build: nested Swift Testing #require macro in the render
  fixture failed compilation; no tests executed. Corrected before all passes.
  `/private/tmp/stocksage-m4-focused-20260906-2210.xcresult`.
- Focused:56/56 passed both before and after render/URL-budget hardening.
  `/private/tmp/stocksage-m4-focused-retry-20260906-2211.xcresult` and
  `/private/tmp/stocksage-m4-render-20260906-2223.xcresult`.
- Final macOS:1693/1693, zero selected failures/skips.
  `/private/tmp/stocksage-m4-broad-macos-20260906-2225.xcresult`.
- Final iPhone17Pro(gate), iOS26.5:1691/1691, zero selected failures/skips.
  `/private/tmp/stocksage-m4-broad-ios-20260906-2227.xcresult`.
  Same three canonical exclusions:CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests.

Live verification was NOT run. Owner authorized a credential retry at22:03;
PreToolUse denied the explicit presence-only check again. At22:09 the owner
removed the file-guard entry: hooks.json remained valid, but the active tool
guard still rejected access. The assistant changed no security configuration,
read no key, and attempted no alternate access path. Reopening the task/file
did not verify a guard reload. Do not infer key absence or entitlement failure.

Owner's running app PID11897/binary and main worktree's unrelated pbxproj/review
artifacts were preserved. No push, real trade, model load or new worker.
Next concrete stage: M5 quote provenance. `MarketsView.sourceTagLabel` still
hardcodes Yahoo and LiveQuote/StockSageQuote/StockSageIdea/history/cache do not
carry provider metadata. Fix that through accepted observations, not by guessing
from a configured key. Keep the approved Massive→Yahoo route; do not resurrect
the old script's EODHD picker or claim the residual EODHD dependencies are gone.

## Pipeline 4 M3 earnings checkpoint — 2026-09-06 21:46 +03

`StockSageMassiveEarnings` now precedes EODHD calendar → Yahoo → history projection
in the existing per-symbol chain. It uses the documented `/benzinga/v1/earnings`
with ticker, date.gte/date.lte, date.asc and a100-row cap over400 days. Dates use
UTC calendar-day precision (including today until midnight), not an invented
release time. Only date_status sets confirmation: confirmed=true, projected=false.
A provider estimate is still a calendar observation with the existing estimated
suffix; it is NOT the app's distinct history-derived .projected record.

Malformed envelopes/rows/statuses/dates, mismatched symbols and partial pages are
unavailable, not checked-empty. Empty valid responses remain answered(nil).
Conflicting statuses on duplicate same-day rows cannot upgrade confirmation.
One status-only probe precedes a US earnings sweep;401/402/403 from either that
probe or a later query suppress this provider for24h, persisted locally. Other
failures do not claim an entitlement rejection. Header-only auth, redirects
disabled, external-access/cancellation gates checked before and after requests.
Existing per-symbol24h answer TTL, fallback order and four-wide sweep remain.

The catalyst card now receives the actual chain source instead of hardcoding
Yahoo. Its general caveat also names the attributed calendar provider. Unknown
provenance is explicit in the real view. No new model inference or order path.

Verified references:
- https://massive.com/docs/rest/partners/benzinga/earnings
- https://raw.githubusercontent.com/massive-com/client-python/master/massive/rest/benzinga.py
  (list_benzinga_earnings: date range modifiers and endpoint)

Verification, serialized canonical xcodebuild tests:
- Initial red build: missing provider/chain/input interfaces, exit65; NO tests
  executed. `/private/tmp/stocksage-m3-red-20260906-2139.xcresult`.
- First implementation build: three Swift Testing nested-try fixture errors,
  exit65; NO tests executed. Fixed before all following passes.
- Focused **103/103**, zero failures/skips:
  `/private/tmp/stocksage-m3-focused-retry-20260906-2141.xcresult`.
  One additional empty/stale-first-source fallback test added afterward.
- Final broad macOS **1,681/1,681**, zero failures/skips among selected tests:
  `/private/tmp/stocksage-m3-broad-macos-20260906-2144.xcresult`.
- Final broad iPhone17Pro(gate), iOS26.5 **1,680/1,680**, zero failures/skips
  among selected tests: `/private/tmp/stocksage-m3-broad-ios-20260906-2145.xcresult`.
- Same three opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Counts checked
  with xcresulttool. Existing unrelated compiler warnings remain. All handles done.

M2b live smoke remains pending: the credential-access hook blocked even a
key-presence check at21:32. No key was read; no guard was bypassed. This is NOT
evidence of a missing key or rejected Massive entitlement. No live probe was run.
Full populated app/VoiceOver QA is also pending; the owner app/binary was not
replaced or relaunched. No model job, real order, push or main project.pbxproj edit.
Next independent stage: M4 news/insights and cited narration, then remaining
M5/M5b/M6/P5/Chat/Derayah work and final integration. M3 is code/test-complete,
not live-verified. Current request budget supersedes the earlier one-call/day
proposal: see the implementation note in COVERAGE_DESIGN_2026-09-06.md.

## Pipeline 4 M2b compact-card checkpoint — 2026-09-06 21:29 +03

US idea cards now show the existing coalesced bid/ask observation: prices, share
sizes, Massive SIP attribution, absolute SIP time, bid/ask venues and observed
spread. The SAME copy is included in the card's overriding VoiceOver label.
Unknown venue IDs remain explicitly unknown until the shared exchange reference
resolves; reference loading reuses the stream's existing startup task and the
24-hour reference cache. No per-card request, socket or timer was added.

The strip deliberately says "last observed, not a fill quote", not "Live". It
does not claim a displayed historical spread is cost-eligible. Existing money
callers still use spreadBps(at:), with five-second freshness and condition
qualification unchanged. One-sided, locked/crossed, zero-size and invalid-number
books do not display a computed spread; a missing book says costs are estimated.
Tadawul cards are unchanged.

Verification (serialized xcodebuild, independently read xcresulttool summaries):
- Focused macOS: **11/11**, zero failures/skips, before the venue-label addition:
  `/private/tmp/stocksage-nbbo-compact-focused-20260906-2120.xcresult`.
- Final broad macOS: **1,672/1,672**, zero failures/skips among selected tests:
  `/private/tmp/stocksage-nbbo-compact-broad-macos-20260906-2124.xcresult`.
- Final broad iPhone17Pro(gate), iOS26.5: **1,671/1,671**, zero failures/skips
  among selected tests:
  `/private/tmp/stocksage-nbbo-compact-broad-ios-20260906-2127.xcresult`.
- Same explicit opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. The extra Mac
  test renders the actual compact component at320pt via ImageRenderer. Inspected
  `/private/tmp/stocksage-nbbo-compact-320.png`: all four lines visible. This is
  component-only QA with synthetic data, NOT full populated app/VoiceOver QA.

All build handles completed. git diff --check is clean. No live authenticated
smoke, real order, model job, push or change to the owner's running app binary.
M2b's remaining verification is populated UI and authenticated provider smoke;
then M3–M6, P5, approved Chat/Derayah work and final integration. Main
project.pbxproj and its unrelated work remain untouched.

Owner asked why the goal looks stalled at21:27. The product goal record is still
marked blocked from earlier, but the separate overnight heartbeat was verified
ACTIVE/every15minutes in this task. That stale goal status does not describe this
implementation checkpoint. Available goal tools cannot resume/reset that status;
do not falsely mark the whole objective complete to remove the badge.

## Pipeline 4 M2b trade-ordering checkpoint — 2026-09-06 21:13 +03

Same-millisecond trades now retain Massive's exact64-bit `q` through the parser,
authenticated StreamState,500ms Store buffer, board/idea merge, scan publication
and quote-cache round trip. Only a strictly larger known T-channel sequence for
the same symbol can break a timestamp tie. Quotes keep their independent Q
sequence. Later timestamps win even when sequence resets; unsequenced later
polls clear old metadata, and legacy caches decode to unknown. No sequence is
invented from a timestamp, price, provider arrival order or another channel.
Stop/target, advice and analysis time remain unchanged by live-price replacement.

The shared ingress also fixes a second regression: taking max(boardTime,ideaTime)
let a corrupt future value mask a valid clock, allowing an older price to replace
both. Each existing observation is now checked independently before accepting a
tick/merge. Quote symbols must match their dictionary keys. Existing undated and
future-time fail-closed rules remain; unknown equal-time provenance stays blocked.
Protocol: https://massive.com/docs/websocket/stocks/trades (`t` milliseconds;
`q` increasing, per-ticker, gaps permitted). This is last-trade ordering, not a
new trade-condition/execution-eligibility policy.

Verification, serialized canonical xcodebuild tests:
- Red: both new regression tests failed against the old code, exit65,
  `/private/tmp/stocksage-sequence-red-20260906-2104.xcresult`.
- The first expanded attempt failed compilation on a test tuple inferred as
  Int rather than Int64 and executed no tests; explicit fixture typing fixed it.
- Focused **42/42**, zero failures/skips:
  `/private/tmp/stocksage-sequence-focused-retry-20260906-2107.xcresult`.
- Broad macOS **1,670/1,670**, zero failures/skips among selected tests:
  `/private/tmp/stocksage-sequence-broad-macos-20260906-2109.xcresult`.
- Broad iPhone17Pro(gate), iOS26.5 **1,670/1,670**, zero failures/skips among
  selected tests: `/private/tmp/stocksage-sequence-broad-ios-20260906-2110.xcresult`.
- Same explicit opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Counts were
  independently read with xcresulttool; no live provider success is implied.
  Existing compiler warnings in allocation/EV and Massive timestamp fixtures remain.

All build handles completed. No live smoke, new-branch populated visual QA,
actual order, model job, push or change to the owner's running app binary.
M2b still needs compact cards and visual/authenticated smoke, followed by M3–M6,
P5, approved Chat/Derayah work and integration. Main project.pbxproj stays untouched.
The owner's ORCL question was answered from their existing running app: no idea
or directory match, with action=All and Any signal strength. This was observation
of the OLD app, not new-branch QA. The baked universe membership restriction in
StockSageQuoteService excludes ORCL; no universe policy was changed or scan run.

## Pipeline 4 M2b measured-cost checkpoint — 2026-09-06 20:43 +03

Current EV/ranking, allocator cost gates, decision snapshots, Today plan and
Markets card/detail/copy/ledger paths now select costs from the SAME idea NBBO.
Qualified fresh US spreads can only raise the existing8bps spread floor. The
full quoted width represents both half-spread crossings; slippage, fees and
per-order minimums are unchanged estimates. Historical backtests, paper candle
simulation and journal slippage benchmarks still use their original defaults.
The shared idea net-RR helper also includes short financing on cards, matching
the detail/ranking path that already included it.

Eligibility is deliberately narrow: one bounded, header-authenticated reference
request per stream start resolves Massive condition IDs from UTP `R` (regular
two-sided NBBO), with no guessed numeric ID. Only non-legacy, non-exchange-specific
stock quote conditions qualify, and only when no indicators are supplied.
Unknown/flagged/malformed metadata, incomplete/duplicate reference records,
reference failure, expired reference, stale/future/locked/crossed/one-sided quotes
all retain default costs. Indicator-bearing quotes remain visible, not cost
evidence, until their semantics are verified. This is NOT trading-halt detection
or execution authorization. Reference retry is on restart, not a polling loop.

The authenticated book propagates at500ms, with a shared one-second expiration
invalidation; money helpers check exact age (5s inclusive). Withdrawals, auth loss
and stop clear cost inputs. Scan and trade-price replacement preserve fresh NBBO
without changing the analysis time. Detail/copy actions re-resolve the store,
so a selected sheet's older value cannot retain a withdrawn cost quote.

References:
- https://massive.com/docs/rest/stocks/market-operations/condition-codes
- https://massive.com/docs/websocket/stocks/quotes
- https://www.utpplan.com/DOC/uqdfspecification.pdf (section7.5.2.2)

Verification:50/50 focused macOS tests, then canonical broad tests **1,664/1,664
passed on EACH platform**, zero failures/skips among selected tests. Explicit
exclusions remain CalibrationPersistRunTests, LiveUniverseVerificationTests and
StrategyBaselineMeasurementTests (opt-in network/measurement). Result bundles:
- `/private/tmp/stocksage-m2b-cost-macos-20260906-2040.xcresult` (focused)
- `/private/tmp/stocksage-m2b-cost-broad-macos-20260906-2038.xcresult`
- `/private/tmp/stocksage-m2b-cost-broad-ios-20260906-2040.xcresult`

All run handles completed; no compiler remains. Existing warnings in allocation
optimizer/EV tests remain. No live provider smoke, populated visual QA, real order,
model load/conversion or push. **M2b overall remains incomplete:** compact cards,
same-time trade sequence through Store, visual QA and authenticated smoke remain.

## Pipeline 4 M2b data/UI checkpoint — 2026-09-06 20:18 +03

The existing Massive connection now subscribes to `Q.` alongside `T.`. Quote
and trade freshness remain independent, with500ms quote publication. The detail
sheet shows bid/ask prices, share sizes, venue attribution and SIP time. Spread
is withheld when older than5s, future-dated, locked, crossed or one-sided.
Distinct same-time QUOTES use exact64-bit per-symbol sequence ordering; the
separate same-time TRADE-to-Store sequence change remains pending.

The on-demand Tape sheet reads `/v3/trades` and `/v3/quotes`, pinned to one symbol
and a seven-day window, capped at3pages ×100rows per channel. Partial results,
invalid rows, entitlement errors and invalid/repeated cursors stay visible.
Bearer authorization is header-only; pagination rejects other hosts/paths/ports,
userinfo, fragments and API-key queries, and redirects are disabled.
The exchange reference is cached24h in process; Nasdaq filtering uses `mic=XNAS`,
never a guessed numeric ID or tape-C listing. Filtered quote sides are not NBBO.

Shared numeric decoding now rejects JSON booleans and fractional/overflowing
integer metadata, retaining exact integer spelling before a Double fallback.

Verification: canonical `xcodebuild test`, parallel testing disabled, **1,660
passed on macOS and1,660 on iPhone 17 Pro (gate)/iOS26.5**, zero failures/skips
among selected tests. The same three opt-in network/measurement suites listed
under M2 were explicitly excluded. Result bundles:

- `/private/tmp/stocksage-m2b-broad-macos-20260906-2014.xcresult`
- `/private/tmp/stocksage-m2b-broad-ios-20260906-2016.xcresult`

**M2b is not complete:** the panel explicitly states ranking/tickets still use
estimated costs. Next: measured spread through every ranking/gate/export caller,
conservative cost floors and quote-condition eligibility, compact card display,
trade sequence propagation, populated visual QA and authenticated endpoint smoke.
No live provider call, actual order, model load or push was performed by this gate.
Continue the remaining checklist in `agent-docs/PIPELINE_TAKEOVER_2026-09-06.md`.

## Pipeline 4 M2 — 2026-09-06 20:00 +03, Codex single-session takeover

Owner stopped the separate pipeline task; its uncommitted M2 changes were
preserved and completed on `wt/coverage`. Massive replaces the active EODHD
stream/quote route; Yahoo remains the fallback. The stream consumes every event
in a batch, preserves authorization across informational statuses, handles send
failures, and cancels stale connection callbacks/retries. Auth alone does not
prove delivery: per-symbol coverage expires 45 seconds after the last accepted
trade. Status publication changes only on transitions, with a one-second expiry
timer; Store price writes retain their 500 ms coalescing.

All quote ingress paths now share ordering/validation: full refresh, targeted,
monitor/gap polls, stream flushes and scan publication cannot rewind a dated
price. Undated seeds remain unknown, corrupt future cache values can recover,
off-board ideas update without creating board rows, and row UUIDs survive polls.

Canonical `xcodebuild test`, separate result bundles, parallel testing disabled:

- macOS arm64: **1,649 passed, 0 failed**, bundle
  `/private/tmp/stocksage-m2-broad-macos-20260906-1956.xcresult`.
- iPhone 17 Pro (gate), iOS 26.5: **1,649 passed, 0 failed**, bundle
  `/private/tmp/stocksage-m2-broad-ios-20260906-1957.xcresult`.
- Both explicitly exclude `CalibrationPersistRunTests`,
  `LiveUniverseVerificationTests`, `StrategyBaselineMeasurementTests` (opt-in
  network/measurement jobs). Zero skips among selected tests; excluded suites
  are not claimed tested. Counts independently read with `xcresulttool`.
- One earlier expanded-test attempt failed compilation on a fixture typo and
  executed no tests; corrected before the focused and broad successful runs.

Not yet verified: live endpoint smoke, per-observation provenance UI, NBBO/tape,
same-millisecond sequence ordering, remaining M3–M6, pipeline 5, final integration.
Continue via `agent-docs/PIPELINE_TAKEOVER_2026-09-06.md`. No push or real order.

Written early under the good-spender `⚠ APPROACHING LIMIT` directive (projection only — this
session is the sole spend in the 7-day window; the EWMA is a read-burst artefact).

## Environment blocker — RESOLVED 09:44 +03 (licence accepted; `xcodebuild`, `/usr/bin/git`, Homebrew work again)
Until 09:44 +03 Xcode 26.6 (17F113) had an unaccepted licence, so `/usr/bin/git`, `xcodebuild`, `xcrun`
and `brew` all refused with "You have not agreed to the Xcode license agreements". Everything below
about "tests NOT run" refers to commits made before that. The iOS 26.5 simulator platform (~8 GB)
was still downloading at 09:49 +03 (owner-approved) — the iOS `xcodebuild test` leg is pending it.

Workarounds used while it was blocked (kept — they are fast gates in their own right):
- git: call `/Applications/Xcode.app/Contents/Developer/usr/bin/git` directly.
- compile gate: `swiftc -typecheck` on `StockSage/Sources/**` for BOTH platforms — script at the
  session scratchpad `tc_stocksage.sh macos|ios` (flags mirror the pbxproj: Swift 6, MainActor
  default isolation, MemberImportVisibility, 26.5 targets). Baseline at 02ab1a0: clean on both,
  ~40 s each. Superseded the same day by `tools/gate.sh` (emit-module, both platforms + test-target
  type-check) and **`tools/runtests.sh`, which EXECUTES the whole Swift Testing suite without xcodebuild**
  (swiftc-built testable dylib + Testing.framework runner, throwaway HOME). `xcodebuild … test` itself
  still needs the licence; commits before 09:30 +03 say "tests NOT run" because the runner did not exist yet.

## Repo state at handoff
- `main` = 02ab1a0, **16 commits ahead of origin/main, unpushed** (all iPhone UI work, Jul 28–29).
- Worktree `~/StockSage-uiwork` on `ios-colour-overhaul` at the same commit, clean.
- Work branch for this session: `review-followups-2026-09-06` (off 02ab1a0).
- Backlog source of truth: `agent-docs/REVIEW_2026-07-28_claude.md` (Part 6 staged plan; Part 3
  UI list). `agent-docs/IOS_REVIEW_2026-07-27.md` is fully FIXED — not a queue.

## Done this session (branch `review-followups-2026-09-06`, 3 commits, tree clean, NOT merged, NOT pushed)
- d21cec5 — review #2 "Open heat"→"Planned heat X% of Y% cap" (honesty-critical), #8 iPhone sheet
  detents + grabber (detail sheet .medium/.large, Settings + Browse .large), #10 Reduce-Motion gates on
  the LIVE pulse and refresh spinner, #17c dead `fontMicro` removed.
- 0aac115 — review #7 `.touchHitArea()` on 13 icon/text-only controls (hit shape only, no layout
  change); #9 21 hardcoded font literals → @ScaledMetric tokens in MarketsTodayActionsCard,
  ExecutionQualityPanel, MarketSessionClockView (byte-identical at default Dynamic Type).
- ba82689 — Q3 `defer { isRefreshing = false }` for the whole refresh cycle; Q6 `addSymbol` passes
  `marketTime`; Q7 `quoteAsOf` max-merge; C2 rebalance sort symbol tiebreak.
Every commit: swiftc -typecheck clean on BOTH platforms; tests NOT run (licence). Skipped on purpose:
the #7 stepper relocation to the bottom bar (structural), Q8 (must follow Q4), and every owner-decision item.

## Batch 2 — 2026-09-06 08:30 +03 (workflow wf_02b04e3a-62a: 16 items, 7 isolated worktrees, 29 agents, 76 min)
All 16 items landed and were cherry-picked onto this branch in dependency order (cache → store → stream →
eodhd → fixture → ui2 → ui), `tools/gate.sh all` green after EVERY group (emit-module macOS + iOS +
test-target type-check). Tests still NOT executed (licence). Each group had an adversarial two-lens review;
every blocker/major was fixed in a `fixup(...)` commit except one the fix pass correctly rejected (the
reviewer flagged Q8 landing before Q4 inside the ui worktree — the merge order lands Q4 first).

| Item | Commit(s) | Note |
|---|---|---|
| Q4 marketTime in quote cache Entry | d131554 | review: clean |
| Q1 heal sweep scoped + capped + backoff | 2be3bd2, a73444f | keeps existing `healBatchCap`/`marketIsTrading` gate (superset); pure `healCandidates` pinned by 6 tests |
| Q9 mirror sweep prices onto ideas | 988da1f, 3bf5994 | fixup: `mergeLiveQuote` no longer fabricates `asOf: Date()` — nil stays unknown |
| P3 O(1) `symbolIndex` | 91d32c3 | also rebuilt in addSymbol/removeSymbol (review omitted them) |
| Q5 stream auth classifier + watchdog | 084b16f, 98690dc | fixup: MarketsView now OBSERVES the stream so the LIVE dot redraws |
| Q10 EODHD parser parity | 22ab017, 1f49ccb | fixup: `parseRealTime([String: Any])` overload so the isFinite guard is testable |
| P2 fixture real spark + clique alloc | 299f009, 45f50bc, 9c79c8f, 80a109c | fixup: per-idea varied spark (a shared spark made a degenerate all-1.0 clique) |
| UI#5 fontCaveat / section header 15 | d25ad97 | 3 calibration labels re-pointed (review said 2) |
| UI#13 iOS watchlist remove + reason | 864129a | |
| UI#15 ideasHeader two tiers | b613ec0 | analysis-timestamp line left untouched (one ternary, always visible) |
| UI#16 minWidth fields + wrap | 4140e3a, 37ffd0d | fixup: 4 other widened-field rows also wrapped |
| UI#6 dangerSoft badges + text sweep | 02a95c3 | static `actionColorForTest` seams + guard test |
| UI#3 ViewThatFits metric rows | c591a18 | 5 rows split (idea card exact per review; 4 others minimal) |
| UI#4 `.explain()` shim | 93c6ede | ~13 honesty-bearing `.help` sites converted; sheet stop line not found by text |
| Q8 banner fail-closed | 774522d | shared `MarketsView.freshnessStale(asOf:now:)` |

Minor review findings left OPEN on purpose (small, do after tests can run): Q5 ping has no pong deadline and
`armWatchdog()` re-allocates per frame; Q1 evaluates `marketIsTrading` for every row before the scope filter;
Q1 backoff `before` lookup is a linear scan (could use `symbolIndex`); the same O(n) `currentPrice` scan
still exists in MarketsRiskAllocationSection (unwired file) and `fxRateAge`; `capTruncates` passes the cap
as a literal 40.

Also this session: `tools/gate.sh` (95b54e2) committed as the licence-blocked compile gate; Ollama 0.33.3 +
`qwen3.8` (27B) installed on this Mac for the new Catalysts tab's optional local explanation backend
(see the Catalysts section once it lands).

## wt/ui — 2026-09-06 09:20 +03 (worktree /Users/saleh/StockSage-wt/ui, branch wt/ui, base e619739) — restored 09:58, dropped by mistake at 09:50
Two commits, `tools/gate.sh all` green after each (macos=OK ios=OK tests=OK; tests type-checked, NOT
executed — licence). good-spender was turned ON for good mid-run (user directive, saved to memory).

| Commit | What |
|---|---|
| 648c425 (wt/ui 4cfa3f9) | fixup(UI#6): the 9 realized-stats + risk-analytics ideaMetric sites → dangerSoft via a new static seam `MarketsView.signedMetricColor(positive:positiveColor:)`, pinned by `SignedMetricColorTests` (BacktestVerdictColorTests.swift) |
| dd578ae (wt/ui 1d2637c) | fixup(UI#6): the remaining 17 small-text raw-danger sites (+2 mixed-helper consumers: `hc` heat text, healthColor verdict text) across MarketsView + MarketsRiskAllocationSection; 25 icon/fill/stroke/background sites keep raw danger. Sonnet diff review: APPROVE, 1 minor (watchlist arrow icon inherits dangerSoft with its text) |

Owner call, NOT changed: white text on a raw-danger FILL — STOP TRADING banner (~3316), "Confirm close"
button (~3631), "DO NOT TRADE" chips (~5877 and ~6998 → BestOpportunityActionCard:9881). Same 3.41:1
class UI#6 fixed on the sell badge, but these are stop/destructive surfaces where the red fill is the
convention — decide badge treatment (pastel fill + dark ink) vs keep.
RESOLVED 2026-09-06 09:35 +03 — owner approved; landed as 0897fea (badgeInk + gateChipColor seams, test-pinned, gate green).

Landed on review-followups-2026-09-06 as 648c425 + dd578ae (cherry-picked clean, gate re-run there —
see merge_gate.log). Licence accepted 2026-09-06 09:44 +03; canonical gate run at 09:47 +03: macOS build OK, macOS
test OK — 1,426 tests in 166 suites passed (Swift Testing, 14.2 s; first EXECUTED run since Jul 29).
iOS leg BLOCKED at first: Xcode 26.6 needs the iOS 26.5 simulator platform (the 27.0 beta runtime is
not an eligible destination); owner approved `xcodebuild -downloadPlatform iOS` (~8 GB) at 09:49 +03.
Next: iOS leg result (see merge_gate.log), then push. Spend (good-spender estimate): run closed at $28.27 vs $3.00 est (9.42x OVER — ~30 Fable-tier
classifier agents ran inside an ultracode workflow before it was stopped on the good-spender directive).

## Catalysts tab — NEW (owner request 2026-09-06, workflows wf_3c5d578a-629 + wf_41e9e30c-825; 10 commits cba3f92..d382cc0)
"A new tab that shows, for the same ideas as the Ideas tab, the key catalyst to watch and explains why" —
BOTH per-idea cards AND a date-ordered calendar; the why is engine rationale always, plus an OPTIONAL
model-written paragraph on tap (owner chose "both" / "both").

| Piece | File | Notes |
|---|---|---|
| Engine | `StockSage/Sources/StockSage/StockSageCatalystWatch.swift` | pure; precedence earnings(imminent/soon) → volume move → earnings(clear) → range extreme → risk-off regime (long ideas only) → reliable seasonality → none; every string lives here; UTC-fixed dates; past earnings (>24h) never shown |
| Narrator | `StockSageCatalystNarrator.swift` | routes over Apple FoundationModels (on-device) and the local server; facts list → ≤80 words, ticker-only, no new numbers; foreign-number guard withholds output; every paragraph labelled with its SOURCE + model |
| Local server client | `StockSageLocalModelServer.swift` | Ollama native `/api/chat` (think:false, num_ctx 4096) or OpenAI-compatible `/v1/chat/completions`; probe; backends auto / on-device only / local server only / off; loopback default; non-loopback WARNS FIRST (banner + per-card) |
| View | `StockSage/Sources/Views/CatalystsSection.swift` | header (mode picker, regime line, always-visible caveat, sample-data label, "Explanation model" settings), lazy cards, calendar buckets Today/Tomorrow/This week/Later/No date on file; earnings fetched for ≤30 shown ideas, ≤4 parallel; 8-K filings on tap (US) |
| Wiring | `MarketsView.swift` (d49a903) | `MarketSection.catalysts` between Ideas and All, icon calendar.badge.clock, `CatalystsSection(ideas: displayedIdeas, store: store) { selectedIdea = $0 }` — same projected board, same order |
| Tests | `StockSageCatalystWatchTests` (12), `…NarratorTests` (13), `…LocalModelServerTests` (9), `CatalystsSectionTests` (3), `…PropertyTests` (11, 52,500-combination oracle sweep) | all EXECUTED green via `tools/runtests.sh` |

Reviews: tab review found 2 blockers (past earnings shown as imminent; calendar dropped the RVOL "unvalidated"
caveat) + 2 majors (UTC vs local day; eager cards) — fixed f098044. Backend review found 2 blockers (LAN warning not
visible at the Explain action; label named the CURRENT model setting, not the generating one) + 1 major (auto
fallback untested) — fixed 39ec0d0/3410c82.

Local model on this Mac (owner "okay"): Ollama 0.33.3 standalone under `~/.local/opt/ollama`, LaunchAgent
`com.ollama.serve` on 127.0.0.1:11434 (keep-alive 24h), model `qwen3.8` (27B Q4_K_M, MTP speculative decoding on).
Measured: quiet Mac 15–53 tok/s ≈ 3–10 s per paragraph; with Swift compilers running 7–11 tok/s. MLX 4-bit + MTP
drafter via mlx-vlm was ~1.3× faster steady-state (3.7–6.3 s) — NOT made the default; venv at `~/.local/venvs/mlx`,
34 GB of A/B artefacts (Ollama tag `qwen3.8:27b-mlx`, HF cache) left on disk for the owner to delete or keep.

## EXECUTED test results
**Canonical `xcodebuild -scheme StockSage -destination 'platform=macOS' … test` on the tab branch (rebased onto
5c547f1), 2026-09-06 09:53 +03: `✔ Test run with 1476 tests in 171 suites passed after 26.920 seconds` — ** TEST
SUCCEEDED ** (n=1,476 executed, 0 failed).** iOS leg: pending the 26.5 simulator platform download (other session).

tools/runtests.sh (macOS arm64, 09:40 +03), before the licence was accepted:
`✔ Test run with 1474 tests in 170 suites passed after 29.967 seconds` on d382cc0's tree (n=1,474 executed, 0 failed).
Earlier the same runner passed 1,446/1,446 on d49a903 (batch 2 + tab wiring) and 33/33 on the catalyst suites.
Not executed: SwiftUI rendering (no simulator/app run), the Apple on-device model path (needs an Apple
Intelligence device), live Yahoo/SEC/Ollama network paths beyond the read-only Ollama probes.

Canonical gate on BOTH platforms at HEAD 5b3f2a4 (2026-09-06 10:01 +03, wt/ui session): macOS test
1,476/1,476 in 171 suites; iOS test 1,476/1,476 in 171 suites on an iPhone 17 Pro simulator (iOS 26.5
23F77, platform downloaded 09:49–09:54 +03, 8.52 GB). HEAD unchanged during the run. Not pushed.
Uncommitted `StockSage.xcodeproj/project.pbxproj` reorder (104+/91−, no semantic change) left for its owner.

## Next actions
1. Owner: `sudo xcodebuild -license accept`, then the canonical `xcodebuild … test` on macOS AND the iOS 27
   simulator (the runner covers macOS only; iOS is emit-module-checked). Open the app: Ideas → Catalysts tab,
   both modes; tap Explain with Apple Intelligence on; set Backend = Local server with Ollama running.
2. Merge `review-followups-2026-09-06` → `main` when green; push `main` (was 16 ahead before this branch).
3. Backlog: the minor review findings listed under Batch 2 above; remaining OPEN review items are the
   owner-decision ones (Q11, C1 wording, M1 retention, UI#11 iPad, UI#1 crown, F1 dead engines) + P2-memo
   (allocator memo, `StockSageStore` + `MarketsView` capitalAllocationCard), UI#3's remaining rows if any.
4. Decide on the MLX server as default (needs a launch agent; ~1–2 s faster per tap) and on deleting the 34 GB
   of A/B model files.
5. The background sweep session's work (`wt/ui`) is ALREADY on this branch (648c425, dd578ae, 0897fea —
   see the wt/ui section above); its worktree `~/StockSage-wt/ui` can be removed once it has run the
   iOS test leg and pushed.

## W4 — local-model retrieval-first internet access (2026-09-06, worktree cov-w4, branch wt/cov-w4)
Citable sources for the on-tap Catalyst "Explain" paragraph: EODHD news (`StockSageNewsService`,
new), the last 8-K (`StockSageDisclosureService`, existing), and insider Form 4 activity
(`StockSageInsider`, existing — now also gated by `ToolPolicy.isExternalAllowed`, closing the one
feed in this subsystem that hit the network unconditionally). `StockSageCatalystNarrator.facts(for:sources:)`
appends one numbered `[n] YYYY-MM-DD <source>: <title> — <snippet> (<link>)` line per source; the
model may cite `[n]` and both the existing number fence AND the new `citationsValid(_:sourceCount:)`
gate must pass before a response is shown as `.text` — otherwise `.withheld`. US/NASDAQ-only via
`StockSageEODHD.covers`, matching the sibling SAHMK/Tadawul task being cancelled (12:57 +03 scope
change) — nothing here touches Tadawul or `.SR` symbols.

**EODHD news cost**: `/api/news` is billed 5 API calls per request PLUS 5 more per ticker named in
the request — one call for one symbol therefore spends 10 calls against the 100k/day EODHD
allowance, separate from and in addition to the existing quote path's per-symbol cost.

**Privacy**: tapping "Explain" now also sends the symbol to eodhd.com (news) and sec.gov (8-K
filings, insider Form 4 trades) directly from the device, in addition to whichever narrator
backend (on-device Apple Intelligence or the local server) answers the paragraph. The Catalysts
tab header states this unconditionally, alongside the existing non-loopback warning.

Gate: `GATE repo=cov-w4 macos=OK ios=OK tests=OK`. Tests: filtered StockSageInsiderTests 10/10,
StockSageNewsService 12/12, StockSageCatalystNarratorTests 23/23; unfiltered suite 1,551/1,551
tests in 177 suites, 0 failed (tools/runtests.sh, EXECUTED, 65.3s). No network hit in any test —
all fixtures are hand-derived pure-parse inputs; `ToolPolicy.override` gating test uses the
pre-existing `ToolPolicyTestLock` seam.
