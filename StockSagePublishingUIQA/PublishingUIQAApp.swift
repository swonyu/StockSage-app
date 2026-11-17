#if !os(iOS) || !targetEnvironment(simulator)
#error("The publishing UI fixture is an isolated iOS Simulator app only.")
#endif
import Foundation
import Combine
import SwiftUI
import UIKit

private let publishingBundleID = "SA.StockSage.PublishingUIQA"

@MainActor
private struct PublishingCase {
    let name: String
    let route: String
    let textSize: DynamicTypeSize
    let textName: String
    let category: UIContentSizeCategory

    static let all: [String: PublishingCase] = [
        "browse-large": .init(name: "browse-large", route: "browse", textSize: .large, textName: "large", category: .large),
        "browse-accessibility3": .init(name: "browse-accessibility3", route: "browse", textSize: .accessibility3, textName: "accessibility3", category: .accessibilityExtraLarge),
        "browse-accessibility5": .init(name: "browse-accessibility5", route: "browse", textSize: .accessibility5, textName: "accessibility5", category: .accessibilityExtraExtraExtraLarge),
        "onboarding-large": .init(name: "onboarding-large", route: "onboarding", textSize: .large, textName: "large", category: .large),
        "onboarding-accessibility3": .init(name: "onboarding-accessibility3", route: "onboarding", textSize: .accessibility3, textName: "accessibility3", category: .accessibilityExtraLarge),
        "navigation-large": .init(name: "navigation-large", route: "navigation", textSize: .large, textName: "large", category: .large),
        "navigation-restore-legacy": .init(name: "navigation-restore-legacy", route: "navigation", textSize: .large, textName: "large", category: .large),
        "navigation-restore-chat": .init(name: "navigation-restore-chat", route: "navigation", textSize: .large, textName: "large", category: .large),
        "personal-records-large": .init(name: "personal-records-large", route: "personal", textSize: .large, textName: "large", category: .large),
        "personal-records-accessibility3": .init(name: "personal-records-accessibility3", route: "personal", textSize: .accessibility3, textName: "accessibility3", category: .accessibilityExtraLarge)
    ]
}

@MainActor
private final class PublishingContext: ObservableObject {
    let fixture: PublishingCase
    let runID: String
    let defaults: UserDefaults
    let store: StockSageStore?
    let portfolio: StockSagePortfolio
    let journal: StockSageJournalStore
    let originalSymbols: [String]
    let chat = StockSageChatSession(historyURL: nil)
    private var visitedPhoneTabs: Set<String> = []
    private var navigationCompleted = false
    private var personalCompleted = false
    let output: URL
    @Published var onboardingPresented = true
    @Published var browsePresented = false
    @Published var browseCompleted = false
    private(set) var browseWasPresented = false
    var geometry: (() -> [String: Any])?

