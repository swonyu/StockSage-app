import SwiftUI
import UserNotifications
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - iOS port shims (2026-07-27)
//
// The engine is platform-pure; the views were macOS-first. These shims are the ONLY
// bridge layer: clipboard (NSPasteboard vs UIPasteboard) and the macOS-only `.help`
// tooltip modifier (no hover on touch — dropped as a no-op there).

enum PlatformClipboard {
    @MainActor static func copy(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

#if os(iOS)
// ponytail: tooltips vanish on iOS rather than being redesigned — a long-press hint
// system is an owner design call, not a port decision. Accessibility labels remain.
extension View {
    func help(_ text: LocalizedStringKey) -> some View { self }
    func help(_ text: Text) -> some View { self }
    func help(_ text: String) -> some View { self }
    func help(_ text: Substring) -> some View { self }
}
#endif

#if os(iOS)
/// iOS suppresses notification banners while the app is FOREGROUND unless a delegate
/// opts in — and foreground is exactly when the iOS monitor runs (no background daemon).
/// Without this, every alert the monitor pushes on-phone would be silently invisible.
final class StockSageNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = StockSageNotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
#endif
