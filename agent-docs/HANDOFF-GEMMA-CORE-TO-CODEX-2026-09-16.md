# Handoff — Gemma/model-quality core, Claude → Codex, 2026-09-16

Owner instruction in Codex: *"u work on gemma"*. Codex takes the Gemma/model-quality core:
`InferenceProfile` (Task 5 part 2b), production `QualityReport` wiring, benchmark/validation
(Task 20) and inference speed (Task 21). I have stopped. **2b and the quality wiring were NOT
started** — no partial edit exists for either.

## State at handoff

| | |
|---|---|
| Worktree | `/Users/saleh/StockSage-wt/research-pipeline-20260915` |
| Branch | `codex/research-pipeline-fixes-20260915` (no upstream, nothing pushed) |
| HEAD | `53d40f2` — plus this document |
| Dirty paths | none, tree clean |
| Running workers | none — no xcodebuild, swiftc or swift-frontend |
| Background agents | none — the survey workflow completed (20/20, 0 errors) |
| Heavy-test lease | **released** |

Commits from my lane, oldest first: `1fb3495` Task 4 · `f7ed89c` Benzinga policy ·
`090771c` Task 5 (1/2) · `b532001` coordination · `d7df176` constraints · `146e1c4` Task 5 (2a) ·
`53d40f2` corrections.

Last measured test state: Ranking 23/23, Benzinga 17/17, LocalModelServer 34/34,
HorizonAnalyze 33 passed / 1 skipped. Gate `macos=OK tests=OK`. No full-suite run since `090771c`.

## What is already done in the core you are inheriting

- **`090771c`** — `researchTemperature` is the single source of truth for temperature; `chatRequest`
  sends it and the attempt observer records it, with a test that decodes the request body so the
  two cannot drift. `Diagnostic.retryReason` added (closed vocabulary, currently only
  `"outputLimit"`), carried in `summary`.
- **`146e1c4`** — both `context.coverage(...)` calls in `assessCaptured` now pass `packet:`.
  `packetVersion` / `classCounts` / `packetDigest` had been nil in **every** shipped receipt
  because no production call site ever passed the packet. This is the anchor Task 20 needs: without
  it two scores cannot be shown to cover the same evidence.

## Unpublished findings (not in any other doc)

1. **`QualityReport` has zero production callers but is well tested.** Declarations at
   `StockSageAIAssessment.swift:347` (`QualityReport`) and `:392` (`static func quality`). Nothing
   outside that file references either. **Grep for `A.quality(` or `quality(`, not `QualityReport`**
   — the tests never name the type, which is why a type-name grep reads as "no tests at all". There
   are 12 call sites in `StockSageAIAssessmentTests.swift` from `:1406`, covering
   `unresolvableCitation`, `insiderSaleFramedAsBuying`, `insiderIntentClaimed`, determinism, and
   the honest-framing negative cases. So the validator logic is built and proven in isolation;
   only Task 3 bullet 5 (publish the badge/receipt) is unwired.
2. **Live endpoint runtime, probed 2026-09-16** (`http://127.0.0.1:18080`, healthy, serving
   `google/gemma-4-31b-qat`): `n_ctx 16384`, `temperature 1.0`, `top_p 0.95`,
   `seed 4294967295` (= -1, i.e. **a fresh random seed per request**), `n_predict -1`.
   StockSage sends `temperature 0.2` but sends **neither `top_p` nor a seed**, so the server owns
   both. **Do not "fix" this by sending them without a re-benchmark**: prompt version 1 is frozen
   against a measured corpus (`StockSageAIAssessment.swift:486-492`), and new sampling parameters
   move the output distribution off that baseline. Record them as unpinned instead. This is also
   why a replay test must assert byte-identical **requests**, not identical **responses** — true
   response determinism is not currently achievable and claiming it would be false.
3. **`InferenceProfile` field spec** is published in
   `COORDINATION-CLAUDE-CODEX-2026-09-16.md` §8, including the two non-obvious constraints:
   `endpointProfile` must be a closed enum never a URL (an existing test asserts no endpoint string
   reaches an owner-readable payload), and `topP`/`seed` are nil on purpose.

## Traps that will cost you time if you rediscover them

1. **SourceKit diagnostics in this repo are systematically false.** Cross-file symbols are reported
   as "cannot find X in scope" and `Testing` as "no such module" on files that compile cleanly.
   Confirmed many times this session. **`tools/gate.sh [repo] [macos|ios|tests|all]` is the only
   ground truth for compilation.**
2. **Use `tools/runtests.sh` (serial).** Under a parallel full-suite `xcodebuild test` the same test
   names fail repeatedly across unrelated suites and all pass in isolation. Confirmed 7+ times.
3. **Simulator `3B0B0FE2-…` "iPhone 17 Pro (gate)" is in a bad state** — the whole
   `StockSageIOSPresentationTests` suite fails uniformly on it. Use
   `CC923127-11DD-4234-A379-457A667E9D4F` "iPhone 17 Pro (ios27)".
4. **`Receipt.fixture` in `StockSageResearchRankingTests.swift` builds a deliberately legacy
   receipt**: `version: 1` with `instructions(horizon:version: 1)`. If you bump the ranking prompt
   version again, pass the matching version there or three unrelated tests fail with an opaque
   `valid(...) == false`.
5. **Legacy byte-identity pattern**, required by the plan's global constraints: add stored fields as
   `var x: T? = nil` (or `= []`) and omit them when empty in a custom `encode(to:)`, so archives
   written before the field re-encode byte-identically. Precedents: `CompletedCheck.insiderTransactions`
   and the ranking `Candidate` Codable added in `1fb3495`.
6. **The purchased-product policy test has teeth on purpose.**
   `StockSageBenzingaTests.everyPurchasedProductReachesTheModelPacket` names the owner's six
   purchased Benzinga products as a literal list rather than `Product.allCases`, so deleting a case
   breaks compilation and dropping one from the packet fails at runtime. Verified to fail when a
   product is removed. Do not "simplify" it back to `allCases` — that is exactly the self-referential
   shape that let a product be deleted silently.

## Open items I am NOT carrying forward

- Task 5 part 2b (`InferenceProfile` record + persistence + `comparableCohort`) — spec in §8, not started.
- Production `QualityReport` wiring, shadow-only — not started.
- Tasks 10 and 19 adoption bullets remain blocked on Task 20's corpus.
- Tasks 11–13 remain blocked on Alpaca credentials and are outside both lanes.
- Still-standing schedule blockers B2 (start() returns false rather than queueing), B3 (Nasdaq
  holiday table is 2026-only, must fail closed in 2027) and B4 (recurring billed spend needs its
  own authorization), plus the 06:00 Riyadh ET date-rollover notes in §7 constraint 4.

Nothing was pushed, installed, restarted or extended. No paid resource was created or resumed.
