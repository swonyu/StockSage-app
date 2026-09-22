import Foundation
import UserNotifications
import OSLog
#if os(iOS)
import AVFoundation
import Combine
import UIKit
#endif

@MainActor enum StockSageNotificationDelivery {
    static func enqueue(_ content: UNMutableNotificationContent, event: StockSageAlertSound,
                        brief: String) async -> Bool {
        #if os(iOS)
        content.userInfo["stocksage.audio.event"] = event.rawValue
        content.userInfo["stocksage.audio.brief"] = brief
        content.sound = StockSageNotificationHandler.shared.backgroundSound(for: event)
        #else
        content.sound = .default
        #endif
        do {
            try await UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString,
                content: content, trigger: nil))
            return true
        } catch {
            Logger(subsystem: "StockSage", category: "notifications").error("Notification enqueue failed")
            return false
        }
    }
}

/// Keeps restored history and subsequent outcome reviews quiet. A completion is
/// eligible once, only for research started after this observer was attached.
nonisolated struct StockSageResearchNotificationGate {
    let observedFrom: Date
    private(set) var seen: Set<UUID> = []
    mutating func accept(id: UUID, startedAt: Date, finishedAt: Date?, now: Date) -> Bool {
        guard let finishedAt, startedAt >= observedFrom, finishedAt >= startedAt,
              finishedAt <= now.addingTimeInterval(5), now.timeIntervalSince(finishedAt) <= 120,
              !seen.contains(id) else { return false }
        seen.insert(id)
        return true
    }
}

