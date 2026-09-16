# Qwen → Gemma 4 31B removal audit

Date: 2026-09-16. Owner directive: "i dont want qwen anymore i have gemma4 31b."

Produced by a 199-agent multi-phase workflow (survey across six lenses — config, behavioral,
userFacing, lifecycle, tests, docs — then adversarial two-verifier classification of every
config/behavioral/lifecycle finding, then synthesis). Zero agent errors, zero empty results.
31,264,153 subagent tokens, 4,276 tool calls, ~60 minutes wall-clock. Run ID `wf_d0d7e79f-820`
(resumable via `Workflow({scriptPath: <see below>, resumeFromRunId: "wf_d0d7e79f-820"})` — cached
agent results replay instantly; scriptPath =
`/Users/saleh/.claude/projects/-Users-saleh-StockSage-wt-research-pipeline-20260915/4ed4d65a-a4a7-47fb-bc58-86a75dee1bc6/workflows/scripts/qwen-to-gemma-audit-wf_d0d7e79f-820.js`).

**Totals: 265 findings — 0 safe to change with no further work, 68 need a Gemma-specific
measurement before changing, 169 cosmetic (comments/docs/test-fixture naming).**

This document is the workflow's own synthesized plan, unedited. It has NOT been executed yet.
Read [[salehman-gemma-research-quality-plan]] memory for the live status of the broader
23-task research-quality plan this audit runs alongside.

---

# Ordered plan: make Gemma 4 31B the model, remove Qwen as a product surface

Repo root: `/Users/saleh/StockSage-wt/research-pipeline-20260915`. Gate for every step: `bash tools/gate.sh /Users/saleh/StockSage-wt/research-pipeline-20260915 all` (macOS + iOS emit-module + test typecheck), then the real Xcode Mac + iPhone test run. Every step below is green on its own and is one commit.

---

## Step 0 — Measure before you touch a constant (no code, blocks steps 6–7)

Three captures from the owner's machine, saved next to the existing receipts in `/Users/saleh/StockSage-harness-20260910.opus/`:

1. **Weights identity.** `curl -s http://127.0.0.1:1234/api/v1/models`. Diff the row for `google/gemma-4-31b-qat` against the five fields the allow-list at `StockSage/Sources/StockSage/StockSageLocalModelServer.swift:559-566` requires: `format == "gguf"`, `architecture == "gemma4"`, `params_string == "31B"`, `quantization.name == "Q4_0"`, `quantization.bits_per_weight == 4`. Also record `loaded_instances[].config.context_length` and `parallel` — `verifiedContext` (`:634-651`) hard-requires `context_length >= 16_384` **and** `parallel == 1` for `gemmaModel`, and `StockSageLocalModelStartup.readyProbe` (`StockSageLocalModelStartup.swift:122-127`) repeats the context floor. If the real inventory differs, fix the download or record the real values — **never widen the allow-list**; that is untested-weights substitution, which the comment at `:547-548` exists to forbid.
2. **Tokenizer bound.** Re-run `/Users/saleh/StockSage-harness-20260910.opus/calibrate_budget.py` with `MODEL = "google/gemma-4-31b-qat"` and `BASE = "http://127.0.0.1:1234"` (then `:18080`). The script recovers real counts from the server's own `usage.prompt_tokens`, so it is model-agnostic. Add the adversarial class the current sample set lacks (details in §7).
3. **Output-cap headroom.** One real request per caller prompt at its shipped cap; record `finish_reason`.

Nothing in this worktree contains a Gemma tokenizer or KV receipt — `grep -rli gemma agent-docs` returns only `AI_MODEL_HARNESS_RESEARCH_2026-09-10.md`, which cites model cards, not measurements. Do not let anyone "re-derive" these from memory.

---

## Step 1 — Truthful comments only (zero behavior change)

Rewrite only prose. No value moves.

