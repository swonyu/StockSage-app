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

// Review 2026-07-27: the former iOS no-op `.help` shim is GONE — SwiftUI's native iOS
// `.help` exists (accessibility hint + iPad pointer tooltip) and the same-module shim
// was silently shadowing it app-wide, stripping every assistive hint.

extension View {
    /// Decimal pad for numeric entry on iOS; inert on macOS. (Review 2026-07-27: price/size
    /// fields showed a full QWERTY keyboard with autocorrect on iPhone.)
    @ViewBuilder func decimalKeyboardOnIOS(_ numeric: Bool = true) -> some View {
        #if os(iOS)
        if numeric { self.keyboardType(.decimalPad).autocorrectionDisabled() } else { self }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// iOS suppresses notification banners while the app is FOREGROUND unless a delegate
/// opts in — and foreground is exactly when the iOS monitor runs (no background daemon).
/// Without this, every alert the monitor pushes on-phone would be silently invisible.
final class StockSageNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = StockSageNotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list, .sound] }   // .list: survive in Notification Center after the banner (review 2026-07-27)

    /// Tap deep-link (2026-07-27): route to the tapped symbol — MarketsView listens and opens
    /// the symbol's idea sheet (or the Alerts section when no idea is on the board).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let symbol = response.notification.request.content.userInfo["symbol"] as? String else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .stockSageOpenSymbol, object: symbol)
        }
    }
}

#endif

// Cross-platform constant (the POSTER is iOS-only, but the MarketsView listener compiles
// on both platforms — macOS simply never receives it).
extension Notification.Name {
    /// Payload: the tapped alert's symbol (String) in `object`.
    static let stockSageOpenSymbol = Notification.Name("stocksage.openSymbol")
}
