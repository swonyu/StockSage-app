#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import StockSage

/// Offline component captures, not proof of a provider connection or a live research result.
@Suite("Native momentum cards", .serialized)
@MainActor struct StockSageMomentumLayoutTests {
    private typealias M = StockSageMomentum
    private typealias T = StockSageMassiveTicks

    @Test(arguments: [
        ("populated", 393.0, false), ("gaps-unavailable", 393.0, false),
        ("populated", 650.0, false), ("populated", 1100.0, false),
        ("gaps-unavailable", 650.0, false), ("gaps-unavailable", 1100.0, false),
        ("populated", 650.0, true)
    ])
    func nativeMomentumCardsExposeEverySection(state: String, width: Double, largeText: Bool) async throws {
        // Keep a verified-session capture deterministic. The shipping TimelineView correctly
        // labels these saved observations historical when the fixture runs at a later real clock.
        let capturedAt = try #require(ISO8601DateFormatter().date(from: "2026-09-18T15:00:20Z"))
        let end = Date(timeIntervalSince1970: floor(capturedAt.timeIntervalSince1970 / 60) * 60)
        func candles(change: Double, accelerated: Bool = false) -> T.Intraday {
            let bars = (0..<30).map { index -> T.Minute in
                let close = index < 25 ? 100 : 100 + change * Double(index - 24) / 5
                return .init(at: end.addingTimeInterval(Double(index - 30) * 60), open: close,
                    high: close + 0.5, low: close - 0.5, close: close,
                    volume: accelerated && index >= 25 ? 4_000 : 1_000)
            }
            return .init(facts: [], asOf: end, bars: bars, verifiedMinutes: true)
        }
        var spy: T.Intraday? = candles(change: 0.3)
        var qqq: T.Intraday? = candles(change: 0.7)
        var stockInput = candles(change: 4, accelerated: true)
        if state == "gaps-unavailable" {
            spy?.bars.remove(at: 27)
            qqq = nil
            stockInput.bars.remove(at: 27)
        }
        let market = M.market(spy: spy, qqq: qqq, now: capturedAt)
        let stock = M.stock(symbol: "FIXTURE", intraday: stockInput, market: market, now: capturedAt)
        if state == "populated" {
            #expect(stock.heavyMomentum(profile: .microcap, now: capturedAt) != nil)
            #expect(stock.volumeAcceleration.multiple == 4)
            let relativesAvailable = stock.vsSPY.allSatisfy { $0.status == .available }
                && stock.vsQQQ.allSatisfy { $0.status == .available }
            #expect(relativesAvailable)
        } else {
            #expect(stock.volumeAcceleration.multiple == nil)
            #expect(stock.series.returns.first { $0.minutes == 5 }?.status == .gap)
            #expect(market.qqq.returns.allSatisfy { $0.percent == nil })
        }

        let size = CGSize(width: width, height: 1900)
        let view = ScrollView(.vertical) {
            StockSageMomentumView(market: market, stock: stock)
                .padding(DS.Space.lg)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .font(.body)
        .foregroundStyle(DS.Palette.textPrimary)
        .tint(DS.Palette.accent)
        .background(DS.Palette.bgTop)
        .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .frame(width: size.width, height: size.height)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = host
        window.setContentSize(size)
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutSubtreeIfNeeded()
        #expect(host.view.bounds.width.isFinite && host.view.bounds.height.isFinite)
        #expect(abs(host.view.bounds.width - size.width) < 1)
        #expect(abs(host.view.bounds.height - size.height) < 1)
        let scroll = try #require(scrollViews(in: host.view).max {
            $0.contentView.bounds.width * $0.contentView.bounds.height
                < $1.contentView.bounds.width * $1.contentView.bounds.height
        })
        let document = try #require(scroll.documentView)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stocksage-momentum-layout-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(state)-\(Int(width))-\(largeText ? "ax3" : "default")"

        // Capture every native scroll interval with overlap. A taller document gets more
        // images, rather than assuming the relative/volume sections fit the first viewport.
        let initialY = document.isFlipped ? 0 : max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: initialY))
        scroll.reflectScrolledClipView(scroll.contentView)
        var reachedEnd = false
        for page in 1...8 {
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let visible = scroll.documentVisibleRect
            #expect(document.bounds.height.isFinite && document.bounds.width.isFinite)
            #expect(visible.width > 0 && visible.height > 0)
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let path = directory.appendingPathComponent("\(name)-page-\(page).png")
            try png.write(to: path, options: .atomic)
            print("MOMENTUM_LAYOUT_RENDER pid=\(ProcessInfo.processInfo.processIdentifier) state=\(state) width=\(width) type=\(largeText ? "ax3" : "default") page=\(page) viewport=\(host.view.bounds) document=\(document.bounds) visible=\(visible) path=\(path.path)")
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let current = scroll.contentView.bounds.origin.y
            reachedEnd = document.isFlipped ? current >= maximum - 1 : current <= 1
            if reachedEnd { break }
            let step = max(1, visible.height - 160)
            let next = document.isFlipped ? min(maximum, current + step) : max(0, current - step)
            #expect(abs(next - current) > 0.5, "The native page must advance to expose remaining content")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: next))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        #expect(reachedEnd, "All momentum sections must be reachable and captured within the bounded fixture")
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
#endif
