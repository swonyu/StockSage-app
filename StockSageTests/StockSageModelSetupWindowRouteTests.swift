#if os(macOS)
import AppKit
import Testing
@testable import StockSage

@Suite("Model setup window routing", .serialized) @MainActor
struct StockSageModelSetupWindowRouteTests {
    @Test func reusesOnlyTheFrontmostMainWindow() {
        var presented: [NSWindow] = []
        let router = StockSageModelSetupWindowRoute(presentWindow: { presented.append($0) })
        var firstRoutes = 0
        var otherRoutes = 0
        var opened = 0
        let settings = window()
        let first = window()
        let other = window()
        defer { [settings, first, other].forEach { $0.close() } }
        attach(to: first, router: router) { firstRoutes += 1 }
        attach(to: other, router: router) { otherRoutes += 1 }

        router.request(in: [settings, first, other]) { opened += 1 }

        #expect(firstRoutes == 1)
        #expect(otherRoutes == 0, "Opening model setup must not navigate another main window")
        #expect(opened == 0, "An existing main window must avoid WindowGroup creating another one")
        #expect(presented.count == 1 && presented.first === first)
    }

    @Test func newWindowConsumesOneRequestAfterAttachmentUsingTheLatestRoute() async throws {
        var presented: [NSWindow] = []
        let router = StockSageModelSetupWindowRoute(presentWindow: { presented.append($0) })
        var opened = 0
        var oldRoutes = 0
        var currentRoutes = 0
        var otherRoutes = 0
        router.request(in: []) { opened += 1 }
        router.request(in: []) { opened += 1 }
        #expect(opened == 1, "Repeated clicks while a window opens should share the same request")

        let main = window()
        let other = window()
        defer { [main, other].forEach { $0.close() } }
        let marker = attach(to: main, router: router) { oldRoutes += 1 }
        marker.updateRoute { currentRoutes += 1 }
        #expect(oldRoutes == 0 && currentRoutes == 0,
                "Native attachment and representable updates must not publish navigation synchronously")

        try await waitUntil { currentRoutes == 1 }
        attach(to: other, router: router) { otherRoutes += 1 }
        marker.updateRoute { currentRoutes += 1 }
        try await Task.sleep(for: .milliseconds(20))

        #expect(oldRoutes == 0)
        #expect(currentRoutes == 1)
        #expect(otherRoutes == 0, "The fallback request must not broadcast to later windows")
        #expect(presented.count == 1 && presented.first === main)
    }

    @Test func aDetachedMarkerDoesNotLoseThePendingRequest() async throws {
        var presented: [NSWindow] = []
        let router = StockSageModelSetupWindowRoute(presentWindow: { presented.append($0) })
        var detachedRoutes = 0
        var attachedRoutes = 0
        router.request(in: []) {}
        let discarded = window()
        let live = window()
        defer { [discarded, live].forEach { $0.close() } }
        let marker = attach(to: discarded, router: router) { detachedRoutes += 1 }
        marker.removeFromSuperview()
        attach(to: live, router: router) { attachedRoutes += 1 }

        try await waitUntil { attachedRoutes == 1 }

        #expect(detachedRoutes == 0)
        #expect(presented.count == 1 && presented.first === live)
    }

    @Test func closingARetainedWindowBeforeDeliveryCancelsItsRouteAndAllowsRetry() async throws {
        var presented: [NSWindow] = []
        let router = StockSageModelSetupWindowRoute(presentWindow: { presented.append($0) })
        var opened = 0
        var closedRoutes = 0
        var replacementRoutes = 0
        router.request(in: []) { opened += 1 }
        let closed = window()
        let replacement = window()
        defer { replacement.close() }
        let marker = attach(to: closed, router: router) { closedRoutes += 1 }
        closed.close()
        try #require(marker.window === closed,
                     "Exercise a retained closed window, not a detached marker")

        try await Task.sleep(for: .milliseconds(20))

        #expect(closedRoutes == 0, "Closing the window must cancel its deferred navigation")
        #expect(presented.isEmpty, "A deferred request must not reopen the window the user closed")
        router.request(in: [closed]) { opened += 1 }
        #expect(opened == 2, "A new explicit request must skip retained closed windows and retry creation")
        attach(to: replacement, router: router) { replacementRoutes += 1 }
        try await waitUntil { replacementRoutes == 1 }
        #expect(closedRoutes == 0)
        #expect(presented.count == 1 && presented.first === replacement)
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.frame)
        return window
    }

    @discardableResult
    private func attach(to window: NSWindow, router: StockSageModelSetupWindowRoute,
                        route: @escaping @MainActor () -> Void) -> StockSageModelSetupWindowMarker {
        let marker = StockSageModelSetupWindowMarker(router: router, openModelSettings: route)
        let container = NSView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(container)
        container.addSubview(marker)
        return marker
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "The attached native window should receive the pending route")
    }
}
#endif
