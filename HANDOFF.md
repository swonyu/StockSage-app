# HANDOFF — StockSage-app (written 2026-09-06 05:55 +03, session fe29f7aa, Claude Fable 5.1)

## Desktop acceptance and spoken-strength parity — 2026-09-07 23:48 +03

Started clean at aaf66d4, peer independently inactive, Qwen disabled/no8765 listener,
and no compiler writer. Installed app's Watchlist rendered correctly. Native click
and screenshot/AX confirmed the RIGHT sidebar collapses to its icon rail, retains
all nine labelled accessibility destinations/selection, and offers Expand sidebar.
Expansion itself is not yet checked. Chat click then lost the native pipe; screenshot
also failed and the keyboard recovery was rejected until a fresh native state can
be obtained. No repeated recovery loop, no alternate UI automation or forced quit.

The Watchlist check exposed a genuine accessibility mismatch: visible strength3/5,
but combined VoiceOver label said45 percent. Both Watchlist and Markets render
signalCard; its one leftover percentage expression bypassed the existing ordinal
mapping. Extracted that exact expression unchanged into the caller's tested label
seam, then reproduced four assertion failures (Buy/Strong Buy/Sell/Strong Sell),
with the three prior ordinal tests passing. Tests use synthetic signals, not owner
records or provider calls. The fix reuses ordinalStrengthLevel, explicitly says
level N of5/not a win probability, and retains Hold/no-signal suppression. Invalid
scores inherit the visible label's safe finite-value handling. No engine/ranking,
price/source text, visible styling or iPhone layout changes.

Verification completed after midnight on2026-09-08: red4 tests/3 pass/1 failure
(four assertions), focused8/8 pass across OrdinalStrengthTests and navigation,
canonical macOS1830/1830 and iPhone17Pro(gate)1827/1827 pass, zero selected
failures/skips, exit0. Canonical exclusions remain CalibrationPersistRunTests,
LiveUniverseVerificationTests and StrategyBaselineMeasurementTests. Artifacts:
/private/tmp/stocksage-desktop-a11y-{red,focused,macos,ios}-20260907.log/.xcresult.
Same derived data and gate simulator as the redesign plan; serial builds, no Swift
edits while compiling. Inline diff/caller review complete, no debug instrumentation.

Native final-label verification is unavailable; installed99d904f remains running.
Frozen tested copy: /private/tmp/stocksage-desktop-a11y-ready-20260907.app, strict/deep
codesign verified and checksum/link-aware rsync dry-run identical to the built app.
NOT installed. Next: after normal app closure is verified, install this tested copy
with the current installed app preserved in a new unique Trash path; then check the
native label and remaining design acceptance items. Do not force-quit the owner's
app or keep retrying the failing UI helper. No owner records, real orders, pushes,
model startup or unrelated checkout changes. The15-minute heartbeat stays ACTIVE.

## Autonomous continuation resumed — 2026-09-07 23:32 +03

Owner said "continue auto". Resumed the existing stocksage-overnight-implementation
heartbeat (ACTIVE, every15 minutes, same task); updated its stale approval/stop
instructions to the approved redesign and current owner resume. This does not
restart Qwen: LaunchAgent remains disabled and port8765 has no listener. Worktree
was clean at99d904f; peer task independently remains inactive and no compiler ran.

Opened /Applications/StockSageX.app, not the old temporary build. Native screenshot
now verifies the final compact Home briefing, complete quick links, right sidebar
and visible cached/not-live provenance. Normal app refresh may run; no model calls
or owner record changes were requested. The rail-toggle attempt returned a user-
changed-app notice, and the required fresh state query failed with native pipe
closed. Collapse/expansion and other pending checks remain unverified; do not infer
an app crash or a successful toggle. Installed app remains running. No code changes
or repeated full gates in this documentation-only checkpoint; prior1829/1826 results
below remain the last executed gates. Preserve outstanding native acceptance work.

## macOS right-sidebar redesign — 2026-09-07

Owner resumed the redesign at18:07 after stopping the app/model/automation. This
resumes UI work only: Qwen LaunchAgent remains disabled, port8765 has no listener,
and stocksage-overnight-implementation remains PAUSED. The owner context waives
routine design reconfirmation; approved spec/inline plan are committed at5baad2a
in docs/superpowers/{specs,plans}/2026-09-07-macos-redesign*.md. Existing wt/coverage
is retained, with the other Codex task independently inactive before edits.

Implemented a right-side220pt navigation panel/64pt icon rail, persisted Mac-only
collapse choice, all nine destinations and original Command-number assignments.
Home replaces Briefing's Mac label/default; Markets replaces All's label. Header
and source/freshness banner stay above the page. Neutral Mac canvas/card surfaces,
wide content, aligned price digits and no hovering-row zoom; iPhone visuals remain
in their original platform branch. Home groups briefing, quick links and market
context. A six-line briefing preview expands to the complete unchanged summary,
including both strength and weakness. Ideas planning/backtest tools are disclosures.
Portfolio has Holdings/Journal/Paper/Analytics; every idea-to-journal caller still
uses the shared prefill function, now selecting Journal on Mac. No record mutation
or market/AI calculation was redesigned.

Chat has its own transcript scroll and fixed composer, Command-Return to send,
visible invalid-configuration notices and an expandable privacy note. Its existing
send/cancel/storage/provenance checks are unchanged. Sidebar SettingsLink reuses
the native Settings scene; Model settings routes to the existing Catalysts controls.
No new dependencies, model startup, inference request or actual brokerage order.

Verification:10 focused navigation/Chat tests pass after the expected missing-type
red run and two corrected compile errors. Full macOS gate:1829/1829 pass, zero
selected failures/skips, exit0. iPhone17Pro(gate):1826/1826 pass, zero selected
failures/skips, exit0. Existing warnings in unrelated tests are not new failures.
Artifacts: /private/tmp/stocksage-desktop-{red,focused,focused2,focused3,macos,ios}-20260907
with .log/.xcresult suffixes. Canonical commands/exclusions are in the plan; same
derived-data path and iPhone17Pro(gate) simulator as M11. No Swift edits during gates.

Native preview: launched the new Debug product; screenshot/AX confirmed Home,
right sidebar, Holdings and switching to Journal. Home's overlong summary prompted
the six-line preview fix. This was normal app data with normal quote refresh, NOT
an offline fixture. Clicking Chat then crashed SkyComputerUseService; retry and
fresh runtime failed too (18:20 crash reports, Array.remove(at:) assertion). The
StockSage process survived. Final preview expansion, Chat/fixed composer, all-route
sweep, collapsed/minimum-window behavior and Settings are NOT visually verified.
Code/test success is not a substitute for those remaining native checks.

Installed the tested Debug product at /Applications/StockSageX.app after staging
and verifying its signature. Previous app is recoverable at
/Users/saleh/.Trash/StockSageX-pre-redesign-20260907-1817.app; no owner data removed.
Post-install strict/deep signature verification passes. A checksum/link-aware rsync
dry-run reports no differences against the built app (plain diff warned on framework
symlink loops). The earlier temporary preview may still be open; quit/reopen the
installed app to load the final fixes. Native control could not complete that step.
Main checkout's unrelated project.pbxproj, AGENTS.md and review documents remain
untouched. No push or merge. The residual visual checklist is not marked complete.

## Full-review M11: stale saves must not revive deleted records — 2026-09-07 12:28 +03

Started at db5d595 with the peer independently inactive, no other compiler writer,
and Claude PID52276 still rooted in .claude/chrome. Reproduced against two isolated
instances of the journal, holdings and paper stores: deletion dropped foreign disk
additions, then the stale instance's next save revived the deleted ID. First red
selection accidentally omitted the portfolio aggregation suite (50 total, two failed);
corrected selection:62 total,59 passed/3 failed,13 assertions. No owner defaults used.

All three stores now share a small per-record deletion-marker helper, scoped by their
existing defaults suite and record key. Loads and reconciled saves filter deleted IDs;
remove preserves unrelated disk additions, clear/reset includes currently saved IDs,
and late paper-close batches cannot resurrect records. One preference per deleted UUID
avoids overwriting a shared marker list. Strict read/encode precedes marking/writing;
failed mutations keep prior memory and stored bytes. Paper mutations invalidate its
cached scoreboard. Successful fully prepared JSON restore may explicitly revive original
journal/holding IDs; ordinary adds and late journal closes cannot. Failed three-store
restore preparation leaves markers intact. No existing record format/key migration.

Focused green:73 tests, then102 tests in six suites including legacy array rewrites,
independent/custom-key markers, malformed/wrong-type saved books, encoding failures,
late closes, foreign additions and successful/failed explicit restore. Canonical serial
gates:1828/1828 macOS and1826/1826 iPhone17Pro(gate), both exit0, zero selected
failures/skips. Explicit opt-in exclusions remain CalibrationPersistRunTests,
LiveUniverseVerificationTests and StrategyBaselineMeasurementTests. Artifacts:
/private/tmp/stocksage-deletion-{red,red-all,focused,focused-final,macos,ios}-20260907.xcresult
and matching .log files. Focused final selection: StockSageJournalStoreQASeedTests,
StockSagePortfolioAggregationTests, StockSagePaperTraderTests, StockSageBackupTests,
StockSageJournalCSVImportTests and StockSagePortfolioTests. Gates use the existing
/private/tmp/stocksage-codex-m1b.qzpbNS derived data and iPhone simulator
3B0B0FE2-C39B-4B04-9E32-C8CCB93DA3AA. Inline source/caller/test diff reviewed.

Limits: record-array writes are still nontransactional, not globally crash-atomic or
cross-process locked; actual simultaneous process interleavings are not exhaustively
tested. Markers do not expire while stale writers may exist, so deletion metadata grows.
Idle instances do not live-refresh their in-memory UI; updated readers filter legacy
array writes, but old app versions may display stale records. New portfolio/paper error
properties do not yet add error presentation to their UI. No owner records deleted,
live provider/order calls, app/model restarts or push. Built/gated, not installed;
the prior native CUA normal-close/visual blocker remains. Main checkout's unrelated
pbxproj/AGENTS/review artifacts remain untouched.

PRIORITY CHANGE: at12:20 +03 Saleh requested a complete simpler macOS redesign with
an Apple Music-inspired RIGHT-hand collapsible sidebar. The current mac shell places
context cards before all selected sections, nine segments in a narrow picker, and
centers content in a780pt column. Redesign proposal/approval comes next; preserve the
iPhone presentation, existing engine/state and live/model lifecycle. The 15-minute
automation now prioritizes this request and must not treat the old September6 design
approval as approval of this new visual design. Other backlog/live API/P5 work remains
unfinished and secondary; do not silently continue unrelated fixes instead.

## Full-review M10: CSV compatibility and duplicate accounting — 2026-09-07 12:01 +03

Started clean at3eaa047, peer independently notLoaded/completed, no compiler writer.
Claude PID52276 remains rooted in .claude/chrome; installed app/model PIDs unchanged.
Read the actual export -> preview -> journal.importNew UI path and every parser caller.
No new UI, dependency, shared human-input policy or live-service access was needed.

Red actual API tests:22 pass/4 fail,25 assertions. CRLF failed header parsing and
an export-only CRLF note was not quoted. Tiny/large finite values written by
String(Double) were refused on reimport. In-batch duplicate rows acquired fresh IDs
and persisted three journal records instead of two; a malformed closure later got
misreported as an intentional duplicate. Plain numbers and LF/CR were controls.
Focused command: xcodebuild test -project StockSage.xcodeproj -scheme StockSage
-configuration Debug -destination 'platform=macOS,arch=arm64'
-derivedDataPath /private/tmp/stocksage-codex-m1b.qzpbNS
-only-testing:StockSageTests/StockSageJournalCSVImportTests
-only-testing:StockSageTests/StockSageJournalCSVTests (red artifact below).

One-variable probes: recognizing Swift's single CRLF Character and using scalar
matching for export escaping left24 pass/2 fail (numeric/dedup only). CSV-only
decimal-exponent parsing left36 pass/1 fail across the parser/export/input suites
(only dedup). Accepted-row seen-key insertion, AFTER closure validation, fixed the
original repro. An added multiline error-location test then isolated37 pass/1 fail:
the UI's "line" was a logical row index, one short after a two-line note. The splitter
now carries each record's physical starting line, counting CR/LF/CRLF inside quotes.

CSV accepts the exporter's finite positive decimal exponents; human money/percent
validation stays unchanged, as does the grouping-aware comma policy. Tests reject
hex, NaN/inf, overflow, zero-underflow, nonpositive and malformed notation in all five
numeric fields. Quoted Unicode notes/commas/doubled quotes retain exact content with
LF, CR and CRLF. Duplicate identity remains the existing symbol/side/entry/shares/
opened-minute key; first validated row wins, invalid rows do not reserve keys, and
skips/errors remain disjoint on repeat import. Actual saves use isolated UUID suites
and reopened stores, not owner defaults. Derived realizedR remains computed, never
trusted from the file. CSV is interchange, not a lossless journal backup (IDs and
extra metadata are omitted); JSON remains the identity-preserving path. General
malformed-quote grammar hardening is not claimed by this scoped compatibility fix.

Final61 focused tests pass in five suites, including journal-store and JSON-backup
regressions. Canonical serial gates:1821/1821 macOS and1819/1819 iPhone17Pro(gate)
pass, both exit0, zero selected failures/skips. Usual explicit exclusions: CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Artifacts:
/private/tmp/stocksage-csv-{red,lines,numbers,dedup,focused,macos,ios}-20260907.xcresult
and matching .log files. Inline diff/caller/test review completed; no debug probes left.
No owner records changed, trade/provider calls, model/app restart or push. Built/gated,
not installed: prior CUA normal-close/visual blocker remains. Main's unrelated pbxproj
and review/AGENTS artifacts remain untouched. Next M11: reproduce delete-then-save
across two isolated instances before designing deletion retention. Native/live API/P5
acceptance and N15 inner fetch/build cancellation remain distinct unfinished work.

## Full-review UI03: restore journal, holdings and watchlist — 2026-09-07 11:46 +03

Started clean at c7fccd3 with the peer independently inactive and no compiler writer.
Both macOS and iPhone JSON pickers decoded all three backup collections but only
called journal.importNew; positions were relegated to an "add via Portfolio" message
and watchlist entries were ignored. Existing tests covered decoding, not application.

Extracted the two callers into one store-injected restore overload before fixing it.
The actual-path regression uses UUID-scoped UserDefaults and fresh store instances:
7 pass / 1 fail, eight assertions (missing in-memory/reloaded positions/watchlist and
incorrect repeat counts); the codec round-trip and trade persistence controls passed.
Focused invocation: xcodebuild test -project StockSage.xcodeproj -scheme StockSage
-configuration Debug -destination 'platform=macOS,arch=arm64'
-derivedDataPath /private/tmp/stocksage-codex-m1b.qzpbNS
-only-testing:StockSageTests/StockSageBackupTests, with the red artifact below.

Shared restore now validates the whole payload, prepares/encodes all three destination
updates, then applies them without an await. Each store owns its existing keys and
publishes its resulting state. Journal preparation reuses the ordinary save's extracted
reconciliation rule (foreign IDs preserved, disk terminal close wins, invalid conflicts
fail); CSV/parent imports retain their existing per-record import semantics. Holdings
merge by original lot ID, NOT add(), which would allocate new IDs and duplicate repeat
restores. Different lots of the same symbol survive. Existing IDs win over backup
records; repeated/in-file duplicates are counted as skips. Watchlist entries normalize
through validateNewSymbol and merge case-insensitively, without fetching/inventing
quotes. Financial records are preserved rather than guessed/repaired.

Tests cover fresh/repeated restores, independent lots, foreign writes/terminal close,
normalized duplicates, six invalid-file variants and eight destination/preparation
failures (malformed JSON, wrong stored types, nonfinite encoding, closure conflict).
Failures leave all three collections/defaults unchanged; positive controls reopen
stores from the same isolated suite. First 80 focused tests passed; final112 in seven
suites include existing journal reconciliation/CSV/portfolio/tracking/scan regressions.
Final review added wrong-UserDefaults-type guards and corrected stale scope comments.
Both native callers now report actual three-collection counts; mac file-read failure
is visible. Removed the misleading ALL-data promise: settings, credentials, chat and
research imports are outside this JSON format. No schema/key changes.

Canonical serial gates:1816/1816 macOS and1814/1814 iPhone 17 Pro (gate) pass,
both exit0, zero selected failures/skips (iPhone1814 tests in191 suites).
The usual explicit opt-in exclusions remain CalibrationPersistRunTests,
LiveUniverseVerificationTests and StrategyBaselineMeasurementTests. Artifacts:
/private/tmp/stocksage-full-restore-{red,focused,focused-final,macos,ios}-20260907.xcresult
and matching .log files. These are isolated application-path tests, not a clicked
native file-picker acceptance run. The three UserDefaults writes are NOT crash-atomic
or cross-process locked; deletion tombstones (M11) remain separate. Parent migration
still imports journal only; export's pre-existing encoding-error fallback is unchanged.
No owner records, real providers, notifications, orders, model/app restarts or pushes.
Built/gated, not installed: prior native CUA normal-close/visual blocker remains.
Main checkout's unrelated pbxproj/AGENTS/review artifacts stay untouched. Next M10:
actual CSV round-trip tests for CRLF/scientific notation and same-batch duplicates.
Native/live API/P5 acceptance and N15 inner fetch/build cancellation remain separate.

## Full-review N16: removal wins during live scans — 2026-09-07 11:26 +03

Started clean at 5b44c97; peer task independently inactive, no compiler writer.
Claude PID52276 remained rooted in .claude/chrome and was left alone. Reused N07's
offline fix; this milestone addresses in-memory quote/idea membership during scans.

Added a bare Store initializer with explicit UserDefaults and a live held-symbol
provider so watchlist/scan tests do not bootstrap owner caches or calibration.
The private production convenience initializer still uses standard preferences,
live portfolio/open-journal holdings and the original sample/cache/calibration
startup order. Store-owned preference reads/writes now consistently use that
instance's defaults; keys and formats are unchanged. This is a narrow test seam,
not a claim that every Store service dependency has been isolated.

The actual shared runChunkedScan now accepts an optional fetch/build callback;
production leaves it nil and runs the unchanged provider/analysis path. Tests
use the REAL chunk loop, Task cancellation forwarding, merge, publication and
watchdog-task cleanup, supplying only deterministic chunk inputs/results.
The 120-second watchdog timeout itself was not exercised.
The initial board is itself seeded through that loop, not by assigning ideas.

Red: 9 pass / 1 fail, 17 failed assertions across full/retry before-publication,
full/retry after-publication and holding cases; unchanged was a control. The
watchlist persisted removal and the parent really cancelled after two chunks,
but the idea remained/reappeared in trackedSymbolsUnion. Held quote rows were
also incorrectly dropped. Immediate removal cleanup alone reduced this to
9 pass / 1 fail, six assertions solely in full/retry before-publication cases,
isolating a second source: late chunk publication bypassed final reconciliation.

removeSymbol now drops quote/idea rows, missing entries, deltas and new-listing
flags when the name is genuinely untracked; curated/held names retain coverage
after the watchlist preference is removed. Every intermediate chunk publication
filters against CURRENT trackedDefs before prices are merged into the live board.
Full completion already had its own final filter; both full and retry scans use
this shared loop. Accumulated ranked results deliberately remain a scan snapshot:
cancelledScanCommit must still know a chunk published when its ONLY idea was then
removed, or it would fail to name the unscanned remainder. A dedicated control
pins that case. No new deletion tombstone, retry queue, ranking or risk policy.

Final seven replay cases also check a fresh isolated Store's saved watchlist,
holding retention, quote index/union consistency and rejection of a cancelled
chunk's late result. Final fixture review aligned history keys with chunk symbols.
58 focused tests pass in eight suites (final run ~0.035s test bodies). Canonical
serial gates: 1812/1812 macOS and 1810/1810 iPhone 17 Pro (gate), exit 0, zero
selected failures/skips. Usual explicit opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Artifacts:
/private/tmp/stocksage-removal-scan-{red,cleanup-red,focused,focused-final,macos,ios}-20260907.xcresult
and matching .log files. Final inline production/test review is recorded above.

Limits: the tests invoke the shared loop in full/retry shapes, not the clicked UI
or the full network-backed wrappers. They do not verify cancellation inside the
real fetch/build implementation (N15 remains distinct). No owner watchlist,
portfolio, journal or cache was edited; no real provider/notification/trading
action, app/model restart or push. Built/gated, not installed: prior CUA normal-
close/visual blocker remains; main checkout's unrelated project.pbxproj and
review/AGENTS artifacts stay untouched. Next UI03: verify the current full-restore
path/history and reproduce whether holdings/watchlist restore with trades in
isolated stores. Native phone/live API/P5 acceptance remains separate.

