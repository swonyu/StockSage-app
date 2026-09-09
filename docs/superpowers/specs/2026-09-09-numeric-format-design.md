# Exact numeric-format equivalence — proposed bounded fix

Status: draft awaiting owner approval under the brainstorming review gate. No app implementation has been made. This proposal does not block the separately authorized whole-market feed task.

## Problem and evidence

At integration commit18d3070, `StockSageCatalystNarrator.introducesForeignNumbers` compares literal digit-run strings. Executing its actual current Swift helper bodies reproduced rejection of `2000` and `2,000` when the supplied fact says `2000.0 USD`. Changed-value controls (`2001` and rounding `1125.4624` to `1125`) remained rejected. A date paraphrase (`Nov 4` against `2026-11-04`) also fails, but that is deliberately outside this first fix.

The shared helper is used by CatalystNarrator.checkedResponse and StockSageAIAssessment.parse. Assessment first limits numeric evidence to the explicitly selected fact IDs. Chat has a separate typed-record/draft contract and is not changed.

## Alternatives and recommendation

1. **Recommended: exact formatting equivalence only.** Recognize well-formed ASCII thousands grouping and insignificant trailing decimal zeros in both compared text and cited facts, using string operations rather than floating-point conversion. Keep dates, leading-zero integer tokens and abbreviations unchanged. This fixes observed formatting rejections with a narrow, testable boundary.
2. **Fact formatting only.** Print all inputs more consistently but keep literal output comparison. Smaller validator change, but a model can still validly format `2000` as `2,000`, and already-captured facts retain their old formatting.
3. **Typed numeric/date claims.** Bind subject, unit, sign and time to structured source facts. Stronger semantic verification, but a separate larger design; not necessary for this bounded representation bug.

## Required behavior

| Supplied fact | Model text | Proposed result |
|---|---|---|
| `2000.0 USD` | `2000`, `2,000`, `2000.00` | Pass numeric membership |
| `1183 shares` | `1,183 shares` | Pass numeric membership |
| `12.50%` | `12.5%` | Pass numeric membership |
| `9007199254740993.0` | `9007199254740993` | Pass without floating-point rounding |
| `2000.0 USD` | `2001`, `20,000`, `2k` | Reject unless those separate tokens actually exist in the selected evidence |
| `1125.4624 USD` | `1125`, `1125.46` | Reject: these are rounding, not equivalent formatting |
| `2026-11-04` | `Nov 4`, `FY26` | No new date/abbreviation conversion; remain rejected for this isolated fact |
| `1183` | `1,18`, `1,183,4`, `1.1.83` | Do not repair malformed numeric text into1183 |

Normalize only an entire well-formed grouped scalar, not a valid-looking substring inside malformed grouping. Do not expand scientific notation, abbreviations or locale-dependent decimal commas. Do not normalize F/W reference identities, change evidence selection, add uncited facts, round values or convert through Double/Float. `numericTokens` itself keeps its existing externally tested output; representation comparison belongs in `introducesForeignNumbers`.

Passing membership still does NOT prove subject/sign/unit/date entailment. Existing caveats and all other schema, citation, digit, field-length, time and execution gates remain. This is not authorization to force a Buy, alter confidence/sizing, loosen ten-second execution freshness or treat an AI opinion as a verified fact.

## Verification and scope

Add regressions before behavior changes at the shared helper and through Assessment.parse using selected and deliberately unselected evidence. Assert the action, facts and references are not rewritten. Cover both comparison directions, malformed grouping, unchanged date/reference rejection, huge adjacent integers beyond Double precision, and genuine rounding/invented-number controls. Run existing narrator/assessment/news tests and full macOS/iPhone canonical gates, coordinated with the feed task's build windows. No model calls or live data needed.

Expected code scope: StockSageCatalystNarrator.swift and existing narrator/assessment test files. Do not edit PaperAutomation.swift, stream/store freshness/UI files, live ledger/schema, model server configuration, providers, broker connections or frozen research. Parent owns integration and installation; no merge/push for this slice. Safe failure diagnostics and news-outcome repairs remain separate follow-up work.

## Self-review

The recommendation deliberately rescues fewer cases than Fable's broader leading-zero/date normalization. It does not claim a new current-model acceptance percentage: the report's saved outputs are historical, and the current failure-class distribution is unknown. Numeric grouping may also stop incorrectly accepting a fragment of a grouped number; tests must distinguish exact value equivalence from old accidental fragment matches. No dates or trading claims become more permissive in this proposal.
