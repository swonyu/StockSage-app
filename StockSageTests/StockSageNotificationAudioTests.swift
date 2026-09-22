import Testing
import Foundation
import AVFoundation
import UserNotifications
@testable import StockSage

struct StockSageNotificationAudioTests {
    @Test @MainActor func notificationTapSurvivesLateAttachmentAndStaleAcknowledgement() throws {
        let router = StockSageNotificationRouter()
        router.receive(action: UNNotificationDefaultActionIdentifier,
                       userInfo: ["stocksage.research.ready": true])
        let cold = try #require(router.pending)
        #expect(cold.destination == .research)
        router.receive(action: UNNotificationDefaultActionIdentifier, userInfo: ["symbol": " AAPL\n"])
        let newer = try #require(router.pending)
        #expect(newer.destination == .symbol("AAPL") && newer.id != cold.id)
        router.acknowledge(cold.id)
        #expect(router.pending == newer)
        router.acknowledge(newer.id)
        #expect(router.pending == nil)
    }

    @Test @MainActor func dismissedAndMalformedNotificationsNeverNavigate() {
        let router = StockSageNotificationRouter()
        for action in [UNNotificationDismissActionIdentifier, "unregistered-action"] {
            router.receive(action: action, userInfo: ["stocksage.research.ready": true, "symbol": "AAPL"])
            #expect(router.pending == nil)
        }
        let payloads: [[AnyHashable: Any]] = [[:], ["symbol": "  "], ["symbol": 42],
                                           ["symbol": String(repeating: "A", count: 33)]]
        for payload in payloads {
            router.receive(action: UNNotificationDefaultActionIdentifier, userInfo: payload)
            #expect(router.pending == nil)
        }
    }

    @Test func rejectedResearchDeliveryCanRetryButAnAcceptedOneCannotRepeat() {
        let now = Date(), id = UUID()
        var gate = StockSageResearchNotificationGate(observedFrom: now)
        let first = gate.accept(id: id, startedAt: now, finishedAt: now, now: now)
        let duplicate = gate.accept(id: id, startedAt: now, finishedAt: now, now: now)
        #expect(first && !duplicate)
        gate.deliveryFailed(id: id)
        let retry = gate.accept(id: id, startedAt: now, finishedAt: now, now: now)
        let repeated = gate.accept(id: id, startedAt: now, finishedAt: now, now: now)
        #expect(retry && !repeated)
        gate.deliveryFailed(id: id)
        let expired = gate.accept(id: id, startedAt: now, finishedAt: now, now: now.addingTimeInterval(121))
        #expect(!expired)
    }

    #if os(iOS)
    @Test func allMixingConfigurationsAreAcceptedByTheNativeAudioSession() async throws {
        // Category configuration only: no sound, permission request or activation.
        try await Task.detached {
            let session = AVAudioSession.sharedInstance()
            let category = session.category, mode = session.mode, options = session.categoryOptions
            defer { try? session.setCategory(category, mode: mode, options: options) }
            for mixing in StockSageNotificationAudioPreferences.Mixing.allCases {
                try StockSageNotificationHandler.configureSession(mixing)
                #expect(session.category == (mixing == .pause ? .soloAmbient : .ambient))
                #expect(session.categoryOptions.contains(.duckOthers) == (mixing == .duck))
            }
        }.value
    }

    @Test func disconnectedOutputStopsBriefButNormalRouteChangesDoNot() {
        typealias R = AVAudioSession.RouteChangeReason
        for reason in [R.oldDeviceUnavailable, .noSuitableRouteForCategory] {
            #expect(StockSageNotificationHandler.shouldStopForRouteChange(reason.rawValue))
        }
        for reason in [R.newDeviceAvailable, .categoryChange, .override, .wakeFromSleep, .unknown] {
            #expect(!StockSageNotificationHandler.shouldStopForRouteChange(reason.rawValue))
        }
        #expect(!StockSageNotificationHandler.shouldStopForRouteChange(nil))
    }
    #endif
    @Test(arguments: StockSageAlertSound.allCases)
    func shippedChimesAreAudibleShortPCMResources(_ sound: StockSageAlertSound) throws {
        let url = try #require(sound.resourceURL, "A missing bundled sound silently becomes the OS default")
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(seconds > 0.5 && seconds < 2)
        #expect(file.processingFormat.channelCount == 1)
        let data = try Data(contentsOf: url)
        #expect(StockSageNotificationWave.attenuate(data, amplitude: 1) == data)
        #expect(data.dropFirst(44).contains { $0 != 0 })
    }

