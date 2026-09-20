import Foundation
import CryptoKit
import Combine

/// App-lifetime watcher. No scheduler, model fallback or broker dependency.
@MainActor final class StockSageMicrocapMonitor: ObservableObject {
    static let shared = StockSageMicrocapMonitor()
    @Published private(set) var isEnabled = false
    @Published private(set) var status = "Watching is off. Pair Telegram, then enable fresh-setup assessments."
    @Published private(set) var nextCheck: Date?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var claimFailure: String?
    private let directory: URL?
    private let requireWriter: () throws -> Void
    static let interval: TimeInterval = 300

    init(directory: URL? = nil, requireWriter: @escaping () throws -> Void = { try StockSageRecordWriter.require(.standard) }) {
        self.directory = directory ?? (StockSageStore.isRunningTests ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("StockSage/MicrocapResearch", isDirectory: true))
        self.requireWriter = requireWriter
    }

    nonisolated static func setupID(symbol: String, facts: [StockSageAIAssessment.EvidenceFact], at: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let parts = calendar.dateComponents([.year, .month, .day], from: at)
        let catalysts = Set(facts.filter { $0.key.hasPrefix("sameDay.catalyst.") }.map(\.text)).sorted()
        let fields = [symbol.uppercased(), "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"] + catalysts
        let bytes = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Commit an attempt before consuming subscription usage. Damage blocks, never erases history.
    func claim(_ id: String) -> Bool {
        claimFailure = nil
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }), let directory else {
            status = "Setup tracking is unavailable; no automatic assessment started."; claimFailure = status; return false
        }
        do {
            try requireWriter()
            for folder in [directory.deletingLastPathComponent(), directory] where FileManager.default.fileExists(atPath: folder.path) {
                let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = directory.appendingPathComponent("automatic-setups.json")
            let marker = directory.appendingPathComponent("automatic-setups.initialized")
            let activated = FileManager.default.fileExists(atPath: marker.path)
            if activated {
                let attributes = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, attributes.fileSize == 1,
                      try Data(contentsOf: marker) == Data([1]), FileManager.default.fileExists(atPath: path.path) else { throw CocoaError(.fileReadCorruptFile) }
            }
            var ids = Set<String>()
            if FileManager.default.fileExists(atPath: path.path) {
                let attributes = try path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      let size = attributes.fileSize, size <= 8_000_000 else { throw CocoaError(.fileReadCorruptFile) }
                ids = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: path))
                guard ids.count <= 100_000, ids.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else { throw CocoaError(.fileReadCorruptFile) }
            }
            guard !ids.contains(id) else { return false }
            guard ids.count < 100_000 else { status = "Saved setup tracking reached its limit. Existing attempts are preserved; watching cannot assess new setups."; claimFailure = status; return false }
            // A failed first write leaves a marker and blocks restart instead of forgetting an attempted setup.
            if !activated { try Data([1]).write(to: marker, options: [.withoutOverwriting, .completeFileProtection]) }
            ids.insert(id)
            try JSONEncoder().encode(ids).write(to: path, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return true
        } catch { status = "Setup history could not be saved or verified. No automatic assessment started; existing records are preserved."; claimFailure = status; return false }
    }

    func stop() {
        generation = UUID(); isEnabled = false; nextCheck = nil
        task?.cancel(); task = nil
        StockSageSameDayResearch.microcap.stop()
        status = "Watching stopped. Saved research and alert attempts remain available."
    }

    #if os(macOS)
    func start(store: StockSageStore) {
        guard !isEnabled, !StockSageStore.isRunningTests else { return }
        guard StockSageTelegram.shared.isReady else { status = "Finish private Telegram pairing before enabling watching."; return }
        guard ToolPolicy.isExternalAllowed, !store.isSampleData else { status = "Enable current market access before watching."; return }
        if let blocker = StockSageMassive.credentialAccessBlocker() { status = blocker; return }
        guard (try? requireWriter()) != nil else { status = "The research writer is unavailable."; return }
        let access = StockSageMassive.Access().capture(), run = UUID()
        let pairing = StockSageTelegram.shared.pairingRevision
        generation = run; isEnabled = true
        StockSageLiveStream.shared.start(symbols: [])
        let research = StockSageSameDayResearch.microcap
        task = Task { [weak self] in
            guard let self else { return }
            @MainActor func active() -> Bool { !Task.isCancelled && self.generation == run && self.isEnabled && access.isCurrent() && !store.isSampleData && StockSageTelegram.shared.isReady && StockSageTelegram.shared.pairingRevision == pairing }
            var ownedRun: UUID?
            var admissionFailure: String?
            while active() {
                let now = Date()
                guard let session = StockSageSameDayResearch.session(at: now), now >= session.open.addingTimeInterval(1800) else {
                    self.status = "Waiting for a verified US regular session with thirty completed minutes. Mac must remain awake and StockSage open."
                    self.nextCheck = nil
                    try? await Task.sleep(for: .seconds(30)); continue
                }
                if research.isRunning || StockSageSameDayResearch.shared.isRunning || StockSageHorizonResearch.shared.running != nil {
                    self.status = "Waiting for the current research run to finish."
                    try? await Task.sleep(for: .seconds(5)); continue
                }
                if let next = self.nextCheck, next > now {
                    try? await Task.sleep(for: .seconds(min(5, next.timeIntervalSince(now)))); continue
                }
                self.status = "Checking for a fresh qualifying setup…"
                let prior = Set(research.savedReceipts.flatMap(\.checks).compactMap(\.setupID))
                let started = research.start(store: store, admitSetup: { [weak self] id in
                    guard active(), admissionFailure == nil, !prior.contains(id), let self else { return false }
                    let claimed = self.claim(id)
                    if let failure = self.claimFailure { admissionFailure = failure }
                    return claimed
                })
                if started {
                    let runID = research.receipt?.id
                    ownedRun = runID
                    while research.isRunning, active() { try? await Task.sleep(for: .milliseconds(250)) }
                    guard active() else { break }
                    ownedRun = nil
                    if admissionFailure != nil { break }
                    if let receipt = research.receipt, receipt.id == runID,
                       let check = receipt.checks.first(where: { $0.symbol == receipt.selectedSymbol }),
                       let text = Self.alert(receipt, at: Date()), let id = check.setupID {
                        let delivery = await StockSageTelegram.shared.send(text: text, deliveryID: id, stillValid: {
                            active() && research.receipt?.id == receipt.id && StockSageSameDayResearch.current(receipt, at: Date())
                        })
                        guard active() else { break }
                        switch delivery {
                        case .delivered: self.status = "Fresh qualified pick sent to your paired Telegram chat."
                        case .alreadyAttempted: self.status = "This setup already has a recorded Telegram attempt; no duplicate was sent."
                        case .blocked: self.status = "Telegram delivery was blocked or the pick expired. The research is saved."
                        case .unknown: self.status = "Telegram delivery could not be confirmed. Check your phone; this attempt will not retry automatically."
                        }
                    } else { self.status = research.status }
                } else { self.status = research.status }
                self.nextCheck = Date().addingTimeInterval(Self.interval)
            }
            if self.generation == run {
                if let ownedRun, research.receipt?.id == ownedRun, research.isRunning { research.stop() }
                self.isEnabled = false; self.nextCheck = nil; self.task = nil
                self.status = admissionFailure ?? "Watching paused because access, pairing or app activity changed. Enable it again after checking setup."
            }
        }
    }
    #endif

    nonisolated static func alert(_ receipt: StockSageSameDayResearch.Receipt, at now: Date) -> String? {
        guard receipt.mode == .microcap, receipt.finishedAt != nil, receipt.blocker == nil,
              StockSageSameDayResearch.current(receipt, at: now),
              let check = receipt.checks.first(where: { $0.symbol == receipt.selectedSymbol }), check.qualified,
              check.codexAudit?.requestedModel == "gpt-6-astra", let plan = check.scenario else { return nil }
        func price(_ value: Double) -> String { String(format: "$%.4f", locale: Locale(identifier: "en_US_POSIX"), value) }
        return "StockSage · Micro cap · \(check.symbol)\nGPT-6 Astra · same-day research\nObserved buy ceiling: \(price(plan.entry))\nStop reference: \(price(plan.stop))\nTarget reference: \(price(plan.target))\nQuote checked: \(check.verifiedQuote?.at.ISO8601Format() ?? "unavailable")\n\(check.reason ?? "")\nRisk: \(check.risk ?? "")\nUnvalidated screen; public Massive evidence. Dated research, not an order or a live execution guarantee. Recheck the market in StockSage before acting."
    }
}
