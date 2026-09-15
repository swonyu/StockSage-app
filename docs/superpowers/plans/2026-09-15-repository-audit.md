# Repository critique and repair plan

**Goal:** Review the current repository, document evidenced problems, and repair every accepted finding with appropriate verification.

**Baseline:** `11d63c94820460c1f500d03e952cb0011fdb0d34`, equal to remote `main` on 15 September 2026. Inventory: 486 tracked files, 368 Swift files and 24 supporting tool files. Work occurs on `codex/repository-audit-20260915` in the existing isolated checkout.

**Design:** Keep the approved charcoal/magenta native Mac/iPhone design. The user's subsequent requirements make 1–7 and 7–14 trading-day Research the primary product, limited to five Buy/Strong Buy results per horizon, with saved original predictions and later outcome checks. Retire new same-day runs while preserving legacy records. Correct problems at their shared source; reuse working implementations and native controls. The user authorized critique, planning, implementation and these product changes together. No dependencies, model loading, owner-record mutation or app replacement are required.

## Review coverage

- [x] Swift data flow, persistence, imports/exports, networking and trust boundaries (lead).
- [x] Research, feeds, financial calculations, portfolio and paper behavior (independent reviewer).
- [x] Mac/iPhone views, accessibility, navigation and truthful controls (independent reviewer).
- [x] Python/shell tools, build/test gates, project metadata and documentation (independent reviewer).
- [x] Consolidate findings with source evidence, severity, reproduction and disposition.

## Repair sequence

1. Reproduce accepted integrity/reliability defects with focused offline checks.
2. Repair the shared implementation and retain a regression check.
3. Remove misleading controls and platform-inappropriate flows; inspect resulting UI.
4. Repair tooling failures and update current documentation.
5. Review the integrated diff, freeze source, and run the Mac and iOS test gates serially.
6. Publish a critique and completion receipt with actual coverage, exclusions and remaining external limitations.

## Initial accepted findings

### A01 — Journal CSV accepts malformed quotation (P1)

Files: `StockSage/Sources/StockSage/StockSageJournalCSVImport.swift`, `StockSageTests/StockSageJournalCSVImportTests.swift`.

An unmatched quote in the final note is silently accepted; quotes inside unquoted values or trailing text after a closing quote are also concatenated into data. The parser must track field state and attach a physical-line error to the malformed record. Preserve valid multiline fields, escaped quotes, supported newline styles and valid neighboring rows. Compare header columns structurally, not by rejoining them.

- [x] Reproduce malformed-note, unquoted-quote, closing-quote-tail and malformed-header inputs.
- [x] Return explicit row errors before creating trades; verify ordinary round trips (native focused gate).

### A02 — Ideas CSV does not escape CRLF-only fields (P2)

Files: `StockSage/Sources/StockSage/StockSageIdeasCSV.swift`, `StockSageTests/StockSageIdeasCSVTests.swift`.

Swift treats CRLF as one Character, so this exporter misses it when searching for separate CR or LF Characters. The journal exporter already handles Unicode scalars correctly. Reuse that existing field escape function rather than maintain two implementations.

- [x] Reproduce with a rationale containing CRLF but no comma or quote.
- [x] Reuse journal CSV escaping; verify all newline styles (native focused gate).

Additional findings are appended after independent validation. Size, historical comments and unverified suspicions alone are not defects.

## Verification

Use isolated fixture preferences; never the owner's records. Root owns builds with four jobs and serial execution. Run the README's three standard exclusions (`CalibrationPersistRunTests`, `LiveUniverseVerificationTests`, `StrategyBaselineMeasurementTests`) and disable paper diagnostic opt-ins. Execute on macOS and the verified iOS 27 simulator; distinguish SDK/toolchain from runtime. Run offline Python/shell checks for touched tools. Inspect relevant native component captures. The installed application and physical device are separate from source verification.

### A03 — Settings advertises a disabled menu-bar scene (P2)

Files: `StockSage/Sources/App/StockSageSettings.swift`, `StockSage/Sources/App/StockSageApp.swift`.