    init() {
        precondition(Bundle.main.bundleIdentifier == publishingBundleID, "Unexpected QA identity")
        precondition(!StockSageStore.isRunningTests, "Standalone UI fixture must not impersonate a hosted test runtime")
        let args = CommandLine.arguments
        func one(_ key: String) -> String {
            let indices = args.indices.filter { args[$0] == key }
            precondition(indices.count == 1 && indices[0] + 1 < args.count, "Missing or duplicate QA argument")
            return args[indices[0] + 1]
        }
        let selected = one("--publishing-case")
        guard let value = PublishingCase.all[selected] else { preconditionFailure("Unknown case") }
        let runValue = one("--publishing-run-id")
        precondition(runValue.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil, "Invalid owned run ID")
        precondition(one("-set_offlineOnly") == "YES" && one("-set_webAccess") == "NO", "Missing offline arguments")
        let localDefaults = UserDefaults.standard
        // This is the new, dedicated simulator app's domain, never the shipping app.
        localDefaults.removePersistentDomain(forName: publishingBundleID)
        localDefaults.set(false, forKey: "stocksage.liveStream")
        localDefaults.set(false, forKey: "stocksage.autoRefresh")
        localDefaults.set(false, forKey: "stocksage.onboarding.done")
        if selected == "navigation-restore-legacy" {
            localDefaults.set("weekResearch", forKey: MarketSection.phoneSelectionKey)
        } else if selected == "navigation-restore-chat" {
            localDefaults.set("chat", forKey: MarketSection.phoneSelectionKey)
        }
        ToolPolicy.override = .localOnly
        precondition(AppSettings.isOfflineOnly && !ToolPolicy.isExternalAllowed, "Policy must be local-only before rendering")
        let localStore: StockSageStore?
        let localPortfolio = StockSagePortfolio(userDefaults: localDefaults)
        let localJournal = StockSageJournalStore(defaults: localDefaults)
        let symbols: [String]
        if value.route == "browse" || value.route == "navigation" || value.route == "personal" {
            let candidate = StockSageStore(defaults: localDefaults,
                heldSymbols: { localPortfolio.positions.map(\.symbol) }, journalTrades: { localJournal.trades })
            precondition(candidate.watchlistPersistenceError == nil && candidate.addSymbolError == nil,
                         "Fresh QA record storage failed")
            localStore = candidate
            symbols = candidate.userSymbols
        } else {
            localStore = nil
            symbols = []
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let location = documents.appendingPathComponent("PublishingUIQA", isDirectory: true)
            .appendingPathComponent(runValue, isDirectory: true)
            .appendingPathComponent(value.name, isDirectory: true)
        precondition(!FileManager.default.fileExists(atPath: location.path), "Case cannot run twice")
        do { try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true) }
        catch { preconditionFailure("Could not create owned QA evidence: \(error)") }
        fixture = value
        runID = runValue
        defaults = localDefaults
        store = localStore
        portfolio = localPortfolio
        journal = localJournal
        originalSymbols = symbols
        output = location
    }

    var onboardingState: String {
        "bindingDismissed=\(!onboardingPresented);done=\(defaults.bool(forKey: "stocksage.onboarding.done"))"
    }
    var browseState: String {
        "sheetDismissed=\(!browsePresented);symbolsUnchanged=\(store?.userSymbols == originalSymbols);addErrorAbsent=\(store?.addSymbolError == nil)"
    }

    func record(_ phase: String) {
        precondition(["started", "opened", "completed"].contains(phase)
                     || ["watchlist", "portfolio", "chat", "library"].contains(String(phase.dropFirst(4))) && phase.hasPrefix("tab-"),
                     "Unknown evidence phase")
        guard let geometry else { preconditionFailure("Geometry unavailable") }
        let frames = geometry()
        let policyLocal = AppSettings.isOfflineOnly && !ToolPolicy.isExternalAllowed
        precondition(policyLocal, "Offline policy changed")
        var value: [String: Any] = [
            "schema_version": 1, "run_id": runID, "case_id": fixture.name,
            "route": fixture.route, "dynamic_type": fixture.textName,
            "phase": phase, "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "local_only": policyLocal, "offline_only": AppSettings.isOfflineOnly,
            "web_external_allowed": ToolPolicy.isExternalAllowed,
            "hosted_test_runtime": StockSageStore.isRunningTests,
            "onboarding_presented": onboardingPresented,
            "onboarding_done": defaults.bool(forKey: "stocksage.onboarding.done"),
            "browse_presented": browsePresented,
            "browse_was_presented": browseWasPresented,
            "symbols_before": originalSymbols,
            "symbols_after": store?.userSymbols ?? [],
            "symbols_unchanged": store?.userSymbols == originalSymbols || fixture.route != "browse",
            "add_error_absent": store?.addSymbolError == nil,
            "stored_phone_tab": defaults.string(forKey: MarketSection.phoneSelectionKey) ?? "",
            "visited_phone_tabs": visitedPhoneTabs.sorted(),
            "geometry": frames
        ]
        value["recorded_at"] = ISO8601DateFormatter().string(from: Date())
        if fixture.route == "personal" {
            value["manual_record_count"] = store?.manualPriceBook.records.count ?? 0
            value["holding_count"] = portfolio.positions.count
            value["personal_records_completed"] = personalCompleted
            if let price = store?.manualPriceBook.records.first {
                value["recorded_symbol"] = price.symbol
                value["recorded_raw_price"] = price.rawPrice
                value["recorded_currency"] = price.denomination.currencyCode
                value["recorded_units_per_major"] = price.denomination.rawUnitsPerMajor.rawValue
                value["recorded_provenance"] = price.denomination.provenance.rawValue
                value["price_observed_at"] = price.observedAt.timeIntervalSince1970
                value["price_recorded_at"] = price.recordedAt.timeIntervalSince1970
                if let holding = portfolio.positions.first {
                    value["holding_symbol"] = holding.symbol
                    value["holding_shares"] = holding.shares
                    value["holding_cost_basis"] = holding.costBasis
                    value["holding_cost_currency"] = holding.costDenomination?.currencyCode
                    value["holding_cost_units_per_major"] = holding.costDenomination?.rawUnitsPerMajor.rawValue
                    if let result = StockSageRecordedValuation.holding(holding, quote: price.quote, now: Date()) {
                        value["holding_value"] = result.value
                        value["holding_value_currency"] = result.currency
                        value["holding_profit"] = result.profit
                    }
                }
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: output.appendingPathComponent(phase + ".json"), options: .atomic)
        } catch { preconditionFailure("Could not preserve native QA state: \(error)") }
    }

