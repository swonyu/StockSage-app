# iPhone verification and repair — 22 September 2026

## Scope and acceptance

Owner requested a thorough live iPhone audit, fixes for found defects and useful improvements, with a one-day delivery deadline (23 September 2026, Asia/Riyadh). Baseline: `579761b`, installed notification implementation `8744624`. Work stays in the existing isolated checkout; unrelated worktrees remain untouched.

The verification question is: **Does the shipped iPhone app retain user data and provide usable, accurate navigation, market information and alerts across normal operation, larger text, interruptions and relaunch?** This uses the requested deep-research skill in fact-check mode, with engineering debugging/testing workflows. AI-assisted analysis is checked against primary Apple documentation, current source, reproducible fixtures and observed UI. This is a software verification report, not an academic systematic review.

| Area | Method | Acceptance |
| --- | --- | --- |
| Launch, navigation and settings | Physical installation/launch plus simulator UI walkthrough | Reachable primary pages; no crashes, stuck sheets or missing dismissal controls |
| Research and saved results | Isolated component fixtures; inspect live empty/saved-state UI | No accidental run; complete records and honest unavailable/stale status |
| Market data | Existing parser/freshness tests and bounded app checks where credentials are available | Session/time/source retained; missing or delayed data never labelled live |
| Notification routing | Fresh/warm-start fixtures and local test notifications | Taps reach destination even before UI attachment; dismissal does not navigate |
| Audio | Settings previews and lifecycle/route tests | Chime then brief; gain/mixing honored; interruption stops cleanly; no unintended output after unplug |
| Accessibility | Normal/largest Dynamic Type, narrow viewport and RTL fixtures plus pixels | Controls reachable, meaningful labels, no clipped essential content |
| Persistence | Isolated restart/cancellation tests; preserve physical app installation/data | No fixture writes to owner records; settings retained across reopen |
| Regression | Serial iOS suite, focused Mac tests, full compile gate, signed physical Release | Exact source/receipt identity; no unexplained failures |

Do not infer audible physical output from decoding a WAV or observing a running process. Simulator results are not physical-device results. Live stock research, model loading, GPU spend and broker operations require their separate explicit owner requests; synthetic research fixtures provide coverage here.

## Initial evidence

- The connected physical iPhone 16 Pro Max is available. Its app container is readable through CoreDevice. The bounded StockSage crash-log inventory returned zero matching reports; this is not proof that a crash never happened.
- The owner authenticated iPhone Mirroring. The physical app opened, its watchlist and Settings rendered, and Settings → Test connection returned **HTTP 200, AAPL snapshot received**. This verifies the saved phone credential for that route only. Mirroring subsequently disconnected because the phone was in use; the next connection reached a new Touch ID/Mac-login prompt. Manual continuation requires owner authentication; it is not bypassed.
- The first serial iOS baseline reported **3,137 definitions / 262 suites / 13 issues**. The launcher inadvertently repeated the `test` action; after the first run ended, the extra action hung and was interrupted. Its partial result bundle is not a release gate. A corrected single-action run is required. Existing exclusions remain `CalibrationPersistRunTests`, `LiveUniverseVerificationTests` and `StrategyBaselineMeasurementTests`; no diagnostic/replay environment flags were inherited.
- Baseline issues: a 1,500-symbol fixture used a half-second polling budget; saved-result UI assertions expected superseded copy; cap-mode fixtures expected a macOS-only assessment on iOS. These tests now retain their numerical/data-integrity checks, use a bounded completion wait, match the current comparison-policy wording and explicitly assert the iOS unsupported path without invoking a model.

## Primary-source method

Search scope: Apple Developer documentation for notification delivery/action handling, AVAudioSession route changes and speech ownership, Dynamic Type, and accessibility audits. Include current API contracts and SDK headers; exclude forum answers and unrelated academic literature from implementation decisions. Older UI reviews supply reproduction ideas only and must be rechecked against this build. Record contrary evidence and failed checks rather than treating a green unit suite as complete UI signoff.