## Full-review N07: removed cache rows cannot re-enroll offline — 2026-09-07 11:03 +03

Verified clean wt/coverage at 487da21, inactive peer task, no compiler writer.
The long-running Claude process is rooted in .claude/chrome, not this worktree;
left it and all unrelated processes alone. History confirms 777e9b5 introduced
Q11's save-side retainedCacheEntries filter, but offline load still trusted all
entries until a later successful refresh could persist the removal.

Red replay wrote a two-row cache to a temporary directory and restored it against
current tracked definitions, without another save. A removed custom row returned
on the rebuilt board and kept its new-listing flag: 13 pass / 1 fail in the cache
suite (three parameter cases, six assertions failed). Watchlist/holding retention,
cache timestamps and unchanged file bytes provided controls. The initial test
seam supplied tracking to the existing loader without applying it; the final
implementation instead keeps raw load unchanged and adds a retaining(tracked:)
transformation, preserving the original load-before-tracking initialization order.

Offline Store restoration now applies that transformation before rebuilding rows
or new-listing flags. It reuses Q11's actual membership filter, normalizes keys,
and preserves every retained Entry and savedAt. Membership comes from the existing
curated + user-watchlist + portfolio/open-journal trackedDefs composition, never
from cached/idea rows themselves. Removing a watchlist entry does not exclude an
instrument still held. An empty retained cache takes the existing no-usable-cache
fallback. No cache schema, prices, market times, sequences, retention-save policy,
owner watchlist, portfolio or journal records were changed or deleted.

Final replay covers removed/watchlisted/held, mixed-case keys, empty tracking,
rebuilt rows/new-listing flags and byte-identical disk contents. 32 focused tests
pass across QuoteCache, TrackedSymbols, ComposeTrackedDefs, CancelHonesty and
CancelSaveDecision (initial focused selection ran 28 before correcting the
ComposeTrackedDefs suite name). Canonical serial gates pass 1811/1811 macOS and
1809/1809 iPhone 17 Pro (gate), exit 0, zero selected failures/skips. Usual explicit
opt-in exclusions: CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Artifacts:
/private/tmp/stocksage-removal-cache-{red,focused,focused-final,macos,ios}-20260907.xcresult
and matching .log files, including complete xcodebuild invocations. Final inline
review required no further source edits.

Scope limit: this proves disk decode → current-membership filtering → row rebuild,
not a clicked removal or actual process relaunch. N16 remains OPEN: removeSymbol
still leaves ideas in memory, and intermediate runChunkedScan publications lack
the normal scan-end tracked-set filter. Existing cancel tests cover missing/delta
metadata, not that live board. Next build a red replay for remove→partial-scan→
cancel (including retry) before fixing it. Built/gated, not installed; prior CUA
normal-close/visual blocker remains, installed PID34669 unchanged. No model/app
restart, real notifications/trades, provider calls or push. Main checkout's
unrelated project.pbxproj and review/AGENTS artifacts remain unchanged.

## Full-review UI04: durable iPhone monitoring opt-out — 2026-09-07 10:50 +03

iPhone automatic monitoring now consults `stocksage.monitor.iosEnabled` on every
foreground resume. Only an explicit Alerts toggle change writes that preference;
background `stop()` remains transient. An absent preference preserves the existing
iPhone enabled default (the old view-only off state had no durable value to migrate).
The independent Mac `stocksage.monitor.autostart` opt-in remains default-off and
is now macOS-fenced at both declaration and launch call.

The existing iOS start calls were first routed through a behavior-preserving
`resumeForegroundMonitoring` seam with an optional simulated starter. Two new
regressions exercise the actual resume entry point using isolated UserDefaults:
saved off/on through background and a new Monitor instance, a stray Mac autostart
flag, the absent-key legacy default, and off→on changes on the same instance.
Red command: canonical macOS xcodebuild test with
`-only-testing:StockSageTests/StockSageMonitorTests`; full invocation is in the red
log below. Result: 14 pass / 2 fail, with two start attempts despite saved off.
The saved-value and new-instance checks passed, isolating unconditional resume
rather than persistence loss or a merely visual toggle problem. Adding only the
shared preference guard made all 16 tests pass (test bodies ~0.015s).

Final wiring removes both onAppear snapshots of monitor state. MarketsView now
observes `@Published isRunning` via the existing shared Monitor, so launch, stop
and foreground changes update the toggle. iPhone initial/return starts have one
owner: `.onChange(of: scenePhase, initial: true)` on the test-guarded root view.
Removed the duplicate permission-await task, which could otherwise resume after
backgrounding/opt-out; Monitor.start retains the native permission request and
now logs its denied/error result. No permission callback starts monitoring.
The native initial-onChange API was checked in the installed SwiftUICore SDK.
Ordinary board refreshes, scans, live streams and Qwen requests are unchanged.

Final 48 focused tests pass across monitor, budget, price-alert and alert-decision
suites. Canonical serial gates: 1810/1810 macOS, 1808/1808 iPhone 17 Pro (gate),
exit 0, zero selected failures/skips. Usual explicit opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Artifacts:
/private/tmp/stocksage-monitor-optout-{red,guard,focused,macos,ios}-20260907.xcresult
and matching .log files. Inline final source review required no further edits.

Limits: the new tests simulate starts, not OS authorization, native lifecycle
events or a clicked toggle. They do not start polling, send notifications or edit
owner preferences. Built/gated, not installed: the prior CUA normal-close/visual
acceptance blocker remains. No app/model restart or push. Main checkout's unrelated
project.pbxproj and untracked review/AGENTS artifacts remain untouched. Next:
verify N07/N16 custom-removal persistence against current history before editing;
native phone/live API/P5 acceptance remains separate and unclaimed.

## Full-review N18: revalidate one-shot alerts before enqueue — 2026-09-07 10:30 +03

Extracted the existing price-alert fetch/check/send path with behavior preserved,
using callbacks for current alerts, quote fetch, enqueue and ID-filtered latch.
The private production entry point delegates to it; shared-store access remains
lazy and behind the existing notification preference check. Tests use isolated
defaults/in-memory alerts, not owner records, network or real notifications.

Initial4pass/2fail reproduced both await windows: delete, mute, already-trigger,
edit or replace during quote fetch still enqueued the captured alert; changes
during the first enqueue, including cancellation, still let the rest of the old
batch fire. Unchanged cases and cancellation during fetch were controls. Direct
preference reads correctly returned false: this was stale eligibility in the
loop, not cached preferences or a UI-only latch error.

Before EVERY enqueue the loop now checks cancellation, current price-alert
preference and full equality with a current still-armed alert. Captured candidates
come from the existing newlyTriggered evaluator, so equality includes the nil
trigger state as well as ID/symbol/target/direction. Existing freshness and hourly
cap checks remain; accepted enqueues are still recorded/latching is not skipped
merely because cancellation arrived after dispatch began.

Value equality alone left a trigger→re-arm identity hole. With guards in place,
4pass/3fail remained solely on re-arm cases and a new identity/Codable test.
resetPriceAlert now delegates to PriceAlert.rearmed(), creating a fresh UUID for
each one-shot arm while retaining its symbol/target/direction. No schema change
or migration. The actual UI caller and Store ID-filtered latch were source-read;
old completion IDs cannot match the replacement arm. No owner alert was re-armed.

Final53focused pass (initial green52 preceded the late-completion control):15
fetch/batch mutation variants, identity roundtrip and failed/late-rearmed enqueue
sequences cover the production callback boundary. Accepted old-arm completions
leave a replacement arm eligible; a failed enqueue remains retryable; accepted
unchanged alerts stop repeating. Tests simulate the Store's ID-filtered latch,
not actual owner UserDefaults writes or a clicked native re-arm control.
Canonical serial1808/1808macOS and1806/1806iPhone17Pro(gate) pass, exit0, zero
selected failures/skips. Usual explicit opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Artifacts:
/private/tmp/stocksage-price-alert-race-{red,rearm-red,focused,focused-final,macos,ios}-20260907.xcresult
and matching.log files. Final source review required no further edits.

Limit: a request already handed to the OS cannot be retracted here; this change
does not add cross-cycle delivery serialization or prove OS display/receipt.
No real pushes, owner defaults, model/service restarts or installed-app changes;
no push. Built/gated, not installed: CUA normal-close/visual acceptance remains
blocked. Next UI04: persist desired monitoring state independently of the live
task so iPhone foregrounding cannot silently undo an opt-out.

## Full-review N17: failed watchlist enqueue stays retryable — 2026-09-07 10:08 +03

The original pure monitor tests never exercised an enqueue result. Extracted the
existing post-fetch watchlist loop, preserving its behavior before correction;
runWatchlistCycle still calls that exact loop, publishes quotes, then checks
price/idea alerts in the original order. Instance-scoped UserDefaults and an
optional strong-signal sender let tests exercise the real loop without network,
shared-board mutation or system pushes. Production defaults remain standard
preferences and the unchanged native notification sender; budget reads/writes
and preference checks consistently use the instance's defaults.

Red: one fresh TEST quote at110/previous100, first sender result false, subsequent
results true. Three cycles attempted only one enqueue and persisted no accepted
alert.9pass/1fail initially, then13pass/1fail with controls. Freshness stayed true;
the saved budget remained empty; a fresh monitor using that SAME saved budget and
quote could send. This isolated premature in-memory dedupe advancement, not a
budget charge or stale quote. The failure repeats at the actual production loop
seam (initial test body0.002s), not a copied decision simulation.

Watchlist now uses runCycle's existing delivered-result rule: failed enqueue
retains the prior recommendation; accepted enqueue records the budget and advances
dedupe. Deliberate mute/budget suppression still advances dedupe to prevent queued
bursts. Inspection-only/stale observations do not consume eligibility. No new
retry timer, thresholds, trade behavior or notification permission policy.

Final49focused tests pass across monitor, budget, price-alert and alert-decision
suites. Six new test functions cover fail→retry→dedupe, accepted-only control,
fresh-monitor failure probe, stale/inspection/mute/cap controls, a cancelled failed
batch followed by retry, and muting strong signals during the first send. Actual
OS display/delivery is NOT proven by a simulated enqueue acceptance result.
Canonical serial1804/1804macOS and1802/1802iPhone17Pro(gate) pass, exit0 and zero
selected failures/skips. Usual explicit opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Bundles/logs:
/private/tmp/stocksage-monitor-retry-{red,controls-red,focused,macos,ios}-20260907.xcresult
(logs use matching.log basenames). Final review found no additional change needed.

No real notifications, owner defaults, model/service restarts, installed-app
replacement or push. Built/gated, not installed; the existing CUA normal-close/
visual blocker remains. N18 is still OPEN: one-shot price alerts capture armed
state before a quote fetch and need post-await ID/state/preference checks before
each enqueue. Strong-signal mute coverage here is not a fix for that other path.

## Full-review N19: notification budget restart parity — 2026-09-07 09:53 +03

N08 (pre-heal quote cache) and N21 (targeted new-listing reconciliation) were
already corrected in4514e8b: refresh serializes current symbols after healing,
and targeted merges route through mergeLiveQuotes. Source/history checked;
related cache/heal/new-listing tests pass. No duplicate production fix or claim
of a new full refresh/network/cache integration test was made.

N19 reproduced against the actual notification-budget source using an isolated
UserDefaults suite: record TEST at100, save, compare continuing versus restored
instances at31minutes with price100.1. Continuing refused; restored allowed and
had zero price anchors. The1minute control and31minute/101price control passed;
the next-day wobble also failed. Restore incorrectly treated cooldown expiry as
hysteresis expiry. Removed that filter, preserving live-process policy: one
last-alerted-price anchor per symbol, unchanged30minute cooldown/0.5% hysteresis/
8-per-hour cap. Hourly timestamps still expire; clear(symbol:) still removes only
that symbol's anchor. Retention ceiling is documented beside the load: any future
anchor expiry must be applied to both running and restored budgets.

Regression suite:11pass/2fail before fix ->13pass, including49 time/price parity
cases across cooldown/hour boundaries and a persisted clear/other-symbol control.
The old test incorrectly demanded anchor expiry after a day; replaced it with
continuing-versus-restored parity. First test-build attempt failed because a
mutating allow call was inside #expect; corrected by evaluating before the macro,
then obtained the real red run. No runtime fix was made before that red result.
Standalone /private/tmp/stocksage-alert-budget.h2fiws/check now passes default,
--minute, --move and --day, printing `Notification budget self-check ok`.

Focused50/50 passed (budget, monitor decisions, price alerts, quote cache, heal,
new-listing reconciliation). Canonical serial1798/1798macOS and1796/1796iPhone17Pro
(gate) passed, zero selected failures/skips. Usual explicit opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Artifacts:
/private/tmp/stocksage-alert-budget-{red,red2,focused,macos,ios}-20260907.xcresult
and corresponding.log files; red is the compile attempt, red2 the actual11/2 run.

No actual notifications, owner defaults, model process or installed app changed;
no push. Built/gated, not installed: existing CUA normal-close/visual-acceptance
blocker remains. N17 failed watchlist enqueue dedupe and N18 post-await muted/
deleted alert checks remain OPEN; N19 does not claim to fix those separate paths.

## Full-review M3: coherent journal closure boundaries — 2026-09-07 09:38 +03

Reproduced with one real TradeRecord/API call, no owner data: entry100/stop90,
one share, exit110 and no close time reported isOpen=true AND realizedProfit10,
realizedR1. Repeated and JSON-roundtrip replays failed identically. Removing the
exit or supplying a coherent close passed. An inverted close time also reached
aggregate closed-count/profit (1/10), proving this was not contained by the
summary's open filter. Initial regressions were85pass/5fail: calculations,
CSV import, backup validation, store add and store close all admitted the defect.

One pure closureError/isFinalized policy now requires paired exit/close fields,
finite timestamps, positive finite exit, and close>=open. Same-time records remain
allowed because ISO exports have second precision; calibration retains its
stricter prediction/availability policy. Realized P&L/R and exit slippage require
finalization, and nonfinite computed P&L/R are undefined rather than emitted.
Journal financial aggregates share that cohort; coherent entry==stop legacy
records still count with undefined R. The separate descriptive history count
intentionally preserves raw legacy close flags, never laundering them into R.
Malformed open records cannot generate openActions. Days-held conversion is
bounded against nonfinite/out-of-range input to avoid an Int conversion trap.

New adds and close edits validate before mutation. Encoding failure rolls memory
back to its prior value and preserves stored bytes; optional close measurements
must be positive finite when supplied, and omitted measurements still retain
previous values. Existing records are not repaired/deleted on load: their exact
fields stay retained/exportable, excluded from realized results, with explicit
UI warnings about uncertain position status and potentially incomplete exposure.
The add/close editors do not dismiss a rejected change. CSV reports malformed
closures as row errors while preserving good rows; backup decoding rejects the
entire payload before returning it to the applying UI, with the journal index.

Import callers (CSV, mac/iPhone backup, parent migration and onboarding) now
reuse the same add path and report actual additions, ID duplicates and rejections
separately. Review found two related failures, locked down BEFORE correction:
successful later rows erased an earlier error; an invalid disk close silently
displaced an open in-memory record. That boundary run was10pass/2fail. Imports
now retain the first rejection; conflicting invalid disk updates refuse the write
without destroying either side. An explicit valid close may repair only the exact
invalid version already loaded. Known foreign records and coherent close-wins
reconciliation remain intact. No actual owner record was edited or repaired.

Final175focused journal/CSV/backup/paper/slippage/loss-limit/execution-quality/
calibration tests pass. Nine new tests also cover byte-preserved legacy load/save,
actual import counts, failed-encode rollback, optional measurement preservation,
and coherent same-time/undefined-risk controls. Original production-module replay
/private/tmp/stocksage-journal-closure.zQZOid/check was recompiled: default,
--roundtrip, --inverted, --coherent and --no-exit all exit0 and print
`Journal closure self-check ok`. Invalid cases now yield nil realized values and
zero finalized count; the coherent control remains10profit/1R/one closed trade.

Canonical serial1797/1797macOS and1795/1795iPhone17Pro(gate) pass, exit0,
zero selected failures/skips. Same opt-in exclusions: CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Bundles under
/private/tmp/stocksage-journal-closure-{red,focused,boundary-red,focused-final,macos,ios}-20260907.xcresult;
logs use the same basenames. First focused90pass preceded the extra boundary
corrections; focused-final175pass is the complete functional change. Only a
non-runtime import-cost/transaction-limit comment was added after the mac gate.

Limits: existing per-record reconciliation is not a whole-book transaction and
has quadratic batch cost; whole restore of holdings/watchlist (UI03), general
CSV format/dedup issues and deletion tombstones are NOT declared fixed here.
Closure consistency is not broker reconciliation, correct entry/stop economics,
or proof of profitable trading. No schema migration, new dependency, model reload,
credential access, actual import/restore, trade or push. Main's unrelated four
paths unchanged; appPID34669 and QwenPID23631 remain alive. Built/gated, NOT
installed: the installed app is still the first Chat build and CUA remains the
normal-install/native-acceptance blocker; no unchanged retry or force-stop.
Next concrete issue: N08 poll→heal→save→reload retaining the accepted final quote.
Native/phone/live-API acceptance and contract-gated P5 remain open.

## Full-review M2: calibration label-availability purge — 2026-09-07 09:15 +03

Reproduced the actual public split before editing: six overlapping journal
trades produced three training labels unavailable at the first test prediction.
The minimized three-row case still leaked one label; reversed input and a larger
row embargo still failed. Fifty overlapping rows leaked34labels. A short,
nonoverlapping six-row control passed. This isolated lost event timing, not
input order or tiny-sample arithmetic: a record-count embargo is not a purge.

Journal, manual backtest and offline backtest now retain prediction AND label-
availability times through the same split. Whole prediction-time groups stay
together at both boundaries; training labels must be strictly known before the
first test prediction. Candidate scoring uses that purged cohort, retaining the
existing30-training-label minimum; only after selection is the winner refit on
all finalized observations. Insufficient time-separated evidence remains an
explicit unvalidated, prior-capped identity, including totals above44records.
Backtest openAtEnd labels, unusable chronology, and incoherent/unfinalized journal
records are excluded from calibration. The dateless backtest fallback is removed;
the undated tuple API remains only the low-level numerical/test seam.

