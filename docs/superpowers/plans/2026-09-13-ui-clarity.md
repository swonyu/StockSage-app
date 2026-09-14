# StockSage UI clarity implementation plan

> Execute inline with test-first checks; the lead remains sole writer and gate owner. The bounded Spark source inventory is read-only.

**Goal:** Make existing research, Chat and paper monitoring understandable without changing financial behavior.

**Architecture:** Reuse the native sidebar, Table, Picker, DisclosureGroup and existing presentation helpers. No new dependencies or persistence. Preserve the unfinished Unicode-schema fix.

## Critique and acceptance

| Finding | Evidence | Change and acceptance |
|---|---|---|
| U1 Research only filters buys; 31 incomplete rows previously required manual hunting | Actual Research view source and owner screenshot | Replace Boolean with All / Buy or Strong Buy / Incomplete / Not checked picker; filter never changes results or starts a scan; whitespace search matches |
| U2 Failure explanation contains dense transport metadata | Owner WFC screenshot; Result.note producer and detail renderer | Keep explanation visible; move the exact recognized diagnostics suffix into a native disclosure; unfamiliar notes remain fully visible |
| U3 Only individual work spins; totals crowd narrow windows | Research panel source | Show determinate checked/total progress, explicitly not successful opinions; wrap summary in narrow layouts; retain per-stock indeterminate work |
| U4 Scenario column names truncate | Owner Research screenshot and current width constraints | Short Stop / Target headings with scenario qualification, full accessibility labels and help; keep original values and explain missing levels |
| U5 Results disappear on quit; warning buried in assumptions/help | In-memory Scan state and panel | Persistent short notice beside research controls: quitting clears temporary results, a new run replaces them |
| U6 iPhone composer duplicates older editing/error and accessibility behavior | Spark inventory verified against shared Chat code | Reuse QuestionField and warning helpers, expose count and attributed links on both platforms; both validation and storage errors remain visible |
| U7 candidate: iPhone paper markup differs | Independent real-caller review found this panel is macOS-only; iPhone intentionally shows the Mac-only account notice | Withdraw this candidate. Keep the Mac-only boundary and remove the unused iPhone refactor; no account mutation |

## Implementation

- [x] Add regression coverage in existing HorizonResearchTests and ChatTests. Filter checks use synthetic results and preserve order; diagnostics checks preserve unknown notes and the appended omission warning. Existing render fixtures check narrow/wide controls and no side effects.
- [x] ResearchModesPanel: `Presentation.filter` replaces `buysOnly`; one `filteredListings` helper applies the actual predicates. Clear filter/selection only on existing transitions. Preserve the known receipt in disclosure and keep the omission warning outside. Use native overall ProgressView and adaptive summary. Shorten table headings and surface lifetime notice.
- [x] ChatSection: reuse current field and warnings; make platform-neutral helpers shared. Keep desktop focus/keyboard shortcuts scoped to macOS and do not imply iPhone local-model connectivity.
- [x] PaperAutomationPanel candidate withdrawn after caller verification: unchanged, because the iPhone production route intentionally does not instantiate it.
- [x] Run focused native tests, inspect real hosted-view PNGs, then freeze source and run canonical Mac and iPhone suites serially. Final Mac: 2,414 passed / 1 opt-in skip / 0 failed. Final iPhone: 2,334 passed / 0 skipped or failed. Exact candidate and remaining live-UI limitations are in `docs/reviews/2026-09-13-ui-critique.md`.

## Follow-up: complete U2 for failed requests

Confirmed remaining path: `StockSageAIAssessments.failureSummary` returns only
`Diagnostic.summary` for transport/preflight failures. Horizon research prefixes it
with “No verified opinion”; the detail splitter recognizes only `validation=`.
Ideas also bypasses the shared formatter for a failed initial request. Paper research
already uses the formatter. This is a presentation defect, not a reason to retry
forever or weaken financial acceptance.

- [x] Add an executed failing regression in `StockSageHorizonResearchTests.swift`:
  every existing failure category must supply a human cause, preserve the exact
  safe receipt and retain a trailing evidence-omission warning outside disclosure.
  Unknown note formats remain fully visible.
- [x] In `StockSageAIAssessment.swift`, reuse `StockSageLocalModelServer.cause(for:)`
  for assessment-specific wording; route the Ideas initial failure through the
  existing formatter. No Chat-specific timeouts or model settings are copied.
- [x] In `StockSageResearchModesPanel.swift`, also recognize the formatter's
  newline-delimited server receipt. Do not alter notes, records or verdicts.
- [x] Run focused red/green tests, independent source review, then serial canonical
  Mac/iPhone gates on frozen source. Preserve the exact Mac-tested candidate and
  record that live UI control remains unavailable. No installation or publication.

Final follow-up: Mac2,415 passed / 1 existing opt-in skip / 0 failed; iPhone2,335
passed / 0 skipped or failed. Both gates exit0 on the same frozen source. Native
failed-request component renders were inspected at360 and760 points. Full receipt
and installation/visual limits are in the review and top HANDOFF section.

## Verification / scope

Live Home and Research were inspected on the installed older build. Native-control connection then failed twice, including reset; remaining live screens are not claimed inspected. Source review covered native routes, market/ideas/watchlist/portfolio/alerts empty-state/control paths, Chat, Catalysts and Settings. No speculative redesign is justified without additional pixels.

Use existing `StockSageChatTests.capture` offscreen fixture infrastructure, not owner state. Primary guidance: [Apple lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars). No provider/model probes, history edits, new orders, push or install in this task.