The active “Show menu-bar ticker” toggle only writes a preference; the MenuBarExtra scene is parked. Remove the control, unused property wrappers and stale introductory claim. Preserve the parked scene and existing saved preference; do not re-enable the scene or change launch behavior.

- [x] Inspect native Mac Settings and confirm every remaining General control is connected.
- Validation: a presentation deletion; no new unit test or red baseline is warranted.

### A04 — Onboarding teaches an obsolete real-trade flow and does not fit large phone text (P2)

Files: `StockSage/Sources/Views/OnboardingSheet.swift`, `StockSage/Sources/App/StockSageSettings.swift`.

The welcome flow hardcodes 901 symbols, claims a stop-out loses exactly the planned fraction, asks for exact broker transcription, and exposes a Mac-only parent-app import on iPhone. Replace it with Home’s daily summary → Research horizons → saved evidence and outcomes → Watchlist/Chat → Portfolio/Journal. New same-day paper runs are retired under A32. Explain planned stop risk as an estimate affected by gaps, fills and costs. Keep manual broker review distinct from research and simulated results. Fence parent-app import to Mac and describe the existing Journal backup-restore route on iPhone. Put long content and import feedback in one scrollable region with a reachable Get started footer; preserve completion/import behavior.

- [x] Review copy against current destination names and paper-only scope.
- [x] Inspect first-launch/reopened sheets at Mac width 560 and iPhone width 375, including AX3; scroll to the final step and complete the sheet.
- Validation: native fixture checks are required; there is no claim of an executed red baseline for this presentation/copy repair.

### A05 — Unavailable Tape attribution reads as a checked-empty result (P2)

File: `StockSage/Sources/Views/StockSageTapeView.swift`.

When exchange-reference loading fails with Nasdaq only selected, every raw record is filtered out and the empty sections claim no matches. Show that Nasdaq attribution is unavailable instead. Reuse the existing NBBO side notice where appropriate and clear prior reference/notice state when a new symbol load begins. Keep raw tape access possible by changing the existing filter; do not infer Nasdaq attribution or silently change the user's filter.

- [x] Exercise missing reference, known Nasdaq matches, a checked window without matches, and filter-off raw records in isolated fixtures.
- [x] Verify a later successful symbol load does not retain the earlier failure notice.
- Validation: existing NBBO filter-notice tests cover the shared side classification; the Tape composition/reload requires fixture inspection. Any added message-state tests need a root-owned red baseline before a passing result is credited.

### A06 — Negative catalyst rows multiply secondary-text dimming (P2)

Files: `StockSage/Sources/Views/CatalystsSection.swift`, `StockSageTests/CatalystsSectionTests.swift`.

Secondary text at 0.66 white opacity is additionally dimmed by the row's 0.6 opacity, producing approximately 3.69:1 contrast on the current charcoal card. Remove the redundant row opacity while preserving the neutral secondary color and “No known catalyst” badge. Remove the test that enforces the defect; retain the existing neutral-color and badge classification tests. Native rendering must verify the composed row contrast.

- [x] Root executes the retained negative-record badge/classification tests.
- [x] Inspect a mixed calendar containing a real event and a negative record; both remain readable and semantically distinct.
- Validation: the deleted test pinned the defective 0.6 opacity. No new red regression is claimed for this presentation fix; root must inspect the native row.

### A07 — iPhone Log trade leaves Portfolio on Holdings or Analytics (P2)

File: `StockSage/Sources/Views/MarketsView.swift`.

All three Log trade actions call `prefillTradeFromIdea`, but selecting the Journal subpage is fenced to Mac even though the subpage picker is now shared. Select Journal on both platforms after prefilling the draft, before showing Portfolio. Preserve all draft values and require the existing explicit Save action.

- [x] From Holdings and Analytics on iPhone, invoke Log trade from the best opportunity, Home action and idea detail; confirm Journal opens with the expected unsaved draft.
- Validation: use the actual route fixture; do not add a test-only state abstraction for a platform fence removal.

