# Form 4 transaction isolation

Owner approved the parser-first review slice with "continue" at 23:01 +03 on
2026-09-08. Review baseline: d7b1518 (source unchanged since 7e6e7aa).

## Design

Keep the existing pure parser and return types. Extract Table I transaction
blocks first, then read each block's code, shares, price, A/D flag and date.
Missing optional values remain nil; missing code or invalid shares skip that
row without borrowing another row's fields. Preserve the existing P/S-derived
A/D fallback when the flag is absent. Derivative contracts are not share trades.
Reject non-finite/negative monetary values and share quantities that are
non-positive or cannot be rendered by the existing integer citation formatter.
Only emit a net dollar total when all surfaced trades have finite dollar values.
Both the insider card and catalyst context consume this shared result unchanged.

No changes to SEC fetching, freshness rules, trading gates, Qwen, providers,
broker execution, frozen research sources or other worktrees. No new dependency.
The parser still handles the existing unprefixed SEC element format, not a
general-purpose XML vocabulary or all Form 4 semantic ambiguities.

## Implementation / verification plan

1. Reproduce missing price/date/flag/shares/code and mechanical-row misalignment
   through the actual parser in the existing Swift Testing suite (red).
2. Scope extraction to transactions; preserve unknown totals; run focused tests.
3. Inspect all callers and the diff, then run canonical macOS and iPhone gates
   serially with the established three live/measurement-suite exclusions.
4. Record exact results in HANDOFF.md; commit explicit paths. Do not push/merge.

## Executed evidence

Six missing-field cases reproduced 15 failures against the original parser
(exit65). Focused14-test suite then passed. Final15-test insider suite passed
within the full1835-test macOS and1832-test iPhone gates, both exit0. Sources
were unchanged between the canonical gates. Test artifacts and recoverable
installation details are in HANDOFF.md; no visual/live-market certification.
