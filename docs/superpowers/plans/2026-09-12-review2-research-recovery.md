# Second reliability review and research completion plan

> Execution: lead sole writer/tester/installer, read-only domain reviewers. Inline test-first integration under the owner's autonomous-fix approval.

**Goal:** Reduce avoidable incomplete research without changing evidence, model weights, strategy/risk thresholds or accepting unsupported answers.

**Architecture:** Reuse the current request builder, strict assessment validator, bounded output-limit recovery and exact-opinion evidence repair. Pass an optional JSON schema to the verified LM Studio 9B profile only; conversational/narrative requests retain their existing format. Keep all factual figures visible in captured evidence, while constraining assessment prose to the already-required qualitative format. A completed HTTP reply is not an accepted opinion.

**Evidence:** Installed bd8ea9c live Research showed SPY validation=schema (finish=stop,108 tokens), MU validation=unboundNumber (stop,74 tokens), IWM validation=foreignNumber (stop,117 tokens). These are not output-limit failures. On the same loaded 9B MLX6bit model a synthetic schema request returned four-key JSON, stop,65 tokens,no reasoning in8.13s. No credentials or account data were sent.

**Alternatives:** Raising every output limit cannot fix a normally completed invalid answer. Accepting incomplete/unsupported text would remove correctness checks. Constrained generation plus the existing strict validator is the chosen root-cause improvement; no new model/dependency or prediction claims.

## Work and acceptance

- [x] Add red real-caller tests showing assessment requests lack schema, and horizon research does not reuse exact-opinion missing-evidence repair. Add negative controls for numeric claims, changed action/prose and cancellation; retain existing expiry/fill-boundary checks and extend source-reviewed evidence validity to repairs.
- [x] Add optional `jsonSchema: Data?` request payload support; emit only for the verified non-Ollama LM Studio9B profile. `StockSageAIAssessment.responseSchema(facts:)` supplies required fields, offered fact-ID enum, bounded qualitative prose and action enum. Keep validator unchanged.
- [x] Share the schema across idea/paper/horizon requests. Paper and horizon reuse the bounded assessment completion helper; idea assessment retains its existing exact-opinion repair rather than duplicating it. Keep narrative Chat/Catalyst formatting unchanged.
- [x] Reproduce and correct additional reviewer-confirmed defects individually with real Swift regression tests; do not implement speculative findings. R1–R10 are recorded in the review receipt.
- [ ] Review all reachable native tabs; capture limits without bypassing computer-use tools. Preserve owner-started scans and paper/history state.
- [x] Run focused red/green tests, independent source review, serial full Mac/iPhone gates on frozen source, and bounded synthetic local-model checks. No new paid requests, no real orders/relay, no pushes or main merge.
- [x] Record exact review coverage, recommendations/disposition, validation and installation status. Tested candidate retained separately; owner scan and installed app untouched. Complete remaining native visual acceptance and coordinate normal quit before installation; do not discard the owner's running scan.

Artifacts: `/private/tmp/stocksage-review2-20260912.3sHFBU`.
Review and remaining acceptance: `docs/superpowers/reviews/2026-09-12-review2-model-and-app.md`.
Source baseline: `bd8ea9cd38ea3dc664f8d15f12b934dd5a599083`, `/Users/saleh/StockSage-wt/opus-harness`.
Current installed executable SHA256: `5be7474b21fbe2240f1ad051fbd39eefee8eb58821bb9f168da5ab6c94a335ec`.
Later installation completed after owner-authorized Stop/Quit; previous bundle and state
preserved under `/Users/saleh/Codex-Backups/stocksage-review2-install-20260912.Aoqdkx`.
Home/Research inspected after launch; full all-tab acceptance remains open.