## Results

Tested source `5188ae1`; signed Release ready, device installation pending. Build logs, screenshots, source manifests and local receipts: `/Users/salman/Documents/Codex/StockSage-iPhone-Audit-2026-09-22/`.

## Platform fact-check and contrary evidence

| Claim | Primary source and local evidence | Decision / limit |
| --- | --- | --- |
| Cold-launch notification responses must reach an attached UI | [Apple action handling](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions), [default tap action](https://developer.apple.com/documentation/usernotifications/unnotificationdefaultactionidentifier); previous delegate posted a transient event | Buffer the latest explicit tap until the workspace consumes it; dismiss/custom actions do not route. Native cold-attachment fixture added. |
| Disconnecting headphones should stop playback | [Apple route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes); existing observer only refreshed the route label | Stop chime/speech and pending audio on lost output; category changes and newly attached outputs do not trigger this stop. Physical unplug scenario remains distinct from policy tests. |
| Ambient playback respects Silent and screen lock | [Apple ambient category](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/ambient) | Keep ambient/soloAmbient behavior; no critical-alert or playback-category bypass. |
| Ducking with ambient has inconsistent documentation | [Apple duckOthers web page](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/duckothers) omits ambient; installed Xcode 27 `AVAudioSessionTypes.h` lines 496–498 explicitly includes ambient with default mode | Do not switch to playback, which would alter Silent behavior, based on that web page alone. Native iOS 27 category-configuration test passed for Mix, Duck and Pause; ambient ducking is accepted. Actual concurrent music audibility remains a physical check. |
| Dynamic Type checks are necessary but incomplete | [Apple typography](https://developer.apple.com/design/human-interface-guidelines/typography), [accessibility audits](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app) | Narrow native captures, largest text and RTL checks; these are not a VoiceOver user study or a claim that XCUITest accessibility audits ran. |

## Repairs under verification

- Notification launch routing now retains a pending route, acknowledges its identity and dismisses conflicting Settings/diagnostic sheets.
- Audio-session activation/release now uses one serial queue off the UI thread. Identity checks prevent a late activation from playing a stopped/replaced preview; idle Settings teardown does not release an unowned session. This addresses three native main-thread audio warnings in the baseline.
- Lost audio output stops speech and queued events; cancelled speech releases its session. A foreground-to-inactive delivery transition leaves chime ownership with iOS.
- Settings shows OS notification permission, a link to iOS notification settings and an explicitly labelled five-second local test. Preview/test actions never start research or an order.
- Settings normalizes the gain from its bound preferences instead of overwriting it from a different defaults store. Sound/voice changes stop the old preview.
- A research notification rejected by iOS can be retried on a later fresh history update; accepted/in-flight deliveries still suppress duplicates. No background retry loop added.

Private owner-container backups stay outside the repository. No API key, account holdings, positions or raw provider payloads are included in this report.

## Verification attempts retained

- Baseline: 3,130 passed / 3 failed / 4 skipped definitions; 13 assertion issues across five parameterized executions. Its wrapper did not exit normally.
- First/second repair builds found test-only macro and closure-label compilation mistakes; both were corrected before execution.
- Focused iOS run: 129 definitions in four suites; only the new cold-route assertion failed because it looked for a control in a nested history sheet. The captured viewport already showed Saved research. The assertion now verifies that destination's outcome summary. All audio, 1,500-symbol, same-day and remaining presentation cases passed.
- Xcode again stalled after the failed focused run had finished and its app test host exited. The wrapper was terminated; logs and bundle retained. The full run uses the documented `-collect-test-diagnostics never` option to avoid verbose failure sysdiagnose collection. Assertions, result bundles, logs and native captures remain enabled.
- The new settings fixture covers 375-point width, normal/largest Dynamic Type, LTR/RTL and reopen persistence. All four combinations passed; initial/bottom pixels inspected. RTL placement is verified, not a claim of complete Arabic translation.

- First full repair run: 3,108 passed / 32 failed / 4 skipped definitions. Every failure was the missing UIKit window scene (113 parameterized issues); runtime warnings were empty. No UI assertion was removed. After the simulator was explicitly booted and BackBoard readiness confirmed, the unchanged-source rerun passed the cold-launch route and all presentation fixtures. Final full totals follow.

## Final iOS regression gate

`full-ios-cleanboot.xcresult` passed: **3,140 definitions / 3,960 parameterized executions / zero failures / four existing skips**. Swift Testing reported 3,144 total definitions in 262 suites; xcresult separates the four skips. Duration: **340.464 seconds**. All three established owner-state/live-measurement suite exclusions remain in place.

No xcresult runtime warnings and no targeted native layout/state-publishing diagnostics. The 463-file source/test/resource/project manifest matched after the run. The test host retained 586 PNG captures; all 30 initial page viewports (15 destinations × normal/accessibility text), new cold-route screen and representative notification/RTL/largest-text captures were visually reviewed. Automated scrolling and semantic checks cover the remaining captured states; do not interpret this as individual visual review of every PNG.

Commands: `xcodebuild test -project StockSage.xcodeproj -scheme StockSage -configuration Debug -destination 'platform=iOS Simulator,id=AD7113A2-C443-4987-8662-4440EC151C62' -jobs 4 -parallel-testing-enabled NO -collect-test-diagnostics never`, with the artifact directory's `DerivedData`, named result bundle, `CODE_SIGNING_ALLOWED=NO`, and the three exclusions listed above. Before the passing run, `xcrun simctl boot` plus `bootstatus -b` confirmed BackBoard readiness.

## Compile, Mac and release checks

- Complete `tools/gate.sh . all`: **macos=OK ios=OK tests=OK**. Stages: 94 / 89 / 233 seconds. Toolchain emits existing already-enabled-upcoming-feature warnings; no errors.
- Serial `tools/runtests.sh . --filter StockSageNotificationAudioTests --filter StockSageSameDayResearchTests --filter StockSageHorizonResearchTests`: **97 definitions / 223 executions / zero failures or skips**, no xcresult runtime warnings; targeted diagnostic guard passed. External ad hoc test signing kept project settings unchanged. Apple logged nonfatal `linkd.autoShortcut` connection messages.
- Signed physical Release built successfully. Strict deep signature check passed; all four WAV hashes and the 463-file source manifest match. Binary SHA-256: `4136b5d9dd41db0e0e2dd855be18895b02d180dfd0e0c539d591edf41a5a097f`. Source commit: `5188ae1`.
- Preserved previous Release `8744624` as a separate ZIP; private app-data backup contains 10 files. The new signed app ZIP is ready locally.
- **Installation did not occur:** CoreDevice error 4016; physical iPhone reports unavailable. Its previous build remains installed. Mac authentication later locked as well, so the live notification checks and sending Saleh a completion message are blocked on user reconnection/unlock.

## Remaining physical checks

Install the verified app without uninstalling the existing identity; confirm main-process identity and app data after launch. In Settings → Notification audio, test foreground chime/brief, background chime, notification tap after closing the app, rapid Preview/Stop/Preview, gain/mixing, Silent mode and headphones disconnect. Use only the clearly labelled local test; no stock research or order is required. Actual audibility needs the owner's ears or an authorized audio capture, not a screenshot. Sustained SIP-stream readiness was not established by the successful snapshot check.

No model/GPU/broker action, no subagents and no new background watcher. Codex token/cost telemetry is unavailable; do not invent a dollar amount.

## Guide and delivery record

Living/concise edition 43 exported to eleven pages; extracted-text checks and all-page visual review passed. PDF SHA-256 `01017a93d614eec6bc3d777be48c564d6754c9d563b1ff8c073653bcac788e7e`. Previous local exports are preserved. The owner's exact `/Users/saleh` attachment path is absent; replacement remains pending and no PDF was sent.
