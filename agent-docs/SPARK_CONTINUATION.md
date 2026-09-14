# StockSage continuation and publishing

Updated 2026-09-14. This is an operating guide, not an additional research report.

The primary task is `01a09652-9a4a-7260-82a6-e949fe0c3dbc`. Work only in
`/Users/salman/Stocksage Project`, on `codex/research-quality-fixes`. Never merge
or push main. The scheduled fallback is `stocksage-spark-fallback-continuation`,
model `gpt-5.3-codex-spark`, high reasoning, every 30 minutes, project `Stocks`
(`b417a150-672a-45f1-82d1-a279c929c91f`). Its app-managed configuration lives in
`~/.codex/automations/`; change it with the Codex automation tool, not file edits.

## One owner

All providers use the same ignored `.research/continuation-state.json` with
`tools/research_continuation.py`. The helper uses an OS file lock and atomic
replacement, retains history, and refuses wrong-owner checkpoint/release.
It validates supplied observations; it does not query Codex or enforce Git.
Always obtain observations from current tools, never invented flags.

```bash
python3 tools/research_continuation.py --state .research/continuation-state.json status
python3 tools/research_continuation.py --state .research/continuation-state.json claim \
  --owner-thread 01a09652-9a4a-7260-82a6-e949fe0c3dbc \
  --branch codex/research-quality-fixes --mode explicit --user-paused false
```

Spark must first query current usage and the primary task. Defer quietly unless
`ordinaryUsageAllowed` is explicitly false, Spark has capacity in every reported
window, and the primary task is confirmed not running. Unknown data is not
exhaustion or a stopped task. A persisted user pause blocks every claim.

For an eligible fallback, use its actual task UUID, `--mode fallback`,
`--ordinary-usage exhausted --spark-available true --primary-task-running false`,
and `--evidence-at` with the tool-observation UTC timestamp (under five minutes
old). If Astra was interrupted before releasing, also supply
`--takeover-owner-thread` with the exact recorded owner UUID and
`--prior-owner-running false`, after verifying that exact task is stopped.
This records the displaced claim; it never takes ownership on a stale clock alone.
Recheck task and Git state immediately after claiming. Release if conditions changed.

Checkpoint before tests, staging and publication, using the active owner UUID:

```bash
python3 tools/research_continuation.py --state .research/continuation-state.json checkpoint \
  --owner-thread ACTUAL_TASK_UUID --note 'Current phase and verified evidence'
python3 tools/research_continuation.py --state .research/continuation-state.json release \
  --owner-thread ACTUAL_TASK_UUID
```

`ACTUAL_TASK_UUID` is a placeholder, not an owner to reuse. When updating phase,
HEAD and roadmap metadata directly, use the helper's `locked_state` and
`write_state` functions; preserve ownership fields and history. Do not start a
second continuation-state file. The primary owner follows the same protocol.

## Commit and push checkpoint

1. Read current HANDOFF, roadmap, report acceptance criteria, branch and dirty files.
   Preserve other providers' unfinished work. One bounded recommendation or due
   benchmark per fallback run; no new agents or loops.
2. Test the exact source. Native builds are serial with two jobs. Verify nonzero
   test counts. Keep logs, inputs, hashes and full measurements in ignored evidence.
3. Update the one colored report under its maintainer lock; validate it. Full
   metrics belong in benchmark sections; changelog rows contain improvements only.
   Update timestamped HANDOFF and local roadmap. Distinguish code validation,
   model format acceptance, factual support and investment outcomes.
4. Recheck active ownership and branch. Stage an explicit reviewed list of source,
   tests, maintained tools and handoff/docs. Never `git add -A`; keep report,
   `.research` and unrelated user files unstaged. Scan the staged diff for secrets
   and review whitespace before committing. Do not bypass hooks.
5. Push normally to `origin codex/research-quality-fixes`, then verify its remote
   ref equals local HEAD. Never force push; stop on unexpected divergence or edits.
6. Private report-delivery instructions omitted.
7. Send the primary task a timestamped result with commit, benchmark improvement,
   blockers and completion percentage; release ownership before exit.

## GPU and limits

Use the local resource broker under StockSage's own session UUID; verify actual
device, instance, model and context. A shared key can resolve to the preferred
remote LM Link device. On 2026-09-14, an explicit local CLI selection also reported
71,680 context after requesting 16,384. Neither requested settings nor a successful
load message proves the measured profile. The replay runner now refuses a context
mismatch. Keep remote models and active image workers untouched; release owned
models when returning to CPU work. Do not alter the shared broker without coordination.

No full research scan, training, paid compute, trading or incidental install/launch.
Preserve FaceTime/Safari. Keep the app updater paused. Completion uses all 27 ledger
items; the pre-existing R17 guard counts separately from newly finished fixes and
APP-FRESHNESS is outside the denominator. Data/training gates remain open until evidenced.

The changelog-only heartbeat remains separate: `refresh-stocksage-research-audit`,
every 15 minutes, quiet if unchanged. It does not build, infer or edit source.
The schedulers require an available Codex host; a future quota-triggered run has
not been observed merely because configuration and local coordination tests pass.
