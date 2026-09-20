# StockSage owner context

- Current owner direction, 20 September 2026: focus on **macOS only**. iOS and
  WidgetKit development/verification are on hold. Preserve their existing work;
  do not run further iOS builds, tests or release actions until the owner resumes them.

- Owner confirmed 2026-09-06: already subscribes to **Massive Advanced** and has
  bought additional Massive products. Do not recommend repurchasing Advanced.
  History identifies Benzinga Earnings as selected and Analyst Ratings +
  Corporate Guidance as explicitly purchased (2026-09-06). Verify live
  entitlements without printing keys; do not assume redistribution rights.
- Product objective: StockSage should place **BUY and SELL orders via Derayah**,
  including cancel/modify and portfolio/order tracking, not merely copy tickets.
  Unattended own-account trading is explicit (Claude d1ce9e6b, source line 2750),
  reaffirmed at 18:24 +03. Support manual and explicitly enabled, risk-bounded
  automated modes; do not replace the goal with permanent per-order approval.
  Review is groundwork, not a replacement product goal. This is not authorization
  to place real trades while developing. AI should improve research/decision speed; profit is a
  measured research outcome, never a guaranteed capability.
- Owner target (18:33 +03): **5% per week on the total portfolio**. Treat as an
  aspiration to test, not a promised return or permission to raise leverage/risk.
  Evaluate net/cash-flow-adjusted total equity, drawdowns and losing weeks;
  distinguish occasional5% weeks from a sustainable weekly compound return.
- Proactive briefing/feed plus conversational Chat, grounded in current data.
  Preserve local-first inference and avoid local GPU work while the owner works.
- Current reconciled design and acceptance checklist:
  `agent-docs/CHAT_DERAYAH_ARCHITECTURE_2026-09-06.md`. Owner approved autonomous
  implementation at 19:37 +03; at 19:38 required all work in this Codex session,
  with no new tasks/subagents. Other pipeline task was stopped, confirmed idle
  at 19:43. Reuse its saved coverage changes; overnight check-in every 15 minutes
  until the owner says stop. No routine design reconfirmation is needed.
- Concurrent worktrees exist. Inspect current git state and HANDOFF.md; preserve
  unrelated edits (especially project.pbxproj). No push for this implementation;
  never push to Salman-bot. Do not infer task completion from old notifications.

## Gemma / model integration

Historical source reference: `agent-docs/GEMMA_MODEL_AND_RESEARCH_GUIDE_2026-09-20.md`
(revision B, pinned to `main@74d6a81`). Read it alongside the living guide and current source
before touching `StockSageLocalModelServer`, `StockSageAIAssessment`, `StockSageSameDayResearch`,
`StockSageHorizonResearch`, `StockSageResearchQualification`, `StockSageTopFiveRanking`,
`StockSageResearchRanking` or `StockSageResearchHistory`.

The dated guide predates the integration repairs. Its §0.3 E1–E9 describe the older source
snapshot, not the repaired behavior or errors in the living guide/PDF. It does not supersede
the living guide or the owner's PDF. For current behavior and verification status, use
`agent-docs/GEMMA_MODEL_AND_RESEARCH_GUIDE.md`, current source and matching receipts.
Historical claims do not override newer owner instructions or reviewed integration changes.

Non-negotiable, even if you read nothing else:

- Gemma is a **pretrained interpreter**. No training, fine-tuning, LoRA or adapter code may be
  added to any model path. `StockSageConvictionCalibration`'s gradient/Hessian is a logistic
  calibration over saved outcomes, not model training — do not "fix" it.
- **All** numeric entry/stop/target references are computed by app code. The model never
  produces a price, level, probability or score. `reason`/`risk` are prose with no numerals.
- Output schema is exactly four keys (`action`, `reason`, `risk`, `evidence`),
  `additionalProperties: false`, six allowed actions. Do not add a key.
- A model "Strong Buy" is an **eligibility label, not a signal**. `StockSageResearchQualification`
  v1 and the `StockSageTopFiveRanking` overlay are rigid arithmetic. Do not introduce
  probabilistic or LLM-derived scoring into either.
- Output budget 192 → one restart at 384. `reservedOutputTokens(for:)` doubles **only** when the
  initial budget is in `1...512`; any larger initial value silently disables the retry.
- Do **not** start sending `top_p` or a seed. Prompt version 1 is frozen against a measured
  corpus; new sampling parameters move the distribution off that baseline. They are unpinned on
  purpose and recorded as nil.
- Compile gate `tools/gate.sh . all`; tests `tools/runtests.sh . --filter ExactSuite` (serial —
  parallel runs produce false failures). SourceKit diagnostics in this repo are systematically
  false; do not act on them.
- Never start a research run, load a model, spend RunPod compute, or reach a broker without an
  explicit owner request **each time**.

## Living Gemma guide — owner directive, 2026-09-20

After each completed StockSage change or verification milestone, update affected
sections and the revision/status in `agent-docs/GEMMA_MODEL_AND_RESEARCH_GUIDE.md`
and regenerate the owner's exact PDF path recorded under “Maintaining the owner's
PDF” in that guide. Preserve the previous PDF and verify the replacement. Separate
implemented, tested, installed, and pending work; do not claim unrun checks or live
model/provider readiness. This is part of the active work, not a scheduled task.
Do not resend the PDF without an explicit request. The dated guide is a separate
historical source snapshot, not the editable source for this living PDF.

Owner update, 21 September 2026: the PDF must be **20 pages maximum**, including
cover and contents, with readable type. Maintain the concise PDF source in
`agent-docs/GEMMA_MODEL_AND_RESEARCH_GUIDE_CONCISE.md` alongside the full living
technical reference. Keep verified behavior and limitations in the concise guide;
leave detailed historical receipts in the full reference. Check the page count,
content and rendered pages before replacing the owner's PDF.
