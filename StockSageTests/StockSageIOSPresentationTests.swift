#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import StockSage

@Suite("iPhone Chat and Research presentation", .serialized)
@MainActor
struct StockSageIOSPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_788_739_200)

    @Test(arguments: [false, true])
    func chatReceiptAndEvidenceFitThePhone(accessibility: Bool) async throws {
        let receipt = StockSageChatSession.Turn(id: UUID(), question: "add rklb to watchlist",
            snapshot: .init(at: now, facts: [], context: "Local watchlist action."), model: "StockSage",
            answer: "Added RKLB to your watchlist.", evidence: [], notice: "Local watchlist action completed.",
            isWatchlistAction: true)
        var edits = 0
        try await capture(StockSageChatSection.turnContent(receipt, pending: false, editQuestion: { edits += 1 }),
                          name: "chat-watchlist", accessibility: accessibility)

        let symbol = StockSageSymbol(symbol: "ORCL", market: "US", quotes: [
            .init(price: 159.70, previousPrice: 158, marketTime: now, priceSource: .massiveSIP)
        ])
        var snapshot = StockSageChat.snapshot(symbols: [symbol], ideas: [], earnings: [:], sample: false, now: now)
        let fact = try #require(snapshot.facts.first)
        let source = StockSageChat.Source(id: "fixture.news", subject: "ORCL",
            attribution: "Fixture market bulletin with a deliberately long attribution", date: now,
            excerpt: "Synthetic source excerpt · تحقق من المصدر والتاريخ.",
            warning: "Attributed report, not a verified forecast or an executable quote.",
            link: URL(string: "https://example.invalid/research"))
        snapshot.sources = [source]
        let turn = StockSageChatSession.Turn(id: UUID(),
            question: "What does this dated observation tell me, and what remains unknown?",
            snapshot: snapshot, model: "fixture",
            answer: "Synthetic answer: a recorded observation is not a prediction. Check the captured source and its timestamp below.",
            evidence: [fact.id, source.id], notice: "Unverified draft · fixture")
        try await capture(StockSageChatSection.turnContent(turn, pending: false, editQuestion: { edits += 1 }),
                          name: "chat-evidence", accessibility: accessibility)
        #expect(edits == 0, "Rendering cannot edit or send a question")
        #expect(turn.snapshot == snapshot && turn.evidence == [fact.id, source.id])
    }

    @Test(arguments: [false, true])
    func populatedResearchAndDetailFitThePhone(accessibility: Bool) async throws {
        typealias R = StockSageHorizonResearch
        let suite = "stocksage.ios.presentation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let research = R()
        let listings = ["AAPL", "MSFT"].map { symbol in
            R.Listing(ticker: symbol, name: "\(symbol) synthetic company with a longer display name",
                market: "stocks", locale: "us", active: true, type: "CS", currency_name: "usd",
                primary_exchange: "XNAS")
        }
        let receipt = StockSageResearchUniverse.Receipt(session: "2026-09-11", requestedAt: now,
            returnedCount: 2, eligibleCount: 2, directoryCount: 2, partialSession: false,
            dollarVolume: ["AAPL": 900, "MSFT": 100])
        let result = R.Result(
            verdict: .init(action: .buy, reason: "Synthetic interpretation, not a verified trading edge.",
                           risk: "Future news and overnight gaps remain unknown.", evidence: ["F1"]),
            levels: .init(entry: 159.70, stop: 150, target: 179.10, at: now,
                basis: "Synthetic daily ATR reference plan. These are scenarios, not forecasts."),
            facts: ["Synthetic fixture only; no live quote or order."], note: "Synthetic research only.",
            at: now, model: "fixture", referenceClose: (value: 159.70, at: now))
        var analyses = 0
        // Use the same injected offline seam as the existing Mac presentation tests.
        let started = research.start(.week, allowed: { true }, universe: { .init(listings, receipt: receipt) },
            analyze: { item in
                analyses += 1
                return item.ticker == "AAPL" ? result : .init(note: "No verified opinion. Synthetic incomplete result.", at: now)
            })
        try #require(started)
        defer { research.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while research.running != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(research.running == nil && analyses == 2)
        let captured = try #require(research.scans[.week])
        var presentation = StockSageResearchModesPanel.Presentation()
        var presentationChanges = 0
        let panel = StockSageResearchModesPanel(store: store, research: research,
            presentation: Binding(get: { presentation }, set: { presentation = $0; presentationChanges += 1 }))
        try await capture(panel.defaultAppStorage(defaults), name: "research-results", accessibility: accessibility)
        try await capture(StockSageResearchModesPanel.resultDetail(listings[0], result: captured.results["AAPL"]),
                          name: "research-detail", accessibility: accessibility)
        #expect(presentationChanges == 0 && presentation.selected == nil && presentation.search.isEmpty
                && presentation.filter == .all && presentation.horizon == .week)
        #expect(research.running == nil && analyses == 2 && research.scans[.week]?.at == captured.at)
        #expect(research.scans[.week]?.selection == receipt && research.scans[.week]?.results.count == 2)
        #expect(store.userSymbols.isEmpty, "Rendering cannot change the isolated watchlist")
    }

    private func capture(_ view: some View, name: String, accessibility: Bool) async throws {
        let width: CGFloat = 375
        var appeared = false
        // Erase the fixture wrapper to avoid the documented iOS 27 deep generic metadata issue.
        let host = UIHostingController(rootView: AnyView(view.padding(16)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, accessibility ? .accessibility3 : .large)
            .tint(DS.Palette.accent)
            // This is a component capture; device safe areas must not shrink its measured height.
            .ignoresSafeArea()
            .onAppear { appeared = true }))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 812)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        host.view.backgroundColor = UIColor(DS.Palette.bgTop)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !appeared, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(appeared)
        host.view.layoutIfNeeded()
        let fitting = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
        try #require(fitting.width.isFinite && fitting.height.isFinite && fitting.height > 100 && fitting.height < 10_000)
        #expect(fitting.width <= width + 1, "The component must fit a 375-point phone without horizontal overflow")
        // Capture the entire component at phone width so evidence and every synthetic row are inspectable.
        window.frame.size = CGSize(width: width, height: ceil(fitting.height))
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.view.layoutIfNeeded()
        func checkBounds(_ current: UIView) {
            guard !current.isHidden, current.alpha > 0.01 else { return }
            if current is UIControl || current is UILabel || current is UITextView {
                let bounds = current.convert(current.bounds, to: host.view)
                if !bounds.isEmpty {
                    #expect(bounds.minX >= -1 && bounds.maxX <= width + 1,
                            "Native text and controls must stay within the phone's horizontal bounds")
                }
            }
            for child in current.subviews { checkBounds(child) }
        }
        checkBounds(host.view)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // drawHierarchy asks the render server for the tall hosting surface at device scale;
        // accessibility Research exceeds that snapshot limit on iOS 27. Render the same laid-out
        // native layers directly into this 1x CPU bitmap, retaining every row and native control.
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { context in
            host.view.layer.render(in: context.cgContext)
        }
        let png = try #require(image.pngData())
        #expect(image.size.width == width && image.size.height > 100 && png.count > 1_000)
        let pixels = try #require(image.cgImage?.dataProvider?.data) as Data
        #expect(Set(pixels).count > 16, "The native render must contain drawn content, not a blank canvas")
        let suffix = accessibility ? "accessibility3" : "default"
        try png.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("stocksage-ios-\(name)-375-\(suffix).png"), options: .atomic)
    }
}
#endif