### A08 — Journal close fields and confirmation overflow a narrow phone (P2)

File: `StockSage/Sources/Views/MarketsView.swift`.

Three fixed-minimum fields plus Confirm close exceed the 375-point phone viewport. Reuse the existing adaptive form approach, forcing a column for phone accessibility sizes and allowing a column when ordinary text does not fit. Preserve all close guards, reconciliation notices, preview calculations and cancel behavior. Use decimal keyboards for the two optional price fields as well.

- [x] Inspect the form at width 375 and AX3; all fields, Confirm close and Cancel remain reachable.
- [x] Use isolated long/short trade fixtures to confirm valid/invalid input and reconciliation retain existing behavior and exact typed optional prices.
- Validation: root owns native fixtures and existing journal close regressions; no standalone layout predicate test or subagent red execution.

### A09 — iPhone AI assessment disables its action without an explanation (P2)

Files: `StockSage/Sources/Views/StockSageAIAssessmentView.swift`, `StockSageTests/StockSageChatTests.swift`.

The phone's duplicate header has no disabled reason when another symbol is being assessed or sample data is active. Reuse the existing adaptive Mac RequestControls on both platforms, including its draft-aware Reassess title and busy/sample explanation. Preserve the request closure and assessment lifecycle.

- [x] Make existing RequestControls state tests available on iOS as well as Mac; execute busy-other-symbol, sample-data and draft cases.
- [x] Inspect a 375-point AX3 header to ensure the button and explanation wrap visibly.
- Validation: sharing the existing tested implementation does not have a new behavioral red baseline; the new platform compile and native fixture are required.

### A10 — Shared phone segments ignore Dynamic Type and touch size (P2)

File: `StockSage/Sources/DesignSystem/DesignSystem.swift`; existing caller fixtures in `StockSageTests/DesignSystemMotionTests.swift`.

The custom segment control uses a fixed 12-point font and approximately 26-point buttons on iPhone. Preserve Mac styling and motion behavior. On iPhone use a scalable native text style, at least 44-point interaction height, and a native menu picker at accessibility sizes or when the full segments do not fit. Retain selection labels and selected-state accessibility semantics.

- [x] Inspect all five callers: catalyst Cards/Calendar, market asset filter, price-alert direction, Journal side and fast-lane mode, at normal and AX3 phone text.
- [x] Root executes existing reduced-motion/selection fixtures on Mac and relevant phone fixtures.
- Validation: no new mirror-of-layout unit test; selection, labels and target size require actual native fixture checks.

### A11 — Portfolio overflow can create an unrestorable holding (P2)

Files: `StockSagePortfolio.swift`, `StockSagePortfolioTests.swift`.

- [x] Trace the shipped amount-entry form through storage and backup validation.
- [x] Add tests for nonfinite products/sums, preserved saved bytes, and unavailable percentages.
- [x] Reject nonfinite totals before saving; share aggregation validation without dropping invalid lots into a partial total. Preserve valid gifted lots and existing records.

### A12 — Corrupt history-cache dates can crash a scan (P2)

Files: `StockSageHistoryCache.swift`, `StockSageScanChunking.swift`, related date-key consumers and `StockSageHistoryCacheTests.swift`.

- [x] Trace decoded `savedAt` through normal scan partitioning to the trapping integer conversion.
- [x] Add extreme-date/array-shape regressions that fail before attempting the known trap.
- [x] Reject unusable cache dates/entries and protect date-key consumers; retain valid schema-2 caches and fetch again when a disposable cache is unusable.

### A13 — Explicit unfinished model replies can publish financial verdicts (P2)

Files: `StockSageLocalModelServer.swift`, financial completion callers, `StockSageModelHarnessTests.swift`, `StockSageAIAssessmentTests.swift`.

- [x] Trace initial assessment, repair, horizon and paper completion guards.
- [x] Add synthetic explicit filtered/tool/unknown/malformed finish cases.
- [x] Broaden the existing shared financial guard and its error wording. Preserve generic Chat text and documented absent-metadata compatibility; do not change strict 9B inference settings.

