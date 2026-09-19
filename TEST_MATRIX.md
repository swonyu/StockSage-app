# Tradier acceptance test matrix

Prepared 2026-09-08 +03. These are **required future tests**, not executed results. At document creation D/S/L/V/I rows are BLOCKED because the application is not implemented; access-dependent rows have additional prerequisites below. `PASS` requires executed evidence, `FAIL` means an executed assertion failed, and `BLOCKED` identifies a missing prerequisite. A skipped external test never passes its gate.

Fixture evidence proves local behavior only. Sandbox evidence proves paper protocol behavior, not live fills. Production read-only evidence proves observed data/timing only. No test here places a real order. Test IDs are stable; each run records results separately without replacing this specification.

## G0 document verification

| ID | Check | Pass evidence |
| --- | --- | --- |
| P01 | Current upstream safely fetched/pulled; dedicated branch | Exact baseline SHA, branch and git output; no lost local work |
| P02 | Complete brief mapped to PLAN/ROADMAP/TEST_MATRIX | Gates, standalone boundary, language decision, input schema, blockers and updated authorization are explicit |
| P03 | Public claims separated from runtime proof | Dated official source register with discrepancies and unchecked endpoints labeled |
| P04 | Application untouched | Diff from baseline includes planning Markdown/handoff only; original four user files retain hashes |
| P05 | Document integrity | Relative links resolve; table/fence sanity and whitespace checks pass; staged diff contains no credential values |

## G1 deterministic offline tests

Every D row must pass without credentials or external network. HTTP/WebSocket/clock fixtures are labeled synthetic and requests are intercepted; an attempted real socket is a failure.

| ID | Scenario / fixture | Required assertion |
| --- | --- | --- |
| D01 | No mode, bad mode, missing/mixed account/token; offline startup | Diagnostic omission selects offline; network commands need explicit mode; no fallback or credential loading offline |
| D02 | Production POST/PUT/PATCH/DELETE orders including preview; arbitrary URL, redirect, traversal, wrong host/port, wrong account | Deny before network/auth attachment; only exact live-read allowlist and market-session POST permitted |
| D03 | Empty/null/single/list account, position, order and quote envelopes; malformed JSON/type; unknown enum; absent prices | Normalize supported shapes; reject unsafe ambiguity, preserve raw unknown status, never synthesize price/state |
| D04 | Quantity missing/zero/negative/fraction/bool; NaN/Infinity/float price; invalid tick; unsupported side/class/duration/symbol | Reject without transport; Decimal exactness; no auto-selected price/quantity or short sale |
| D05 | Failed/false/malformed preview, changed intent after preview, separate submit | No submission on preview; valid preview binds same immutable intent; explicit paper submit required |
| D06 | 200/ok acknowledgement then pending/open/partial/filled/rejected/canceled/expired | Ack is not fill; save broker ID and cumulative quantities; polling stops on terminal state |
| D07 | Cancel acknowledgement then still open; fill-before-cancel; partial/cancel race; cancel timeout | Confirm final state from status; no forced re-order, duplicate cancel or assumed success |
| D08 | Timeout/5xx/malformed submit response after send; crash before ack persistence | Durable UNKNOWN_SUBMISSION; exactly one send attempt; no automatic resend |
| D09 | Unique, no-match, multiple-match and lagging reconciliation responses | Attach uniquely established broker outcome; ambiguous/missing outcome remains paused; tag is not idempotency |
| D10 | Same request ID with same/different content; concurrent API/CLI writers; restart in SUBMITTING | Idempotent local result or conflict; one writer lock; unresolved intents survive and block new orders |
| D11 | 401/403; 429 with headers; read timeout/5xx; exhausted budget | Credentials stop on auth failure; safe reads back off with bounded attempts/deadline; mutation never retries |
| D12 | Shared rate buckets; many previews/status requests | Honor credential/category budget and recovery headroom; stop terminal polling; no extra tokens to evade limits |
| D13 | WebSocket disconnect, expired session, malformed/duplicate/out-of-order frames, slow consumer | Bounded serial reconnect, at most one connection; observable counters; no mutation module or order replay |
| D14 | Missing/stale quote, delayed sandbox data, DST/holiday/closed clock and clock skew | Missing/untrusted eligibility disables order action; delayed data labeled; closed session not a fake feed failure |
| D15 | Journal unavailable/full/corrupt; critical queue overflow; interrupted SQLite transaction | Fail closed with visible error; no request without durable pre-send state; no lost critical transitions |
| D16 | Restart while paused; explicit pause with holdings/open orders | Pause durable; new/replacement orders denied; no automatic liquidation or bulk cancel |
| D17 | Sentinel credentials/session IDs/account PII in headers, payloads, exceptions and URLs | Redact logs/reports/API/errors; ignore private state; no secrets in history or command arguments |
| D18 | Live process startup/import graph and wrong credential environment | Loads only production read-only config; no sandbox mutation module/credential; no order endpoints |
| D19 | API missing/wrong auth, mode override, oversized/extra fields, duplicate requests, health/status | Authentication, limits and shared safety checks enforced; no generic proxy or live route; secret-free errors |
| D20 | Fresh account constraints: unset caps, insufficient funds, existing commitments, long holdings | Missing/unsafe account or risk inputs disable submit; cannot oversell or use leverage |