Daily bars require special care: Massive's timestamp is the aggregate window
START, not a known exit time (https://massive.com/docs/rest/stocks/aggregates/custom-bars).
The actual Massive mapper preserves that timestamp. Backtests therefore use the
decision-bar boundary as a conservative prediction lower bound and the NEXT
observed bar boundary as an exit-availability upper bound. Without that next
boundary the label is omitted, never assigned an invented intraday time. This
can conservatively discard valid adjacent observations; it does not certify
exact fill/publication times or point-in-time vendor revisions. Journal timing
uses the recorded openedAt/closedAt values, not an inferred earlier advice time.

Optional persisted validation provenance distinguishes current policy from old
undated maps. Old snapshots still decode and stay stored, but do not activate in
sizing; the existing offline auto-fit trigger can replace them. No actual owner
snapshot was edited, no manual/network calibration run was invoked. Previously
validated nonidentity maps under the new policy keep their learned probabilities;
the existing300-bar/five-symbol positive fixture still earns such a fit unchanged.

Evidence: initial18-test regression was14pass/4fail before the fix. A later
bar-start-specific red regression was20pass/1fail before correcting availability.
Final132focused calibration/selector/snapshot/EV tests pass, including overlap,
input permutations, grouped boundaries, same-time rejection, missing/censored
labels, exact33/30/29 available-training counts from50total, and legacy persistence.
The first focused build hit a test-fixture typechecker limit (no tests ran); an
explicit typed closure fixed it. Subsequent130/131focused passes preceded the
final132pass result; only the final artifacts describe the complete correction.

Production-module replay /private/tmp/stocksage-calibration-time.ZHzgMa/check
was recompiled against the final Debug dylib. Default, --minimal, --reverse,
--extra-gap, --large and --nonoverlap all exit0 with
`Calibration time self-check ok`; the nonoverlap control retains3train/2test.
Canonical serial1788/1788macOS and1786/1786iPhone17Pro(gate) pass, exit0,
zero selected failures/skips. Same three opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Final bundles:
/private/tmp/stocksage-calibration-time-{final,macos,ios}-20260907.xcresult.
Red bundles: stocksage-calibration-time-red-20260907.xcresult and
stocksage-calibration-bar-time-red-20260907.xcresult, both under /private/tmp.
Logs use the same basenames. No repo debug instrumentation or new dependencies.

Inline review, caller sweep and diff checks complete. Main worktree's unrelated
project.pbxproj and three untracked docs preserved; appPID34669 and QwenPID23631
remain running. No new task, credential access, model reload, real trade or push.
Built/gated, NOT installed: CUA remains unavailable and the installed app is still
the first Chat build. M3 is addressed only at calibration consumption; coherent
closure at journal add/import/restore and realized-accounting boundaries is next.
Native acceptance/reinstall, secure phone serving, remaining live API verification
and contract-gated P5 remain open. This is correctness evidence, not a trading edge.

## Full-review M1: thin-calibration query ceiling — 2026-09-07 08:32 +03

Reproduced the review's actual public API path before editing: 30 alternating
outcomes at conviction0.50 returned0.5225 instead of the prior ceiling0.465;
entry100/stop90/target120 then produced0.5675R EV instead of0.395R. The same
failure survived minimization to30 identical conviction0.50/all-loss records.
Conviction0.49 and midpoint0.75 were controls;0.51 still failed, while changing
only minPerBin to1 (five bins, query0.50 now a midpoint) passed. Stored bins
were already capped: this proved midpoint-only clipping, not raw identity mode
or incorrect exact-edge bucketing, was the cause.

winProb now additionally caps an unvalidated identity lookup at the QUERY's
shared prior. Extracted the existing selector split rule (30% holdout, one-row
embargo,30 training minimum) and reused it to recognize thin persisted identity
maps. No new stored field, manual snapshot edit, refit or schema migration.
The43/44 boundary, OOS-selected raw identity, learned beta/Platt/isotonic maps,
stored bins, and assumed-label provenance are preserved. EV/ranking/sizing
receive the correction through the existing shared probability API. This is a
correction to the approved prior policy, not new evidence of a trading edge.

Regression:17selector tests passed/2new tests failed BEFORE the fix. Final
124focused calibration/snapshot/EV tests passed. Tests sweep n30...43, bin
counts2/3/5, minPerBin1/20, a conviction grid and nextDown/exact/nextUp around
every internal edge; pin monotonicity/no promotion, EV, legacy decoding/plist
round-trip, unchanged low/midpoint controls and separately validated maps.
Production-module scratch /private/tmp/stocksage-prior-envelope.uMWwDq/check
was recompiled against the final Debug dylib: original, --minimal, --below,
--midpoint, --inside, --five-bins all exit0, `Prior envelope self-check ok`.
Original/minimal now give0.465 and0.395R, with original stored bins unchanged.

Canonical serial1780/1780macOS and1778/1778iPhone17Pro(gate) passed, exit0,
zero selected failures/skips. Same three opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Result bundles:
/private/tmp/stocksage-prior-envelope-{red-suite,focused,macos,ios}-20260907.xcresult.
The first method-only filter selected ZERO tests (red bundle, not evidence);
the first post-fix build caught an assertion still using the moved minimum
constant (green bundle, no tests run). The assertion now shares that constant;
only the subsequent focused/full results above are passing evidence.

Inline review and diff checks complete. No debug instrumentation in repo,
dependencies, actual calibration writes, new tasks, keys, model reload or push.
Main worktree's unrelated project.pbxproj and three untracked docs unchanged.
AppPID34669 and QwenPID23631 still running. Installed app is still the first
Chat build: CUA failure remains an installation/visual-acceptance blocker, not
a reason to kill the app or retry an unchanged service failure. This fix is
built/gated, NOT installed. Next: full-review M2/M3 prediction/label-availability
timing and finalized-vs-censored calibration outcomes; native acceptance,
phone serving, remaining live API verification and P5 are still open.

## Chat research sources: news + private export leads — 2026-09-07 08:10 +03

Chat now enriches explicit ticker questions using the EXISTING recentNews and
ResearchLeads.load paths. First selected ticker only: at most3 news excerpts from
7days and3 deduplicated local group excerpts from30days,400characters each.
News honors ToolPolicy and the existing Massive-first/EODHD-fallback request
bounds; only the ticker is sent to those providers. Private messages go only to
the captured loopback model, never to news providers. No new connector, training,
embedding job, cloud upload, credentials access or service provisioning.

Quoted sources are a separate Codable array, not monetary Fact records. They
retain subject/provider/date, import/timezone warning for group leads, and safe
HTTPS links for news only. Group links are never followed or promoted to clickable
source links. CFA identity/returns remain explicitly unverified. Model IDs can
select source cards but cannot rewrite captured quotes; prose stays interpretation
or visible unverified draft. Empty retrieval is not proof of no news/discussion.
One pre-generation attachResearch transition requires current request ownership,
unchanged original facts/time/context, and no prior attachment. Cancel/clear/new
question cannot be overwritten by late fetches. Existing history decodes without
the optional new fields. Overfull requests drop old conversational context first,
never current evidence;16k-byte hard request ceiling remains (not a tokenizer-based
general context-length proof). General questions without a named ticker do not
start supplemental retrieval. Lowercase app/on/ai are no longer silently treated
as APP/ON/AI; explicit uppercase/cashtags and the four existing company aliases
remain supported. Alias lookup is shared, not a second differently maintained map.

19focused tests passed, including new source isolation/windows/dedup/serialization,
legacy-history decoding, wrong-quote/late/double-attachment rejection, and lexical
selection. Final serial canonical1778/1778macOS and1776/1776iPhone17Pro(gate) passed,
exit0, zero selected failures/skips; same opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Bundles:
/private/tmp/stocksage-chat-research-{focused,macos,ios}-20260907.xcresult.

Actual local export rechecked (metadata only): schema1,546messages, imported
2026-09-07T00:29:15Z. Production-module smoke
/private/tmp/stocksage-chat-research.i6bDwN/check loaded3actual ORCL leads, kept
market facts unchanged, and sent3434prompt bytes to existing QwenPID23631.
No news requests in THIS smoke (newsRequests=0); no actual live quote was supplied.
Qwen returned valid JSON citing ORCL.lead.1/2/3 and explicitly described claims as
unverified leads requiring independent sources, not prices/outcomes/proof of
returns. `Chat private-research self-check ok`, exit0. Log inside the private
scratch directory: /private/tmp/stocksage-chat-research.i6bDwN/smoke.log.
This proves local retrieval/client integration for that case, not profitable
forecasting, complete news coverage or native visual acceptance.

Native CUA reacquisition still exits with "native pipe closed before response";
StockSagePID34669 and original Qwen remain running. No repeated reset loop,
force-kill, access-control/UI-automation bypass or unrelated-process interruption.
Installed app remains the FIRST Chat build from the previous checkpoint; this
source integration and the settings shortcut are built/gated but await normal
reinstall/visual acceptance after CUA recovery. Do not claim the installed app
already exposes the new source cards or that live news was checked this pulse.

Coverage worktree was clean at start, peer task independently notLoaded/revision5,
and no competing compiler. Main's same four unrelated paths preserved; no push or
real trade. Next safe code issue while native inspection remains unavailable:
reproduce full-review M1 (thin-sample query prior envelope), then M2/M3 label timing.
Native acceptance/reinstall, secure phone serving, live API checks and contract-
gated P5 remain outstanding, not replaced by passing tests or mocks.

## Native Chat first vertical slice — 2026-09-07 07:51 +03

Added Chat to existing MarketSection (between Alerts and Briefing; Briefing kept).
It opens a deterministic typed quote briefing for at most four watchlist/board
symbols, refreshed from app data, plus the existing capped crossing-event log.
No automatic inference on every quote; no new monitor, notification permission,
backend, model, dependency or money/order path. Model settings routes directly to
Catalysts/Explanation model, reusing the same keys and loopback-only AI policy.

Specific ticker questions capture new source/market-time/currency/subject records,
technical rules opinions and available earnings schedules. Follow-ups retain
subject selection but rebuild facts. Model-selected IDs render original typed
records, not model-rewritten financial numbers. Prose ALWAYS remains unverified
interpretation; numeric prose (including Arabic digits), bad schema and unknown
IDs stay visible as labelled drafts, never a newly trusted quote or trade signal.
No semantic-entailment/profit claim. News/filings, WhatsApp leads, portfolio balances
and journal notes are NOT yet retrieved by Chat (the existing primary assessment's
WhatsApp/news path is unchanged). This is not completion of the whole V3 design.

History: last24 turns, last2 bounded turns supplied as explicitly historical
conversation, each answer keeps its original snapshot/model. Local App Support
StockSageChat/history.json, atomic/protected writes,0600 file/0700 directory,
excluded from backup. Clear deletes that app copy; not external backups/logs.
Corrupt/oversized history is not silently overwritten. Pending UUID ownership,
cancellation on tab/settings changes, and final config checks prevent late replies
from reviving cleared history or overwriting a newer request. Likely-credential
questions are rejected before persistence/send; automatic context excludes account
identifiers/credentials entirely. This is a heuristic input check, not a universal
secret detector. External/phone inference remains disabled in this slice.

Seven focused checks passed (four new tests plus section navigation). First full
canonical passes:1776macOS/1774iPhone, zero selected failures/skips, same three
opt-in exclusions. Bundles /private/tmp/stocksage-chat-{focused,macos,ios}-20260907.xcresult.
Final serial gate after adding the direct settings button: macOS1776/1776 and
iPhone1774/1774 passed, exit0, zero selected failures/skips, same exclusions
(CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests). Final bundles:
/private/tmp/stocksage-chat-final-macos-20260907.xcresult and
/private/tmp/stocksage-chat-final-ios-20260907.xcresult. No source changes during builds.

Real local-Qwen production-client smoke (one Arabic general question, empty facts,
NOT a live stock-price test): /private/tmp/stocksage-chat-smoke.lMbfeR/check,
log /private/tmp/stocksage-chat-smoke-20260907.log. It returned valid JSON, explained
old observations versus executable prices in Arabic, and printed
`Chat local-model self-check ok`, exit0. Original QwenPID23631 unchanged.

Installed the first green Chat build at /Applications/StockSageX.app, PID34669:
executable/debug-dylib cmp and strict deep codesign passed. Previous app recoverable
at /Users/saleh/.Trash/StockSageX-pre-chat-20260907-0744.app. Native screenshot/AX
verified the new navigation entry. On opening Chat, SkyComputerUseService crashed
in Swift Array.remove(at:), NOT StockSage. Reset/reacquisition (name, explicit path)
repeated the same service failure; app stayed running. Crash evidence:
/Users/saleh/Library/Logs/DiagnosticReports/SkyComputerUseService-2026-09-07-074429.ips.
Do NOT claim populated Chat UI/Q&A was visually verified. The subsequently added
settings shortcut is built/gated but not reinstalled while normal CUA Quit is
unavailable; no force-kill or UI-automation bypass was used.

Next: recover native inspection, install the final settings-shortcut build and
verify populated Chat, then extend source-bound news/WhatsApp retrieval. Secure
iPhone serving, semantic grounding, independent API acceptance and contract-gated
P5 remain separate work. Main worktree's unrelated four paths preserved; no push,
real trade, cloud upload, credential access, model training/reload or new task.

## Explain distinguishes invalid citations from financial numbers (2026-09-07 07:22 +03)

The captured native PAA paragraph contained an unoffered[1], but checkedResponse
reported an invented financial number because the numeric check ran first.
Production-module replay `/private/tmp/stocksage-citation-diagnostic.lwUzdI/check`
failed with that exact warning (exit1). Minimal `Target 27 [1]` still failed;
removing only[1] passed, and adding only an unrelated fact containing1 changed
the warning to the correct citation failure. citationsValid itself returned false
throughout. This isolates error ordering, not a missing PAA financial fact.
A separate --overflow replay proved a40-digit ID could pass when those digits
also occurred in facts: Int parsing failed and the citation was silently skipped.

The same response boundary used by BOTH backends now validates citations first.
Unparseable/oversized IDs fail; failed text/source remain unchanged and visible
as an unverified draft. Valid citations still undergo the unchanged numeric check.
No prompt/temperature/model, primary badge, financial rule or shared numeric-helper
change. The existing [n] grammar is unchanged; malformed bracket prose is not
newly interpreted as a citation. This does not establish semantic entailment.

All five replay modes pass (full, --minimal, --control, --fact-one, --overflow):
`Citation diagnostic self-check ok`, exit0. New regression covers both backend
sources, zero/out-of-range/oversized IDs, retained draft/source, valid text and
genuine foreign financial numbers. Red25pass/1fail -> focused48/48 passed:
`/private/tmp/stocksage-citation-diagnostic-red-20260907.xcresult`,
`/private/tmp/stocksage-citation-diagnostic-green-20260907.xcresult`.
Final serial canonical macOS1772/1772 and iPhone17Pro(gate)1770/1770 passed,
exit0, zero selected failures/skips; same three opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Final bundles:
`/private/tmp/stocksage-citation-diagnostic-macos-20260907.xcresult`,
`/private/tmp/stocksage-citation-diagnostic-ios-20260907.xcresult`.
An initial macOS invocation had a misspelled derivedDataPath flag (exit64,
no tests run); corrected before the actual gate. Its separate diagnostic log is
`/private/tmp/stocksage-citation-diagnostic-invocation-error-20260907.log`.

Installed tested MacPID29461; executable/debug-dylib cmp and strict deep codesign
passed. Previous app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-citation-diagnostic-20260907-0721.app`.
One actual PAA Explain via unchanged QwenPID23631 rendered normally with the
original model/footer and facts disclosure (native AX/populated screenshot).
This fresh output contained no bracket citation; the bad-citation warning was
verified by replay, NOT forced into the UI. No extra generation/retry, settings
edit, model restart, credential access, cloud upload, push or trade. Main changes
preserved; sibling task independently confirmed inactive.

Inline review traced both checkedResponse callers and all citation/number-helper
consumers. Next product slice is approved native Chat: reuse MarketSection,
existing deterministic briefing and local client, with bounded local history and
per-question fact snapshots. V3 architecture reread in full (428lines) this pass.
No Chat completion claim yet; semantic grounding, independent API acceptance,
phone serving and contract-gated P5 retain their separate acceptance requirements.

## Connection probes belong to their request and settings (2026-09-07 07:11 +03)

N14/UI14 adjacent lifecycle fix. Manual and automatic probes previously wrote the
same result/spinner unconditionally after await. Behavior-preserving extraction
of those transitions into ConnectionProbeState gave a deterministic real-state
replay: `/private/tmp/stocksage-probe-freshness.LfMN6t/check` printed
oldReplyEnabledNewModel=true/newerRequestStillProbing=false, exit1. It also failed
--same-settings, --changed-before-start and --cancelled; --control (one matching,
uncancelled request) passed. The initial view regression was10pass/1fail.

Both callbacks now use the same small value-state boundary: each begin clears the
old result and owns a UUID; a superseded completion cannot publish OR clear the
newer's spinner. Current results/spinners match the selected settings even before
the next automatic task starts. Cancelled or settings-mismatched completions do
not publish. Task identity uses the existing settings array, not a delimiter-joined
string. Disappearance and automatic off/on-device selection invalidate state.
Manual Test connection still explicitly probes in those modes. Config is captured
before scheduling; probeServer takes it rather than rereading UserDefaults later.
All status text/color and Explain availability consume the filtered result.

All five replay modes now print `Connection probe freshness self-check ok`, exit0.
One regression covers old-before-new/old-after-new completion, same-setting overlap,
settings changes, cancellation, disappearance, successful control and nil config
(no I/O). Focused46/46 passed. Artifacts:
`/private/tmp/stocksage-probe-freshness-red-20260907.xcresult`,
`/private/tmp/stocksage-probe-freshness-green-20260907.xcresult`.
Final serial canonical macOS1771/1771 and iPhone17Pro(gate)1769/1769 passed,
exit0, zero selected failures/skips; same three opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Final bundles:
`/private/tmp/stocksage-probe-freshness-macos-20260907.xcresult`,
`/private/tmp/stocksage-probe-freshness-ios-20260907.xcresult`.

Tested Mac installed asPID24163; executable/debug-dylib cmp and strict deep
codesign passed. Previous app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-probe-freshness-20260907-0707.app`.
Native auto-probe and manual Test connection confirmed the saved local Qwen model
reachable/present with Explain available (AX plus populated screenshot). Offscreen
AX click scrolled the long list unexpectedly; native scrollbar setValue("0") and
small scrolls restored the viewport, then a visible coordinate click verified
the actual control again. No settings edits, synthetic UI responses or extra
Explain generations. Original QwenPID23631 unchanged. Races were replay-tested,
NOT forced by changing owner settings or slowing the real endpoint.

Inline review traced both callers and all three result consumers. This is request
ownership, not continuous server health monitoring or a wall-clock expiry policy.
No dependency, trade, push, credential access, cloud upload or model reload; main
worktree changes preserved and sibling task independently confirmed inactive.
Next bounded issue: Explain citation/number diagnostics (native PAA's unoffered
[1] currently surfaces as a financial-number failure). Semantic grounding,
independent API acceptance, full Chat and contract-gated P5 remain open.

## Explain facts retain quote source and market time (2026-09-07 06:57 +03)

N10/N14 bounded provenance fix. The shared narrator fact builder omitted the
quote provider and timestamp. A compiled production-module replay through
withLivePrice -> CatalystWatch.brief -> narrator.facts -> narrationRefreshReason
proved equal-price provider-only and timestamp-only changes incorrectly remained
current (both exit1); unchanged-input and price-only controls passed (exit0).
Harness: `/private/tmp/stocksage-quote-provenance.lO8RBo/check` (default,
--timestamp, --control, --price). Original regression24pass/1fail.

The existing shared fact builder now includes the source label and UTC market
timestamp with milliseconds, explicitly described as an observed snapshot, not
a live execution quote. Missing or nonfinite dates remain unknown; no scan-time
or wall-clock fallback. Both narrator backends and the existing freshness check
consume this line. The Original app facts disclosure is available for fresh as
well as stale results. No new model calls on ticks, cache, dependency or money
logic. All four original replays now print `Quote provenance self-check ok`, exit0.
Focused48/48 passed; regression covers all source alternatives, missing/invalid
metadata, unchanged inputs and subsecond/previous-day timestamp changes.
Red/green evidence: `/private/tmp/stocksage-quote-provenance-red-20260907.xcresult`,
`/private/tmp/stocksage-quote-provenance-green-20260907.xcresult`.

Final serial canonical macOS1770/1770 and iPhone17Pro(gate)1768/1768 passed,
exit0, zero selected failures/skips; same three opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Final gates include the disclosure change:
`/private/tmp/stocksage-quote-provenance-macos-20260907.xcresult`,
`/private/tmp/stocksage-quote-provenance-ios-20260907.xcresult`.

Tested Mac bundle installed asPID18562; executable/debug-dylib cmp and strict
deep codesign passed. Prior app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-quote-provenance-20260907-0651.app`.
One real native PAA Explain used the existing Qwen serverPID23631. Expanded
disclosure shows `Quote source: Massive SIP; market time: 2026-09-04T20:23:46.598Z`
and the not-live disclaimer (AX and populated screenshot inspected). Unsupported
[1] citation still leaves the full warned draft visible. No injected response,
owner-settings mutation, model reload, credentials, cloud upload, push or trade.
Main worktree's pre-existing changes remain untouched; sibling task stayed idle.

Inline review traced all four shared-facts callers and freshness publication.
This is millisecond snapshot identity, NOT nanosecond tick identity, wall-clock
expiry or semantic truth. Connection-probe settings freshness is the next bounded
lifecycle check; citation diagnostic ordering, semantic grounding, independent
API acceptance, full Chat and contract-gated P5 remain open.

## Explanation freshness includes request settings (2026-09-07 06:42 +03)

N14/UI14 bounded lifecycle fix. The generating-model label was ALREADY correct,
but the Catalyst Explain panel only compared fact strings; changing backend,
URL or model did not mark an old response stale. Diagnostic workflow first
extracted that existing display decision unchanged into narrationRefreshReason,
then exercised the production helper without changing owner preferences or
calling a model. `/private/tmp/stocksage-narration-settings.HJogxm/check`
reported settingsChanged=true/staleWarning=false, exit1; --control changed only
model-B back to model-A and passed. Regression9pass/1fail before the fix.

The panel now compares both original facts and the three request settings.
Stale text stays readable below "Previous explanation — not current", with an
Original app facts disclosure and its original numbered sources/model. It is
not relabelled as a fresh explanation. Footer wording says supplied facts
snapshot rather than facts above, which could now mean the changed live card.
Facts/settings/sources/result publish together after generation, not as partial
metadata before awaits. A settings change during source retrieval prevents the
pending call from silently using newly selected settings; a change during
generation leaves a stale snapshot. Cancellation clears the spinner via defer.
No new coordinator, dependency, request retry, model or persistent cache.

Original replay now prints `Narration settings freshness self-check ok`, exit0;
unchanged-settings control also passes. Test covers model, URL, all other backend
modes, missing metadata, changed facts and unchanged inputs. Focused47/47 passed:
`/private/tmp/stocksage-narration-settings-red-20260907.xcresult`,
`/private/tmp/stocksage-narration-settings-green-20260907.xcresult`.
Serial canonical macOS1769/1769 and iPhone17Pro(gate)1767/1767 passed, exit0,
zero selected failures/skips, same three opt-in exclusions (CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests):
`/private/tmp/stocksage-narration-settings-macos-20260907.xcresult`,
`/private/tmp/stocksage-narration-settings-ios-20260907.xcresult`.

Tested installed appPID13924; executable/debug-dylib cmp and strict deep codesign
passed. Normal quit initially met an open detail sheet; installer stopped before
any replacement, then normal sheet close/quit succeeded. Previous app recoverable:
`/Users/saleh/.Trash/StockSageX-pre-narration-settings-20260907-0639.app`.
Native PAA Explain at06:41 used existing QwenPID23631, no injected response:
failed-citation/numeric draft retained in full, prominent warning, exact generating
model and new snapshot footer visible in AX and a populated screenshot. Same
backend/URL/model settings confirmed; no owner settings or money inputs changed.
Live settings mutation and in-flight switching were NOT UI-smoked; settings
decisions use the isolated regression, async publication was reviewed inline.

This does not add wall-clock expiry, prove semantic grounding, or solve the
separate connection-probe freshness race. Next concrete review item: N10/N14,
quote provider/time are absent from narrator facts, so equal-price provenance
changes can escape fact-string invalidation. Primary AI, APIs and contract-gated
P5 retain their independent requirements. No push, real trades, credential access,
cloud upload or model reload; main worktree and stopped sibling task preserved.

## AI assessment checks selected evidence, not every offered fact (2026-09-07 06:26 +03)

N13 bounded source-grounding step. The primary badge parser displayed selected
F IDs but whitelisted numbers from ALL offered facts. A compiled production-module
replay with F1=AAPL revenue100 and F2=MSFT revenue200 accepted the false claim
"AAPL revenue200 (F1)" with evidence[F1]. Original replay exited1; changing ONLY
200→100 passed. The shared parser now checks numbers against selected facts and
requires inline F references to belong to the displayed evidence list. W references
remain bounded unverified group leads, never evidence or a numerical whitelist.
The prompt states the same contract; all six AI actions remain available.

Missing-evidence repair preflights other fields against all offered IDs WITHOUT
publishing those temporary IDs. Its one actual repair still has to pass selected
evidence validation and preserve the original action/reason/risk exactly. This
avoids falsely rejecting a legitimate quote from F2 merely because the old
temporary preflight used F1. Failed replies retain their original visible draft;
no bad record/badge is published, no extra repair for a four-key invalid reply.
No changes to rules, sizing, money, journal or execution paths.

Diagnostic/implementation workflow: regressions at parser AND real coordinator
failed first (10pass/3fail), then37/37 focused assessment/narrator tests passed.
The existing F13 citation fixture now actually selects F13; digit/reference and
private-group checks still pass. Original `/private/tmp/stocksage-grounding.GSpxE9/check`
now prints `Cited-fact numeric binding self-check ok`, exit0 (control also passed).
Artifacts: `/private/tmp/stocksage-cited-facts-red-20260907.xcresult`,
`/private/tmp/stocksage-cited-facts-green-20260907.xcresult`.
Serial canonical gates: macOS1768/1768 and iPhone17Pro(gate)1766/1766 passed,
zero selected failures/skips, same three opt-in exclusions (CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests):
`/private/tmp/stocksage-cited-facts-macos-20260907.xcresult`,
`/private/tmp/stocksage-cited-facts-ios-20260907.xcresult`.

Tested Mac bundle installed asPID9366; binary/debug-dylib cmp and strict deep
codesign passed. Previous bundle recoverable at
`/Users/saleh/.Trash/StockSageX-pre-cited-facts-20260907-0624.app`.
Actual auto-assessed PAA snapshot03:24:16Z rendered Buy, separate Rules Strong Buy,
with selectedF1,F2,F3,F4,F5,F6,F9,F14. Native AX and populated screenshot inspected:
50/200DMA,+16%,6months,ratio9 belong to citedF4;20.5% volatility to citedF5.
No injected response or extra generation request; original QwenPID23631 unchanged.
Account/risk inputs remained untouched. No push/trades/credentials/cloud upload.

Inline review traced both parse calls, repair, draft retention and evidence UI.
This is selected-fact NUMERIC MEMBERSHIP, not semantic entailment: a model can
still swap subjects/signs/units or values among multiple cited facts, or invent a
word-only claim. The older Explain numeric check still has its separate source
contract. N13 remains open for typed claim/source binding; no model-accuracy,
all-API, full-Chat or P5 completion claim. Main-worktree changes preserved.

## Explain retains failed output as an unverified draft (2026-09-07 06:08 +03)

Owner's explicit "never withhold" request also applies to the older Catalyst
Explain paragraph, not only the newer primary AI assessment. Both local-server
and on-device response paths previously discarded text/source and kept only a
withheld reason. Extracted their identical check into one real shared response
boundary, reproduced the loss, then replaced withheld with
unverified(text, generatingSource, reason). The existing UI renders the retained
plain/selectable text, a prominent failed-check warning, the generating model
label/caveats and the same numbered source list. It is NOT marked checked text,
promoted to app facts, or used to change primary badges, sizing or execution.
Unavailable transports/models remain unavailable; no fabricated draft/retry.

The tiny compiled production-module replay
`/private/tmp/stocksage-narrator-draft.sEJ9wn/check` exited1 with only a withheld
reason for an out-of-range citation. Changing ONLY[2]→[1] passed. After the fix,
the original input passes with exact text/source retained and a warning:
`Narrator visible-draft self-check ok`, exit0. No model/network/configuration
needed for this feedback loop. Regression covers both backends, foreign numbers,
out-of-range citations (where the number itself is a valid fact), and valid text.
Red23pass/1fail→33/33 focused narrator/view tests:
`/private/tmp/stocksage-narrator-draft-red-20260907.xcresult`
`/private/tmp/stocksage-narrator-draft-green-20260907.xcresult`.
Full serial macOS1765/1765, iPhone17Pro(gate)1763/1763 passed, exit0, zero
selected failures/skips; same three opt-in exclusions (CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests):
`/private/tmp/stocksage-narrator-draft-macos-20260907-0603.xcresult`
`/private/tmp/stocksage-narrator-draft-ios-20260907-0605.xcresult`.
Tested Mac bundle installed asPID5107; binary/debug-dylib comparison and strict
deep codesign passed. Previous app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-narrator-draft-20260907-0607.app`.

The diagnostic/implementation workflow fixed one shared result boundary rather
than disabling the guards in two backends. Numeric/citation checks still do NOT
prove semantic grounding, sign/subject/unit correctness or profitable analysis.
Existing changed-facts suppression remains; stale paragraphs are not silently
presented under new facts. This is Explain parity, not the full proactive Chat.
Native PAA Explain smoke at06:08–06:09 +03 used the EXISTING Qwen server/model
and actual app facts (no injected response). It generated an unoffered[1] citation;
the numeric check failed, but the complete paragraph remained visible beneath
"Unverified draft" with the exact local model path and caveats. Accessibility
text AND populated screenshot were inspected. This proves the real
request→shared-result→native-panel failed-check path, not improved semantic
accuracy or on-device FoundationModels generation. No response was rewritten.
No push, trades, key inspection, extra model, cloud upload, training or
main-worktree edits. Original QwenPID23631 unchanged; tested appPID5107.

## Pagination Store/UI acceptance completed (2026-09-07 06:07 +03)

Normal installed-app refresh (toolbar action, after the15-minute due window)
persisted answered Form4 observations for ALL nine former incompleteResponse
symbols at03:04:39–03:04:45Z. No cache editing/reset or synthetic timestamp.
Native CRWD card visibly shows5/5 current checks, a Form4 sale filedSeptember4,
and its expanded disclosure says Form4 checkedSeptember7 with one selected
event. This closes the request→parser→Store→UI acceptance gap recorded below.
The cache now has exactly two failures, SBLK/TEM conflictingTransactionDirection;
those source-data contradictions remain unresolved. No all-API/P5 completion claim.

## Company-event pagination implemented and live-replayed (2026-09-07 05:54 +03)

Actual CRWD HTTP200 response at02:41Z:149,572bytes/100rows plus next_url.
Offline replay failed incompleteResponse; removing ALL rows still failed;
removing ONLY next_url made the100 original rows pass. This isolated the
one-page coverage ceiling, not missing access or a malformed transaction.
Official continuation contract: https://massive.com/docs/rest/stocks/filings/form-4

The shared five-feed fetch now follows at most10 sequential pages,100rows/page,
2MB TOTAL, retaining the existing four-symbol Store concurrency. Each page
passes the same row/symbol/date/transaction validation. Only complete success
selects an event (latest, earliest upcoming for dividends). A later error,
oversize response, unsafe/repeated cursor or exhausted cap yields unavailable,
nil event, never a partial or checked-empty success. Single-response parse still
rejects continuation. Selection uses the same deterministic content tie-break.
Continuation requests reuse the MassiveTicks trust-boundary pattern: exact
HTTPS api.massive.com/feed path,443/default port, no userinfo/fragment/API-key
query, bounded URL length, header-only bearer, no redirects. Every production
page retains policy/cancellation/cooldown checks; cancellation after a response
also prevents publication. Probe stays status-only and one request.

Real installed-app fetches,02:51:17–02:51:32Z, all answered successfully:

| Symbol | Pages | Rows | Raw response bytes | Selected event |
|---|---:|---:|---:|---|
| CRWD | 2 | 139 | 207536 | yes |
| UTHR | 2 | 199 | 306269 | yes |
| NAVN | 2 | 136 | 228916 | yes |
| STX | 2 | 183 | 221196 | yes |
| CRNX | 2 | 103 | 213513 | no qualifying transaction |
| CBRS | 2 | 146 | 236072 | yes |
| FLYW | 2 | 111 | 265333 | yes |
| CHYM | 8 | 706 | 1748224 | yes |
| CLBK | 2 | 138 | 130246 | yes |

All real continuation URLs used the exact expected HTTPS host/path and only a
cursor query. Native fetch invoked through the app's Swift debugger context;
no key/header inspection or alternate credential path. Captured public pages
at parsePage, stripped request IDs and replaced cursor URLs with fixed markers.
Debugger detached/breakpoints removed. Private scratch:
`/private/tmp/stocksage-form4-pages.b8WfQx/{main.swift,check,capture.lldb}`.
`check --captured-pages` replays all24 pages OFFLINE, compares each entire
Observation against its native result (9/9 identical), prints
`Form 4 complete-pagination replay self-check ok`, exit0. Original one-page
`check` still exits1 intentionally; `--page-control` isolates the old guard.

Regression at the real injectable request/response seam:18pass/1fail before
paging,21/21 after. Covers all feeds, bad late rows/statuses, cursor security,
repeats,10-page completion/cap,100-row boundary, aggregate bytes/cancellation:
`/private/tmp/stocksage-form4-pages-red-20260907.xcresult`
`/private/tmp/stocksage-form4-pages-green-20260907.xcresult`.
Full serial macOS1764/1764 and iPhone17Pro(gate)1762/1762 passed, exit0, zero
selected failures/skips; same three opt-in exclusions (CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests):
`/private/tmp/stocksage-form4-pages-macos-20260907-0548.xcresult`
`/private/tmp/stocksage-form4-pages-ios-20260907-0550.xcresult`.
Tested Mac installed asPID98852; executable/debug-dylib comparisons and strict
deep codesign passed. Previous app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-form4-pages-20260907-0551.app`.

IMPORTANT acceptance boundary: the targeted live fetches do not write the Store.
At05:54 the ordinary app cache still has9 old incompleteResponse warnings from
05:48 checks, plus the2 genuine SBLK/TEM direction conflicts. Do NOT edit/delete
cache to manufacture success. Next verify the normal due refresh after06:03 +03,
then native Company feeds UI. Request/parser success is proved; new Store/UI
publication remains pending. Other API/Chat/P5 work is not declared complete.
Only coverage worktree changed; main files preserved, no push/trade/new model,
original QwenPID23631 unchanged. Inline review found no further blocker.

## Remaining Form4 validation failures are contradictory source filings (2026-09-07 05:32 +03)

SBLK and TEM do NOT have the prior security-spelling bug or a missing credential.
Two targeted read-only fetches ran through the installed app's own fetch path,
from its existing Swift debugger context. Captured only the public response at
the parser boundary (SBLK2,414bytes/2rows; TEM83,666bytes/48rows); removed request
IDs/cursor URLs, never inspected credentials. Debugger detached and all breakpoints
removed. No app settings, journal or cached observation was manually changed.

Offline original replay minimized each failure to one row: SBLK index1,
accession0002005037-26-000012, and TEM index46, accession0002113721-26-000016.
Both code the transaction S (sale) but label shares A (acquired). Changing ONLY
A→D makes the replay pass, but that control is NOT a correction authorized for
real data. The same S/A conflict appears in the primary filings themselves:
- SBLK: https://www.sec.gov/Archives/edgar/data/1386716/000200503726000012/xslF345X06/primary_doc.xml
- TEM issuer copy: https://investors.tempus.com/node/10586/html
- SEC interpretation233.03 says transaction codes and acquired/disposed labels
  must be consistent: https://www.sec.gov/rules-regulations/staff-guidance/corporation-finance-interpretations/exchange-act-section-16-related-rules-forms

Keep the rejection; do not invent purchase/sale direction or checked-empty status.
Added a fixed conflictingTransactionDirection failure category through the
existing response/cache/UI path instead of the unhelpful generic invalidPayload.
Unknown direction strings still get invalidPayload; no row/cap/entitlement bypass.
One regression pins P/D and S/A rejection, nil event, Codable preservation and
specific UI copy. Red17pass/1fail→focused18/18:
`/private/tmp/stocksage-form4-direction-red-20260907.xcresult`
`/private/tmp/stocksage-form4-direction-green-20260907.xcresult`.
`/private/tmp/stocksage-form4-remaining.MTlwKF/check --expect-conflict` also red→green
against BOTH untouched captured responses, keeping them unavailable with no
event. `--direction-control` is diagnostic-only; never writes the captured data.
The standalone harness loads no user configuration and performs no network I/O.

Full serial macOS1761/1761 and iPhone17Pro(gate)1759/1759 passed, exit0, zero
selected failures/skips; same three opt-in exclusions (CalibrationPersistRunTests,
LiveUniverseVerificationTests, StrategyBaselineMeasurementTests):
`/private/tmp/stocksage-form4-direction-macos-20260907-0530.xcresult`
`/private/tmp/stocksage-form4-direction-ios-20260907-0532.xcresult`.
Installed tested Mac bundle; executable/debug-dylib comparisons and strict deep
codesign passed. Prior app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-form4-direction-20260907-0533.app`.
Native SBLK expanded disclosure and screenshot show the specific conflict reason,
not generic validation or a missing-key message, and correctly retain4/5 checks.
Normal app refresh persisted conflictingTransactionDirection for TEM02:33:22Z
and SBLK02:33:24Z; cache now has exactly two conflicts plus nine incompleteResponse
failures. No cache reset or edit. Installed appPID94169, original Qwen unchanged.
The two source conflicts remain real unresolved data-quality failures, not API
successes. Next separate issue: the nine measured one-page/100-row limits.

## Form 4 live-schema mismatch fixed (2026-09-07 05:19 +03)

GILD was not missing API access: one bounded configured request returned HTTP200,
13,663 bytes and11 rows, but the production parser rejected seven rows. Live
`security_type` is `non_derivative`; the official Form4 docs say `non-derivative`:
https://massive.com/docs/rest/stocks/filings/form-4
Changing ONLY that field in the captured response made the replay pass. The
shared parser now accepts both exact spellings, still rejects unknown types,
and still excludes derivatives. No caps, credentials, retries, trading logic or
UI validation were relaxed. The diagnosing-bugs workflow isolated a provider
contract mismatch that the documentation-shaped fixture did not cover.

Evidence:
- `/private/tmp/stocksage-form4.vqNqtf/main.swift` and `check`: isolated compiled
  production-module request/response replay using existing app configuration.
  No key value/header was printed or exported. The private scratch capture keeps
  public filing data, strips request ID, replaces any pagination URL with a fixed
  marker, and freezes time. Offline original replay repeatedly exited1 with
  invalidPayload; field-only control passed. After fix the UNMODIFIED capture and
  all11 isolated rows pass, `Form 4 replay self-check ok`, exit0. This diagnostic
  is not itself native-consumer acceptance; that was verified separately below.
- Regression at the actual response→observation seam covers purchase/sale aliases,
  full event equality and unknown/derivative exclusions. Before fix16pass/1fail:
  `/private/tmp/stocksage-form4-red-20260907.xcresult`; after fix17/17:
  `/private/tmp/stocksage-form4-green-20260907.xcresult`.
- Full serial gates: macOS1760/1760 and iPhone17Pro(gate)1758/1758, exit0,
  zero selected failures/skips. Same three opt-in suite exclusions:
  CalibrationPersistRunTests, LiveUniverseVerificationTests,
  StrategyBaselineMeasurementTests.
  `/private/tmp/stocksage-form4-macos-20260907-0516.xcresult`
  `/private/tmp/stocksage-form4-ios-20260907-0517.xcresult`.
- Installed the tested macOS bundle; executable AND debug dylib comparisons and
  strict deep codesign verification passed. Prior app recoverable at
  `/Users/saleh/.Trash/StockSageX-pre-form4-fix-20260907-0517.app`.
- Native Catalysts GILD expanded disclosure/screenshot now shows5/5 current checks
  and a Form4 sale filed September2. App-owned cache independently records an
  answered Form4 check at2026-09-07T02:17:12Z. No manual cache edit.
- Normal installed-app refresh reduced Form4 invalidPayload285→2 (283 recovered).
  At05:19, SBLK and TEM still fail validation; nine remain incompleteResponse:
  CRWD,UTHR,NAVN,STX,CRNX,CBRS,FLYW,CHYM,CLBK. Do not label these empty/successful
  or assume the same cause. Diagnose those two payloads next, then the measured
  pagination ceiling. All other API acceptance and P5 remain open.

Only this worktree changed. Main's unrelated files preserved, no push/trade/new
model process; original Qwen PID23631 remains. Installed app PID88355. Temporary
debugger/probe attempts made no production edits; debugger detached, breakpoints
removed, and the offline replay above provided the actual red/green evidence.

## Demo-quote contamination and test-host isolation (2026-09-07 05:01 +03)

The "sample" header was NOT just a cosmetic label bug. The real quote cache held
902 entries: five sample rows (the exact startup seed set),35Yahoo,862MassiveSIP.
Sample quotes carried a fresh Date(), so the shared monotonic-clock guard rejected
genuine older market closes on those symbols. Full refresh preserved and cached the
demo rows; scan publication could copy their synthetic prices onto real histories.
The failure reproduces without XCTest, disk I/O or network; test pollution is not
required for this ordering bug. Unit-test hosts nevertheless had access to the real
default cache and launched the normal auto-refreshing Markets screen.

Fixed at shared seams, not by suppressing the source label:
- Quote/tick ordering now rejects explicitly sample incoming observations and
  ignores an existing sample clock when considering real data. Provenance flows
  through full/targeted/polled refreshes, streams, infraFX and scan publication.
  Genuine timestamp/sequence ordering and undated/future guards remain in place.
- Header clock/source selection excludes synthetic observations. The sample-only
  startup banner still exists; a mixed board cannot derive freshness from demos.
- Quote-cache extraction excludes samples; loading old contaminated files ignores
  only explicitly sample entries, preserving other values/dates and not rewriting
  on read. No manual cache deletion or price replacement was performed.
- Unit-test app hosts skip Markets startup and iOS telemetry/notification setup.
  Default quote-cache I/O is disabled under the existing test detector; explicit
  temporary-URL round trips remain enabled. This is not a claim that every other
  singleton/UserDefaults persistence path has been independently isolated.

Diagnosing-bugs evidence:
- `/private/tmp/stocksage-sample.9Pu3sd/main.swift`: fresh demo AAPL227.1 blocked
  real245 with a two-day-old timestamp, acceptedKeys empty, exit1. Removing only
  the demo timestamp made the control pass. After fix: real245/MassiveSIP accepted,
  `Sample recovery self-check ok`, exit0. Non-test default-cache access also passes.
- `/private/tmp/stocksage-sample-red-20260907.xcresult`:21pass/2fail before fix.
  Separate `/private/tmp/stocksage-sample-isolation-red-20260907.xcresult` failed
  the default-cache isolation regression before its guard. Focused57/57 green:
  `/private/tmp/stocksage-sample-focused2-20260907.xcresult`.
- Full serial gates: macOS1759/1759 and iPhone17Pro(gate)1757/1757, exit0,
  zero selected failures/skips. Same three opt-in exclusions (CalibrationPersistRun,
  LiveUniverseVerification, StrategyBaselineMeasurement test suites):
  `/private/tmp/stocksage-sample-final-macos-20260907-0456.xcresult`
  `/private/tmp/stocksage-sample-final-ios-20260907-0458.xcresult`.
  With the installed app normally quit, the owner's real quote-cache SHA256 stayed
  `58a4613c459e16c67dc2c246072b9a3ea449487aaf041d3ad75454c677e09bce` across both gates.
- Native normal launch after installation:902entries,864MassiveSIP+38Yahoo, ZERO
  samples. All five seed rows recovered through the normal provider refresh.
  AAPL/NVDA now have September4 market times; the three Saudi names September6.
  AX and screenshot show "Last quote · Yahoo · as of 6 Sep 2026 at 3:19PM" and
  amber "Last observed quote (not live)", replacing today's green sample stamp.
  M4 weekly consistency remains4.6Rnet/4.8Rgross. No sizing/alert/journal action.

Tested app installed at `/Applications/StockSageX.app`,PID83180; executable+dylib
comparisons and strict/deep codesign passed. Old app recoverable at
`/Users/saleh/.Trash/StockSageX-pre-sample-fix-20260907-0500.app`; pre-recovery cache
copy at `/private/tmp/stocksage-sample.9Pu3sd/quote-cache-before.json` (outside git).
Original QwenPID23631 unchanged; no training, cloud upload, push or real trade.
Main worktree/pbxproj preserved. Next: remaining live per-route acceptance and
company-event/Form4 diagnosis, then model-news semantic checks/full Chat/P5.
Keep the existing15-minute same-task heartbeat; not overall completion.

## M4 — shared gross/net velocity horizon (2026-09-07 04:44 +03)

Fixed the full-review P1 where costs appeared to INCREASE daily/weekly returns.
Gross velocity already inflated hold time for variable absolute price moves;
net velocity, its actual ranking key, sized snapshots and turnover labels did not.
`velocityHoldDays(for:holds:)` now supplies that same positive, finite denominator
to all five paths. Weekly gross/net sums inherit it without changing their
same-basket/concentration contract. Fee numerators, short-borrow assumptions,
probability mapping and the existing dispersion heuristic are unchanged. This is
arithmetic consistency, not validation of a holding-time model or profitable edge.

Evidence from the diagnosing-bugs red/green workflow:
- Production-module replay: `/private/tmp/stocksage-m4.Dh1v2W/main.swift` (recompile
  against the current Debug dylib before running). Synthetic AAPL100/90/120,
  conviction1, spark[100,101,101,103]: gross .0222R/day, old net .03635R/day;
  same-stock weekly .111R gross versus .18175R net. Per-trade EV already fell
  correctly from .74R to .727R; constant-move control removed the mismatch.
  After fix: net .02181R/day, weekly .10905R, snapshot parity, exit0 and
  `M4 same-horizon self-check ok` (original exit1).
- Regression first failed on both actual ranking and the gross/net/cadence seam:
  `/private/tmp/stocksage-m4-red-macos-20260907.xcresult`, 4pass/2fail, exit65.
  Existing Jensen test previously checked only gross display, never rank order.
- Focused140/140, exit0: `/private/tmp/stocksage-m4-focused-macos-20260907.xcresult`.
  Covers uneven/constant/empty sparks, default/custom holds, sized and unsized
  snapshots, actual ranking and sized override, same-stock weekly sums, turnover,
  zero-cost primitive equality, unsupported classes and invalid hold inputs.
- Full serial gates: macOS1756/1756 and iPhone17Pro(gate)1754/1754, both exit0,
  zero selected failures/skips:
  `/private/tmp/stocksage-m4-final-macos-20260907-0441.xcresult`
  `/private/tmp/stocksage-m4-final-ios-20260907-0442.xcresult`
  Same three explicit opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Not live API
  acceptance or strategy-performance evidence. Only the known existing warnings.
- Native before/after AX and screenshots: main weekly net6.8R/gross4.8R becomes
  net4.6R/gross4.8R; fastest PAA net1.20 becomes .78R/day. 1080.SR detail now
  shows gross .221/net .180R/day, formerly net .265. Original account text and
  empty risk field left untouched; no copy, journal, alert or trading action.

Tested app installed as `/Applications/StockSageX.app`, PID76843. Executable AND
debug dylib comparisons and strict/deep codesign passed. Prior app normally quit
and preserved at `/Users/saleh/.Trash/StockSageX-pre-m4-20260907-0443.app`.
Qwen remains the original PID23631; no model reload/train/cloud upload. No pushes,
real orders or changes in the main worktree. Next: sample-header/test-cache
isolation, then remaining API/model-quality/P4/P5 work. Not overall completion;
the existing 15-minute heartbeat remains in this task.

## M8 — quantity-aware costs across sized decisions (2026-09-07 04:31 +03)

Fixed the reproduced minimum-fee disagreement without changing the fee table or
the model's opinions. DecisionSnapshot now sizes first, then derives net R:R,
net expectancy, net velocity, floor flag and cost-failure reason from ONE NetEdge.
Its gate rejects zero-share and non-positive sized expectancy; an unknown foreign
order size warns that minimums are unpriced. Missing FX still blocks, never 1:1.
Board/detail/CTA net displays and copied plans reuse that snapshot. Removed the
view-only invented $10,000/1% snapshot defaults. Unsized research ranking remains
the existing rules model; both Today's Plan ranking modes now apply sized costs
before top-N truncation. Gross fields remain labelled gross.

Single and multi-plan exports omit actionable terms for blocked rows. Allocation
and marginal-add checks re-evaluate costs at FINAL rounded shares after risk
limits. Rejected allocations leave their risk budget in cash, with named reasons;
no redistribution loop or new sizing strategy. Existing raw-quote-unit fee and
short-financing assumptions are retained and disclosed, not certified broker
tariffs. This does not establish that Derayah trading/API acceptance is ready.

Evidence:
- A standalone production-module replay in `/private/tmp/stocksage-m8.OzjDIX/`
  failed before the fix: one-share SAP.DE, entry100/stop95/target115, accountUSD600,
  risk1%, EURUSD1.1: snapshot2.773585R:R versus sized1.531646, CLEAR. Afterward it
  prints `M8 sized-cost self-check ok`, sized netEV0.648R and CAUTION.
- Stronger regression: SAP.DE100/99/103, accountUSD120, risk1%, EURUSD1.1,
  conviction0.9. Before: displayed2.076923 versus sized0.025641R:R, CLEAR despite
  costs. After: BLOCKED, netEV-1.672R, sized floor/ranking and status-only exports.
  `/private/tmp/stocksage-m8-red2-20260907.xcresult`: 9pass/1fail, exit65.
- `/private/tmp/stocksage-m8-focused3-20260907.xcresult`: 101/101, exit0. Covers
  size/FX changes, long/short financing, missing FX, zero shares, ranking max1,
  final-size allocation/add rejection and copied-plan parity. Initial test label
  typo and two integration compile errors were fixed before these passing runs.
- Native installed-build test at04:25: 1080.SR, temporary accountUSD10/risk1%,
  yielded1share, gateBLOCKED, netR:R-0.5 and netEV-5.70R, ~1204bps total estimated
  cost including minimums. Screenshot/AX verified; original account text and blank
  risk field restored. No journal, alert, real order or account connection made.
- Final broad gates, including the 64-bit share-count formatting regression:
  macOS1755/1755 and iPhone1753/1753, both exit0, zero selected failures/skips.
  `/private/tmp/stocksage-m8-final2-macos-20260907-0428.xcresult`
  `/private/tmp/stocksage-m8-final2-ios-20260907-0430.xcresult`
  Same three opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests and StrategyBaselineMeasurementTests. These runs
  do NOT claim live API acceptance or measured strategy performance.

The tested app replaced `/Applications/StockSageX.app`; old bundle recoverable at
`/Users/saleh/.Trash/StockSageX-pre-m8-20260907-0425.app`. Executable and debug dylib
comparisons plus strict/deep codesign passed. Original Qwen PID23631 unchanged;
no training, downloads or uploads. Main worktree/pbxproj untouched; no pushes.
Final formatting-only build installed after its macOS gate, process72465; the
preceding M8 bundle is recoverable at
`/Users/saleh/.Trash/StockSageX-pre-m8-format-20260907-0430.app`. Both binary
comparisons and strict/deep signature verification passed again. The one-share
native check above preceded only that 64-bit formatting correction.

Next: M4 gross/net projection horizon mismatch (still visible natively), then
sample-header/test-cache isolation and semantic news/model checks. Broker contract,
live per-route API acceptance, full Chat/iPhone serving and P5 remain open. The
15-minute heartbeat continues in this task; this is not overall completion.

## Final native research verification — 2026-09-07 03:57 +03

Final installed QCOM badge: **AI Hold**,03:55snapshot, RulesAvoid, exact4-bit
model ID, real news-source disclosure and3 private export leads. Visual screenshot
and AX both show the complete opinion, counter-case and provenance. AMZN03:47
and APP03:49 each rendered accepted Hold with3 private leads and news disclosures
in the preceding research build (only citation parsing changed afterward).
Quotes were dated September4, not live execution prices; no rating was forced.
Native main best-opportunity also showed PAA AIBuy versus RulesStrongBuy.

News-enriched QCOM exposed another false rejection: inline F13 was read as a
financial13 by the existing numeric tokenizer. Fixed in the shared assessment
parser, not in each view: validate F IDs against offered facts and W IDs against
the captured lead count, exclude only those identifiers from number comparison.
Unknown references and W-as-verified-evidence remain invalid. Regression was
9/10 passing and1 failed before fix, exit65. Final macOS1752/1752 and iPhone
1750/1750, exit0, same3 opt-in exclusions, zero selected failures/skips:
- `/private/tmp/stocksage-ai-inline-red-20260907-0349.xcresult`
- `/private/tmp/stocksage-ai-inline-final-macos-20260907-0350.xcresult`
- `/private/tmp/stocksage-ai-inline-final-ios-20260907-0352.xcresult`

Final install normally quit58374 and preserved that bundle in
`/Users/saleh/.Trash/StockSageX-pre-inline-20260907-0354.app`. Executable AND debug
dylib comparison and strict deep codesign passed; user data/settings preserved.
Qwen remains the original single process23631; no training or cloud upload.

Remaining quality findings are explicit: APP conflated different feed windows
with30days despite mechanical checks passing; QCOM repeats provider commentary
as fundamentals without an independent filing check. News often mentions the
target within another company's article. These are semantic/relevance evaluation
cases, not evidence of verified predictions. The main header still reports a
newer sample quote while these target quotes are genuine MassiveSIP; investigate
cache/test isolation separately, never manually rewrite caches to hide it.
M8 minimum-fee and M4 gross/net-horizon defects, all-route live API acceptance,
older narrator draft-display parity, full Chat/iPhone serving and P5 are still
open. Main worktree/pbxproj untouched, no real orders or pushes. Keep overnight
work in this one task; don't equate this feature release with overall completion.

## Primary Qwen assessments, news and private group leads — 2026-09-07 03:45 +03

Implemented owner02:19 Qwen-selected primary badges, then03:20 news/visible
drafts/private WhatsApp research. Separate AI records never mutate TradeAdvice
or sizing/EV/stops/execution. Shared Ideas/Catalysts/detail badges show AI action,
time and secondary Rules action; rankings, filters, widget and trade-plan exports
remain explicitly Rules-based. Global one-request ceiling, bounded top3 after
scan, selected detail and explicit Reassess; no per-tick model work or new server.
Existing news service supplies at most3 recent excerpts; failures/unknown dates
stay explicit. Exact model and fact/source disclosures are visible. Invalid model
output is a plain-text unverified draft, not hidden or promoted to a valid badge.
The older optional Catalyst narrator's withholding behavior is unchanged.

Both owner-provided WhatsApp exports imported locally:546messages(24+522),
private0600 index outside git, no source archive edits/extraction/upload/training.
Latest3 relevant distinct messages within30days are W-leads, outside F-facts and
the numeric whitelist. Sender/contact redaction is heuristic; identities/CFA
claims/performance remain unverified. Snapshot, NOT live WhatsApp. Timezone
Asia/Riyadh is explicitly assumed. Full limits/research references and refresh
instructions: `agent-docs/QWEN_RESEARCH_2026-09-07.md`.

QCOM root cause captured: valid three-key JSON omitted evidence. One format-only
repair preserves action/reason/risk exactly. The first real repair supplied four
valid references and hit an arbitrary three-reference cap; removed that display
cap, retaining offered-ID/uniqueness/size checks. Four-ID regression:8/10 passed,
2 failed on old code, exit65; final broad tests include both passing. Actual
original-response replay now exits0: Hold, original two sentences unchanged,
F3/F4/F5/F6. No retry-until-Buy, invented evidence or adjusted financial threshold.

Final gates: macOS1752/1752 and iPhone17Pro(gate), iOS26.5,1750/1750, both exit0,
no selected failures/skips. Same3 explicit opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests, StrategyBaselineMeasurementTests.
- `/private/tmp/stocksage-ai-citations-red-20260907-0340.xcresult`
- `/private/tmp/stocksage-ai-research-final-macos-20260907-0341.xcresult`
- `/private/tmp/stocksage-ai-research-final-ios-20260907-0343.xcresult`
- Earlier focused news/group tests67/67:
  `/private/tmp/stocksage-ai-research-focused-20260907-0333.xcresult`
- Local actual failure/replay harness and captured public facts:
  `/private/tmp/stocksage-ai-smoke.zpIGHz/diagnose.swift`, `QCOM-replay.json`.
- Importer `python3 tools/import_whatsapp_research.py --demo`: self-check ok.
Initial missing-interface tests failed at compile, not runtime. One mistaken
method-specific selector selected zero tests; it is NOT counted as passing proof.

Normally quit installed process48827 (close sheet before Cmd-Q), preserved only
the old bundle in `/Users/saleh/.Trash/StockSageX-pre-research-20260907-0346.app`,
copied the final tested macOS app to `/Applications/StockSageX.app`, verified both
executable and debug dylib byte-for-byte plus strict deep codesign, and opened it.
User data/preferences untouched. Existing Qwen process23631 remains unchanged.
Native final stock/source checks follow below. Main worktree untouched; no push
or real trades. Full Chat, secure iPhone serving, M8/M4 fixes, provider acceptance
and P5 remain open; green software gates do not establish a profitable strategy.

## Company-feed failure diagnostics — 2026-09-07 02:31 +03

Native GILD coverage showed four successful checks and an unavailable Form4
check; other symbols showed five. The specific cause is NOT established. The
shared request/parser previously discarded every failure, so this change retains
only a fixed typed category or HTTP status through Observation, disk Codable,
preflight sweep and the existing per-feed status line. No raw body, URL, header,
or localized error is retained. Valid-empty remains answered; pagination and
oversize responses remain unavailable with their existing limits, not partial
success. No new endpoint, retry, cap, timeout, credential access or UI screen.

New regression exercises13 failure cases, cache roundtrip, secret-like sentinel
exclusion, valid-empty and legacy records without the optional reason. The red
attempt failed to compile against the missing interface (zero tests ran), not a
runtime reproduction of GILD's failure. Focused16/16 passed; broad macOS1741/1741
and iPhone17Pro(gate)1739/1739 passed, exit0, no selected failures/skips. Same
three opt-in exclusions: CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. Exact bundles:
- `/private/tmp/stocksage-api-reasons-red-20260907-0211.xcresult`
- `/private/tmp/stocksage-api-reasons-green-20260907-0218.xcresult`
- `/private/tmp/stocksage-api-reasons-macos-20260907-0223.xcresult`
- `/private/tmp/stocksage-api-reasons-ios-20260907-0230.xcresult`

Installed app still d4967a0; this diagnostics update is not installed yet. Main
worktree untouched. No pushes, actual trades or duplicate model/Stocks servers.
Owner02:19 requested Qwen set primary Buy/Strong Buy badges. Planned primary
AI assessment with model/data provenance, rules comparison, explicit missing/
invalid state, and unchanged deterministic risk/execution checks; not implemented
in this diagnostics commit. ORCL's live app cache already records confirmed
September10 earnings from Massive/Benzinga. Oracle's September2 official IR
announcement independently confirms September10,2026 after US market close.
No calendar/cache edit was needed; the date alone does not imply a positive return.

## Cited narrator provenance fixed — 2026-09-07 02:05 +03

Live SBLK/Qwen output reproduced a footer bug: any positive evidence count
discarded the backend/model captured on Result.text. Fixed the shared label
overload to append the listed evidence count to the existing source-aware label.
Generation, numeric/citation validation, and settings are unchanged. Singular
source wording is correct; zero/negative counts preserve the original label.

Revised the existing tests that pinned the generic footer; no new test suite.
The regression failed against the old implementation (22/23 passed, exit65),
then passed with the fix (23/23, exit0). Evidence bundles:
- `/private/tmp/stocksage-narrator-footer-red-20260907-0153.xcresult`
- `/private/tmp/stocksage-narrator-footer-green-20260907-0159.xcresult`
- macOS1740/1740, exit0: `/private/tmp/stocksage-narrator-footer-macos-20260907-0200.xcresult`
- iPhone17Pro(gate)1738/1738, exit0: `/private/tmp/stocksage-narrator-footer-ios-20260907-0202.xcresult`
Same three opt-in exclusions; no selected failures/skips in either final gate.

Quit the old installed process normally and replaced only the app bundle with
the tested macOS binary. Executable comparison and strict deep codesign passed.
Previous bundle is recoverable at
`/Users/saleh/.Trash/StockSageX-pre-footer-20260907-0204.app`; user data/preferences
were preserved. New installed process31018 observed. Qwen's existing loopback
server was left running; no duplicate server, new training, or real orders.
Owner02:02 reiterated every API must work: per-route native acceptance is next,
not a blanket success claim. Main worktree and other session remain untouched.

## Qwen converted and connected — 2026-09-07 01:50 +03

Owner01:41 approved the conversion/server startup that the previous note held
for approval. DONE: separate4-bit copy15.13GB,15shards,1847tensors; original BF16
untouched. Conversion exit0, measured4.76GB peak RSS, repeated saved-index checks
passed, overwrite attempt rejected. Added `tools/convert_qwen_mlx.py`, reusing
installed MLX loader/quantizer/writer, not installing/updating packages.

Server is RUNNING under the session-local launchctl job
`com.swonyu.stocksage.qwen-local` (PID23631), listener127.0.0.1:8765only. Native
StockSage Catalysts settings now use Local server only and exact model ID
`/Users/saleh/models/salehman-qwen38-27b-4bit`. Real model discovery passed,
synthetic stale-quote generation passed, and a real SBLK card rendered a
validated explanation citing Massive news. PAA's first response was withheld
by the unchanged numeric guard; that is recorded, not hidden as a success.

Full commands, limits, logs and stop/restart instructions:
`agent-docs/LOCAL_QWEN_2026-09-07.md`. No public/iPhone exposure, no automated
login/reboot startup, no trades, no cloud purchases. Do not start a second model
server or blindly relaunch conversion. Use launchctl remove for this exact job
when the owner requests unloading. Main worktree unchanged; installed app remains
the tested d7c84a0 build, not modified by these tooling/docs changes.

Remaining: per-route API acceptance; new Chat/proactive Qwen briefing; secured
iPhone serving; M8/M4 money-safety fixes and P5. Cited narrator footer omits model
name when sources>0 (header correctly shows selected local model)—follow up in
the shared label helper. No Swift changed this slice, so no redundant full build;
existing1740macOS/1738iOS gates still describe the installed app source.

## Owner-requested installed build replacement — 2026-09-07 01:36 +03

Owner01:34: open the new build and delete the old one. The active installed app
was a July28 executable, without the new API settings. Quit process18626 via
native Cmd-Q; verified no StockSage process remained before replacing anything.
Moved only `/Applications/StockSageX.app` to
`/Users/saleh/.Trash/StockSageX-old-20260907-0134.app` (recoverable; not purged).
Installed the existing tested macOS app from
`/private/tmp/stocksage-codex-m1b.qzpbNS/Build/Products/Debug/StockSageX.app`.
Executable cmp and codesign --verify --deep --strict passed. This is d7c84a0's
tested build:1740macOS/1738iOS, no new source changes or redundant builds.

Opened the new installed app, verified only process20169 running, and opened
Settings → Data sources. The existing saved Massive key appeared only as masked
secure text. Native Test connection returned:
`Connected — HTTP 200, AAPL snapshot parsed.`
No credentials were retrieved/revealed, no second socket/process deliberately
opened, no settings/portfolio/journal data deleted, and no model loaded. The
older PID11897 is no longer current. Main worktree remains untouched.

Separate01:32 presence-only shell check was denied again by PreToolUse; do not
retry or bypass it. Native snapshot testing is now possible and passed, so do
not keep calling every Massive route credential-blocked. Other endpoints still
require individual native verification; snapshot success is not add-on access,
store freshness, or live T/Q delivery proof. Updated API ledger holds evidence.
M8 tracing was paused for the owner's API/build request; no M8 edits made.

Owner01:37 additionally requested connecting all app AI features to Qwen. Local
inspection found `/Users/saleh/models/salehman-qwen38-27b/config.json` declares
Qwen3_5ForCausalLM/qwen3_5_text, bfloat16, no quantization config. No GGUF or other
quantized config found under the owner's models directory; no Ollama/MLX/vLLM
server process observed. Mac reports48GiB physical memory. Do not load the
51GB BF16 checkpoint directly. Quantization/server startup remains a distinct
resource decision under the owner's earlier save-RAM restriction; no conversion,
download, server startup, inference request or preference change performed here.

## N09 earnings API response classification — 2026-09-07 01:24 +03

Fixed the reviewed error/empty conflation without new network requests. The
actual EODHD parser reproduced it in a fast isolated CLI loop: a JSON error
object returned a non-nil zero-row list, which its fetch/chain treated as answered.
Unused networking/config dependencies were stubbed, not the parser. Red exited1
with `FAIL: malformed response became answered empty (0 rows)`; the same command
after the fix exited0 with `PASS: malformed unavailable, genuine empty answered`.
The final binary was rerun green after both platform gates.

Diagnostic-only command (run from this worktree; no key/network access):
```
xcrun swiftc StockSage/Sources/StockSage/StockSageEODHDCalendar.swift /private/tmp/stocksage-n09-repro.IskiBE/main.swift -o /private/tmp/stocksage-n09-repro.IskiBE/check && /private/tmp/stocksage-n09-repro.IskiBE/check
```

Yahoo's legacy fetch now delegates to its richer fetch. Both use the same
validated CalendarFetch outcome rather than wrapping a parser miss in answered.
The module container must exist and contain a single result without provider
errors. An explicit empty date list stays answered(nil); missing/partial ranges,
Boolean/non-finite/out-of-range epochs stay unavailable. Estimate flags require
an actual Boolean before a date can be called confirmed. Optional convenience
parsers delegate to this same core, eliminating the duplicated date extraction.

EODHD calendar/history and Yahoo history now return optional arrays: nil for
missing/error/partial, [] only for a valid explicit empty container. EODHD
calendar checks the requested symbol; date text round-trips to reject values
such as2026-02-30 instead of silently normalizing them. Date-field interpretations
and optional projections are unchanged; they are not newly live-verified.

Two new test functions and revised existing fixtures cover the real parsed
response→chain and refresh-stamp seams. Malformed replies cannot count as an
answered source or earn the24h checked timestamp; valid empties can. Old tests
explicitly encoding malformed-as-empty/partial-as-complete were changed to the
reviewed contract, with positive and genuinely empty controls retained.

Executed results, xcresulttool counts, serialized builds:
- Focused Earnings/EODHDCalendar/CatalystChain:56/56,exit0:
  `/private/tmp/stocksage-n09-focused-20260907-0121.xcresult`.
- FINAL macOS:1740/1740,exit0:
  `/private/tmp/stocksage-n09-broad-macos-20260907-0119.xcresult`.
- FINAL iPhone17Pro(gate),iOS26.5:1738/1738,exit0:
  `/private/tmp/stocksage-n09-broad-ios-20260907-0122.xcresult`.
All zero selected failures/skips, same opt-in exclusions:
CalibrationPersistRunTests, LiveUniverseVerificationTests,
StrategyBaselineMeasurementTests. No compile correction required this slice.
All command handles finished; no temporary debug instrumentation in app source.

No liveAPI acceptance status changed: Yahoo429/SEC403 and authenticated access/
Derayah-contract blockers remain. Existing derived cache entries were not purged
or retroactively certified; prior malformed writes cannot be identified without
provider evidence and otherwise age through the existing TTL. No persistent
service, model load, retry-policy change, real order, unrelated worktree edit or
push. Work inline; other pipeline task verified unchanged/stopped at01:10.
Next is M8 sized minimum-fee/gate/EV/export consistency before P5 tickets.

## All-API acceptance audit — 2026-09-07 01:06 +03

Owner00:59 requires every integration to work. Reachable route/consumer/status
inventory and bounded live-probe evidence are in
`agent-docs/API_VERIFICATION_2026-09-07.md`. Six Yahoo chart/FX/calendar/history-
module GETs returned429; SEC ticker map with Disclosure's existing agent returned
403. No downstream SEC call, retry loop, proxy/header evasion, key access or
second socket. Default localhost Ollama discovery returned a transport error;
the owner's actual configured server and generation were NOT tested.

These probes used a small Python stdlib HTTP/JSON diagnostic, not the native
URLSession/parser/UI. Process exit0 only means the status collection completed;
it is explicitly NOT seven API passes. No payloads/keys/account details saved.
Massive/EODHD authenticated checks and the actual broker contract remain blocked.
The all-API requirement is not satisfied yet. Next independent API correction:
N09 malformed200→answered(nil), with regression at the response/chain seam;
then M8 minimum-fee/gate consistency before P5 tickets. No live order authority.

M9 code/tests were committed locally as60c8d3d before this read-only API audit.
No code changes since its1738/1736 canonical gates; audit changes are docs only.

## P5 prerequisite / M9 dated-FX checkpoint — 2026-09-07 01:01 +03

Completed the second M9 boundary on top of fd0ff0d. infraFX now retains an
existing StockSageQuote (price, marketTime, source), not a bare Double. A shared
resolver returns the selected rate WITH that observation's clock; known-source
rates within the existing72h app-planning ceiling take precedence, then newest
market time, then stable candidate order. Fetch time never establishes freshness.
USD remains identity1; sample, invalid/future timestamps, non-finite/non-positive
prices and unusable inverse conversions cannot become usable valuation rates.
New sizing additionally rejects old/undated/unknown-source observations.

The pure infra merge enforces the allowed symbol, matching payload symbol,
positive finite price and monotonic market clock. Empty/failed/rejected updates
preserve the last accepted observation without renewing its age. Undated first
responses remain unverified; valid incoming clocks can recover a corrupt future
stored date. Publishing checks cancellation and network policy after the await.
No extra request, timer, persistence format or dependency was introduced.

Every shipped size/plan/snapshot/allocator/detail/export caller still enters via
sizingFXRates, now requesting only eligible dated FX. Ordinary portfolio totals
can retain old/unknown rates with an explicit summary warning, and their rate-map
and missing-currency keys now use the same quote-leg currency as portfolioTotals.
The detached rate-age lookup is removed; a fresh inverse clock can no longer
validate an older direct price. Regression: USD100 risk /EUR10 stop distance
/EURUSD2 yields5 shares, selecting both the inverse rate and its actual clock.

Actual results (serialized xcodebuild; xcresulttool counts):
- Initial missing-interface RED compile failure,exit65,zero tests:
  `/private/tmp/stocksage-m9-dated-fx-red-20260907-0046.xcresult`.
- First implementation compile failed on a mixed numeric test array inferred as
  `[Any]`,exit65,zero tests. Fixed by typing it `[TimeInterval]`:
  `/private/tmp/stocksage-m9-dated-fx-focused-20260907-0050.xcresult`.
- Focused Currency+PositionSizer:40/40,zero failures/skips,exit0:
  `/private/tmp/stocksage-m9-dated-fx-focused-20260907-0051.xcresult`.
- FINAL macOS:1738/1738,zero selected failures/skips,exit0:
  `/private/tmp/stocksage-m9-dated-fx-broad-macos-20260907-0058.xcresult`.
- FINAL iPhone17Pro(gate),iOS26.5:1736/1736,zero selected failures/skips,exit0:
  `/private/tmp/stocksage-m9-dated-fx-broad-ios-20260907-0059.xcresult`.
  Same explicit opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Five new test
  functions, all build handles finished. Existing unused optimizer `lo` warning
  remains unrelated. Bundle suffixes are identifiers; xcresult records run times.

Scope limits:72h is a planning tolerance, NOT a verified broker FX quote. Legacy
journal-heat/valuation panels still need per-panel incomplete/stale disclosure
before becoming account-risk authority. MarketsRiskAllocationSection is preview-
only; its duplicate resolver was not changed or newly wired. No live provider,
populated new-build UI, model or broker-execution verification is claimed.

Owner00:59 added an explicit ALL-API acceptance requirement. The takeover plan
now tracks this independently of unit gates: real authenticated responses,
correct parsing/provenance and app behavior for every active route. Inventory
is in progress; existing credential-guard and missing Derayah-contract blockers
remain. No key access retry/bypass, local model load or real order was attempted.

Next: complete reachable API inventory and safe live checks, then M8 one coherent
quantity/minimum-fee-aware cost result for gate/EV/export before P5 tickets.
All work inline on wt/coverage; owner app/main worktree/credentials untouched.
No push.15-minute original-task heartbeat read back ACTIVE; good-spender OFF.

## P5 prerequisite / M9 missing-FX sizing checkpoint — 2026-09-07 00:37 +03

The shared sizer now represents USD explicitly as1 and missing/invalid foreign FX
as nil. Native stop-risk/notional units and pence conversion are retained. Finite
inputs that overflow derived notional/risk/account-percent no longer return an
unrenderable size. The view's duplicated plain-size fallback is removed, and its
direct/inverse FX resolver rejects non-finite/underflowed/overflowed conversions.

Snapshot, single Today plan and detail gate block missing FX. Ranked plans inherit
the block; Copy all now includes the failed-check reason, matching the rendered
and VoiceOver row. Detail sizing/copy and weekly-dollar qualifiers explain why
no size exists rather than pretending only account input or one-share flooring
is at fault. No return forecast or research edge was changed.

The allocator excludes missing-FX candidates BEFORE weighting/correlation/heat
allocation, reports sorted unpricedSymbols, and carries those omissions into the
visible and copied plan. It does not mislabel them as below the one-share minimum.
Retained (currently unwired) suggestAdd and optimizer helpers now use the same
currency-aware sizer. suggestAdd's existing symbol-less openTrades inputs must be
USD-normalized by callers; returned candidate amounts remain raw-native.

Regression evidence: the synthetic USD10,000 /1% /EUR100 entry /EUR90 stop case
returned10 shares without FX, although the supplied EURUSD2 fixture correctly
returns5. The shared-path regression additionally checks snapshot, single and
ranked exports, allocation, marginal sizing and the weekly-dollar warning.
Old tests explicitly pinning missing-SAR=USD were corrected to the reviewed
contract, not deleted. USD identity, actual SAR, pence, unknown suffix, FX quote
legs, invalid rates, minor-unit underflow and derived overflow remain covered.

Executed results (xcresulttool counts; serialized, no live provider requests):
- First narrow method selector executed ZERO tests despite exit0; discarded as
  evidence. `/private/tmp/stocksage-m9-fx-red-20260907-0024.xcresult`.
- Red full sizer suite:17 executed,16 passed/1 failed,exit65. The failing witness
  is the ten-share missing-FX fallback.
  `/private/tmp/stocksage-m9-fx-red-20260907-0026.xcresult`.
- Focused8 suites:212/212,0 failures/skips,exit0.
  `/private/tmp/stocksage-m9-fx-focused-20260907-0031.xcresult`.
- First broad macOS:1733/1733,exit0, before final Copy-all reason parity.
  `/private/tmp/stocksage-m9-fx-broad-macos-20260907-0031.xcresult`.
- FINAL broad macOS:1733/1733,0 selected failures/skips,exit0.
  `/private/tmp/stocksage-m9-fx-broad-macos-20260907-0034.xcresult`.
- FINAL iPhone17Pro(gate),iOS26.5:1731/1731,0 selected failures/skips,exit0.
  `/private/tmp/stocksage-m9-fx-broad-ios-20260907-0035.xcresult`.
  Same3 explicit opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests and StrategyBaselineMeasurementTests.
  All build handles finished; no compiler remains.4 new test functions overall.

M9 is NOT fully closed: infraFX still strips market timestamps, and the view's
age resolver is detached from the selected rate. Next fix keeps price/time paired
and withholds stale/undated/future/sample rates for NEW sizing; historical
portfolio valuation needs an explicit old/unknown-rate label instead. Numeric
validity is not freshness. Existing symbol-to-currency heuristics are not a
verified broker instrument contract. M8 sized-minimum-fee parity, P5 tickets,
actual Derayah integration and populated UI/provider smoke remain pending.

Work stayed inline on wt/coverage; owner app/main-worktree/credentials/model were
not touched, no new persistent services/workers/real trades, no push. The15-minute
original-task heartbeat was read back ACTIVE. Good-spender remains OFF. Xcode's
GUI rejection is recorded in the prior checkpoint; its command-line gates work.

## Pipeline 4 M6 company-event checkpoint — 2026-09-07 00:15 +03

Five Massive feeds now supply dated catalyst observations: Benzinga ratings and
guidance,SEC8-K,dividends and non-derivative Form4 P/S transactions. The new
provider/parser, versioned disk cache, native full-refresh/symbol-union task,
engine priority, card/calendar copy, source links and per-feed coverage are wired.
No trade decision/target/EV/ranking input was changed. Known/estimated urgent
earnings and urgent history projections precede the new reported events; the
other precedence/window details are in COVERAGE_DESIGN's M6 contract.

Unknown/malformed/partial/entitlement failures do not become checked-empty.
Successful daily records expire at UTC rollover; unavailable retries15min,
401/402/403 feed gates24h. Four-wide paced requests, one probe per due feed,
no new timer/dependency/socket. Atomic bounded cache survives relaunch and exposes
save failures; cancellation/generation guards prevent obsolete publication.
Guidance uses paired bounds (raised/lowered/equal/mixed/unknown), not a midpoint
guess or missing→withdrawn inference. Analyst targets retain their own basis and
opinion label. Form4 preserves transaction/filing dates, amendment/10b5-1 status,
and purchase-vs-private ambiguity. These are issuer-ticker-attributed records,
not a verified mapping to a particular share class or an aggregate insider book.
Past company reports go to Recently reported, not Today. SEC/Benzinga links are
HTTPS/host-validated; calendar VoiceOver includes provenance and caveats.
Changed brief facts suppress stale cached AI explanations; source caveats and
untrusted-text labels reach the optional narrator. No model was loaded or called.

Executed checks (serialized; xcresulttool counts, not log estimates):
- Red:1 test executed/failed,0 passed. Urgent projected earnings incorrectly
  followed volume. `/private/tmp/stocksage-m6-red-20260907-0003.xcresult` (exit65).
- First implementation compile failed, no tests executed: optional Item equality
  inherited MainActor conformance. Replaced nil equality with guard pattern matching.
  `/private/tmp/stocksage-m6-focus-20260907-0005.xcresult` (exit65).
- Focused:92/92,0 failures/skips,exit0.
  `/private/tmp/stocksage-m6-focus-20260907-0010.xcresult`.
- Final broad macOS:1729/1729,0 selected failures/skips,exit0.
  `/private/tmp/stocksage-m6-broad-macos-20260907-0011.xcresult`.
- Final broad iPhone17Pro(gate),iOS26.5:1727/1727,0 selected failures/skips,exit0.
  `/private/tmp/stocksage-m6-broad-ios-20260907-0012.xcresult`.
  Canonical broad exclusions remain CalibrationPersistRunTests,
  LiveUniverseVerificationTests and StrategyBaselineMeasurementTests (opt-in).
  Both build handles completed. All5 new SF Symbols also resolve via NSImage on
  macOS; this is an icon check, not a full populated UI inspection.

15 new tests include real contract keys, header-only auth, all5 copy/priority
pins,7/8d and14/15d and30/31d boundaries, numeric/partial failures, Form4 filtering,
source links, cache roundtrip/corrupt provenance, and changed narrator facts.
The new exhaustive grid covers3^5 feed states ×7 earnings states ×2 volume states
=3402 combinations; the independent157500-case legacy grid remains intact.
These are separate exhaustive domains, not a claimed Cartesian cross-product of
every old/new axis. No fixture test makes a network/key/Store.shared call.

Live entitlements/payloads and full populated UI remain unverified; the old
credential-access guard has no confirmed new state and was not bypassed/retried.
Owner requested Xcode GUI at00:04: normal app launch, explicit bundle launch and
native-app opening all failed; macOS reports kLSIncompatibleApplicationVersionErr
(-10664). Selected Xcode26.6 command-line builds still work on macOS27.0. No
installation/security changes were made. Existing owner app/binary/main-worktree
changes remain untouched. All work inline; good-spender OFF; no push or trades.
Next: P5 order core/tickets
against the approved V3 design, NOT the old script's silent rounding, guessed
broker schemas/scopes or permanent manual-only/Sahm restriction.

## Pipeline 4 M5b split-comparison checkpoint — 2026-09-06 23:29 +03

Open journal comparisons now require a complete dated Massive split check, then
rebase a disposable copy's entry/stop/target/shares together. Both urgent actions
and row P&L/R use that copy; original serialized journal, recorded fills, realized
accounting and calibration are unchanged. The source and multiplier appear in
the row and its explicit VoiceOver label. Two positions in one symbol now have
distinct action IDs. Invalid prices/terms cannot produce actions, nonfinite R
is withheld, and a crossed stop no longer falsely claims a realized loss.

Current `/stocks/v1/splits` API and execution-day semantics were checked against
Massive docs and its official Python SDK. New York execution-day entries are
already post-split, including premarket; only strictly later events apply.
Old/undated/future/pre-entry prices or marks predating an executed split withhold
comparisons. Shared equity freshness tolerance remains48h. Failure, partial or
ambiguous results remain unverified, not a negative corporate-action observation.
Ratio overflow, invalid dates, symbol mismatch and conflicting duplicates fail closed.

Only open covered US symbols are fetched, serially; native task cancellation and
generation guards reject obsolete sweeps. In-memory daily answers cover the
earliest open entry through today and expire at NY rollover or24h. No new timer,
dependency or owner-disk writes. Transient retry floor60s;401/402/403 gate24h.
One complete page/100-event ceiling; pagination withholds rather than truncates.
Full contract/budget and source links: COVERAGE_DESIGN's M5b section.

Closing limitation is explicit: never prefill a feed price unless verified
factor=1. A known non-unit split disables confirmation and preview in the old
close editor, pending explicit broker-basis reconciliation. Unknown-basis manual
closing remains available with an original-units warning and no quote prefill.
This is NOT split-aware realized accounting, cash-in-lieu handling, or support
for mergers/spinoffs/non-US corporate actions. Do not silently rewrite entries.

Verification (serialized builds; counts independently read with xcresulttool):
- Red:54 executed,52 passed/2 failed, exit65; invalid marks produced actions and
  the stop text claimed realization. `/private/tmp/stocksage-m5b-red-20260906-2315.xcresult`.
- First implementation build exit65 before tests: refresh-key Equatable inherited
  TradeRecord's main-actor isolation but was declared nonisolated. Removed that
  unnecessary isolation override; no changes to TradeRecord's conformance.
  `/private/tmp/stocksage-m5b-focus-20260906-2323.xcresult`.
- Focused:64/64, zero failures/skips, exit0.
  `/private/tmp/stocksage-m5b-focus-20260906-2325.xcresult`.
- Broad macOS:1714/1714, zero selected failures/skips, exit0.
  `/private/tmp/stocksage-m5b-broad-macos-20260906-2325.xcresult`.
- Broad iPhone17Pro(gate), iOS26.5:1712/1712, zero selected failures/skips,
  exit0. `/private/tmp/stocksage-m5b-broad-ios-20260906-2326.xcresult`.
  Same three explicit opt-in exclusions:CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests.

Hand-derived checks cover4:1,1:10, shorts, unchanged no-split math, multiple events,
NY same-day/premarket/UTC straddles, stale/missing marks, daily cache boundaries,
malformed/paginated data, overflow, header authentication, closing prefill gates
and byte-identical original record encoding. No network/key/Store.shared access
in these tests. Both platform handles completed; only docs changed afterward.

Live provider smoke and populated-screen/VoiceOver QA are still unverified; the
credential guard has no confirmed new state, so it was not retried/bypassed.
Owner app PID11897 and main worktree's unrelated files remain intact. No push,
orders, model load or new workers. Good-spender OFF per owner23:12 request.
Next M6: five endpoint contracts checked during the iPhone build; important
field-name/withdrawal corrections are in PIPELINE_TAKEOVER. No M6 code yet.

## Pipeline 4 M5 source-provenance checkpoint — 2026-09-06 23:03 +03

Prices now carry their actual parser/stream origin: Massive SIP, Massive daily
bars, Yahoo, Yahoo bars, dormant EODHD, or explicit sample. Optional metadata
survives accepted board/idea updates, off-board price retention, stream buffering,
history slicing and both cache round-trips. Older cache entries decode with
unknown origin; no owner cache/journal was migrated or rewritten by this work.
A newer unknown-source observation clears the old source, while stale/equal-time
unsequenced quotes cannot relabel an accepted price. Ordering rules, analysis
timestamps, stop/target levels and monetary calculations are unchanged.

Card price captions, signal rows and their explicit VoiceOver labels use actual
source plus market age. Global sample/cache precedence remains; cached known
sources stay visible. Future/nonfinite market times never read "just now".
The header/banner identify the SAME closeable-first observation (mixed providers
on an equal-time tie), not all901 names as live. Old intraday prices are called
last observed quotes, not incorrectly asserted to be the session close.

Shared macOS/iOS settings explain automatic Massive→Yahoo routing, delayed
fallback, local key storage/authenticated transmission, and the snapshot-only
scope of Test connection. No provider picker, credential-access workaround,
new networking/timer/dependency, purchase, risk-setting or model change.
EODHD quote retirement stays intact; residual news/calendar dependencies remain.

Code-derived budgets are corrected in COVERAGE_DESIGN:250-ticker snapshot chunks,
20-symbol rotating gap cap,30/60s foreground sleep with25s shared start floor,
900/1800s full sweeps plus separate monitor/manual/heal/FX/history traffic. The
old flat60calls/hour and one872-ticker request are not actual implementation.
An all872-name stream outage takes44 gap sweeps (~22min at ideal30s cadence plus
work time), not every name every30s. No rate/entitlement claim from live usage.

Verification (serialized builds; xcresulttool independently checks executed tests):
- Regression red:8 executed,6 passed/2 failed, exit65. Old formatter called an
  unknown-source observation Yahoo and a future observation "just now".
  `/private/tmp/stocksage-m5-red-20260906-2242.xcresult`.
- Focused implementation:75/75, zero failures/skips, exit0.
  `/private/tmp/stocksage-m5-focused-20260906-2255.xcresult`.
- Broad macOS:1702/1702, zero selected failures/skips, exit0.
  `/private/tmp/stocksage-m5-broad-macos-20260906-2258.xcresult`.
- Broad iPhone17Pro(gate), iOS26.5:1700/1700, zero selected failures/skips,
  exit0. Both platform build handles completed; no compiler remains.
  `/private/tmp/stocksage-m5-broad-ios-20260906-2300.xcresult`.
  Same three canonical opt-in exclusions:CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests.

The seven new pure tests cover provider parsing, accepted/rejected merge metadata,
scan retention, old/new quote/history cache reconstruction, real buildIdeas
publication and age/header text. They do not instantiate Store.shared or access
credentials, disk caches or network. Existing age tests now explicitly supply
Yahoo; expected minute/hour/day arithmetic is unchanged.

Live endpoint smoke and full populated-screen/VoiceOver interaction QA remain
unverified (see M4 credential-guard record). Owner app PID11897 and main worktree's
unrelated project.pbxproj/AGENTS/review files are preserved. The original-task
15-minute heartbeat is confirmed ACTIVE; no new tasks, push or actual trades.
Next:M5b split-basis guard. Both urgentActs and journalOpenRow call the shared
StockSageJournal.openActions; row P&L/R also compares against raw logged levels.
Use verified corporate-action evidence, not a price-jump heuristic; never rewrite
the owner's journal. Existing caution text is not a substitute for the guard.

## Pipeline 4 M4 news checkpoint — 2026-09-06 22:27 +03

Explain now requests Massive `/v2/reference/news` first, with the existing EODHD
news path as fallback only when no usable primary items are available. One
request per Explain, at most five articles within the preceding seven days,
newest first; at most one EODHD fallback request. No new timer, subscription,
pagination, dependency, model invocation trigger, or trading/ranking input.
The documented feed updates hourly, not live. An empty selection is never a
complete "no news" finding. Existing EODHD fallback budget:10 API credits/request.

Article ticker membership is required. Sentiment/reasoning must match the requested
ticker and a documented positive/negative/neutral label; missing/unknown/conflicting
insights are omitted. Provider/publisher, title, bounded excerpt, date and safe
link survive the actual NewsItem→CitedSource→prompt/UI path. Sentiment occupies
a second line under the SAME citation number, labelled provider commentary in
the UI. Both narrator backends retain the unchanged number/citation checks;
these are NOT semantic truth or predictive-edge checks. External source prose
is explicitly untrusted data, not instructions. No profitability claim.

Shared news boundary rejects future dates, invalid limits/windows and unsafe
links (non-HTTPS, userinfo, or URLs over2048 bytes). Titles/publishers/excerpts/
reasoning have whole-word budgets, avoiding truncated numeric tokens. Results
are deduplicated before limiting. Missing Massive status is allowed by its
optional schema; present non-OK/wrong-type status or malformed envelopes fall
through. HTTP200, external-access and cancellation checks surround requests;
redirects are disabled and Massive auth stays in the header. No secrets logged.

The source list now exposes publisher, excerpt and sentiment, even when narration
is withheld/unavailable. Prompt and UI share a POSIX/Gregorian UTC date formatter.
Native Link semantics remain; an explicit plain SwiftUI label fixed ImageRenderer's
unsupported native-link placeholder. The final actual component render at320pt
was inspected: `/private/tmp/stocksage-news-sources-320.png`. Synthetic component
QA only, not full populated-app, live-model or VoiceOver interaction verification.

Verified references:
- https://massive.com/docs/rest/stocks/news
- https://raw.githubusercontent.com/massive-com/client-python/master/massive/rest/reference.py
  (`list_ticker_news`: published_utc range modifiers and endpoint)

Verification (serialized xcodebuild; xcresulttool independently checked counts):
- Regression red:15 executed,12 passed/3 failed, exit65. Future date, unsafe link,
  unbounded snippet tests caught real existing defects.
  `/private/tmp/stocksage-m4-red-20260906-2156.xcresult`.
- First implementation build: nested Swift Testing #require macro in the render
  fixture failed compilation; no tests executed. Corrected before all passes.
  `/private/tmp/stocksage-m4-focused-20260906-2210.xcresult`.
- Focused:56/56 passed both before and after render/URL-budget hardening.
  `/private/tmp/stocksage-m4-focused-retry-20260906-2211.xcresult` and
  `/private/tmp/stocksage-m4-render-20260906-2223.xcresult`.
- Final macOS:1693/1693, zero selected failures/skips.
  `/private/tmp/stocksage-m4-broad-macos-20260906-2225.xcresult`.
- Final iPhone17Pro(gate), iOS26.5:1691/1691, zero selected failures/skips.
  `/private/tmp/stocksage-m4-broad-ios-20260906-2227.xcresult`.
  Same three canonical exclusions:CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests.

Live verification was NOT run. Owner authorized a credential retry at22:03;
PreToolUse denied the explicit presence-only check again. At22:09 the owner
removed the file-guard entry: hooks.json remained valid, but the active tool
guard still rejected access. The assistant changed no security configuration,
read no key, and attempted no alternate access path. Reopening the task/file
did not verify a guard reload. Do not infer key absence or entitlement failure.

Owner's running app PID11897/binary and main worktree's unrelated pbxproj/review
artifacts were preserved. No push, real trade, model load or new worker.
Next concrete stage: M5 quote provenance. `MarketsView.sourceTagLabel` still
hardcodes Yahoo and LiveQuote/StockSageQuote/StockSageIdea/history/cache do not
carry provider metadata. Fix that through accepted observations, not by guessing
from a configured key. Keep the approved Massive→Yahoo route; do not resurrect
the old script's EODHD picker or claim the residual EODHD dependencies are gone.

## Pipeline 4 M3 earnings checkpoint — 2026-09-06 21:46 +03

`StockSageMassiveEarnings` now precedes EODHD calendar → Yahoo → history projection
in the existing per-symbol chain. It uses the documented `/benzinga/v1/earnings`
with ticker, date.gte/date.lte, date.asc and a100-row cap over400 days. Dates use
UTC calendar-day precision (including today until midnight), not an invented
release time. Only date_status sets confirmation: confirmed=true, projected=false.
A provider estimate is still a calendar observation with the existing estimated
suffix; it is NOT the app's distinct history-derived .projected record.

Malformed envelopes/rows/statuses/dates, mismatched symbols and partial pages are
unavailable, not checked-empty. Empty valid responses remain answered(nil).
Conflicting statuses on duplicate same-day rows cannot upgrade confirmation.
One status-only probe precedes a US earnings sweep;401/402/403 from either that
probe or a later query suppress this provider for24h, persisted locally. Other
failures do not claim an entitlement rejection. Header-only auth, redirects
disabled, external-access/cancellation gates checked before and after requests.
Existing per-symbol24h answer TTL, fallback order and four-wide sweep remain.

The catalyst card now receives the actual chain source instead of hardcoding
Yahoo. Its general caveat also names the attributed calendar provider. Unknown
provenance is explicit in the real view. No new model inference or order path.

Verified references:
- https://massive.com/docs/rest/partners/benzinga/earnings
- https://raw.githubusercontent.com/massive-com/client-python/master/massive/rest/benzinga.py
  (list_benzinga_earnings: date range modifiers and endpoint)

Verification, serialized canonical xcodebuild tests:
- Initial red build: missing provider/chain/input interfaces, exit65; NO tests
  executed. `/private/tmp/stocksage-m3-red-20260906-2139.xcresult`.
- First implementation build: three Swift Testing nested-try fixture errors,
  exit65; NO tests executed. Fixed before all following passes.
- Focused **103/103**, zero failures/skips:
  `/private/tmp/stocksage-m3-focused-retry-20260906-2141.xcresult`.
  One additional empty/stale-first-source fallback test added afterward.
- Final broad macOS **1,681/1,681**, zero failures/skips among selected tests:
  `/private/tmp/stocksage-m3-broad-macos-20260906-2144.xcresult`.
- Final broad iPhone17Pro(gate), iOS26.5 **1,680/1,680**, zero failures/skips
  among selected tests: `/private/tmp/stocksage-m3-broad-ios-20260906-2145.xcresult`.
- Same three opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Counts checked
  with xcresulttool. Existing unrelated compiler warnings remain. All handles done.

M2b live smoke remains pending: the credential-access hook blocked even a
key-presence check at21:32. No key was read; no guard was bypassed. This is NOT
evidence of a missing key or rejected Massive entitlement. No live probe was run.
Full populated app/VoiceOver QA is also pending; the owner app/binary was not
replaced or relaunched. No model job, real order, push or main project.pbxproj edit.
Next independent stage: M4 news/insights and cited narration, then remaining
M5/M5b/M6/P5/Chat/Derayah work and final integration. M3 is code/test-complete,
not live-verified. Current request budget supersedes the earlier one-call/day
proposal: see the implementation note in COVERAGE_DESIGN_2026-09-06.md.

## Pipeline 4 M2b compact-card checkpoint — 2026-09-06 21:29 +03

US idea cards now show the existing coalesced bid/ask observation: prices, share
sizes, Massive SIP attribution, absolute SIP time, bid/ask venues and observed
spread. The SAME copy is included in the card's overriding VoiceOver label.
Unknown venue IDs remain explicitly unknown until the shared exchange reference
resolves; reference loading reuses the stream's existing startup task and the
24-hour reference cache. No per-card request, socket or timer was added.

The strip deliberately says "last observed, not a fill quote", not "Live". It
does not claim a displayed historical spread is cost-eligible. Existing money
callers still use spreadBps(at:), with five-second freshness and condition
qualification unchanged. One-sided, locked/crossed, zero-size and invalid-number
books do not display a computed spread; a missing book says costs are estimated.
Tadawul cards are unchanged.

Verification (serialized xcodebuild, independently read xcresulttool summaries):
- Focused macOS: **11/11**, zero failures/skips, before the venue-label addition:
  `/private/tmp/stocksage-nbbo-compact-focused-20260906-2120.xcresult`.
- Final broad macOS: **1,672/1,672**, zero failures/skips among selected tests:
  `/private/tmp/stocksage-nbbo-compact-broad-macos-20260906-2124.xcresult`.
- Final broad iPhone17Pro(gate), iOS26.5: **1,671/1,671**, zero failures/skips
  among selected tests:
  `/private/tmp/stocksage-nbbo-compact-broad-ios-20260906-2127.xcresult`.
- Same explicit opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. The extra Mac
  test renders the actual compact component at320pt via ImageRenderer. Inspected
  `/private/tmp/stocksage-nbbo-compact-320.png`: all four lines visible. This is
  component-only QA with synthetic data, NOT full populated app/VoiceOver QA.

All build handles completed. git diff --check is clean. No live authenticated
smoke, real order, model job, push or change to the owner's running app binary.
M2b's remaining verification is populated UI and authenticated provider smoke;
then M3–M6, P5, approved Chat/Derayah work and final integration. Main
project.pbxproj and its unrelated work remain untouched.

Owner asked why the goal looks stalled at21:27. The product goal record is still
marked blocked from earlier, but the separate overnight heartbeat was verified
ACTIVE/every15minutes in this task. That stale goal status does not describe this
implementation checkpoint. Available goal tools cannot resume/reset that status;
do not falsely mark the whole objective complete to remove the badge.

## Pipeline 4 M2b trade-ordering checkpoint — 2026-09-06 21:13 +03

Same-millisecond trades now retain Massive's exact64-bit `q` through the parser,
authenticated StreamState,500ms Store buffer, board/idea merge, scan publication
and quote-cache round trip. Only a strictly larger known T-channel sequence for
the same symbol can break a timestamp tie. Quotes keep their independent Q
sequence. Later timestamps win even when sequence resets; unsequenced later
polls clear old metadata, and legacy caches decode to unknown. No sequence is
invented from a timestamp, price, provider arrival order or another channel.
Stop/target, advice and analysis time remain unchanged by live-price replacement.

The shared ingress also fixes a second regression: taking max(boardTime,ideaTime)
let a corrupt future value mask a valid clock, allowing an older price to replace
both. Each existing observation is now checked independently before accepting a
tick/merge. Quote symbols must match their dictionary keys. Existing undated and
future-time fail-closed rules remain; unknown equal-time provenance stays blocked.
Protocol: https://massive.com/docs/websocket/stocks/trades (`t` milliseconds;
`q` increasing, per-ticker, gaps permitted). This is last-trade ordering, not a
new trade-condition/execution-eligibility policy.

