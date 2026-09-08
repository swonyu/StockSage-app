# Copied-plan quote freshness

Owner approved at23:15 +03 on2026-09-08: one shared rule across Today, detail and
ranked exports. Source baseline377a447; no new trading or model behavior.

## Contract

At copy/share/save time, the actual price timestamp must be finite, not in the
future, and no more than60seconds old (exactly60seconds is allowed). Missing,
future, invalid or older timestamps return "Draft only — refresh price", the
symbol/reason and a re-price/reconfirm instruction instead of entry/stop/target/
size or a clear-gate checklist. Sample data cannot establish a verified quote.
Ranked exports apply the rule per row. Copy builders retain existing blocked-risk
reasons alongside draft status. A delayed Share/Save can replace the captured
text entirely with draft status; underlying risk evaluation, ranking and sizing
are unchanged.
Keep on-screen research, charts, Qwen analysis and journal logging unchanged.
Caller sweep also covers the allocation copy's share-count rows with the same
rule. The money-velocity narrative has no ticket terms: retain it as explicitly
labelled "Copy research summary", not "Copy plan". Historical CSV/backups remain
data exports, not order checklists, and are unchanged.
Do not substitute fetch time/generatedAt for the price's own market timestamp.

Reuse the existing plan builders and a shared pure status helper. Inject `now`
for deterministic boundaries. Recheck shared/file data on transfer so leaving
a sheet/save panel open cannot freeze a previously fresh ticket indefinitely.
A copied external string cannot be revoked later; this check is at export time,
not a guarantee of fill price, broker readiness or profitability. No automatic
re-pricing, broker requests, source/model changes or new dependencies.

## Inline implementation plan

1. Observe failing actual Today/ranked/detail export tests before changing code.
2. Add one shared predicate/status and route every scoped export through it.
3. Test nil/future/invalid, same-day-old and60second boundaries; valid controls;
   mixed ranked rows; delayed share/save and no changes to analysis inputs.
4. Self-review all clipboard/share consumers; focused tests, then serial full
   macOS/iPhone gates. Install the tested bundle with recoverable old app.
5. Record exact evidence in HANDOFF; commit explicit paths, no merge/push.

## Installation coordination

During final iPhone verification, task01a0822f-6195-7f81-b4dc-6a0402fcaa4b
requested an installation hold while preparing the owner's combined Qwen/paper
build in the separate qwen-context worktree. Accepted: do not replace
`/Applications/StockSageX.app` from this task. Stage this tested artifact privately
and hand over the isolated commit and gate evidence for integration instead.
This changes installation ownership, not this approved export contract. A combined
build needs its own verification; these results certify only the coverage source.

## Executed evidence

- Initial method-filter invocation selected zero tests; not accepted as validation.
- Actual failing suites:21 tests,22 issues, exit65; focused final regression:100
  tests in6 suites, exit0.
- Final serial canonical gates:1840 macOS tests (56.534s),1837 iPhone17Pro(gate)
  tests (55.592s), both exit0 with the established three gate exclusions.
- 46 research tests passed in2.522s. Frozen recipe and sources unchanged.
- Logs/xcresults: `/private/tmp/stocksage-plan-freshness-20260908.XPKRvp/`.
- Private staged Mac artifact matches the tested product and passes strict deep
  codesign. Installation is deliberately held for the combined-build owner;
  native Share/Save visual acceptance and integrated-build gates are not claimed.