## G1 external tests

| ID | Prerequisite / operation | Required real evidence |
| --- | --- | --- |
| S01 | Approved sandbox access; profile and explicit account selection | SANDBOX label; balances, positions, quotes and clock retrieved and normalized; account association verified |
| S02 | Owner-specified equity LIMIT/DAY intent and caps; preview then separate paper submit | Redacted request shape/preview outcome, internal ID, broker ID and real observed lifecycle; form encoding verified |
| S03 | Cancellable sandbox order where available | Cancel request and later status; immediate fill/race documented as observed outcome. D07 covers otherwise-unavailable race deterministically; never submit repeatedly to manufacture cancellation |
| S04 | Sandbox restart/reconciliation of known intent | Journal survives restart, real broker status agrees or remains explicitly unresolved; no duplicate submission |
| L01 | Production account/data entitlement; separate read-only process; regular session | 30 continuous minutes over 1–3 configured symbols; exact event/error/reconnect counts, timestamps, mode and revision |
| L02 | L01 plus controlled disconnect/reconnect | Close old stream before new; session renewal works; no overlapping stream or order request; healthy recovery in same run |
| L03 | Known source timestamp semantics and local clock check | p50/p95/p99 local processing and warm read RTT, each with n; source age separately labeled, unknown semantics marked unknown; no live execution inference |

G1 = all D rows PASS + real S01–S04 evidence (S03 has the documented immediate-fill alternative) + L01–L03 PASS + no critical defect + P04 still PASS. A fixture cannot close an access blocker. Do not inject broker 429s by flooding; use fixtures for hard-to-trigger failures.

## G2 one-VPS acceptance

| ID | Required operation | Pass condition / evidence |
| --- | --- | --- |
| V01 | G1 + exact hosting approval; same locked application revision on Linux | Install/smoke/offline suite pass; revision/lock/runtime recorded; one non-root host; no local duplicate stream/writer |
| V02 | Review SSH/firewall/updates/time/secrets/logs/disk/private health | Key-only restricted admin; no public app port; TLS on; restrictive state; rotation/limits and clock evidence |
| V03 | Process kill/restart and host reboot with unresolved fixture/paper intent | Starts read-only/non-trading; state reconciles; pause retained; no duplicate or replay |
| V04 | Network interruption, session expiry, token replacement, bounded rate errors | Observable recovery/auth stop; one stream; no secrets, unbounded retries or accidental mutation |
| V05 | Two complete regular U.S. market sessions | Same revision, broker-calendar dates/windows, gap explanations and counts; no unexplained data/journal loss or unresolved critical error; partial sessions do not qualify |
| V06 | Protected backup, journal restore and known-good release rollback | Integrity comparison, safe restart/reconciliation and documented exact rollback command; real mutation remains disabled |
| V07 | Performance/resources/cost review | n beside p50/p95/p99; CPU/RSS/disk/queue/reconnects and errors; actual accrued cost plus monthly projection; p95 <10 ms target deviation explained; within approved spend |

G2 requires all V tests, retained G1 safety regression coverage and empty StockSage application diff. Any critical failure or incomplete session blocks G3. A second VPS is outside this gate and needs its own approval and sequential comparison plan.

## G3 integration acceptance (deferred)

| ID | Required operation | Pass condition |
| --- | --- | --- |
| I01 | Identify target, code/auth/deployment/users and data rights | Written observed architecture and approved private/distribution permissions; no assumed interfaces |
| I02 | Add read-only health/quotes/account/order observations | Mode/freshness/unknowns explicit, no broker secrets on client, authenticated boundary, observers share one stream |
| I03 | Add manual sandbox preview/submit/status/cancel | Duplicate click/request, stale/offline/auth/restart/race tests pass; all live actions disabled; RTL verified where applicable |
| I04 | Standalone regression, integration rollback | Original CLI/API still works independently; rollback proven; no leaked credentials or unresolved critical defects |

## Evidence method

Save private evidence under standalone `reports/<run_id>/` (ignored). Redacted summaries may be committed after review. Record exact executed commands, exit status and environment; placeholders in this plan are not executable test results. Retain raw broker state only in protected evidence and normalized state in reports. Sanitized synthetic fixtures must be clearly labeled and contain no copied customer data.

Timing records include sample size, window, units, percentile definition and errors; report n=0 as BLOCKED with its reason, never a measured zero. Separate cold setup, warm REST, local validation, paper acknowledgement, paper fill observation and feed age. Record host/runtime/revision/symbol count and clock uncertainty. Predeclare the local <10 ms p95 engineering target; do not revise it after seeing numbers. Any performance optimization must pass affected safety tests again.
