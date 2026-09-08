# Qwen research and simulated trading

Implemented in `codex/qwen-chat-context`, isolated from the shared coverage worktree
at committed base `7e6e7aa`. No broker credentials, real orders, real-journal
changes, new dependencies, or changes to the frozen prospective research pilot.

## Operation

StockSage's macOS Chat page contains **Qwen research and paper trading** with
Start/Pause controls, cash, estimated liquidation value, holdings and saved
research evidence. Once enabled it resumes on app launch. It runs while StockSage
is open and the Mac is awake, during scheduled US pre-market, regular and
after-hours sessions: weekdays04:00 inclusive to20:00 exclusive, New York time
(DST-aware). It requires
existing web permission, usable data and the configured local Qwen server.

Every fifteen minutes it researches up to four US watchlist/held stocks, rotating
through the list. It reuses the app's price history, news, catalyst context,
technical ideas and evidence-checked AI opinion schema. Unavailable data and
unverifiable model responses are retained as failures, never substituted with
invented facts or successful trades. The existing watchlist currently contains ORCL.

The new account starts with $10,000 of simulated cash. It permits whole shares,
long positions only, no margin, five positions maximum and $2,000 per new position.
Buy/Strong Buy can open a position; Sell/Reduce closes an existing position fully.
Hold/Avoid does nothing. A model cannot supply prices, quantities or code.

Paper fills require a fresh Massive SIP observation strictly after the saved
decision. Unfilled requests expire after two minutes. Assumed adverse fill cost
is 10 basis points per side. Stops at 2% and targets at 4% request an exit when
observed; the exit fills at a subsequent observation, not an invented stop price.
Position observation runs approximately every thirty seconds while research
inference proceeds separately.

Extended-hours support is native simulation only. It does not enable the IBKR
relay or change its outsideRth/account restrictions. Fixed assumed costs do not
measure actual spreads, order-book depth or extended-hours liquidity; simulated
fills are not evidence that a broker would accept or fill the same order.

The ledger is `~/Library/Application Support/StockSageQwenPaper/account.json`.
A lifetime process lock, validation and atomic replacement protect it against
concurrent writers, partial saves and duplicate fills. Corruption or a failed
save pauses the automation and preserves the previous file. Pause cancels pending
requests and retains holdings. Storage is bounded at 32 MB and 50,000 decisions;
reaching a bound pauses instead of silently deleting history.

Limitations: sampled observations can miss crossings; sleep and outages are not
backfilled. Hours use the existing weekday session schedule, with fresh-data
requirements on holidays. Dividends, actual liquidity, broker minimum fees and
corporate actions are not modeled. Large price/basis changes pause for review.
This is an operational simulation, not evidence of profitable performance.

## Chat context

Chat now budgets 32,768 total tokens, reserves 2,048 for output, and allows a
300-second request. It keeps complete recent exchanges up to the existing
24-turn history limit, dropping oldest exchanges before current evidence.
A conservative UTF-8 byte bound protects the input budget without installing a
tokenizer in the app; normal English may use substantially less than 32K tokens.
Current evidence that cannot fit fails explicitly. History accepts longer replies
and uses a 2 MB file limit. Short catalyst calls retain their smaller defaults.

The running MLX server's 256-token CLI setting is an output default, overridden
per request. Its model was not restarted or duplicated. The local model and
[official Qwen model card](https://huggingface.co/Qwen/Qwen3.8-27B#model-overview)
declare a 262,144-token native context; the app deliberately uses a smaller budget.

## Actual local benchmark

`tools/benchmark_qwen_context.py` uses the installed tokenizer and existing MLX
server, with synthetic beginning/middle/end recall checks. All three returned the
correct ordered checkpoints and stopped normally. These are single sequential
measurements, not trading or model-quality evaluations.

| Context budget | Actual input tokens | First token | Total | Physical footprint |
| --- | ---: | ---: | ---: | ---: |
| 4,096 | 2,048 | 3.24 s | 3.60 s | 15.3 GB |
| 16,384 | 14,336 | 24.06 s | 24.43 s | 17.7 GB |
| 32,768 | 30,720 | 66.47 s | 66.89 s | 18.9 GB |

Each response used eleven output tokens. Peak physical footprint for the process
was 18.9 GB after the final run. Ordinary RSS undercounts Metal allocations.
Logs and machine-readable receipts: `/private/tmp/stocksage-qwen-context-20260908/`.

## Verification

- 24 focused chat, request and paper-ledger tests passed.
- Full macOS gate: 1,838 tests passed in 192 suites.
- Full iPhone 17 Pro (gate) simulator check: 1,835 tests passed in 192 suites.
- Existing gate exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests and StrategyBaselineMeasurementTests.
- Cash/fees, later-only fills, quote freshness/provenance, caps, no margin,
  duplicate prevention, sampled exits, writer locking and corrupt-file retention
  have runnable regression coverage in StockSagePaperAutomationTests.
- No new dependency or Xcode project-file change. No push.

The signed Mac bundle is staged at
`/private/tmp/stocksage-qwen-context-20260908/StockSageX-ready.app`.
Strict/deep signature verification and a checksum-aware comparison against the
tested product passed. Native UI inspection failed with "Sky Computer Use native
pipe closed before response"; no visual acceptance is claimed.

The owner then directed this task to close the app. A normal AppleEvent quit
succeeded, and process absence was verified before installation. The tested
bundle is now installed at `/Applications/StockSageX.app`, running as PID46019.
Its contents match the tested bundle by checksum; strict/deep signature checks
pass. The previous app is recoverable at
`/Users/saleh/.Trash/StockSageX-before-qwen-paper-20260908-214612.app`.
Installed debug-dylib SHA256:
`cb23971b149ec8a0a05c2718c60550f9e31c112985c61c2cb5454f0739eed7c3`.

Only the new `stocksage.qwenPaper.enabled` flag was enabled. The first real
research cycle started at 18:46:18 UTC and completed at 18:46:30 UTC on September8.
ORCL returned an evidence-referenced **Hold** opinion. The saved ledger has no
trades or pending orders and retains its full $10,000 simulated cash. The running
app holds the account writer lease. Qwen remains the original PID61562.
Next research is due after fifteen minutes, subject to the stated availability
and data gates. Use **Chat > Qwen research and paper trading > Pause automation**
to stop it. No profitable outcome or simulated fill is inferred from this first
successful research cycle.