#if os(iOS)
@MainActor final class StockSageNotificationHandler: NSObject, ObservableObject,
    AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = StockSageNotificationHandler()
    @Published private(set) var status = ""
    @Published private(set) var output = "iPhone speaker / current output"
    private let speech = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var utterance: AVSpeechUtterance?
    private struct AudioEvent { let cue: StockSageAlertSound; let brief: String }
    private var current: AudioEvent?
    private var pending: AudioEvent?
    private var observers: Set<AnyCancellable> = []
    private var researchGate = StockSageResearchNotificationGate(observedFrom: Date())
    private var cleanup: Task<Void, Never>?
    private let log = Logger(subsystem: "StockSage", category: "notification-audio")

    private override init() {
        super.init()
        speech.delegate = self
        speech.usesApplicationAudioSession = true
        refreshOutput()
    }

    func refreshOutput() {
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs
        output = ports.isEmpty ? "iPhone speaker / current output" : ports.map(\.portName).joined(separator: ", ")
    }

    func startObservingResearch() {
        guard observers.isEmpty, !StockSageStore.isRunningTests else { return }
        researchGate = .init(observedFrom: Date())
        StockSageResearchHistory.shared.$runs.dropFirst().sink { [weak self] runs in
            guard let self else { return }
            for run in runs.reversed() {
                guard self.researchGate.accept(id: run.id, startedAt: run.startedAt,
                    finishedAt: run.completedAt, now: Date()) else { continue }
                let count = run.coverage.qualifiedBuyCount
                let body = count.map { "\($0) qualified candidates." } ?? "Open the saved results."
                self.researchReady(title: "\(run.horizon.title) research ready",
                    body: body + (run.coverage.incomplete > 0 ? " \(run.coverage.incomplete) incomplete checks." : "") + " No orders placed.",
                    brief: "Research ready. " + body + (run.coverage.incomplete > 0 ? " Some checks incomplete." : "") + " No orders.",
                    event: .research)
            }
        }.store(in: &observers)
        for research in [StockSageSameDayResearch.shared, .microcap, .largecap] {
            research.$receipt.dropFirst().sink { [weak self] receipt in
                guard let self, let receipt,
                      self.researchGate.accept(id: receipt.id, startedAt: receipt.startedAt,
                        finishedAt: receipt.finishedAt, now: Date()) else { return }
                let title = (receipt.mode ?? research.mode).title
                if receipt.blocker != nil {
                    self.researchReady(title: "\(title) research needs attention",
                        body: "Research stopped or could not be saved. Open StockSage for details. No orders placed.",
                        brief: "Research needs attention. Open StockSage for details.", event: .price)
                } else {
                    let pick = receipt.selectedSymbol
                    self.researchReady(title: "\(title) research ready",
                        body: pick.map { "Research candidate: \($0). Review the saved evidence. No orders placed." }
                            ?? "No qualified candidate selected. Review the saved checks. No orders placed.",
                        brief: pick.map { "Research ready. Candidate \($0). Review the evidence. No orders." }
                            ?? "Research ready. No qualified candidate. No orders.", event: .research)
                }
            }.store(in: &observers)
        }
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.refreshOutput() }
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).sink { [weak self] _ in
            Task { @MainActor in self?.stopAudio() }
        }.store(in: &observers)
    }

    private func researchReady(title: String, body: String, brief: String, event: StockSageAlertSound) {
        guard StockSageNotificationAudioPreferences().research else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        content.userInfo["stocksage.research.ready"] = true
        Task {
            guard StockSageNotificationAudioPreferences().research else { return }
            _ = await StockSageNotificationDelivery.enqueue(content, event: event, brief: brief)
        }
    }

    func backgroundSound(for event: StockSageAlertSound) -> UNNotificationSound? {
        let preferences = StockSageNotificationAudioPreferences()
        guard preferences.chime else { return nil }
        let tone = preferences.tone(for: event)
        if preferences.gainDB == 0 { return tone.notificationSound }
        do {
            let directory = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Sounds", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "v1-\(-preferences.gainDB)dB-" + tone.rawValue
            let file = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) {
                guard let url = tone.resourceURL,
                      let data = StockSageNotificationWave.attenuate(try Data(contentsOf: url), amplitude: preferences.amplitude)
                else { log.error("Notification sound resource is unavailable"); return nil }
                try data.write(to: file, options: .atomic)
            }
            return UNNotificationSound(named: .init(rawValue: name))
        } catch { log.error("Notification gain sound could not be prepared"); return nil }
    }

    func present(_ content: UNNotificationContent) async -> UNNotificationPresentationOptions {
        guard let raw = content.userInfo["stocksage.audio.event"] as? String,
              let cue = StockSageAlertSound(rawValue: raw) else { return [.banner, .list, .sound] }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.soundSetting == .enabled, UIApplication.shared.applicationState == .active {
            let brief = content.userInfo["stocksage.audio.brief"] as? String ?? content.title
            enqueueAudio(.init(cue: cue, brief: brief))
        }
        // Foreground audio is owned here; requesting the OS sound too would double-play it.
        return [.banner, .list]
    }

    func preview(_ cue: StockSageAlertSound) {
        stopAudio()
        let brief: String
        switch cue {
        case .buy: brief = "Buy alert preview. Research only."
        case .sell: brief = "Sell alert preview. Research only."
        case .price: brief = "Price alert preview. Your saved level was reached."
        case .research: brief = "Ta da. Research is ready. Review your results."
        }
        enqueueAudio(.init(cue: cue, brief: brief))
    }

    private func enqueueAudio(_ event: AudioEvent) {
        if current != nil { pending = event; return } // one current + newest pending, never a spoken backlog
        let preferences = StockSageNotificationAudioPreferences()
        guard preferences.chime || preferences.speech else { status = "Chimes and spoken briefs are off."; return }
        current = event
        do {
            let session = AVAudioSession.sharedInstance()
            switch preferences.mixing {
            case .mix: try session.setCategory(.ambient, mode: .default)
            case .duck: try session.setCategory(.ambient, mode: .default, options: [.duckOthers])
            case .pause: try session.setCategory(.soloAmbient, mode: .default)
            }
            try session.setActive(true)
            refreshOutput(); status = "Playing on \(output)"
            cleanup = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }; self?.stopAudio()
            }
            if preferences.chime, let url = preferences.tone(for: event.cue).resourceURL {
                let next = try AVAudioPlayer(contentsOf: url)
                player = next; next.delegate = self; next.volume = preferences.amplitude
                if next.play() { return }
            }
            speakCurrent()
        } catch {
            log.error("Alert audio start failed"); stopAudio()
            status = "Audio could not start. Check your output and try Preview again."
        }
    }

    private func speakCurrent() {
        player = nil
        let preferences = StockSageNotificationAudioPreferences()
        guard preferences.speech, let current else { finishAudio(); return }
        let text = current.brief.split(whereSeparator: \.isWhitespace).prefix(20).joined(separator: " ")
        let next = AVSpeechUtterance(string: text)
        next.rate = 0.55; next.volume = preferences.amplitude
        if !preferences.voice.isEmpty { next.voice = AVSpeechSynthesisVoice(identifier: preferences.voice) }
        utterance = next; speech.speak(next)
    }

    private func finishAudio() {
        cleanup?.cancel(); cleanup = nil
        current = nil; player = nil; utterance = nil
        if let next = pending { pending = nil; enqueueAudio(next); return }
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { log.error("Alert audio session release failed") }
        status = "Ready. Silent mode and phone volume still apply."
    }

    func stopAudio() {
        pending = nil; current = nil; utterance = nil
        player?.stop(); player = nil
        speech.stopSpeaking(at: .immediate)
        finishAudio()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == identity else { return }
            self.speakCurrent()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.utterance.map(ObjectIdentifier.init) == identity else { return }
            self.finishAudio()
        }
    }
}
#endif
