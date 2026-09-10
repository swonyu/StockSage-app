import Testing
import SwiftUI
import Combine
@testable import StockSage
#if os(macOS)
import AppKit

@Suite(.serialized) @MainActor
struct IdeaDetailLifecycleTests {
    @Test func mountingAnUnattributedCardDoesNotFetchOrOpenDetails() async throws {
        let driver = DetailFixtureDriver(source: nil)
        let window = mount(driver)
        defer { close(window, driver: driver) }
        try await waitUntil { driver.cardMounted }
        try await Task.sleep(for: .milliseconds(150))
        #expect(driver.probe.insiderCalls.isEmpty && driver.probe.filingCalls.isEmpty && driver.probe.quoteCalls.isEmpty)
        #expect(driver.selection == nil, "A quote completion must not open a sheet without a tap")
    }

    @Test func openingSourcedCardOwnsRequestsAndPriceUpdatesDoNotRestartThem() async throws {
        let driver = DetailFixtureDriver(source: "Dated fixture")
        let window = mount(driver)
        defer { close(window, driver: driver) }
        try await waitUntil { driver.cardMounted }
        driver.selection = driver.idea
        try await waitUntil("Actual sourced detail sheet did not appear") { driver.appeared.contains("AAPL") }
        try await waitUntil("The native sheet was not attached") { window.attachedSheet != nil }
        try await waitUntil("The sourced sheet appeared but did not own its three requests") { driver.probe.insiderCalls.count == 1 && driver.probe.filingCalls.count == 1 && driver.probe.quoteCalls.count == 1 }
        #expect(driver.evidence.insiderSummary?.symbol == "AAPL")
        driver.source = "Same symbol, updated source label"
        driver.idea = driver.idea.withLivePrice(102, asOf: nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(driver.probe.insiderCalls == ["AAPL"] && driver.probe.filingCalls == ["AAPL"] && driver.probe.quoteCalls == ["AAPL"])
        #expect(driver.probe.benzingaCalls == ["AAPL"], "Native detail redraw cannot refetch Benzinga")
        driver.selection = nil
        // Offscreen AppKit detaches the real sheet without reliably firing onDisappear.
        try await waitUntil("Clearing selection did not detach the sourced AAPL sheet") { window.attachedSheet == nil }
        #expect(driver.selection == nil)
    }

    @Test func lateResultsCannotReplaceNewSelectionOrReopenDismissedSheet() async throws {
        let driver = DetailFixtureDriver(source: "Dated fixture")
        driver.probe.hold = true
        let window = mount(driver)
        defer { close(window, driver: driver) }
        try await waitUntil { driver.cardMounted }
        driver.selection = driver.idea
        try await waitUntil("Initial AAPL sheet did not start all three requests") { driver.probe.allStarted(1) }
        try await waitUntil("The native sheet was not attached") { window.attachedSheet != nil }
        driver.selection = DetailFixtureDriver.idea("MSFT")
        try await waitUntil("Changing selection from AAPL to MSFT did not start replacement requests") { driver.probe.allStarted(2) }
        driver.probe.complete(1)
        try await waitUntil("MSFT request did not finish after its three leaves returned") { driver.completed.contains("MSFT") }
        driver.probe.complete(0)
        try await waitUntil("Cancelled AAPL request did not finish after its three leaves returned") { driver.completed.contains("AAPL") }
        #expect(driver.selection?.symbol == "MSFT")
        #expect(driver.evidence.insiderSummary?.symbol == "MSFT")
        #expect(driver.evidence.disclosures.first?.accessionNumber == "MSFT-1")

        driver.selection = driver.idea
        try await waitUntil("Returning selection to AAPL did not start its new requests") { driver.probe.allStarted(3) }
        try await waitUntil("The returning AAPL sheet was not attached") { window.attachedSheet != nil }
        driver.selection = nil
        try await waitUntil("Clearing selection did not detach the second AAPL sheet") { window.attachedSheet == nil }
        driver.probe.complete(2)
        try await waitUntil("Dismissed AAPL request did not finish after its three leaves returned") { driver.completed.filter { $0 == "AAPL" }.count == 2 }
        #expect(driver.selection == nil)
        #expect(window.attachedSheet == nil, "Late quote completion must not reopen the native sheet")
        #expect(driver.evidence.insiderSummary == nil && driver.evidence.disclosures.isEmpty)
        #expect(!driver.evidence.insiderLoading && !driver.evidence.disclosuresLoading)
    }

    @Test(arguments: [true, false])
    func coalescedSelectionCycleRestartsTheMountedSheet(dismiss: Bool) async throws {
        let driver = DetailFixtureDriver(source: "Dated fixture")
        driver.probe.hold = true
        let window = mount(driver)
        defer { close(window, driver: driver) }
        try await waitUntil { driver.cardMounted }
        driver.selection = driver.idea
        try await waitUntil { driver.probe.allStarted(1) }
        // No suspension: SwiftUI can observe only the final AAPL selection.
        driver.selection = dismiss ? nil : DetailFixtureDriver.idea("MSFT")
        driver.selection = driver.idea
        try await waitUntil("The mounted sheet did not restart after a coalesced A→…→A transition") {
            driver.probe.allStarted(2)
        }
        driver.probe.complete(1)
        try await waitUntil { driver.selection?.price == 102 }
        driver.probe.complete(0)
        try await waitUntil { driver.completed.count == 2 }
        #expect(driver.selection?.price == 102)
        #expect(driver.evidence.disclosures.first?.accessionNumber == "AAPL-1")
    }

    private func mount(_ driver: DetailFixtureDriver) -> DetailFixtureWindow {
        let window = DetailFixtureWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 500, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: DetailFixtureView(driver: driver))
        window.contentViewController = host
        window.orderBack(nil)
        host.view.layoutSubtreeIfNeeded()
        return window
    }

