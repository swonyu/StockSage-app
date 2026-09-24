# Unanswered owner questions

Last updated: 2026-09-19 00:20 +03  
Relaunch: read this file first. Do not re-ask open items. Mark `answered` when the owner replies.

Source tonight: [StockSage launch](ece46d49-f530-406a-98d3-4f217f7229ef)

## Open

### U1 — RunPod Gemma path
- **Asked:** 2026-09-19 (implicit after probe failed)
- **Question:** The historical Gemma serving pods `x5urnqm3zpxkme` and `f8q26muzsmw8us` are gone (404). Recreate a Gemma llama-server pod, recover a snapshot/template, or stay on local LM Studio `:1234`?
- **Context:** `runpodctl` works; leftover pod `cmypoced9lniv6` (`fingpt-forecaster-private`, EXITED, llama2) was not started. No private Gemma template or network volume. `:18080` connection refused, HTTP 000. No new GPU pod was created.
- **Status:** open
- **Blocks:** attaching StockSage to remote Gemma; U2

### U2 — Restart StockSage after a green model probe
- **Asked:** 2026-09-19 00:14 +03 — “Restart the app after verifying runpod connection.”
- **Question:** After U1 is chosen and the chosen endpoint returns HTTP 200 plus model id `google/gemma-4-31b-qat`, restart StockSage now?
- **Context:** Restart is authorized only after a green probe. Failed probe left PID 62402 running. Installed app is `~/Applications/StockSageX.app` at `fc8940e`.
- **Status:** open (blocked on U1)
- **Blocks:** loading new model-server settings in a fresh process

### U3 — Settings point at a down `:18080` while LM Studio `:1234` is up
- **Asked:** 2026-09-19 (implicit)
- **Question:** Point StockSage back at `http://127.0.0.1:1234` now, or leave `localModelServerURL=http://127.0.0.1:18080` until a RunPod tunnel exists?
- **Context:** Current defaults: URL `:18080`, model `google/gemma-4-31b-qat`, backend `localServerOnly`. LM Studio `:1234` answered HTTP 200 tonight.
- **Status:** open

### U4 — What wiped the watchlist?
- **Asked:** 2026-09-17 (Salman → Saleh in `HANDOFF.md`)
- **Question:** What deleted earlier `stocksage_user_symbols` after an update? Investigate further, or accept the restored list?
- **Context:** Saved list was only `[AVAV, GNRC]`. Claude restored AVAV, GNRC, FLNC, NBIS, CIFR, LITE, MU. Cause not established. Stale in-memory `userSymbols` overwrite is a suspect, not proven.
- **Status:** open

## Closed tonight / superseded

### C1 — Pull, build, launch StockSage with existing credentials
- **Asked:** 2026-09-19 00:06 +03
- **Result:** Done. Debug build from `fc8940e` installed to `~/Applications/StockSageX.app`. Massive Keychain item present. Previous app zipped as `20260919-001013-StockSageX.zip`. Checkout `main` later reached `e170c1e` (even with origin); the running app is still the `fc8940e` install.
- **Status:** answered / done

### C2 — Delete good-spender skills
- **Asked:** 2026-09-19 00:11 +03
- **Result:** Skill + loader symlinks trashed. History/keys left in `~/.claude/good-spender`. Project AGENTS block, live-monitor task, and `good-spender-live` launch config removed.
- **Status:** answered / done

### C3 — Sep 14 restart/clear of the in-progress Research scan
- **Asked:** 2026-09-14 (watchlist-fix install)
- **Result:** Superseded by the 2026-09-19 rebuild and relaunch. Treat as closed unless the owner says the old scan must be preserved.
- **Status:** superseded