### A14 — Long weekends invalidate the latest completed daily history (P2)

Files: `StockSageMarketHours.swift`, `StockSageHorizonResearch.swift`, `StockSageAIAssessment.swift` and their existing tests.

- [x] Add literal Labor Day/Good Friday, missing-session and unsupported-year scenarios at both consumers.
- [x] Reuse the verified exchange calendar for source-specific completed daily history, preserving original timestamps, live-quote limits and the four-hour analysis lifetime.
- [x] Reconcile synthetic weekend-bar fixtures with their stated intent if strict session checks expose them; record the reason.

### A15 — Standalone runner bypasses test isolation (P1)

Files: `tools/runtests.sh`, `tools/test_runtests_status.sh`, `README.md`.

The old runner does not load XCTest, yet app isolation depends on `XCTestCase`. A fresh Foundation probe shows that changing HOME alone still resolves Application Support in the owner's home. Actual launch tests additionally require the native app bundle.

- [x] Replace duplicate dylib/runner compilation with Xcode's native test host, unique artifacts, four jobs and serial testing.
- [x] Preserve failure exits, reject successful zero-test runs, support build-only and exact-suite filters, and strip direct/SIMCTL_CHILD/TEST_RUNNER paper opt-ins.
- [x] Check mock native exits, empty runs, build dispatch, unique artifacts and all environment forwarding forms.
- [x] Execute the real native wrapper, then rerun its native command semantics against the final source with the isolated cached derived tree; record both receipts separately.

### A16 — Unknown compile-gate modes succeed without checking anything (P2)

Files: `tools/gate.sh`, `tools/test_gate_arguments.sh`.

- [x] Observe `gate.sh . invalid-mode` report all SKIP with exit0.
- [x] Reject invalid modes/extra arguments before creating output; use the selected toolchain and unique output directories.
- [x] Verify invalid arguments fail before compiler work.

### A17 — Tracked editor configuration selects another checkout (P2)

Files: `buildServer.json`, `.gitignore`, `README.md`.

- [x] Preserve the local original and its hash; untrack generated machine-specific configuration.
- [x] Ignore it and regenerate locally with `xcode-build-server config -project StockSage.xcodeproj -scheme StockSage`.
- [x] Verify the new workspace resolves to the current checkout and the tracked distribution omits it.

### A18 — Stale source archives and browser captures ship with source (P3)

Files: `.review-tmp/src.tar.gz`, three `.playwright-mcp/*.yml` files, `.gitignore`.

- [x] Inspect metadata without exposing captured private content; identify stale duplicate source and unreferenced generated pages.
- [x] Preserve all bytes under the task's private work folder, verify hashes, untrack and ignore the generated paths.
- [x] Confirm only the intended generated paths were removed from tracking.

### A19 — Concurrent import can overwrite output without --replace (P2)

Files: `tools/import_whatsapp_research.py`, `tools/test_import_whatsapp_research.py`.

- [x] Reproduce a second writer creating the destination after the initial existence check.
- [x] Publish ordinary imports atomically without replacing existing output; retain explicit replacement and 0600 permissions.
- [x] Verify preserved earlier bytes, intentional replacement, valid fresh output and temporary-file cleanup using synthetic messages.

Documentation corrections included with the relevant fixes: describe current destinations; include price alerts in backups; clarify that fallback typechecking covers Mac test code, not iOS-only tests/widgets; explain native runner arguments and local editor regeneration. Historical reports retain their dated provenance.

### A20 — Shortcuts silently omits unknown price freshness (P2)

Files: `StockSageIntents.swift`, `StockSageSpokenProvenanceTests.swift`.

Best Opportunity Now keeps speaking a ranked recommendation when the price timestamp is missing, future-dated or nonfinite, but its shared provenance helper returns an empty caveat. Preserve the answer while explicitly saying the price timestamp is unavailable and freshness is unverified. Preserve sample/cache precedence and dated answers; the parked menu-bar consumer receives the same correction.