Verification, serialized canonical xcodebuild tests:
- Red: both new regression tests failed against the old code, exit65,
  `/private/tmp/stocksage-sequence-red-20260906-2104.xcresult`.
- The first expanded attempt failed compilation on a test tuple inferred as
  Int rather than Int64 and executed no tests; explicit fixture typing fixed it.
- Focused **42/42**, zero failures/skips:
  `/private/tmp/stocksage-sequence-focused-retry-20260906-2107.xcresult`.
- Broad macOS **1,670/1,670**, zero failures/skips among selected tests:
  `/private/tmp/stocksage-sequence-broad-macos-20260906-2109.xcresult`.
- Broad iPhone17Pro(gate), iOS26.5 **1,670/1,670**, zero failures/skips among
  selected tests: `/private/tmp/stocksage-sequence-broad-ios-20260906-2110.xcresult`.
- Same explicit opt-in exclusions: CalibrationPersistRunTests,
  LiveUniverseVerificationTests, StrategyBaselineMeasurementTests. Counts were
  independently read with xcresulttool; no live provider success is implied.
  Existing compiler warnings in allocation/EV and Massive timestamp fixtures remain.

All build handles completed. No live smoke, new-branch populated visual QA,
actual order, model job, push or change to the owner's running app binary.
M2b still needs compact cards and visual/authenticated smoke, followed by M3–M6,
P5, approved Chat/Derayah work and integration. Main project.pbxproj stays untouched.
The owner's ORCL question was answered from their existing running app: no idea
or directory match, with action=All and Any signal strength. This was observation
of the OLD app, not new-branch QA. The baked universe membership restriction in
StockSageQuoteService excludes ORCL; no universe policy was changed or scan run.

