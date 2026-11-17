import SwiftUI
import Combine

/// Transient detail selection/evidence: no singleton store or disk access on construction.
@MainActor final class IdeaDetailEvidence: ObservableObject {
    typealias InsiderFetch = @MainActor @Sendable (String) async -> StockSageInsider.Summary?
    typealias FilingsFetch = @MainActor @Sendable (String) async -> StockSageDisclosureService.FilingsObservation
    typealias QuoteFetch = @MainActor @Sendable (String) async -> StockSageQuoteService.LiveQuote?
    typealias QuotePublish = @MainActor @Sendable (StockSageQuoteService.LiveQuote) -> StockSageIdea?
    typealias BenzingaFetch = @MainActor @Sendable (String) async -> StockSageBenzinga.Snapshot?

    @Published var selection: StockSageIdea? {
        didSet {
            guard oldValue?.id != selection?.id else { return }
            // Selection changes precede SwiftUI task cancellation/startup, including A→nil→A.
            generation = UUID()
            selectionEpoch = generation
            symbol = selection?.symbol
            insiderSummary = nil
            filingsObservation = nil
            benzinga = nil
            benzingaLoading = false
            insiderLoading = false
            disclosuresLoading = false
        }
    }
    @Published private(set) var selectionEpoch = UUID()
    @Published private(set) var insiderSummary: StockSageInsider.Summary?
    @Published private(set) var insiderLoading = false
    @Published private(set) var filingsObservation: StockSageDisclosureService.FilingsObservation?
    var disclosures: [StockSageDisclosureService.Filing] { filingsObservation?.filings ?? [] }
    @Published private(set) var disclosuresLoading = false
    @Published private(set) var symbol: String?
    @Published private(set) var benzinga: StockSageBenzinga.Snapshot?
    @Published private(set) var benzingaLoading = false
    private let fetchInsider: InsiderFetch
    private let fetchFilings: FilingsFetch
    private let fetchQuote: QuoteFetch
    private let fetchBenzinga: BenzingaFetch
    private let benzingaIsCurrent: @MainActor @Sendable (StockSageBenzinga.Snapshot) -> Bool
    private let isAllowed: @MainActor @Sendable () -> Bool
    private var generation = UUID()

    init(fetchInsider: @escaping InsiderFetch = { await StockSageInsider.recentActivity(for: $0) },
         fetchFilings: @escaping FilingsFetch = {
             await StockSageDisclosureService.recentFilingsObservation(for: $0, forms: ["8-K"], limit: 5)
         }, fetchQuote: @escaping QuoteFetch = { await StockSageQuoteService.fetchQuotes(for: [$0])[$0.uppercased()] },
         isAllowed: @escaping @MainActor @Sendable () -> Bool = { ToolPolicy.webToolsDisabledReason() == nil },
         fetchBenzinga: @escaping BenzingaFetch = { _ in nil },
         benzingaIsCurrent: @escaping @MainActor @Sendable (StockSageBenzinga.Snapshot) -> Bool = { _ in true }) {
        self.fetchInsider = fetchInsider
        self.fetchFilings = fetchFilings
        self.fetchQuote = fetchQuote
        self.fetchBenzinga = fetchBenzinga
        self.benzingaIsCurrent = benzingaIsCurrent
        self.isAllowed = isAllowed
    }

    private func loadInsider(for symbol: String, isCurrent: @MainActor @Sendable () -> Bool) async {
        guard !symbol.contains("."), isCurrent() else { return }
        insiderLoading = true
        let summary = await fetchInsider(symbol)
        guard isCurrent() else { return }
        insiderSummary = summary?.symbol.uppercased() == symbol.uppercased() ? summary : nil
        insiderLoading = false
    }

    private func loadFilings(for symbol: String, isCurrent: @MainActor @Sendable () -> Bool) async {
        guard !symbol.contains("."), isCurrent() else { return }
        disclosuresLoading = true
        let filings = await fetchFilings(symbol)
        guard isCurrent() else { return }
        filingsObservation = filings
        disclosuresLoading = false
    }

    private func refreshQuote(for idea: StockSageIdea, using publish: QuotePublish,
                              isCurrent: @MainActor @Sendable () -> Bool) async {
        guard isCurrent() else { return }
        guard let quote = await fetchQuote(idea.symbol), quote.symbol.uppercased() == idea.symbol.uppercased(),
              isCurrent() else { return }
        // No suspension between ownership validation and the shared board merge.
        guard let updated = publish(quote), updated.id == idea.id else { return }
        selection = updated
    }

    private func loadBenzinga(for symbol: String, isCurrent: @MainActor @Sendable () -> Bool) async {
        guard isCurrent() else { return }
        benzingaLoading = true
        let captured = await fetchBenzinga(symbol)
        guard isCurrent() else { return }
        benzingaLoading = false
        guard let captured, captured.symbol.uppercased() == symbol.uppercased(), benzingaIsCurrent(captured) else { return }
        benzinga = captured
    }

    func load(for idea: StockSageIdea, using publish: QuotePublish) async {
        guard !Task.isCancelled, selection?.id == idea.id else { return }
        let request = UUID()
        generation = request
        symbol = idea.symbol
        insiderSummary = nil
        filingsObservation = nil
        benzinga = nil
        benzingaLoading = false
        insiderLoading = false
        disclosuresLoading = false
        defer {
            // An older cancelled request must not clear the replacement's loading flags.
            if generation == request { insiderLoading = false; disclosuresLoading = false; benzingaLoading = false }
        }
        let isCurrent: @MainActor @Sendable () -> Bool = {
            !Task.isCancelled && self.generation == request && self.selection?.id == idea.id && self.isAllowed()
        }
        async let insider: Void = loadInsider(for: idea.symbol, isCurrent: isCurrent)
        async let filings: Void = loadFilings(for: idea.symbol, isCurrent: isCurrent)
        async let quote: Void = refreshQuote(for: idea, using: publish, isCurrent: isCurrent)
        async let productEvidence: Void = loadBenzinga(for: idea.symbol, isCurrent: isCurrent)
        _ = await (insider, filings, quote, productEvidence)
    }
}

/// Price rendering is deliberately free of requests and navigation side effects.
struct IdeaPriceContent<Label: View>: View {
    let source: String?
    @ViewBuilder let label: (String?) -> Label

    var body: some View { label(source) }
}

/// The same presentation boundary is exercised by the isolated lifecycle tests.
struct IdeaDetailPresentation<Detail: View>: ViewModifier {
    @Binding var selection: StockSageIdea?
    let selectionEpoch: UUID
    let load: @MainActor @Sendable (StockSageIdea) async -> Void
    @ViewBuilder let detail: (StockSageIdea) -> Detail

    func body(content: Content) -> some View {
        content.sheet(item: $selection) { idea in
            detail(idea).task(id: selectionEpoch) { await load(idea) }
        }
    }
}
