import Foundation
import Testing
@testable import StockSage

@MainActor @Suite("Research quality badge and evidence class coverage")
struct StockSageResearchQualityPresentationTests {
    typealias Q = StockSageResearchQualityPresentation
    typealias A = StockSageAIAssessment

    private let at = try! Date.ISO8601FormatStyle().parse("2026-09-16T12:00:00Z")

    private func report(_ state: A.QualityReport.State,
                        findings: [A.QualityReport.Finding] = [],
                        offered: Int = 4, cited: Int = 2,
                        classCounts: [String: Int] = ["technical": 3, "insider": 1],
                        purchases: Int = 0, sales: Int = 0,
                        uncitedInsider: [String] = [],
                        action: String? = "Buy") -> A.QualityReport {
        .init(version: A.QualityReport.version, state: state, findings: findings,
              citedCount: cited, offeredCount: offered, classCounts: classCounts,
              insiderPurchases: purchases, insiderSales: sales,
              uncitedInsiderIDs: uncitedInsider, acceptedAction: action, rejectionReason: nil)
    }

    private func prediction(quality: A.QualityReport? = nil,
                            receipt: A.EvidenceCoverage? = nil) -> StockSageResearchHistory.Prediction {
        var value = StockSageResearchHistory.Prediction(
            symbol: "ACME", name: "Acme", action: "Buy", reason: "r", risk: "k",
            evidence: ["F1"], facts: ["F1 text"], model: "google/gemma-4-31b-qat",
            note: "n", referencePrice: 10, referenceDate: at, levels: nil)
        value.qualityReport = quality
        value.evidenceReceipt = receipt
        return value
    }

    private func coverage(_ classCounts: [String: Int]?) -> A.EvidenceCoverage {
        var value = A.EvidenceCoverage(symbol: "ACME", requiredKeys: [], missingOrUnknownRequiredKeys: [],
                                       offeredKeys: ["F1"], omittedKeys: [], prePromptOmittedRecordCount: 0,
                                       citedKeys: ["F1"])
        value.classCounts = classCounts
        return value
    }

    // A run saved before shadow-mode capture has NO quality opinion. It must never be shown as
    // unverified, which would convert missing metadata into a negative judgement of the research.
    @Test func aRunWithoutARecordedReportIsNotAssessedRatherThanUnverified() {
        let state = Q.state(for: prediction())
        #expect(state == .notAssessed)
        let badge = state.badge.lowercased()
        #expect(badge.contains("not assessed") && !badge.contains("unverified"))
        #expect(!state.isNegative, "Absent metadata is not a negative result")
    }

    // A rejected answer is a real recorded outcome and must stay distinct from "never assessed".
    @Test func aModelRejectedRunIsDistinctFromANeverAssessedRun() {
        let rejected = Q.state(for: prediction(quality: report(.modelRejected, action: nil)))
        #expect(rejected != .notAssessed && rejected.isNegative)
        #expect(rejected.badge.lowercased().contains("rejected"))
    }

    // dataUnavailable describes the EVIDENCE, not the company. The copy must not read as a warning
    // about the stock.
    @Test func dataUnavailableDescribesTheEvidenceAndNotTheCompany() {
        let state = Q.state(for: prediction(quality: report(.dataUnavailable, offered: 0, cited: 0, classCounts: [:], action: nil)))
        let text = state.badge.lowercased() + " " + state.explanation.lowercased()
        #expect(text.contains("evidence"))
        for wrong in ["avoid", "risky stock", "poor company", "bad investment"] {
            #expect(!text.contains(wrong), "Quality copy must not read as advice about the company: \(wrong)")
        }
    }

    // Shadow mode is the whole point: a verified badge is an evidence-output check, never a
    // probability, an accuracy claim, or proof the strategy works.
    @Test func aVerifiedBadgeIsQualifiedAsAShadowEvidenceCheck() {
        let state = Q.state(for: prediction(quality: report(.verified)))
        let explanation = state.explanation.lowercased()
        #expect(explanation.contains("evidence"))
        for overclaim in ["probability", "accurate", "will ", "expected return", "win rate", "proven"] {
            #expect(!explanation.contains(overclaim))
        }
    }

    // Offered insider records the answer ignored are surfaced, never removed.
    @Test func uncitedInsiderRecordsAreSurfacedNotDropped() {
        let state = Q.state(for: prediction(quality: report(.unverified,
            findings: [.uncitedInsiderRecord, .insiderSaleFramedAsBuying],
            purchases: 1, sales: 2, uncitedInsider: ["insider.1", "insider.2"])))
        #expect(state.uncitedInsiderIDs == ["insider.1", "insider.2"])
        let findings = state.findingDescriptions.joined(separator: " ").lowercased()
        #expect(findings.contains("insider") && findings.contains("sale"))
        #expect(state.insiderCounts?.purchases == 1 && state.insiderCounts?.sales == 2)
    }

    // The two class counts have different denominators and must never be merged into one number.
    @Test func capturedAndOfferedClassCountsAreReportedSeparately() {
        let state = Q.state(for: prediction(quality: report(.verified, offered: 4, classCounts: ["technical": 3, "insider": 1]),
                                            receipt: coverage(["technical": 5, "insider": 1, "news": 2])))
        let rows = state.classCoverage
        let technical = try! #require(rows.first { $0.factClass == "technical" })
        #expect(technical.captured == 5 && technical.offered == 3 && technical.trimmed == 2)
        // A class captured but entirely trimmed away must still appear, not silently vanish.
        let news = try! #require(rows.first { $0.factClass == "news" })
        #expect(news.captured == 2 && news.offered == 0 && news.trimmed == 2)
    }

    // A legacy receipt that predates classCounts must read as unknown, never as zero facts.
    @Test func aReceiptWithoutRecordedClassCountsReadsAsUnknownNotZero() {
        let state = Q.state(for: prediction(quality: report(.verified, offered: 4, classCounts: ["technical": 4]),
                                            receipt: coverage(nil)))
        let technical = try! #require(state.classCoverage.first { $0.factClass == "technical" })
        #expect(technical.captured == nil && technical.offered == 4)
        #expect(technical.trimmed == nil, "Trim is unknowable when the captured count was never recorded")
    }
}