## Pipeline 4 M2b measured-cost checkpoint — 2026-09-06 20:43 +03

Current EV/ranking, allocator cost gates, decision snapshots, Today plan and
Markets card/detail/copy/ledger paths now select costs from the SAME idea NBBO.
Qualified fresh US spreads can only raise the existing8bps spread floor. The
full quoted width represents both half-spread crossings; slippage, fees and
per-order minimums are unchanged estimates. Historical backtests, paper candle
simulation and journal slippage benchmarks still use their original defaults.
The shared idea net-RR helper also includes short financing on cards, matching
the detail/ranking path that already included it.

Eligibility is deliberately narrow: one bounded, header-authenticated reference
request per stream start resolves Massive condition IDs from UTP `R` (regular
two-sided NBBO), with no guessed numeric ID. Only non-legacy, non-exchange-specific
stock quote conditions qualify, and only when no indicators are supplied.
Unknown/flagged/malformed metadata, incomplete/duplicate reference records,
reference failure, expired reference, stale/future/locked/crossed/one-sided quotes
all retain default costs. Indicator-bearing quotes remain visible, not cost
evidence, until their semantics are verified. This is NOT trading-halt detection
or execution authorization. Reference retry is on restart, not a polling loop.

The authenticated book propagates at500ms, with a shared one-second expiration
invalidation; money helpers check exact age (5s inclusive). Withdrawals, auth loss
and stop clear cost inputs. Scan and trade-price replacement preserve fresh NBBO
without changing the analysis time. Detail/copy actions re-resolve the store,
so a selected sheet's older value cannot retain a withdrawn cost quote.

