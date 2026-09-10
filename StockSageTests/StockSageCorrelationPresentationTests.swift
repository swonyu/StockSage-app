import Foundation
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#endif
@testable import StockSage

@MainActor @Suite("Correlation matrix presentation")
struct StockSageCorrelationPresentationTests {
    private var mixedFixture: CorrelationMatrix {
        CorrelationMatrix(
            symbols: ["BRK.B", "APTVpA", "LONG.TICKER", "NVDA"],
            matrix: [
                [1.00, 0.00, -0.75, 0.82],
                [0.00, 1.00, 0.00, 0.71],
                [-0.75, 0.00, 1.00, -0.20],
                [0.82, 0.71, -0.20, 1.00],
            ],
            defined: [
                [true, true, true, true],
                [true, true, false, true],
                [true, false, true, true],
                [true, true, true, true],
            ])
    }

    @Test("full identities, signed values, measured zero and undefined remain distinct")
    func valueAndAccessibilitySemantics() throws {
        let presentation = try #require(CorrelationMatrixView.presentation(for: mixedFixture))
        let zero = presentation.rows[0][1]
        let negative = presentation.rows[0][2]
        let positive = presentation.rows[0][3]
        let undefined = presentation.rows[1][2]
        let diagonal = presentation.rows[0][0]

        #expect(presentation.symbols == ["BRK.B", "APTVpA", "LONG.TICKER", "NVDA"])
        #expect(zero.state == .zero && zero.displayValue == "0.00")
        #expect(negative.state == .negative && negative.displayValue == "-0.75")
        #expect(positive.state == .positive && positive.displayValue == "+0.82")
        #expect(undefined.state == .undefined && undefined.displayValue == "—")
        #expect(undefined.rowSymbol == "APTVpA" && undefined.columnSymbol == "LONG.TICKER")
        #expect(zero.accessibilityLabel.contains("Row BRK.B, column APTVpA"))
        #expect(zero.accessibilityLabel.contains("not proof of independence"))
        #expect(negative.accessibilityLabel.contains("not proof of a reliable hedge"))
        #expect(undefined.accessibilityLabel.contains("correlation undefined"))
        #expect(diagonal.accessibilityLabel.contains("self-comparison by matrix convention"))
    }

    @Test("legacy empty mask is accepted but malformed inputs fail closed")
    func malformedBoundary() {
        let legacy = CorrelationMatrix(symbols: ["APTVpA", "APTVPA"],
            matrix: [[1, 0.25], [0.25, 1]])
        #expect(CorrelationMatrixView.presentation(for: legacy) != nil,
                "Exact case-distinct provider identities and the legacy empty mask remain valid")

