# Tradier gated roadmap

Prepared 2026-09-08 +03. Scope and authorization: [PLAN.md](PLAN.md). This is dependency order, not a dated delivery promise. The later owner instruction authorizes implementation and automatic progression when gates pass; one VPS up to $20/month total and feature-branch commit/push/test are approved. Tests remain mandatory; real orders are unapproved. **Merge to main only with separate owner permission as the final step.**

## Gates and present state

| Gate | Deliverable | Exit rule | Current status |
| --- | --- | --- | --- |
| G0 | PLAN, ROADMAP, TEST_MATRIX, source register and baseline | Documents reviewed; limits and blockers explicit; application code not written before documents | PASS: planning review, link/fence/whitespace checks and application-diff check completed before implementation |
| G1 | Independent local CLI/private API, deterministic fixtures, actual sandbox lifecycle, separate live observation | Every required D/S/L test passes; 30-minute regular-market read-only evidence; no critical defect; StockSage application diff empty | BLOCKED: application not yet implemented and private access unverified |
| G2 | Same revision on one hardened VPS, runbook and measurements | G1 PASS + spending approval; all V tests; two complete regular-market sessions; no unexplained journal loss/critical error; actual cost/resource review | BLOCKED: G1, host/access and session evidence; one host up to $20/month already approved |
| G3 | Confirmed StockStage target, read-only then sandbox integration | G2 PASS + target/data-use rights; I tests, unchanged standalone functionality and proven rollback | BLOCKED: G2 and target/permission decisions |
| Live gate | Separately reviewed live-capable release/pilot proposal | Exact owner-approved limits/account/order supervision and independent release verification | BLOCKED: not part of initial implementation; no real order authorized |

## Work packages and ownership

| Order | Owner | Work and expected paths in standalone root | Done condition |
| --- | --- | --- | --- |
| 0 | Codex | Sync safely; planning branch; preserve user files; finish these docs | G0 checks P01–P05 recorded |
| 1A | Implementer | Separate repository; `pyproject.toml`, lockfile, `.gitignore`, README; configuration, safety and synthetic tests | Offline command/test suite needs no account/network; runtime/dependencies validated |
| 1B | Implementer | Core HTTP adapter, journal/order coordinator, restart/reconciliation fixtures | Production mutations denied before transport; unknown submissions never retried; D tests pass |
| 1C | Implementer | Thin CLI and authenticated loopback API over the same core | API tests exercise auth, dedup, mode isolation and redaction; no strategy/order automation |
| 1D | Owner + implementer | Local readiness; sandbox reads; manual LIMIT/DAY preview, separate submit, status, applicable cancel | S01–S04 actual redacted evidence; synthetic coverage fills race/state gaps, not connectivity |
| 1E | Implementer after access | Separate production observer, 1–3 owner-selected symbols, 30-minute regular window | L01–L03 actual observations with sample counts and recovery evidence |
| G1 review | Codex | `reports/<run>/`, `docs/GATES.md`, local RUNBOOK/BENCHMARK | D/S/L all PASS and application diff empty; otherwise stop phase transition |
| 2A | Owner + implementer | Specific quote/approval; one Linux VPS and isolated release | Approved monthly total/access; no public API port; no duplicate local/VPS broker connections |
| 2B | Implementer | systemd and hardening, protected state, restart/reboot/rotation/network/restore/rollback | V01–V04, V06 pass |
| 2C | Implementer | Two complete regular sessions on the same tested revision | V05 and V07 pass; actual spend and resource report; G2 reviewed |
| 3A | Owner + implementer | Confirm target; inspect actual code/auth/deployment/users; `STOCKSTAGE_CONTRACT.md` | G2 PASS; approved private/data-use model; no invented app endpoints |
| 3B | Implementer | Thin adapter, read-only then sandbox controls | I01–I04 pass; independent tool survives integration; G3 review |
| Later | Owner | Live pilot approval and reviewed release | No automatic transition from G3 to real orders |

Independent work may proceed while access is missing: fixtures, safety, API/CLI tests, packaging, runbook drafts and public broker eligibility research. Tradier Lite is selected; owner confirmed no approved account yet and willingness to sign up. Do not replace Tradier silently if onboarding is blocked; report an alternative's verified eligibility/access/cost and the scope impact first. Do not submit identity documents or fund an account on the owner's behalf.

## Progress and stopping rules

An hourly task heartbeat is scheduled through **2026-09-09 21:48 +03**. Notify on meaningful progress, gate completion, failure or required owner action; avoid repeated unchanged updates. At the deadline save a final report, stop task-owned workers and pause the heartbeat. No unbounded LLM loop. Do not borrow another task's workers or reset its cost lifecycle.

The standalone package uses one code owner at a time for shared interfaces; a bounded inexpensive worker may handle isolated files/tests. The root reviews transport safety and observed evidence. No paid model API is needed. good-spender speed 3 was present at activation; Codex uses Astra for synthesis and a cheaper available worker because Sonnet/Opus are unavailable in this tool. Dollar figures for Codex remain unknown rather than borrowed from Claude's ledger. Keep the 20% reserve and report actual recorded tokens with scope labels.

Every phase report lists revision, exact commands, PASS/FAIL/BLOCKED by test ID, redacted evidence paths, measured sample counts/performance/cost, remaining defects and next permitted action. Synthetic, sandbox and production-read-only evidence are separate. A failed test gets a fix and targeted rerun; a blocked external test keeps its gate blocked. No claim of bug-free software.

## Phase 1 checklist

- [ ] Create the independent root without overwriting existing work; retain StockSage baseline SHA.
- [ ] Verify supported Python and lock compatible dependencies; no system-wide package changes.
- [ ] Finish default-offline config and final transport guard before any real broker request.
- [ ] Add synthetic edge cases, network denial and redaction tests.
- [ ] Implement durable intent/dedup/reconciliation and crash-safe single-writer behavior.
- [ ] Add explicit paper CLI operations and authenticated private API; no live mutation route.
- [ ] Implement a separate read-only observer with bounded telemetry and recovery.
- [ ] Run offline tests and document exact results.
- [ ] Check broker/account readiness locally without displaying secrets.
- [ ] Exercise sandbox account and manual paper lifecycle only with owner-supplied test inputs.
- [ ] Record real 30-minute regular-market production read-only sample.
- [ ] Publish redacted G1 evidence and prove no StockSage application change.

Next action after document verification: implement standalone Phase 1 under the owner's later authorization. VPS and app integration remain gated.