- [x] Execute the production enum in a bounded Foundation probe: all three unusable-clock cases returned an empty caveat.
- [x] Replace the empty clause and update the existing native regression to verify all three cases.

### A21 — Unused shell-command policy advertises an absent capability (P3)

File: `StockSage/Sources/App/ToolPolicy.swift`.

The extracted app retains more than 170 lines of shell-command denylist/allowlist logic and comments referring to the parent application's ShellTool and command-approval UI. Repository-wide caller searches find no production or test references. This is not a security finding in a shipped shell executor: StockSage has no such executor. Remove the dead nested policy and misleading commentary; retain the actual Web access/Offline Mode gate.

- [x] Search all tracked source/test callers and confirm the nested CommandRisk has none.
- [x] Remove the inherited subsystem; verify existing network-policy tests and native builds.

### A22 — Shared singleton construction prevents isolated workflow verification (P2)

Files: `StockSage/Sources/Views/MarketsView.swift`, `StockSageTests/StockSageIOSPresentationTests.swift`; narrow Store input changes are lead-owned.

The existing `qaSection` and `qaDetailSymbol` select content but do not isolate dependencies. Constructing MarketsView initializes shared record stores, while appearance tasks start services. This prevents trustworthy native verification of the Journal routing/close repairs without reading owner state. Accept the existing concrete dependencies through the current initializer, retaining `.shared` production defaults, and suppress appearance services under the existing `isRunningTests` signal. Supply every dependency and preference suite explicitly in native fixtures; do not create another launch mode or a generalized routing abstraction. The Store's calibration and idea-seed paths must also consume isolated inputs before a workflow fixture is mounted.

- [x] Verify rendering and native Log trade/Close actions use only UUID-scoped fixture records and do not start refresh, streaming, monitoring or inference.
- [x] At 375 points and AX3, operate actual controls, inspect resulting Journal page/draft/record state, and distinguish native activation from direct callback checks.
- [x] Exercise onboarding completion, assessment availability, segment selections, Tape reference transitions and catalyst rows through production views.
- Validation: root owns compilation, native execution and review of fixture outputs; no subagent execution or screenshot-only claim of functional verification.

### A23 — Automatic velocity recording overwrites unreadable saved history (P2)

Files: `StockSage/Sources/StockSage/StockSageVelocityHistory.swift`, `StockSageTests/StockSageVelocityHistoryTests.swift`; visible summary warning in `MarketsView.swift` is UI-owner work.

The daily history store treated both missing and unreadable saved values as an empty history. After a usable launch scan, `MarketsView` automatically records the opportunity summary, replacing the unreadable bytes with a new one-day history. The same overwrite occurs if stored data becomes unreadable after a successful load. Treat only an absent key as fresh; reject unreadable or wrong-type existing values at load and again before saving. Preserve stored bytes and the last valid in-memory series on any rejected record, validate finite input and encoding before publication, and expose `lastError: String?` for the actual summary UI. Preserve legacy metric-basis rows and successful day-key reconciliation.

- [x] Root executed the production store in a UUID-scoped defaults probe: seeded damaged bytes were overwritten (`Corrupt history preserved: false`).
- [x] Implement fail-closed reads, candidate encoding before state publication, finite-input validation and a visible-error property.
- [x] Add a parameterized regression covering unreadable/wrong-type data at initialization and before save, NaN and both infinities, preserved bytes/series, and successful recovery retaining legacy rows; retain day-union coverage and add a fresh-key success check.
- [x] UI owner surfaces the error at the opportunity-history summary; root executes the native regression and final platform gates.

## Additional visual critique and repairs — A24–A31

Direction: retain the owner's charcoal/magenta native identity. SF Pro hierarchy, aligned financial values, readable caveats, fewer repeated headings. Source-backed critique uses the 14 September Mac/iPhone captures; final fresh fixture captures are a separate validation requirement. No new dependency, font family or visual framework.

### A24 — Repeated headings and clipped phone feed explanations (P2)

