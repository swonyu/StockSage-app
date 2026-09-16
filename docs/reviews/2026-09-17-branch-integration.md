# StockSage branch integration — 2026-09-17

Base: `origin/main` at `66d037ffc438e43867f170767bb3903f87225ee7`.
The owner requested merging the other branches and pushing `main`.

## Included

- `claude/review-ui-20260916` at `fdb72a0`: evidence-class retention in research ranking, Gemma inference and quality receipts, saved insider evidence and review presentation, and the first valid quote repair for newly tracked holdings.
- `codex/daily-pick-20260916` at `da6fb1d`: its evidence/history patch was already cherry-picked into the review branch. A clean merge records its ancestry without duplicating changes.
- `codex/portfolio-price-hotfix-20260916` at `4d53e35`: likewise already cherry-picked; a clean merge records ancestry.
- The research-pipeline core through `1239c6c` is an ancestor of the review branch. Main's owner instructions and architecture/review documents are retained.
- Integration review found that a successful insider query spanning UTC midnight could be saved as stale, then have its rows hidden by the review presentation. The correction retains typed/untyped records and omissions with visible and spoken stale labels. Empty stale observations remain data gaps; model output and qualification are unchanged.

## Older branches reviewed separately

- `wt/coverage`: Form 4 field isolation, unknown net totals and copied-plan freshness fixes are already preserved in newer implementations. No older implementation was restored.
- `codex/news-outcomes-20260909`, `codex/qwen-bounded-diagnostics-0909` and `codex/whole-market-feed`: patch-equivalent changes already exist on main.
- `origin/revaluating` and `origin/codex/research-quality-fixes`: not merged wholesale because they overlap and conflict with newer research contracts, diagnostics and provider handling. Remaining work needs adaptation: typed analyst target/currency records, company-relevant news passage selection, duplicate-story provenance, fresh-rerun cache bypass and numeric listing-token boundaries. Their last target-claim validator has no production caller and malformed interpolation; it is not a finished feature to enable.
- `origin/codex/tradier-plan-only`: separate-project planning documents, not StockSage implementation; left separate.

Uncommitted files, stashes and other worktrees are preserved. This integration does not migrate old standalone receipt directories or install/restart the owner's app.

## Verification

- Baseline Mac: 2,765 passed, zero failed, three skipped.
- The new stale-record regression failed before the correction: captured rows disappeared and the stale label was absent.
- Integrated Mac after the correction: 2,800 passed, zero failed, three skipped. Receipt: `/private/tmp/stocksage-integrated-mac-20260917.ynZbgF/result.xcresult`.
- Integrated iOS 27 (iPhone 17 Pro simulator): 2,734 passed, zero failed, two skipped. Receipt: `/private/tmp/stocksage-integrated-ios27-20260917.k1oKkB/result.xcresult`.
- Independent read-only source review found no remaining blocker after the correction. `git diff --check` passes.

Native tests run serially using the real test host and the repository's standard exclusions for calibration persistence, live-universe verification and strategy-baseline measurements. They do not activate a research scan or place orders.