        let invalid: [CorrelationMatrix] = [
            CorrelationMatrix(symbols: ["A", "B"], matrix: [[1, 0.2]]),
            CorrelationMatrix(symbols: ["A", "B"], matrix: [[1, 0.2], [0.2]]),
            CorrelationMatrix(symbols: ["A", "B"], matrix: [[1, .nan], [.nan, 1]]),
            CorrelationMatrix(symbols: ["A", "B"], matrix: [[1, .infinity], [.infinity, 1]]),
            CorrelationMatrix(symbols: ["A", "B"], matrix: [[1, 1.01], [1.01, 1]]),
            CorrelationMatrix(symbols: ["A", "B"], matrix: [[1, 0.2], [0.3, 1]]),
            CorrelationMatrix(symbols: ["A", "A"], matrix: [[1, 0.2], [0.2, 1]]),
            CorrelationMatrix(symbols: ["A", "B"], matrix: [[1, 0.2], [0.2, 1]],
                              defined: [[true, true]]),
            CorrelationMatrix(symbols: ["A", "B"], matrix: [[1, 0.2], [0.2, 1]],
                              defined: [[false, true], [true, true]]),
            CorrelationMatrix(symbols: ["A", "B"], matrix: [[1, 0], [0, 1]],
                              defined: [[true, false], [true, true]]),
            CorrelationMatrix(symbols: ["A", "B"], matrix: [[1, 0.8], [0.8, 1]],
                              defined: [[true, false], [false, true]]),
            CorrelationMatrix(symbols: ["A", "B"], matrix: [[0.9, 0.2], [0.2, 1]]),
        ]
        for matrix in invalid {
            #expect(CorrelationMatrixView.presentation(for: matrix) == nil)
        }
        #expect(CorrelationMatrixView.Presentation.invalidMessage.contains("no coefficients are shown"))
    }

    @Test("cluster warning reports the unchanged threshold as sample evidence")
    func clusterWarning() throws {
        let matrix = CorrelationMatrix(symbols: ["AAA", "BBB", "CCC", "OUT"], matrix: [
            [1.00, 0.82, 0.74, -0.30],
            [0.82, 1.00, 0.79, 0.10],
            [0.74, 0.79, 1.00, 0.20],
            [-0.30, 0.10, 0.20, 1.00],
        ])
        let warning = try #require(CorrelationMatrixView.presentation(for: matrix)?.clusterMessage)

        #expect(warning.contains("AAA, BBB, CCC"))
        #expect(warning.contains("+0.70") && warning.contains("+0.74"))
        #expect(warning.contains("last-computed sample") && warning.contains("can change"))
        #expect(!warning.contains("move as one") && !warning.contains("~1 bet"))
    }

    @Test("caveat does not invent unavailable lookback or freshness metadata")
    func caveat() {
        let copy = CorrelationMatrixView.Presentation.caveat.lowercased()
        for required in ["last-computed", "shared overlapping history", "small samples", "regime changes"] {
            #expect(copy.contains(required))
        }
        #expect(copy.contains("none establishes independence"))
        #expect(!copy.contains("current portfolio") && !copy.contains("updated at"))
    }

    #if os(macOS)
    @Test("actual leaf renders wide and narrow large-text fixtures, including after horizontal scroll")
    func offscreenRenders() async throws {
        let overflow = CorrelationMatrix(symbols: ["BRK.B", "APTVpA", "LONG.TICKER", "NVDA", "MSFT", "2222.SR"], matrix: [
            [1.00, 0.00, -0.75, 0.82, 0.22, -0.15],
            [0.00, 1.00, 0.00, 0.71, 0.18, -0.05],
            [-0.75, 0.00, 1.00, -0.20, 0.12, 0.40],
            [0.82, 0.71, -0.20, 1.00, 0.76, 0.20],
            [0.22, 0.18, 0.12, 0.76, 1.00, 0.33],
            [-0.15, -0.05, 0.40, 0.20, 0.33, 1.00],
        ], defined: [
            [true, true, true, true, true, true],
            [true, true, false, true, true, true],
            [true, false, true, true, true, true],
            [true, true, true, true, true, true],
            [true, true, true, true, true, true],
            [true, true, true, true, true, true],
        ])

        let wide = CorrelationMatrixView(matrix: overflow)
            .padding(16)
            .frame(width: 960, height: 560, alignment: .topLeading)
            .background(DS.Palette.bgTop)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, .large)
        let wideResult = try await capture(wide, name: "stocksage-correlation-wide", scrollToEnd: false)
        #expect(wideResult.size == CGSize(width: 960, height: 560))

        let narrow = CorrelationMatrixView(matrix: overflow)
            .padding(16)
            .frame(width: 320, height: 820, alignment: .topLeading)
            .background(DS.Palette.bgTop)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, .accessibility3)
        let narrowResult = try await capture(narrow, name: "stocksage-correlation-narrow",
                                             scrollToEnd: true)
        #expect(narrowResult.size == CGSize(width: 320, height: 820))
        #expect(narrowResult.didScroll, "The narrow fixture must exercise real horizontal overflow")
    }

    private func capture(_ view: some View, name: String, scrollToEnd: Bool) async throws
    -> (size: CGSize, didScroll: Bool) {
        let host = NSHostingController(rootView: view)
        let size = host.view.fittingSize
        let window = CorrelationFixtureWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }

        try await Task.sleep(for: .milliseconds(50))
        host.view.layoutSubtreeIfNeeded()
        if !scrollToEnd { try assertRowAlignment(in: host.view) }
        try writePNG(host.view, name: "\(name)-start")

        var didScroll = false
        if scrollToEnd {
            let scrollView = try #require(firstScrollView(in: host.view))
            let documentWidth = try #require(scrollView.documentView).frame.width
            let maxX = max(0, documentWidth - scrollView.contentView.bounds.width)
            #expect(maxX > 0)
            scrollView.contentView.scroll(to: NSPoint(x: maxX, y: scrollView.contentView.bounds.origin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            host.view.layoutSubtreeIfNeeded()
            didScroll = scrollView.contentView.bounds.origin.x > 0
            try writePNG(host.view, name: "\(name)-end")
        }
        return (host.view.bounds.size, didScroll)
    }

    private func assertRowAlignment(in view: NSView) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / view.bounds.width
        // This fixed 960pt fixture has row-label ink at x16...84 and the first numeric
        // column at x92...144. Measure actual rendered text baselines, not source strings.
        func lineCenters(_ band: Range<Int>) -> [Double] {
            var centers: [Double] = [], start: Int?
            for y in 0...bitmap.pixelsHigh {
                let ink = y < bitmap.pixelsHigh && band.contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return min(color.redComponent, color.greenComponent, color.blueComponent) > 0.85
                }
                if ink, start == nil { start = y }
                if !ink, let first = start {
                    centers.append(Double(first + y - 1) / (2 * scale))
                    start = nil
                }
            }
            return centers
        }
        let labels = lineCenters(Int(16 * scale)..<Int(84 * scale))
        let values = lineCenters(Int(92 * scale)..<Int(144 * scale))
        try #require(labels.count == 6 && values.count == 7,
                     "Fixture must show six row labels, six coefficients and one column header")
        for (row, value) in zip(labels, values.dropFirst()) {
            #expect(abs(row - value) <= 2, "Every ticker must align with its own numeric row")
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for child in view.subviews {
            if let scrollView = firstScrollView(in: child) { return scrollView }
        }
        return nil
    }

    private func writePNG(_ view: NSView, name: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).png"), options: .atomic)
    }
    #endif
}

#if os(macOS)
@MainActor private final class CorrelationFixtureWindow: NSWindow {
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { false }
}
#endif
