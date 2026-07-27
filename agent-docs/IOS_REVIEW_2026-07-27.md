# iOS full code review + iOS 27 crash investigation — 2026-07-27

Method: 6 parallel review dimensions (platform fences, lifecycle/concurrency, iPhone UI,
notifications, new-file quality, project config), each medium/high finding adversarially
verified against source by an independent agent. 22 agents, 47 raw findings, 13 verified,
0 refuted. This doc is the durable record (session transcripts auto-delete).

## The iOS 27 crash (root cause, evidence, fix)

**Symptom arc**: black screen on device (pre-reboot: process alive forever, zero logs,
zero crash reports — suspended by a wedged debug stack) → after phone restart: SIGSEGV
within seconds of launch.

**Root cause**: `libswiftCore.dylib` on iOS 27.0 beta (24A5370h AND beta 4 24A5390f)
segfaults in `swift_getTypeByMangledName` → recursive `TypeDecoder`/`buildDescriptorPath`
("Could not determine thread index for stack guard region") while instantiating the single
giant composite generic type of `MarketsView.normalBody`'s card stack, at first body
evaluation (crash frames: `normalBody.getter` → 3 closures deep → 40 runtime frames).
NOT an SDK-mismatch: rebuilt with matched Xcode 27 beta 4 (27A5228h, iOS 27.0 SDK),
identical crash, binary UUID-matched to the report. macOS + iOS 26.5 run the same type fine.

**Fix (shipped)**: `erasedOnIOS(_:)` — AnyView type-erasure of each of the six card
subtrees in `normalBody` (iOS only; macOS keeps concrete types for structural diffing).
Caps the depth of any single metadata tree; the runtime never builds the mega-type.
**Verified**: app renders fully on the iOS 27.0 (24A5390f) simulator — the exact
crashing runtime build — onboarding, Markets board, all cards. Screenshot-verified.

**Launch-path hardening also shipped** (each independently justified):
- `ENABLE_DEBUG_DYLIB[sdk=iphoneos*] = NO` — the stub+debug-dylib Debug layout wedged
  at launch on the beta (and an unsigned side-dylib bricks manual signing).
- Full orientation declarations (the port had NONE — iPhone + iPad keys).
- Shared scheme's Run action launches without lldb attach (attach wedges on the beta;
  Test action unchanged). Revert when the beta era ends.
- Temporary `bootlog()` checkpoints + `--stocksage-minimal` seam in StockSageApp
  (remove after the physical phone confirms a clean launch).

## Verified findings → status

| Sev | Finding | Status |
|-----|---------|--------|
| high | Idea detail sheet `minWidth: 440` clips most iPhones (MarketsView:7744) | FIXED — macOS-fenced |
| high | Onboarding sheet fixed `width: 560` clips every iPhone | FIXED — `maxWidth` on iOS |
| high/med | iOS monitor auto-start desyncs Alerts toggle ("Monitoring is off" while running) | FIXED — re-sync at alertsSection appear |
| med | iOS `.help` no-op shim shadowed NATIVE iOS `.help` — stripped a11y hints app-wide | FIXED — shim deleted (premise was false; native exists) |
| med | `willPresent` omitted `.list` — alerts vanished after banner | FIXED |
| med | Strong-signal dedup latched even when push failed to deliver | FIXED — latch only on accepted push |
| med | Idea stop/target crossing consumed on failed push | FIXED — baseline advances only on accepted push |
| med | BrowseMarkets sheet `minWidth: 420` clips iPhones | FIXED — macOS-fenced |
| med | Data menu on iOS: all items mac-only, sole live entry a guaranteed dead end | FIXED — whole menu macOS-fenced |
| med | PullToRefresh/iPadLayout/HapticFeedback dead code compiled in | FIXED — deleted; native `.refreshable` + `.sensoryFeedback` wired instead |
| med | No iOS keyboard config on numeric fields (full QWERTY for prices) | FIXED — `decimalKeyboardOnIOS` on journal/kelly fields |
| low | Alerts copy said "Get a Mac notification" on iPhone | FIXED — platform-neutral copy |
| med | PortfolioWidget winRate ignores trade side (wrong for shorts) | OPEN — fix when the real widget target lands |
| med | checkIdeaAlerts lacks the cooperative-cancellation guard its siblings have | OPEN |
| med | Stale product reference named StockSage.app in pbxproj (cosmetic; build uses PRODUCT_NAME) | OPEN |
| low | No `didReceive` handler — notification tap doesn't deep-link to the symbol | OPEN (feature) |
| low | No scenePhase handling — monitor keeps polling in background; spurious offline banner on return | OPEN (queued) |
| low | Touch targets < 44pt on journal row controls; hover-gated watchlist remove; 200pt fast-lane picker | OPEN (owner-adjacent visual changes) |
| low | ITSAppUsesNonExemptEncryption unset; iOS rpath entry missing for frameworks; badge requested never set | OPEN (App Store prep batch) |

Refuted/settled during review: PortfolioWidget parked `@main` (deliberate), MenuBarExtra
park (deliberate), the libswiftCore crash as an app bug (it's a beta runtime bug — dodged).