    func observePhoneSelection() {
        guard fixture.route == "navigation",
              let selected = defaults.string(forKey: MarketSection.phoneSelectionKey),
              ["watchlist", "portfolio", "chat", "library"].contains(selected) else { return }
        if visitedPhoneTabs.insert(selected).inserted { record("tab-" + selected) }
        let complete = fixture.name == "navigation-large"
            ? visitedPhoneTabs == Set(["watchlist", "portfolio", "chat", "library"])
            : selected == (fixture.name == "navigation-restore-chat" ? "chat" : "watchlist")
        if complete && !navigationCompleted { navigationCompleted = true; record("completed") }
    }

    func observePersonalRecords() {
        guard fixture.route == "personal", !personalCompleted, let store,
              store.userSymbols == ["CSPX.L"],
              store.manualPriceBook.records.count == 1, portfolio.positions.count == 1,
              let price = store.manualPriceBook.records.first,
              let holding = portfolio.positions.first,
              price.symbol == "CSPX.L", price.rawPrice == 600,
              price.denomination.currencyCode == "USD", price.denomination.rawUnitsPerMajor == .major,
              price.denomination.provenance == .manualEntry,
              holding.symbol == "CSPX.L", holding.shares == 2, holding.costBasis == 500,
              holding.costDenomination?.currencyCode == "USD",
              holding.costDenomination?.rawUnitsPerMajor == .major,
              let result = StockSageRecordedValuation.holding(holding, quote: price.quote, now: Date()),
              result.currency == "USD", result.value == 1_200, result.profit == 200 else { return }
        personalCompleted = true
        record("completed")
    }

    func openBrowse() {
        precondition(fixture.route == "browse" && !browseWasPresented)
        browseWasPresented = true
        browsePresented = true
        record("opened")
    }

    func finishBrowse() {
        precondition(browseWasPresented && !browsePresented, "No real sheet dismissal")
        browseCompleted = true
        record("completed")
    }

    func setOnboardingPresented(_ value: Bool) {
        let old = onboardingPresented
        onboardingPresented = value
        if old && !value { record("completed") }
    }
}