- [x] Remove duplicate in-content destination titles where native navigation already identifies the page.
- [x] Keep the Mac banner's load-bearing finite height; increase text to 11 points.
- [x] Give phone feed states concise visible sample/cached/stale/unknown labels and a native disclosure for complete provenance and failure reasons.
- [x] Verify narrow phone and Mac geometry with actual native views.

### A25 — Home hides one side of the market behind a ticker paragraph (P2)

- [x] Show tone, evaluated coverage, three named moves per direction and explicit remaining counts; preserve every name in the expanded summary.
- [x] Remove the disconnected Generate/sparkles presentation and its cached string. This target's briefing is local rules computation, so derive it directly from current observations.
- [x] Add a compact/full regression covering both directions, omitted counts, stale labels and missing previous-close coverage.
- [x] Execute the regression and inspect fresh Home captures.

### A26 — Empty holdings and entry controls communicate poorly (P2)

- [x] Neutral empty-book P&L; keep valid zero-cost, unpriced and unreadable-record distinctions.
- [x] Persistent Symbol/Shares/Cost per share labels and native Add holding action; adaptive row/column layout.
- [x] Inspect empty and narrow native rendering.

### A27 — Market rows and Ideas do not support comparison (P2)

- [x] Consolidate Mac market/source metadata and reduce redundant row padding; retain reasons and stale/unknown cues.
- [x] Correct singular instrument count.
- [x] Give Ideas readable semantic type, adaptive lead-card metrics, a quiet charcoal surface, and native readable Log trade/Copy plan actions.
- [x] Shorten repeated explanatory paragraphs while retaining unvalidated badges, assumed win-rates and source-access qualifications.
- [x] Validate rows/lead card at narrow widths and accessibility text; verify journal actions remain functional.

### A28 — Catalyst configuration crowds out events (P2)

- [x] Events precede model configuration; shorten header prose and raise metadata text sizes.
- [x] Retain material sample/stale/unvalidated/missing-coverage/nonloopback warnings before actions.
- [x] Explicit Chat Model settings navigation scrolls to the existing expanded disclosure; ordinary navigation still starts at the page top.
- [x] Native visual/reveal validation.

### A29 — Research idle repeats instructions and buries result lifetime (P2)

- [x] Remove duplicate phone horizon prose and omit only untouched idle status; preserve preflight failures, running, error, results and filters.
- [x] Put active/completed result lifetime beside Run and use one concise empty instruction.
- [x] Inspect actual idle/result captures and run existing state tests.

### A30 — Alert switches and action affordances are weak (P2)

- [x] Native toggles label concise rows, with explanations below; Check now uses a native readable action.
- [x] Render only with isolated state; no provider/monitor actions in this visual audit.

### A31 — Phone Chat setup competes with the conversation (P2)

- [x] Remove duplicate heading, shorten disconnected setup and reuse connection details for technical explanation while preserving local watchlist availability.
- [x] Inspect native Chat captures and run existing watchlist/conversation tests.

Superseded by the owner's explicit product focus below: Research and Watchlist are now primary on both platforms.

## Native review refinements

Run 5 confirmed real accessibility defects: gesture-only Catalyst rows had no native activation, group labels replaced individual segment choices, and Journal combined its editable close form into a single accessibility element. Native Buttons and contained groups repair these at the shared source (A06/A08/A10/A28). Run 6 activated Calendar, all five picker configurations, and exact typed-price Journal save/cancel/readback; only the Close hit area remained undersized. Its visible label now declares the rectangular 44-point interaction region.

The 44-image phone review also found large-text Portfolio values and selectors splitting, a Markets count squeezed beside Sort, clipped onboarding symbols, and a truncated historical-snapshot date. These are folded into A04/A25/A26/A27/A31. Values/selectors now stack at accessibility sizes, phone holding fields fill their available width, clock/snapshot text wraps and symbols retain their intrinsic scaled width. Final native captures verified those changes, with the standalone inspector-capture limit recorded in the output gallery.

## Owner-requested product focus — A32–A34

### A32 — The primary workflow contradicts the requested holding horizons

