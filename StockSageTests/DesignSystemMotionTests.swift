import Testing
import SwiftUI
@testable import StockSage

#if os(macOS)
import AppKit
import Combine

// `accessibilityReduceMotion` is get-only in the SDK. The underscored writable key is
// confined to this test; MotionSegmentFixture reads the public value before any click.
@Suite(.serialized) @MainActor
struct DesignSystemMotionTests {
    @Test(arguments: [false, true])
    func luxPressOnlyScalesWhenReduceMotionIsOff(reduceMotion: Bool) async throws {
        let root = Button(action: {}) {
            Color.white.frame(width: 100, height: 40)
        }
        .buttonStyle(LuxPressStyle())
        .environment(\._accessibilityReduceMotion, reduceMotion)
        .frame(width: 160, height: 80)
        .background(Color.black)
        let fixture = mount(root, size: NSSize(width: 160, height: 80))
        defer { fixture.close() }

        try await settle(for: .milliseconds(50), fixture.host.view)
        let restingPixels = try brightPixelCount(in: fixture.host.view)
        try #require(restingPixels > 0, "The fixture must render the actual button before testing its motion")
        try fixture.sendMouse(.leftMouseDown, at: NSPoint(x: 80, y: 40))
        try await settle(for: .milliseconds(500), fixture.host.view)
        let pressedPixels = try brightPixelCount(in: fixture.host.view)
        try fixture.sendMouse(.leftMouseUp, at: NSPoint(x: 80, y: 40))

        if reduceMotion {
            #expect(pressedPixels == restingPixels,
                    "Reduce Motion must remove the shared button's pressed scaling")
        } else {
            #expect(pressedPixels < restingPixels,
                    "The existing 0.97 pressed scale must remain when Reduce Motion is off")
        }
    }

    @Test(arguments: [false, true])
    func segmentSelectionUsesTheAccessibilityMotionTransaction(reduceMotion: Bool) async throws {
        let model = MotionSegmentModel()
        let root = MotionSegmentFixture(model: model)
            .environment(\._accessibilityReduceMotion, reduceMotion)
        let fixture = mount(root, size: NSSize(width: 180, height: 44))
        defer { fixture.close() }

        try await settle(for: .milliseconds(50), fixture.host.view)
        try await waitUntil { model.observedReduceMotion == reduceMotion }
        try fixture.click(at: NSPoint(x: 135, y: 22))
        try await waitUntil { model.selection == .two && model.selectionTransaction != nil }
        let transaction = try #require(model.selectionTransaction)

        #expect(model.selection == .two, "The actual second segment must update rendered selection state")
        if reduceMotion {
            #expect(transaction.animation == nil && transaction.disablesAnimations,
                    "Reduce Motion must make the selected-segment update immediate")
        } else {
            #expect(transaction.animation != nil && !transaction.disablesAnimations,
                    "The existing spring transaction must remain when Reduce Motion is off")
        }
    }

    private func mount(_ root: some View, size: NSSize) -> MotionFixture {
        let host = NSHostingController(rootView: AnyView(root))
        let window = MotionFixtureWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderBack(nil)
        host.view.frame = NSRect(origin: .zero, size: size)
        return MotionFixture(window: window, host: host)
    }

    private func settle(for duration: Duration, _ view: NSView) async throws {
        try await Task.sleep(for: duration)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func brightPixelCount(in view: NSView) throws -> Int {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.7 && color.greenComponent > 0.7 && color.blueComponent > 0.7 {
                    count += 1
                }
            }
        }
        return count
    }
}

private enum MotionSegment: String, CaseIterable { case one = "One", two = "Two" }

@MainActor private final class MotionSegmentModel: ObservableObject {
    @Published var selection = MotionSegment.one
    var selectionTransaction: Transaction?
    var observedReduceMotion: Bool?

    func record(_ transaction: Transaction) {
        guard selection == .two, selectionTransaction == nil else { return }
        selectionTransaction = transaction
    }
}

@MainActor private struct MotionSegmentFixture: View {
    @ObservedObject var model: MotionSegmentModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DSSegmentPicker(cases: MotionSegment.allCases, selection: $model.selection) { $0.rawValue }
            .transaction { model.record($0) }
            .frame(width: 180, height: 44)
            .onAppear { model.observedReduceMotion = reduceMotion }
    }
}

@MainActor private final class MotionFixtureWindow: NSWindow {
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { false }
}

@MainActor private struct MotionFixture {
    let window: MotionFixtureWindow
    let host: NSHostingController<AnyView>

    func click(at point: NSPoint) throws {
        try sendMouse(.leftMouseDown, at: point)
        try sendMouse(.leftMouseUp, at: point)
    }

    func sendMouse(_ type: NSEvent.EventType, at point: NSPoint) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: type == .leftMouseDown ? 1 : 2,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0))
        window.sendEvent(event)
    }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }
}
#endif