    private func close(_ window: DetailFixtureWindow, driver: DetailFixtureDriver) {
        driver.selection = nil
        driver.probe.releaseAll()
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }

    private func waitUntil(_ message: Comment = "Actual fixture card/sheet attachment or expected request did not occur", _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), message)
    }
}

@MainActor private final class DetailFixtureWindow: NSWindow {
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { false }
}
#endif

@Suite(.serialized) @MainActor
struct IdeaDetailEvidenceTests {
    @Test(arguments: ["cancel", "policy", "credential", "mismatched-symbol"])
    func benzingaLateCompletionRequiresCurrentOwnershipAndReceipt(reason: String) async throws {
        let driver = DetailFixtureDriver(source: nil)
        driver.selection = driver.idea
        driver.probe.hold = true
        defer { driver.probe.releaseAll() }
        let load = Task { await driver.load(driver.idea) }
        defer { load.cancel() }
        try await driver.waitForRequests(1)
        switch reason {
        case "cancel": load.cancel()
        case "policy": driver.probe.allowed = false
        case "credential": driver.probe.benzingaCurrent = false
        default: driver.probe.benzingaSymbol = "MSFT"
        }
        driver.probe.complete(0)
        await load.value
        #expect(driver.evidence.benzinga == nil)
        #expect(!driver.evidence.benzingaLoading)
    }

    @Test func benzingaRetainsExactCaptureAndClearsOnSelectionChange() async {
        let driver = DetailFixtureDriver(source: nil)
        driver.selection = driver.idea
        await driver.load(driver.idea)
        let expected = driver.probe.benzingaSnapshot("AAPL", index: 0)
        #expect(driver.evidence.benzinga == expected)
        #expect(driver.probe.benzingaCalls == ["AAPL"])
        driver.selection = driver.selection?.withLivePrice(105, asOf: nil)
        #expect(driver.evidence.benzinga == expected, "Same-selection quote publication cannot replace source capture")
        #expect(driver.probe.benzingaCalls == ["AAPL"])
        driver.selection = nil
        #expect(driver.evidence.benzinga == nil && !driver.evidence.benzingaLoading)
    }
    @Test(arguments: [true, false])
    func selectionCycleInvalidatesBeforeReplacementLoadStarts(dismiss: Bool) async throws {
        let driver = DetailFixtureDriver(source: nil)
        driver.probe.hold = true
        defer { driver.probe.releaseAll() }
        driver.selection = driver.idea
        let first = Task { await driver.load(driver.idea) }
        try await driver.waitForRequests(1)
        // SwiftUI has not yet cancelled/replaced the old task when these setters run.
        driver.selection = dismiss ? nil : DetailFixtureDriver.idea("MSFT")
        driver.selection = driver.idea
        driver.probe.complete(0)
        await first.value
        #expect(driver.selection?.price == 100, "Old A must not update a reopened A before its task starts")
        #expect(driver.probe.publishedPrices.isEmpty, "An obsolete quote must not merge into the shared board before ownership validation")
        #expect(driver.evidence.insiderSummary == nil && driver.evidence.disclosures.isEmpty)
        #expect(!driver.evidence.insiderLoading && !driver.evidence.disclosuresLoading)
        driver.probe.hold = false
        await driver.load(driver.idea)
        #expect(driver.selection?.price == 102)
        #expect(driver.evidence.insiderSummary?.nonDiscretionaryCount == 2)
        #expect(driver.evidence.disclosures.first?.accessionNumber == "AAPL-1")
    }

