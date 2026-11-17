#if os(iOS)
import SwiftUI
import AVFoundation
import AVKit
import UIKit

struct StockSageNotificationAudioSettings: View {
    private typealias Preferences = StockSageNotificationAudioPreferences
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ObservedObject private var handler = StockSageNotificationHandler.shared
    @AppStorage(Preferences.Key.chime) private var chime = true
    @AppStorage(Preferences.Key.speech) private var speech = true
    @AppStorage(Preferences.Key.research) private var research = true
    @AppStorage(Preferences.Key.gain) private var gain = 0.0
    @AppStorage(Preferences.Key.mixing) private var mixing = Preferences.Mixing.mix.rawValue
    @AppStorage(Preferences.Key.voice) private var voice = ""
    @AppStorage(Preferences.Key.tone(.buy)) private var buyTone = StockSageAlertSound.buy.rawValue
    @AppStorage(Preferences.Key.tone(.sell)) private var sellTone = StockSageAlertSound.sell.rawValue
    @AppStorage(Preferences.Key.tone(.price)) private var priceTone = StockSageAlertSound.price.rawValue
    @AppStorage(Preferences.Key.tone(.research)) private var researchTone = StockSageAlertSound.research.rawValue

    var body: some View {
        Section {
            Text(handler.permissionSummary).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.audio.permission")
            if handler.authorization == .notDetermined {
                Button("Allow notifications", systemImage: "bell.badge") {
                    Task { await handler.requestPermission() }
                }.accessibilityIdentifier("settings.audio.allow")
            }
            Button("Open iOS notification settings", systemImage: "gearshape") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }.accessibilityIdentifier("settings.audio.systemSettings")
            Toggle("Research completion alerts", isOn: $research)
                .accessibilityIdentifier("settings.audio.research")
            Toggle("Play chimes", isOn: $chime)
                .accessibilityIdentifier("settings.audio.chime")
            Toggle("Short spoken brief", isOn: $speech)
                .accessibilityIdentifier("settings.audio.speech")
            VStack(alignment: .leading) {
                Text("Gain: \(Int(gain.isFinite ? min(0, max(-24, gain)) : 0)) dB")
                Slider(value: $gain, in: -24...0, step: 1) { Text("Alert gain") }
                    .accessibilityIdentifier("settings.audio.gain")
            }
            Picker("Other audio", selection: $mixing) {
                ForEach(Preferences.Mixing.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }.accessibilityIdentifier("settings.audio.mixing")
            HStack {
                VStack(alignment: .leading) {
                    Text("Speaker / output")
                    Text(handler.output).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StockSageAudioRoutePicker().frame(width: 44, height: 44)
                    .accessibilityLabel("Choose audio output")
            }
            Picker("Voice", selection: $voice) {
                Text("System voice").tag("")
                ForEach(voices, id: \.identifier) { item in
                    Text("\(item.name) · \(item.language)").tag(item.identifier)
                }
            }.accessibilityIdentifier("settings.audio.voice")
            tonePicker("Buy sound", selection: $buyTone)
            tonePicker("Sell sound", selection: $sellTone)
            tonePicker("Price-alert sound", selection: $priceTone)
            tonePicker("Research-ready sound", selection: $researchTone)
            Button("Preview Buy alert", systemImage: "speaker.wave.2") { handler.preview(.buy) }
                .accessibilityIdentifier("settings.audio.previewBuy")
            Button("Preview Sell alert", systemImage: "speaker.wave.2") { handler.preview(.sell) }
                .accessibilityIdentifier("settings.audio.previewSell")
            Button("Preview research ready", systemImage: "sparkles") { handler.preview(.research) }
                .accessibilityIdentifier("settings.audio.previewResearch")
            Button("Stop preview", systemImage: "stop.circle") { handler.stopAudio() }
                .accessibilityIdentifier("settings.audio.stop")
            Button("Send test notification in 5 seconds", systemImage: "bell.badge") {
                Task { await handler.scheduleTestNotification() }
            }.accessibilityIdentifier("settings.audio.testNotification")
            Button("Clear test notification", systemImage: "bell.slash") { handler.cancelTestNotification() }
                .accessibilityIdentifier("settings.audio.clearTestNotification")
            if !handler.notificationTestStatus.isEmpty {
                Text(handler.notificationTestStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !handler.status.isEmpty { Text(handler.status).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("Notification audio") }
        footer: {
            Text("Short, playful chimes and quick briefs. Previews make no trade or research request. Voice, mixing and output selection apply while StockSage is open; background notifications use the chosen chime and gain. Silent mode, phone volume and notification sound settings still apply. Research alerts announce completed checks, never placed orders.")
        }
        .onAppear { handler.refreshOutput(); gain = Double(Preferences.clampedGain(gain)) }
        .task(id: scenePhase) { if scenePhase == .active { await handler.refreshPermission() } }
        .onChange(of: chime) { handler.stopAudio() }
        .onChange(of: speech) { handler.stopAudio() }
        .onChange(of: mixing) { handler.stopAudio() }
        .onChange(of: gain) { handler.stopAudio() }
        .onChange(of: [buyTone, sellTone, priceTone, researchTone, voice]) { handler.stopAudio() }
        .onDisappear { handler.stopAudio() }
    }

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") || $0.language.hasPrefix("ar") }
            .sorted { ($0.language, $0.name, $0.identifier) < ($1.language, $1.name, $1.identifier) }
    }
    private func tonePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(StockSageAlertSound.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
        }
    }
}

private struct StockSageAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}
#endif
