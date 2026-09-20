import Foundation

nonisolated enum StockSageResearchFreshness {
    struct MarketStatus: Equatable, Sendable {
        enum Tone: Sendable { case green, amber, red, gray }
        let phaseLabel: String
        let clock: String
        let next: String
        let caveat: String
        let tone: Tone
    }

    static func market(at date: Date) -> MarketStatus {
        let state = StockSageMarketHours.nasdaqState(at: date, calendar: Calendar(identifier: .gregorian))
        let known = StockSageMarketHours.nasdaqDay(at: date) != nil
        let tone: MarketStatus.Tone
        if !known { tone = .gray }
        else {
            switch state.phase {
            case .open: tone = .green
            case .preMarket, .afterHours: tone = .amber
            default: tone = .red
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")!
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm z"
        return .init(phaseLabel: known ? state.phaseLabel : "Session calendar unavailable",
                     clock: formatter.string(from: date),
                     next: state.nextTransition.map { formatter.string(from: $0) } ?? "Unavailable",
                     caveat: state.caveat, tone: tone)
    }

    static func age(_ date: Date, at now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 2) else { return "clock mismatch" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h \(Int(seconds / 60) % 60)m ago" }
        return "\(Int(seconds / 86_400))d \(Int(seconds / 3600) % 24)h ago"
    }

    static func change(from previous: StockSageHorizonResearch.Result?, to current: StockSageHorizonResearch.Result) -> String {
        guard let previous else { return "New listing in this run; no prior result to compare." }
        let old = previous.verdict?.action.rawValue ?? "Incomplete"
        let new = current.verdict?.action.rawValue ?? "Incomplete"
        var parts = [old == new ? "Opinion unchanged (\(new))." : "Opinion \(old) → \(new)."]
        if let a = previous.referenceClose, let b = current.referenceClose {
            if a.at == b.at, a.value == b.value { parts.append("Same completed daily bar; unchanged price is expected while markets are closed.") }
            else if a.at == b.at {
                parts.append("Same-session reference price was revised; a common split-adjustment basis is unverified, so no price-change percentage is shown.")
            } else {
                parts.append("Reference session changed; a common split-adjustment basis is unverified, so no price-change percentage is shown.")
            }
        }
        if let oldNews = previous.newestNewsAt, let newNews = current.newestNewsAt {
            parts.append(newNews > oldNews ? "Newer article retained." : newNews == oldNews ? "Newest retained article date unchanged." : "Newest retained article is older; check source coverage.")
        }
        parts.append("Previous result \(age(previous.at, at: current.at)).")
        return parts.joined(separator: " ")
    }
}
