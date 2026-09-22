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
                        brief: String, identifier: String = UUID().uuidString,
                        trigger: UNNotificationTrigger? = nil) async -> Bool {
        #if os(iOS)
        content.userInfo["stocksage.audio.event"] = event.rawValue
        content.userInfo["stocksage.audio.brief"] = brief
        content.sound = StockSageNotificationHandler.shared.backgroundSound(for: event)
        #else
        content.sound = .default
        #endif
        do {
            try await UNUserNotificationCenter.current().add(.init(identifier: identifier,
                content: content, trigger: trigger))
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
    mutating func deliveryFailed(id: UUID) { seen.remove(id) }
}

#if os(iOS)
@MainActor final class StockSageNotificationHandler: NSObject, ObservableObject,
    AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = StockSageNotificationHandler()
    @Published private(set) var status = ""
    @Published private(set) var output = "iPhone speaker / current output"
    @Published private(set) var authorization: UNAuthorizationStatus?
    @Published private(set) var permissionSummary = "Checking notification permission…"
    @Published private(set) var notificationTestStatus = ""
    private static let testIdentifier = "stocksage.audio.test"
    private let speech = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var utterance: AVSpeechUtterance?
    private struct AudioEvent { let id = UUID(); let cue: StockSageAlertSound; let brief: String }
    private var current: AudioEvent?
    private var pending: AudioEvent?
    private var observers: Set<AnyCancellable> = []
    private var researchGate = StockSageResearchNotificationGate(observedFrom: Date())
    private var cleanup: Task<Void, Never>?
    private var sessionRequested = false
    private nonisolated static let sessionQueue = DispatchQueue(label: "stocksage.notification-audio.session")
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

    func refreshPermission() async {
        guard !StockSageStore.isRunningTests else {
            permissionSummary = "Notification permission is not requested in automated fixtures."
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
        switch settings.authorizationStatus {
        case .notDetermined: permissionSummary = "Notifications need your permission."
        case .denied: permissionSummary = "Notifications are off in iOS Settings."
        case .provisional: permissionSummary = "iOS delivers notifications quietly. Enable sounds in iOS Settings to hear alerts."
        case .authorized, .ephemeral:
            permissionSummary = settings.soundSetting == .enabled
                ? "Notifications and sounds are allowed. Silent mode and phone volume still apply."
                : "Notifications are allowed, but sounds are off in iOS Settings."
        @unknown default: permissionSummary = "Check notification permission in iOS Settings."
        }
    }

    func requestPermission() async {
        guard !StockSageStore.isRunningTests else { return }
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { notificationTestStatus = "Notification permission could not be requested. Try iOS Settings." }
        await refreshPermission()
    }

    func scheduleTestNotification() async {
        guard !StockSageStore.isRunningTests else { return }
        await refreshPermission()
        guard authorization == .authorized || authorization == .provisional || authorization == .ephemeral else {
            notificationTestStatus = "Enable notifications before sending a test alert."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "StockSage test notification"
        content.body = "A playful research-alert preview. Tap to open Saved research. No research run or order."
        content.userInfo["stocksage.research.ready"] = true
        let accepted = await StockSageNotificationDelivery.enqueue(content, event: .research,
            brief: "Ta da. Test alert. This is a notification preview.", identifier: Self.testIdentifier,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        notificationTestStatus = accepted
            ? "Test scheduled in five seconds. Stay here for speech, or go Home to check the background chime."
            : "The test alert could not be scheduled. Try again."
    }

    func cancelTestNotification() {
        guard !StockSageStore.isRunningTests else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.testIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.testIdentifier])
        notificationTestStatus = "Test notification cleared."
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
                self.researchReady(id: run.id, title: "\(run.horizon.title) research ready",
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
                    self.researchReady(id: receipt.id, title: "\(title) research needs attention",
                        body: "Research stopped or could not be saved. Open StockSage for details. No orders placed.",
                        brief: "Research needs attention. Open StockSage for details.", event: .price)
                } else {
                    let pick = receipt.selectedSymbol
                    self.researchReady(id: receipt.id, title: "\(title) research ready",
                        body: pick.map { "Research candidate: \($0). Review the saved evidence. No orders placed." }
                            ?? "No qualified candidate selected. Review the saved checks. No orders placed.",
                        brief: pick.map { "Research ready. Candidate \($0). Review the evidence. No orders." }
                            ?? "Research ready. No qualified candidate. No orders.", event: .research)
                }
            }.store(in: &observers)
        }
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).sink { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reason: reason) }
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).sink { [weak self] _ in
            Task { @MainActor in self?.stopAudio() }
        }.store(in: &observers)
    }

    func handleRouteChange(reason: UInt?) {
        // Disconnecting headphones must not move a spoken financial brief onto
        // the phone speaker. Category changes caused by our own setup may continue.
        if Self.shouldStopForRouteChange(reason) {
            stopAudio()
            status = "Audio stopped because the output disconnected."
        }
        refreshOutput()
    }

    nonisolated static func shouldStopForRouteChange(_ reason: UInt?) -> Bool {
        reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            || reason == AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue
    }

    private func researchReady(id: UUID, title: String, body: String, brief: String, event: StockSageAlertSound) {
        guard StockSageNotificationAudioPreferences().research else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        content.userInfo["stocksage.research.ready"] = true
        Task {
            guard StockSageNotificationAudioPreferences().research else { return }
            if !(await StockSageNotificationDelivery.enqueue(content, event: event, brief: brief)) {
                // Permit the next fresh history update to retry a rejected request.
                // The reservation still suppresses duplicates while enqueue is in flight.
                researchGate.deliveryFailed(id: id)
            }
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
        // During a foreground transition, leave sound ownership with iOS until
        // we can actually play it. Otherwise both paths can suppress the chime.
        guard UIApplication.shared.applicationState == .active else { return [.banner, .list, .sound] }
        if settings.soundSetting == .enabled {
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
        sessionRequested = true
        let identity = event.id, mixing = preferences.mixing
        // AVAudioSession activation can block. Serialize activation/deactivation
        // off the UI thread, including rapid Preview → Stop → Preview sequences.
        Self.sessionQueue.async { [weak self] in
            let activated: Bool
            do {
                try Self.configureSession(mixing)
                try AVAudioSession.sharedInstance().setActive(true)
                activated = true
            } catch { activated = false }
            Task { @MainActor [weak self] in
                guard let self, self.current?.id == identity else { return }
                guard activated else {
                    self.log.error("Alert audio session activation failed")
                    self.stopAudio()
                    self.status = "Audio could not start. Check your output and try Preview again."
                    return
                }
                self.playCurrent()
            }
        }
    }

    nonisolated static func configureSession(_ mixing: StockSageNotificationAudioPreferences.Mixing) throws {
        let session = AVAudioSession.sharedInstance()
        switch mixing {
        case .mix: try session.setCategory(.ambient, mode: .default)
        case .duck: try session.setCategory(.ambient, mode: .default, options: [.duckOthers])
        case .pause: try session.setCategory(.soloAmbient, mode: .default)
        }
    }

    private func playCurrent() {
        guard let event = current else { return }
        let preferences = StockSageNotificationAudioPreferences()
        do {
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
        if sessionRequested {
            sessionRequested = false
            Self.sessionQueue.async {
                do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
                catch { Logger(subsystem: "StockSage", category: "notification-audio").error("Alert audio session release failed") }
            }
        }
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

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.utterance.map(ObjectIdentifier.init) == identity else { return }
            self.finishAudio()
        }
    }
}
#endif
