# StockSageX — deep review, 2026-07-28

Reviewed at `main` @ `18da262` ("Real-time price streaming over EODHD WebSocket"). 259 Swift files staged and read locally. Every line number below was re-opened in the actual file before it was written down.

---

# Part 0 — About the Gemini report

Read this before you act on anything in it.

**The Gemini report was written without the source code.** It never read a single Swift file. Its own trace log says so, in its own words:

> "my initial attempts to locate standalone codebase files indicate that the implementation details may be embedded directly within these primary documentation assets"

> "While the high-level design documents are now clear, there is an information gap regarding the exact location of the raw implementation files."

It searched your Google Drive and Gmail, found three prose documents (`StockSage UI Design Review`, `Quantitative Trading Engine Review`, `StockSageX — status report 2026-07-28`), and generated a code review from those plus web articles about `scenePhase`. Every `file.swift:line` citation in it is synthesised. Here is the verification, one claim at a time:

| Gemini's citation | What is actually there |
|---|---|
| `IdeaDetailSheet.swift:L120` — "sizing cascade as static text" | **This file does not exist.** `find . -name '*DetailSheet*'` returns nothing. The idea detail sheet lives inside `MarketsView.swift:7078–7890`. |
| `StockSageMonitor.swift:L45` — "unbounded concurrent polling loops" | Line 45 is a doc comment: `/// scans ONLY the watchlist (fetching just those quotes) instead of pulling the whole`. |
| `MarketsView.swift:L410` — "Signal Strength as a base-100 fraction" | Line 410 is `.task(id: store.lastUpdated) { await store.refreshCatalysts() }`. |
| `StockSageQuoteService.swift:L85` — "naive concurrent iteration over 600 symbols" | Line 85 is a comment inside `fetchOne`. **Chunking already exists** — `StockSageQuoteService.swift:65–72` and `:194–211` both do `stride(from:to:by:)` chunking with a `TaskGroup` per chunk and a pacing interval. Gemini's headline "critical" fix is a re-implementation of shipped code, minus the pacing. |
| `StockSageDeflatedSharpe.swift:L88` — "kurtosis convention mismatch" | The file is 94 lines; line 88 is inside `psrDsr`, not the denominator. And the claim is backwards — see below. |

Three of its proposals are things you have already shipped:

- **"Invert Signal Strength to 5 ordinal blocks."** Already done. `MarketsView.swift:8253`: *"Signal strength as 5 DISCRETE ordinal blocks — a categorical rules-based rating, deliberately…"*, with `ordinalStrengthLabel` / `ordinalStrengthLevel` at `:5422–5429` and pinned by `OrdinalStrengthTests.swift`.
- **"Bulk chunking for Yahoo polling."** Already done, see above.
- **"Base Currency Normalization (SAR peg)."** `StockSageCurrency.swift:106–145` already handles the SAR/USD read and the `.SR`→SAR suffix mapping; `refreshInfraFX()` fetches the live rate rather than hardcoding 3.75.

**One of its proposals is an actual regression.** On the Deflated Sharpe: `StockSageDeflatedSharpe.swift:39` documents the convention explicitly —

```swift
39:    /// Skewness + NON-excess kurtosis (normal = 3) of a sample. nil if < 4 points or zero variance.
50:        return (skew: m3 / (sd*sd*sd), kurtosis: m4 / (m2*m2))
59:        let denom = Swift.max(1e-12, 1 - skew*sr + ((kurtosis - 1)/4)*sr*sr).squareRoot()
```

`moments()` returns non-excess kurtosis, and `probabilisticSharpe` consumes it as `(kurtosis - 1)/4`. That is the standard Bailey/López de Prado PSR denominator for non-excess kurtosis: with a normal sample (γ₄ = 3) it evaluates to `(3-1)/4 = 0.5`, giving `√(1 + 0.5·SR²)`. Correct as written, and internally consistent.

Gemini proposes `(empiricalKurtosis - 3.0) / 4.0`, which for a normal sample gives **0**, removing the SR² term entirely and *inflating* PSR/DSR. Its own suggested verification ("must evaluate to exactly 0.0 for a normal distribution") is the bug, asserted as the acceptance test. Do not apply it.

Its `StockSageMonitor` rewrite would also not compile against your code: it replaces the `@MainActor final class` + `static let shared` singleton with an `@Observable` type that has no `shared`, breaking `StockSageApp.swift:61,68,85`, `MarketsView.swift:465,950,1219,1230,1242,1251`, and every test in `StockSageMonitorTests.swift`.

**What it got right, in substance if not in citation:** notifications need hysteresis, a per-symbol cooldown, a global cap, and a digest. That is a correct read of your prompt — you told it the answer in the question. It is Part 1 below, with the actual mechanism and code that compiles against your files.

**And one correction to your own hypothesis, before you spend the evening on it.** You wrote:

> my strong suspicion is the monitor restarting on every foreground (that scenePhase handler I added tonight) combined with the 4.75-minute cadence, which would re-arm alert state far more often than intended

The scenePhase handler is not it, and the cadence is not 4.75 minutes. Both are verifiable in seconds:

```swift
// StockSageMonitor.swift:51,57 — instance state on the singleton
private var lastAlerted: [String: StockSageRecommendation] = [:]
private var lastIdeaPrice: [String: Double] = [:]

// StockSageMonitor.swift:119-123 — stop() does not touch either map
func stop() {
    task?.cancel()
    task = nil
    isRunning = false
}
```

A `.background` → `.active` round trip resumes with both dedup maps fully intact. And `start()` guards on `isRunning` (`:74`), so the `try?` at `StockSageApp.swift:85` is a no-op whenever a monitor is already live — you cannot stack loops that way either.

The cadence is **45 seconds**, not 285. `start(interval: TimeInterval = 45, firstCycleDelay: TimeInterval = 20)` (`:73`), and all four call sites — `StockSageApp.swift:61,68,85` and `MarketsView.swift:1219` — invoke `start()` with no arguments. The 285s figure is `MarketsView.swift:421`, a *separate* auto-refresh loop. You are running two independent refresh loops, and alert evaluation happens on the 45s one.

The real mechanism is process death, not foregrounding. Part 1, finding N1.

---

# Part 1 — Notifications (TOP PRIORITY)

Five findings. Four are certain. N1 is the one that produces the burst you are seeing; N3 is the one that produces the drip.

---

## N1 | CRITICAL | CERTAIN | `StockSageMonitor.swift:51,57` + `StockSageApp.swift:68`

### What's wrong

The dedup maps are in-memory only, and nothing persists them:

```swift
// StockSageMonitor.swift:49-57
    /// The last strong recommendation fired per symbol, so we don't re-spam the
    /// SAME alert every cycle (only a NEW or CHANGED strong signal notifies).
    private var lastAlerted: [String: StockSageRecommendation] = [:]
    /// The last live price seen per TRACKED IDEA symbol, so `checkIdeaAlerts` can detect a
    /// stop/target CROSSING (this cycle's price vs the prior one) instead of a standing
    /// condition — mirrors `lastAlerted`'s role for the strong-signal path. …
    private var lastIdeaPrice: [String: Double] = [:]
```

`grep -rn "lastAlerted" StockSage/Sources` returns only `StockSageMonitor.swift`. There is no `UserDefaults`, no file, no `@AppStorage` behind either map. A fresh process starts with both empty.

Now the firing rule. `shouldPushStrongSignal` is dedup-plus-freshness only:

```swift
// StockSageMonitor.swift:420-424
    nonisolated static func shouldPushStrongSignal(recommendation: StockSageRecommendation,
                                                    lastAlerted: StockSageRecommendation?,
                                                    isFresh: Bool) -> Bool {
        isFresh && recommendation != lastAlerted
    }
```

With `lastAlerted[symbol] == nil`, that is `isFresh && true`. And "strong" is a 6% day move:

```swift
// StockSageSignalEngine.swift:47-50
        if absChange > 6 {
            recommendation = changePercent > 0 ? .strongBuy : .strongSell
```

against `latest.previousPrice`, which is the previous close. So on a cold launch the monitor pushes **one notification for every name in the core universe that is more than ±6% on the day**, all at once, with no cap:

```swift
// StockSageApp.swift:62-69  (iOS — starts unconditionally with the app)
                    #if os(iOS)
                    await requestNotificationAuthorization()
                    try? StockSageMonitor.shared.start()
                    #endif
```
```swift
// StockSageMonitor.swift:148-176 — the loop, no rate limit anywhere in it
        for symbol in store.fetchAllSymbols() {
            …
            guard signal.recommendation == .strongBuy || signal.recommendation == .strongSell else { continue }
```

`.core` is ~210 names (`StockSageMonitor.swift:46`). On a gap day, or any Tadawul session with a sector running — Tadawul's daily limit is ±10%, so ±6% is an ordinary day for a mover — that is a double-digit burst arriving 20 seconds after launch.

**And it repeats every launch**, because iOS reclaims backgrounded apps routinely. Your `.background` handler (`StockSageApp.swift:87`) correctly stops the monitor; it cannot stop iOS from killing the process. Each kill wipes `lastAlerted`. Each relaunch re-fires the whole set.

### Why it matters

This is the burst. It is not the scenePhase handler — within one process lifetime, `stop()`/`start()` preserves the maps (Part 0). It is that "have I already told him about this?" is answered from RAM in an app whose process is destroyed several times a day.

Note that the same wipe makes `checkPriceAlerts` behave correctly by comparison — `markPriceAlertsTriggered` is UserDefaults-persisted, and the comment at `:274–277` says exactly why that matters:

```swift
        // `markPriceAlertsTriggered` is UserDefaults-persisted, so unlike the in-memory
        // `lastAlerted`/`lastIdeaPrice` dedup maps, a wrongful fire here doesn't self-heal
```

The author noticed the asymmetry and documented it. The conclusion just did not get drawn: the in-memory maps do not "self-heal", they *self-erase*, and erasing a dedup map is a re-fire.

### The fix

Persist them, keyed to the trading day. Full code in **The notification budget** below; `StockSageAlertBudget` owns both maps and reloads them on launch.

### How to verify

Launch the app on a volatile day, count the pushes 20–30s in. Force-quit, relaunch, count again. Before: the same set arrives twice. After: silence on the second launch, because the day-keyed state survived.

Cheap deterministic proof without waiting for a volatile day:

```swift
@Test func dedupStateSurvivesAProcessRestart() {
    let d = UserDefaults(suiteName: "budget-restart-test")!
    d.removePersistentDomain(forName: "budget-restart-test")
    var a = StockSageAlertBudget.Snapshot(dayKey: "2026-07-28")
    a.lastAlerted["AAPL"] = .strongBuy
    a.save(to: d)
    let b = StockSageAlertBudget.Snapshot.load(from: d, today: "2026-07-28")
    #expect(b.lastAlerted["AAPL"] == .strongBuy)          // survives the restart
    let tomorrow = StockSageAlertBudget.Snapshot.load(from: d, today: "2026-07-29")
    #expect(tomorrow.lastAlerted.isEmpty)                  // but a new day re-arms
}
```

---

## N2 | HIGH | CERTAIN | `StockSageMonitor.swift:234`

### What's wrong

`runWatchlistCycle` does not check the per-type notification preference. `runCycle` does:

```swift
// StockSageMonitor.swift:167-171  (runCycle — pref IS checked)
            if liveNotify, StockSageNotifyPrefs.enabled(StockSageNotifyPrefs.strongSignalsKey),
               Self.shouldPushStrongSignal(recommendation: signal.recommendation,
                                                        lastAlerted: lastAlerted[signal.symbol],
                                                        isFresh: fresh) {
                delivered = await sendAlert(signal: signal, market: symbol.market)
            }
```
```swift
// StockSageMonitor.swift:234-238  (runWatchlistCycle — pref is NOT checked)
            if notify, Self.shouldPushStrongSignal(recommendation: signal.recommendation,
                                                    lastAlerted: lastAlerted[signal.symbol],
                                                    isFresh: fresh) {
                await sendAlert(signal: signal, market: sym.market)
            }
```

### Why it matters

Turning "Strong signals" off in Settings does nothing while watchlist-only mode is on. If you tried to quiet the app by unticking that switch and the noise continued, this is why — and it would have looked like the switch was ignored, which is worse than the noise.

The owner directive that introduced these prefs (`StockSageMonitor.swift:448`: *"not for everything — control from Settings"*) is silently unenforced on one of the two cycle paths.

### The fix

```swift
            if notify, StockSageNotifyPrefs.enabled(StockSageNotifyPrefs.strongSignalsKey),
               Self.shouldPushStrongSignal(recommendation: signal.recommendation,
                                                    lastAlerted: lastAlerted[signal.symbol],
                                                    isFresh: fresh) {
                await sendAlert(signal: signal, market: sym.market)
            }
```

