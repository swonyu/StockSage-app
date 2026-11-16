import Foundation

/// Shared by the app and its widget: format a known percentage without trapping
/// on Double-to-Int conversion or printing a non-finite/unknown value as zero.
nonisolated enum StockSageRiskDisplay {
    static func percentageText(_ percentage: Double) -> String? {
        guard percentage.isFinite, percentage >= 0 else { return nil }
        if percentage == 0 { return "0.0" }
        if percentage < 0.1 { return "<0.1" }
        if percentage >= 1_000_000 { return String(format: "%.2e", percentage) }
        return String(format: "%.1f", percentage)
    }
}

/// What the home-screen widget shows — written by the app, read by the widget extension.
///
/// WHY A SNAPSHOT AND NOT A LIVE READ: a widget process is given a few seconds and a few tens of
/// MB. It cannot run the advisor over ~900 names, cannot hold a WebSocket, and must never make the
/// user wait. So the app writes this small record after every scan and the widget renders exactly
/// what it finds — no engine, no network, no recomputation.
///
/// THE HONESTY PROBLEM A WIDGET CREATES: a number on the home screen looks current by virtue of
/// being on the home screen. This one often is not — iOS decides when a widget reloads, and it can
/// be hours. So `asOf` is not decoration: `age` and `isStale` exist so the widget can SAY how old
/// it is, and `isSampleData` rides along so a demo board can never masquerade as a real one.
/// `nonisolated` is load-bearing, not decoration: this module defaults to main-actor isolation, so
/// the synthesized Codable conformance would be main-actor-isolated too — and the widget decodes
/// this from its OWN process, off the main actor, where an isolated conformance cannot be used.
nonisolated struct StockSageWidgetSnapshot: Codable, Sendable, Equatable {

    /// The App Group both the app and the widget read. A widget extension is a separate process
    /// with its own container, so a plain UserDefaults write is invisible to it — this suite is
    /// the only shared surface, and it requires a PAID developer account to exist at all.
    nonisolated static let appGroup = "group.SA.StockSageX"
    nonisolated static let defaultsKey = "stocksage.widget.snapshot.v1"

    /// When the app last completed a scan. NOT when the widget last drew.
    let asOf: Date
    /// Highest-expected-value idea at `asOf`, when there was one.
    let bestSymbol: String?
    let bestAction: String?
    /// Ordinal conviction 1…5 — the same ordinal scale the board shows, never a false-precision
    /// percentage.
    let bestStrength: Int?
    /// Open paper positions, and what fraction of the account they risk in total.
    ///
    /// `portfolioHeatPct` is OPTIONAL because heat is only meaningful against an account size the
    /// owner has actually entered. Writing 0 when it is unknown would render "0.0% of 8%" — a
    /// specific, reassuring, and false claim. nil renders an explicit unavailable status.
    let openPositions: Int?
    let portfolioHeatPct: Double?
    let heatCapPct: Double
    /// Resolved paper closes toward a first Deflated-Sharpe reading, and how many that takes.
    let forwardCloses: Int?
    let forwardNeeded: Int
    /// True when the board behind this was the built-in sample, not live quotes.
    let isSampleData: Bool
    /// nil for older snapshots that did not capture cache provenance.
    var isCachedData: Bool? = nil
    /// Only corrected, complete calculations set this true. Older snapshots may
    /// contain partial FX totals, so their numeric heat alone is not trustworthy.
    var portfolioHeatIsComplete: Bool? = nil

    /// Beyond this, the widget stops presenting the figures as current.
    nonisolated static let staleAfter: TimeInterval = 3600 * 6

    nonisolated func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(asOf) }

    /// Stale when old — and ALSO when `asOf` is in the future, which means a clock changed under
    /// us. "Somehow newer than now" is not evidence of freshness.
    nonisolated func isStale(now: Date = Date()) -> Bool {
        let a = age(now: now)
        return !a.isFinite || a < 0 || a >= Self.staleAfter
    }

    /// Age in the plain words a person reads at a glance. Never renders negative time.
    nonisolated func ageText(now: Date = Date()) -> String {
        let secs = age(now: now)
        guard secs.isFinite else { return "time unverified" }
        guard secs >= 0 else { return "clock changed" }
        guard let mins = Int(exactly: (secs / 60).rounded(.towardZero)) else { return "time unverified" }
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return days == 1 ? "yesterday" : "\(days)d ago"
    }

    nonisolated var sourceText: String {
        if isSampleData { return "SAMPLE" }
        guard let isCachedData else { return "SNAPSHOT" }
        return isCachedData ? "CACHED" : "LAST SCAN"
    }

    nonisolated var paperPositionsText: String {
        guard let openPositions else { return "Paper records unavailable" }
        return "Paper · \(openPositions) open"
    }

    nonisolated var forwardProgressText: String? {
        guard let forwardCloses else { return "Forward record unavailable" }
        return forwardCloses < forwardNeeded ? "Paper forward test \(forwardCloses)/\(forwardNeeded)" : nil
    }

    /// Heat as a fraction of the cap, clamped to [0, 1] for a progress bar. Returns nil rather
    /// than a misleading 0 when the cap is absent or degenerate — a full bar and an undrawable
    /// bar must not look the same.
    nonisolated var heatFractionOfCap: Double? {
        guard portfolioHeatIsComplete == true,
              let heat = portfolioHeatPct, heat.isFinite, heat >= 0,
              heatCapPct.isFinite, heatCapPct > 0 else { return nil }
        return Swift.min(1, heat / heatCapPct)
    }

    /// Whether a known, complete total has reached the displayed reference cap.
    nonisolated var isAtHeatCap: Bool {
        guard portfolioHeatIsComplete == true,
              let heat = portfolioHeatPct, heat.isFinite, heat >= 0,
              heatCapPct.isFinite, heatCapPct > 0 else { return false }
        return heat >= heatCapPct
    }

    nonisolated var paperHeatText: String {
        guard portfolioHeatIsComplete == true, let heat = portfolioHeatPct,
              let percentage = StockSageRiskDisplay.percentageText(heat),
              let cap = StockSageRiskDisplay.percentageText(heatCapPct), heatCapPct > 0 else {
            return "Paper stop risk unavailable"
        }
        return "Paper stop risk \(percentage)% of account; cap \(cap)%"
    }

    // MARK: - Shared storage

    /// Written by the app after a scan. A failure here is silent BY DESIGN: the widget missing an
    /// update is a cosmetic problem, and it must never be allowed to disturb the app's own run.
    nonisolated func save() {
        guard let defaults = UserDefaults(suiteName: Self.appGroup),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Read by the widget. nil when the app has not written one yet — the widget then says so
    /// rather than rendering zeros, because "no data" and "no positions" are different facts.
    nonisolated static func load() -> StockSageWidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(StockSageWidgetSnapshot.self, from: data)
    }
}