    @Test func aReturnToTheSameSymbolRejectsItsPreviousGeneration() async throws {
        let driver = DetailFixtureDriver(source: nil)
        driver.probe.hold = true
        defer { driver.probe.releaseAll() }
        driver.selection = driver.idea
        let first = Task { await driver.load(driver.idea) }
        try await driver.waitForRequests(1)
        let other = DetailFixtureDriver.idea("MSFT")
        driver.selection = other
        let second = Task { await driver.load(other) }
        try await driver.waitForRequests(2)
        driver.selection = driver.idea
        let third = Task { await driver.load(driver.idea) }
        try await driver.waitForRequests(3)
        driver.probe.complete(0)
        await first.value
        #expect(driver.evidence.insiderSummary == nil && driver.evidence.insiderLoading)
        #expect(driver.evidence.benzinga == nil && driver.evidence.benzingaLoading,
                "An older cleanup must not clear the replacement's loading state")
        #expect(driver.evidence.disclosures.isEmpty && driver.evidence.disclosuresLoading)
        driver.probe.complete(2)
        await third.value
        driver.probe.complete(1)
        await second.value
        #expect(driver.selection?.symbol == "AAPL" && driver.selection?.price == 103)
        #expect(driver.evidence.insiderSummary?.nonDiscretionaryCount == 3)
        #expect(driver.evidence.disclosures.first?.accessionNumber == "AAPL-2")
        #expect(driver.evidence.benzinga == driver.probe.benzingaSnapshot("AAPL", index: 2))
    }

    @Test func deniedAndRevokedPolicyCannotFetchOrPublish() async throws {
        let driver = DetailFixtureDriver(source: nil)
        driver.selection = driver.idea
        driver.probe.allowed = false
        await driver.load(driver.idea)
        #expect(driver.probe.insiderCalls.isEmpty && driver.probe.filingCalls.isEmpty && driver.probe.quoteCalls.isEmpty)
        driver.probe.allowed = true
        driver.probe.hold = true
        defer { driver.probe.releaseAll() }
        let load = Task { await driver.load(driver.idea) }
        try await driver.waitForRequests(1)
        driver.probe.allowed = false
        driver.probe.complete(0)
        await load.value
        #expect(driver.selection?.price == 100)
        #expect(driver.evidence.insiderSummary == nil && driver.evidence.disclosures.isEmpty)
        #expect(!driver.evidence.insiderLoading && !driver.evidence.disclosuresLoading)
    }

    @Test func unsupportedSECAndMissingResultsLeaveNoOldEvidenceOrSpinner() async {
        let driver = DetailFixtureDriver(source: nil)
        driver.selection = driver.idea
        await driver.load(driver.idea)
        let other = DetailFixtureDriver.idea("2222.SR")
        driver.selection = other
        await driver.load(other)
        #expect(driver.probe.insiderCalls == ["AAPL"] && driver.probe.filingCalls == ["AAPL"])
        #expect(driver.probe.quoteCalls == ["AAPL", "2222.SR"])
        #expect(driver.evidence.insiderSummary == nil && driver.evidence.disclosures.isEmpty)
        driver.probe.empty = true
        driver.selection = driver.idea
        await driver.load(driver.idea)
        #expect(driver.evidence.insiderSummary == nil && driver.evidence.disclosures.isEmpty)
        #expect(!driver.evidence.insiderLoading && !driver.evidence.disclosuresLoading)
    }
}

@MainActor private final class DetailRequestProbe {
    var insiderCalls: [String] = []
    var filingCalls: [String] = []
    var quoteCalls: [String] = []
    var benzingaCalls: [String] = []
    var benzingaCurrent = true
    var benzingaSymbol: String?
    var pendingBenzinga: [CheckedContinuation<StockSageBenzinga.Snapshot?, Never>?] = []
    var hold = false
    var allowed = true
    var empty = false
    var pendingInsider: [CheckedContinuation<StockSageInsider.Summary?, Never>?] = []
    var pendingFilings: [CheckedContinuation<[StockSageDisclosureService.Filing], Never>?] = []
    var pendingQuote: [CheckedContinuation<StockSageQuoteService.LiveQuote?, Never>?] = []
    var publishedPrices: [Double] = []

