import Foundation
import UserNotifications

/// Short, original bell motifs. OS notification settings still control audibility.
nonisolated enum StockSageAlertSound: String, CaseIterable, Sendable {
    case buy = "stocksage-buy.wav"
    case sell = "stocksage-sell.wav"
    case price = "stocksage-price.wav"
    case research = "stocksage-research.wav"

    var title: String {
        switch self { case .buy: "Rising sparkle"; case .sell: "Gentle tumble";
        case .price: "Little bell"; case .research: "Playful reveal" }
    }

    var notificationSound: UNNotificationSound {
        #if os(iOS)
        UNNotificationSound(named: UNNotificationSoundName(rawValue: rawValue))
        #else
        .default
        #endif
    }

    static func forRecommendation(_ recommendation: StockSageRecommendation) -> Self {
        switch recommendation {
        case .strongBuy, .buy: .buy
        case .strongSell, .sell: .sell
        default: .price
        }
    }

    static func forIdea(_ kind: StockSageAlert.Kind) -> Self {
        switch kind {
        case .newStrongBuy, .targetHit: .buy
        case .newStrongSell, .stopBreach: .sell
        case .flip: .price
        }
    }

    var resourceURL: URL? { Bundle.main.url(forResource: rawValue, withExtension: nil) }
}

nonisolated struct StockSageNotificationAudioPreferences {
    enum Mixing: String, CaseIterable, Sendable { case mix, duck, pause
        var title: String {
            switch self { case .mix: "Mix with music"; case .duck: "Lower other audio"; case .pause: "Pause other audio" }
        }
    }
    enum Key {
        static let chime = "stocksage.audio.chime"
        static let speech = "stocksage.audio.speech"
        static let gain = "stocksage.audio.gainDB"
        static let mixing = "stocksage.audio.mixing"
        static let voice = "stocksage.audio.voice"
        static let research = "stocksage.audio.researchNotifications"
        static func tone(_ event: StockSageAlertSound) -> String { "stocksage.audio.tone." + event.rawValue }
    }
    let chime: Bool
    let speech: Bool
    let gainDB: Int
    let mixing: Mixing
    let voice: String
    let research: Bool
    private let tones: [StockSageAlertSound: StockSageAlertSound]

    init(defaults: UserDefaults = .standard) {
        chime = defaults.object(forKey: Key.chime) as? Bool ?? true
        speech = defaults.object(forKey: Key.speech) as? Bool ?? true
        research = defaults.object(forKey: Key.research) as? Bool ?? true
        let gain = defaults.object(forKey: Key.gain) as? Double ?? 0
        gainDB = Self.clampedGain(gain)
        mixing = Mixing(rawValue: defaults.string(forKey: Key.mixing) ?? "") ?? .mix
        voice = defaults.string(forKey: Key.voice) ?? ""
        tones = Dictionary(uniqueKeysWithValues: StockSageAlertSound.allCases.map { event in
            (event, StockSageAlertSound(rawValue: defaults.string(forKey: Key.tone(event)) ?? "") ?? event)
        })
    }
    var amplitude: Float { Float(pow(10, Double(gainDB) / 20)) }
    func tone(for event: StockSageAlertSound) -> StockSageAlertSound { tones[event] ?? event }
    static func clampedGain(_ value: Double) -> Int {
        value.isFinite ? Int(min(0, max(-24, value)).rounded()) : 0
    }
}

/// Only accepts the repository's bounded PCM16 mono WAV format. Used to bake the
/// same gain into background sounds, where iOS offers no per-notification volume.
nonisolated enum StockSageNotificationWave {
    static func attenuate(_ source: Data, amplitude: Float) -> Data? {
        guard amplitude.isFinite, (0...1).contains(amplitude), source.count >= 44,
              source.count <= 44100 * 2 * 3 + 44 else { return nil }
        func tag(_ start: Int, _ value: String) -> Bool { source.subdata(in: start..<(start + 4)) == Data(value.utf8) }
        func le(_ start: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | (Int(source[start + $1]) << ($1 * 8)) }
        }
        guard tag(0, "RIFF"), tag(8, "WAVE"), tag(12, "fmt "), tag(36, "data"),
              le(4, 4) == source.count - 8, le(16, 4) == 16, le(20, 2) == 1,
              le(22, 2) == 1, le(24, 4) == 44100, le(28, 4) == 88200,
              le(32, 2) == 2, le(34, 2) == 16, le(40, 4) == source.count - 44,
              (source.count - 44).isMultiple(of: 2) else { return nil }
        var result = source
        for i in stride(from: 44, to: source.count, by: 2) {
            let sample = Int16(bitPattern: UInt16(le(i, 2)))
            let scaled = UInt16(bitPattern: Int16((Float(sample) * amplitude).rounded()))
            result[i] = UInt8(scaled & 255); result[i + 1] = UInt8(scaled >> 8)
        }
        return result
    }
}
