# Top Five and Incomplete Research Recovery

## Goal

Recover the existing completed 500-stock 7–14-day scan, refresh only its four incomplete checks, and compare the entire updated Buy / Strong Buy pool for Top 5. Retain the original 496 completed opinions, every overwritten failed check, capture dates, coverage, stop/target scenarios and existing saved runs. Preserve separate 1–7 and 7–14 trading-day horizons and the NASDAQ common-stock universe.

## Confirmed cause and implementation

- LM Studio MLX rejects the ranking schema's unsupported `uniqueItems` keyword. Remove it; keep application validation of exact count, uniqueness and candidate membership. The same synthetic request passed after this change.
- Retry a transient ranking network/5xx failure once with identical inputs. Never publish an alphabetical or partial-comparison fallback.
- Keep the latest complete checks for each horizon in two bounded files beside history using the existing writer guard, file lock and atomic writes. Validate all symbols, counts, dates, evidence and ranking receipts; reject corrupt files without overwriting them.
- Save checks before comparison. Restore them on startup and offer comparison-only `Retry Top 5` with visible progress. It uses original evidence without provider calls.
- `Retry incomplete` obtains fresh evidence only for nil-verdict results, retains accepted results unchanged and compares the entire updated eligible pool. Use the verified model worker capacity and a 384-token initial response allowance for these failed-check retries; normal scan requests retain 192 tokens.
- Preserve amendment receipts and digests so every preceding failed-check generation can be reconstructed. Keep the 500-check/16 MiB bounds and at most 500 amendment receipts; reject a write at the ceiling.
- Append dated immutable prediction records linked to the original/completed source. A storage-only `Retry save` and startup reconciliation preserve the same ID and review date if only one of the two writes succeeds.
- Keep the existing All checks, Buy, Hold, Avoid, Stop and Target displays.

## Verification and release

Root owns integration, heavy tests, model calls and installation. Bounded History changes were delegated with sole-file ownership and independently reviewed. Regression tests failed before fixes for transient/schema failures, checkpoint recovery, amendment preservation and asymmetric save failure.

1. Run focused regressions and validate the actual recovered 500-check archive plus synthetic benchmark responses using production Swift validators.
2. Run full canonical Mac and iOS simulator gates serially with nonzero executed tests and zero failures. Actual toolchain is Xcode 26.6 / 17F113 on macOS 27 with an iOS 27 simulator; do not claim Xcode 27 SDK or physical-device testing. Three canonical opt-in suites remain excluded.
3. Build a signed Release in a distinct artifact directory, compare designated signing requirements, back up preferences/research/previous app, and install without altering existing records.
4. Import only the validated missing completed-check checkpoint; never overwrite existing runs with fixture history. Refresh the four incomplete checks and verify full-pool Top 5, history persistence and visible UI.
5. Record benchmark and release evidence. No remote Git publication is authorized for this batch.

## Performance measurement

User authorized unloading the two competing 27B instances; leave them unloaded. StockSage keeps Qwen3.5-9B-6bit and four workers. Compare the exact 16-request synthetic corpus with unchanged validation, and report total output tokens divided by batch wall time. Distinguish warm repeated-prompt measurements from fresh workloads and decoder-only speed. Do not switch weights or weaken evidence validation to inflate throughput.