References:
- https://massive.com/docs/rest/stocks/market-operations/condition-codes
- https://massive.com/docs/websocket/stocks/quotes
- https://www.utpplan.com/DOC/uqdfspecification.pdf (section7.5.2.2)

Verification:50/50 focused macOS tests, then canonical broad tests **1,664/1,664
passed on EACH platform**, zero failures/skips among selected tests. Explicit
exclusions remain CalibrationPersistRunTests, LiveUniverseVerificationTests and
StrategyBaselineMeasurementTests (opt-in network/measurement). Result bundles:
- `/private/tmp/stocksage-m2b-cost-macos-20260906-2040.xcresult` (focused)
- `/private/tmp/stocksage-m2b-cost-broad-macos-20260906-2038.xcresult`
- `/private/tmp/stocksage-m2b-cost-broad-ios-20260906-2040.xcresult`

All run handles completed; no compiler remains. Existing warnings in allocation
optimizer/EV tests remain. No live provider smoke, populated visual QA, real order,
model load/conversion or push. **M2b overall remains incomplete:** compact cards,
same-time trade sequence through Store, visual QA and authenticated smoke remain.

## Pipeline 4 M2b data/UI checkpoint — 2026-09-06 20:18 +03

The existing Massive connection now subscribes to `Q.` alongside `T.`. Quote
and trade freshness remain independent, with500ms quote publication. The detail
sheet shows bid/ask prices, share sizes, venue attribution and SIP time. Spread
is withheld when older than5s, future-dated, locked, crossed or one-sided.
Distinct same-time QUOTES use exact64-bit per-symbol sequence ordering; the
separate same-time TRADE-to-Store sequence change remains pending.

