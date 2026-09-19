import Foundation
import Testing
@testable import StockSage

@Suite("Research holding-risk calendar")
struct StockSageResearchHorizonCalendarTests {
    typealias Calendar = StockSageResearchHorizonCalendar
    typealias B = StockSageBenzinga

    private func instant(_ value: String) throws -> Date {
        try Date.ISO8601FormatStyle().parse(value)
    }

    private func dateOnly(_ value: String, zone: String = "America/New_York") -> Calendar.Point {
        .dateOnly(value, sourceTimeZone: zone)
    }

    private func classify(
        _ time: Calendar.EventTime,
        in window: Calendar.HoldingWindow,
        sourceState: Calendar.SourceState = .current,
        confirmation: Calendar.Confirmation = .unknown
    ) -> Calendar.Classification {
        Calendar.classify(
            .init(time: time, sourceState: sourceState, confirmation: confirmation),
            in: window
        )
    }

    private func record(
        symbol: String,
        product: B.Product = .earnings,
        date: String?,
        schedule: String? = nil
    ) -> B.Record {
        .init(id: "\(product.rawValue).\(symbol).\(date ?? "unknown")", vendorID: nil,
              revision: "fixture", product: product, symbol: symbol,
              source: "Massive/Benzinga fixture", date: date, time: nil, timeZone: nil,
              published: nil, lastUpdated: nil, headline: "Captured \(product.rawValue)",
              details: schedule.map { ["Schedule: \($0); not a beat claim."] } ?? [],
              excerpt: nil, bullCase: nil, bearCase: nil, link: nil,
              analystIDs: [], firmIDs: [], ratingIDs: [])
    }

    private func snapshot(symbol: String, at: Date, records: [B.Record]) -> B.Snapshot {
        .init(symbol: symbol, capturedAt: at, credentialGeneration: "fixture-credential",
              pages: B.Product.allCases.map { product in
                  .init(query: .init(product: product, subject: symbol, from: nil, through: nil),
                        checkedAt: at, credentialGeneration: "fixture-credential", status: .answered,
                        records: records.filter { $0.product == product }, excludedCount: 0,
                        hasMore: false)
              })
    }

    @Test
    func horizonsCountVerifiedSessionsAndExposeBothExitBoundaries() throws {
        let assessment = try instant("2026-09-13T12:00:00Z") // Sunday morning in New York.
        let week = try #require(Calendar.window(at: assessment, horizon: .week))
        #expect(week.earliestExitSession == 1)
        #expect(week.latestExitSession == 7)
        #expect(week.earliestExitDate == "2026-09-14")
        #expect(week.latestExitDate == "2026-09-22")
        #expect(week.earliestExitAt == (try instant("2026-09-14T20:00:00Z")))
        #expect(week.latestExitAt == (try instant("2026-09-22T20:00:00Z")))

        let fortnight = try #require(Calendar.window(at: assessment, horizon: .fortnight))
        #expect(fortnight.earliestExitSession == 7)
        #expect(fortnight.latestExitSession == 14)
        #expect(fortnight.earliestExitDate == "2026-09-22")
        #expect(fortnight.latestExitDate == "2026-10-01")
    }

