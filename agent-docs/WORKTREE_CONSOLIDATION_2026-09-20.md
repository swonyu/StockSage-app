# Reviewed worktree consolidation — 20 September 2026

The owner requested reviewing every StockSage worktree and consolidating its work
into `codex/app-improvements-20260919`. The starting integration commit was
`74d6a81439a22e0f8270b2cae60775961751c637`.

## Inventory and preservation

There were 25 registered worktrees: 24 present and one missing historical
`/private/tmp/stocksage-ctl-68664bf` checkout. Every present worktree's committed
HEAD was already an ancestor of the integration HEAD. Five other worktrees held
15 uncommitted files. Their bytes and hashes were backed up before review; their
source files, indexes and branches were preserved. No worktree was reset, removed
or pruned. Existing committed history did not need another merge commit.

The contemporaneous inventory, backup and detailed reviewer reports are in the
integration task's `work/worktree-review-20260920-*` artifacts. The original ten
Benzinga files are also preserved verbatim in
`agent-docs/archive/2026-09-09-benzinga/`, with a checked SHA-256 manifest.

## Dispositions

| Worktree | Remaining files | Integrated result |
| --- | ---: | --- |
| `benzinga-direct-news-20260909` | 2 | Archived the cancelled direct-provider client and its tests. Current Massive-backed news, identity, provenance and cancellation behavior supersede this API route. No direct-key setup was restored. |
| `benzinga-evidence-20260909` | 4 | Archived the prototype model, client, tests and handoff. Recovered the missing earnings/guidance/ratings provider notes into the current optional excerpt field, capped at 400 characters. Current record identity, date attribution, currency precision, shared transport and prompt limits remain authoritative. |
| `benzinga-production-review-0909` | 4 | Archived the dated review, hashes and standalone diagnostic sources. They remain historical evidence, excluded from application/test compilation and current validation claims. |
| `integration-20260917` | 2 | Integrated the Mac Chat privacy disclosure's bounded, selectable native scroll area and native sizing regression. Applied only its changes, preserving current Chat wording and persistence behavior. |
| `qwen-context` | 3 | Integrated the dormant paper-relay reader's version-2 audit-archive compatibility, integrity/bounded-read checks, offline tests and documentation. Added a current manual-only/dormant notice. No relay, broker connection, service, paper run or order was started. |

Older prototype assumptions about analyst statistics, consensus counts, timestamp
chronology and adjusted price targets conflict with the current implementation's
explicit contracts. They were retained in the archive rather than silently
replacing the newer rules. The exact differences and comparisons are documented
in the task's `work/worktree-review-benzinga.md`.

## Verification state

The transplanted relay's complete offline suite passed: 26 tests, zero failures.
It uses temporary synthetic files and a fake broker; this establishes no live
broker result. The source reader accepts validated native v1/v2 generations,
checks archive hashes/UUID names/counts/dates/control consistency, and returns
trade intents only after the complete captured generation passes validation.

Native validation of the combined app remains pending at the time this document
was written. Release claims must use the final frozen-source macOS result receipt and
signed installed-bundle identity, not older worktree test totals. The owner has
paused iOS and WidgetKit work; their preserved changes are not validated by this
macOS release gate.
The final integration task report records those results separately.

The archived received-byte diagnostic distinguishes the app's retained/parsed
response limit from URLSession's own buffering. Its old delivered-byte measurement
is not a current socket, memory or performance measurement. It is preserved as
historical context, not presented as a reproduced current failure.

The owner's current product contract remains manual research: one qualified
same-day pick with dated entry/stop/target, a deterministic Top 5 for 1–7 trading
days, and a separate deterministic Top 5 for 7–14 trading days. Consolidating
historical work does not reactivate automated research or trading.
