# Review UI (Tasks 6 & 23) — backend API requests for Codex

From a 6-cluster read-only survey of the view layer at `1239c6c`, every availability claim
adversarially re-verified: 12 agents, 0 failures, **15 claims corrected**. No builds or tests were
run — the heavy-test lease is held by Codex.

**84 of the needs are already reachable from existing accessors. 46 are not.** Those 46 are mostly
the same handful of gaps seen from different surfaces, and collapse to the list below.

## A. The core ask — four optional fields on `Prediction`

`StockSageResearchHistory.Prediction` (`:40-53`) is what a saved run's row actually carries, and it
has none of these. All four are `Optional`/defaulted so legacy `runs.json` still decodes, which —
per the `insiderTransactions` decode failure you just hit — means **Optional, not a defaulted
non-optional**, for anything a view must distinguish from "genuinely empty".

| Field | Unlocks |
|---|---|
| `evidenceReceipt: StockSageAIAssessment.EvidenceCoverage?` | Task 6 per-class coverage + citation completeness; Task 23 cited IDs. One field delivers `classCounts`, `packetVersion`, `packetDigest`, `offeredKeys`, `citedKeys`, `missingOrUnknownRequiredKeys`, `omittedKeys`, `prePromptOmittedRecordCount`. |
| `qualityReport: StockSageAIAssessment.QualityReport?` | Task 6 quality badge; Task 23 quality-state filter. You are already adding this to `Result`/`CompletedCheck` — it needs to reach `Prediction` too, or the filter can't run at list level. |
| `qualification: StockSageResearchQualification.Receipt?` | Task 6 "why it qualified"; Task 23 full technical snapshot, confluence verdict, catalyst timing. |
| `insiderTransactions` + presence discriminator | The insider section. Converges with the recorded-presence flag you described. |

## B. A per-run lookup

Today only `completedScan(horizon:)` (`:1342`) exists, and it returns **the latest checkpoint per
horizon — not the run being reviewed**. That is the precondition for most of Task 23: a user
opening an arbitrary historical row currently cannot reach its receipt at all.

Request: `func completedScan(runID: UUID) -> (run: Run, scan: Scan)?` — **returning nil rather than
substituting a neighbouring run.** Silently showing an adjacent run's evidence under another run's
header would be the worst failure mode in this whole surface.

## C. Two traps found in passing — both in code you are editing right now

### C1. `factClasses` is silently lost by the saved-checks archive round-trip
`StockSageHorizonResearch.Result.factClasses` (`:71`, set at `:1205`) has no counterpart on
`CompletedCheck` (`:970-997`). It is assigned on the live result and dropped on save, so a restored
check reports **no fact classes at all** — not "unclassified", just gone. This is fallout from my
Task 4 change meeting persistence, so it is my regression to own, but it sits in your file.
Smallest fix: `var factClasses: [StockSageAIAssessment.FactClass] = []` on `CompletedCheck`,
assigned in its `init(listing:result:)` and returned in `var result`.

### C2. Per-class counts already exist — but they answer a *different* question
The verifier corrected my first ask here, and the correction is worth reading before acting.
`Candidate.classSummary: [String: ClassCoverage]` (`StockSageResearchRanking.swift:114`) **is
already persisted** inside `Round.user` JSON (built `:466-471`, refreshed `:462`). `Candidate`,
`ClassCoverage` and `Fact` are `private`, which is the only reason a view cannot decode them — so a
read accessor would be cheaper than a new `Prediction` field and would avoid touching the
legacy-stable encoding.

**But it is not the same number.** `classSummary` counts only what a candidate **cited**, is empty
on receipt versions 1 and 2, and exists only for candidates that entered a comparison round. Task 6
asks for coverage of the evidence *offered*. Using `classSummary` for it would under-report every
class the model did not cite, and an absent class would render as "no evidence of that class" —
a missing-as-negative-evidence failure.

**Recommendation:** take `evidenceReceipt` on `Prediction` (A) as the real answer, and treat the
`classSummary` accessor as a separate, optional nicety for "what did the ranker actually cite".

## D. Items that need an owner decision, not a field

- **Counterevidence IDs** (Task 23 bullet 2). No counterevidence identifier is produced anywhere
  today. Do not invent a tag. The honest minimum is a derived accessor —
  `var uncitedOfferedKeys: [String] { offeredKeys.filter { !citedKeys.contains($0) } }` — which is
  "offered but not cited", **not** "counterevidence". Naming it counterevidence would assert a
  judgement the model never made. Task 19 is where real counterevidence typing belongs.
- **"Overnight context"** (Task 23 bullet 1 filter). Undefined in the persisted model and blocked on
  Tasks 11–13. **Do not add a filter whose predicate cannot be evaluated** — an overnight filter
  that silently matches nothing is worse than no filter.
- **Win-rate claims** (Task 23 bullet 4). Nothing to request: the correct outcome is that the view
  computes **no rate at all** until the benchmark has settled outcomes. If a gate is ever wanted it
  belongs with Task 20, not here.

## E. Honesty rules I will implement on the view side

- `nil` quality renders as **"quality was not assessed for this saved run"** — never `.unverified`,
  never a negative badge. Historical prose in `reason` is never re-scanned to synthesise a state.
- `.dataUnavailable` describes the **evidence**, not the company; copy must not read as a warning
  about the stock.
- A missing `promptVersion` is never defaulted to the current one — that would retroactively claim
  a legacy receipt came from today's prompt.
- `prediction.facts.count` is the count of facts that **fit the prompt**, not the count offered;
  it is never presented as "offered".
- Insider: four distinct states (not recorded / checked-and-none / not-checked-or-unavailable /
  transactions present), with empty implying "no activity" **only** when captured source coverage
  confirms it.
