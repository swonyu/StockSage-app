# Local 9B / FinGPT migration — implementation and acceptance record

Owner instruction: `/private/tmp/stocksage-model-replacement-20260910-01a08be0.md` (ten phases). Parent sole writer, heavy tester and installer. Broader 54-item roadmap and its heartbeat remain paused. Good-spender removed. No paid services, real orders, IBKR relay, strategy/risk or historical-record changes.

Publication exception, September 10: the owner subsequently requested a commit and push. This authorizes a development checkpoint on `codex/qwen-chat-context`, not a merge into `main`, model promotion, installation, or completion claim for the ten phases below.

Scope update, September 10: the owner dropped the IBKR integration idea. Do not resume IBKR implementation or activate its relay. Pending relay code/documentation/tests are preserved locally and excluded from this publication; removing existing integration files would be a separate change.

## Checkpoint scope — migration still incomplete

The checkpoint contains a selectable loopback LM Studio profile, conservative whole-prompt bounds, returned-model/finish checks, and on-demand exact-label headline sentiment with provenance, cancellation and settings-revision checks. Numeric prose remains explicitly unverified when subject/sign/unit/time binding is not proven. These are partial implementation pieces, not completion of every caller, lifecycle or quality gate.

The saved comparison scored 11/12 sentiment cases for both plain 9B and the FinGPT-style prompt, with the same adversarial Arabic failure. Saved arithmetic and timestamp errors remain evidence gaps. No quality improvement or non-inferiority to the fine-tuned 27B is established; the 27B stays available for rollback. FinGPT here is a prompt contract, not a downloaded finance-tuned model or an execution signal.

The next harness/candidate research is in [AI_MODEL_HARNESS_RESEARCH_2026-09-10.md](AI_MODEL_HARNESS_RESEARCH_2026-09-10.md). That report is a proposed implementation plan, not evidence that its recommendations are already implemented. Publishing this checkpoint does not relax the acceptance gates.

## Implementation plan

Architecture: reuse `StockSageLocalModelServer.completeDetailed` and native per-article UI. One stock Qwen3.5-9B MLX6bit model through LM Studio; FinGPT is a prompt and categorical label contract, not new weights. The existing fine-tuned27B remains the rollback model. Swift remains authoritative for finance and eligibility.

- [x] Phase1: verified branch `codex/qwen-chat-context`, HEAD `d301176d645cce3fbf7b4836f394fd3961b52721`, 46 dirty records; no running local model/build/installed app process. Preserved actual preferences privately and copied current source before editing.
- [ ] Phase2: verify stable JIT identity, selected local6bit artifact, non-thinking, idle unload/reload, server restart. Do not persist temporary alias. Requested4096 is not yet a proven runtime cap.
- [ ] Phase3: reuse shared transport/settings revision. Add focused regressions for profile lifecycle/request identity; preserve other endpoints and legacy metadata compatibility.
- [ ] Phase4: exact-label native sentiment using selected news only, provenance/exact excerpt, no cache or market scan. Test neutral versus unavailable, truncation, cancellation, settings ABA, EN/AR, malicious input. Include upstream MIT attribution.
- [ ] Phase5: trace all five callers and pin deterministic facts/validation without changing financial decisions.
- [ ] Phase6: measure competing requests and whole-prompt bounds. Add shared asynchronous admission only if measured. Evidence/config rechecked after waits; exits and provider I/O remain independent.
- [ ] Phase7: frozen historical six cases + two holdouts and twelve balanced sentiment cases before new inference. Raw receipts are immutable; compare27B/plain9B/FinGPT9B serially; preserve failures.
- [ ] Phase8: RED/GREEN focused native tests and FinGPT offline checks, then stable/beta Mac/iPhone executed suites and strict compilation, serial jobs2 with canonical three exclusions and source hashes. Preserve exact tested Mac bundle.
- [ ] Phase9: only promote after quality/lifecycle/platform gates; normal quit/lease release, private owner-data snapshot, recoverable previous bundle, exact tested installation and real-path UI/relaunch checks. iPhone loopback unavailable remains truthful.
- [ ] Phase10: append exact results, limitations and rollback instructions; installed status explicitly separate from candidate readiness.

## Recovery / evidence

Private artifacts: `/Users/saleh/StockSage-model-migration-20260910.w6pSJw/`. `source-before/`, `source-before.sha256`, `status-before.txt` preserve unfinished work. `owner-preferences-before.plist` contains private actual settings; never include it in Git or output. Prior endpoint `http://127.0.0.1:8765`, model `/Users/saleh/models/salehman-qwen38-27b-4bit`; model files and LM registration untouched.

Installed executable hash remains `e6d3ba3f8cd27eb7ab56ca7395f2c0732f5a3cb44229b90f0c7da0afe1e3ccb7`, debug dylib `84bd218295ac2ad21be02c648e6aee554e710c449b234df5176bda3a8cf8b2ef`. No migration installed yet.

LM inventory: local `qwen3.5-9b` resolves `mlx-community/Qwen3.5-9B-6bit`, safetensors6bit,8215256416 artifact bytes. Remote LM Link models are out of scope. Prior launchd Qwen service absent at initial check. Nonzero pre-existing swap (~5840MB) is not by itself current memory pressure.

LM Studio documents JIT and request `ttl`: https://lmstudio.ai/docs/developer/core/ttl-and-auto-evict . Actual behavior must still pass local lifecycle tests. No persistent daemon/runtime or weight patch is planned.
