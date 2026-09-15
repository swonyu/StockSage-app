import Testing
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import StockSage

@Suite("Magenta brand accent")
struct DesignSystemAccentTests {
    @Test @MainActor func sharedAndNativeAccentsUseMagentaWithoutChangingStatusColors() throws {
        for color in [DS.Palette.accent, DS.Palette.accentText, Color("AccentColor")] {
            let rgb = try components(color)
            #expect(rgb[0] > 0.65 && rgb[2] > 0.6)
            #expect(rgb[1] < min(rgb[0], rgb[2]) * 0.6, "Magenta has strong red/blue, not an indigo or red-only accent")
        }
        #expect(DS.Palette.success == Color.green)
        #expect(DS.Palette.danger == Color.red)
        #if os(macOS)
        #expect(StockSageDesktop.berry == DS.Palette.accentText, "Navigation must use the shared accent")
        #endif
    }

    @Test @MainActor func whiteButtonLabelsAndAccentTextRetainAAContrast() throws {
        for fill in [DS.Palette.accent, Color("AccentColor")] {
            #expect(contrast(try components(fill), [1, 1, 1]) >= 4.5)
        }
        let text = try components(DS.Palette.accentText)
        #expect(contrast(text, [0.137, 0.137, 0.149]) >= 4.5)
        #expect(contrast(text, [0.2, 0.2, 0.2]) >= 4.5)
    }

    @Test @MainActor func macAndPhoneShareOpaqueCharcoalSurfaces() throws {
        for (color, expected) in [(DS.Palette.bgTop, [0.094, 0.094, 0.102]),
                                  (DS.Palette.bgBottom, [0.094, 0.094, 0.102]),
                                  (DS.Bezel.cardFill, [0.137, 0.137, 0.149])] {
            let rgba = try components(color)
            for index in 0..<3 { #expect(abs(rgba[index] - expected[index]) < 0.001) }
            #expect(rgba[3] == 1, "Surfaces must not change color with the content behind them")
        }
        #expect(StockSageDesktop.icon(for: .briefing) == "house")
        #expect(StockSageDesktop.icon(for: .watchlist) == "star")
    }

    @MainActor private func components(_ color: Color) throws -> [Double] {
        #if os(macOS)
        let color = try #require(NSColor(color).usingColorSpace(.sRGB))
        return [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent)]
        #else
        let color = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        try #require(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [Double(red), Double(green), Double(blue), Double(alpha)]
        #endif
    }

    @Test @MainActor func correlationCoefficientsRetainAAContrastAcrossTheirSignedRange() throws {
        for coefficient in [-1.0, -0.75, -0.01, 0, 0.01, 0.75, 1] {
            let matrix = CorrelationMatrix(symbols: ["A", "B"], matrix: [[1, coefficient], [coefficient, 1]])
            let cell = try #require(CorrelationMatrixView.presentation(for: matrix)?.rows[0][1])
            let rgba = try components(cell.fill)
            for background in [try components(DS.Palette.bgTop), [0.2, 0.2, 0.2]] {
                let composite = (0..<3).map { rgba[$0] * rgba[3] + background[$0] * (1 - rgba[3]) }
                #expect(contrast(composite, try components(DS.Palette.textPrimary)) >= 4.5,
                        "Readable correlation \(coefficient), regardless of sign or fill intensity")
            }
        }
    }

    private func contrast(_ lhs: [Double], _ rhs: [Double]) -> Double {
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let a = luminance(lhs), b = luminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    #if os(macOS)
    @Test @MainActor func renderNativeAccentControls() async throws {
        var appeared = false
        let content = HStack(spacing: 0) {
            StockSageDesktopNavigation(selection: .constant(.research)).frame(width: 235)
            VStack(alignment: .leading, spacing: 24) {
                Text("Magenta accent").font(.largeTitle.bold())
                Text("Synthetic component fixture · no services or account data")
                    .foregroundStyle(.secondary)
                Button("Run research") {}.buttonStyle(.borderedProminent)
                Toggle("Enabled control", isOn: .constant(true)).toggleStyle(.switch)
                Picker("Research mode", selection: .constant(0)) {
                    Text("Same day").tag(0)
                    Text("1–7 days").tag(1)
                    Text("7–14 days").tag(2)
                }.pickerStyle(.segmented)
                Label("Accent text and icons", systemImage: "sparkle")
                    .foregroundStyle(DS.Palette.accentText)
                HStack {
                    Label("Gain", systemImage: "arrow.up").foregroundStyle(DS.Palette.successSoft)
                    Label("Loss", systemImage: "arrow.down").foregroundStyle(DS.Palette.dangerSoft)
                    Label("Warning", systemImage: "exclamationmark.triangle").foregroundStyle(DS.Palette.warningSoft)
                }
                Spacer()
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 850, height: 650)
        .background(DS.Palette.bgTop)
        .tint(DS.Palette.accent)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .environment(\.controlActiveState, .key)
        .onAppear { appeared = true }
        let host = NSHostingController(rootView: content)
        let window = AccentFixtureWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 850, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !appeared, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(appeared)
        host.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("stocksage-magenta-\(ProcessInfo.processInfo.processIdentifier).png")
        try png.write(to: output, options: .atomic)
        #expect(bitmap.pixelsWide >= 850 && bitmap.pixelsHigh >= 650)
        print("Magenta component fixture: \(output.path)")
    }
    #endif
}

#if os(macOS)
@MainActor private final class AccentFixtureWindow: NSWindow {
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { false }
}
#endif
