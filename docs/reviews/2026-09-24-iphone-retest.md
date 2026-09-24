# Our nine commits: verification on 24 September 2026

Verified checkout: `codex/gemma-images-20260922`, HEAD and remote `main` at `7b16b12`; `git pull --ff-only origin main` was already up to date. Application source is `5188ae1`; `7b16b12` changes documentation only. The dirty primary checkout and other worktrees were left untouched.

## Commit-by-commit result

PASS applies only to the stated checks. Historical documentation commits are checked as records, not independent app features.

| Commit | Feature or fix | Result on 24 September |
| --- | --- | --- |
| `256f838` | Verified pre-market/after-hours display, timestamps and source labels | PASS: focused price/calendar/provenance regression. Live extended-session display not observed in this regular-session check. |
| `2f711da` | Extended-hours receipt and guide | PASS: historical scope retained; latest limitations recorded here. |
| `3c0b692` | Pinned Gemma RunPod container and private launcher | PASS: archive identity and five offline container checks. Live Gemma connection unavailable; GPU inference, publication and deployment pending. |
| `8df6d22` | Mac/Gemma image and connection documentation | PASS: DMG verification, extracted ZIP signature and recorded hashes. No new Mac installation or live inference. |
| `0ae07e6` | API entitlement and physical iPhone installation receipt | PASS: 22 Mac-key endpoints HTTP 200; phone's saved key separately passes native AAPL snapshot HTTP 200. Latest signed phone release installed and launched. |
| `8744624` | Playful chimes, short speech and audio Settings | PASS: owner heard Buy chime and spoken brief; rapid previews/stop returned Ready; preference and WAV/native audio checks passed. Unmirrored speaker, real headphone mixing and interruption scenarios not all exercised. |
| `579761b` | Audio build and behavior documentation | PASS: foreground/background limits retained; current device observations added. |
| `5188ae1` | Launch-time routing, audio lifecycle, retry and permission/test controls | PASS: full iOS regression, focused Mac suites, installed release and owner-confirmed phone notification → Saved research. FAIL: mirrored notification was not seen even with forwarding enabled. Physical cold-launch tap/headphone unplug remain untested. |
| `7b16b12` | Audit receipt and then-pending installation | PASS: valid dated record; its pending install is superseded by today's verified installation. |

## Automated evidence

- Full iOS 27 simulator: **3,140 definitions / 3,960 executions / zero failures / four existing skips**. No xcresult runtime warnings; targeted UI diagnostic guard passed. Normal/largest-text/RTL and cold-route fixtures are automated evidence, not physical-device equivalents.
- Focused Mac: **315 definitions / 616 executions / zero failures or skips**, across sixteen suites, no runtime warnings; diagnostic guard passed. Builds and tests ran serially with external signing settings.
- Existing calibration-persistence, live-universe and strategy-baseline exclusions were retained. No fresh model run was used to satisfy them.
- All **463 source/project/resource files** still match the signed source manifest. No application source was changed during this retest; no claim of a newly fixed app bug is made.
- Signed physical Release SHA-256: `4136b5d9dd41db0e0e2dd855be18895b02d180dfd0e0c539d591edf41a5a097f`. Strict signature verification passed; installed over the existing app without uninstalling. Launch/process identity matched the new installation.
- Thirteen pre-existing StockSage preferences and the Documents file were unchanged. All eight Application Support files survived; five were byte-identical. Quote/catalyst/event caches refreshed. Event count changed 4,340 → 3,496; 868 prior insider identities were absent, with old checked dates outside the existing freshness window. This cache refresh is separate from saved research retention; backups remain private.

## Live phone notification result

The owner confirmed hearing the Buy chime followed by the short spoken brief. Mirroring can route audio through the Mac, so this does not prove the unmirrored speaker output. Rapid preview/stop checks remained responsive. A real output-disconnected message appeared after a Mirroring reconnect; physically unplugging headphones was not tested.

Repeated five-second test requests showed scheduling status but the owner saw no alert. iOS allowed alerts, lock screen, Notification Center, banners, sounds and Show on Mac. Mac forwarding was initially off; the owner authorized enabling it temporarily. StockSageX was also enabled in the Mac per-app list, but the owner still saw no alert.

The global forwarding switch was restored to **off** and verified; other user-changed settings were left untouched. We clicked Send again, returned Home and closed Mirroring. The final scheduling screenshot timed out, so that intermediate state was not independently verified. The owner's subsequent result was **“Appeared and opened Saved research”**, establishing direct device delivery and tap routing. This is not a physical cold-launch test. Mirrored delivery remains failed/undetermined; no unsupported OS bypass or speculative app fix was applied.

## Provider, model and package checks

All 22 bounded read-only Mac-key routes returned HTTP 200: market snapshots/history/trades/quotes/news/dividends/splits, Massive filings, nine Benzinga products and four fundamentals routes. Sample median **574.5 ms**, range **510–2,266 ms**; these are access samples, not throughput or completeness measurements. The first helper's consensus URL returned 404 because it omitted the required ticker path. The application already used the correct path. Correcting the external verification helper produced HTTP 200; the failed first receipt is retained. [Official endpoint](https://massive.com/docs/rest/partners/benzinga/consensus-ratings).

Phone Settings separately returned **HTTP 200, AAPL snapshot received** with its saved key. Reconnecting and unavailable price freshness were also observed, so sustained streaming is not verified. This regular-session check does not establish live pre/post-market delivery. No direct SEC, Telegram or new RunPod entitlement check is claimed.

The prior Mac DMG checksum, extracted ZIP signature and Mac executable hash passed rechecks. The exported Gemma image matched its prior hash. Five network-disabled checks passed: missing SSH key, missing GPU, help-path key guard, actual binary version `0.4.1 / 11096 / c550d2f60`, and corrupt-weight rejection. Colima was started only for these local checks and stopped afterward. Simulator was also shut down.

Local model inventory checks still found port 18080 unreachable and no Gemma advertised by LM Studio at 1234. **Live model readiness remains unavailable.** No weights were loaded, paid GPU started, inference/research run or broker action performed; no new inference speed is claimed.

## Receipts and remaining boundaries

Sanitized results, command/logs and xcresults: `/Users/salman/Documents/Codex/StockSage-iPhone-Retest-2026-09-24/`. Private app backups are access-restricted and excluded from git. Full Mac result bundle remains at `/var/folders/qb/cnp00ynx0qg3lxyfgf4p2b4h0000gn/T/stocksage-tests.DlmGqo/result.xcresult`.

Remaining: mirrored notification delivery; physical cold-launch tap and accessory/music mixing matrix; sustained/extended-session streaming; widget behavior; authorized live Gemma deployment/inference. Automated success does not close these gaps. The original one-day deadline was 23 September; this verification completed on 24 September and is not reported as on-time.

Living/concise edition 44 supersedes the pending-install state. Previous PDFs are preserved. The owner-designated attachment under `/Users/saleh` remains absent on this Mac, so exact-path replacement is pending; no PDF is sent.