(One added line. Keep it structurally identical to `runCycle`'s so the two paths stay diffable.)

### How to verify

Set `marketsWatchlistOnly = true` with a non-empty watchlist, set `stocksage.notify.strongSignals = false`, put a >6% mover in the watchlist. Before: push. After: silence.

---

## N3 | HIGH | CERTAIN | `StockSageAlertDecision.swift:40-49` + `StockSageMonitor.swift:334,344,348`

### What's wrong

There is no hysteresis on a level crossing. The crossing test is a pure two-point comparison:

```swift
// StockSageAlertDecision.swift:40-48
        if let s = stop, s > 0 {
            let breached: Bool
            if isShort { breached = priorPrice < s && price >= s }
            else { breached = priorPrice > s && price <= s }
            if breached {
```

and `checkIdeaAlerts` advances the baseline to the current price on **both** branches:

```swift
// StockSageMonitor.swift:334
            let priorPrice = lastIdeaPrice[idea.symbol] ?? price
// StockSageMonitor.swift:344  (no alert → baseline advances)
            ), Self.isPushableIdeaAlert(alert) else { lastIdeaPrice[idea.symbol] = price; continue }
// StockSageMonitor.swift:347-349  (alert delivered → baseline advances)
            if await sendIdeaAlert(alert, held: holdingBySymbol[idea.symbol.uppercased()]) {
                lastIdeaPrice[idea.symbol] = price
            }
```

So for a long idea with stop = 100, at the 45s cadence:

| cycle | price | prior | `prior > 100 && price <= 100` | result |
|---|---|---|---|---|
| 1 | 101 | 101 | no | baseline → 101 |
| 2 | 99 | 101 | **yes** | **push**, baseline → 99 |
| 3 | 101 | 99 | no | baseline → 101 |
| 4 | 99 | 101 | **yes** | **push again** |

A name pinned at its stop fires on every re-crossing — up to ~40 pushes an hour at a 45s cadence, for one event.

**The tests do not pin this away.** `StockSageAlertDecisionTests.stopCrossFiresOnceOnTheCrossing` tests 95→89 (fire) then 89→88 (silent) — a price that stays *through* the level. It never tests 89→101→99. The re-crossing case is untested, not decided.

### Why it matters

This is the drip between bursts, and it is worst exactly when it is least useful: a price sitting on its stop is the case where you already know, and where the market is telling you nothing new.

### The fix

Latch the level as **disarmed** when it fires, and re-arm only after price leaves a band around it. See `StockSageAlertBudget.levelReArmed` below. The band is directional: a long stop re-arms above `level × (1 + band)`, a long target re-arms below `level × (1 − band)`.

### How to verify

```swift
@Test func aPriceWobblingAcrossAStopDoesNotReAlert() {
    typealias B = StockSageAlertBudget
    // Long stop at 100, band 0.4%. Fired on the way down.
    let down = B.firedDownward(kind: .stopBreach, isShort: false)
    #expect(down == true)
    #expect(B.levelReArmed(level: 100, price: 100.2, firedDownward: down, band: 0.004) == false) // wobble
    #expect(B.levelReArmed(level: 100, price: 100.5, firedDownward: down, band: 0.004) == true)  // genuine recovery
    // Long target at 120, fired on the way up: re-arms only on a fall back through the band.
    let up = B.firedDownward(kind: .targetHit, isShort: false)
    #expect(up == false)
    #expect(B.levelReArmed(level: 120, price: 119.8, firedDownward: up, band: 0.004) == false)
    #expect(B.levelReArmed(level: 120, price: 119.4, firedDownward: up, band: 0.004) == true)
}
```

---

## N4 | HIGH | CERTAIN | `StockSageMonitor.swift` (whole file)

### What's wrong

There is no rate limit of any kind. `grep -n "cooldown\|throttle\|rateLimit\|cap\|budget" StockSageMonitor.swift` returns only the thermal back-off at `:111–113`, which paces the *loop*, not the *pushes*. Every gate in the file is a correctness gate (is it fresh? is it a duplicate? is it sample data?). None is an attention gate.

The consequence is that N1's burst has no ceiling and N3's drip has no floor. Even with N1 and N3 fixed, a genuinely volatile session across ~900 names still has unbounded push volume, because every one of those pushes is individually legitimate.

### Why it matters

Correctness gates and attention gates answer different questions. "Is this a real, new, fresh event?" is not the same as "have I already spent enough of his attention this hour?" The app currently only asks the first.

### The fix

The budget below: per-symbol cooldown, rolling global cap, digest for the overflow.

---

## N5 | MEDIUM | CERTAIN | `StockSageMonitor.swift:73` vs `MarketsView.swift:421`

### What's wrong

Two independent refresh loops with different periods, and the alert loop is the fast one:

```swift
// StockSageMonitor.swift:73
    func start(interval: TimeInterval = 45, firstCycleDelay: TimeInterval = 20) throws {
```
```swift
// MarketsView.swift:418-425
            .task(id: autoRefreshEnabled) {
                guard autoRefreshEnabled else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(285))
```

All four `start()` call sites use the default. So alert evaluation runs every 45s, six times more often than the 4.75-minute cadence you set, and each of those cycles also does `await StockSageStore.shared.refresh(scope: .core)` (`:100`) — a ~210-name fetch. That is a second full refresh loop your Settings copy does not mention (`IOSSettingsSheet.swift:31–32` describes only the 285s timer).

### Why it matters

Two things. It multiplies N3 by 6.3×. And it roughly triples your feed load versus what the Settings text claims, which feeds directly into the throttling in Part 2.

### The fix

Make the monitor's cadence the same setting the UI already advertises, and stop pretending they are independent:

```swift
    /// Poll cadence. Defaults to the SAME 285s the board's auto-refresh uses
    /// (MarketsView's `.task(id: autoRefreshEnabled)` loop) — these were 45s and 285s
    /// respectively, so alert evaluation ran 6.3× more often than the Settings copy
    /// claimed and each tick also pulled the ~210-name core. One advertised cadence,
    /// one number to reason about.
    static let defaultInterval: TimeInterval = 285

    func start(interval: TimeInterval = StockSageMonitor.defaultInterval,
               firstCycleDelay: TimeInterval = 20) throws {
```

**Flagging this as your call, not mine:** dropping to 285s means a stop breach can go unnoticed for up to ~4.75 minutes rather than ~45 seconds. That is a genuine trade-off between attention cost and reaction latency, and it is a trading decision. If you want the fast loop, keep 45s — the budget below still bounds the notification volume, and the cost is feed load rather than noise. If you want it fast for *ideas you hold* and slow for everything else, say so and I will write the split.

---

# The notification budget

Three brakes, each able to veto on its own, plus a digest for what they suppress, plus persistence so a process kill is not a re-arm. New file, then diffs.

## New file: `StockSage/Sources/StockSage/StockSageAlertBudget.swift`

```swift
import Foundation

// MARK: - Notification budget
//
// The monitor's dedup maps answer "is this the SAME event?". This answers the separate
// question "have we already spent enough of the owner's attention?" — a correctness gate
// and an attention gate are not the same thing, and before this the app only had the first.
//
// Three independent brakes, any one of which can veto a push:
//
//   1. HYSTERESIS — a stop/target that has fired stays DISARMED until price leaves a band
//      around it. Without this a name pinned at its stop re-fires on every re-crossing:
//      StockSageAlertDecision's test is (prior > s && price <= s) and checkIdeaAlerts
//      advances the baseline either way, so 101 → 99 (push) → 101 (silent) → 99 (PUSH
//      AGAIN), ~40×/hour at the old 45s cadence.
//   2. PER-SYMBOL COOLDOWN — at most one push per symbol per window, whatever the event.
//   3. GLOBAL CAP — a hard ceiling on pushes in a rolling hour, so a gap day across the
//      ~210-name core can't empty the notification centre in one burst.
//
// What the brakes suppress is NOT discarded: it accumulates in a digest that flushes as a
// single summary push. Honesty floor — the digest says how many events it stands for and
// that it is a summary, and it never restates a per-event claim it can no longer verify.
//
// State is PERSISTED, day-keyed. This is the fix for the actual spam mechanism: the
// monitor's `lastAlerted` / `lastIdeaPrice` were in-memory only, so every process death —
// routine on iOS for a backgrounded app — re-fired every name past the ±6% strong-signal
// threshold 20s after the next launch, uncapped. Day-keying means dedup survives a kill
// but a genuinely new session still re-arms: one push per symbol per event class per day.

/// Per-budget tunables, all Settings-backed. Absent key = the default here, so an existing
/// install picks up sane limits without visiting Settings first (same contract as
/// StockSageNotifyPrefs' absent-key-means-enabled rule).
enum StockSageAlertBudgetPrefs {
    static let cooldownMinutesKey   = "stocksage.notify.cooldownMinutes"
    static let hourlyCapKey         = "stocksage.notify.hourlyCap"
    static let hysteresisPercentKey = "stocksage.notify.hysteresisPercent"
    static let digestKey            = "stocksage.notify.digest"

    static let defaultCooldownMinutes = 30
    static let defaultHourlyCap = 12
    /// Half-band as a percent of the LEVEL. A long stop at 100 re-arms only once price is
    /// back above 100.40. Sized against Tadawul's 0.01-SAR tick on a ~20 SAR name (0.05%
    /// per tick), so re-arming needs ~8 ticks of genuine recovery rather than one print.
    static let defaultHysteresisPercent = 0.4

    nonisolated static func int(_ key: String, or fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.integer(forKey: key)
    }
    nonisolated static func double(_ key: String, or fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.double(forKey: key)
    }

    nonisolated static var cooldown: TimeInterval {
        TimeInterval(int(cooldownMinutesKey, or: defaultCooldownMinutes) * 60)
    }
    nonisolated static var hourlyCap: Int { int(hourlyCapKey, or: defaultHourlyCap) }
    /// Returned as a FRACTION (0.004), not a percent — every consumer wants the fraction.
    nonisolated static var hysteresis: Double {
        double(hysteresisPercentKey, or: defaultHysteresisPercent) / 100
    }
    /// Default OFF: a digest trades immediacy for quiet, which is the owner's call to make.
    nonisolated static var digestEnabled: Bool { UserDefaults.standard.bool(forKey: digestKey) }
}

/// What the budget decided about one candidate push.
enum StockSageAlertVerdict: Equatable, Sendable {
    /// Send it now.
    case push
    /// Suppressed now, but the owner should still learn it happened — fold into the digest.
    case digest(reason: String)
    /// Suppressed and worth nothing in a summary either (the level never re-armed; this is
    /// the SAME event we already reported, not a new one we're deferring).
    case drop(reason: String)
}

/// One suppressed event, held for the digest. Deliberately carries only what stays TRUE
/// while it waits: the symbol, the event class, and when it happened. It does NOT carry the
/// price — by flush time that number is stale, and a digest line quoting a price the engine
/// can no longer stand behind is exactly the honesty-floor breach the caveats exist to stop.
struct StockSagePendingAlert: Codable, Sendable, Equatable {
    let symbol: String
    let kind: String        // StockSageAlert.Kind.rawValue, or a strong-signal rawValue
    let at: Date
}

@MainActor
final class StockSageAlertBudget {
    static let shared = StockSageAlertBudget()

    /// Everything that must outlive the process. Day-keyed: loading with a different
    /// `dayKey` returns a cleared snapshot, so dedup survives an iOS kill but a new
    /// trading day re-arms every symbol.
    struct Snapshot: Codable, Sendable {
        var dayKey: String
        /// The recommendation last PUSHED per symbol (the monitor's `lastAlerted`).
        var lastAlerted: [String: String] = [:]
        /// The crossing baseline per tracked-idea symbol (the monitor's `lastIdeaPrice`).
        var lastIdeaPrice: [String: Double] = [:]
        /// "SYM|stopBreach" → the level value that fired, held until price re-arms it.
        var disarmedLevels: [String: Double] = [:]
        /// When each symbol last consumed a push (per-symbol cooldown).
        var lastPushAt: [String: Date] = [:]
        /// Push timestamps inside the rolling global window.
        var recentPushes: [Date] = []
        /// Suppressed events awaiting a digest flush.
        var pending: [StockSagePendingAlert] = []
        var lastDigestAt: Date?

        static let storeKey = "stocksage.notify.budgetState"

        nonisolated func save(to defaults: UserDefaults = .standard) {
            guard let data = try? JSONEncoder().encode(self) else { return }
            defaults.set(data, forKey: Self.storeKey)
        }

        /// Load, or return a cleared snapshot when the stored one is from another day or
        /// cannot be decoded. Decode failure falls back to EMPTY, not to a partial state —
        /// an empty budget over-notifies once, a corrupt one could silence a stop breach.
        nonisolated static func load(from defaults: UserDefaults = .standard, today: String) -> Snapshot {
            guard let data = defaults.data(forKey: storeKey),
                  let decoded = try? JSONDecoder().decode(Snapshot.self, from: data),
                  decoded.dayKey == today else { return Snapshot(dayKey: today) }
            return decoded
        }
    }

    private var state: Snapshot

    private init() {
        state = Snapshot.load(today: StockSageScanChunking.utcDayKey(Date()))
    }

    // MARK: Monitor-facing dedup state (was in-memory on StockSageMonitor)

    func lastAlerted(_ symbol: String) -> StockSageRecommendation? {
        state.lastAlerted[symbol].flatMap(StockSageRecommendation.init(rawValue:))
    }

    func setLastAlerted(_ rec: StockSageRecommendation, for symbol: String) {
        rollDayIfNeeded()
        state.lastAlerted[symbol] = rec.rawValue
        state.save()
    }

    func lastIdeaPrice(_ symbol: String) -> Double? {
        state.lastIdeaPrice[symbol]
    }

    func setLastIdeaPrice(_ price: Double, for symbol: String) {
        rollDayIfNeeded()
        state.lastIdeaPrice[symbol] = price
        state.save()
    }

    /// Roll the day over mid-session (the app can be open across the UTC boundary — Riyadh
    /// is UTC+3, so 03:00 local). Clears dedup so a new session re-arms, exactly as a
    /// relaunch would have.
    private func rollDayIfNeeded() {
        let today = StockSageScanChunking.utcDayKey(Date())
        guard state.dayKey != today else { return }
        state = Snapshot(dayKey: today)
    }

    // MARK: The three brakes

    /// Ask before pushing. Does NOT mutate — call `record` only when the push is ACCEPTED
    /// for delivery, mirroring the existing "latch only on a delivered push" rule
    /// (StockSageMonitor's review-2026-07-27 contract).
    func verdict(symbol: String, kind: String, price: Double,
                 level: Double?, firedDownward: Bool, now: Date = Date()) -> StockSageAlertVerdict {
        rollDayIfNeeded()

        // 1. HYSTERESIS — has this exact level re-armed since it last fired?
        if let level, level > 0 {
            let key = Self.levelKey(symbol: symbol, kind: kind)
            if let disarmedAt = state.disarmedLevels[key], disarmedAt == level {
                guard Self.levelReArmed(level: level, price: price,
                                        firedDownward: firedDownward,
                                        band: StockSageAlertBudgetPrefs.hysteresis) else {
                    // The SAME event, not a new one — no digest line either.
                    return .drop(reason: "level \(level) has not re-armed")
                }
                state.disarmedLevels[key] = nil
            }
        }

        // 2. PER-SYMBOL COOLDOWN
        if Self.withinCooldown(lastPush: state.lastPushAt[symbol], now: now,
                               cooldown: StockSageAlertBudgetPrefs.cooldown) {
            return .digest(reason: "per-symbol cooldown")
        }

        // 3. GLOBAL CAP (rolling hour)
        if Self.capReached(recent: state.recentPushes, now: now,
                           cap: StockSageAlertBudgetPrefs.hourlyCap) {
            return .digest(reason: "hourly cap")
        }

        return .push
    }

    /// Latch a push that was ACCEPTED for delivery.
    func record(symbol: String, kind: String, level: Double?, now: Date = Date()) {
        rollDayIfNeeded()
        state.lastPushAt[symbol] = now
        state.recentPushes.append(now)
        state.recentPushes = Self.trimmed(state.recentPushes, now: now)
        if let level, level > 0 {
            state.disarmedLevels[Self.levelKey(symbol: symbol, kind: kind)] = level
        }
        state.save()
    }

    /// Hold a suppressed event for the summary. Capped so a pathological session can't grow
    /// the stored snapshot without bound (same discipline as StockSageStore.maxAlerts).
    func defer_(symbol: String, kind: String, now: Date = Date()) {
        rollDayIfNeeded()
        state.pending.append(StockSagePendingAlert(symbol: symbol, kind: kind, at: now))
        if state.pending.count > Self.maxPending {
            state.pending.removeFirst(state.pending.count - Self.maxPending)
        }
        state.save()
    }

    static let maxPending = 200
    /// Minimum gap between digest pushes — the digest must not become the spam.
    static let digestInterval: TimeInterval = 3600

    /// Flush the digest if it is due and non-empty. Returns the body to push, or nil.
    func dueDigest(now: Date = Date()) -> String? {
        rollDayIfNeeded()
        guard StockSageAlertBudgetPrefs.digestEnabled, !state.pending.isEmpty else { return nil }
        if let last = state.lastDigestAt, now.timeIntervalSince(last) < Self.digestInterval { return nil }
        let body = Self.digestBody(state.pending)
        state.pending.removeAll()
        state.lastDigestAt = now
        state.save()
        return body
    }

    // MARK: - Pure decision helpers (testable without the @MainActor state above)

    nonisolated static func levelKey(symbol: String, kind: String) -> String {
        "\(symbol.uppercased())|\(kind)"
    }

    /// Which way price moved THROUGH the level when this alert fired. Re-arming requires
    /// travel back the OTHER way by the band — a wobble across the level is not enough.
    /// A LONG stops BELOW / targets ABOVE; a SHORT stops ABOVE / targets BELOW, mirroring
    /// StockSageAlertDecision.evaluate's own side-aware rule.
    nonisolated static func firedDownward(kind: StockSageAlert.Kind, isShort: Bool) -> Bool {
        switch kind {
        case .stopBreach: return !isShort
        case .targetHit:  return isShort
        default:          return false
        }
    }

    /// Has price travelled far enough past the level, in the opposite direction to the one
    /// it fired in, to treat a future re-crossing as a NEW event?
    nonisolated static func levelReArmed(level: Double, price: Double,
                                         firedDownward: Bool, band: Double) -> Bool {
        guard level > 0, price > 0 else { return false }
        return firedDownward ? price > level * (1 + band) : price < level * (1 - band)
    }

    nonisolated static func withinCooldown(lastPush: Date?, now: Date, cooldown: TimeInterval) -> Bool {
        guard let lastPush else { return false }
        return now.timeIntervalSince(lastPush) < cooldown
    }

    nonisolated static func trimmed(_ pushes: [Date], now: Date, window: TimeInterval = 3600) -> [Date] {
        pushes.filter { now.timeIntervalSince($0) < window }
    }

    nonisolated static func capReached(recent: [Date], now: Date, cap: Int, window: TimeInterval = 3600) -> Bool {
        trimmed(recent, now: now, window: window).count >= cap
    }

    /// Summary text. States the COUNT and the classes, never a price — by flush time the
    /// prices are stale and the app must not restate a number it can no longer justify.
    nonisolated static func digestBody(_ pending: [StockSagePendingAlert]) -> String {
        let byKind = Dictionary(grouping: pending, by: \.kind)
        let parts = byKind
            .map { kind, items -> String in
                let symbols = Array(Set(items.map(\.symbol))).sorted()
                let shown = symbols.prefix(4).joined(separator: ", ")
                let more = symbols.count > 4 ? " +\(symbols.count - 4) more" : ""
                return "\(kind): \(shown)\(more)"
            }
            .sorted()
        return parts.joined(separator: " · ") + " — summary of \(pending.count) suppressed alert(s); open the app for current levels."
    }
}
```

## Diffs to `StockSageMonitor.swift`

**1. Delete the in-memory maps** (`:51` and `:57`) and route through the budget.

```swift
    /// The last strong recommendation fired per symbol, so we don't re-spam the
    /// SAME alert every cycle (only a NEW or CHANGED strong signal notifies).
    /// PERSISTED via StockSageAlertBudget (2026-07-28): this was an in-memory dictionary,
    /// so every process death — routine on iOS for a backgrounded app — re-fired every
    /// name past the ±6% threshold on the next launch. Day-keyed, so a new session still
    /// re-arms.
    private var lastAlerted: [String: StockSageRecommendation] {
        get { [:] }   // never read wholesale — see budget.lastAlerted(_:)
        set { _ = newValue }
    }
```

Cleaner: remove both properties outright and change the four read sites. The reads are `:169`, `:235`, `:343`; the writes are `:183`, `:240`, `:331`, `:344`, `:348`.

```swift
// :167-175 becomes
            var delivered = true
            if liveNotify, StockSageNotifyPrefs.enabled(StockSageNotifyPrefs.strongSignalsKey),
               Self.shouldPushStrongSignal(recommendation: signal.recommendation,
                                           lastAlerted: budget.lastAlerted(signal.symbol),
                                           isFresh: fresh) {
                // Attention gate, distinct from the dedup gate above: a NEW, FRESH, non-duplicate
                // strong signal can still be the 13th this hour.
                switch budget.verdict(symbol: signal.symbol, kind: signal.recommendation.rawValue,
                                      price: symbol.latest?.price ?? 0, level: nil, firedDownward: false) {
                case .push:
                    delivered = await sendAlert(signal: signal, market: symbol.market)
                    if delivered { budget.record(symbol: signal.symbol, kind: signal.recommendation.rawValue, level: nil) }
                case .digest(let why):
                    budget.defer_(symbol: signal.symbol, kind: signal.recommendation.rawValue)
                    _ = why
                case .drop:
                    break
                }
            }
```

and

```swift
// :183 becomes
        if liveNotify, !Task.isCancelled {
            for (sym, rec) in nowStrong { budget.setLastAlerted(rec, for: sym) }
        }
```

**2. `checkIdeaAlerts` — thread the hysteresis.** Replace `:334–349`:

```swift
            // First sighting this session: seed the baseline rather than claim a crossing that
            // may not be real (mirrors `lastAlerted`'s "no alert on first appearance" rule).
            let priorPrice = budget.lastIdeaPrice(idea.symbol) ?? price
            guard let alert = StockSageAlertDecision.evaluate(
                symbol: idea.symbol,
                recommendation: Self.ideaAlertRecommendation(for: idea.advice.action),
                price: price, priorPrice: priorPrice,
                stop: idea.advice.stopPrice, target: idea.advice.targetPrice,
                lastAlertedRecommendation: budget.lastAlerted(idea.symbol)
            ), Self.isPushableIdeaAlert(alert) else { budget.setLastIdeaPrice(price, for: idea.symbol); continue }

            // HYSTERESIS + cooldown + global cap. `level` is the price level this alert is
            // ABOUT, so the budget can hold it disarmed until price genuinely leaves the band —
            // without this a name pinned at its stop re-fires on every re-crossing.
            let isShort = Self.ideaAlertRecommendation(for: idea.advice.action) == .strongSell
            let level = alert.kind == .stopBreach ? idea.advice.stopPrice : idea.advice.targetPrice
            let down = StockSageAlertBudget.firedDownward(kind: alert.kind, isShort: isShort)
            switch budget.verdict(symbol: idea.symbol, kind: alert.kind.rawValue,
                                  price: price, level: level, firedDownward: down) {
            case .push:
                // Review 2026-07-27: advance the crossing baseline only when the push was ACCEPTED —
                // a failed push keeps the prior baseline so the same crossing re-fires next cycle.
                if await sendIdeaAlert(alert, held: holdingBySymbol[idea.symbol.uppercased()]) {
                    budget.setLastIdeaPrice(price, for: idea.symbol)
                    budget.record(symbol: idea.symbol, kind: alert.kind.rawValue, level: level)
                }
            case .digest:
                budget.defer_(symbol: idea.symbol, kind: alert.kind.rawValue)
                budget.setLastIdeaPrice(price, for: idea.symbol)
            case .drop:
                budget.setLastIdeaPrice(price, for: idea.symbol)
            }
```

**3. Add the accessor and the digest flush.** Near the top of the class:

```swift
    private var budget: StockSageAlertBudget { StockSageAlertBudget.shared }
```

At the end of `runCycle`, after `checkIdeaAlerts` (`:196`):

```swift
                await checkIdeaAlerts(prices: freshPrices)
                // Flush the digest if one is due — everything the budget suppressed this hour
                // arrives as ONE summary rather than silently disappearing.
                if let body = budget.dueDigest() { await sendDigest(body) }
```

and the sender, beside `sendIdeaAlert`:

```swift
    /// One summary push for everything the budget suppressed. Deliberately carries no prices:
    /// by flush time those numbers are stale, and the app must never restate a number it can
    /// no longer justify (honesty floor). It says what happened and where to look.
    private func sendDigest(_ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = "StockSage — quiet-hours summary"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        if (try? await UNUserNotificationCenter.current().add(request)) != nil { await bumpBadge() }
    }
```

## Diffs to `IOSSettingsSheet.swift`

Add under the existing notification toggles:

```swift
                Section("Notification budget") {
                    Stepper("Per-symbol cooldown: \(cooldownMinutes) min", value: $cooldownMinutes, in: 0...240, step: 15)
                    Stepper("Max per hour: \(hourlyCap)", value: $hourlyCap, in: 1...60)
                    Stepper("Re-alert band: \(hysteresisPercent, specifier: "%.1f")%", value: $hysteresisPercent, in: 0...5, step: 0.1)
                    Toggle("Digest suppressed alerts", isOn: $digestEnabled)
                    Text("Suppressed alerts are summarised once an hour rather than dropped. The summary states how many events it covers and names the symbols — it does not restate prices, which are stale by the time it sends.")
                        .font(.caption).foregroundStyle(.secondary)
                }
```

with the bindings:

```swift
    @AppStorage(StockSageAlertBudgetPrefs.cooldownMinutesKey)   private var cooldownMinutes = StockSageAlertBudgetPrefs.defaultCooldownMinutes
    @AppStorage(StockSageAlertBudgetPrefs.hourlyCapKey)         private var hourlyCap = StockSageAlertBudgetPrefs.defaultHourlyCap
    @AppStorage(StockSageAlertBudgetPrefs.hysteresisPercentKey) private var hysteresisPercent = StockSageAlertBudgetPrefs.defaultHysteresisPercent
    @AppStorage(StockSageAlertBudgetPrefs.digestKey)            private var digestEnabled = false
```

## New test file: `StockSageTests/StockSageAlertBudgetTests.swift`

```swift
import Testing
import Foundation
@testable import StockSage

// MARK: - Notification budget (pure decision helpers + persistence)
//
// Same shape as StockSageMonitorTests: the @MainActor, side-effecting store is thin, and
// every decision it makes is a `nonisolated static` pure function pinned here.

struct StockSageAlertBudgetTests {
    typealias B = StockSageAlertBudget

    // MARK: N3 — hysteresis

    @Test func aLongStopReArmsOnlyAfterPriceClearsTheBand() {
        let down = B.firedDownward(kind: .stopBreach, isShort: false)
        #expect(down == true)
        #expect(B.levelReArmed(level: 100, price: 100.2, firedDownward: down, band: 0.004) == false)
        #expect(B.levelReArmed(level: 100, price: 100.5, firedDownward: down, band: 0.004) == true)
    }

    @Test func aLongTargetReArmsDownward() {
        let down = B.firedDownward(kind: .targetHit, isShort: false)
        #expect(down == false)
        #expect(B.levelReArmed(level: 120, price: 119.8, firedDownward: down, band: 0.004) == false)
        #expect(B.levelReArmed(level: 120, price: 119.4, firedDownward: down, band: 0.004) == true)
    }

    @Test func shortSidesMirrorTheLongSides() {
        // A SHORT stops ABOVE (fires UP → re-arms DOWN) and targets BELOW (fires DOWN → re-arms UP).
        #expect(B.firedDownward(kind: .stopBreach, isShort: true) == false)
        #expect(B.firedDownward(kind: .targetHit,  isShort: true) == true)
    }

    @Test func nonLevelAlertKindsNeverClaimADirection() {
        for kind in [StockSageAlert.Kind.newStrongBuy, .newStrongSell, .flip] {
            #expect(B.firedDownward(kind: kind, isShort: false) == false)
        }
    }

    // MARK: N4 — cooldown + global cap

    @Test func perSymbolCooldownBlocksInsideTheWindowAndReleasesAfter() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(B.withinCooldown(lastPush: nil, now: t0, cooldown: 1800) == false)
        #expect(B.withinCooldown(lastPush: t0, now: t0.addingTimeInterval(900),  cooldown: 1800) == true)
        #expect(B.withinCooldown(lastPush: t0, now: t0.addingTimeInterval(1800), cooldown: 1800) == false)
    }

    @Test func globalCapCountsOnlyTheRollingHour() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let old = (0..<20).map { t0.addingTimeInterval(-3700 - Double($0)) }   // all >1h ago
        #expect(B.capReached(recent: old, now: t0, cap: 12) == false)
        let recent = (0..<12).map { t0.addingTimeInterval(-Double($0) * 60) }
        #expect(B.capReached(recent: recent, now: t0, cap: 12) == true)
        #expect(B.capReached(recent: Array(recent.dropLast()), now: t0, cap: 12) == false)
    }

    // MARK: N1 — persistence across a process death, day-keyed

    @Test func dedupStateSurvivesRestartButANewDayReArms() {
        let suite = "budget-restart-test"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        var s = B.Snapshot(dayKey: "2026-07-28")
        s.lastAlerted["AAPL"] = StockSageRecommendation.strongBuy.rawValue
        s.lastIdeaPrice["2222.SR"] = 27.5
        s.save(to: d)

        let sameDay = B.Snapshot.load(from: d, today: "2026-07-28")
        #expect(sameDay.lastAlerted["AAPL"] == StockSageRecommendation.strongBuy.rawValue)
        #expect(sameDay.lastIdeaPrice["2222.SR"] == 27.5)

        let nextDay = B.Snapshot.load(from: d, today: "2026-07-29")
        #expect(nextDay.lastAlerted.isEmpty)
        #expect(nextDay.lastIdeaPrice.isEmpty)
        d.removePersistentDomain(forName: suite)
    }

    // MARK: Digest — honest by construction

    @Test func digestStatesCountsAndSymbolsButNeverAPrice() {
        let pending = [
            StockSagePendingAlert(symbol: "AAPL", kind: "Stop breached", at: Date()),
            StockSagePendingAlert(symbol: "NVDA", kind: "Stop breached", at: Date()),
            StockSagePendingAlert(symbol: "2222.SR", kind: "Target hit", at: Date()),
        ]
        let body = B.digestBody(pending)
        #expect(body.contains("3 suppressed alert(s)"))
        #expect(body.contains("AAPL"))
        #expect(body.contains("Target hit"))
        // No price may leak in — the numbers are stale by flush time.
        #expect(body.contains(".") == true)                       // sentence punctuation only
        #expect(body.range(of: #"\d+\.\d{2,}"#, options: .regularExpression) == nil)
    }

    @Test func digestTruncatesLongSymbolListsHonestly() {
        let many = (0..<9).map { StockSagePendingAlert(symbol: "S\($0)", kind: "Stop breached", at: Date()) }
        let body = B.digestBody(many)
        #expect(body.contains("+5 more"))
        #expect(body.contains("9 suppressed alert(s)"))
    }
}
```

## What this changes in practice

| scenario | before | after |
|---|---|---|
| cold launch on a gap day, 18 names past ±6% | 18 pushes at T+20s, again on every relaunch | ≤12 in the first hour, and 0 on relaunch the same day |
| a long idea pinned at its stop, 45s cadence | ~40 pushes/hour | 1, until price clears the stop by 0.4% and comes back |
| watchlist-only + "Strong signals" off | still pushes | silent |
| a busy session across 900 names | unbounded | capped, with one hourly digest naming what was held |

---

# Part 2 — Stale / mistracked prices

Eleven findings. I re-opened every cited line before including it. The first three form one causal chain and are the reason you were seeing days-old prices; they are independent fixes.

---

## Q1 | CRITICAL | CERTAIN | `StockSageStore.swift:1897-1903`, called at `:2025`

```swift
1897:    private func healStaleQuotes() async {
1898:        let staleSymbols = symbols.filter { $0.isStale() }.map(\.symbol)
1899:        guard !staleSymbols.isEmpty else { return }
1900:        let recovered = await StockSageQuoteService.fetchQuotes(for: staleSymbols)
1901:        guard !recovered.isEmpty else { return }
1902:        for (sym, q) in recovered { mergeLiveQuote(q, symbol: sym) }
1903:    }
```

Three compounding defects.

**No scope.** It filters `symbols` — the whole board, 901 rows after any `.full` refresh — but runs at the tail of *every* `refresh(scope:)`, including the monitor's `.core` cycle (`StockSageMonitor.swift:100`). The `.core` scoping exists precisely so an unpaced background loop can't pull the whole universe every tick; the comment at `StockSageStore.swift:351-352` says so. `healStaleQuotes` silently defeats it.

**No cap.** `fetchQuotes` runs at `concurrency: 6`, so a 901-name stale set is ~150 sequential chunks.

**It cannot converge while the market is shut.** `isStale` is a flat 48h for equities (`StockSageModels.swift:86-88`). Friday 16:00 ET → Monday 09:00 ET is ~65h, so **every US equity row and every Tadawul row is stale all weekend and every holiday**. The refetch returns the same close, so the set is still stale next cycle. It re-fires on every refresh, forever, with no backoff.

Net: on any weekend or holiday the app fires a full-board sweep every 45s (monitor) plus every 285s (`MarketsView.swift:421`) plus every open and pull-to-refresh — roughly doubling each refresh's request volume against exactly the endpoints whose rate-limiting `StockSageEODHD.swift:5-8` names as the cause of days-old prices.

**Why it matters:** this is a self-inflicted 429 storm, and it is the most likely single cause of the staleness the EODHD hybrid was bought to fix.

**Exact fix** — scope it, cap it, back off when the feed has nothing newer:

```swift
    /// Symbols whose last heal returned a market time no newer than the one we already had.
    /// Re-asking before that stamp advances is pure feed cost with zero possible gain — a shut
    /// market keeps returning the SAME close. Cleared the moment a newer marketTime lands.
    private var healBackoff: [String: Date] = [:]

    /// Cap for one heal pass. A weekend/holiday puts EVERY equity row past the 48h freshness
    /// window at once (Fri 16:00 ET → Mon 09:00 ET is ~65h), so an uncapped heal doubles the
    /// request volume of every refresh on a sweep that cannot succeed while the market is shut.
    /// Bounded + cooled-down, the heal stays what it was designed to be: a retry for the handful
    /// a THROTTLED sweep genuinely missed.
    private static let maxHealPerPass = 40

    /// One targeted retry for board rows whose quotes remain materially stale. SCOPED to the
    /// symbols this cycle actually attempted — a `.core` monitor tick must never heal the ~700
    /// rows it didn't even fetch (the feed-cooldown risk `.core` exists to avoid; see
    /// refresh(scope:)'s doc). Successes merge into the board AND any matching idea.
    private func healStaleQuotes(scopedTo scope: Set<String>) async {
        let candidates = symbols.filter { s in
            guard scope.contains(s.symbol.uppercased()), s.isStale() else { return false }
            guard let recorded = healBackoff[s.symbol.uppercased()] else { return true }
            return recorded != s.latest?.marketTime
        }
        let staleSymbols = Array(candidates.prefix(Self.maxHealPerPass).map(\.symbol))
        guard !staleSymbols.isEmpty else { return }
        let recovered = await StockSageQuoteService.fetchQuotes(for: staleSymbols)
        guard !recovered.isEmpty else { return }
        for (sym, q) in recovered {
            let key = sym.uppercased()
            let before = symbols.first { $0.symbol.uppercased() == key }?.latest?.marketTime
            mergeLiveQuote(q, symbol: sym)
            // No advance ⇒ the feed has nothing newer; don't re-ask until it does.
            if let t = q.marketTime, t == before { healBackoff[key] = t } else { healBackoff[key] = nil }
        }
    }
```

Call site at `:2025` becomes `await healStaleQuotes(scopedTo: scopedKeys)` (`scopedKeys` already exists at `:1994`).

**How to verify:** counter in `fetchQuotes`, run on a Saturday with the monitor on. Before: ~901 symbols fetched twice per 45s tick. After: ≤40, and 0 on the second tick.

---

## Q2 | HIGH | CERTAIN | `StockSageStore.swift:1744` × `MarketsView.swift:407,410`

Every streamed trade tick stamps the board clock:

```swift
1743:        // A streamed trade IS a live observation — keep the board's freshness clock honest.
1744:        lastUpdated = Date()
1745:        quoteAsOf = when ?? Date()
```

and two modifiers key off it:

```swift
407:            .sensoryFeedback(.success, trigger: store.lastUpdated)
410:            .task(id: store.lastUpdated) { await store.refreshCatalysts() }
```

`refreshCatalysts()` does `await Task.detached { StockSageHistoryCache.load() }.value` — the store's own comment (`:483`) calls that "the whole multi-MB on-disk JSON cache". With ~300 NASDAQ names subscribed, a live session produces many ticks per second, each cancelling and restarting that task. `Task.detached` does not inherit cancellation, so every restart leaks a full decode that runs to completion. Plus a haptic per tick on iOS.

**Why it matters:** main-actor starvation during exactly the window when quotes should be updating. A stalled main actor is how a refresh times out and a row freezes on an old price — this is a stale-price cause, not just a perf nit. Catalysts derive from the history cache, which only the ideas scan writes, so the dependency is wrong as well as expensive.

**Exact fix:**

```swift
            // Refresh-landed tick (iOS haptic; silent no-op on macOS). Keyed to the SCAN clock,
            // not `lastUpdated` — a streamed trade advances lastUpdated many times a second.
            .sensoryFeedback(.success, trigger: store.ideasUpdated)
            // Catalysts derive from the on-disk HISTORY cache, which only the ideas scan writes.
            // Keying this to `lastUpdated` restarted a multi-MB detached decode on every streamed
            // tick (and Task.detached ignores the cancellation, so they piled up).
            .task(id: store.ideasUpdated) { await store.refreshCatalysts() }
```

and coalesce the publish in `applyLiveTick`:

```swift
    /// Minimum gap between board-clock publishes from the stream. A trade tick is a real
    /// observation, but stamping `lastUpdated`/`quoteAsOf` on every one republishes the whole
    /// Markets surface dozens of times a second for no additional honesty.
    private static let streamClockCoalesce: TimeInterval = 1

        let observed = when ?? Date()
        if lastUpdated.map({ Date().timeIntervalSince($0) >= Self.streamClockCoalesce }) ?? true {
            lastUpdated = Date()
        }
        quoteAsOf = [quoteAsOf, observed].compactMap { $0 }.max()
```

**How to verify:** counter in `refreshCatalysts`, stream on during US hours. Before: hundreds of calls/minute. After: one per scan.

---

## Q3 | HIGH | CERTAIN | `StockSageStore.swift:1944` vs `:2021-2034`

The re-entrancy guard is released ~90 lines before the function commits:

```swift
1933:        guard !isRefreshing else { return }
1939:        isRefreshing = true
1942:        let quotes = await StockSageQuoteService.fetchQuotes(for: universe.map(\.symbol))
1943:        await refreshInfraFX()
1944:        isRefreshing = false
…
2021:        replaceAll(committed, isSample: false)
2025:        await healStaleQuotes()          // ← awaits the network with the guard already open
2026:        lastUpdated = Date()
2029:        quoteAsOf = quotes.values.compactMap(\.marketTime).max()
2034:        StockSageQuoteCache.from(symbols: committed, savedAt: lastUpdated ?? Date(), newListings: newListings).save()
```

While refresh A is suspended in `healStaleQuotes()` (which per Q1 can run for minutes), the 45s monitor tick or the 285s auto-refresh starts refresh B — `guard !isRefreshing` passes, because A already cleared it. B commits fresher rows. A then resumes, overwrites `quoteAsOf` with its own older max, and writes **A's** pre-heal snapshot to disk, discarding B's fresher prices from the cache.

**Why it matters:** next launch seeds from the older of two snapshots, and the freshness banner is stamped from the older sweep. Most likely to fire exactly when refreshes are slow — i.e. when the feed is throttled.

**Exact fix:**

```swift
        isRefreshing = true
        // Hold the guard until the WHOLE commit lands (replaceAll + heal + clocks + cache save).
        // Clearing it at the fetch boundary let a monitor tick start a second refresh mid-commit;
        // the older one then resumed and overwrote quoteAsOf AND the disk cache with its stale
        // snapshot. The spinner staying up through the heal is correct — it is still fetching.
        defer { isRefreshing = false }
        feedError = nil
```

and delete line 1944. (The two early returns at `:1958` and `:1967` are then covered by the `defer`, behaviour unchanged.)

**How to verify:** two concurrent `refresh()` calls in a `TaskGroup` against a stubbed feed; assert only one performs a cache write.

---

## Q4 | HIGH | CERTAIN | `StockSageQuoteCache.swift:12-31, 39-58`

`Entry` has no `marketTime`, and the rebuild never supplies one:

```swift
12:    nonisolated struct Entry: Codable, Sendable, Equatable {
13:        let symbol: String
14:        let price: Double
15:        let previousClose: Double
16:        let time: Date
…
55:                StockSageQuote(price: e.price, previousPrice: e.previousClose, time: e.time),
```

Line 55 omits `marketTime:`, so it defaults to nil. Under the owner-signed fail-closed rule (`StockSageModels.swift:85`, `guard let t = marketTime else { return true }`), **every cache-restored row is STALE at launch, even if the cache was written 30 seconds ago.** The data exists at write time; it is simply never persisted.

Not pinned as deliberate — `StockSageQuoteCacheTests.swift:29-33` calls `from(symbols:)` "the inverse of `symbols(marketFor:)`" but only asserts price/previousClose. A hole in the round-trip, not a decision.

**Why it matters:** the whole board wears the stale clock on every cold launch; `closeableQuoteAsOf` is nil so the banner can't state the board's real age; and it hands Q1 a 901-name stale set on the very first refresh after every launch.

**Exact fix** — add to `Entry`:

```swift
        /// The quote's own MARKET timestamp when it was cached. Optional, so a cache file written
        /// before this field existed still decodes (synthesized `decodeIfPresent`) — unlike
        /// `isNewListing` above, which is non-optional and hard-fails an old file. WITHOUT this,
        /// every restored row hit the fail-closed `nil marketTime ⇒ STALE` rule (owner-signed
        /// 2026-07-27) and the whole board badged stale on launch even when the cache was seconds old.
        let marketTime: Date?

        init(symbol: String, price: Double, previousClose: Double, time: Date,
             isNewListing: Bool = false, marketTime: Date? = nil) {
            self.symbol = symbol
            self.price = price
            self.previousClose = previousClose
            self.time = time
            self.isNewListing = isNewListing
            self.marketTime = marketTime
        }
```

`from(symbols:savedAt:newListings:)` at `:42` gains `marketTime: q.marketTime`; `symbols(marketFor:)` at `:55` gains `marketTime: e.marketTime`.

**How to verify:**

```swift
        let mt = Date(timeIntervalSince1970: 1_700_000_000)
        let c = StockSageQuoteCache(entries: [
            .init(symbol: "AAPL", price: 110, previousClose: 100, time: mt, marketTime: mt)
        ], savedAt: mt)
        let row = c.symbols(marketFor: { _ in "M" })[0]
        #expect(row.latest?.marketTime == mt)
        #expect(row.isStale(asOf: mt.addingTimeInterval(3600)) == false)   // 1h-old cache is NOT stale
        // Legacy file with no marketTime key still decodes, and stays fail-closed stale.
        let legacy = #"{"entries":[{"symbol":"A","price":1,"previousClose":1,"time":0,"isNewListing":false}],"savedAt":0}"#
        #expect((try? JSONDecoder().decode(StockSageQuoteCache.self, from: Data(legacy.utf8))) != nil)
```

---

## Q5 | HIGH | CERTAIN | `StockSageLiveStream.swift:126-144`

`isStreaming` is set true on any frame and cleared only by `stop()` or an explicit `.failure`:

```swift
127:                switch result {
128:                case .success(let message):
129:                    self.isStreaming = true
…
137:                case .failure:
138:                    self.isStreaming = false
```

No ping, no keepalive, no silence timeout.

**A quiet socket lies.** After the US close no trades arrive, `receive` never completes, `isStreaming` stays true all night and all weekend, and `MarketsView.swift:825` renders the pulsing LIVE dot on a frozen board. Its own doc (`:24-25`) says it "must never claim live on a dropped connection".

**A half-open socket never reconnects.** Wi-Fi→cellular, NAT timeout, or laptop sleep leaves a TCP connection producing neither data nor error. `.failure` never fires, so the backoff at `:137-144` is never entered. Prices silently stop moving, indefinitely, while the app says LIVE.

Same block: `isStreaming = true` fires for the `{"status_code":401,"message":"Unauthorized"}` frame that `parseTick` explicitly rejects (pinned at `StockSageLiveStreamTests.swift:37`). An unauthorized socket lights the LIVE dot.

**Why it matters:** the honesty floor applied to prices has to apply to the freshness indicator. The one element that says "these numbers are moving on their own" is the one most likely to be wrong.

**Exact fix** — add an auth classifier and a silence watchdog:

```swift
    /// Status-frame classifier. EODHD's control frames carry `status_code`; nil means this is not
    /// a status frame. Kept separate from `parseTick` (which correctly rejects them) so the
    /// connection layer can honour `isStreaming`'s "open AND AUTHORIZED" contract.
    nonisolated static func authStatus(_ text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let c = obj["status_code"] as? Int { return c }
        if let s = obj["status_code"] as? String { return Int(s) }
        return nil
    }

    /// How long the socket may go without ANY frame before we stop claiming LIVE and re-probe.
    /// A quiet market sends no trades and a NAT/Wi-Fi handover leaves a half-open socket — in both
    /// cases `receive` simply never returns, so `.failure` (the only thing that cleared
    /// `isStreaming`) never fires and the pulsing dot lies indefinitely.
    private static let silenceTimeout = 45
    private var watchdog: Task<Void, Never>?

    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.silenceTimeout))
            guard !Task.isCancelled, let self, self.wantsConnection, let t = self.task else { return }
            // A ping proves the socket is alive without claiming any price moved.
            t.sendPing { [weak self] error in
                Task { @MainActor in
                    guard let self, self.task === t else { return }
                    if error != nil {
                        self.isStreaming = false
                        self.openSocket()
                    } else {
                        self.armWatchdog()
                    }
                }
            }
        }
    }
```

and rewrite the `.success` arm:

```swift
                case .success(let message):
                    self.reconnectAttempt = 0
                    if case .string(let text) = message {
                        if let status = Self.authStatus(text) {
                            // ONLY an explicit 200 means authorized — the `isStreaming` contract.
                            self.isStreaming = (status == 200)
                        } else if let tick = Self.parseTick(text) {
                            self.isStreaming = true
                            StockSageStore.shared.applyLiveTick(symbol: tick.symbol, price: tick.price,
                                                                at: tick.timestamp)
                        }
                    }
                    self.armWatchdog()
                    self.receiveLoop()
```

Cancel it in `stop()` and `openSocket()`: `watchdog?.cancel(); watchdog = nil`.

**How to verify:**

```swift
    @Test func statusFramesClassifyAndTradeFramesDoNot() {
        #expect(L.authStatus(#"{"status_code":200,"message":"Authorized"}"#) == 200)
        #expect(L.authStatus(#"{"status_code":401,"message":"Unauthorized"}"#) == 401)
        #expect(L.authStatus(#"{"s":"AAPL","p":336.91,"t":1785184080000}"#) == nil)
    }
```

Manual: enable the stream, turn Wi-Fi off without quitting. Before: LIVE stays lit forever. After: clears within ~45s and the backoff reconnect engages when the network returns.

---

## Q6 | MEDIUM | CERTAIN | `StockSageStore.swift:411-414`

`addSymbol` has `q.marketTime` in hand and drops it:

```swift
411:        let added = StockSageSymbol(symbol: symbol, market: Self.userMarketLabel, quotes: [
412:            StockSageQuote(price: q.previousClose, previousPrice: q.previousClose, time: Date(timeIntervalSinceNow: -86_400)),
413:            StockSageQuote(price: q.price, previousPrice: q.previousClose),
414:        ])
```

Every other construction site passes it: `mergeLiveQuotes` (`:317`), `mergeLiveQuote` (`:1924`), `refresh` (`:1955`), `runWatchlistCycle` (`StockSageMonitor.swift:224`). This is the identical defect class already fixed once and documented in `StockSageMonitorTests.swift:49-67` ("Mirrors the PRE-FIX construction (marketTime omitted)"); `addSymbol` is the survivor.

**Why it matters:** a ticker you just added, priced seconds ago, is immediately badged STALE, dimmed in the heatmap, excluded from the monitor's alert gates (`StockSageMonitor.swift:162,193`), and pointlessly re-fetched by `healStaleQuotes` next refresh.

**Exact fix:**

```swift
            // Carry the real MARKET time (was omitted here) so a just-added ticker isn't
            // instantly fail-closed STALE — same fix as runWatchlistCycle's synthetic row.
            StockSageQuote(price: q.price, previousPrice: q.previousClose, marketTime: q.marketTime),
```

---

## Q7 | MEDIUM | CERTAIN | `StockSageStore.swift:2029`

```swift
2029:        quoteAsOf = quotes.values.compactMap(\.marketTime).max()
```

Unconditional assignment. `mergeLiveQuotes` does the same job correctly two lines of code away:

```swift
326:        if let newest = quotes.values.compactMap(\.marketTime).max() {
327:            quoteAsOf = [quoteAsOf, newest].compactMap { $0 }.max()
328:        }
```

Three regressions: if the feed omitted every timestamp this sweep, a known-good `quoteAsOf` is wiped to nil; the monitor's `.core` refresh (a ~210-name subset) overwrites a `.full` refresh's value and can move the clock **backwards**; and it discards anything `healStaleQuotes` (line 2025, immediately above) or the live stream just recovered.

**Exact fix:**

```swift
        // Newest MARKET time across the priced quotes — the banner uses this (not fetch time) to
        // tell live from a stale close. MAX-MERGED, not assigned: a `.core` cycle covers a subset
        // and a timestamp-less sweep would otherwise wipe or REVERSE a known-good clock.
        if let newest = quotes.values.compactMap(\.marketTime).max() {
            quoteAsOf = [quoteAsOf, newest].compactMap { $0 }.max()
        }
```

---

## Q8 | MEDIUM | CERTAIN | `MarketsView.swift:567-568` (and the identical copy at `:803-804`)

The banner treats "freshness unknown" as "live":

```swift
567:        let asOf = store.closeableQuoteAsOf ?? store.quoteAsOf
568:        let stale = asOf.map { Date().timeIntervalSince($0) > 3600 } ?? false
```

`?? false` is fail-open, the exact inverse of the owner-signed row-level contract (`StockSageModels.swift:85`: `guard let t = marketTime else { return true }`). When no row carries a market time — Q4's cache path before that fix, or a sweep that returned prices without timestamps (the `"timestamp":"NA"` shape `StockSageEODHDTests.swift:55-59` documents) — `asOf` is nil, so the banner renders the green dot and *"Live Tadawul + NASDAQ quotes"* while **every tile beneath it wears the stale clock**.

The `nil ⇒ not stale` rationale at `StockSageStore.swift:130-132` — "e.g. an all-crypto board, which genuinely is live" — is dead post-restriction: `isAllowedUniverseSymbol` admits no crypto, so `closeableQuoteAsOf` is now nil only in the "we know nothing" case.

**Why it matters:** straight honesty-floor breach. The app asserts a freshness it cannot justify, and contradicts itself on the same screen.

**Exact fix**, both sites:

```swift
        let asOf = store.closeableQuoteAsOf ?? store.quoteAsOf
        // FAIL-CLOSED, matching StockSageQuoteFreshness (owner-signed 2026-07-27): an unknown
        // `asOf` means we cannot VERIFY freshness, so it must never render as "Live". The
        // all-crypto rationale for `?? false` died with the 2026-07-16 Tadawul+NASDAQ restriction —
        // the universe carries no 24/7 asset any more.
        let stale = asOf.map { Date().timeIntervalSince($0) > 3600 } ?? true
```

and give the unknown case its own text rather than quoting a time it doesn't have:

```swift
        let text: String
        if stale, let asOf {
            text = "Prices are the last close as of \(asOf.formatted(date: .abbreviated, time: .shortened)) — markets may be closed; NOT live. Educational, not financial advice."
        } else if stale {
            text = "Price age unknown — the feed returned no market timestamps. Refresh for live. Educational, not financial advice."
        } else {
            text = "Live Tadawul + NASDAQ quotes across \(StockSageUniverse.marketCount) market groups (\(StockSageUniverse.worldwide.count) names). Prices may be delayed ~15 min — educational, not financial advice."
        }
```

Land this **after** Q4, or the banner will correctly-but-loudly report "unknown" on every launch until the cache carries timestamps.

---

## Q9 | MEDIUM | CERTAIN | `StockSageStore.swift:2021` (invariant stated at `:1746` and `:1917`)

Two paths deliberately mirror a fresh quote onto the matching idea, with the invariant stated:

```swift
1746:        // Mirror onto the matching idea so the card and the row can never disagree.
1747:        if let j = ideas.firstIndex(where: { $0.symbol.uppercased() == key }) {
1748:            ideas[j] = ideas[j].withLivePrice(price, asOf: when ?? Date())
```

`refresh()` — the main path, which fetches the entire universe — does neither. It calls `replaceAll(committed, isSample: false)` at `:2021` and stops. Only rows that happen to be *stale* get mirrored, as a side effect of `healStaleQuotes` → `mergeLiveQuote`.

Idea prices come from the daily bar (`:993`: `let price = history.latestClose`), so after a plain refresh the idea card shows this morning's bar close while the watchlist row for the same symbol shows the live quote.

**Why it matters:** the stated invariant is violated on the path that runs most often. Two different prices for one symbol on one screen is the clearest form of "displays an outdated price", and the idea card is the surface you actually trade off.

**Exact fix**, after `:2021`:

```swift
        // Mirror this sweep's live prices onto the matching ideas — same invariant applyLiveTick
        // and mergeLiveQuote already hold ("the card and the row can never disagree"). Without
        // this, refresh() left every idea card on its scan-time daily-bar close while the board
        // row beside it showed the live quote. `withLivePrice` deliberately leaves stop/target/EV
        // untouched — those are fixed LEVELS (see StockSageIdea.withLivePrice).
        for (j, idea) in ideas.enumerated() {
            guard let q = quotes[idea.symbol.uppercased()], q.price > 0 else { continue }
            ideas[j] = idea.withLivePrice(q.price, asOf: q.marketTime)
        }
```

`asOf: q.marketTime` — not `?? Date()` — so a timestamp-less quote leaves `priceAsOf` nil, which `cardIsStale` correctly treats as "can't judge" (`MarketsCardIsStaleTests.nilPriceAsOfIsNeverStaleViaThatAxis`).

---

## Q10 | MEDIUM | CERTAIN | `StockSageEODHD.swift:60-65`

The new authenticated source skips two guards the Yahoo path treats as mandatory:

```swift
60:        guard let close = num("close"), close > 0 else { return nil }
61:        let prev = num("previousClose") ?? close
62:        let marketTime = num("timestamp").map { Date(timeIntervalSince1970: $0) }
63:        return StockSageQuoteService.LiveQuote(symbol: requestedSymbol, price: close,
64:                                               previousClose: prev, marketTime: marketTime,
65:                                               isNewListing: false)
```

versus `parseChart` (`StockSageQuoteService.swift:152-160`), which computes `isNewListing: realPreviousClose == nil`.

1. **`isNewListing` is hardcoded false.** When EODHD sends `"previousClose":"NA"`, `prev` falls back to `close`, producing the exact flat placeholder the flag exists to label — reported as a genuine 0.00% move.
2. **It actively erases a correct flag.** `reconcileNewListings` (`:291-303`) removes a symbol from `newListings` whenever a quote arrives with `isNewListing == false`. Since EODHD is tried first for every US name (`StockSageQuoteService.swift:92`), a genuine new listing correctly flagged by an earlier Yahoo fetch gets its badge cleared on the next EODHD refresh.
3. `num()` lacks the `isFinite` rejection `number()` has (`:265-268`), and `prev` isn't `> 0`-guarded — the exact L3-08 defect pinned for Yahoo at `StockSageQuoteServiceTests.swift:41-62`.

**Why it matters:** a fabricated flat 0.00% on a name with no real prior close is a number the engine cannot justify, and it now arrives on the *primary* US path.

**Exact fix:**

```swift
        // Every numeric field arrives as a number OR the string "NA".
        func num(_ key: String) -> Double? {
            let v: Double?
            if let d = obj[key] as? Double { v = d }
            else if let i = obj[key] as? Int { v = Double(i) }
            else { v = nil }                    // "NA" (String) lands here → treated as absent
            // Reject NaN / ±Inf exactly like the Yahoo parser's `number()` does.
            guard let value = v, value.isFinite else { return nil }
            return value
        }
        guard let close = num("close"), close > 0 else { return nil }
        // L3-08 parity with parseChart: a non-positive previousClose is exactly as unusable as a
        // missing one — route it through the SAME fallback and FLAG it, never fabricate a flat
        // 0.00%. Hardcoding isNewListing:false also let reconcileNewListings CLEAR a correct flag
        // a prior Yahoo fetch had set, since EODHD is tried first for every US name.
        let realPreviousClose = num("previousClose").flatMap { $0 > 0 ? $0 : nil }
        let marketTime = num("timestamp").map { Date(timeIntervalSince1970: $0) }
        return StockSageQuoteService.LiveQuote(symbol: requestedSymbol, price: close,
                                               previousClose: realPreviousClose ?? close,
                                               marketTime: marketTime,
                                               isNewListing: realPreviousClose == nil)
```

---

## Q11 | MEDIUM | PROBABLE | `StockSageStore.swift:1999-2004, :2034`

`refresh()` preserves board rows the cycle did not *attempt*, but drops rows it attempted and the feed *missed*:

```swift
1999:        let preservedOutOfScopeRows = symbols.filter {
2000:            $0.market != Self.userMarketLabel
2001:                && !scopedKeys.contains($0.symbol.uppercased())
2002:                && !liveKeys.contains($0.symbol.uppercased())
2003:        }
2004:        let committed = liveFiltered + preservedUserRows + preservedOutOfScopeRows
```

A curated symbol in `scopedKeys` but absent from `quotes` (a 429 during the sweep) matches neither lane, so it is removed. The coverage guard only bails below 50% (`:1875-1877`), so at 65% coverage ~315 names silently vanish. Then `:2034` persists `committed`, **erasing those symbols' last-good prices from disk**.

PROBABLE rather than CERTAIN on *intent*: dropping a row is arguably more honest than showing a stale one, and no comment addresses it either way. The cache erasure has no honest reading — it destroys data the app already paid for and needs for the last-good board.

**Exact fix** — cache-only, keeps the on-screen behaviour:

```swift
        // Persist EXACTLY what is on screen … plus any row this cycle ATTEMPTED but the feed
        // MISSED (429/throttle). Caching only `committed` pruned those names' last-good prices
        // off disk, so a throttled sweep made the NEXT cold launch worse than the last — the
        // opposite of what the last-good cache exists for. On-screen behaviour is unchanged.
        let committedKeys = Set(committed.map { $0.symbol.uppercased() })
        let cacheable = committed + symbols.filter { !committedKeys.contains($0.symbol.uppercased()) }
        loadedFromCache = false
        StockSageQuoteCache.from(symbols: cacheable, savedAt: lastUpdated ?? Date(), newListings: newListings).save()
```

---

# DELIBERATE, NOT BUGS — don't re-investigate these

1. **`nil marketTime ⇒ STALE` (fail-closed).** Owner-signed 2026-07-27, `StockSageModels.swift:80-89`; pinned at `StockSageStalenessTests.swift:22-26,46-48` and `GeminiReportInvariantsTests.swift:76-83`. Q4/Q6/Q8 fix the *sources* of spurious nils; the rule is correct.
2. **48h equity / 6h crypto tolerance, flat and session-unaware.** Pinned at `StockSageStalenessTests.swift:17-21,42-45`. `StockSageMarketHours` is deliberately a schedule readout only. Do not widen the window to silence the Monday flag — fix the heal loop (Q1).
3. **Tadawul is Yahoo-only; `StockSageEODHD.covers` excludes `.SR`.** Measured vendor fact, `:12-16`, pinned at `StockSageEODHDTests.swift:19-26`.
4. **Same-UTC-day history-cache reuse serving a previous-day close mid-session.** Documented 429-avoidance policy at `StockSageStore.swift:52-59`; honesty gap covered by the `priceAsOf` label, pinned at `MarketsCardIsStaleTests.swift:45-83`.
5. **Whole-file `savedAt` in the history cache.** Named as a known gap, deferred by design (`:535-536`).
6. **`closeableQuoteAsOf` excluding crypto.** Pinned at `StockSageStalenessTests.swift:29-37`. Its *consumer* is Q8; the function is correct.
7. **`mergeLiveQuotes` not flipping `isSampleData`/`loadedFromCache`/`lastUpdated`.** Deliberate under-claim, `:305-309`.
8. **`historyPacingInterval` applying only to `fetchHistories`.** Scoped on purpose, `:181-186`.
9. **Yahoo `parseChart`'s `isNewListing` handling.** Correct and pinned at `StockSageQuoteServiceTests.swift:22-62`. Q10 brings EODHD up to it, not the reverse.
10. **`refresh()`'s <50% coverage bail.** Pure, tested (`coverageGuardShouldBail`), deliberately not gated on `!isSampleData` (`:1962-1970`).

---

# Part 3 — UI/UX


---

# StockSageX — Product Design Review (UI/UX)

**Read first:** `DesignSystem.swift` is a good, opinionated system (7-step spacing, documented AA derivations, a real motion vocabulary). The detail sheet's 10-section order — header → risk chips → gate → sizer → plan numerics → why → evidence → exit plan → context → pinned verdict bar (`MarketsView.swift:7078–7890`) — is genuinely risk-first and well reasoned. The problems below are almost entirely **(a) the board surface around it, and (b) the fact that every layout was tuned for a 780pt mac column and shipped unchanged to a 393pt phone.**

Three things I checked and am *not* flagging, because tests or comments pin them as deliberate: the 5-block ordinal signal meter instead of a percentage (`8253–8263`, owner-directed), the no-wrap section swipe walls (`MarketSectionNavigationTests.swift:24–29`), and `BacktestVerdict.metricColor`'s neutral-on-insignificant rule (`BacktestVerdictColorTests.swift:14–22`).

---

## 1. CRITICAL | CERTAIN | `MarketsView.swift:3909–4002`

**WHAT'S WRONG:** On the Ideas tab — the tab the app *lands on* (`:300`) — the ranked idea list is the **17th element on the page**. Order is literally:

```
feedBanner · regimeCard · catalystCard · moneyVelocityCard   (:334–349)
sectionPicker                                                 (:364)
ideasHeader · shariaScreenBanner · bestOpportunityCard ·
capitalAllocationCard · fastLaneStrip · todaysActionsCard ·
alertsPanel · strategyBacktestPanel · backtestPanel           (:3911–3919)
sort/filter strip · ideasSummaryStrip                         (:3929–3991)
LazyVStack { ideaCard }                                       (:3997)  ← the product
```

Measured against a 393×852 iPhone: the pinned header is ~86pt + 59pt safe area; feedBanner ~68; regimeCard ~170; catalystCard ~154; moneyVelocityCard ~160 — the **section picker itself lands at ~648pt in a ~673pt viewport**, and the first ranked idea is roughly 3,000pt (4–5 screens) down.

Worse, five of those cards are *different rankings of the same list* — `bestOpportunityCard` (highest gross EV), `todaysActionsCard` #1 (fastest net EV/day, equities-first), `fastLaneStrip` #1 (log-growth at ½-Kelly), `capitalAllocationCard` #1 (heat-capped half-Kelly), plus `moneyVelocityCard`'s "Best now". They disagree often enough that the code carries **three separate cross-reference disclosures** explaining the divergence (`:4957`, `:5852`, `MarketsTodayActionsCard.swift:72–75`). That is a symptom, not a solution: the user is being asked to reconcile four crowns before seeing the board.

**WHY IT MATTERS:** A trader opening the app to answer "what do I do?" scrolls past four summary cards to find the navigation, then eight analysis panels to find the ideas. The honesty labelling is excellent but it is attached to content nobody reaches.

**EXACT FIX:** Two independent moves.

(a) Lift the primary nav above the fold — `normalBody`, `:334–367`:

```swift
erasedOnIOS(feedBanner)
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .animation(DS.Motion.lux.delay(0.05), value: appeared)
    .transition(.opacity.combined(with: .offset(y: -4)))
// Primary nav directly under the provenance banner: on a 393pt phone the four
// summary cards below used to push the picker to ~648pt of a ~673pt viewport,
// so section switching required a scroll on every launch.
erasedOnIOS(sectionPicker)
    .opacity(appeared ? 1 : 0)
    .animation(DS.Motion.lux.delay(0.06), value: appeared)
erasedOnIOS(regimeCard) …
erasedOnIOS(catalystCard) …
erasedOnIOS(moneyVelocityCard) …
```

(b) Put the board above the analysis pile — `ideasSection`, `:3910–3919`:

```swift
VStack(alignment: .leading, spacing: DS.Space.sm) {
    ideasHeader
    shariaScreenBanner
    bestOpportunityCard          // ONE crown stays above the fold
    ideasBoard                   // sort strip + summary strip + LazyVStack (extract :3920-4002)
    analysisPanels               // everything else, collapsed by default
}
```

with

```swift
/// The five ranked-again surfaces + the two backtest panels are analysis, not the
/// answer — collapsed so the board itself is reachable without scrolling past them.
@AppStorage("marketsIdeasAnalysisExpanded") private var analysisExpanded = false

@ViewBuilder private var analysisPanels: some View {
    DisclosureGroup(isExpanded: $analysisExpanded) {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            capitalAllocationCard
            fastLaneStrip
            todaysActionsCard
            alertsPanel
            strategyBacktestPanel
            backtestPanel
        }
        .padding(.top, DS.Space.sm)
    } label: {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: mvFont11)).foregroundStyle(DS.Palette.accent)
            Text("Analysis & planning")
                .font(.system(size: fontSectionHeader, weight: .semibold)).foregroundStyle(.white)
            Text("Deploy capital · Fast lane · Today’s plan · Alerts · Backtests")
                .font(.system(size: fontCaption)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    .tint(DS.Palette.accent)
    .accessibilityHint("Shows the capital-allocation plan, fast lane, today’s ranked plan, signal alerts and backtests")
}
```

`backtestPanel` already self-collapses (`:6379`) so this only changes reachability, never content. **No caveat moves** — `ideasHeader`'s calibration honesty label and `StockSageAdvisor.caveat` stay above the board.

**HOW TO VERIFY:** Run `--section ideas` in the iPhone 16 simulator; the section picker and at least one `ideaCard` must be visible without scrolling. Then Cmd-drag the ideas list — the `DisclosureGroup` state must persist across relaunch via `@AppStorage`.

---

## 2. CRITICAL | CERTAIN | `MarketsView.swift:2682–2713`

**WHAT'S WRONG:** Portfolio heat — one of the three things the product exists for — renders as a **9pt caption** (`mvFont9`, `:2706`), buried inside the trade journal, inside the Portfolio tab, and **only when `journal.open` is non-empty AND an account size is set**. It is the sole `StockSagePortfolioHeat` render site in the entire app (verified: one hit in `Sources/`). The default landing tab never shows it.

Compounding this: **the Deploy-capital card labels planned heat "Open heat"** (`:5236`) — the exact phrase the journal uses for *realized* live risk (`:2705`, `:2712`). And there are three different heat rulers with no cross-reference:

| Surface | Number | Ceiling | Verdict language |
|---|---|---|---|
| `capitalAllocationCard:5236` | *planned* heat of an unplaced plan | `maxHeat: 0.08` (`StockSageCapitalAllocator.swift:58`) | amber above `maxHeat * 0.75` = 6% (`:5229`) |
| journal `:2705` | *realized* open heat | none | cool <5 / warm <10 / hot ≥10 (`StockSagePortfolioHeat.swift:19`) |

A user at 6.5% reads "getting full; add carefully" on one tab and a green in-cap plan on another, both under the word "heat."

**WHY IT MATTERS:** This is the honesty floor applied to a *label*, not a number: two different quantities share one name, and the one the product is built around is the smallest text on a screen you have to navigate to.

**EXACT FIX:** (a) Rename the Deploy metric so it can't be read as live exposure — `:5236`:

```swift
// "Planned", not "Open": this is the heat this UNPLACED plan would create, not the
// live book's realized open risk (Portfolio → journal). Same word, different quantity.
ideaMetric("Planned heat", String(format: "%.1f%% of %.0f%% cap",
                                  plan.totalHeat * 100, plan.maxHeat * 100),
           color: heatColor)
    .help("If you place EVERY line of this plan, total risk-at-stop would be \(String(format: "%.1f%%", plan.totalHeat * 100)) of the account, against the allocator's \(String(format: "%.0f%%", plan.maxHeat * 100)) cap. Your CURRENT open heat (Portfolio → journal) is a separate, realized number.")
```

(b) Promote live heat to a persistent strip under `feedBanner`, visible on every tab, with an honest empty state instead of vanishing:

```swift
/// Live portfolio heat — the app's load-bearing risk number, previously a 9pt line
/// inside the journal panel on one tab. Renders on EVERY section; when the account
/// isn't set it says so rather than disappearing (honesty floor: absence of a number
/// must be visible, not silent).
@ViewBuilder private var heatStrip: some View {
    let acct = StockSageInput.positiveAmount(sizerAccount)
    let heat: PortfolioHeat? = acct.flatMap { a in
        StockSagePortfolioHeat.compute(
            openTrades: journal.open.compactMap { t in
                guard let rate = fxRateToUSD(conversionCurrencyForSymbol(t.symbol)) else { return nil }
                return (shares: t.shares,
                        entry: StockSageCurrency.majorUnitValue(symbol: t.symbol, rawValue: t.entry) * rate,
                        stop:  StockSageCurrency.majorUnitValue(symbol: t.symbol, rawValue: t.stop)  * rate)
            }, accountSize: a)
    }
    HStack(spacing: DS.Space.sm) {
        Image(systemName: "flame.fill")
            .font(.system(size: mvFont14))
            .foregroundStyle(heat.map(heatTint) ?? DS.Palette.textSecondary)
        VStack(alignment: .leading, spacing: 2) {
            if let heat {
                Text("Open heat \(Int((heat.heatPct * 100).rounded()))% of account")
                    .font(.system(size: fontCardTitle, weight: .semibold))
                    .foregroundStyle(heatTint(heat))
                    .monospacedDigit()
                Text("\(heat.openCount) open · \(heat.verdict)")
                    .font(.system(size: fontCaption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Open heat — not measurable")
                    .font(.system(size: fontCardTitle, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                Text(acct == nil
                     ? "Set your account size in the position sizer to measure total open risk."
                     : "No open journal trades — nothing at risk.")
                    .font(.system(size: fontCaption)).foregroundStyle(.secondary)
            }
        }
        Spacer(minLength: 0)
        if let heat {
            // Bar, not colour alone — the level must survive greyscale/colour-blindness.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                    Capsule().fill(heatTint(heat))
                        .frame(width: max(4, geo.size.width * min(heat.heatPct / 0.10, 1)), height: 6)
                }
            }
            .frame(width: 72, height: 6)
            .accessibilityHidden(true)
        }
    }
    .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background((heat.map(heatTint) ?? DS.Palette.textSecondary).opacity(0.08),
                in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
        .stroke((heat.map(heatTint) ?? DS.Palette.textSecondary).opacity(0.35), lineWidth: 1))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(heat.map {
        "Open heat: \(Int(($0.heatPct * 100).rounded())) percent of account at risk across \($0.openCount) open trades. \($0.verdict) \($0.caveat)"
    } ?? "Open heat not measurable — \(acct == nil ? "account size not set" : "no open trades")")
    .help(heat?.caveat ?? "")
}

private func heatTint(_ h: PortfolioHeat) -> Color {
    switch h.level {
    case .cool: return DS.Palette.successSoft
    case .warm: return DS.Palette.warningSoft
    case .hot:  return DS.Palette.dangerSoft   // small TEXT — dangerSoft per DesignSystem.swift:50-57
    }
}
```

Insert after `feedBanner` in `normalBody` (`:338`). Keep the journal's existing block — it carries `heat.caveat` in full.

**HOW TO VERIFY:** With 3 open journal trades and an account set, heat must be visible on all seven sections without scrolling. With account blank, the strip must still render and say why. Deploy card must read "Planned heat 6.2% of 8% cap".

---

## 3. HIGH | CERTAIN | `MarketsView.swift:4619–4705`, `:8218–8238`

**WHAT'S WRONG:** The idea card's metric row is a flat `HStack` with up to **eight** children. Ideal-width budget on a velocity-sorted card with an account set:

```
Vel.(62) Price+sub(64) Stop+sub(62) At risk(78) Target(48)
Base size(54) R:R(26) ●hot(28) + 7 gaps×8 (56)  =  478pt
```

Available on a 393pt iPhone: `393 − 2×24` (`:396` outer `DS.Space.xl`) `− 2×12` (`IdeaSpace.cardPad`) = **321pt**. That is 49% over.

`ideaMetric`'s two branches make it worse: the `sub != nil` branch (`:8226–8228`, used by Price and Stop) has `.lineLimit(1)` and **no `minimumScaleFactor`**, so it hard-truncates — "Yahoo · 3…", "−5.1% aw…". The non-sub branch scales to 0.75 (`:8233`), i.e. 12.5 → 9.4pt.

And there is **no adaptive layout anywhere in the view layer** — I grepped `Views/` and `App/` for `ViewThatFits`, `horizontalSizeClass`, `AnyLayout`, `dynamicTypeSize`: **zero hits**. The same defect repeats at `MarketsView.swift:5364–5395` (`deployPositionRow`, 6 metrics), `:6261–6278` (strategy backtest, 7 metrics incl. label "Pooled DD (eq-wt)"), `:7260–7290` (sheet plan numerics — the Stop value string `"135.20 (−5.1% to stop)"` alone needs ~130pt), and `ExecutionQualityPanel.swift:49–70` (5 stat cells with a "Assumed (this book)" title at `.lineLimit(1)`).

**WHY IT MATTERS:** These rows carry entry, stop, shares and dollars-at-risk. A truncated money figure on an order-shaped row is exactly the honesty failure `MarketsTodayActionsCard.swift:343–347` documents and guards against with `.fixedSize` — the ideas board never got the same treatment.

**EXACT FIX:** Wrap the row in `ViewThatFits` so macOS stays byte-identical and the phone gets a risk-first two-row form. Replace `:4619` `HStack(spacing: IdeaSpace.chipGap) {` … `:4705` `}` with:

```swift
// Narrow-width fallback (iPhone port): this row's ideal width is ~478pt against
// ~321pt of phone card interior, and ideaMetric's sub-branch has no
// minimumScaleFactor — it HARD-truncates money figures. ViewThatFits keeps the
// 780pt mac column on the single-row form and folds the phone into two rows,
// risk first. Same metrics, same order within each group, nothing dropped.
ViewThatFits(in: .horizontal) {
    HStack(spacing: IdeaSpace.chipGap) { ideaMetricsRow(idea, atRisk: atRisk, vel: vel) }
    VStack(alignment: .leading, spacing: IdeaSpace.stack) {
        HStack(spacing: IdeaSpace.chipGap) { ideaRiskMetrics(idea, atRisk: atRisk) }
        HStack(spacing: IdeaSpace.chipGap) { ideaPlanMetrics(idea, vel: vel) }
    }
}
```

Split the existing children verbatim — `ideaRiskMetrics` gets **Stop, At risk** (plus the momentum dot); `ideaPlanMetrics` gets **Price, Target, Base size, Vol-adj, R:R, Vel.**. Do not change any string, guard, `.help` or accessibility text — the card's `.accessibilityLabel` builder (`:4749–4833`) reads the same values and is unaffected.

Additionally, give the sub-branch the same scale floor as its sibling — `:8226–8228`:

```swift
if let sub {
    Text(value).font(.system(size: mvFont14, weight: .bold, design: .rounded))
        .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.75)
    Text(sub).font(.system(size: mvFont8)).foregroundStyle(subColor)
        .lineLimit(1).minimumScaleFactor(0.8)
}
```

Apply the same `ViewThatFits` pattern to `deployPositionRow`, `strategyBacktestPanel`'s metric row, and `ExecutionQualityPanel.statCell`'s container.

**HOW TO VERIFY:** iPhone SE (375pt) + iPhone 16 Pro Max, default and AX3 Dynamic Type: every money figure and every metric label must render complete. Set `.border(.red)` on `ideaMetric` temporarily — no cell may clip.

---

## 4. HIGH | CERTAIN | 138 `.help(…)` sites across `Views/`

**WHAT'S WRONG:** `.help(_:)` renders a tooltip on macOS hover and an *iPad pointer* tooltip — on **iPhone it is invisible to sighted users** (it becomes an accessibility hint only). There are **122 in `MarketsView.swift` alone**, 138 across `Views/`. What lives there and only there on a phone:

- `:4470` — what "costs > edge" means (the net-cost floor)
- `:4545` — that the EV chip is **gross, before round-trip costs**
- `:4628` — why the velocity number differs from the board's ordering key
- `:4678` / `:5399` — `sizeMetricHelp`, the entire base-size-vs-Deploy-plan distinction
- `:3799–3805` — the *reason* a watchlist signal fired, and the stale-quote explanation
- `:5263` — the effective-bets caveat that n_eff is an optimistic upper bound
- `:8118` (fast lane) — that the hold-day steppers only anchor an estimate

The codebase already recognised this pattern once: `:4248–4250` explicitly moved the "takes several minutes" expectation out of a `.help` because it was "invisible unless the user happens to hover the button." That fix was never generalised.

**WHY IT MATTERS:** This is the honesty floor failing by platform. On macOS every number is one hover from its qualification. On iPhone a large fraction of the qualifications simply do not exist for a sighted user — while the numbers still render at full confidence.

**EXACT FIX:** Add an info-affordance modifier that is a no-op on macOS (where `.help` already works) and a tappable disclosure on iOS. Put it in `PlatformShims.swift` next to `touchHitArea()`:

```swift
#if os(iOS)
/// iOS has no hover, so `.help` text is invisible to sighted users — 138 of this app's
/// caveats live there. `explain(_:)` keeps the `.help` (VoiceOver hint + iPad pointer)
/// AND adds a tappable ⓘ that presents the same string. One source, no drift.
struct ExplainAffordance: ViewModifier {
    let text: String
    @State private var showing = false
    func body(content: Content) -> some View {
        HStack(spacing: 3) {
            content
            Button { showing = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .touchHitArea()
            .accessibilityHidden(true)   // the .help already speaks this
        }
        .popover(isPresented: $showing) {
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Space.md)
            }
            .frame(maxWidth: 320)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(DS.Palette.bgTop)
        }
    }
}
#endif

extension View {
    /// `.help` on every platform, plus a visible ⓘ on iOS. Use for caveats a sighted
    /// phone user must be able to reach; plain `.help` stays fine for pure hover polish.
    @ViewBuilder func explain(_ text: String) -> some View {
        #if os(iOS)
        self.help(text).modifier(ExplainAffordance(text: text))
        #else
        self.help(text)
        #endif
    }
}
```

Then convert the **honesty-bearing** subset only — `.help` → `.explain` at `:4470`, `:4545`, `:4628`, `:4678`, `:5263`, `:5399`, `:6118`, `:7275`, and `calibrationChip`. Leave decorative `.help`s alone (e.g. "Close (Esc)" at `:7109`, "Refresh live quotes" at `:860`) so the phone doesn't grow 122 ⓘ glyphs.

**HOW TO VERIFY:** On iPhone, tap the ⓘ next to the EV chip — the popover must contain the same string macOS shows on hover. `grep -c '\.explain('` should be ~9–15, not 122.

---

## 5. HIGH | CERTAIN | `MarketsView.swift:4150–4168`, `:7171–7177`, `:8010`, `:102–110`

**WHAT'S WRONG:** **The caveats are the smallest type in the app.** Concretely:

| Content | Site | Size |
|---|---|---|
| "Rules-based what / when / how-much across the 901-name universe…" (descriptive) | `:4151` | `.caption` = **12pt** |
| "⚠ EV win-rates are **assumed** (identity floor)…" (load-bearing) | `:4158` | `mvFont10` = **10pt** |
| "Signal strength 65 · Trending bull" (the number) | `:7172` | `.caption` = **12pt** |
| "How many rules agree — **NOT a win probability**." | `:7177` | `mvFont9` = **9pt** |
| `a.caveat` in the pinned pre-trade CTA bar | `:8010` | `mvFont9` = **9pt** |

`OnboardingSheet.swift:30` tells the user *"These labels are the product."* They render two steps *below* the marketing copy on the modular scale. This is not a request to remove anything — it is the opposite: the app under-weights its own best feature.

Second, the declared ladder at `:93–100` claims a ≈1.125 major-second ramp, but the actual steps are 8 → 9 (1.125) → 10 (1.11) → 11.5 (1.15) → 12.5 (1.087) → **13 (1.04)** → 15 (1.15) → 20 (1.33). `fontSectionHeader` (13) is **4% larger than `fontMetricValue` (12.5)** — the sheet's "Why / Evidence / Exit plan / Context" headers do not visually outrank the numbers they introduce, despite the comment at `:97–99` asserting that was the point of the 12→13 bump.

Third, `fontMicro` and `fontCaption` (`:109–110`) have **zero consumers** — dead tokens.

**EXACT FIX:** (a) Give caveats their own role, one step *above* metric labels, and make section headers a real level — `:102–110`:

```swift
private var fontSheetTitle: CGFloat { mvFont20 }
private var fontCardTitle: CGFloat { mvFont15 }
// 13 → 15 (2026-07-28 design review): at 13 the section header was 1.04× the 12.5pt
// metric values it introduces — inside the JND, so "Why"/"Evidence"/"Exit plan"/
// "Context" read as body, not structure. 15 restores the 1.2× step the ladder claims.
private var fontSectionHeader: CGFloat { mvFont15 }
private var fontMetricValue: CGFloat { mvFont12_5 }
private var fontBody: CGFloat { mvFont11_5 }
/// Caveats, honesty labels and provenance. Deliberately ONE STEP ABOVE fontChipLabel:
/// these strings are the product's differentiator, and at 9-10pt they rendered smaller
/// than the descriptive copy they qualify. Never below 11.
private var fontCaveat: CGFloat { mvFont11_5 }
private var fontChipLabel: CGFloat { mvFont10 }
private var fontMetricLabel: CGFloat { mvFont9 }
// fontCaption / fontMicro removed — zero consumers since the wave-2 role migration.
```

(b) Re-point the load-bearing caveats. `:7176–7177`:

```swift
Text("How many rules agree — NOT a win probability.")
    .font(.system(size: fontCaveat, weight: .medium))
    .foregroundStyle(DS.Palette.warningSoft)
    .fixedSize(horizontal: false, vertical: true)
```

`:8010` (pinned bar, the last thing read before placing a trade):

```swift
Text(a.caveat)
    .font(.system(size: fontCaveat)).foregroundStyle(DS.Palette.textSecondary)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
```

`:4158` / `:4167` — bump both calibration Labels from `mvFont10` to `fontCaveat`, and drop `:4151`'s descriptive subtitle from `.caption` to `.font(.system(size: fontBody))` so the caveat outranks it.

Section-header sites take the token automatically: `:7363`, `:7386`, `:7571`, `:7717`.

**HOW TO VERIFY:** Screenshot the detail sheet. The "NOT a win probability" line must be visibly larger than the metric labels beside it, and "Why" must be visibly larger than the metric values below it. Nothing may be *removed* — only resized.

---

## 6. HIGH | CERTAIN | `MarketsView.swift:8339–8355`, `:3820–3835`

**WHAT'S WRONG:** The Sell / Reduce action badge is **white text on `DS.Palette.danger`** (`= Color.red`, `#FF453A` in dark):

```swift
case .reduce, .sell:   return DS.Palette.danger        // :8344  → badge fill
case .sell, .strongSell: return .white                 // :8352  → badge ink
```

rendered at `mvFont11` bold (`:4445`, `:7099`, `:3747`). Measured contrast: L(#FF453A) = 0.258 → **3.41:1**. WCAG AA needs 4.5:1 for 11pt bold (14.7px, below the 18.66px bold large-text threshold). The comment at `:3828–3831` asserts "white still reads on the darker red sell badge" — that assertion is wrong by measurement, and `DesignSystem.swift:50–57` already documents the underlying fact ("system red measures ~3.7–4.3:1 there").

The buy and hold badges already do it right: light pastel fill + `Color(white: 0.06)` ink ≈ 10.9:1. Sell is the only outlier — so the fix also makes the four badge families consistent.

Separately, the AA sweep that produced `dangerSoft` was ratified and **test-pinned** (`BacktestVerdictColorTests.swift:9–11`: *"the negative-significant branch swapped danger → dangerSoft … every caller renders this at ~12.5pt TEXT, so the wave's small-danger-TEXT-is-AA invariant applies"*) — but it never reached the Portfolio/journal surface. Raw `DS.Palette.danger` is still used as small-text foreground at, among others, `:3084` and `:3170` (journal P&L), `:2330`, `:2332`, `:2334`, `:2352`, `:2360`, `:2365` (scoreboard), `:3425`, `:3427` (Max DD / VaR), `:2544`, `:2598`, `:2617` (monthly/side/sector R), and `ExecutionQualityPanel.swift:51`, `:60`, `:67`. I verified no test pins any of these — only `BacktestVerdictColorTests` references `DS.Palette` at all.

**EXACT FIX:** `:8339–8355`:

```swift
private func actionColor(_ a: TradeAdvice.Action) -> Color {
    switch a {
    case .strongBuy, .buy: return DS.Palette.successSoft
    case .hold:            return DS.Palette.warningSoft
    case .avoid:           return Color.white.opacity(0.22)
    // dangerSoft, not danger: white-on-#FF453A measures 3.41:1 at this badge's 11pt
    // bold — below the AA 4.5:1 bar. dangerSoft + the dark ink below is 7.85:1, and
    // matches how the buy/hold badges already work (light fill, dark ink).
    case .reduce, .sell:   return DS.Palette.dangerSoft
    }
}

private func actionTextColor(_ a: TradeAdvice.Action) -> Color {
    switch a {
    case .avoid: return .white                     // 22%-white fill stays dark → 8.6:1
    default:     return Color(white: 0.06)         // dark ink on every pastel fill
    }
}
```

Mirror in `recColor` / `recTextColor` (`:3820–3835`). Then sweep the ~15 small-text `DS.Palette.danger` foregrounds listed above to `DS.Palette.dangerSoft`, leaving `danger` for fills/strokes/icons exactly as `DesignSystem.swift:53` prescribes (`heatColor:3563`, `correlationColor:2017`, `tradePlanOverlay:8397`, the trash icon `:3769` all stay).

Add a guard test so the wave can't regress again:

```swift
@Test func actionBadgesUseLightFillDarkInk() {
    // Every action badge must be a pastel fill with dark ink — the AA pattern the
    // buy/hold badges already used and the sell badge did not (3.41:1 white-on-red).
    for a in [TradeAdvice.Action.strongBuy, .buy, .hold, .reduce, .sell] {
        #expect(MarketsView.actionTextColorForTest(a) == Color(white: 0.06))
    }
    #expect(MarketsView.actionColorForTest(.sell) == DS.Palette.dangerSoft)
}
```

**HOW TO VERIFY:** Xcode Accessibility Inspector → Color Contrast on a Sell card badge: must report ≥ 4.5:1. Visually, Sell/Reduce badges should now match the visual weight of Strong Buy badges.

---

## 7. HIGH | CERTAIN | `PlatformShims.swift:34–40` + ~20 sites

**WHAT'S WRONG:** `touchHitArea()` — the shim written specifically to fix "caption-size row buttons were ~18pt tappable" (its own doc comment) — is applied at exactly **two sites** in the whole app: `MarketsView.swift:1134` and `:5562`. Every other icon-only control ships at glyph size:

| Control | Site | Approx. hit area |
|---|---|---|
| Detail-sheet **prev/next chevrons** | `:8144–8175` | ~15×13pt each, 4pt apart |
| Detail-sheet **close ✕** | `:7106–7110` | ~24×24pt |
| Card **set-alert** menu | `:4589–4592` | ~16×16pt |
| Card **backtest** button | `:4596–4600` | ~16×16pt |
| Ideas **search clear** ✕ | `:3973–3976` | ~13×13pt |
| **Retry failed** | `:4309–4312` | text height only |
| Sharia **Turn off** | `:4116–4117` | text height only |
| Alerts **Clear** | `:4915–4917` | text height only |
| Price-alert **trash** | `:1156–1158` | ~14×14pt |

The header refresh button does it correctly (`:855` `.padding(7).contentShape(Circle())`) and its comment claims it's "the only sub-44pt control in this header" — true of the header, never swept elsewhere.

The prev/next pair is the worst: two ~15pt targets 4pt apart, immediately beside the close button, in the **top-right corner of a tall phone** — simultaneously the hardest one-handed reach and the highest mis-tap risk (next-idea vs close-sheet).

**EXACT FIX:** Apply the existing shim. `:8143–8175`:

```swift
HStack(spacing: DS.Space.xs) {
    Button { stepSheet(-1, from: idea.id) } label: {
        Image(systemName: "chevron.up").font(.system(size: mvFont14, weight: .semibold))
            .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain).touchHitArea()      // 15pt glyph → 44pt HIG floor on iOS
    …
    Button { stepSheet(+1, from: idea.id) } label: {
        Image(systemName: "chevron.down").font(.system(size: mvFont14, weight: .semibold))
            .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain).touchHitArea()
    …
}
```

Add `.touchHitArea()` at each site in the table. It expands only the hit shape (`padding(12) → contentShape → padding(-12)`), so **no visual layout changes on any platform** — this is a zero-risk sweep.

Additionally, on iOS relocate the stepper to the bottom bar where the thumb already is — insert into the `safeAreaInset` button row at `:7955`, just before `Spacer(minLength: 0)`:

```swift
#if os(iOS)
// Thumb-zone stepper: the header pair sits in the top-right of an 852pt phone —
// the least reachable corner, adjacent to Close. Same stepSheet actions.
sheetNavControls(idea)
#endif
```

and gate the header copy with `#if os(macOS)` at `:7105`.

**HOW TO VERIFY:** Accessibility Inspector → Audit on the detail sheet: zero "Hit area is too small" results. Manually: step through 5 ideas one-handed on an iPhone 16 Pro Max without accidentally dismissing.

---

## 8. HIGH | CERTAIN | `MarketsView.swift:508`, `:794`, `:3686`

**WHAT'S WRONG:** Three `.sheet` presentations, **none** with `presentationDetents`, `presentationDragIndicator`, or `presentationBackground`. On iPhone the idea detail sheet therefore presents as a full-height modal with no grabber and no way to peek at the board underneath — and its only visible dismiss affordance is the ~24pt ✕ in the top-right corner (`:7107`).

The sheet's whole design assumes you compare ideas: it has a prev/next stepper, an "N of M" position label, and a `.task(id:)` debounce specifically for rapid stepping (`:8074–8085`). On a phone you cannot see what you're stepping *within*.

**EXACT FIX:** `:508`:

```swift
.sheet(item: $selectedIdea) { idea in
    ideaDetailSheet(idea)
        #if os(iOS)
        // Medium first: the sheet's top ~40% is symbol/action/signal/gate/sizer —
        // the decision content. A medium detent lets the board stay visible while
        // stepping prev/next, which is what the stepper exists for. Large is one
        // drag away for Evidence / Exit plan / Context.
        .presentationDetents([.medium, .large], selection: $detailDetent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.scrolls)
        #endif
}
```

with `@State private var detailDetent: PresentationDetent = .medium` beside `selectedIdea` (`:155`).

Verify the pinned CTA bar survives at `.medium` — it uses `safeAreaInset(edge: .bottom)` (`:7890`), which is detent-relative, so the gate verdict chip and caveat stay pinned. That is the important property: **the verdict must never be the thing that falls below a detent.**

Add the same two lines to `StockSageIOSSettingsSheet` (`:794`) with `[.large]` and to `BrowseMarketsView` (`:3686`) with `[.large]`.

**HOW TO VERIFY:** iPhone: tap an idea → sheet opens at medium with a grabber, board visible above; the gate chip and `a.caveat` are both on-screen without scrolling; drag up → full sheet; step ⌄ → next idea, still medium.

---

## 9. HIGH | CERTAIN | `MarketsTodayActionsCard.swift:35–36` vs 17 hardcoded sites

**WHAT'S WRONG:** The file declares `@ScaledMetric font8` / `font9` (`:35–36`) and then uses **raw literals** at 17 sites — including all of the card's load-bearing content:

```swift
:55  Image(systemName: "list.number").font(.system(size: 11))
:56  Text("Today's plan — executable equities first").font(.system(size: 11, weight: .bold))
:64  .font(.system(size: 9))    // "Top N setups, sized and gated…"
:66  .font(.system(size: 9))    // net-vs-growth-rate ranking disclosure
:74  .font(.system(size: 9))    // crown-divergence disclosure
:78  .font(.system(size: 8))    // "Executable now includes only rows that…"
:175 .font(.system(size: 9, weight: .semibold))  // execution recommendation headline
:207 .font(.system(size: 9, weight: .semibold))  // paper realized-vs-planned
:225 .font(.system(size: 8))    // the closed-only selection-bias caveat
:319 Text("#\(rank)").font(.system(size: 11, weight: .bold))
:321 Text(plan.symbol).font(.system(size: 13, weight: .semibold, design: .rounded))
:327 Text("…R/day gross").font(.system(size: 11, design: .monospaced))
```

Result: at AX3 Dynamic Type the `font8`/`font9` parts grow while the rank number, symbol, velocity, and every disclosure stay frozen — the card visually inverts and its 8–9pt caveats become unreadable relative to everything around them. Same defect at `ExecutionQualityPanel.swift:90–91` (`9` and `12.5`), `MarketSessionClockView.swift:29` (`11`, in the *pinned header*), and `MarketsRiskAllocationSection.swift:99, 114, 125, 128, 253, 284, 385, 423`.

**EXACT FIX:** In `MarketsTodayActionsCard.swift`, add the two missing tokens and replace every literal:

```swift
@ScaledMetric(relativeTo: .caption2) private var font8: CGFloat = 8
@ScaledMetric(relativeTo: .caption2) private var font9: CGFloat = 9
@ScaledMetric(relativeTo: .caption2) private var font11: CGFloat = 11
@ScaledMetric(relativeTo: .caption2) private var font12: CGFloat = 12
@ScaledMetric(relativeTo: .caption2) private var font13: CGFloat = 13
```

Then `sed`-style: `size: 8` → `size: font8`, `size: 9` → `size: font9`, `size: 11` → `size: font11`, `size: 12` → `size: font12`, `size: 13` → `size: font13`. Default-size rendering is byte-identical (each `@ScaledMetric` equals its base at the default setting — the exact contract `MarketsView.swift:64–66` documents).

Same treatment for `ExecutionQualityPanel.statCell` and `MarketSessionClockView.line`.

Then raise the sub-9pt disclosures on this card to 9 minimum: `:78`, `:180`, `:215`, `:225` go from `font8` → `font9` (they are caveats, and per finding #5 caveats should not be the smallest text on screen).

**HOW TO VERIFY:** Settings → Accessibility → Larger Text at max, open Ideas → Today's plan. Every line must grow together; nothing frozen at 8pt.

---

## 10. MEDIUM-HIGH | CERTAIN | `MarketsView.swift:824–837`

**WHAT'S WRONG:** The LIVE indicator runs `.easeInOut(duration: 1).repeatForever(autoreverses: true)` (`:829`) on a dot in the **pinned header** — an indefinite animation that is on-screen continuously whenever the socket is open, and it is **not gated on `accessibilityReduceMotion`**. The view already reads `reduceMotion` (`:280`) and correctly gates the header logo keyframes (`:733`) and the empty-state halo (`:8465`). This one and the refresh spinner (`:846`) were missed.

An indefinitely repeating animation in persistent chrome is the canonical Reduce Motion case — for motion-sensitive users it is the single most aggravating pattern.

**EXACT FIX:** `:824–837`:

```swift
@ViewBuilder private var liveStreamIndicator: some View {
    if liveStreamEnabled, StockSageLiveStream.shared.isStreaming {
        HStack(spacing: 4) {
            Circle().fill(DS.Palette.successSoft).frame(width: 6, height: 6)
                // Reduce Motion: solid dot. An indefinite pulse in the PINNED header is
                // on-screen for the whole session — the textbook case for the setting.
                // The dot + "LIVE" word still carry the state (colour is not the only cue).
                .opacity(reduceMotion ? 1 : (livePulse ? 1 : 0.25))
                .animation(reduceMotion ? nil
                           : .easeInOut(duration: 1).repeatForever(autoreverses: true),
                           value: livePulse)
            Text("LIVE").font(.system(size: fontChipLabel, weight: .bold))
                .foregroundStyle(DS.Palette.successSoft)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live streaming prices")
        .explain("Streaming trades in real time for US names. Saudi names refresh on the timer — no stream exists for that exchange.")
        .onAppear { if !reduceMotion { livePulse = true } }
    }
}
```

(Note the size bump 9 → 10: "LIVE" at `mvFont9` bold is the smallest label in the header.) Do the same for `:844–847` — under Reduce Motion, swap the infinite rotation for a static `Image(systemName: "arrow.clockwise")` plus the existing `.disabled(store.isRefreshing)` state, or a `ProgressView()`.

**HOW TO VERIFY:** Settings → Accessibility → Motion → Reduce Motion ON. The LIVE dot must be solid and steady; the refresh glyph must not spin.

---

## 11. MEDIUM-HIGH | PROBABLE | `MarketsView.swift:398`, `:8042–8045`

**WHAT'S WRONG:** iPad and mac wide windows get a **780pt centred column and nothing else** (`:398`). On a 13" iPad in landscape (1366pt) that leaves ~293pt of empty canvas on each side. The detail sheet caps at 680pt (`:8042`) and presents as a centred form sheet, so opening an idea *covers* the board — on a device with room to show both.

This is a device the app is otherwise well suited to: the boards are dense tables, the sheet is a detail pane, and the user's task is comparing candidates.

**EXACT FIX:** Replace the modal sheet with a `NavigationSplitView` detail column on regular-width, keeping the sheet on compact. In `normalBody`, wrap:

```swift
@Environment(\.horizontalSizeClass) private var hSize

var body: some View {
    if let sym = qaDetailSymbol { … }           // QA seam unchanged
    else if hSize == .regular {
        // iPad / wide mac: the board is a list and the sheet is a detail pane — showing
        // them side by side is the whole reason to be on a big screen. Same ideaDetailSheet
        // body, same selectedIdea binding, so every .task/.onChange keeps working.
        NavigationSplitView {
            normalBody.navigationSplitViewColumnWidth(min: 420, ideal: 520, max: 620)
        } detail: {
            if let idea = selectedIdea { ideaDetailSheet(idea) }
            else {
                ContentUnavailableView("No idea selected",
                                       systemImage: "sparkles.rectangle.stack",
                                       description: Text("Tap a ranked idea to see its full plan, gate verdict and evidence."))
            }
        }
        .navigationSplitViewStyle(.balanced)
    } else {
        normalBody      // iPhone: unchanged, .sheet(item:) as today
    }
}
```

and gate the `.sheet(item:)` at `:508` on `hSize == .compact`. Raise `:398`'s cap to `maxWidth: 900` in the split-view leg so the multi-metric rows get real room.

**Flagging for your decision:** this is the largest structural change in the review and it touches the `qaDetailSymbol` snapshot seam's sibling path. If you'd rather not, the minimum viable version is just raising `:398` from 780 → 900 on regular width, which un-cramps the metric rows for free.

**HOW TO VERIFY:** iPad Pro 13" landscape: board on the left, detail on the right, both scrollable independently; prev/next steps the detail without dismissing. iPhone: byte-identical to today.

---

## 12. MEDIUM | CERTAIN | `MarketsView.swift:6231–6375`

**WHAT'S WRONG:** `strategyBacktestPanel` renders unconditionally on the Ideas tab even with no backtest — a full card with icon, title, description, Run button, and the calibration status block, roughly 120pt of chrome around one button. Its sibling `backtestPanel` correctly self-collapses (`:6379`). And when it *does* have data it emits a **7-metric `HStack`** (`:6261–6278`) whose labels include "Worst-name DD" and "Pooled DD (eq-wt)" — hopeless below ~700pt.

**EXACT FIX:** Collapse to a single actionable line when there's nothing to show. After `:6232`:

```swift
private var strategyBacktestPanel: some View {
    // Collapsed shell when nothing has been run: a full card of chrome around one
    // button is dead weight on the tab the app lands on. The calibration status block
    // below is what makes the un-run state meaningful, so it stays in the collapsed form.
    if store.strategyBacktest == nil && !store.isLoadingStrategy && store.strategyError == nil {
        return AnyView(
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: mvFont13)).foregroundStyle(DS.Palette.accent)
                Text("Strategy backtest — not run")
                    .font(.system(size: fontBody, weight: .semibold)).foregroundStyle(.white)
                Text("Calibrates EV win-rates. Until it runs they are assumed.")
                    .font(.system(size: fontCaveat)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { Task { await store.refreshStrategyBacktest() } } label: {
                    Text("Run").font(.system(size: fontBody, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(DS.Palette.accent, in: Capsule())
                }
                .buttonStyle(LuxPressStyle()).touchHitArea()
            }
            .padding(DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill).strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
        )
    }
    return AnyView(strategyBacktestExpanded)   // existing body, renamed
}
```

Note the collapsed form is *more* honest than the expanded one: it states plainly that win-rates are assumed until it runs, in `warningSoft`, rather than burying that in the calibration block. And apply the finding-#3 `ViewThatFits` to `:6261–6278`.

**HOW TO VERIFY:** Fresh install → Ideas tab: the strategy panel is one row, ~44pt. Run it → expands to the full card.

---

## 13. MEDIUM | CERTAIN | `MarketsView.swift:3766–3775`, `:3799–3805`

**WHAT'S WRONG:** The watchlist row's remove affordance is **hover-gated** (`if sym.market == "★ My watchlist", hovered`) — on iOS `.onHover` never fires, so the trash button **never renders on a phone or iPad**. The only touch path is the `.contextMenu` at `:3806–3811` (long press), which is undiscoverable. And the row's entire explanatory payload — the signal reason, and the stale-quote timestamp — lives in a `.help` (`:3799–3805`), invisible on iPhone per finding #4. So on iOS a watchlist row shows a Buy/Sell badge and a strength level with **no reachable explanation and no visible way to remove it.**

Also, the watchlist row is not tappable at all (no `onTapGesture`), unlike ideas cards — so the section's only interaction on a phone is a hidden long-press.

**EXACT FIX:** Add the platform-native idiom. Wrap the `ForEach` at `:3604` in a swipe-capable container, or simpler and lower-risk, make the trash unconditional on iOS:

```swift
// Hover-gated on macOS (quiet rows until pointed at); ALWAYS shown on iOS, where
// .onHover never fires — the button previously did not exist on touch at all, leaving
// only an undiscoverable long-press.
#if os(iOS)
let showRemove = sym.market == "★ My watchlist"
#else
let showRemove = sym.market == "★ My watchlist" && hovered
#endif
if showRemove {
    Button { withAnimation(DS.Motion.smooth) { store.removeSymbol(sym.symbol) } } label: {
        Image(systemName: "trash").font(.system(size: mvFont12)).foregroundStyle(DS.Palette.dangerSoft)
    }
    .buttonStyle(.plain).touchHitArea()
    .help("Remove from watchlist")
    .accessibilityLabel("Remove \(sym.symbol) from watchlist")
    .transition(.opacity)
}
```

And surface the signal reason as a visible line rather than a tooltip — after `:3721`:

```swift
// The reason was .help-only, i.e. invisible on iPhone. It is the only thing that
// makes the Buy/Sell badge interpretable, so it belongs in the pixels.
if let reason = signal?.reason, !reason.isEmpty {
    Text(reason).font(.system(size: fontCaveat)).foregroundStyle(.secondary)
        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
}
```

**HOW TO VERIFY:** iPhone → Watchlist: each user-added row shows a trash icon with a 44pt target, and each signalled row shows its reason text.

---

## 14. MEDIUM | CERTAIN | `MarketsView.swift:1978`, `:2509`

**WHAT'S WRONG:** `mvFont7` — a **7pt** token — renders the correlation-matrix cell values (`:1978`, bold white inside 26×18pt tiles) and the calibration histogram bin labels (`:2509`). Even scaled by `@ScaledMetric`, 7pt at the default text setting is below any legibility floor; Apple's guidance treats 11pt as the practical minimum for anything a user must read. A correlation coefficient the user is meant to act on (a concentration warning) should not be the smallest glyph in the product.

Note the mirror copy in `MarketsRiskAllocationSection.swift:411` has the identical problem.

**EXACT FIX:** Grow the cell to carry legible type — `:1974–1980`:

```swift
Rectangle().fill(defined ? correlationColor(v) : DS.Palette.surfaceAlt)
    .frame(width: 34, height: 24)                    // was 26×18 — room for 9pt
    .overlay(Text(defined ? String(format: "%.1f", v) : "—")
        .font(.system(size: mvFont9, weight: .bold)) // was mvFont7
        .foregroundStyle(.white.opacity(defined ? 0.95 : 0.55)))
```

The panel is already inside a horizontal `ScrollView` (`:1962`-ish), so widening the cells costs nothing but scroll extent. Then delete `mvFont7` (`:67`) once both sites move — it will have no consumers. Same edit in `MarketsRiskAllocationSection.swift:409–411`.

**HOW TO VERIFY:** Correlation values readable at arm's length on a phone at default text size.

---

## 15. MEDIUM | CERTAIN | `MarketsView.swift:4143–4331`

**WHAT'S WRONG:** `ideasHeader` can stack **nine** conditional status lines under its title — subtitle, calibration honesty label, full-scan progress note (`:4256`), analysis timestamp (`:4265`), TOM seasonal disclosure (`:4280`), throttle banner (`:4292`), missing-names banner (`:4306`), `ideasError` (`:4317`), and `StockSageAdvisor.caveat` (`:4319`) — all at `.caption2`/`mvFont9`/`mvFont10` in interchangeable grey and amber. During a first scan on a throttled connection, most of them fire at once and the card becomes an undifferentiated wall of small amber text. Nothing distinguishes "your ranking is missing 400 names" (actionable, degrades the whole board) from "ranking includes a small seasonal month tilt" (informational, permanent).

**WHY IT MATTERS:** Every one of these lines is honest and should stay. But nine equal-weight caveats read as *no* caveat — the reader tunes them all out, which defeats the purpose.

**EXACT FIX:** Two tiers, not nine peers. Keep every string; change only weight and grouping.

```swift
// Tier 1 — degrades the board you're about to act on. Amber, fontCaveat, always visible,
// with an icon. (throttle · missing names · ideasError · stale analysis)
// Tier 2 — standing context. Secondary, fontChipLabel, folded into one collapsible row.
// (universe description · scan-duration note · TOM tilt · StockSageAdvisor.caveat)
@AppStorage("marketsIdeasNotesExpanded") private var ideasNotesExpanded = false
```

Render Tier 1 exactly as today (`:4283–4318`) but at `fontCaveat` with a leading `Image(systemName: "exclamationmark.triangle.fill")`, and collect Tier 2 behind:

```swift
DisclosureGroup(isExpanded: $ideasNotesExpanded) {
    VStack(alignment: .leading, spacing: 4) {
        Text("Rules-based what / when / how-much across the \(StockSageUniverse.worldwide.count)-name analyzed universe (\(Self.worldwideEquityCount) equities), on 1-year history.")
        if store.isLoadingIdeas, let p = store.ideasProgress, p.total >= StockSageUniverse.worldwide.count {
            Text("Scanning the \(StockSageUniverse.worldwide.count)-name universe — first scan of the day takes several minutes; results stream in as they complete.")
        }
        if ideaSort == .ev && StockSageAdvisor.turnOfMonthEnabled && !store.seasonality.isEmpty {
            Text("Ranking includes a small seasonal month tilt (each name's calendar-month history, capped ±0.03 rank units) — a weak, backward-looking tendency, not a forecast.")
        }
        Text(StockSageAdvisor.caveat)
    }
    .font(.system(size: fontChipLabel)).foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
} label: {
    Text("How this board is built (4 notes)")
        .font(.system(size: fontChipLabel, weight: .semibold)).foregroundStyle(.secondary)
}
.tint(DS.Palette.textSecondary)
```

**This removes nothing.** The calibration honesty label (`:4155–4169`) stays *outside* the disclosure at Tier-1 weight — it qualifies every EV number on the board and must never be collapsible.

**HOW TO VERIFY:** Trigger a throttled scan: exactly the throttle + missing-names lines are visible in amber at `fontCaveat`; the four standing notes are one collapsed row. Expand → all four strings present verbatim.

---

## 16. LOW-MEDIUM | CERTAIN | `MarketsView.swift:1079–1092`, `:1574–1580`

**WHAT'S WRONG:** Form fields use **fixed pixel widths** — `journalField("Ticker", …, width: 78)`, `DSSegmentPicker(…).frame(width: 74)`, `journalField("Price", …, width: 78)` plus an Add button, totalling ~308pt against 325pt of iPhone card interior. The widths don't grow with Dynamic Type but their contents do, so at AX1+ the placeholder "Ticker" and the entered price clip inside their own boxes. `field(_:_:width:focus:)` at `:1575` has the same `.frame(width: width)`.

**EXACT FIX:** Convert the frames to minimum widths so they can grow — `:1575`:

```swift
// minWidth, not a fixed width: the content scales with Dynamic Type and the box did not,
// so entered prices clipped inside their own field at larger text sizes.
.padding(.horizontal, 8).padding(.vertical, 6)
.frame(minWidth: width, maxWidth: width * 1.8)
```

and let the price-alert row wrap on narrow widths:

```swift
ViewThatFits(in: .horizontal) {
    HStack(spacing: 6) { priceAlertFormFields }
    VStack(alignment: .leading, spacing: 6) { priceAlertFormFields }
}
```

**HOW TO VERIFY:** AX3 text size, Alerts tab: type "2222.SR" and "38.40" — both fully visible.

---

## 17. LOW | CERTAIN | `MarketsRiskAllocationSection.swift` (whole file), `OnboardingSheet.swift:28`, `MarketsView.swift:109–110`

Three small ones, grouped:

**(a) 458 lines of dead code.** `MarketsRiskAllocationSection` is referenced nowhere — I grepped all of `Sources/` and `StockSageTests/`; the only hits are inside the file itself. Its own header comment says "Wiring this into MarketsView is intentionally deferred to the file's owner." It duplicates `riskParityPanel` / `allocationPanel` / `correlationHeatmapPanel` (`MarketsView.swift:1644–2020`) and has since **drifted** — it carries hardcoded fonts at `:99, 114, 125, 128, 253, 284, 385, 423` where the live copies use `mvFont` tokens, so any fix applied to one won't reach the other. Either wire it in (replacing `MarketsView.swift:1644–2020`, which would cut ~380 lines from the 8,722-line file) or delete it. Leaving a divergent shadow copy is the worst option.

**(b) Hardcoded universe count.** `OnboardingSheet.swift:28`: `"Scans the 901-name Tadawul + NASDAQ universe"`. `MarketsView.swift:13–19` documents at length that this is a known regression class ("NEVER hardcode a universe count in copy — a literal regresses the auto-updating number the moment the universe changes"). Fix:

```swift
.init(id: 2, icon: "magnifyingglass", title: "Run \"Find ideas\"",
      detail: "Scans the \(StockSageUniverse.worldwide.count)-name Tadawul + NASDAQ universe and ranks ideas. The first scan of the day takes a few minutes; results stream in."),
```

**(c) Dead design tokens.** `fontMicro` (`:110`) and `fontCaption` (`:109`) have zero consumers. Delete `fontMicro`; keep `fontCaption` and actually use it for the ~40 `mvFont9` caption sites (or delete it too and rename per finding #5).

---

# Mockup 1 — iPhone 16 (393×852), Ideas tab

**Current** — primary nav at ~648pt of a ~673pt viewport; first ranked idea ~3,000pt down:

```
┌─ 393pt ────────────────────────────────────┐
│▓▓ PINNED HEADER ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│
│ [◨] Markets ⟨SIGNALS & PORTFOLIO⟩ ●LIVE ↻⚙│  86pt
│     Live · 2 groups · updated 14:32        │  +59pt safe
│     🇸🇦 Tadawul · closed (3h 12m)           │
│     🇺🇸 NASDAQ · open (2h 41m)              │
├────────────────────────────────────────────┤
│ ● Live Tadawul + NASDAQ quotes across 2    │  ~68
│   market groups (901 names). Prices may…   │
├────────────────────────────────────────────┤
│ ↗ Trending bull                  [Gauge]   │
│   Suggested sizing: ×1.10 of normal        │  ~170
│   ▓▓▓▓▓▓▓▓▓░░░░░░░                         │
│   · S&P above 200dma  · RSI 58  · VIX 14   │
│   Gauged 2 hours ago.                      │
├────────────────────────────────────────────┤
│ ⚡ Volume-confirmed moves      unvalidated  │
│   AAPL  2.4× volume  +3.1%       Tier A    │  ~154
│   2222.SR 3.1× volume −2.2%  index flow?   │
├────────────────────────────────────────────┤
│ ⚡ Money velocity — fastest moves now       │
│   BEST NOW   FASTEST    EST./WEEK          │  ~160
│   NVDA       AVGO       +2.4R              │
│   Est. EV +0.45R  +0.09R/d  net, top 3     │
├────────────────────────────────────────────┤
│ (Watchlist)(Ideas)(All)(Heatmap)(Portfo…   │ ← nav, ~648pt
└═══ fold ≈ 673pt ═══════════════════════════┘
  ↓ ideasHeader (9 status lines) …
  ↓ Best opportunity … Deploy capital …
  ↓ Fast lane … Today's plan … Signal alerts
  ↓ Strategy backtest … Backtest …
  ↓ sort/filter … 24 shown · 6 strong buy …
  ▶ FIRST RANKED IDEA  ≈ 3,000pt down
```

**Proposed** — nav + heat + one crown + first idea all above the fold:

```
┌─ 393pt ────────────────────────────────────┐
│▓ [◨] Markets            ●LIVE   ↻    ⚙   ▓│  44pt
│▓ Live · 14:32 · 🇸🇦 closed 3h · 🇺🇸 open   ▓│  +59pt safe
├────────────────────────────────────────────┤
│ ● Live Tadawul + NASDAQ · delayed ~15 min  │  ~34 (1 line)
├────────────────────────────────────────────┤
│ 🔥 Open heat 3.2% of account   ▓▓▓░░░░░░   │  ~44   ← FINDING 2
│    3 open · room to add                    │        every tab
├────────────────────────────────────────────┤
│ (Watchlist)(Ideas)(All)(Heatmap)(Portfo…   │  ~32   ← FINDING 1
├────────────────────────────────────────────┤
│ ✦ Trade ideas               [Find ideas]   │
│   ⚠ EV win-rates are ASSUMED (identity     │  ~72   caveat at
│     floor) — capped at ~40-55% prior       │        11.5pt, not 10
│   ▸ How this board is built (4 notes)      │        ← FINDING 15
├────────────────────────────────────────────┤
│ ★ BEST OPPORTUNITY                         │
│   NVDA  NVIDIA Corp            Strong Buy  │  ~120
│   RISK IF STOPPED   ≈$98 · 12 sh · 1.00%   │
│   142.50 → 135.20 (−5.1%)  ▸ 156.30        │
│   [Copy plan] [Log trade]      ✓ CLEAR     │
├────────────────────────────────────────────┤
│ 24 shown · 6 strong buy · ↕ velocity sort  │  ~28
├────────────────────────────────────────────┤
│ ▌NVDA  NVIDIA Corp             Strong Buy  │  ← FIRST IDEA
│ ▌▓▓▓▓░   ╱‾╲╱‾╲╱                           │    ≈ 480pt
│ ▌RISK ≈$98 · 12 sh    STOP 135.20 (−5.1%)  │
└═══ fold ≈ 673pt ═══════════════════════════┘
  ↓ TARGET 156.30 · R:R 2.1 · VEL +0.043R/d
  ↓ more ideas …
  ↓ ▸ Analysis & planning (7)          [tap]
      Deploy capital · Fast lane · Today's
      plan · Signal alerts · Backtests
```

---

# Mockup 2 — Idea card metric row

**Current** — flat `HStack`, ideal ~478pt into 321pt of iPhone card interior:

```
├── 321pt available on iPhone ──────────────────────┤
│VEL.     PRICE      STOP       AT RISK   TARGET  BASE SIZE  R:R  ●hot│
│+0.043R/d 142.50    135.20     ≈$98·12sh 156.30  3.2%       2.1      │
│         Yahoo·31m  −5.1% away                                       │
├──────────── needs 478pt (49% over) ────────────────────────────────┤

renders as:  "Yahoo · 3…"   "≈$98 · 1…"   "Base siz…"   R:R + ●hot clipped off
             ↑ sub-branch has NO minimumScaleFactor → hard truncation (:8226)
```

**Proposed** — `ViewThatFits`; mac keeps the single row, phone folds to risk-first two rows:

```
┌─ macOS (780pt column) — unchanged, single row ─────────────────────┐
│VEL.     PRICE      STOP       AT RISK   TARGET  BASE SIZE  R:R  ●hot│
└────────────────────────────────────────────────────────────────────┘

┌─ iPhone (321pt) — two rows, risk group first ──────┐
│ RISK IF STOPPED            ENTRY → STOP            │
│ ≈$98 · 12 sh · 1.00% acct  142.50 → 135.20 (−5.1%) │  ← what you lose
│                                             ● hot  │
├────────────────────────────────────────────────────┤
│ TARGET   R:R   BASE SIZE   VEL.                    │
│ 156.30   2.1   3.2%        +0.043R/d               │  ← what you hope
│ Yahoo · 31m                                        │
└────────────────────────────────────────────────────┘
```

Same metrics, same guards, same `.help`/`accessibilityLabel` strings, nothing dropped — only regrouped so the loss-side numbers read as a unit and no money figure truncates.

---

# Prioritised implementation plan

**Do first — independent, no decisions needed, mechanical:**

| # | Finding | Effort | Risk |
|---|---|---|---|
| 7 | `.touchHitArea()` sweep (~20 sites) | 30 min | zero — hit shape only |
| 10 | Reduce Motion gate on `livePulse` + refresh spinner | 15 min | zero |
| 6 | `dangerSoft` swap: action badges + ~15 small-text sites | 1 h | zero — finishes a test-pinned wave |
| 9 | `MarketsTodayActionsCard` / `ExecutionQualityPanel` / `MarketSessionClockView` font tokens | 45 min | zero — byte-identical at default size |
| 17b | `OnboardingSheet.swift:28` universe count | 2 min | zero |
| 17c | Delete `fontMicro` | 2 min | zero |
| 14 | `mvFont7` → `mvFont9`, widen correlation cells | 20 min | zero |

**Then — the two structural wins:**

| # | Finding | Effort | Notes |
|---|---|---|---|
| 1 | Reorder `normalBody` + `ideasSection`, add `analysisPanels` disclosure | 2–3 h | Biggest single UX gain. Independent of everything else. |
| 2 | Promote `heatStrip`; rename Deploy "Open heat" → "Planned heat" | 2 h | Depends on nothing. **The rename is the honesty-critical half — do it even if you skip the strip.** |
| 3 | `ViewThatFits` on 5 metric rows + `minimumScaleFactor` on `ideaMetric` sub-branch | 3 h | Independent. Do after #1 so you're testing the new order. |
| 8 | `presentationDetents` on all three sheets | 45 min | Independent. |

**Then — polish:**

| # | Finding | Effort |
|---|---|---|
| 5 | Type-role changes (`fontCaveat`, `fontSectionHeader` 13→15) + re-point 6 caveat sites | 1.5 h |
| 4 | `.explain()` shim + convert ~12 honesty-bearing `.help`s | 2 h |
| 15 | `ideasHeader` two-tier notes | 1.5 h |
| 12 | `strategyBacktestPanel` collapsed state | 45 min |
| 13 | Watchlist iOS remove + visible signal reason | 45 min |
| 16 | Fixed-width fields → `minWidth` | 30 min |

**Needs your decision:**

1. **Finding 11 (iPad `NavigationSplitView`).** Real work, touches the QA snapshot seam's sibling path, and it's a judgement call whether iPad matters to you. Cheap fallback: raise `MarketsView.swift:398` from `maxWidth: 780` to `900` on regular width and stop there.

2. **Finding 17a — `MarketsRiskAllocationSection.swift`.** Wire it in (removes ~380 lines from `MarketsView.swift`, but it has drifted — you'd need to reconcile the hardcoded fonts and the `panelHeader` refactor against the live copies) or delete it (458 lines, zero risk). Not my call which.

3. **Finding 1's crown consolidation.** I've proposed keeping `bestOpportunityCard` above the board and collapsing the other four ranking surfaces. Whether Today's plan or Fast lane deserves the above-fold slot instead is a product judgement about which lens you actually trade off — the code currently declines to choose and ships all four with divergence disclosures. Collapsing them is reversible; picking a different crown is yours.

4. **The three heat thresholds** (allocator `0.08` / `0.10`, `PortfolioHeat` 5%/10% bands, plan colour at `maxHeat × 0.75`). Finding 2 fixes the *labels* so they can't be confused. Whether the numbers should be reconciled to one ruler is an engine/product decision, not a UI one — flagging it rather than assuming.agentId: a3cd9e09dd756a0f7 (use SendMessage with to: 'a3cd9e09dd756a0f7', summary: '<5-10 word recap>' to continue this agent)
<usage>subagent_tokens: 303007
tool_uses: 54
duration_ms: 853275</usage>
---

# Part 4 — Features, ranked by value-to-effort

Ranked by (value to a solo trader watching two markets) ÷ (effort). The top item is unusual: most of the work is already done and merged.

---

## F1. Surface the four finished engines that have no UI — **highest value-to-effort in this review**

Verified with `grep -rlw <symbol> StockSage/Sources` returning only the defining file:

| Engine | Lines | Production callers | Tests |
|---|---|---|---|
| `StockSageAllocationOptimizer` | 217 | 0 | 1 file |
| `StockSagePBO` | 121 | 0 | 1 file |
| `StockSageCryptoLiquidityGate` | 89 | 0 | 2 files |
| `StockSageRelativeStrength` | 73 | 0 | 1 file |

These are written, tested, and reachable from nothing. That is ~500 lines of finished engine sitting dark. Two of them are directly load-bearing for the honesty floor:

**`StockSagePBO`** — Probability of Backtest Overfitting is the natural companion to the Deflated Sharpe you already display. DSR answers "is this Sharpe a fluke given how many strategies I scanned?"; PBO answers "does my selection procedure generalise out-of-sample at all?" You already tell the user DSR ≈ 0. PBO belongs in the same block, in the backtest panel beside the DSR readout (`MarketsView.swift`, backtest section) — it makes the existing honesty claim *more* complete, which is the only direction this app moves.

**`StockSageRelativeStrength`** — a Tadawul name up 3% on a day TASI is up 4% is a *laggard*, and the current idea card cannot say so. This belongs as one chip on the idea card metric row, next to the existing signal-strength blocks. It changes what a 6% mover means.

**`StockSageAllocationOptimizer`** — you already ship two strategies via `stocksage.allocStrategy` (`MarketsView.swift:5209`: `greedyKnapsack` / uniform). This is a third. Settings → Allocation strategy, one more case.

**`StockSageCryptoLiquidityGate`** — the universe carries no crypto since the 2026-07-16 restriction. This one is genuinely orphaned by a scope change, not by an oversight. Delete it or park it with a comment; don't wire it.

**Effort:** three small view additions plus one Settings case. **Value:** two of them strengthen the honesty floor with zero new math to justify.

---

## F2. Cross-market correlation warning on the idea sheet

The single most expensive mistake available to someone watching Tadawul *and* NASDAQ is stacking one bet twice: 2222.SR (Aramco) and an oil major both score on the same day, both get funded, and the 8% heat cap is satisfied while the real exposure is one factor at 8%.

You already have every piece: `StockSageCorrelationCluster.correlationAdjustedWeights` (used inside `StockSageCapitalAllocator.allocate`), `StockSagePortfolio.holdingBySymbol`, and `StockSageSector`. What's missing is that the warning only exists *inside* the allocator's weighting, never as a statement to the user at the moment of decision.

**Where it lives:** the idea detail sheet (`MarketsView.swift:7078–7890`), in the risk-chip row near the top — above the sizer, because it changes whether you take the trade at all, not just how big.

**Shape:** when the candidate shares a sector tag with an open position in the *other* market, a `DS.Palette.warningSoft` chip reading e.g. *"Overlaps 2222.SR (open, Tadawul) — same sector. Correlation over the last 60 bars: 0.71 (measured)."* Label it measured, and when there aren't 60 shared bars, say `correlation: unavailable (< 60 shared bars)` rather than computing one you can't stand behind.

**Effort:** medium — one new pure function plus a chip. **Value:** high, and it is exactly the risk-discipline framing the app exists for.

---

## F3. Session-aware notification windows

`StockSageMarketHours.swift` (159 lines) already models both sessions and is deliberately a schedule readout only. Wire it to the budget from Part 1: don't push a Tadawul name outside 10:00–15:00 AST, don't push a NASDAQ name outside 16:30–23:00 AST, and never push either during the small hours.

This is the highest-leverage complement to the notification budget, because it removes an entire category of alert you can't act on. It also fixes the specific insult of a stop-breach push at 03:00 Riyadh time for a name whose market has been shut for eleven hours.

**Where it lives:** Settings → Notifications, one toggle ("Only during market hours", default on) plus a "Quiet hours" range.

**Implementation note:** the gate belongs in `StockSageAlertBudget.verdict`, as a fourth brake returning `.digest(reason: "outside session")` — not `.drop`. The event happened; you should learn it at the next open.

**Effort:** low. **Value:** high.

---

## F4. Notification history / audit log

Every push the app sent, every event the budget suppressed and why. Settings → Notifications → History, or a section in the existing Alerts board section.

Two reasons this is worth more than it looks. First, it is the honesty floor applied to the app's own behaviour: an app that pushes should be able to show you what it pushed. Second, and more practically — you spent tonight guessing at the spam mechanism from memory. With this, the answer would have been on screen: *"14 pushes at 09:12, cause: cold-start dedup miss"*.

`StockSageAlertBudget.Snapshot` already persists `pending` and `recentPushes`; extend it with a bounded (`maxAlerts`-style) delivered log.

**Effort:** low-medium. **Value:** medium, but it is diagnostic infrastructure that pays for itself the next time notifications misbehave.

---

## F5. Pre-open plan, pinned

`StockSageTodayPlan.swift` (419 lines) is wired. What's missing is the *timing*: the plan is most valuable in the twenty minutes before Tadawul opens, and that is exactly when the app is least likely to be open.

Given the hard constraints — no App Groups, so no widget; no server, so no background compute — the honest version is a **local notification scheduled at 09:40 AST** carrying the plan headline computed from last night's scan, with the caveat that it is pre-open and the numbers are last close. `UNCalendarNotificationTrigger`, no server, no entitlement.

**Where it lives:** Settings → Notifications → "Pre-open summary (09:40)".

**Effort:** low. **Value:** medium-high, and it is the only way to get value out of the app at the moment it matters most, under your constraints.

---

## F6. Settings additions, consolidated

Collecting everything this review implies, in the order they should appear:

```
Notifications
  Strong signals                          [on]
  Idea stop / target alerts               [on]
  Price alerts                            [on]
  ── Budget ──────────────────────────────
  Per-symbol cooldown          30 min  [−][+]      ← Part 1
  Max per hour                     12  [−][+]      ← Part 1
  Re-alert band                  0.4%  [−][+]      ← Part 1
  Digest suppressed alerts               [off]     ← Part 1
  Only during market hours                [on]     ← F3
  Quiet hours              23:00 – 08:00           ← F3
  Pre-open summary (09:40)               [off]     ← F5
  History…                                     >   ← F4

Data
  Live streaming (US names)               [on]
  Poll cadence                    4.75 min ▾       ← N5: make the ONE advertised number real
  Allocation strategy       Concentrated ▾         ← F1 adds a third case
```

The "Poll cadence" row matters beyond convenience: right now the Settings copy at `IOSSettingsSheet.swift:31–32` describes a 4.75-minute timer while the monitor independently runs at 45s. One control, one number, one truth.

---

## Deliberately not proposed

- **Home-screen widget / Live Activity** — needs App Groups, needs the $99/yr program. Blocked, correctly.
- **24/7 tracking** — needs a server. Blocked, correctly.
- **Any Saudi real-time feed via EODHD** — measured: no Saudi exchange at any tier. Blocked.
- **Anything that softens a caveat.** Nothing above hides a number; F1 and F2 add caveats rather than removing them.

---

# Part 5 — Correctness, concurrency, performance, memory, dead code

Everything below was verified against the actual lines. Notification and quote-freshness findings live in Parts 1–2 and are not repeated.

---

# CORRECTNESS

## C1 | MEDIUM | PROBABLE | `StockSageCapitalAllocator.swift:196` (+ `:38`, `MarketsView.swift:5217`)

In `.greedyKnapsack` mode — the **production default** (`MarketsView.swift:5209-5210`: `?? "greedyKnapsack"`) — `fundable` is replaced by the truncated list before `fundableCandidateCount` is read:

```swift
// StockSageCapitalAllocator.swift:159-160
            fundable = kept
            scaleApplied = 1   // knapsack truncates instead of scaling
…
// :196
                                 fundableCandidateCount: fundable.count)
```

But the field's contract (`:32-38`) is explicit:

```swift
    /// F5 (2026-07-09): how many ideas cleared EVERY qualitative gate (buy-family, positive EV,
    /// clears cost-after-frictions, positive weight) BEFORE the whole-share floor — i.e. were
    /// genuinely fundable in principle.
    let fundableCandidateCount: Int
```

Separately, knapsack drops names entirely, and the only truncation tell-tale in the UI is gated on `scaleApplied < 1`, which knapsack pins to 1:

```swift
// MarketsView.swift:5237-5239
                        if plan.scaleApplied < 1 {
                            ideaMetric("Cap scale", String(format: "%.0f%%", plan.scaleApplied * 100), color: DS.Palette.warningSoft)
                        }
```

**Why it matters.** Two things. The empty-plan message at `:5220` ("all N fundable positions are below the 1-share minimum…") reports the post-truncation N, understating how many ideas actually qualified — the exact ambiguity F5 was added to remove. And with the concentrated strategy on, ideas that passed every gate are silently deleted from the plan with **no on-screen disclosure at all**. You cannot tell "nothing else qualified" from "six more qualified and didn't fit". `GeminiReportWave2Tests` pins the heat invariant and `scaleApplied == 1`; nothing pins `fundableCandidateCount` under knapsack.

**Exact fix** — capture the pre-truncation count and surface the drop:

```swift
        // Step 3: fit Σ pre-floor heat under the cap, by the selected strategy.
        let requestedHeat = fundable.reduce(0) { $0 + $1.weight }
        let qualifiedCount = fundable.count   // F5 contract: BEFORE any cap truncation
        var scaleApplied = requestedHeat > cap ? cap / requestedHeat : 1
```

then at `:189` and `:196`:

```swift
        var finalCaveat = caveat
        if qualifiedCount > fundable.count {
            finalCaveat += " \(qualifiedCount - fundable.count) further idea(s) cleared every gate but were TRUNCATED — the heat cap was reached first (concentrated mode). This plan is not the whole fundable set."
        }
```
```swift
                                 fundableCandidateCount: qualifiedCount)
```

**Verify:** extend `GeminiReportWave2Tests.knapsackTruncatesInsteadOfScaling` with `#expect(knap.fundableCandidateCount == unif.fundableCandidateCount)` and `#expect(knap.caveat.contains("TRUNCATED"))`. `.uniformScale` callers are byte-identical because `qualifiedCount == fundable.count` there.

**This one needs your judgement**, and it is the only finding in this review that touches the honesty floor. The `fundableCandidateCount` half is an unambiguous contract violation and I would just fix it. The caveat *wording* changes what the card asserts, which is yours.

---

## C2 | LOW | CERTAIN | `StockSageRebalance.swift:57`

```swift
        trades.sort { abs($0.deltaValue) > abs($1.deltaValue) }   // biggest moves first
```

`Array.sort(by:)` is not documented as stable, and ties on `|deltaValue|` are ordinary (two symbols at symmetric drift, or an equal-weight book). Same defect class `StockSageCapitalAllocator.positionOrder` (`:199-211`) was explicitly written to fix, and `StockSageJournal.bySector` (`:811-813`) also guards.

**Why it matters:** the rebalance list can reorder between renders for identical inputs, and `RebalancePlan` is `Equatable` — an unstable order makes plan equality flaky.

```swift
        // Total order (same discipline as StockSageCapitalAllocator.positionOrder): magnitude
        // desc → symbol asc, so two symbols tying on |delta| can never swap between runs.
        trades.sort { $0.deltaValue.magnitude != $1.deltaValue.magnitude
                        ? abs($0.deltaValue) > abs($1.deltaValue)
                        : $0.symbol < $1.symbol }
```

---

# CONCURRENCY

## N1 | HIGH | CERTAIN | `StockSageStore.swift:1944`

Same finding as Q3 in Part 2 — the `refresh(scope:)` re-entrancy guard is released ~90 lines before the function commits, with `await healStaleQuotes()` still to come. Six callers, two of them on timers. Fix is `defer { isRefreshing = false }`. Full detail in Part 2.

## N2 | MEDIUM | CERTAIN | `StockSageLiveStream.swift:137-144`

The receive handler validates identity *before* the backoff sleep and never re-validates after it:

```swift
                case .failure:
                    self.isStreaming = false
                    guard self.wantsConnection else { return }
                    let delay = Self.backoffSeconds(attempt: self.reconnectAttempt)
                    self.reconnectAttempt += 1
                    try? await Task.sleep(for: .seconds(delay))
                    if self.wantsConnection { self.openSocket() }
```

Textbook `@MainActor` re-entrancy: up to 30s passes inside that `await`, during which `start(symbols:)` (fired by `.task(id: streamSubscriptionKey)`, `MarketsView.swift:414`) may already have opened a healthy socket. The stale continuation then tears it down — an avoidable disconnect on every symbol-set change coinciding with a backoff window.

`openSocket()` additionally cancels the old task and can bail without clearing it:

```swift
    private func openSocket() {
        task?.cancel(with: .goingAway, reason: nil)
        let key = StockSageEODHD.apiKey
        guard !key.isEmpty, let url = URL(string: "\(Self.host)?api_token=\(key)") else { return }
```

leaving `task` pointing at a cancelled socket whose failure handler still matches `self.task === t` — a missing key yields a permanent 30s reconnect loop.

```swift
                    try? await Task.sleep(for: .seconds(delay))
                    // RE-VALIDATE ACROSS THE AWAIT: `start(symbols:)`/`stop()` can have run during
                    // the backoff, so `t` may no longer be the socket this store wants. Reconnecting
                    // off a stale continuation would cancel a healthy live socket.
                    guard self.wantsConnection, self.task === t else { return }
                    self.openSocket()
```
```swift
    private func openSocket() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil                                  // never leave a cancelled socket as `task`
```

---

# PERFORMANCE

## P1 | CRITICAL | CERTAIN | `MarketsView.swift:407,410` × `StockSageStore.swift:1744`

Same root as Q2 in Part 2, stated here as the perf finding it also is. `.task(id: store.lastUpdated)` is keyed on a value `applyLiveTick` mutates on every trade tick, and `refreshCatalysts()` decodes the whole multi-MB history cache in a `Task.detached` that ignores cancellation. Every cancelled instance still runs to completion, so decodes pile up concurrently.

Note the author already solved this exact problem three lines below, for the socket: `streamSubscriptionKey` (`:177-179`) exists precisely so the stream isn't rebuilt per tick. The catalyst task and the haptic were missed. Fix in Part 2 (Q2), plus the cancellation guard:

```swift
    func refreshCatalysts() async {
        let advBySymbol = liquidity.mapValues(\.avgDollarVolume)
        let found = await Task.detached {
            guard let histories = StockSageHistoryCache.load()?.priceHistories(), !histories.isEmpty else { return [StockSageCatalyst.Signal]() }
            return StockSageCatalyst.scan(histories, advDollarBySymbol: advBySymbol)
        }.value
        guard !Task.isCancelled else { return }   // a superseded run must not stomp fresher catalysts
        catalysts = found
    }
```

## P2 | HIGH | CERTAIN | `MarketsView.swift:5201-5213` + `StockSageCorrelationCluster.swift:70-80`

The whole capital allocator runs inside `body`:

```swift
// MarketsView.swift:5211
            let plan = StockSageCapitalAllocator.allocate(ideas: shariaScreenedIdeas, account: acct, calibration: store.convictionCalibration, regime: store.regime,
                                                          fxRatesToUSD: sizingFXRates(for: shariaScreenedIdeas.map(\.symbol)),
                                                          strategy: strategy)
```

and `allocate` contains an unbounded pairwise correlation step (`StockSageCapitalAllocator.swift:127-131`) — `correlationMatrix` is O(F²), `StockSagePortfolioAnalytics.correlation` (`:188`) allocates two arrays per pair, and the greedy clique search `StockSageCorrelationCluster.largest` (`:32-48`) does `members.map { m.matrix[$0][c] }.min()`, an array allocation per candidate per growth step.

`body` is invalidated by hover (`:4847-4848`) and by every `applyLiveTick`.

**Why the existing probe cleared it — this is the important part.** `StockSagePerfProbeTests.oneWholeRenderPass` *does* call `allocate(...)` at `:185`. But its fixture is:

```swift
// StockSageTestFixtures.swift:137-142
        return StockSageIdea(
            symbol: symbol, market: symbol, price: price,
            advice: TradeAdvice(…),
            spark: [])
```

With `spark: []`, `dailyReturns([])` returns `[]`, so `correlationAdjustedWeights` hits its guard and returns immediately:

```swift
// StockSageCorrelationCluster.swift:74-75
        let minLen = returns.map(\.count).min() ?? 0
        guard minLen >= 2 else { return weights }
```

**The entire correlation stage is skipped in the probe.** The measured number is not the production cost. In production every idea carries a real spark (`StockSageStore.swift:1059-1060`).

**Fix, two parts.** (1) Memoize the plan store-side using the codebase's own precedent (`JournalCalibrationCache`, `:1244-1261`):

```swift
    /// Allocator memo (same shape/rationale as JournalCalibrationCache above): `allocate` is an
    /// O(F²) correlation pass over the fundable set, and `capitalAllocationCard` reads it from
    /// `body` — so a hover or a streamed tick re-ran the whole thing.
    struct AllocationPlanCache {
        private var key: AnyHashable?
        private var cached: CapitalAllocation?
        private(set) var computeCount = 0
        nonisolated mutating func value(ideas: [StockSageIdea], account: Double,
                                        calibration: StockSageConvictionCalibration?,
                                        regime: MarketRegime?, fx: [String: Double],
                                        strategy: StockSageCapitalAllocator.AllocationStrategy) -> CapitalAllocation {
            let k = AnyHashable([
                AnyHashable(ideas.map { "\($0.symbol)|\($0.price)|\($0.advice.conviction)|\($0.advice.action.rawValue)" }),
                AnyHashable(account), AnyHashable(calibration?.sampleSize ?? -1),
                AnyHashable(regime?.state.rawValue ?? ""), AnyHashable(fx.map { "\($0)=\($1)" }.sorted()),
                AnyHashable(strategy.rawValue),
            ])
            if key != k {
                cached = StockSageCapitalAllocator.allocate(ideas: ideas, account: account,
                                                            calibration: calibration, regime: regime,
                                                            fxRatesToUSD: fx, strategy: strategy)
                key = k; computeCount += 1
            }
            return cached!
        }
    }
    private var allocationPlanCache = AllocationPlanCache()

    func allocationPlan(ideas: [StockSageIdea], account: Double, fx: [String: Double],
                        strategy: StockSageCapitalAllocator.AllocationStrategy) -> CapitalAllocation {
        allocationPlanCache.value(ideas: ideas, account: account, calibration: convictionCalibration,
                                  regime: regime, fx: fx, strategy: strategy)
    }
```

(2) Remove the per-candidate allocation in the clique search (`StockSageCorrelationCluster.swift:37-43`):

```swift
                var inMembers = [Bool](repeating: false, count: n)
                for m0 in members { inMembers[m0] = true }
                for c in 0..<n where !inMembers[c] {
                    var minToMembers = Double.greatestFiniteMagnitude
                    for m0 in members { minToMembers = Swift.min(minToMembers, m.matrix[m0][c]) }
                    if minToMembers >= threshold, pick == -1 || minToMembers > pickMin {
                        pick = c
                        pickMin = minToMembers
                    }
                }
```

**Verify:** first prove the gap — change `StockSageTestFixtures` to build a real spark (e.g. `spark: (0..<32).map { 100 + Double($0 % 7) }`) and re-run `wholeRenderEquivalentAt2400ScaleColdStart`; the `[PERF]` number will jump. Then assert `store.allocationPlan(...)` called 3× with identical inputs leaves `computeCount == 1`.

## P3 | MEDIUM | CERTAIN | `MarketsView.swift:1262`

```swift
    private func currentPrice(_ symbol: String) -> Double? {
        store.symbols.first { $0.symbol.uppercased() == symbol.uppercased() }?.latest?.price
    }
```

`symbol.uppercased()` is re-evaluated inside the closure, so each call is `2 × |store.symbols|` String allocations over the ~901-name board. Called from inside `ForEach` row builders: `priceAlertRow` (`:1123`, plus a second full scan at `:1122`), `journalOpenRow` (`:3060`, `:3065`), `positionRow` (`:1593`), and `fxRateToUSD` (`:1294-1295`) — where both calls **always miss**, since FX pairs deliberately left the universe (`StockSageStore.swift:104-110`), before falling through to the `infraFX` dictionary. That runs per idea card via `sizingFXRates` (`:4364`).

So every `.SR` idea card pays ~3,600 String allocations to reach a dictionary lookup that would have answered immediately. This is the O(n²)-in-ForEach the codebase already fixed elsewhere (`StockSageJournal.historyBySymbol`, `StockSagePortfolio.holdingBySymbol` — "PERF-2/4: one O(trades)/O(positions) pass for the whole board instead of one per card"); `currentPrice` was left behind.

```swift
// StockSageStore.swift — beside `symbols`
    /// Uppercased-symbol → index into `symbols`. Rebuilt only by the shape-changing writers
    /// (replaceAll / loadCachedQuotes / seedSampleData); the in-place per-row replacements
    /// (applyLiveTick, mergeLiveQuote, mergeLiveQuotes) preserve order, so the index survives them.
    private(set) var symbolIndex: [String: Int] = [:]
    private func rebuildSymbolIndex() {
        symbolIndex = Dictionary(symbols.enumerated().map { ($0.element.symbol.uppercased(), $0.offset) },
                                 uniquingKeysWith: { a, _ in a })
    }
    /// O(1) board price lookup — the per-row `store.symbols.first { … }` scan it replaces was O(n)
    /// with two String allocations per element, called once per ForEach row.
    func latestPrice(_ symbol: String) -> Double? {
        symbolIndex[symbol.uppercased()].flatMap { symbols[$0].latest?.price }
    }
    func isOnBoard(_ symbol: String) -> Bool { symbolIndex[symbol.uppercased()] != nil }
```

Call `rebuildSymbolIndex()` at the end of `replaceAll(_:isSample:)` (`:2047`), `loadCachedQuotes()` (`:333`) and `seedSampleData()` (`:2059`). Then `currentPrice` becomes `store.latestPrice(symbol)` and `:1122` becomes `store.isOnBoard(a.symbol)`.

---

# MEMORY

## M1 | MEDIUM | CERTAIN | `StockSagePaperTrader.swift:286-355`

`StockSagePaperTradeStore.trades` has no cap or pruning. Its only shrinking APIs are user-driven `remove(_:)` (`:318`) and `reset()` (`:320`); everything else grows it, and `save()` (`:338-355`) decodes the whole on-disk array, merges, then re-encodes to `UserDefaults`.

`StockSageStore.updatePaperTrades` (`:792-800`) runs at every scan end, and `step` opens a paper trade for every long-actionable idea without an open position, from a 901-name universe. Over months that is thousands of records in a `UserDefaults` value — memory-resident for the process lifetime — paying a full decode + encode per scan. Every render also walks the array several times (`:258-259`, `:270`, `MarketsView.swift:2062`, `:2070`). The store already carries a MEM-01a fix for the per-call re-encode; the unbounded array was not addressed.

```swift
    /// MEM: the paper book is append-only across scans (one open per long-actionable idea, ~900
    /// candidates/scan) and every save re-encodes the whole array. Keep every OPEN trade — they
    /// are live positions — plus the newest `maxClosedRetained` closes; the forward stats
    /// (forwardStats / scoreboard / weeklyDigest) all read far fewer than this.
    static let maxClosedRetained = 500

    private func prune() {
        let closed = trades.filter { !$0.isOpen }
        guard closed.count > Self.maxClosedRetained else { return }
        let keep = Set(closed.sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
                             .prefix(Self.maxClosedRetained).map(\.id))
        trades = trades.filter { $0.isOpen || keep.contains($0.id) }
    }
```

Call `prune()` at the top of `save(reconciling:)` (`:338`), before the disk-reconcile block.

---

# DEAD CODE

Verified: `grep -rlw <symbol> StockSage/Sources` returns only the defining file for each. All are exercised by tests, so this is dead *production* code, not untested code.

| Symbol | File | Lines | Prod callers |
|---|---|---|---|
| `StockSageAllocationOptimizer` + result type | `StockSageAllocationOptimizer.swift` | 217 | 0 |
| `StockSagePBO` | `StockSagePBO.swift` | 121 | 0 |
| `StockSageCryptoLiquidityGate` | `StockSageCryptoLiquidityGate.swift` | 89 | 0 |
| `StockSageRelativeStrength` + rank type | `StockSageRelativeStrength.swift` | 73 | 0 |
| `StockSageCryptoFunding` + drag type | `StockSageCryptoFunding.swift` | 69 | 0 |
| `StockSageCapitalAllocator.rebalanceToEdge` + plan | `:299-443, 462-466` | ~150 | 0 (prose mention only) |
| `StockSageCapitalAllocator.suggestAdd` + suggestion | `:218-268, 446-457` | ~62 | 0 (prose only) |
| `StockSageKelly.portfolioCap` + `PortfolioKelly` | `:41-51, 107-120` | ~24 | 0 |
| `StockSageMenuBarLabel` / `StockSageMenuBarContent` | `App/StockSageMenuBar.swift` | 60 | 0 — **documented as deliberately parked** (`StockSageApp.swift:97-101`) |

**Do not bulk-delete.** `rebalanceToEdge` carries three distinct adversarial-review fixes in its doc comment (new-vs-new clique de-weighting, per-position concentration ceiling, the honest "concentration unavoidable" refusal) — deleting it discards litigated reasoning. Add `// UNWIRED (2026-07-28 audit): zero production callers; kept for <reason>. Wire or delete.` to each and treat the list as a roadmap question. Four of them (`AllocationOptimizer`, `PBO`, `CryptoLiquidityGate`, `RelativeStrength`) are finished features that never got a surface — see Part 4, F1. Only `StockSageMenuBar` is already documented as parked.

---

# DELIBERATE, NOT BUGS — don't re-investigate

1. **`StockSageAdvisor` short-side asymmetry** (`:323-335`), `>= 0.5` for `.strongBuy` vs strict `< -0.5` for `.sell`. Documented (F34: short financing + unbounded loss), pinned by `actionForScore` boundary tests.
2. **Single-tier vol brake** (`StockSageCapitalAllocator.swift:102-115`) — `Swift.min(scalerBrake, regimeBrake)` rather than composing them makes a doubly-volatile name 4× larger. **OWNER-FORCED 2026-07-28** with the measured number in the comment and re-derived pins in `StockSageMultiBrakeTests`. Do not "fix".
3. **Turn-of-month tilt ON with a powered null** (`StockSageAdvisor.swift:91-108`) — RATIFIED 2026-07-09 as a disclosed owner preference, pinned by `StockSageTomGateTests`.
4. **`weeklyR` on the earnings/liquidity-unaware lane while `weeklyRNet` uses the aware one** (`StockSageExpectedValue.swift:1174-1185`) — deliberate, for `VelocityHistory` cross-session continuity; `weeklyRGrossSameBasket` exists so a paired display never mixes baskets.
5. **`evRankKey`'s `netRatio` defaulting to 1 when `netEVR` is nil** (`:426-437`) — the nil path is documented unreachable given the upstream `ev(for:)` guard.
6. **`nonisolated(unsafe) static var` flags** (`StockSageAdvisor.swift:89,108`; `StockSageConvictionCalibration.swift:125`; `StockSageStore.swift:1278`; `ToolPolicy.swift:15`) — documented test/QA seams, written only by tests or the `--qa` path. No live race.
7. **`fastLaneConcentration`'s `counts.max(by:)` over a Dictionary** (`StockSageExpectedValue.swift:1263`) — a tie yields a per-launch-random `dominantClass`, but all three render sites are gated on `isConcentrated`, which requires one class only. Unobservable. Checked because `StockSageJournal.bySector:811-813` documents exactly this hazard; it doesn't apply here.
8. **Reconciling saves without tombstones** (`StockSagePaperTrader.swift:314-317`) — the resurrect-under-concurrent-delete ceiling is explicitly acknowledged. Known and accepted.
9. **`StockSageBacktester.trailLevels` is O(n²)** (`:368-388`) — only reachable via `.chandelierTrail`, used solely from the user-triggered strategy backtest, off-main in a `Task.detached`. Not on a hot path.
10. **`JournalCalibrationCache` comparing the whole `[TradeRecord]` array by value on every read** (`:1250-1259`) — deliberate F12 trade-off; value-keying is what makes any journal mutation self-invalidating with no hooks to forget.

---

## One meta-note worth more than any single finding

`StockSagePerfProbeTests` is the file that concluded "memoization NOT justified — the honest null" for `displayedIdeas`. Its fixture (`StockSageTestFixtures.swift:142`) builds `spark: []`, which silently disables the allocator's entire correlation stage. The null may well still hold for `rankByVelocity` — but it was never measured for `allocate`, and the probe cannot see the cost it is cited to rule out. Fix the fixture before trusting that file's next verdict.

---

# Part 6 — Prioritised implementation plan

## Stage 1 — Stop the noise (do tonight, all independent)

| # | Finding | File | Size |
|---|---|---|---|
| 1 | **N2** — add the missing `StockSageNotifyPrefs` check to `runWatchlistCycle` | `StockSageMonitor.swift:234` | 1 line |
| 2 | **N1 + N3 + N4** — add `StockSageAlertBudget.swift`, route the monitor through it | new file + `StockSageMonitor.swift` | ~250 new lines, ~40 changed |
| 3 | **Q3 / N1(conc)** — `defer { isRefreshing = false }` | `StockSageStore.swift:1939,1944` | 2 lines |
| 4 | **P1 / Q2** — retarget `.task(id:)` and `.sensoryFeedback` to `store.ideasUpdated`, add the cancellation guard | `MarketsView.swift:407,410` + `StockSageStore.swift:1759` | ~6 lines |

Item 1 is the cheapest real win in the review — if you have been trying to quiet the app from Settings while in watchlist-only mode, the switch has been doing nothing. Item 4 is a live regression from the same-day live-stream commit and is the single biggest performance win.

Do item 2 last of the four; the other three are one-liners that shouldn't wait behind a new file.

## Stage 2 — Stop the stale prices (independent of Stage 1, and of each other)

| # | Finding | File |
|---|---|---|
| 5 | **Q1** — scope + cap + back off `healStaleQuotes` | `StockSageStore.swift:1897` |
| 6 | **Q4** — persist `marketTime` in the quote cache | `StockSageQuoteCache.swift` |
| 7 | **Q6** — `addSymbol` carries `marketTime` | `StockSageStore.swift:413` |
| 8 | **Q7** — max-merge `quoteAsOf` instead of assigning | `StockSageStore.swift:2029` |
| 9 | **Q9** — mirror refresh prices onto ideas | `StockSageStore.swift:2021` |
| 10 | **Q10** — EODHD parser parity with the Yahoo parser | `StockSageEODHD.swift:60` |
| 11 | **Q5** — live-stream auth classifier + silence watchdog | `StockSageLiveStream.swift` |
| 12 | **Q8** — banner fail-closed | `MarketsView.swift:567,803` |

**Ordering constraint:** 12 must land *after* 6, or the banner will honestly-but-loudly report "price age unknown" on every launch until the cache carries timestamps. Everything else in this stage is order-free.

Items 5 and 6 together are the biggest reduction in feed load in the review, which means they are also the biggest reduction in 429s, which is the root of the staleness you set out to fix.

## Stage 3 — Performance and hygiene

| # | Finding | File |
|---|---|---|
| 13 | **P2 fixture** — give `StockSageTestFixtures.idea` a real spark, re-baseline the perf probe | `StockSageTestFixtures.swift:142` |
| 14 | **P2** — allocator memo + clique-search allocation removal | `StockSageStore.swift`, `StockSageCorrelationCluster.swift` |
| 15 | **P3** — store-side symbol index | `StockSageStore.swift`, `MarketsView.swift:1262` |
| 16 | **M1** — paper-store prune | `StockSagePaperTrader.swift:338` |
| 17 | **N2(conc)** — re-validate the socket across the backoff await | `StockSageLiveStream.swift:137` |
| 18 | **C2** — total-order the rebalance sort | `StockSageRebalance.swift:57` |

Do 13 before 14 — otherwise you cannot measure whether 14 helped, and the probe will keep reporting a number that excludes the cost you're trying to remove.

## Stage 4 — UI/UX (Part 3, in its own order)

Part 3 ships its own prioritised list. The two that dominate: the ranked idea list being the 17th element on the tab the app lands on, and the ~138 `.help(…)` tooltip sites that are macOS-only and therefore silently drop every explanation on iPhone.

## Stage 5 — Features (Part 4)

F1 first (four finished engines, no surface — the work is already paid for), then F3 (session-aware notification windows, which completes Stage 1), then F2, F4, F5.

---

# What needs your decision

Five things. I have not assumed on any of them.

**1. The monitor's cadence — N5.** The monitor polls every 45s; your Settings copy advertises 4.75 minutes; they are two different loops. Making them one number is a trading decision, not an engineering one: at 285s a stop breach can go unnoticed for up to ~4.75 minutes instead of ~45 seconds. Options: keep 45s and accept the feed load (the budget still bounds the *notifications*); move to 285s and accept the latency; or split — fast for ideas you hold, slow for everything else. Say which and I will write it.

**2. The budget defaults.** I chose 30-minute per-symbol cooldown, 12/hour global cap, 0.4% hysteresis band, digest off. The band is sized against Tadawul's 0.01-SAR tick on a ~20 SAR name (~8 ticks of genuine recovery to re-arm). All four are Settings-exposed, so these are starting points rather than commitments — but they are *your* starting points to pick, because they trade missed events against quiet.

**3. C1's caveat wording.** `.greedyKnapsack` is the shipping default and silently drops ideas that cleared every gate. The `fundableCandidateCount` contract violation I would just fix. The *wording* of the new caveat changes what the capital-allocation card asserts, and that is an honesty-floor decision only you make.

**4. Dead code — delete or schedule?** Four of the nine entries (`AllocationOptimizer`, `PBO`, `CryptoLiquidityGate`, `RelativeStrength`) are finished, tested engines that never got a UI surface. `PBO` and `RelativeStrength` in particular would *strengthen* the honesty floor (Part 4, F1). `CryptoLiquidityGate` was orphaned by the 2026-07-16 scope change and is genuinely dead. This is a roadmap question, not a cleanup one.

**5. Q11 — cache retention.** The fix changes what the disk cache retains after a throttled sweep (data retention, not a displayed number). If you'd rather the board and the cache stay byte-identical, skip it and accept the cold-launch degradation.

---

# What I checked and am NOT reporting

So you don't re-investigate: the "DELIBERATE, NOT BUGS" lists at the end of Part 2 and Part 5 name 20 things that look wrong out of context and are pinned by a test, an owner signature, or a documented trade-off. The single-tier vol brake (`StockSageCapitalAllocator.swift:102-115`) is the one most likely to be re-flagged by the next reviewer — it is owner-forced 2026-07-28 with the measured number in the comment. It is not a bug.

Also not reported, having been checked: the negative-price sign inversion (`StockSageModels.swift:44` already uses `abs(previousPrice)`, owner-signed), the fail-open staleness gate (`StockSageModels.swift:85` is fail-*closed*), and the heat-invariant breach (pinned by `GeminiReportWave2Tests`). Those three remain non-existent, as you said.
