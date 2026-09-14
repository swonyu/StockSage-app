# UI critique and implementation — 2026-09-13

## Follow-up result — latest verified candidate

The six fixes below are preserved. A remaining U2 defect was confirmed: a failed
model request (as distinct from a completed but rejected answer) supplied only
`server=...` metadata. Its real path is `failureSummary` → horizon `Result.note`
→ `notePresentation`; Ideas separately bypassed the formatter. The shared
formatter now reuses `StockSageLocalModelServer.cause(for:)` for safe human wording;
Ideas routes initial failures through it and paper already did. No server error
body is interpolated. Missing/unsupported models, bad settings, network denial,
unreachable service, timeout, HTTP rejection, excessive response/context,
unfinished/empty/unreadable answers and cancellation/settings changes remain distinct.
Research recognizes the formatter's newline-delimited receipt, keeps it exact
under Technical details and leaves appended omission warnings visible. Unknown
notes are retained. No acceptance, risk, retry, model-weight or record changes.

Test-driven reproduction: `red.xcresult` executed21tests,20passed/1failed,exit65
because the old formatter lacked human explanations. `green.xcresult` ran51tests,
zero failures,exit0. Final native renders include a failed request at360/760 points,
both inspected with readable wrapping and the omission warning outside disclosure.
Independent read-only Astra review of the formatter, callers, splitter and tests
found no remaining actionable scoped issue. This is not an all-app visual signoff.

| Final gate | Executed result |
|---|---|
| Mac, macOS27.0 arm64 | 2,415 passed, 1 existing opt-in skip, 0 failed;227suites;78.782 Swift Testing seconds;exit0 |
| iPhone17Pro(gate), iOS26.5 simulator | 2,335 passed,0skip/fail;223suites;67.280 Swift Testing seconds;exit0 |

Both used the canonical commands/destinations/exclusions documented below, serially,
with Xcode26.6/17F113, all paper live/replay/process-death environment opt-ins unset,
and derived roots `/private/tmp/stocksage-d4-codex-KfDey5/mac` then `/ios`.
Artifact root: `/private/tmp/stocksage-ui-followup-20260913.2kal3k`.
Logs/results: `red`, `green`, `mac`, `ios` (`.log` / `.xcresult`). The later final
gates include both the generic fallback wording correction and render extension.
Sorted source/test/widget SHA256 stayed identical across both final gates:
`1732cfd14a969fd4d976a22a50f8f83e4789b2c334eae0873d8501566d5d23c5`.

`Mac-tested-StockSageX.app` in that directory is the latest candidate, preserved
before the simulator gate, with strict/deep signature verification passed.
Executable SHA256:`d707e3fbf4055c4dcec250591b52063dfd9e0a3fcd9caae4a6e9e2133d1c2a20`;
debug dylib:`e1f13cbebf41d113f2583b48eabdd5e54a8772832cd3e8e9990b78620cc26ca3`.
`research-failure-narrow.png` and `research-failure-wide.png` are synthetic native
component previews, not screenshots of owner data or the installed app.

Installed executable remains5be7474…335ec at PID11799, unchanged. No quit/install,
commit/push, model/provider call or historical edit. App-control access again returned
`Sky Computer Use native pipe closed before response`; whole-window interaction,
remaining live tabs, VoiceOver and physical iPhone are still unverified. Simulator
returned to Shutdown. Older receipts below document their own earlier source states.

## Scope and method

Lead is the sole writer and heavy-test owner in `/Users/saleh/StockSage-wt/opus-harness`, branch `claude/model-harness-2026-09-10`, base `62d99cf5ba3055d7f23b5a2f95c34a65fefedeb3`. Preserved the unfinished Unicode-schema reliability change and its HANDOFF section. No strategy, model weights, risk limits, fill logic or historical records were edited.

The installed old build was opened for inspection. Home screenshot and Home/Research accessibility trees were inspected; no scan or trading control was activated. Normal startup attempted its configured feed refresh. Subsequent native UI calls failed with `Sky Computer Use native pipe closed before response`, including after reset; exact app-path selection avoided backup-bundle ambiguity. Other live tabs and the new build's full window remain visually unverified.

Targeted source review covered sidebar/routes, Home briefing, Research, Chat, paper monitoring, market/watchlist/ideas/heatmap controls and empty states, Portfolio/Alerts and Settings/Catalysts. This is not a claim of every possible screen/state being exercised. Spark ran a bounded read-only label/accessibility inventory on Chat, paper, Catalysts and settings; the lead verified the relevant callers before changing them.

## Findings implemented

| ID | Critique | Implemented improvement |
|---|---|---|
| U1 | Incomplete checks could not be isolated from a 500-row list. Search also treated pasted surrounding whitespace as meaningful. | Native result picker: All checks, Buy / Strong Buy, Incomplete, Not checked. Search trims surrounding whitespace; controls stay above the no-match state instead of jumping below it. Filter and selection tests preserve ordering, existing results and scan ownership. |
| U2 | An ordinary failed-result explanation displayed dense transport metadata inline. | Explanation stays visible; the known validation receipt is preserved verbatim under Technical details. The producer's optional-evidence omission warning stays visible, even when appended after the receipt. Unknown note formats are never silently removed. |
| U3 | No overall progress bar; completed checks could be confused with successful opinions. | Checked/total progress, explicit incomplete count and qualification, adaptive narrow-width summary. Per-stock indeterminate activity remains. No invented ETA or success percentage. |
| U4 | Long table headings clipped at constrained widths; dashes lacked a nearby explanation. | Short Opinion, Stop and Target headings, scenario help/accessibility labels, USD/reference qualification and missing-value explanation. Values and calculation basis unchanged. |
| U5 | Quitting discards research, but its lifetime warning was buried. | Visible notice beside scan controls; no claim that temporary results are persisted. |
| U6 | iPhone Chat retained old editing/error behavior and omitted Mac accessibility labels. | Shared editor clears stale input warnings on edit, both input/storage warnings stay visible, count and source links have descriptive accessibility labels. Desktop focus/shortcuts remain Mac-only; no unsupported iPhone model connectivity is implied. |
| U7 — withdrawn | Source-only candidate concerned old conditional iPhone paper markup. | Independent review traced the actual caller: iPhone intentionally displays “Paper trading runs on your Mac,” not this panel. Removed the unused refactor; paper presentation and Mac-only account boundary remain unchanged. This is not counted as a shipped fix. |