    func insider(_ symbol: String) async -> StockSageInsider.Summary? {
        insiderCalls.append(symbol)
        if hold { return await withCheckedContinuation { pendingInsider.append($0) } }
        return empty ? nil : summary(symbol, index: insiderCalls.count - 1)
    }
    func filings(_ symbol: String) async -> [StockSageDisclosureService.Filing] {
        filingCalls.append(symbol)
        if hold { return await withCheckedContinuation { pendingFilings.append($0) } }
        return empty ? [] : filing(symbol, index: filingCalls.count - 1)
    }
    func quote(_ symbol: String) async -> StockSageQuoteService.LiveQuote? {
        quoteCalls.append(symbol)
        if hold { return await withCheckedContinuation { pendingQuote.append($0) } }
        return empty ? nil : .init(symbol: symbol, price: 100 + Double(quoteCalls.count), previousClose: 100)
    }
    func benzinga(_ symbol: String) async -> StockSageBenzinga.Snapshot? {
        benzingaCalls.append(symbol)
        if hold { return await withCheckedContinuation { pendingBenzinga.append($0) } }
        return empty ? nil : benzingaSnapshot(symbol, index: benzingaCalls.count - 1)
    }
    func benzingaSnapshot(_ symbol: String, index: Int) -> StockSageBenzinga.Snapshot {
        .init(symbol: benzingaSymbol ?? symbol,
              capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
              credentialGeneration: "fixture-generation", pages: [])
    }
    func publish(_ quote: StockSageQuoteService.LiveQuote) -> StockSageIdea? {
        publishedPrices.append(quote.price)
        return DetailFixtureDriver.idea(quote.symbol).withLivePrice(quote.price, asOf: quote.marketTime)
    }
    func allStarted(_ count: Int) -> Bool {
        insiderCalls.count == count && filingCalls.count == count && quoteCalls.count == count && benzingaCalls.count == count
    }
    func complete(_ index: Int) {
        if pendingBenzinga.indices.contains(index) {
            pendingBenzinga[index]?.resume(returning: benzingaSnapshot(benzingaCalls[index], index: index))
            pendingBenzinga[index] = nil
        }
        if pendingInsider.indices.contains(index) {
            pendingInsider[index]?.resume(returning: summary(insiderCalls[index], index: index)); pendingInsider[index] = nil
        }
        if pendingFilings.indices.contains(index) {
            pendingFilings[index]?.resume(returning: filing(filingCalls[index], index: index)); pendingFilings[index] = nil
        }
        if pendingQuote.indices.contains(index) {
            pendingQuote[index]?.resume(returning: .init(symbol: quoteCalls[index], price: 101 + Double(index), previousClose: 100)); pendingQuote[index] = nil
        }
    }
    func releaseAll() {
        hold = false
        for index in 0..<max(pendingInsider.count, pendingFilings.count, pendingQuote.count, pendingBenzinga.count) { complete(index) }
    }
    private func summary(_ symbol: String, index: Int) -> StockSageInsider.Summary {
        .init(symbol: symbol, discretionary: [], nonDiscretionaryCount: index + 1)
    }
    private func filing(_ symbol: String, index: Int) -> [StockSageDisclosureService.Filing] {
        [.init(accessionNumber: "\(symbol)-\(index)", form: "8-K", filingDate: Date(timeIntervalSince1970: 1_700_000_000),
            acceptedAt: nil, items: [], documentURL: nil)]
    }
}

@MainActor private final class DetailFixtureDriver: ObservableObject {
    var selection: StockSageIdea? {
        get { evidence.selection }
        set { evidence.selection = newValue }
    }
    @Published var source: String?
    @Published var idea = idea("AAPL")
    static func idea(_ symbol: String) -> StockSageIdea { StockSageIdea(symbol: symbol, market: "US", price: 100,
        advice: TradeAdvice(action: .hold, conviction: 0, regime: .range, rationale: [],
            stopPrice: nil, targetPrice: nil, suggestedWeight: 0, caveat: "Fixture only"), spark: []) }
    var cardMounted = false
    var appeared: Set<String> = []
    var completed: [String] = []
    let probe = DetailRequestProbe()
    let evidence: IdeaDetailEvidence
    init(source: String?) {
        self.source = source
        let probe = self.probe
        evidence = IdeaDetailEvidence(fetchInsider: { await probe.insider($0) }, fetchFilings: { await probe.filings($0) },
            fetchQuote: { await probe.quote($0) }, isAllowed: { probe.allowed },
            fetchBenzinga: { await probe.benzinga($0) }, benzingaIsCurrent: { _ in probe.benzingaCurrent })
    }
    func load(_ idea: StockSageIdea) async {
        await evidence.load(for: idea, using: probe.publish)
        completed.append(idea.symbol)
    }
    func waitForRequests(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !probe.allStarted(count), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(probe.allStarted(count), "The real load did not reach the injected request boundary")
    }
}

@MainActor private struct DetailFixtureView: View {
    @ObservedObject var driver: DetailFixtureDriver
    @ObservedObject var evidence: IdeaDetailEvidence

    init(driver: DetailFixtureDriver) {
        self.driver = driver
        self.evidence = driver.evidence
    }

    var body: some View {
        IdeaPriceContent(source: driver.source) { source in Text(source ?? "Unattributed price") }
        .onAppear { driver.cardMounted = true }
        .modifier(IdeaDetailPresentation(selection: $evidence.selection, selectionEpoch: evidence.selectionEpoch,
            load: driver.load) { idea in
            Text(idea.symbol).frame(width: 240, height: 160)
                .onAppear { driver.appeared.insert(idea.symbol) }
        })
    }
}