    @Test
    func weekendHolidayEarlyCloseAndDSTUseThePublishedCalendar() throws {
        let weekend = try #require(Calendar.window(
            at: instant("2026-09-12T16:00:00Z"), horizon: .week
        ))
        #expect(weekend.earliestExitAt == (try instant("2026-09-14T20:00:00Z")))

        let juneteenth = try #require(Calendar.window(
            at: instant("2026-06-19T16:00:00Z"), horizon: .week
        ))
        #expect(juneteenth.earliestExitDate == "2026-06-22")
        #expect(juneteenth.earliestExitAt == (try instant("2026-06-22T20:00:00Z")))

        let beforeEarlyClose = try #require(Calendar.window(
            at: instant("2026-11-27T17:00:00Z"), horizon: .week
        ))
        #expect(beforeEarlyClose.earliestExitAt == (try instant("2026-11-27T18:00:00Z")))
        let afterEarlyClose = try #require(Calendar.window(
            at: instant("2026-11-27T18:30:00Z"), horizon: .week
        ))
        #expect(afterEarlyClose.earliestExitAt == (try instant("2026-11-30T21:00:00Z")))

        let acrossDST = try #require(Calendar.window(
            at: instant("2026-03-06T22:00:00Z"), horizon: .week
        ))
        #expect(acrossDST.earliestExitDate == "2026-03-09")
        #expect(acrossDST.earliestExitAt == (try instant("2026-03-09T20:00:00Z")))
    }

    @Test
    func unsupportedCalendarYearsFailClosed() throws {
        #expect(Calendar.window(at: try instant("2027-01-04T15:00:00Z"), horizon: .week) == nil)
        #expect(Calendar.window(at: try instant("2026-12-24T12:00:00Z"), horizon: .week) == nil,
                "A window crossing into an unverified year must not guess 2027 sessions")
    }

    @Test
    func eventsBeforeEarliestExitRemainInsideHoldingRisk() throws {
        let assessment = try instant("2026-09-13T12:00:00Z")
        let week = try #require(Calendar.window(at: assessment, horizon: .week))
        let fortnight = try #require(Calendar.window(at: assessment, horizon: .fortnight))
        let dayFourEarnings = Calendar.EventTime.exact(dateOnly("2026-09-17"))

        #expect(classify(dayFourEarnings, in: week).placement == .futureWithinRiskAfterEarliestExit)
        #expect(classify(dayFourEarnings, in: fortnight).placement == .futureWithinRiskThroughEarliestExit,
                "Day-four earnings are exposure risk for a seven-to-fourteen-session position")
        #expect(classify(.exact(dateOnly("2026-09-11")), in: fortnight).placement == .past)
        #expect(classify(.exact(dateOnly("2026-11-03")), in: fortnight).placement == .futureOutsideRisk)
    }

    @Test
    func providerDateOnlyComponentsAreNeverShiftedThroughUTC() throws {
        let assessment = try instant("2026-09-14T01:00:00Z") // Sunday 21:00 ET.
        let window = try #require(Calendar.window(at: assessment, horizon: .week))
        let providerDate = classify(
            .exact(dateOnly("2026-09-14", zone: "UTC")),
            in: window,
            confirmation: .tentative
        )
        #expect(providerDate.placement == .unknown,
                "A date-only event on the earliest-exit date can fall on either side of close")
        #expect(providerDate.confirmation == .tentative)

        let midnightInstant = classify(
            .exact(.instant(try instant("2026-09-14T00:00:00Z"))),
            in: window,
            confirmation: .tentative
        )
        #expect(midnightInstant.placement == .past,
                "An explicit instant keeps instant semantics; only date-only input preserves components")
    }

    @Test
    func invalidAmbiguousAndBoundaryStraddlingRangesAreUnknown() throws {
        let window = try #require(Calendar.window(
            at: instant("2026-09-13T12:00:00Z"), horizon: .fortnight
        ))
        let insideEstimate = classify(
            .range(start: dateOnly("2026-09-17"), end: dateOnly("2026-09-18")),
            in: window,
            confirmation: .tentative
        )
        #expect(insideEstimate.placement == .futureWithinRiskThroughEarliestExit)
        #expect(insideEstimate.confirmation == .tentative)

        let latestBoundaryOverlap = classify(
            .range(start: dateOnly("2026-09-30"), end: dateOnly("2026-10-02")),
            in: window,
            confirmation: .tentative
        )
        #expect(latestBoundaryOverlap.placement == .unknown)
        #expect(latestBoundaryOverlap.confirmation == .tentative)
        #expect(classify(
            .range(start: dateOnly("2026-09-21"), end: dateOnly("2026-09-23")),
            in: window
        ).placement == .unknown, "A range crossing the earliest-exit boundary has no single bucket")
        #expect(classify(
            .range(start: dateOnly("2026-09-18"), end: dateOnly("2026-09-17")),
            in: window
        ).placement == .unknown)
        #expect(classify(.exact(dateOnly("2026-09-22")), in: window).placement == .unknown,
                "A date-only event on the earliest exit cannot choose a side of close")
        #expect(classify(.exact(dateOnly("2026-10-01")), in: window).placement == .unknown,
                "A date-only event on the latest exit cannot choose a side of close")
        #expect(classify(.exact(dateOnly("2026-02-30")), in: window).placement == .unknown)
        #expect(classify(.exact(dateOnly("2026-09-17", zone: "Not/A_TimeZone")), in: window).placement == .unknown)
        #expect(classify(.unknown, in: window).placement == .unknown)
    }

    @Test
    func staleAndPreAIEvidenceStayUnknownWithoutChangingProviderStatus() throws {
        let window = try #require(Calendar.window(
            at: instant("2026-09-13T12:00:00Z"), horizon: .fortnight
        ))
        let timing = Calendar.EventTime.exact(dateOnly("2026-09-17"))
        let stale = classify(timing, in: window, sourceState: .stale, confirmation: .confirmed)
        #expect(stale == .init(placement: .unknown, confirmation: .confirmed))
        let preAI = classify(timing, in: window, sourceState: .preAI, confirmation: .projected)
        #expect(preAI == .init(placement: .unknown, confirmation: .projected))
        let unknownConfirmation = classify(timing, in: window, confirmation: .unknown)
        #expect(unknownConfirmation.placement == .futureWithinRiskThroughEarliestExit)
        #expect(unknownConfirmation.confirmation == .unknown)
    }

    @Test
    func AMDAndKRCounterexamplesStayOutsideOrHistorical() throws {
        let window = try #require(Calendar.window(
            at: instant("2026-09-13T12:00:00Z"), horizon: .fortnight
        ))
        let amdDistantNovember = classify(
            .exact(dateOnly("2026-11-03")), in: window, confirmation: .tentative
        )
        #expect(amdDistantNovember == .init(placement: .futureOutsideRisk, confirmation: .tentative))

        let krReported = classify(
            .exact(dateOnly("2026-09-11")), in: window, confirmation: .confirmed
        )
        #expect(krReported == .init(placement: .past, confirmation: .confirmed))
        let krProjectedDecember = classify(
            .exact(dateOnly("2026-12-03")), in: window, confirmation: .projected
        )
        #expect(krProjectedDecember == .init(placement: .futureOutsideRisk, confirmation: .projected))
    }

    @Test
    func capturedAMDAndKREvidenceUsesTheProductionNormalizationSeam() throws {
        let assessment = try instant("2026-09-13T12:00:00Z")
        let window = try #require(Calendar.window(at: assessment, horizon: .fortnight))

        let amd = snapshot(symbol: "AMD", at: assessment, records: [
            record(symbol: "AMD", date: "2026-11-03", schedule: "projected")
        ])
        let amdEvents = Calendar.capturedEvents(benzinga: amd, catalyst: nil, at: assessment)
        let amdEvent = try #require(amdEvents.only)
        #expect(amdEvent.product == .earnings)
        #expect(Calendar.classify(amdEvent.event, in: window)
            == .init(placement: .futureOutsideRisk, confirmation: .projected))
        let amdFact = Calendar.mandatoryFact(
            at: assessment, horizon: .fortnight, events: amdEvents
        )
        #expect(amdFact.contains(
            "earnings 2026-11-03 [date-only UTC] -> future outside holding-risk window; certainty projected"
        ))
        #expect(Calendar.capturedEvents(benzinga: amd, catalyst: nil, at: assessment,
                                       excludingProducts: [.earnings]).isEmpty)

        let kr = snapshot(symbol: "KR", at: assessment, records: [
            record(symbol: "KR", date: "2026-09-11", schedule: "confirmed")
        ])
        let projected = StockSageCatalystRecordCache.Record(
            symbol: "KR", earningsDate: try instant("2026-12-03T00:00:00Z"),
            checkedAt: assessment.addingTimeInterval(-60), source: "projection",
            status: .projected, confirmed: nil, projectionBasis: "fixture interval"
        )
        let krEvents = Calendar.capturedEvents(
            benzinga: kr, catalyst: projected, at: assessment
        )
        #expect(krEvents.count == 2)
        let krClassifications = krEvents.map { Calendar.classify($0.event, in: window) }
        #expect(krClassifications.contains(.init(placement: .past, confirmation: .confirmed)))
        #expect(krClassifications.contains(.init(placement: .futureOutsideRisk,
                                                 confirmation: .projected)))

        let fact = Calendar.mandatoryFact(at: assessment, horizon: .fortnight, events: krEvents)
        #expect(fact.contains("outside future window 1"))
        #expect(fact.contains("past 1"))
        #expect(fact.contains("confirmed 1"))
        #expect(fact.contains("projected 1"))
        #expect(fact.contains(
            "earnings 2026-09-11 [date-only UTC] -> past before assessment; certainty confirmed"
        ))
        #expect(fact.contains(
            "earnings 2026-12-03 [date-only UTC] -> future outside holding-risk window; certainty projected"
        ))
    }

    @Test
    func capturedEvidenceFiltersProviderStateAndStaleCatalystWithoutClaimingNoEvents() throws {
        let assessment = try instant("2026-09-13T12:00:00Z")
        let unusablePage = B.Page(
            query: .init(product: .earnings, subject: "AMD", from: nil, through: nil),
            checkedAt: assessment, credentialGeneration: "old", status: .answered,
            records: [record(symbol: "AMD", date: "2026-09-17", schedule: "confirmed")],
            excludedCount: 0, hasMore: false
        )
        let capture = B.Snapshot(symbol: "AMD", capturedAt: assessment,
                                 credentialGeneration: "current", pages: [unusablePage])
        let stale = StockSageCatalystRecordCache.Record(
            symbol: "AMD", earningsDate: try instant("2026-09-17T00:00:00Z"),
            checkedAt: assessment.addingTimeInterval(-StockSageStore.earningsCheckTTL),
            source: "fixture", status: .dateKnown, confirmed: true
        )
        let events = Calendar.capturedEvents(benzinga: capture, catalyst: stale, at: assessment)
        #expect(events.isEmpty)

        let stalePage = B.Page(
            query: .init(product: .earnings, subject: "AMD", from: nil, through: nil),
            checkedAt: assessment.addingTimeInterval(-B.Product.earnings.cacheTTL),
            credentialGeneration: "current", status: .answered,
            records: [record(symbol: "AMD", date: "2026-09-17", schedule: "confirmed")],
            excludedCount: 0, hasMore: false
        )
        let staleCapture = B.Snapshot(symbol: "AMD", capturedAt: assessment,
                                      credentialGeneration: "current", pages: [stalePage])
        #expect(Calendar.capturedEvents(benzinga: staleCapture, catalyst: nil,
                                       at: assessment).isEmpty)

        let futureCapture = B.Snapshot(
            symbol: "AMD", capturedAt: assessment.addingTimeInterval(1),
            credentialGeneration: "current", pages: []
        )
        #expect(Calendar.capturedEvents(benzinga: futureCapture, catalyst: nil,
                                       at: assessment).isEmpty,
                "A future snapshot clock must not become current evidence")
        let fact = Calendar.mandatoryFact(at: assessment, horizon: .week, events: events)
        #expect(fact.contains("Current captured event timing"))
        #expect(fact.contains("zero is not proof of no events"))

        let unsupported = Calendar.mandatoryFact(
            at: try instant("2027-01-04T15:00:00Z"), horizon: .week, events: events
        )
        #expect(unsupported.contains("Holding-risk calendar: unknown"))
        #expect(unsupported.contains("not proof of no events"))
    }

    @Test
    func mandatoryEventTagsAreBoundedAndDiscloseOmissions() throws {
        let assessment = try instant("2026-09-13T12:00:00Z")
        let events = try (1...11).map { day in
            Calendar.CapturedEvent(
                product: .guidance,
                event: .init(
                    time: .exact(.instant(try instant(
                        String(format: "2026-09-%02dT12:00:00Z", day + 13)
                    ))),
                    confirmation: .unknown
                )
            )
        }
        let fact = Calendar.mandatoryFact(at: assessment, horizon: .fortnight, events: events)
        #expect(fact.components(separatedBy: " -> ").count - 1 == 10)
        #expect(fact.contains("Omitted event tags: 1"))
    }

    @Test
    func deterministicClassificationBenchmarkHasAnHonestMissingBaseline() throws {
        let window = try #require(Calendar.window(
            at: instant("2026-09-13T12:00:00Z"), horizon: .fortnight
        ))
        let cases: [Calendar.Event] = [
            .init(time: .exact(dateOnly("2026-09-11")), confirmation: .confirmed),
            .init(time: .exact(dateOnly("2026-09-17")), confirmation: .tentative),
            .init(time: .exact(dateOnly("2026-09-30")), confirmation: .projected),
            .init(time: .exact(dateOnly("2026-11-03")), confirmation: .projected),
            .init(time: .range(start: dateOnly("2026-09-30"), end: dateOnly("2026-10-02")),
                  confirmation: .tentative),
            .init(time: .unknown, sourceState: .preAI, confirmation: .unknown)
        ]
        let start = ContinuousClock.now
        var counts: [Calendar.Placement: Int] = [:]
        for _ in 0..<1_000 {
            for event in cases {
                counts[Calendar.classify(event, in: window).placement, default: 0] += 1
            }
        }
        let elapsed = start.duration(to: .now).components
        let elapsedNanoseconds = Int64(elapsed.seconds) * 1_000_000_000
            + Int64(elapsed.attoseconds / 1_000_000_000)
        #expect(counts.values.reduce(0, +) == 6_000)
        let benchmark: [String: Any] = [
            "case": "research_horizon_calendar",
            "before": "unavailable_no_classifier",
            "after_cases": counts.values.reduce(0, +),
            "after_elapsed_ns": elapsedNanoseconds
        ]
        let data = try JSONSerialization.data(withJSONObject: benchmark, options: [.sortedKeys])
        print("BENCHMARK " + String(decoding: data, as: UTF8.self))
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