The on-demand Tape sheet reads `/v3/trades` and `/v3/quotes`, pinned to one symbol
and a seven-day window, capped at3pages ×100rows per channel. Partial results,
invalid rows, entitlement errors and invalid/repeated cursors stay visible.
Bearer authorization is header-only; pagination rejects other hosts/paths/ports,
userinfo, fragments and API-key queries, and redirects are disabled.
The exchange reference is cached24h in process; Nasdaq filtering uses `mic=XNAS`,
never a guessed numeric ID or tape-C listing. Filtered quote sides are not NBBO.

Shared numeric decoding now rejects JSON booleans and fractional/overflowing
integer metadata, retaining exact integer spelling before a Double fallback.

Verification: canonical `xcodebuild test`, parallel testing disabled, **1,660
passed on macOS and1,660 on iPhone 17 Pro (gate)/iOS26.5**, zero failures/skips
among selected tests. The same three opt-in network/measurement suites listed
under M2 were explicitly excluded. Result bundles:

- `/private/tmp/stocksage-m2b-broad-macos-20260906-2014.xcresult`
- `/private/tmp/stocksage-m2b-broad-ios-20260906-2016.xcresult`

**M2b is not complete:** the panel explicitly states ranking/tickets still use
estimated costs. Next: measured spread through every ranking/gate/export caller,
conservative cost floors and quote-condition eligibility, compact card display,
trade sequence propagation, populated visual QA and authenticated endpoint smoke.
No live provider call, actual order, model load or push was performed by this gate.
Continue the remaining checklist in `agent-docs/PIPELINE_TAKEOVER_2026-09-06.md`.