@MainActor
private struct PublishingRoot: View {
    @ObservedObject var context: PublishingContext
    var body: some View {
        Group {
            if context.fixture.route == "navigation" || context.fixture.route == "personal" {
                MarketsView(chatSession: context.chat, store: context.store!,
                    portfolio: context.portfolio, journal: context.journal)
                    .defaultAppStorage(context.defaults)
                    .onAppear { context.observePhoneSelection() }
                    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                        context.observePhoneSelection()
                    }
                    .onReceive(context.portfolio.$positions) { _ in
                        // Published values arrive before the stored property changes.
                        Task { @MainActor in await Task.yield(); context.observePersonalRecords() }
                    }
                    .onReceive(context.store!.manualPriceBook.$records) { _ in
                        Task { @MainActor in await Task.yield(); context.observePersonalRecords() }
                    }
            } else if context.fixture.route == "onboarding" {
                if context.onboardingPresented {
                    OnboardingSheet(isPresented: Binding(
                        get: { context.onboardingPresented },
                        set: { context.setOnboardingPresented($0) }))
                        .defaultAppStorage(context.defaults)
                } else {
                    Text(context.onboardingState)
                        .font(.caption2).dynamicTypeSize(.large)
                        .accessibilityIdentifier("qa.onboarding.completed")
                        .padding()
                }
            } else {
                VStack(spacing: 16) {
                    Button("Open fixture sheet") { context.openBrowse() }
                        .accessibilityIdentifier("fixture.openSheet")
                    if context.browseCompleted {
                        Text(context.browseState)
                            .font(.caption2).dynamicTypeSize(.large)
                            .accessibilityIdentifier("qa.browse.completed")
                    }
                }
                .sheet(isPresented: $context.browsePresented, onDismiss: { context.finishBrowse() }) {
                    BrowseMarketsView(store: context.store!)
                        .defaultAppStorage(context.defaults)
                        .environment(\.dynamicTypeSize, context.fixture.textSize)
                }
            }
        }
        .environment(\.dynamicTypeSize, context.fixture.textSize)
        .preferredColorScheme(.dark)
        .tint(DS.Palette.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.bgTop)
    }
}

@MainActor
private final class PublishingHostingController: UIHostingController<AnyView> {
    var didAppear: (() -> Void)?
    private var recorded = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !recorded { recorded = true; didAppear?() }
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
}

@MainActor
final class PublishingQASceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var context: PublishingContext?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { preconditionFailure("Missing native phone scene") }
        let context = PublishingContext()
        self.context = context
        let window = UIWindow(windowScene: scene)
        // Natural scene geometry; no artificial frame or fixed inner container.
        let host = PublishingHostingController(rootView: AnyView(PublishingRoot(context: context)))
        window.overrideUserInterfaceStyle = .dark
        window.traitOverrides.preferredContentSizeCategory = context.fixture.category
        host.view.backgroundColor = UIColor(DS.Palette.bgTop)
        window.rootViewController = host
        self.window = window
        let requestedCategory = context.fixture.category.rawValue
        context.geometry = { [weak window, weak host] in
            guard let window, let host, let scene = window.windowScene else { preconditionFailure("Window lost") }
            func frame(_ r: CGRect) -> [String: CGFloat] {
                ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
            }
            let screen = scene.screen
            return [
                "screen_bounds": frame(screen.bounds), "screen_native_bounds": frame(screen.nativeBounds),
                "screen_scale": screen.scale, "screen_native_scale": screen.nativeScale,
                "scene_bounds": frame(scene.coordinateSpace.bounds), "window_frame": frame(window.frame),
                "hosting_view_frame_in_window": frame(host.view.convert(host.view.bounds, to: window)),
                "safe_area_top": host.view.safeAreaInsets.top, "safe_area_bottom": host.view.safeAreaInsets.bottom,
                "interface_orientation": scene.interfaceOrientation.rawValue,
                "artificial_window_resize": false, "fixed_inner_container": false,
                "requested_content_size_category": requestedCategory,
                "content_size_category": window.traitCollection.preferredContentSizeCategory.rawValue
            ]
        }
        host.didAppear = { context.record("started") }
        window.makeKeyAndVisible()
    }
}

@main
@MainActor
final class PublishingQAAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { true }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "PublishingUIQA", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = PublishingQASceneDelegate.self
        return configuration
    }
}

