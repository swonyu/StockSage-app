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
    /// ≥44pt hit area on iOS without changing visual layout (HIG floor for touch;
    /// review 2026-07-27: caption-size row buttons were ~18pt tappable). The
    /// grow-capture-shrink dance expands only the HIT shape, not the layout.
    @ViewBuilder func touchHitArea() -> some View {
        #if os(iOS)
        self.padding(12).contentShape(Rectangle()).padding(-12)
        #else
        self
        #endif
    }

    /// Decimal pad for numeric entry on iOS; inert on macOS. (Review 2026-07-27: price/size
    /// fields showed a full QWERTY keyboard with autocorrect on iPhone.)
    @ViewBuilder func decimalKeyboardOnIOS(_ numeric: Bool = true) -> some View {
        #if os(iOS)
        if numeric { self.keyboardType(.decimalPad).autocorrectionDisabled() } else { self }
        #else
        self
        #endif
    }

    /// `.help` on every platform, plus a visible ⓘ on iOS. Use for caveats a sighted
    /// phone user must be able to reach; plain `.help` stays fine for pure hover polish.
    @ViewBuilder func explain(_ text: String) -> some View {
        #if os(iOS)
        self.help(text).modifier(ExplainAffordance(text: text))
        #else
        self.help(text)
        #endif
    }
}

#if os(iOS)
/// iOS has no hover, so `.help` text is invisible to sighted users — review 2026-07-28
/// counted 138 of this app's caveats living there. `explain(_:)` keeps the `.help`
/// (VoiceOver hint + iPad pointer) AND adds a tappable ⓘ that presents the same string.
/// One source, no drift.
struct ExplainAffordance: ViewModifier {
    let text: String
    @State private var showing = false
    func body(content: Content) -> some View {
        HStack(spacing: 3) {
            content
            Button { showing = true } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .touchHitArea()
            .accessibilityHidden(true)   // the .help already speaks this
        }
        .popover(isPresented: $showing) {
            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Space.md)
            }
            .frame(maxWidth: 320)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(DS.Palette.bgTop)
        }
    }
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
        -> UNNotificationPresentationOptions {
        await StockSageNotificationHandler.shared.present(notification.request.content)
    }

    /// Tap deep-link (2026-07-27): route to the tapped symbol — MarketsView listens and opens
    /// the symbol's idea sheet (or the Alerts section when no idea is on the board).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            StockSageNotificationRouter.shared.receive(action: response.actionIdentifier,
                userInfo: response.notification.request.content.userInfo)
        }
    }
}

#endif

// Cross-platform constant (the POSTER is iOS-only, but the MarketsView listener compiles
// on both platforms — macOS simply never receives it).
extension Notification.Name {
    /// Payload: the tapped alert's symbol (String) in `object`.
    static let stockSageOpenSymbol = Notification.Name("stocksage.openSymbol")
    static let stockSageResearchReady = Notification.Name("stocksage.researchReady")
}
