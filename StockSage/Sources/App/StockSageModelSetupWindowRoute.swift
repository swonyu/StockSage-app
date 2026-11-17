#if os(macOS)
import AppKit
import SwiftUI

/// Routes this one Settings action to an actual MarketsView window. WindowGroup's
/// identifier-only openWindow creates a new window, so it is only the fallback.
@MainActor
final class StockSageModelSetupWindowRoute {
    static let shared = StockSageModelSetupWindowRoute()

    private var pendingRequest: UUID?
    private let presentWindow: @MainActor (NSWindow) -> Void

    init(presentWindow: @escaping @MainActor (NSWindow) -> Void = { window in
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }) {
        self.presentWindow = presentWindow
    }

    func request(in windows: [NSWindow], openWindow: () -> Void) {
        for window in windows {
            guard let root = window.contentView, let marker = marker(in: root) else { continue }
            pendingRequest = nil
            marker.openModelSettings()
            presentWindow(window)
            return
        }
        // Coalesce clicks during creation. This transient request has one consumer;
        // it is not a preference observed by every existing scene.
        guard pendingRequest == nil else { return }
        pendingRequest = UUID()
        openWindow()
    }

    fileprivate func deliverPendingRequest(to marker: StockSageModelSetupWindowMarker) {
        guard let request = pendingRequest, marker.routableWindow != nil else { return }
        marker.scheduledRequest = request
        Task { @MainActor [weak self, weak marker] in
            // Attachment/update can occur during a SwiftUI render. Publish the
            // navigation change only after that synchronous update has returned.
            await Task.yield()
            guard let self, let marker, let window = marker.routableWindow,
                  self.pendingRequest == request else { return }
            self.pendingRequest = nil
            marker.openModelSettings()
            self.presentWindow(window)
        }
    }

    fileprivate func cancelPendingRequest(_ request: UUID?) {
        guard let request, pendingRequest == request else { return }
        pendingRequest = nil
    }

    private func marker(in view: NSView) -> StockSageModelSetupWindowMarker? {
        if let marker = view as? StockSageModelSetupWindowMarker,
           marker.router === self, marker.routableWindow != nil {
            return marker
        }
        for child in view.subviews {
            if let marker = marker(in: child) { return marker }
        }
        return nil
    }
}

struct StockSageModelSetupWindowLink: NSViewRepresentable {
    var openModelSettings: @MainActor () -> Void

    func makeNSView(context: Context) -> StockSageModelSetupWindowMarker {
        StockSageModelSetupWindowMarker(router: .shared, openModelSettings: openModelSettings)
    }

    func updateNSView(_ view: StockSageModelSetupWindowMarker, context: Context) {
        view.updateRoute(openModelSettings)
    }
}

@MainActor
final class StockSageModelSetupWindowMarker: NSView {
    fileprivate let router: StockSageModelSetupWindowRoute
    fileprivate var openModelSettings: @MainActor () -> Void
    fileprivate var scheduledRequest: UUID?
    private weak var observedWindow: NSWindow?
    private var windowHasClosed = false

    fileprivate var routableWindow: NSWindow? { windowHasClosed ? nil : window }

    init(router: StockSageModelSetupWindowRoute, openModelSettings: @escaping @MainActor () -> Void) {
        self.router = router
        self.openModelSettings = openModelSettings
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if observedWindow !== window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            observedWindow = window
            windowHasClosed = false
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                                       name: NSWindow.willCloseNotification, object: window)
            }
        }
        router.deliverPendingRequest(to: self)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === observedWindow else { return }
        // close() can leave a retained window's native views attached. Invalidate
        // synchronously, before a deferred route can navigate or present it again.
        windowHasClosed = true
        router.cancelPendingRequest(scheduledRequest)
        scheduledRequest = nil
    }

    func updateRoute(_ route: @escaping @MainActor () -> Void) {
        openModelSettings = route
        router.deliverPendingRequest(to: self)
    }
}
#endif