    @Test func backgroundGainMatchesForegroundAmplitudeWithoutChangingTiming() throws {
        let url = try #require(StockSageAlertSound.research.resourceURL)
        let original = try Data(contentsOf: url)
        let reduced = try #require(StockSageNotificationWave.attenuate(original, amplitude: 0.5))
        #expect(original.count == reduced.count)
        #expect(original.prefix(44) == reduced.prefix(44))
        var maximumRoundingError = 0
        for i in stride(from: 44, to: original.count, by: 2) {
            func sample(_ data: Data) -> Int16 { Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8) }
            maximumRoundingError = max(maximumRoundingError, abs(Int(sample(reduced)) * 2 - Int(sample(original))))
        }
        #expect(maximumRoundingError <= 1)
        #expect(StockSageNotificationWave.attenuate(original, amplitude: 0)?.dropFirst(44).allSatisfy { $0 == 0 } == true)
        #expect(StockSageNotificationWave.attenuate(original, amplitude: .nan) == nil)
        #expect(StockSageNotificationWave.attenuate(original, amplitude: 2) == nil)
        #expect(StockSageNotificationWave.attenuate(Data(original.dropLast()), amplitude: 0.5) == nil)
        var corrupt = original; corrupt[20] = 3 // float encoding is not PCM16
        #expect(StockSageNotificationWave.attenuate(corrupt, amplitude: 0.5) == nil)
    }

    @Test func preferencesClampGainAndRetainIndependentControls() throws {
        let name = "notification-audio.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        typealias P = StockSageNotificationAudioPreferences
        defaults.set(-6.0, forKey: P.Key.gain)
        defaults.set(false, forKey: P.Key.chime)
        defaults.set(true, forKey: P.Key.speech)
        defaults.set(false, forKey: P.Key.research)
        defaults.set("invalid", forKey: P.Key.mixing)
        defaults.set(StockSageAlertSound.price.rawValue, forKey: P.Key.tone(.buy))
        let p = P(defaults: defaults)
        #expect(!p.chime && p.speech && !p.research)
        #expect(abs(p.amplitude - 0.501187) < 0.00001)
        #expect(p.mixing == .mix && p.tone(for: .buy) == .price && p.tone(for: .sell) == .sell)
        defaults.set(20.0, forKey: P.Key.gain); #expect(P(defaults: defaults).gainDB == 0)
        defaults.set(-200.0, forKey: P.Key.gain); #expect(P(defaults: defaults).gainDB == -24)
        defaults.set(Double.nan, forKey: P.Key.gain); #expect(P(defaults: defaults).gainDB == 0)
    }

    @Test func restoredAndRepeatedResearchNeverReannounces() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var gate = StockSageResearchNotificationGate(observedFrom: start)
        let id = UUID(), now = start.addingTimeInterval(30)
        let accepted1 = gate.accept(id: id, startedAt: start.addingTimeInterval(-1), finishedAt: now, now: now)
        #expect(!accepted1)
        let accepted2 = gate.accept(id: id, startedAt: start, finishedAt: nil, now: now)
        #expect(!accepted2)
        let accepted3 = gate.accept(id: id, startedAt: start, finishedAt: now.addingTimeInterval(60), now: now)
        #expect(!accepted3)
        let accepted4 = gate.accept(id: id, startedAt: start, finishedAt: now, now: now)
        #expect(accepted4)
        let accepted5 = gate.accept(id: id, startedAt: start, finishedAt: now, now: now.addingTimeInterval(1))
        #expect(!accepted5)
        let accepted6 = gate.accept(id: UUID(), startedAt: start, finishedAt: now, now: now.addingTimeInterval(121))
        #expect(!accepted6)
        let accepted7 = gate.accept(id: UUID(), startedAt: start, finishedAt: now, now: now)
        #expect(accepted7)
    }
}