- [x] Lead with Research, Watchlist and Chat on Mac/iPhone; keep native Home and all supporting routes.
- [x] Shared model instructions explicitly support multi-session 1–7 / 7–14 trading days, no intraday or longer-horizon plans. Historical lookback remains background evidence.
- [x] Retire new same-day paper start/resumption, preserve account/history/export, and disable the separate legacy long-hold forward recorder without changing old records.
- [x] Remove the misleading iPhone short/long horizon setting and update onboarding/current documentation.
- [x] Verify actual native navigation, model dispatch and preserved legacy state with isolated tests.

### A33 — Research exposes every verdict instead of the requested five eligible picks

- [x] Shared projection caps each horizon at five accepted Strong Buy/Buy verdicts; Strong Buy first, stable dated activity order within tiers. Fewer eligible results means fewer rows.
- [x] Search narrows the selected five; never backfills a sixth result. Preserve raw scan coverage, unchecked/incomplete reasons, partial-run state and selection receipt.
- [x] Execute deterministic projection/dispatch tests and actual Mac/iPhone result fixtures at normal/accessibility text sizes.

### A34 — Temporary runs cannot be reviewed against later outcomes

- [x] Save completed runs atomically with immutable original ordered picks, evidence, model, reference prices and coverage. Corrupt/unwritable storage must preserve existing bytes and expose a visible error.
- [x] Count seven/fourteen future Nasdaq regular-session closes after completion, accounting for verified holidays, early closes and DST. Unknown calendars stay unavailable.
- [x] Compare the next trading date’s daily open after completion with the exact target-date daily close from one freshly verified split-adjusted history; preserve the originally captured reference separately. Wait until the target New York date ends before freezing its daily bar. Explicit rose/fell/flat, not-due and unavailable states.
- [x] Add native Saved research list/detail and a manual Check due results action with cancellation, credential/policy and sample-data guards. Never use model prose as outcome evidence.
- [x] Execute persistence/relaunch/immutability, clock/calendar/split/corruption, completion/cancellation and fetch-boundary regressions; inspect actual native saved views.

New outcome checks measure forward price direction from the next trading date’s daily open after completion to the target daily close. They do not establish execution profit, target/stop attainment, calibrated win probability or comparative ranking superiority. No prediction is retroactively edited. No owner research is loaded during fixtures, and no production model/provider request is made by the verification gates.

The final forward-benchmark review caught a timing bias before release: an old reference could credit price movement that preceded the prediction. The benchmark now starts on the next trading date, with a regression where reference100 → future open120 → target110 correctly falls8.33%. Daily-bar review waits until the target NY date has ended, because eligible extended-session trades can still update daily aggregates after the regular close. Original reference/evidence remain immutable.


### A35 — Home must summarize current research and reviews due

User approved Home as the first destination once it has a useful daily summary. This supersedes A32’s earlier Research-first ordering while preserving the two-horizon product focus.

- [x] Home first/default on Mac and iPhone; preserve all raw routes and original Command-digit assignments.
- [x] Latest completed run per horizon, selected by completion time; retain original top-five order, exact dates and coverage, including a newer empty run.
- [x] Reuse saved-history availability and pending-prediction rules for due/retry, waiting and unverifiable-calendar states; no automatic check or research scan added.
- [x] Native links open original evidence, Saved research or the selected Research horizon. Wider market context is a secondary disclosure.
- [x] Verify unsorted/empty/latest runs, Eastern Time day boundaries, due/retry/evaluated/calendar counts, native Home routes and default/AX3 phone layouts; preserve fixture records and service state.


## Completion receipt

A01–A35 implemented and reviewed. Mac native gate: 2,476 passed, 0 failed, 1 opt-in diagnostic skipped. iOS native gate: 2,405 passed, 0 failed. Three documented native suite exclusions; Xcode 26.6 / SDK26.5 on OS27 runtimes. The final phone-only clock placement was checked in ios-full-final-4 after mac-full-final-3. Reports and unedited screenshots are in the task outputs. No merge, push, install or owner-model/provider call was performed for this audit batch.