- `StockSageLocalModelServer.swift:11` — "tested: Ollama 0.33.3, qwen3.8, loopback 127.0.0.1:11434" → keep as *history* (it is a dated smoke test), but mark it as the historical Ollama case, not the shipped default.
- `:178-207` (the `researchContextTokens` justification) — the whole cost derivation is Qwen3.5 hybrid arithmetic (`full_attention_interval` 4 over 64 layers, Gated DeltaNet, 4 KV heads × 256 dim → 64 KiB/token) and the "LM Studio auto-fits this model to a 262,144 runtime window" line is a qwen3.5-9b observation. Delete the architecture arithmetic and that sentence; keep the two claims that survive the model swap (Ollama receives `contextTokens` verbatim as `num_ctx`; 16,384 is what makes every caller's 12,000-byte packet fit) and add one line: *KV cost for gemma-4-31b-qat is not derived here; the value is a request target and a readiness floor, not a memory claim.*
- `:216-228` — keep "measured on qwen3.5-9b", add explicitly: *the ≤1-token-per-NFC-byte property and the 128-byte framing allowance are UNVERIFIED for google/gemma-4-31b-qat.*
- `:359` Probe.detail example and `:367` `stripLatestSuffix` example — swap the `qwen3.8` illustrations for a neutral name.
- `StockSageChat.swift:12-16` — same treatment; it carries an independent copy of the same claim backing a *different* reserve (1,024).
- `StockSageCatalystNarrator.swift:211`, `StockSageLocalSentiment.swift:125`, `StockSageLocalModelServer.swift:653` — these document real past defects; keep them, but make clear they describe Ollama/`:latest` rules, not current Qwen support.

Test: the full suite must be byte-identically green. If anything changes, the "comment-only" claim was false.

---

## Step 2 — Messages name the model that answered

This is independent of the removal and worth landing first, because it is what makes every later message honest.

`StockSageAIAssessment.ValidationFailure.explanation` (`StockSageAIAssessment.swift:643-660`) is a `var` with no model in scope, and hardcodes "Qwen" four times. Change it to `func explanation(model: String?) -> String` with `let who = model.map { "The model \($0)" } ?? "The model"`:

| line | replacement |
|---|---|
| `:645` | `"\(who) included numerical claims in its opinion. Use the captured figures below; this opinion did not pass validation."` |
| `:647` | `"\(who) did not provide valid references to the supplied evidence. No opinion was accepted."` |
| `:655` | `"\(who) stated earnings timing or a probability that the captured research does not establish. Use the earnings window check and original evidence; no opinion was accepted."` |
| `:657` (default) | `"\(who) did not return the required complete answer format. Retry this research; no partial opinion was accepted."` |

Call sites both have the reply in hand: `StockSageHorizonResearch.swift:1144` → `failure.explanation(model: completion.model)`; `StockSageAIAssessment.swift:1065` → `...?.explanation(model: completion.model)`. Use the **reply's** model (`completion.model`), not `config.model` — the seam has already rejected an identity mismatch at `:1141-1152`, so the reported model is the one that actually answered; fall back to `config.model` where in scope and to the neutral "The model" otherwise.

Same pass for `StockSagePaperAutomation.swift:930/940`, which do have `config` in scope:

- `:930` → `"Model request failed (\(config.model)); \(summary). No paper order. Scheduled exits remain active."`
- `:940` → `"Model response rejected (\(config.model)); \(summary). No paper order. Scheduled exits remain active."`

New test (`StockSageTests/StockSageModelHarnessTests.swift`): `everyModelFacingMessageNamesTheAnsweringModel` — drive each path with a stub reporting `"fixture-model-A"` and assert the surfaced string contains it.

Optional, flag for the owner: `StockSageCatalystNarrator.swift:456/459` builds `.localServer(model: config.model)` — the *requested* model. Changing it to `completion.model ?? config.model` makes the label at `:336` ("Model-written by the local server model \(model)…") name what answered. It touches `StockSageCatalystNarratorTests.swift:542-544` equality cases. Worth doing, but it is a separate decision.

---

## Step 3 — Split the test fixtures off the shipped defaults (test-only)

This is the step that makes Step 7 a real test instead of a silent fixture mutation. Today ~20 sites use `S.defaultURL`/`S.defaultModel` to mean "a generic Ollama backend", so flipping the default would rewrite what those tests test while staying green.

Introduce test-local constants (e.g. in `StockSageTests/StockSageModelHarnessTests.swift`, referenced by the others):

```swift
static let ollamaFixtureURL = "http://127.0.0.1:11434"
static let ollamaFixtureModel = "fixture-ollama-model"
```

Re-point: `StockSageModelHarnessTests.swift:62, 79, 287, 306/309, 342/345, 355, 370/373, 381, 394/398, 409, 542/550, 561/567, 583/596`; `StockSageHorizonAnalyzeTests.swift:190, 211-212, 274, 321, 342, 685, 707, 714, 746, 775, 786, 875`; `StockSageModelDownloadTests.swift:145` (replace `S.defaultURL` with the literal `"http://127.0.0.1:11434"` — that test's whole point is Ollama-vs-LM-Studio unload branching at `StockSageLocalModelServer.swift:515`); `StockSageRunPodGemmaTests.swift:21` (the loop `[S.lmStudioURL, S.defaultURL]` is the *only* assertion that 11434 is in `supportsLocalUnload`'s allow-list — make it a literal or the loop degenerates to the same URL twice and proves nothing).

**Also in this step, strengthen `everyEvidenceHeavyCallerFitsItsDeclaredWindow` (`StockSageModelHarnessTests.swift:114-133`)** — today it computes the allowance from each caller's *raw* output tokens, but production passes `config.reservedOutputTokens(for:)` (`StockSageLocalModelServer.swift:311`), which **doubles** any initial value in `1...512` on a strict-output config. After Step 7 the strict path is the default path, so the guard must model it: build a strict Gemma config, use `config.reservedOutputTokens(for:)`, and add the missing binding caller — horizon at `outputTokens: 384` (the `qualify` path, `StockSageHorizonResearch.swift:705`). Have the test `print` the actual headroom above 12,000 so the framing-reserve ceiling in §2 is measured, not guessed.

If that strengthened assertion fails, that is the gate working. The fix is a larger measured serving window or less packed evidence — **never** lowering the 12,000-byte floor.

---

## Step 4 — Move the managed-profile coverage onto Gemma (test-only, Qwen still present)

Both managed profiles exist today, so this can land before anything is deleted — and it is what prevents Step 5 from silently deleting real coverage.

Build a hand-derived Gemma managed inventory fixture (gguf / gemma4 / 31B / Q4_0 / `bits_per_weight: 4`, with `loaded_instances[].config = {"context_length": …, "parallel": 1}` — `parallel` is mandatory for Gemma at `StockSageLocalModelServer.swift:644-648`). Per `testing-discipline` / `spec-fidelity`, derive the fixture from the Step 0 capture, do not copy the shape the new code emits.

Re-point these **real behavioral** tests from the 9B fixture to it (move them out of `StockSageModelDownloadTests.swift` into e.g. `StockSageTests/StockSageManagedModelLifecycleTests.swift`, since they are not about downloading):

`compatibleCopiesResolveTheLoadedInstanceRegardlessOfOrder` (:16), `ambiguousCopiesNeverConfirmContextOrUnload` (:49), `unloadedNativeInventoryIsPresentWithoutLoadingOrDownloading` (:72), `outputLimitRecoveryIsBoundedAndUsesTheSameEvidence` (:85), `nativeAbsenceIsNotInferredFromMalformedOrIncompatibleInventory` (:129), `quitUnloadsOnlySelectedModelAndVerifiesItIsGone` (:144), `quitCannotControlRemoteOrUnknownRuntime` (:172), `quitFailureIsNotReportedAsUnloaded` (:179), `quitWithUnresolvedJITDoesNotTreatEmptyInventoryAsConfirmedUnload` (:185), `bufferedAnswerRequiresServingContextWithinOriginalDeadline` (:193), `contextVerificationCannotExtendTheTotalDeadline` (:217).

Also re-point the managed cases in `StockSageLocalModelServerTests.swift:216, 380, 396, 429, 437, 444, 515, 532, 692`, `StockSageResearchRankingTests.swift:55/69`, `StockSageLocalSentimentTests.swift:10/21`, `StockSageHorizonAnalyzeTests.swift:98, 118, 128, 138, 212, 811, 816`.

Record two deliberate, unreplaceable coverage losses in the commit message (see §5).

---

## Step 5 — Delete the Qwen managed profile as one compile-checked unit

One commit, driven by compile errors (do not paper over any of them):

- `StockSageLocalModelServer.swift:211` `lmStudioModel`; `:320-324` `Config.isLMStudio9B`; `:301` collapse `isManagedLMStudio` to `isLMStudioGemma`.
- `:549` **make `modelKey` a required parameter** — do not re-default it to `gemmaModel`. Re-defaulting silently repoints `StockSageModelDownload.swift:109/155` and `StockSageHorizonAnalyzeTests.swift:85` with no compile error.
- `:550` guard → `guard modelKey == gemmaModel`; `:570-590` the whole Qwen branch (including the `parallel`-slot read at `:575-583` and the three detail strings at `:586-589`); `:637` allow-list → `model == gemmaModel`, making `:644` unconditional; `:677` `body["ttl"] = 180`.
- `Probe.canDownload` (`:361`) and the `prepare()` download branch (`:620-626`) — the Qwen branch was its only producer, so it is dead once that branch goes.
- `StockSage/Sources/StockSage/StockSageModelDownload.swift` entirely, plus `StockSageLocalModelServer.swift:45` (`StockSageModelDownload.shared.stopChecking()` inside `beginShutdown`).
- `StockSage/Sources/Views/CatalystsSection.swift:96` (`@State modelDownload`), `:478-499` (the "Use LM Studio · Qwen3.5 9B" button, its `.help`, the download panel, the `onChange(of: modelDownload.ready)`), and `:524-546` `modelDownloadControls`.
  **Move, do not delete**, the sentence at `:493`: *"Quitting StockSage unloads the selected local model from memory; downloaded files stay on disk. Force Quit cannot run this cleanup."* — it currently renders only inside the 9B block, and it is the only disclosure of the quit-unload contract. Put it in the Gemma block at `:469-475`.
- Delete the four genuinely download-specific tests (§5) and the two download-status pass-through cases (`StockSageHorizonResearchTests.swift:1217/1223`, `StockSageChatTests.swift:1446`).

`stocksage.modelDownload.receipt` becomes an orphaned UserDefaults key. Leave it (nothing can read it any more; removing it gains nothing), but note in the log that the app will no longer surface a paused or unacknowledged LM Studio transfer — that lives in LM Studio now.

This step is a **visual change** to the Mac settings pane → it needs a `visual-qa` pass, not just a green suite.

---

## Step 6 — What happens to a saved Qwen setting: **migrate once, plus a fail-closed backstop**

### The decision

**Migrate**, one time, at launch, through `StockSageLocalModelServer.setSetting` — *and* add a narrow profile-scoped refusal so the outcome cannot silently degrade if the value comes back.

### Why not the other two

- **Fail closed alone is not actually what happens.** After Step 5, a persisted `localModelServerModel == "qwen3.5-9b"` at `127.0.0.1:1234` still produces a valid `Config` (the model is free text, only trimmed and ≤512 bytes), but it stops satisfying `isManagedLMStudio`, so `requiresStrictOutput` goes **false** — and that silently disables, all at once: the `response_format` json_schema (`:681`), the truncated-verdict rejection (`:1174`), the post-response `verifiedContext` gate (`:1180-1191`), the fail-closed `identityMismatch ?? c.requiresStrictOutput` (`:1147`), the doubled output reservation and its same-evidence retry (`:311`, `:1157`), and the `isManagedLMStudio` half of the quit-unload guard (`:520`). Meanwhile `probe` falls through to `/v1/models`, which LM Studio *does* serve, so the settings pane reports "Reachable · OpenAI-compatible · model qwen3.5-9b present" while the honesty floor is off. That is fail-**open**, and it is the single most dangerous outcome of this whole change.
- **Prompt on launch** would be honest but is a modal on first run for a setting most users never typed, and it still leaves the fail-open window until they answer.

### The migration, concretely

New file `StockSage/Sources/StockSage/StockSageModelIdentityMigration.swift`, called from `StockSageApp.init()` immediately after `StockSageMassiveCredential.beginLaunch(...)` (`StockSage/Sources/App/StockSageApp.swift:95-97`) — **not** from `applicationDidFinishLaunching`, which runs in the XCTest host and would rewrite the owner's real `UserDefaults.standard` during `xcodebuild test`. `init()` is already inside `guard !StockSageStore.isRunningTests else { return }` and is this repo's only launch-migration precedent. Take `defaults: UserDefaults` as a parameter, like `StockSageMassiveCredential.migrate(defaults:storage:)`, so it is unit-testable.

```
markerKey   = "stocksage.modelSettings.migratedTo"
inProgress  = "gemma-4-31b-qat.v1.inProgress"
done        = "gemma-4-31b-qat.v1"
retired     = ["qwen3.8", "qwen3.5-9b"]   // compared after trimming + :latest stripping
```

1. If marker == `done`, return.
2. Read `modelKey`. If nil, write `done` and return — a fresh install gets the new default constant and must never be marked unmigrated.
3. If the saved model is not in `retired` (and is not a half-migrated `gemmaModel` on a non-Gemma endpoint), write `done` and return — a deliberate choice is never overridden.
4. Destination, computed from the **pair**:
   - saved URL is loopback `:1234` → model = `gemmaModel`, **URL unchanged** (LM Studio Gemma)
   - saved URL is loopback `:18080` → model = `gemmaModel`, **URL unchanged** (RunPod Gemma)
   - anything else (`:11434`, custom, LAN) → model = `gemmaModel` **and** URL = `lmStudioURL`
5. Write marker `inProgress`, then **model first, then URL**, both via `setSetting` (so `revisionKey` bumps, in-flight requests are invalidated, and the narration cache at `CatalystsSection.swift:851` — which includes `serverModel` — correctly misses). Model-first matters: URL-first would transiently produce `qwen3.5-9b @ :1234`, the old download trigger. Then write `done`.
6. Because the decision is a function of the pair, an interrupted run (`inProgress` + `gemmaModel @ :11434`) completes correctly on the next launch.
7. **Never** write `StockSageLocalModelStartup.enabledKey` (`stocksage.model.autoLoadOnLaunch`) and **never** write `backendKey`. Auto-loading a 31B at launch stays the opt-in it is today.

### The backstop

Add to `Config`:

```swift
nonisolated var isRetiredManagedIdentity: Bool   // model ∈ retired, loopback, port 1234 or 18080
```

`requestFailure` (`StockSageLocalModelServer.swift:374-386`) returns `.invalidConfig` for it, and `probe` returns `hasModel: false` with detail: **`"The Qwen managed profile was removed. \(c.model) is no longer served here — choose Gemma 4 31B in Model settings, or use a different endpoint."`**

Scope is deliberate: **only on the two managed ports**, where those names used to select a profile whose guarantees no longer exist. On `:11434` or any other endpoint, `qwen3.8` remains a perfectly serveable generic model — no strict-output guarantee was ever claimed there, so nothing silently downgrades, and the server stays generic (§6).

### Tests (all real behavioral)

`retiredLMStudioIdentityMigratesModelOnlyAndKeepsItsEndpoint`, `retiredOllamaIdentityMovesToTheManagedLMStudioProfile`, `aDeliberateNonRetiredModelIsNeverRewritten`, `migrationRunsOnceAndDoesNotStompALaterOwnerChoice`, `migrationBumpsTheSettingsRevision`, `anInterruptedMigrationCompletesOnTheNextLaunch`, `migrationNeverEnablesAutomaticStartupOrChangesTheBackend`, `retiredQwenIdentitiesAreRefusedOnManagedPortsAndStillAllowedElsewhere`. All on an injected `UserDefaults(suiteName:)` with `removePersistentDomain` in `defer`, per the repo convention.

---

## Step 7 — Flip the shipped default (both constants, one commit)

```swift
static let defaultURL   = lmStudioURL     // "http://127.0.0.1:1234"
static let defaultModel = gemmaModel      // "google/gemma-4-31b-qat"
```

Reference the constants, never re-type the literals; declaration order forces moving `defaultURL`/`defaultModel` below the `nonisolated static let` block at `:210-212` (or making them computed). They are read independently in seven places (`StockSageApp.swift:23-24`, `CatalystsSection.swift:93-94`, `StockSageLocalSentimentView.swift:8-9`, `StockSageChatSection.swift:18-19`, `StockSageLocalModelStartup.swift:26-27`, `StockSageCatalystNarrator.swift:525-533`, `StockSageAIAssessment.swift:833-834`) — changing one without the other ships an unservable pair, so they move together or not at all.

New test: `theShippedDefaultIsTheManagedGemmaProfile` — `#expect(S.config(url: S.defaultURL, model: S.defaultModel)?.isLMStudioGemma == true)` and `requiresStrictOutput == true`.

Two consequences to state in the commit and in the settings copy, not discover later:

- A fresh install's first "Explain"/assessment now routes through `prepare()` → `StockSageLocalModelStartup.ensureLoaded` (`:615-618`), which opens `/Applications/LM Studio.app` and POSTs `api/v1/models/load` — an active 31B load, where today it was a read-only `/api/tags` probe. Launch-time auto-start is still gated behind `enabledKey` (default false).
- `chatRequest` moves from the Ollama branch (which sends `options.num_ctx = contextTokens`) to the OpenAI branch (which does not). `researchContextTokens` stops being a value the app *sets* and becomes a value it *assumes* — protected on the Gemma path only by `readyProbe`'s `context >= researchContextTokens` gate and the post-response `verifiedContext` check. Chat clamps to the real window (`StockSageChatSection.swift:647`); research callers do not.

---

## Step 8 — User-facing string sweep

| file:line | current | replacement |
|---|---|---|
| `StockSageAIAssessment.swift:875` | "Choose a reachable loopback **Qwen** server in Catalysts → Explanation model…" | "Choose a reachable loopback **model** server in Catalysts → Explanation model. Off/on-device-only disables AI badges. Remote iPhone serving is not configured here." |
| `StockSagePaperAutomation.swift:211` | "**Qwen** paper simulation; assumed costs, not a broker fill." | "**Model-research** paper simulation; assumed costs, not a broker fill." (future records only; past notes keep their text) |
| `StockSagePaperAutomation.swift:760` | "Selected \(n) for **Qwen**:" | "Selected \(n) for **model research**:" |
| `StockSagePaperAutomation.swift:767` | "Local **Qwen** is disabled or not configured." | "The **local model server** is disabled or not configured." |
| `StockSagePaperAutomation.swift:779, 792` | "**Qwen** research \(f)/\(n) completed…" | "**Model** research \(f)/\(n) completed…" |
| `StockSagePaperAudit.swift:53` | `"scope": "Committed native **Qwen** paper account…"` | "Committed native **model-research** paper account…" (changes exported bytes going forward; no test pins it) |
| `StockSagePaperAutomationPanel.swift:106` | "Preparing market data and **Qwen**…" | "Preparing market data and **\(serverModel)**…" — thread `@AppStorage(StockSageLocalModelServer.modelKey)` into the panel; this describes an in-flight request whose model is known |
| `StockSagePaperAutomationPanel.swift:111` | "\(symbol) · Checking sources and **Qwen**…" | "\(symbol) · Checking sources and **\(serverModel)**…" |
| `StockSagePaperAutomationPanel.swift:355` (×3), `:356` (×1) | "**Qwen** receives completed minute bars…", "…independently of **Qwen**.", "…not individually analyzed by **Qwen**." | "**The model** receives…", "…independently of **the model**.", "…not individually analyzed by **the model**." (policy prose, no request in flight — generic is correct here) |
| `OnboardingSheet.swift:26` | "After every check, **Qwen** compares…" | "After every check, **the local model** compares…" |
| `OnboardingSheet.swift:28` | "**Qwen** opinions and the ranking are unvalidated…" | "**Model** opinions and the ranking are unvalidated…" |
| `StockSageHorizonResearch.swift:577` | "Enable web access and the local **Qwen** model in Settings to retry Top 5…" | "Enable web access and the local **model** in Settings to retry Top 5. Original checks retained." |
| `StockSageHorizonResearch.swift:724` | "Enable web access, Massive and the local **Qwen** model in Settings…" | "Enable web access, Massive and the local **model** in Settings. No scan started." |
| `StockSageChat.swift:154` | `source: "StockSage rules, not **Qwen**"` | `source: "StockSage rules, not **the model**"` — this string goes *into* the prompt as a fact source; no test pins it (verified) |

Already correct, leave alone: `StockSageCatalystNarrator.swift:336` interpolates the actual model; `StockSageLocalModelStartup.swift` and `StockSageLocalModelServer.swift:431/440/567-568` already say "Gemma 4 31B" and are reached only on Gemma profiles.

**Do not rename** (persisted identifiers — renaming silently destroys owner state): `StockSagePaperAutomation.enabledKey = "stocksage.qwenPaper.enabled"` (`:9`) and the on-disk directory `StockSageQwenPaper/account.json` (`:284`).

---

## Step 9 — Docs, log, gate, visual QA

`HANDOFF.md` / DEVELOPMENT_LOG entry; mark `agent-docs/MODEL_DOWNLOAD_2026-09-12.md` retired; fix `agent-docs/API_VERIFICATION_2026-09-07.md:238` ("the CODE DEFAULT `127.0.0.1:11434/api/tags`"). Leave `agent-docs/QWEN_*.md`, `LOCAL_QWEN_2026-09-07.md` and the harness receipts untouched — they are the provenance for the numbers being re-measured. Full Mac + iPhone gate, then `visual-qa` on the Model settings disclosure (Mac: buttons/toggle/status line; iPhone: the URL/Model fields and the non-loopback warning still render, and the deleted download block leaves no gap).

---

## 2. Constants that MUST NOT change without a Gemma measurement

Rule applied throughout: **under-using Gemma's context is acceptable; overflowing is not.**

| identifier | file:line | why it is Qwen-derived | safe interim |
|---|---|---|---|
| the bytes≥tokens bound in `promptFits` / `maximumUserBytes` / `fit` | `StockSageLocalModelServer.swift:229-295` | Sound only because Qwen3.5 uses NFC + byte-level BPE. Gemma-family tokenizers are SentencePiece-derived; NMT_NFKC normalization can **expand** (U+FDFA: 3 NFC bytes → ~33 bytes), and a dummy-prefix token adds a token with no input bytes. If it fails, it fails toward **overflow**. | Keep 1 byte = 1 unit, and add the one hedge that removes the known failure mode without any measurement: budget on `max(precomposedStringWithCanonicalMapping.utf8.count, precomposedStringWithCompatibilityMapping.utf8.count)`. NFKC can shrink (ﬁ→fi) or grow (U+FDFA), so the max upper-bounds both. Costs allowance only on text containing compatibility characters. Measurement (§7.1) is what lets you drop the hedge. |
| `- 128` framing reserve | `StockSageLocalModelServer.swift:245` | Measured as 34 units on Qwen's verified two-string-message non-thinking template. Gemma uses `<start_of_turn>`/`<end_of_turn>` and has no native system role, while `chatRequest` (`:666-670`) always emits a separate `system` message. | **Never lower it.** Keep 128 (≈4× the measured Qwen framing). If measurement says raise it, the ceiling is bounded above by Chat's own 1,024 reserve (`chatOwnBudgetStaysInsideTheSeamBudget`) and by the 12,000-byte floor at the binding caller (horizon-fortnight at doubled 384). Read the exact headroom from the `print` added in Step 3 — do not take a number from this plan. |
| `researchContextTokens = 16_384` | `StockSageLocalModelServer.swift:208` | The **value** is caller-side arithmetic and transfers; the **justification** (`:190-207`) is Qwen hybrid-attention KV arithmetic and does not. | Keep 16_384 byte-for-byte. It is pinned by live Gemma gates (`StockSageLocalModelStartup.swift:124`, `runPodCapacity` at `:481`) and by boundary tests (`StockSageRunPodGemmaTests.swift:58/66/72` straddle 16384-inclusive vs 8192-rejected). Rewrite only the comment (Step 1). |
| `StockSageChat.contextTokens = 32_768`, `outputTokens = 512`, `- 1_024` | `StockSageChat.swift:8-17` | Independent copy of the same Qwen tokenizer claim, different reserve. | Keep. Chat already clamps to the real window (`StockSageChatSection.swift:647`), so it is the least exposed. |
| output caps 192 / 240 / 256 / 384 / 512 / 170 / 16 | `StockSagePaperAutomation.swift:19`, `StockSageHorizonResearch.swift:12` and `:705`, `StockSageAIAssessment.swift:962`, `StockSageResearchRanking.swift:123`, `StockSageChat.swift:9`, narrator, `StockSageLocalSentiment` (`maxTokens: 16`) | Qwen-era completion lengths. Under the strict profile, `finish != .stop` is a **hard** `.incompleteOutput` rejection (`:1174`), so an under-sized cap turns a complete verdict into a refused one. | Keep. Raise only after §7.4; note raising shrinks the byte allowance, which the strengthened 12,000-byte floor test gates. |
| the Gemma inventory allow-list (`gguf` / `gemma4` / `31B` / `Q4_0` / `bits_per_weight 4`) | `StockSageLocalModelServer.swift:559-566` | Not sizing at all — weights identity, on the per-request hot path via `verifiedContext` (`:1178-1191`). | Keep **byte-for-byte**. If the owner's real inventory disagrees, fix the download; widening the predicate is the untested-weights substitution `:547-548` forbids. `StockSageLocalModelServerTests.swift:39-60` pins all five reject scenarios — do not edit those assertions. |
| `Config.reservedOutputTokens(for:)` doubling | `StockSageLocalModelServer.swift:311` | Not Qwen-derived, but it is what makes the default flip silently shrink every caller's evidence allowance. | Unchanged in code; **modelled** in the strengthened guard test (Step 3). |

---

## 5. Test inventory — naming artifact vs real behavioral assertion

**Pure naming artifacts (rename the literal; never touch the assertion):**
`StockSageQwenDiagnosticsTests.swift:5/7` (file + suite + struct name; the config inside is already `"fixture-model"`) → `StockSageModelDiagnosticsTests.swift`, suite "Model bounded diagnostics". `StockSageAIAssessmentTests.swift:5` (`@Suite("Qwen primary assessment")`), `:104`, `:835` ("fixture-qwen"). `StockSagePaperAutomationTests.swift:8`, `:28`, `:1599/:1640/:1665` (defaults suite names). `StockSageChatTests.swift:506, 1031, 1651-1675, 1931, 1966, 2041-2074, 2085-2086, 2129-2131`. `StockSageHorizonResearchTests.swift:557` ("Unvalidated Qwen research." is an arbitrary non-receipt string). `StockSageLocalModelServerTests.swift:544/549, 556, 607/609, 637/646, 738` — rename to something plainly generic like `"fixture-model"`, **not** to `gemmaModel`, so they keep exercising the generic path.
`StockSageCatalystNarratorTests.swift:282-283, 417, 431, 449, 479, 498, 542-544` — the literals are artifacts, but the surrounding `#expect(text.contains(model))` is a **real** assertion that the label names the model. Swap literals, keep assertions.

**Real behavioral assertions, re-pointed at a Gemma managed fixture (Step 4), never weakened:** the eleven lifecycle tests listed in Step 4, plus `StockSageLocalModelServerTests.swift:216, 396, 429, 437, 444, 515, 532, 692`, `StockSageResearchRankingTests.swift:55/69`, `StockSageLocalSentimentTests.swift:10/21`, `StockSageHorizonAnalyzeTests.swift:98, 118, 128, 138, 212, 811/816`.

**Real behavioral assertions that survive unchanged:** `StockSageLocalModelServerTests.swift:21-60` (Gemma canonical identity + all five variant rejections, including the `"qwen3_5"` architecture negative at `:44` — **keep that literal**, it is the case proving a Qwen variant cannot pass a Gemma gate), `:73-132` (identity/finish/serving-context, retry deadline), all of `StockSageRunPodGemmaTests.swift`, all of `StockSageLocalModelStartupTests.swift` — including `:25`'s `(S.modelKey, "qwen3.5-9b")`, which is the negative case "a saved model with backend off must not auto-start"; it gets sharper after this change, not weaker.

**Deleted because the subsystem is deleted (not because they became inconvenient):** `StockSageModelDownloadTests.swift:253` `oneDownloadUsesCurrent6BitSourceAndRequiresInventoryConfirmation` (pins the Qwen HF URL body), `:287` `unsuccessfulChecksNeverRequestWeights`, `:306` `restartRetainsKnownJobAndUnknownSubmissionWithoutDuplicatePOST`, `:340` `completionWithoutCompatibleInventoryCannotClaimReady`; plus the download-status pass-through cases `StockSageHorizonResearchTests.swift:1217/1223` and `StockSageChatTests.swift:1446`. Do **not** rewrite these as Gemma downloads — there is no verified Gemma download source, and inventing one would be fabricating a capability.

**Coverage genuinely lost, with no replacement — log it, do not hide it:**
1. **LM Studio multi-slot parallelism.** `StockSageLocalModelServerTests.swift:380` and `:428` (the `parallel: 1/2/4/8` fixtures) and `StockSageHorizonAnalyzeTests.swift:85` (`researchParallelism >= response.parallelism`) exist only because the Qwen branch reads LM Studio's `parallel` slot. Gemma's branch never does, and `verifiedContext` forces `parallel == 1`, so **LM Studio Gemma research is serial by construction**. Consequence: `refreshCapacityAfterLoad` (`StockSageHorizonResearch.swift:767`) becomes a permanent no-op on LM Studio; only RunPod's `/props` still varies, covered by `StockSageRunPodGemmaTests`.
2. **The saved 9B throughput corpus.** `StockSageHorizonAnalyzeTests.swift:27` `syntheticThroughputPayloadExportAndValidation` is opt-in (`STOCKSAGE_THROUGHPUT_DIR`) and pins `manifest.model == Server.lmStudioModel`. Keep the test by pinning the **literal** `"qwen3.5-9b"` with a comment saying the corpus is a historical archive of a model the app no longer serves — that is honest and fixes the compile break; deleting it throws away a real measurement.

**Strengthened (allowed; the opposite of weakening):** `everyEvidenceHeavyCallerFitsItsDeclaredWindow` (Step 3), plus the new tests in Steps 2, 6 and 7.

---

## 6. Stays Qwen-capable vs removed

**Stays — the server is deliberately generic:**
`config(url:model:)` accepting any non-empty ≤512-byte model string on any http/https endpoint, including `qwen3.8`; the entire Ollama transport (`api/chat`, `think: false`, `options.num_ctx`, `api/tags`, `api/ps`, `api/generate` + `keep_alive: 0` unload, `stripLatestSuffix`) — `think: false` was measured against qwen3.8 but is an Ollama server flag, correct for any Ollama model; the generic OpenAI-compatible branch; `supportsLocalUnload` keeping `11434` in its allow-list; the free-text Server URL / Model fields at `CatalystsSection.swift:505-510`, which are the only way to reach any other model and the recovery path after migration; `StockSageLocalSentiment.swift:125`'s `:latest` tolerance; and every historical Qwen receipt in `agent-docs/` and `/Users/saleh/StockSage-harness-20260910.opus/`.

**Removed — the product surface:** `lmStudioModel`, `Config.isLMStudio9B`, `isManagedLMStudio` (collapsed to `isLMStudioGemma`), the Qwen branch of `managedInventory` with its parallelism read and three detail strings, `lmStudioModel` in `verifiedContext`'s allow-list, `body["ttl"] = 180`, `Probe.canDownload` and `prepare()`'s download branch, `StockSageModelDownload.swift` in full, the "Use LM Studio · Qwen3.5 9B" button and its download panel, and all Qwen product copy.

**Untouched — persisted identifiers:** `"stocksage.qwenPaper.enabled"`, `StockSageQwenPaper/account.json`, and (orphaned on purpose) `"stocksage.modelDownload.receipt"`.

---

## 7. What I am not confident about, and the measurement that settles it

1. **Does Gemma 4 31B QAT's tokenizer ever emit more tokens than NFC UTF-8 bytes?** This is the one that can cause an actual overflow, and it governs the path every user takes. Settle with `calibrate_budget.py` repointed at `google/gemma-4-31b-qat` on both `:1234` and `:18080`, with the four existing classes **plus** an adversarial class the current sample set lacks: U+FDFA/U+FDFB/U+FDFD and the U+FB50–U+FDFF and U+FE70–U+FEFF ranges, fullwidth U+FF01–U+FF5E, U+00BD/U+2153, NFD-decomposed Arabic and Vietnamese, ZWJ emoji, and multi-thousand-digit runs. Acceptance: `min bytes_per_unit >= 1.0` on **every** sample. Add the `response_format` json_schema and `reasoning_effort: "none"` the app actually sends — the Qwen run did not include them. Note Gemma-family tokenizers split digits individually, so `numeric_table` (already the tightest at 1.214 on Qwen) is the sample most likely to approach 1.0.
2. **Gemma's chat-template framing cost vs the 128 reserve.** Same script's `framing_system_units`, measured separately per transport (different template pipelines), and interpreted against Gemma having no native system role while `chatRequest` always sends one.
3. **Whether the owner's actual download matches the shipped allow-list, and serves ≥16K at `parallel == 1`.** `curl -s http://127.0.0.1:1234/api/v1/models`. If not, the default path fails `.contextBudget` on every request — a first-run brick, not a friendly badge.
4. **Whether Gemma completes each caller's schema inside 192/240/256/384/512/16 output tokens.** One real request per caller prompt; any `finish_reason: "length"` means the strict profile will refuse a good answer.
5. **Whether 16,384 is still cheap on a 31B Q4_0 on a 48 GB Mac.** Resident memory before/after load plus the reported `context_length`. The existing comment's KV arithmetic is Qwen-hybrid and does not transfer; do not re-derive it from memory.
6. **Product call, owner-only:** should the generic server still accept a Qwen model typed by hand at a non-managed endpoint? My plan says yes (refusal scoped to loopback `:1234`/`:18080`). If "i dont want qwen anymore" means *anywhere*, the refusal list becomes global — a one-constant change, but it costs genericity.
7. **Whether flipping `defaultURL` at all is wanted.** The lower-risk alternative is to leave the defaults as a generic Ollama pair and rely on Step 6's migration plus the two existing Gemma buttons, which already write backend + URL + model (+ auto-start) atomically. Flipping means a fresh install attempts a 31B load on its first Explain; not flipping means the shipped default names a model the owner does not run. I recommend flipping **and** saying so in the settings copy — but it is a product decision, and Steps 1–6 are valuable and shippable without it.
8. **Whether `Source.localServer(model:)` should carry the reported rather than the requested model** (Step 2's optional tail). It is strictly more honest; it touches `StockSageCatalystNarratorTests.swift:542-544`.