import Foundation
import CryptoKit

/// Fixed screening assumptions, not a measured predictive edge. This never rewrites a model opinion.
enum StockSageResearchQualification {
    nonisolated static let version = 1

    nonisolated struct Measurements: Codable, Equatable, Sendable {
        let completedBars: Int?
        let close: Double?
        let sma20: Double?
        let horizonReturnPercent: Double?
        let volumeRatio: Double?
        let atr14: Double?
        let stopLow: Double?
        let targetHigh: Double?
    }
    nonisolated struct Scenario: Codable, Equatable, Sendable {
        let entry: Double
        let stop: Double
        let target: Double
        let basis: String
    }
    nonisolated struct Catalyst: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case news, publicInsiderFiling }
        let key: String
        let identity: String
        let kind: Kind
        /// News publication time or public Form 4 filing/event date; never inferred transaction time.
        let date: Date
        let checkedAt: Date
    }
    nonisolated struct Earnings: Codable, Equatable, Sendable {
        let relation: String
        let outcome: String
        let date: Date?
        let confirmed: Bool?
        let checkedAt: Date?
        let recordedAt: Date?

        fileprivate var observation: StockSageMassiveEarnings.Observation? {
            guard let recordedAt else { return nil }
            let response: StockSageMassiveEarnings.Observation.Outcome
            switch outcome {
            case "answered": response = .answered(date.flatMap { date in confirmed.map { .init(date: date, confirmed: $0) } })
            case "unavailable": response = .unavailable
            default: response = .notRequested
            }
            return .init(outcome: response, checkedAt: checkedAt, recordedAt: recordedAt)
        }
    }
    nonisolated struct Receipt: Codable, Equatable, Sendable {
        let version: Int
        let symbol: String
        let horizon: String
        /// Matches Result.at, the beginning of evidence gathering.
        let capturedAt: Date
        /// The final context snapshot controls earnings and catalyst timing.
        let evidenceAsOf: Date
        let barDate: Date?
        let criticalCaptureReady: Bool
        let measurements: Measurements
        let earnings: Earnings
        let candidateCatalysts: [Catalyst]
        let citedQualifyingKeys: [String]
        let originalAction: String
        let scenario: Scenario?
        let reasons: [String]
        /// Nil preserves the original prior-New-York-date rule and legacy archive encoding.
        var completedSessionPolicy: Int? = nil

        var isQualified: Bool { version == StockSageResearchQualification.version
            && (completedSessionPolicy == nil || completedSessionPolicy == 1) && reasons.isEmpty && exclusions(self).isEmpty }
        var levels: StockSageHorizonResearch.Levels? {
            guard isQualified, let scenario, let barDate else { return nil }
            return .init(entry: scenario.entry, stop: scenario.stop, target: scenario.target, at: barDate, basis: scenario.basis)
        }
    }
    nonisolated struct Inputs: Sendable {
        fileprivate let draft: Receipt

        /// Mandatory before generation. Actual catalyst records still require their own citations.
        var fact: String {
            let m = draft.measurements, week = draft.horizon == StockSageHorizonResearch.Horizon.week.rawValue
            func number(_ value: Double?) -> String { value.map { String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "unknown" }
            let earnings = draft.earnings.relation + (draft.earnings.confirmed == false ? "; projected, not announced" : "")
            return "Strict qualification v1, fixed unvalidated screen: close \(number(m.close)); SMA20 \(number(m.sma20)); historical \(week ? 7 : 14)-bar return \(number(m.horizonReturnPercent))%; recent3/prior20 volume ratio \(number(m.volumeRatio)); ATR14 \(number(m.atr14)). Reference stop \(number(m.stopLow)) is the last \(week ? 5 : 10)-bar low; target \(number(m.targetHigh)) is the prior \(week ? 20 : 60)-bar high, latest bar excluded. Require close>SMA20, positive historical return, volume ratio>=1.5, stop<entry<target, reward/risk>=2, stop<=3 ATR and target<=\(week ? 3 : 6) ATR from entry. Earnings: \(earnings); not absence of earnings risk. Only a separately cited recent news or public Form 4 record can support a catalyst; this screen is not catalyst evidence or a return prediction."
        }

        func receipt(verdict: StockSageAIAssessment.Verdict, citedKeys: [String], offeredKeys: [String]? = nil) -> Receipt {
            let offered = offeredKeys.map { Set($0) }
            let candidates = draft.candidateCatalysts.filter { offered?.contains($0.key) ?? true }
            let cited = Set(citedKeys)
            let keys = candidates.map(\.key).filter(cited.contains)
            let pending = Receipt(version: draft.version, symbol: draft.symbol, horizon: draft.horizon,
                capturedAt: draft.capturedAt, evidenceAsOf: draft.evidenceAsOf, barDate: draft.barDate,
                criticalCaptureReady: draft.criticalCaptureReady, measurements: draft.measurements, earnings: draft.earnings,
                candidateCatalysts: candidates, citedQualifyingKeys: keys,
                originalAction: verdict.action.rawValue, scenario: draft.scenario, reasons: [],
                completedSessionPolicy: draft.completedSessionPolicy)
            return Receipt(version: pending.version, symbol: pending.symbol, horizon: pending.horizon,
                capturedAt: pending.capturedAt, evidenceAsOf: pending.evidenceAsOf, barDate: pending.barDate,
                criticalCaptureReady: pending.criticalCaptureReady, measurements: pending.measurements, earnings: pending.earnings,
                candidateCatalysts: pending.candidateCatalysts, citedQualifyingKeys: pending.citedQualifyingKeys,
                originalAction: pending.originalAction, scenario: pending.scenario, reasons: exclusions(pending),
                completedSessionPolicy: pending.completedSessionPolicy)
        }
    }

    @MainActor static func prepare(_ capture: StockSageHorizonResearch.Capture,
                                  horizon: StockSageHorizonResearch.Horizon) -> Inputs {
        let context = capture.context, asOf = context.asOf, week = horizon == .week
        let h = StockSageHorizonResearch.completedHistory(capture.history, at: asOf)
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        let m = Measurements(completedBars: h?.count, close: h?.closes.last,
            sma20: finite(h.flatMap { StockSageIndicators.sma($0.closes, period: 20) }),
            horizonReturnPercent: finite(h.flatMap { StockSageIndicators.returnOverPeriod($0.closes, period: week ? 7 : 14) }),
            volumeRatio: finite(h.flatMap { StockSageIndicators.volumeConfirmation(closes: $0.closes, volumes: $0.volumes,
                lookback: 20, recentBars: 3)?.ratio }),
            atr14: finite(h.flatMap { StockSageIndicators.atr(highs: $0.highs, lows: $0.lows, closes: $0.closes, period: 14) }),
            stopLow: h?.lows.suffix(week ? 5 : 10).min(),
            targetHigh: h.flatMap { $0.count > (week ? 20 : 60) ? $0.highs.dropLast().suffix(week ? 20 : 60).max() : nil })
        let observation = capture.nextEarnings
        let window = StockSageMassiveEarnings.Window(observation: observation, asOf: asOf, horizon: horizon)
        var outcome = "notRequested", earningsDate: Date?, confirmed: Bool?
        if let observation {
            switch observation.outcome {
            case .answered(let row): outcome = "answered"; earningsDate = row?.date; confirmed = row?.confirmed
            case .unavailable: outcome = "unavailable"
            case .notRequested: break
            }
        }
        let earnings = Earnings(relation: relation(window), outcome: outcome, date: earningsDate, confirmed: confirmed,
            checkedAt: observation?.checkedAt, recordedAt: observation?.recordedAt)
        // Legacy unkeyed captures cannot prove that a typed catalyst was offered to the model.
        let packetKeys = Set(capture.evidencePacket?.facts.map(\.key) ?? [])
        var catalysts: [Catalyst] = []
        if let news = context.newsObservation, news.withholdingReason == nil,
           let attempt = news.attempts.last, attempt.status == .answered || attempt.status == .partial,
           fresh(attempt.checkedAt, at: asOf, seconds: 300) {
            for item in context.news ?? [] where attempt.items.contains(item)
                && fresh(item.date, at: asOf, seconds: Double(week ? 3 : 7) * 86_400) {
                let identity = SHA256.hash(data: Data(item.id.utf8)).map { String(format: "%02x", $0) }.joined()
                let key = "news.item." + identity
                if packetKeys.contains(key) {
                    catalysts.append(.init(key: key, identity: identity, kind: .news, date: item.date, checkedAt: attempt.checkedAt))
                }
            }
        }
        if let insider = context.company[.insider], insider.symbol == context.idea.symbol.uppercased(),
           insider.feed == .insider, insider.outcome == .answered, insider.fresh(at: asOf), let first = insider.event {
            let events = insider.insiderEvents?.first == first ? insider.insiderEvents! : [first]
            for (index, event) in events.prefix(StockSageMassiveEvents.insiderRecordLimit).enumerated()
                where event.symbol == context.idea.symbol.uppercased() && event.feed == .insider
                    && fresh(event.date, at: asOf, seconds: Double(week ? 7 : 14) * 86_400) {
                let key = index == 0 ? "feed.insider.event" : "feed.insider.transaction." + event.insiderIdentity
                if packetKeys.contains(key) {
                    catalysts.append(.init(key: key, identity: event.insiderIdentity, kind: .publicInsiderFiling,
                        date: event.date, checkedAt: insider.checkedAt))
                }
            }
        }
        var seen = Set<String>()
        catalysts = catalysts.filter { seen.insert($0.key).inserted }
        let ready = StockSageHorizonResearch.validTicker(context.idea.symbol) && context.quotedInUSD
            && capture.history.symbol == context.idea.symbol && !capture.blockedByThrottle
            && validDate(capture.at) && fresh(capture.at, at: asOf, seconds: 300)
        return Inputs(draft: .init(version: version, symbol: context.idea.symbol, horizon: horizon.rawValue,
            capturedAt: capture.at, evidenceAsOf: asOf, barDate: h?.dates.last, criticalCaptureReady: ready,
            measurements: m, earnings: earnings, candidateCatalysts: catalysts, citedQualifyingKeys: [],
            originalAction: "", scenario: scenario(m, horizon: horizon), reasons: [], completedSessionPolicy: 1))
    }

    /// Structural/archive validation; the immutable measurements are not a backtest or proof of claim support.
    nonisolated static func valid(_ receipt: Receipt, symbol: String, horizon: String, at: Date, citedKeys: [String]) -> Bool {
        guard receipt.version == version, receipt.completedSessionPolicy == nil || receipt.completedSessionPolicy == 1,
              receipt.symbol == symbol, StockSageHorizonResearch.validTicker(symbol),
              receipt.horizon == horizon, let h = StockSageHorizonResearch.Horizon(rawValue: horizon),
              receipt.capturedAt == at, validDate(at), validDate(receipt.evidenceAsOf),
              fresh(at, at: receipt.evidenceAsOf, seconds: 300),
              ["Buy", "Strong Buy", "Hold", "Avoid", "Reduce", "Sell"].contains(receipt.originalAction) else { return false }
        let m = receipt.measurements
        let numbers = [m.close, m.sma20, m.horizonReturnPercent, m.volumeRatio, m.atr14, m.stopLow, m.targetHigh]
        guard numbers.compactMap({ $0 }).allSatisfy(\.isFinite),
              [m.close, m.sma20, m.stopLow, m.targetHigh].compactMap({ $0 }).allSatisfy({ $0 > 0 }),
              [m.volumeRatio, m.atr14].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { return false }
        if let count = m.completedBars {
            guard (30...5000).contains(count), let bar = receipt.barDate,
                  StockSageMarketHours.isLatestCompletedDailyBar(bar, at: receipt.evidenceAsOf,
                      includingCurrentSession: receipt.completedSessionPolicy == 1),
                  m.close != nil, m.sma20 != nil, m.horizonReturnPercent != nil, m.stopLow != nil,
                  (count > (h == .week ? 20 : 60)) == (m.targetHigh != nil) else { return false }
        } else if receipt.barDate != nil || numbers.contains(where: { $0 != nil }) { return false }
        guard receipt.scenario == scenario(m, horizon: h), ["answered", "unavailable", "notRequested"].contains(receipt.earnings.outcome),
              (receipt.earnings.date == nil) == (receipt.earnings.confirmed == nil),
              [receipt.earnings.date, receipt.earnings.checkedAt, receipt.earnings.recordedAt].compactMap({ $0 }).allSatisfy(validDate),
              receipt.earnings.relation == relation(.init(observation: receipt.earnings.observation, asOf: receipt.evidenceAsOf, horizon: h)),
              receipt.candidateCatalysts.count <= 13,
              Set(receipt.candidateCatalysts.map(\.key)).count == receipt.candidateCatalysts.count else { return false }
        for catalyst in receipt.candidateCatalysts {
            let days = catalyst.kind == .news ? (h == .week ? 3 : 7) : (h == .week ? 7 : 14)
            guard !catalyst.identity.isEmpty, catalyst.identity.utf8.count <= 512,
                  fresh(catalyst.date, at: receipt.evidenceAsOf, seconds: Double(days) * 86_400),
                  fresh(catalyst.checkedAt, at: receipt.evidenceAsOf, seconds: catalyst.kind == .news ? 300 : 86_400) else { return false }
            if catalyst.kind == .news {
                guard catalyst.identity.count == 64, catalyst.identity.allSatisfy({ $0.isHexDigit }),
                      catalyst.key == "news.item." + catalyst.identity else { return false }
            } else {
                guard floor(catalyst.checkedAt.timeIntervalSince1970 / 86_400) == floor(receipt.evidenceAsOf.timeIntervalSince1970 / 86_400),
                      catalyst.key == "feed.insider.event" || catalyst.key == "feed.insider.transaction." + catalyst.identity else { return false }
            }
        }
        let cited = Set(citedKeys)
        return receipt.citedQualifyingKeys == receipt.candidateCatalysts.map(\.key).filter(cited.contains)
            && receipt.reasons == exclusions(receipt)
    }

    private nonisolated static func scenario(_ m: Measurements, horizon: StockSageHorizonResearch.Horizon) -> Scenario? {
        guard let entry = m.close, let stop = m.stopLow, let target = m.targetHigh,
              [entry, stop, target].allSatisfy({ $0.isFinite && $0 > 0 }), stop < entry, entry < target else { return nil }
        return .init(entry: entry, stop: stop, target: target,
            basis: "Strict qualification v1: last completed adjusted close; stop is the last \(horizon == .week ? 5 : 10)-bar low; target is the prior \(horizon == .week ? 20 : 60)-bar high excluding the latest bar. Unvalidated historical scenario, not a forecast or live fill; gaps may cross the stop.")
    }
    private nonisolated static func exclusions(_ r: Receipt) -> [String] {
        let m = r.measurements, week = r.horizon == StockSageHorizonResearch.Horizon.week.rawValue
        var reasons: [String] = []
        if ![TradeAdvice.Action.buy.rawValue, TradeAdvice.Action.strongBuy.rawValue].contains(r.originalAction) {
            reasons.append("Original model opinion is not Buy / Strong Buy.")
        }
        if !r.criticalCaptureReady { reasons.append("Critical capture identity, currency, access or timing is unverified.") }
        if m.completedBars == nil { reasons.append("At least 30 valid completed daily bars including the latest prior session are required.") }
        if !(m.close.flatMap { close in m.sma20.map { close > $0 } } ?? false) { reasons.append("Completed close must exceed SMA20.") }
        if !(m.horizonReturnPercent.map { $0 > 0 } ?? false) { reasons.append("The historical return over the selected horizon must be positive.") }
        if !(m.volumeRatio.map { $0 >= 1.5 } ?? false) { reasons.append("Recent three-bar volume must be at least 1.5 times the preceding 20-bar average; missing volume cannot confirm it.") }
        if !(m.atr14.map { $0 > 0 } ?? false) { reasons.append("A positive measured ATR14 is required.") }
        if !(m.stopLow.flatMap { stop in m.close.map { stop > 0 && stop < $0 } } ?? false) { reasons.append("The observed recent low does not establish a valid stop below entry.") }
        if !(m.targetHigh.flatMap { target in m.close.map { target > $0 } } ?? false) { reasons.append("No defensible resistance target above entry from \(week ? 20 : 60) prior bars; the latest bar is excluded.") }
        if let s = r.scenario {
            let risk = s.entry - s.stop, reward = s.target - s.entry
            if reward / risk < 2 { reasons.append("Observed reward/risk is below 2:1.") }
            if let atr = m.atr14, atr > 0 {
                if risk > 3 * atr { reasons.append("Observed stop distance exceeds 3 ATR14.") }
                if reward > Double(week ? 3 : 6) * atr { reasons.append("Observed target distance exceeds \(week ? 3 : 6) ATR14 for this horizon.") }
            }
        }
        if r.earnings.relation != "outside" { reasons.append("The fresh earnings lookup does not establish an outside-window date (\(r.earnings.relation)); missing timing is not absence of risk.") }
        if r.candidateCatalysts.isEmpty { reasons.append("No recent dated news or public insider filing with a fresh answered source was offered.") }
        else if r.citedQualifyingKeys.isEmpty { reasons.append("The model did not cite an offered qualifying news or public insider filing record.") }
        return reasons
    }
    private nonisolated static func validDate(_ value: Date) -> Bool {
        value.timeIntervalSince1970.isFinite && value.timeIntervalSince1970 > 0
    }
    private nonisolated static func fresh(_ date: Date, at now: Date, seconds: TimeInterval) -> Bool {
        validDate(date) && validDate(now) && (0...seconds).contains(now.timeIntervalSince(date))
    }
    private nonisolated static func relation(_ window: StockSageMassiveEarnings.Window) -> String {
        switch window.relation { case .inside: "inside"; case .outside: "outside"; case .boundary: "boundary"; case .unknown: "unknown" }
    }
}
