import Foundation

/// Pure NASDAQ-session arithmetic for classifying captured research events against a requested
/// holding horizon. The published 2026 calendar remains the sole session authority; this type
/// returns `nil` rather than inferring a weekend, holiday, early close or unsupported year.
nonisolated enum StockSageResearchHorizonCalendar {
    enum SourceState: String, Sendable, Equatable {
        case current
        case stale
        case preAI
    }

    /// Provider certainty is retained independently from timing. An estimated date never becomes
    /// confirmed merely because it falls inside the holding-risk window.
    enum Confirmation: String, Sendable, Equatable, Hashable {
        case confirmed
        case tentative
        case projected
        case unknown
    }

    /// A date-only value preserves the provider's calendar components. Its source time zone is
    /// explicit provenance and validation input; the date is never converted through midnight UTC.
    enum Point: Sendable, Equatable {
        case dateOnly(String, sourceTimeZone: String)
        case instant(Date)
    }

    enum EventTime: Sendable, Equatable {
        case exact(Point)
        case range(start: Point, end: Point)
        case unknown
    }

    enum Placement: String, Sendable, Equatable, Hashable {
        case futureWithinRiskThroughEarliestExit
        case futureWithinRiskAfterEarliestExit
        case futureOutsideRisk
        case past
        case unknown
    }

    struct Event: Sendable, Equatable {
        let time: EventTime
        let sourceState: SourceState
        let confirmation: Confirmation

        init(time: EventTime, sourceState: SourceState = .current,
             confirmation: Confirmation = .unknown) {
            self.time = time
            self.sourceState = sourceState
            self.confirmation = confirmation
        }
    }

    /// A bounded, normalized view of captured provider evidence. `product` remains attached so an
    /// instrument classifier can exclude inapplicable products before the prompt is assembled.
    struct CapturedEvent: Sendable, Equatable {
        let product: StockSageBenzinga.Product
        let event: Event
    }

    struct Classification: Sendable, Equatable {
        let placement: Placement
        let confirmation: Confirmation
    }

    struct HoldingWindow: Sendable, Equatable {
        let assessmentAt: Date
        let earliestExitSession: Int
        let latestExitSession: Int
        let earliestExitAt: Date
        let latestExitAt: Date
        let earliestExitDate: String
        let latestExitDate: String
    }

    /// Converts only already-captured evidence. The caller remains responsible for the snapshot's
    /// request-level freshness check; `StockSageBenzinga.projection` supplies the authoritative
    /// page/status/credential/subject filtering. A stale catalyst record is never reintroduced.
    static func capturedEvents(
        benzinga: StockSageBenzinga.Snapshot,
        catalyst: StockSageCatalystRecordCache.Record?,
        at assessmentAt: Date,
        excludingProducts: Set<StockSageBenzinga.Product> = []
    ) -> [CapturedEvent] {
        guard assessmentAt.timeIntervalSince1970.isFinite,
              benzinga.capturedAt.timeIntervalSince1970.isFinite,
              benzinga.capturedAt <= assessmentAt else { return [] }
        let temporalProducts: [StockSageBenzinga.Product] = [.earnings, .guidance, .ratings]
        var result: [CapturedEvent] = []

        // The capture is bounded to three records per product. A generous independent allowance
        // prevents optional prompt trimming from changing the mandatory timing classification.
        let freshRecordKeys = Set(benzinga.pages.flatMap { page -> [String] in
            let age = assessmentAt.timeIntervalSince(page.checkedAt)
            guard page.credentialGeneration == benzinga.credentialGeneration,
                  page.status == .answered || page.status == .partial,
                  (0..<page.query.product.cacheTTL).contains(age) else { return [] }
            return page.records.map { recordKey($0) }
        })
        if let projection = StockSageBenzinga.projection(
            benzinga, maximumUTF8Bytes: 1_000_000, maximumRecords: 27
        ) {
            for record in projection.records
            where temporalProducts.contains(record.product)
                && !excludingProducts.contains(record.product)
                && freshRecordKeys.contains(recordKey(record)) {
                let confirmation: Confirmation
                if record.product == .earnings {
                    if record.details.contains(where: { $0 == "Schedule: confirmed; not a beat claim." }) {
                        confirmation = .confirmed
                    } else if record.details.contains(where: { $0 == "Schedule: projected; not a beat claim." }) {
                        confirmation = .projected
                    } else {
                        confirmation = .unknown
                    }
                } else {
                    // Guidance and rating rows are provider claims with event dates, but carry no
                    // schedule-confirmation field in the captured contract.
                    confirmation = .unknown
                }
                let time = record.date.map {
                    // Benzinga's canonical YYYY-MM-DD parser validates the date in UTC. Keep those
                    // provider components; the optional release-time zone is a different field.
                    EventTime.exact(.dateOnly($0, sourceTimeZone: "UTC"))
                } ?? .unknown
                result.append(.init(product: record.product,
                                    event: .init(time: time, confirmation: confirmation)))
            }
        }

        if !excludingProducts.contains(.earnings), let catalyst,
           catalyst.symbol == benzinga.symbol.uppercased(),
           (0..<StockSageStore.earningsCheckTTL)
                .contains(assessmentAt.timeIntervalSince(catalyst.checkedAt)),
           let start = catalyst.earningsDate,
           catalyst.status == .dateKnown || catalyst.status == .projected {
            let confirmation: Confirmation
            switch catalyst.status {
            case .projected: confirmation = .projected
            case .dateKnown:
                confirmation = catalyst.confirmed == true ? .confirmed
                    : catalyst.confirmed == false ? .tentative : .unknown
            case .notApplicable, .unchecked: confirmation = .unknown
            }
            let startPoint = Point.dateOnly(providerDate(start), sourceTimeZone: "UTC")
            let time: EventTime
            if let end = catalyst.dateRangeEnd, end != start {
                time = .range(start: startPoint,
                              end: .dateOnly(providerDate(end), sourceTimeZone: "UTC"))
            } else {
                time = .exact(startPoint)
            }
            result.append(.init(product: .earnings,
                                event: .init(time: time, confirmation: confirmation)))
        }

        // A single captured schedule can appear in both provider evidence and the catalyst cache.
        // Deduplicate only identical timing/certainty tuples; never promote or rewrite certainty.
        var seen = Set<String>()
        return result
            .sorted { capturedKey($0) < capturedKey($1) }
            .filter { seen.insert(capturedKey($0)).inserted }
    }

    /// Mandatory prompt annotation. It is intentionally an aggregate rather than a second copy
    /// of each provider record. Zero classified rows is disclosed as unknown evidence, never as
    /// proof that the requested holding period contains no events.
    static func mandatoryFact(
        at assessmentAt: Date,
        horizon: StockSageHorizonResearch.Horizon,
        events: [CapturedEvent]
    ) -> String {
        guard let window = window(at: assessmentAt, horizon: horizon) else {
            return "Holding-risk calendar: unknown. The verified NASDAQ session calendar does not cover the full requested window. Captured event timing is unknown; missing or stale evidence is not proof of no events."
        }
        var placements: [Placement: Int] = [:]
        var confirmations: [Confirmation: Int] = [:]
        for captured in events {
            let classification = classify(captured.event, in: window)
            placements[classification.placement, default: 0] += 1
            confirmations[classification.confirmation, default: 0] += 1
        }
        func placementCount(_ placement: Placement) -> Int { placements[placement, default: 0] }
        func confirmationCount(_ confirmation: Confirmation) -> Int { confirmations[confirmation, default: 0] }
        let orderedEvents = events.sorted { capturedKey($0) < capturedKey($1) }
        let tags = orderedEvents.prefix(10).map { captured -> String in
            let classification = classify(captured.event, in: window)
            return "\(captured.product.rawValue) \(timeLabel(captured.event.time)) -> "
                + "\(placementLabel(classification.placement)); certainty "
                + classification.confirmation.rawValue
        }
        let tagText = tags.isEmpty ? "none classifiable from current captured records"
            : tags.joined(separator: " | ")
        let omittedTags = max(0, orderedEvents.count - tags.count)
        return "Holding-risk calendar (verified NASDAQ 2026 sessions): exposure begins \(assessmentAt.ISO8601Format()); earliest exit after \(window.earliestExitSession) session(s) at scheduled close \(window.earliestExitAt.ISO8601Format()); exposure continues through the latest exit after \(window.latestExitSession) session(s) at scheduled close \(window.latestExitAt.ISO8601Format()). Current captured event timing: through earliest exit \(placementCount(.futureWithinRiskThroughEarliestExit)), after earliest through latest \(placementCount(.futureWithinRiskAfterEarliestExit)), outside future window \(placementCount(.futureOutsideRisk)), past \(placementCount(.past)), unknown \(placementCount(.unknown)). Certainty retained: confirmed \(confirmationCount(.confirmed)), tentative \(confirmationCount(.tentative)), projected \(confirmationCount(.projected)), unknown \(confirmationCount(.unknown)). Compact event tags (maximum 10): \(tagText). Omitted event tags: \(omittedTags). Timing only; zero is not proof of no events."
    }

    private struct Day: Sendable, Equatable, Comparable {
        let year: Int
        let month: Int
        let day: Int

        static func < (lhs: Day, rhs: Day) -> Bool {
            (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
        }

        var string: String { String(format: "%04d-%02d-%02d", year, month, day) }
    }

    private static var newYorkCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// The exposure begins at the assessment instant. A still-open trading session can be the
    /// first exit session; at or after its scheduled regular close, counting starts next session.
    /// Week means first/latest exits after one/seven sessions, fortnight after seven/fourteen.
    static func window(at assessmentAt: Date,
                       horizon: StockSageHorizonResearch.Horizon) -> HoldingWindow? {
        guard assessmentAt.timeIntervalSince1970.isFinite,
              StockSageMarketHours.nasdaqDay(at: assessmentAt) != nil else { return nil }
        let counts: (earliest: Int, latest: Int)
        switch horizon {
        case .week: counts = (1, 7)
        case .fortnight: counts = (7, 14)
        }
        let calendar = newYorkCalendar
        let assessmentDay = calendar.startOfDay(for: assessmentAt)
        var exits: [Date] = []
        // Fourteen sessions need at most twenty-eight ordinary calendar days. Forty is bounded
        // headroom for the verified holidays; reaching 2027 still fails through `nasdaqDay`.
        for offset in 0...40 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: assessmentDay),
                  let session = StockSageMarketHours.nasdaqDay(at: candidate) else { return nil }
            guard session.trading, let close = close(on: candidate, hour: session.regularClose,
                                                     calendar: calendar), close > assessmentAt else { continue }
            exits.append(close)
            if exits.count == counts.latest { break }
        }
        guard exits.count == counts.latest,
              let earliestDay = day(from: exits[counts.earliest - 1], calendar: calendar),
              let latestDay = day(from: exits[counts.latest - 1], calendar: calendar) else { return nil }
        return HoldingWindow(
            assessmentAt: assessmentAt,
            earliestExitSession: counts.earliest,
            latestExitSession: counts.latest,
            earliestExitAt: exits[counts.earliest - 1],
            latestExitAt: exits[counts.latest - 1],
            earliestExitDate: earliestDay.string,
            latestExitDate: latestDay.string
        )
    }

    static func classify(_ event: Event, in window: HoldingWindow) -> Classification {
        guard event.sourceState == .current else {
            return .init(placement: .unknown, confirmation: event.confirmation)
        }
        let resultPlacement: Placement
        switch event.time {
        case .unknown:
            resultPlacement = .unknown
        case .exact(let point):
            resultPlacement = placement(of: point, in: window)
        case .range(let start, let end):
            guard ordered(start, beforeOrEqualTo: end) == true else {
                return .init(placement: .unknown, confirmation: event.confirmation)
            }
            let first = placement(of: start, in: window)
            let last = placement(of: end, in: window)
            // A range crossing the assessment, earliest-exit or latest-exit boundary does not
            // establish which side the event occupies. Preserve it as unknown rather than choosing
            // the most favorable endpoint.
            resultPlacement = first == last ? first : .unknown
        }
        return .init(placement: resultPlacement, confirmation: event.confirmation)
    }

    private static func placement(of point: Point, in window: HoldingWindow) -> Placement {
        switch point {
        case .instant(let date):
            guard date.timeIntervalSince1970.isFinite else { return .unknown }
            if date < window.assessmentAt { return .past }
            if date <= window.earliestExitAt { return .futureWithinRiskThroughEarliestExit }
            if date <= window.latestExitAt { return .futureWithinRiskAfterEarliestExit }
            return .futureOutsideRisk
        case .dateOnly(let value, let sourceTimeZone):
            guard let eventDay = parseDateOnly(value, sourceTimeZone: sourceTimeZone) else { return .unknown }
            let calendar = newYorkCalendar
            guard let assessmentDay = day(from: window.assessmentAt, calendar: calendar),
                  let earliestDay = parseDateOnly(window.earliestExitDate, sourceTimeZone: calendar.timeZone.identifier),
                  let latestDay = parseDateOnly(window.latestExitDate, sourceTimeZone: calendar.timeZone.identifier) else {
                return .unknown
            }
            if eventDay < assessmentDay { return .past }
            // With no release time, an event dated on the assessment day could already have
            // happened. It cannot honestly be labeled future.
            if eventDay == assessmentDay { return .unknown }
            if eventDay < earliestDay { return .futureWithinRiskThroughEarliestExit }
            // Date-only evidence spans an unknown release time. On an exit date, it cannot
            // establish which side of the scheduled close contains the event.
            if eventDay == earliestDay || eventDay == latestDay { return .unknown }
            if eventDay < latestDay { return .futureWithinRiskAfterEarliestExit }
            return .futureOutsideRisk
        }
    }

    private static func ordered(_ start: Point, beforeOrEqualTo end: Point) -> Bool? {
        switch (start, end) {
        case (.instant(let lhs), .instant(let rhs)):
            guard lhs.timeIntervalSince1970.isFinite, rhs.timeIntervalSince1970.isFinite else { return nil }
            return lhs <= rhs
        case (.dateOnly(let lhs, let lhsZone), .dateOnly(let rhs, let rhsZone)):
            guard lhsZone == rhsZone,
                  let lhsDay = parseDateOnly(lhs, sourceTimeZone: lhsZone),
                  let rhsDay = parseDateOnly(rhs, sourceTimeZone: rhsZone) else { return nil }
            return lhsDay <= rhsDay
        default:
            return nil
        }
    }

    private static func parseDateOnly(_ value: String, sourceTimeZone: String) -> Day? {
        guard TimeZone(identifier: sourceTimeZone) != nil,
              value.utf8.count == 10 else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].utf8.count == 4, parts[1].utf8.count == 2,
              parts[2].utf8.count == 2,
              parts.allSatisfy({ $0.unicodeScalars.allSatisfy { (48...57).contains(Int($0.value)) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let dayValue = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: sourceTimeZone)!
        let components = DateComponents(timeZone: calendar.timeZone, year: year, month: month,
                                        day: dayValue, hour: 12)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date)
                == DateComponents(year: year, month: month, day: dayValue) else { return nil }
        return Day(year: year, month: month, day: dayValue)
    }

    private static func day(from date: Date, calendar: Calendar) -> Day? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return Day(year: year, month: month, day: day)
    }

    private static func close(on date: Date, hour: Int, calendar: Calendar) -> Date? {
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = hour
        parts.minute = 0
        parts.second = 0
        return calendar.date(from: parts)
    }

    private static func providerDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0,
                      values.day ?? 0)
    }

    private static func capturedKey(_ captured: CapturedEvent) -> String {
        func point(_ value: Point) -> String {
            switch value {
            case .dateOnly(let date, let zone): return "date:\(date):\(zone)"
            case .instant(let date): return "instant:\(date.timeIntervalSinceReferenceDate)"
            }
        }
        let timing: String
        switch captured.event.time {
        case .exact(let value): timing = point(value)
        case .range(let start, let end): timing = "range:\(point(start)):\(point(end))"
        case .unknown: timing = "unknown"
        }
        return "\(captured.product.rawValue)|\(timing)|\(captured.event.confirmation.rawValue)"
    }

    private static func recordKey(_ record: StockSageBenzinga.Record) -> String {
        "\(record.product.rawValue)|\(record.id)|\(record.revision)"
    }

    private static func timeLabel(_ time: EventTime) -> String {
        func point(_ value: Point) -> String {
            switch value {
            case .dateOnly(let date, let zone): return "\(date) [date-only \(zone)]"
            case .instant(let date): return "\(date.ISO8601Format()) [instant]"
            }
        }
        switch time {
        case .exact(let value): return point(value)
        case .range(let start, let end): return "\(point(start)) through \(point(end))"
        case .unknown: return "date unknown"
        }
    }

    private static func placementLabel(_ placement: Placement) -> String {
        switch placement {
        case .futureWithinRiskThroughEarliestExit: "within risk through earliest exit"
        case .futureWithinRiskAfterEarliestExit: "within risk after earliest exit"
        case .futureOutsideRisk: "future outside holding-risk window"
        case .past: "past before assessment"
        case .unknown: "timing unknown"
        }
    }
}