## Pipeline 4 M2 — 2026-09-06 20:00 +03, Codex single-session takeover

Owner stopped the separate pipeline task; its uncommitted M2 changes were
preserved and completed on `wt/coverage`. Massive replaces the active EODHD
stream/quote route; Yahoo remains the fallback. The stream consumes every event
in a batch, preserves authorization across informational statuses, handles send
failures, and cancels stale connection callbacks/retries. Auth alone does not
prove delivery: per-symbol coverage expires 45 seconds after the last accepted
trade. Status publication changes only on transitions, with a one-second expiry
timer; Store price writes retain their 500 ms coalescing.

All quote ingress paths now share ordering/validation: full refresh, targeted,
monitor/gap polls, stream flushes and scan publication cannot rewind a dated
price. Undated seeds remain unknown, corrupt future cache values can recover,
off-board ideas update without creating board rows, and row UUIDs survive polls.

Canonical `xcodebuild test`, separate result bundles, parallel testing disabled:

- macOS arm64: **1,649 passed, 0 failed**, bundle
  `/private/tmp/stocksage-m2-broad-macos-20260906-1956.xcresult`.
- iPhone 17 Pro (gate), iOS 26.5: **1,649 passed, 0 failed**, bundle
  `/private/tmp/stocksage-m2-broad-ios-20260906-1957.xcresult`.
- Both explicitly exclude `CalibrationPersistRunTests`,
  `LiveUniverseVerificationTests`, `StrategyBaselineMeasurementTests` (opt-in
  network/measurement jobs). Zero skips among selected tests; excluded suites
  are not claimed tested. Counts independently read with `xcresulttool`.
- One earlier expanded-test attempt failed compilation on a fixture typo and
  executed no tests; corrected before the focused and broad successful runs.

Not yet verified: live endpoint smoke, per-observation provenance UI, NBBO/tape,
same-millisecond sequence ordering, remaining M3–M6, pipeline 5, final integration.
Continue via `agent-docs/PIPELINE_TAKEOVER_2026-09-06.md`. No push or real order.

Written early under the good-spender `⚠ APPROACHING LIMIT` directive (projection only — this
session is the sole spend in the 7-day window; the EWMA is a read-burst artefact).

## Environment blocker — RESOLVED 09:44 +03 (licence accepted; `xcodebuild`, `/usr/bin/git`, Homebrew work again)
Until 09:44 +03 Xcode 26.6 (17F113) had an unaccepted licence, so `/usr/bin/git`, `xcodebuild`, `xcrun`
and `brew` all refused with "You have not agreed to the Xcode license agreements". Everything below
about "tests NOT run" refers to commits made before that. The iOS 26.5 simulator platform (~8 GB)
was still downloading at 09:49 +03 (owner-approved) — the iOS `xcodebuild test` leg is pending it.

Workarounds used while it was blocked (kept — they are fast gates in their own right):
- git: call `/Applications/Xcode.app/Contents/Developer/usr/bin/git` directly.
- compile gate: `swiftc -typecheck` on `StockSage/Sources/**` for BOTH platforms — script at the
  session scratchpad `tc_stocksage.sh macos|ios` (flags mirror the pbxproj: Swift 6, MainActor
  default isolation, MemberImportVisibility, 26.5 targets). Baseline at 02ab1a0: clean on both,
  ~40 s each. Superseded the same day by `tools/gate.sh` (emit-module, both platforms + test-target
  type-check) and **`tools/runtests.sh`, which EXECUTES the whole Swift Testing suite without xcodebuild**
  (swiftc-built testable dylib + Testing.framework runner, throwaway HOME). `xcodebuild … test` itself
  still needs the licence; commits before 09:30 +03 say "tests NOT run" because the runner did not exist yet.

## Repo state at handoff
- `main` = 02ab1a0, **16 commits ahead of origin/main, unpushed** (all iPhone UI work, Jul 28–29).
- Worktree `~/StockSage-uiwork` on `ios-colour-overhaul` at the same commit, clean.
- Work branch for this session: `review-followups-2026-09-06` (off 02ab1a0).
- Backlog source of truth: `agent-docs/REVIEW_2026-07-28_claude.md` (Part 6 staged plan; Part 3
  UI list). `agent-docs/IOS_REVIEW_2026-07-27.md` is fully FIXED — not a queue.

## Done this session (branch `review-followups-2026-09-06`, 3 commits, tree clean, NOT merged, NOT pushed)
- d21cec5 — review #2 "Open heat"→"Planned heat X% of Y% cap" (honesty-critical), #8 iPhone sheet
  detents + grabber (detail sheet .medium/.large, Settings + Browse .large), #10 Reduce-Motion gates on
  the LIVE pulse and refresh spinner, #17c dead `fontMicro` removed.
- 0aac115 — review #7 `.touchHitArea()` on 13 icon/text-only controls (hit shape only, no layout
  change); #9 21 hardcoded font literals → @ScaledMetric tokens in MarketsTodayActionsCard,
  ExecutionQualityPanel, MarketSessionClockView (byte-identical at default Dynamic Type).
- ba82689 — Q3 `defer { isRefreshing = false }` for the whole refresh cycle; Q6 `addSymbol` passes
  `marketTime`; Q7 `quoteAsOf` max-merge; C2 rebalance sort symbol tiebreak.
Every commit: swiftc -typecheck clean on BOTH platforms; tests NOT run (licence). Skipped on purpose:
the #7 stepper relocation to the bottom bar (structural), Q8 (must follow Q4), and every owner-decision item.

## Batch 2 — 2026-09-06 08:30 +03 (workflow wf_02b04e3a-62a: 16 items, 7 isolated worktrees, 29 agents, 76 min)
All 16 items landed and were cherry-picked onto this branch in dependency order (cache → store → stream →
eodhd → fixture → ui2 → ui), `tools/gate.sh all` green after EVERY group (emit-module macOS + iOS +
test-target type-check). Tests still NOT executed (licence). Each group had an adversarial two-lens review;
every blocker/major was fixed in a `fixup(...)` commit except one the fix pass correctly rejected (the
reviewer flagged Q8 landing before Q4 inside the ui worktree — the merge order lands Q4 first).

| Item | Commit(s) | Note |
|---|---|---|
| Q4 marketTime in quote cache Entry | d131554 | review: clean |
| Q1 heal sweep scoped + capped + backoff | 2be3bd2, a73444f | keeps existing `healBatchCap`/`marketIsTrading` gate (superset); pure `healCandidates` pinned by 6 tests |
| Q9 mirror sweep prices onto ideas | 988da1f, 3bf5994 | fixup: `mergeLiveQuote` no longer fabricates `asOf: Date()` — nil stays unknown |
| P3 O(1) `symbolIndex` | 91d32c3 | also rebuilt in addSymbol/removeSymbol (review omitted them) |
| Q5 stream auth classifier + watchdog | 084b16f, 98690dc | fixup: MarketsView now OBSERVES the stream so the LIVE dot redraws |
| Q10 EODHD parser parity | 22ab017, 1f49ccb | fixup: `parseRealTime([String: Any])` overload so the isFinite guard is testable |
| P2 fixture real spark + clique alloc | 299f009, 45f50bc, 9c79c8f, 80a109c | fixup: per-idea varied spark (a shared spark made a degenerate all-1.0 clique) |
| UI#5 fontCaveat / section header 15 | d25ad97 | 3 calibration labels re-pointed (review said 2) |
| UI#13 iOS watchlist remove + reason | 864129a | |
| UI#15 ideasHeader two tiers | b613ec0 | analysis-timestamp line left untouched (one ternary, always visible) |
| UI#16 minWidth fields + wrap | 4140e3a, 37ffd0d | fixup: 4 other widened-field rows also wrapped |
| UI#6 dangerSoft badges + text sweep | 02a95c3 | static `actionColorForTest` seams + guard test |
| UI#3 ViewThatFits metric rows | c591a18 | 5 rows split (idea card exact per review; 4 others minimal) |
| UI#4 `.explain()` shim | 93c6ede | ~13 honesty-bearing `.help` sites converted; sheet stop line not found by text |
| Q8 banner fail-closed | 774522d | shared `MarketsView.freshnessStale(asOf:now:)` |

Minor review findings left OPEN on purpose (small, do after tests can run): Q5 ping has no pong deadline and
`armWatchdog()` re-allocates per frame; Q1 evaluates `marketIsTrading` for every row before the scope filter;
Q1 backoff `before` lookup is a linear scan (could use `symbolIndex`); the same O(n) `currentPrice` scan
still exists in MarketsRiskAllocationSection (unwired file) and `fxRateAge`; `capTruncates` passes the cap
as a literal 40.

Also this session: `tools/gate.sh` (95b54e2) committed as the licence-blocked compile gate; Ollama 0.33.3 +
`qwen3.8` (27B) installed on this Mac for the new Catalysts tab's optional local explanation backend
(see the Catalysts section once it lands).

## wt/ui — 2026-09-06 09:20 +03 (worktree /Users/saleh/StockSage-wt/ui, branch wt/ui, base e619739) — restored 09:58, dropped by mistake at 09:50
Two commits, `tools/gate.sh all` green after each (macos=OK ios=OK tests=OK; tests type-checked, NOT
executed — licence). good-spender was turned ON for good mid-run (user directive, saved to memory).

| Commit | What |
|---|---|
| 648c425 (wt/ui 4cfa3f9) | fixup(UI#6): the 9 realized-stats + risk-analytics ideaMetric sites → dangerSoft via a new static seam `MarketsView.signedMetricColor(positive:positiveColor:)`, pinned by `SignedMetricColorTests` (BacktestVerdictColorTests.swift) |
| dd578ae (wt/ui 1d2637c) | fixup(UI#6): the remaining 17 small-text raw-danger sites (+2 mixed-helper consumers: `hc` heat text, healthColor verdict text) across MarketsView + MarketsRiskAllocationSection; 25 icon/fill/stroke/background sites keep raw danger. Sonnet diff review: APPROVE, 1 minor (watchlist arrow icon inherits dangerSoft with its text) |

Owner call, NOT changed: white text on a raw-danger FILL — STOP TRADING banner (~3316), "Confirm close"
button (~3631), "DO NOT TRADE" chips (~5877 and ~6998 → BestOpportunityActionCard:9881). Same 3.41:1
class UI#6 fixed on the sell badge, but these are stop/destructive surfaces where the red fill is the
convention — decide badge treatment (pastel fill + dark ink) vs keep.
RESOLVED 2026-09-06 09:35 +03 — owner approved; landed as 0897fea (badgeInk + gateChipColor seams, test-pinned, gate green).

Landed on review-followups-2026-09-06 as 648c425 + dd578ae (cherry-picked clean, gate re-run there —
see merge_gate.log). Licence accepted 2026-09-06 09:44 +03; canonical gate run at 09:47 +03: macOS build OK, macOS
test OK — 1,426 tests in 166 suites passed (Swift Testing, 14.2 s; first EXECUTED run since Jul 29).
iOS leg BLOCKED at first: Xcode 26.6 needs the iOS 26.5 simulator platform (the 27.0 beta runtime is
not an eligible destination); owner approved `xcodebuild -downloadPlatform iOS` (~8 GB) at 09:49 +03.
Next: iOS leg result (see merge_gate.log), then push. Spend (good-spender estimate): run closed at $28.27 vs $3.00 est (9.42x OVER — ~30 Fable-tier
classifier agents ran inside an ultracode workflow before it was stopped on the good-spender directive).

## Catalysts tab — NEW (owner request 2026-09-06, workflows wf_3c5d578a-629 + wf_41e9e30c-825; 10 commits cba3f92..d382cc0)
"A new tab that shows, for the same ideas as the Ideas tab, the key catalyst to watch and explains why" —
BOTH per-idea cards AND a date-ordered calendar; the why is engine rationale always, plus an OPTIONAL
model-written paragraph on tap (owner chose "both" / "both").

| Piece | File | Notes |
|---|---|---|
| Engine | `StockSage/Sources/StockSage/StockSageCatalystWatch.swift` | pure; precedence earnings(imminent/soon) → volume move → earnings(clear) → range extreme → risk-off regime (long ideas only) → reliable seasonality → none; every string lives here; UTC-fixed dates; past earnings (>24h) never shown |
| Narrator | `StockSageCatalystNarrator.swift` | routes over Apple FoundationModels (on-device) and the local server; facts list → ≤80 words, ticker-only, no new numbers; foreign-number guard withholds output; every paragraph labelled with its SOURCE + model |
| Local server client | `StockSageLocalModelServer.swift` | Ollama native `/api/chat` (think:false, num_ctx 4096) or OpenAI-compatible `/v1/chat/completions`; probe; backends auto / on-device only / local server only / off; loopback default; non-loopback WARNS FIRST (banner + per-card) |
| View | `StockSage/Sources/Views/CatalystsSection.swift` | header (mode picker, regime line, always-visible caveat, sample-data label, "Explanation model" settings), lazy cards, calendar buckets Today/Tomorrow/This week/Later/No date on file; earnings fetched for ≤30 shown ideas, ≤4 parallel; 8-K filings on tap (US) |
| Wiring | `MarketsView.swift` (d49a903) | `MarketSection.catalysts` between Ideas and All, icon calendar.badge.clock, `CatalystsSection(ideas: displayedIdeas, store: store) { selectedIdea = $0 }` — same projected board, same order |
| Tests | `StockSageCatalystWatchTests` (12), `…NarratorTests` (13), `…LocalModelServerTests` (9), `CatalystsSectionTests` (3), `…PropertyTests` (11, 52,500-combination oracle sweep) | all EXECUTED green via `tools/runtests.sh` |

Reviews: tab review found 2 blockers (past earnings shown as imminent; calendar dropped the RVOL "unvalidated"
caveat) + 2 majors (UTC vs local day; eager cards) — fixed f098044. Backend review found 2 blockers (LAN warning not
visible at the Explain action; label named the CURRENT model setting, not the generating one) + 1 major (auto
fallback untested) — fixed 39ec0d0/3410c82.

Local model on this Mac (owner "okay"): Ollama 0.33.3 standalone under `~/.local/opt/ollama`, LaunchAgent
`com.ollama.serve` on 127.0.0.1:11434 (keep-alive 24h), model `qwen3.8` (27B Q4_K_M, MTP speculative decoding on).
Measured: quiet Mac 15–53 tok/s ≈ 3–10 s per paragraph; with Swift compilers running 7–11 tok/s. MLX 4-bit + MTP
drafter via mlx-vlm was ~1.3× faster steady-state (3.7–6.3 s) — NOT made the default; venv at `~/.local/venvs/mlx`,
34 GB of A/B artefacts (Ollama tag `qwen3.8:27b-mlx`, HF cache) left on disk for the owner to delete or keep.

## EXECUTED test results
**Canonical `xcodebuild -scheme StockSage -destination 'platform=macOS' … test` on the tab branch (rebased onto
5c547f1), 2026-09-06 09:53 +03: `✔ Test run with 1476 tests in 171 suites passed after 26.920 seconds` — ** TEST
SUCCEEDED ** (n=1,476 executed, 0 failed).** iOS leg: pending the 26.5 simulator platform download (other session).

tools/runtests.sh (macOS arm64, 09:40 +03), before the licence was accepted:
`✔ Test run with 1474 tests in 170 suites passed after 29.967 seconds` on d382cc0's tree (n=1,474 executed, 0 failed).
Earlier the same runner passed 1,446/1,446 on d49a903 (batch 2 + tab wiring) and 33/33 on the catalyst suites.
Not executed: SwiftUI rendering (no simulator/app run), the Apple on-device model path (needs an Apple
Intelligence device), live Yahoo/SEC/Ollama network paths beyond the read-only Ollama probes.

Canonical gate on BOTH platforms at HEAD 5b3f2a4 (2026-09-06 10:01 +03, wt/ui session): macOS test
1,476/1,476 in 171 suites; iOS test 1,476/1,476 in 171 suites on an iPhone 17 Pro simulator (iOS 26.5
23F77, platform downloaded 09:49–09:54 +03, 8.52 GB). HEAD unchanged during the run. Not pushed.
Uncommitted `StockSage.xcodeproj/project.pbxproj` reorder (104+/91−, no semantic change) left for its owner.

## Next actions
1. Owner: `sudo xcodebuild -license accept`, then the canonical `xcodebuild … test` on macOS AND the iOS 27
   simulator (the runner covers macOS only; iOS is emit-module-checked). Open the app: Ideas → Catalysts tab,
   both modes; tap Explain with Apple Intelligence on; set Backend = Local server with Ollama running.
2. Merge `review-followups-2026-09-06` → `main` when green; push `main` (was 16 ahead before this branch).
3. Backlog: the minor review findings listed under Batch 2 above; remaining OPEN review items are the
   owner-decision ones (Q11, C1 wording, M1 retention, UI#11 iPad, UI#1 crown, F1 dead engines) + P2-memo
   (allocator memo, `StockSageStore` + `MarketsView` capitalAllocationCard), UI#3's remaining rows if any.
4. Decide on the MLX server as default (needs a launch agent; ~1–2 s faster per tap) and on deleting the 34 GB
   of A/B model files.
5. The background sweep session's work (`wt/ui`) is ALREADY on this branch (648c425, dd578ae, 0897fea —
   see the wt/ui section above); its worktree `~/StockSage-wt/ui` can be removed once it has run the
   iOS test leg and pushed.

## W4 — local-model retrieval-first internet access (2026-09-06, worktree cov-w4, branch wt/cov-w4)
Citable sources for the on-tap Catalyst "Explain" paragraph: EODHD news (`StockSageNewsService`,
new), the last 8-K (`StockSageDisclosureService`, existing), and insider Form 4 activity
(`StockSageInsider`, existing — now also gated by `ToolPolicy.isExternalAllowed`, closing the one
feed in this subsystem that hit the network unconditionally). `StockSageCatalystNarrator.facts(for:sources:)`
appends one numbered `[n] YYYY-MM-DD <source>: <title> — <snippet> (<link>)` line per source; the
model may cite `[n]` and both the existing number fence AND the new `citationsValid(_:sourceCount:)`
gate must pass before a response is shown as `.text` — otherwise `.withheld`. US/NASDAQ-only via
`StockSageEODHD.covers`, matching the sibling SAHMK/Tadawul task being cancelled (12:57 +03 scope
change) — nothing here touches Tadawul or `.SR` symbols.

**EODHD news cost**: `/api/news` is billed 5 API calls per request PLUS 5 more per ticker named in
the request — one call for one symbol therefore spends 10 calls against the 100k/day EODHD
allowance, separate from and in addition to the existing quote path's per-symbol cost.

**Privacy**: tapping "Explain" now also sends the symbol to eodhd.com (news) and sec.gov (8-K
filings, insider Form 4 trades) directly from the device, in addition to whichever narrator
backend (on-device Apple Intelligence or the local server) answers the paragraph. The Catalysts
tab header states this unconditionally, alongside the existing non-loopback warning.

Gate: `GATE repo=cov-w4 macos=OK ios=OK tests=OK`. Tests: filtered StockSageInsiderTests 10/10,
StockSageNewsService 12/12, StockSageCatalystNarratorTests 23/23; unfiltered suite 1,551/1,551
tests in 177 suites, 0 failed (tools/runtests.sh, EXECUTED, 65.3s). No network hit in any test —
all fixtures are hand-derived pure-parse inputs; `ToolPolicy.override` gating test uses the
pre-existing `ToolPolicyTestLock` seam.
