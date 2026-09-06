# HANDOFF — StockSage-app (written 2026-09-06 05:55 +03, session fe29f7aa, Claude Fable 5.1)

Written early under the good-spender `⚠ APPROACHING LIMIT` directive (projection only — this
session is the sole spend in the 7-day window; the EWMA is a read-burst artefact).

## Environment blocker (needs the owner, not Claude)
Xcode 26.6 (17F113) is installed but its licence is NOT accepted. `/usr/bin/git`, `xcodebuild`,
`xcrun` all refuse with "You have not agreed to the Xcode license agreements". Fix (owner, needs
password):

    sudo xcodebuild -license accept

Workarounds in use this session (read-only-safe, no licence bypass of the build system):
- git: call `/Applications/Xcode.app/Contents/Developer/usr/bin/git` directly.
- compile gate: `swiftc -typecheck` on `StockSage/Sources/**` for BOTH platforms — script at the
  session scratchpad `tc_stocksage.sh macos|ios` (flags mirror the pbxproj: Swift 6, MainActor
  default isolation, MemberImportVisibility, 26.5 targets). Baseline at 02ab1a0: clean on both,
  ~40 s each. **Tests cannot run until the licence is accepted** — nothing in this session is
  test-verified, only type-checked. Say so in every commit message.

## Repo state at handoff
- `main` = 02ab1a0, **16 commits ahead of origin/main, unpushed** (all iPhone UI work, Jul 28–29).
- Worktree `~/StockSage-uiwork` on `ios-colour-overhaul` at the same commit, clean.
- Work branch for this session: `review-followups-2026-09-06` (off 02ab1a0).
- Backlog source of truth: `agent-docs/REVIEW_2026-07-28_claude.md` (Part 6 staged plan; Part 3
  UI list). `agent-docs/IOS_REVIEW_2026-07-27.md` is fully FIXED — not a queue.

## Done this session (branch `review-followups-2026-09-06`, 3 commits, tree clean, NOT merged, NOT pushed)
- d21cec5 — review #2 "Open heat"→"Planned heat X% of Y% cap" (honesty-critical), #8 iPhone sheet
  detents + grabber (detail sheet .medium/.large, Settings + Browse .large), #10 Reduce-Motion gates on
  the LIVE pulse and refresh spinner, #17c dead `fontMicro` removed.
- 0aac115 — review #7 `.touchHitArea()` on 13 icon/text-only controls (hit shape only, no layout
  change); #9 21 hardcoded font literals → @ScaledMetric tokens in MarketsTodayActionsCard,
  ExecutionQualityPanel, MarketSessionClockView (byte-identical at default Dynamic Type).
- ba82689 — Q3 `defer { isRefreshing = false }` for the whole refresh cycle; Q6 `addSymbol` passes
  `marketTime`; Q7 `quoteAsOf` max-merge; C2 rebalance sort symbol tiebreak.
Every commit: swiftc -typecheck clean on BOTH platforms; tests NOT run (licence). Skipped on purpose:
the #7 stepper relocation to the bottom bar (structural), Q8 (must follow Q4), and every owner-decision item.

## Next actions
1. Owner accepts the Xcode licence → run the canonical test gate from README on BOTH platforms:
   `xcodebuild -scheme StockSage -destination 'platform=macOS' … test` and the iOS 27.0 simulator.
2. Merge the work branch only after tests are green; then push `main` (16 + N commits).
3. Remaining review items after the audit — see the audit table in the session summary / below.

## Audit result (Sonnet worker, static inspection at 02ab1a0, 2026-09-06 ~05:58 +03) — n = 35 review findings
DONE 7 (N1, N2, N3, N4, N5, Q2, P1 — notification budget, watchlist pref gate, tick coalescing landed
in 293e1d4 / 5bfe6f9 / 67db574) · PARTIAL 3 (Q1 heal-sweep capped+gated but not scoped to the cycle's
fetch set; UI#1 iOS nav-lift landed, analysis-pile disclosure did not; UI#12 generic prose collapse
landed) · OPEN 25. This session then closed UI#2's rename (d21cec5) and UI#8/#10/#17c.

OPEN, ranked by the review's severity then by size of the prescribed fix (file → one-line fix):
1. Q1 (CRITICAL, partial) `StockSageStore.healStaleQuotes` — pass the cycle's scoped keys instead of scanning the whole board.
2. Q5 (HIGH) `StockSageLiveStream` — `isStreaming` flips true on ANY success frame incl. auth/status; add an auth classifier + silence watchdog.
3. Q4 (HIGH) `StockSageQuoteCache.Entry` — add optional `marketTime` (Codable-compatible); every cache-restored row is fail-closed STALE today.
4. UI#6 (HIGH) `MarketsView` ~4224, ~9080 — sell/action badges still `DS.Palette.danger` + white ink → `dangerSoft` + dark ink.
5. Q3 / N1-conc (HIGH) `StockSageStore.refresh` — `isRefreshing` released before heal/commit → `defer`. (landed ba82689)
6. Q6 (MED) `StockSageStore.addSymbol` — pass `marketTime: q.marketTime`. (landed ba82689)
7. Q7 (MED) `StockSageStore.refresh` — max-merge `quoteAsOf`, never assign. (landed ba82689)
8. Q8 (MED) `MarketsView` ~720, ~1035 — banner `?? false` → fail-closed; land AFTER Q4 or it shouts on every launch.
9. Q9 (MED) — mirror refreshed prices onto ideas after `replaceAll`.
10. Q10 (MED) `StockSageEODHD` — `isFinite` guard, guarded `prev`, honest `isNewListing` (parity with the Yahoo parser).
11. Q11 (MED) — cache retention after a throttled sweep — OWNER DECISION (review "needs your decision" #5).
12. C1 (MED) `StockSageCapitalAllocator` — `fundableCandidateCount` read post-truncation; caveat WORDING is an owner decision (#3).
13. P3 (MED) — store-side symbol index for `currentPrice` O(n) scans.
14. M1 (MED) `StockSagePaperTrader` — no prune; retention = owner decision.
15. P2 + fixture (HIGH) `StockSageTestFixtures.swift:142` `spark: []` masks the allocator's correlation cost — fix the fixture FIRST, then memoize.
16. UI#4 (HIGH) — `.explain()` shim; ~138 `.help` tooltips are invisible on iPhone.
17. UI#5 (HIGH) — `fontCaveat` token / section header 13→15.
18. UI#3 (HIGH) — `ViewThatFits` on the idea metric rows.
19. UI#13 (MED) — watchlist trash is hover-gated → unreachable on iOS.
20. UI#15 (MED) — tier the 9 flat caveat lines.
21. UI#16 (LOW-MED) — 3 `.frame(width:)` → `minWidth`.
22. C2 (LOW) `StockSageRebalance.swift:57` — sort has no tiebreak. (landed ba82689)
23. UI#11 (MED-HIGH) — iPad `NavigationSplitView` or the 780→900 width bump — owner decision (#1).
24. UI#1 residual — collapse the 7 analysis cards above the ranked list — the crown choice is an owner decision (#3 in Part 3).
25. F1 / dead engines (`AllocationOptimizer`, `PBO`, `RelativeStrength`, 0 callers) — roadmap question, owner decision (#4).