## Design choices retained

Native left sidebar, grouped destinations, existing keyboard assignments and magenta accent remain. Existing empty-state distinctions between no records, filtered records and failed loads remain. No speculative new dashboard, charts or navigation rewrite was warranted by this pass.

This follows [Apple's lists and tables guidance](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables) on succinct headings and readable narrow tables, and [sidebar guidance](https://developer.apple.com/design/human-interface-guidelines/sidebars) on familiar grouped navigation and a hideable sidebar.

## Verification record

- Test-first interface check: expected compile failure for the two not-yet-existing research helpers, exit 65. No executed red-test count claimed.
- Executed U2 regression: 20 tests, one failing test with two expected assertions demonstrating the hidden omission warning, exit 65. Correction preserves that warning outside the disclosure. The existing editing and simultaneous input/storage warning checks now execute on both platforms.
- Focused native execution: **72 tests / 2 suites passed**, zero failures, 13.563 test seconds, xcodebuild exit 0. Synthetic checks include filtering/selection, warning behavior and paused-exit copy on shared helpers.
- Inspected fresh native-hosted component PNGs: 240-point research progress; 360-point filters, incomplete detail, scan controls, empty paper activity and failed paper activity. These use synthetic data and do not call providers or mutate owner state.
- Full-workspace PNG capture still shows the pre-existing offscreen/mixed-appearance rendering defect. Those images are **not** visual signoff for whole-window geometry or contrast. Live pixel checks, VoiceOver interaction and physical iPhone layout remain unverified.
- Independent Astra review caught the unused U7 edit and an omission warning appended after diagnostic metadata. U7 was withdrawn; U2 received a producer-shaped regression before correction. Initial full Mac pass is superseded by these subsequent changes; final platform gates and bundle receipt are recorded below after completion.

Artifact directory: `/private/tmp/stocksage-ui-clarity-20260913.HJoQ5W`. No replacement, installation, commit or push has been performed by this UI task.

### Final gates (unchanged final source)

| Gate | Executed result | Receipt |
|---|---|---|
| Mac, macOS 27.0 / arm64 | 2,414 passed, 1 existing opt-in skipped, 0 failed; 227 suites; 94.618 test seconds; xcodebuild exit 0 | `mac-final.log`, `mac-final.xcresult` |
| iPhone 17 Pro (gate), iOS 26.5 simulator | 2,334 passed, 0 skipped/failed; 223 suites; 73.440 test seconds; xcodebuild exit 0 | `ios-final.log`, `ios-final.xcresult` |

Xcode 26.6 (17F113), **not** an Xcode 27 SDK or physical iPhone signoff. Both used `xcodebuild test -project StockSage.xcodeproj -scheme StockSage -configuration Debug -parallel-testing-enabled NO`, first `-destination platform=macOS,arch=arm64`, then `-destination platform=iOS Simulator,id=3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA`. Canonical exclusions: `CalibrationPersistRunTests`, `LiveUniverseVerificationTests`, `StrategyBaselineMeasurementTests`. Paper live/replay/process-death opt-in environment variables and simulator forwarding were unset. No zero-test filter was counted. The executed final iPhone receipt confirms the editing, simultaneous-warning and omission-diagnostic tests passed.

Final source aggregate SHA-256 (sorted tracked/untracked nonignored per-file hashes for `StockSage/Sources`, `StockSageTests`, `StockSageWidget`), unchanged before/after both gates:
`0e5375f4bad7aec54d4882f689240a5ab2efe6daccf8fa61915a3e5528337f9e`.

Mac candidate preserved before the simulator build:
`/private/tmp/stocksage-ui-clarity-20260913.HJoQ5W/Mac-tested-StockSageX.app`.
Strict/deep codesign verification exited 0, valid on disk and satisfying its designated requirement.

- Executable SHA-256: `268211eeccee6abcdf3b827c31792857ae303e566b5719ab0723f86eb9a01ac7`.
- Debug implementation dylib SHA-256: `347a60bdf4c60aad4ee496888a7451a0b527cfe606cdd288353604a6f98d7024`.
- Installed executable remains `5be7474b21fbe2240f1ad051fbd39eefee8eb58821bb9f168da5ab6c94a335ec`; observed running PID 11799. It does not contain these changes. Gate simulator was already shut down at cleanup; no owner simulator was interrupted.

Final independent Astra source review reported no further actionable issue after U2/U7 corrections. Six findings implemented; U7 rejected as not reachable in production. UI interaction limitations above remain open, rather than being treated as passed by the test totals. Native component previews are preserved as `research-detail-preview.png`, `research-filter-preview.png`, and `research-progress-preview.png` in the artifact directory; all contain synthetic data.
