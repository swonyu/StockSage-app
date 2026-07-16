import SwiftUI
import UniformTypeIdentifiers
import AppKit   // NSSavePanel for the "Save as file…" fallback

/// Share/export button for a trade plan's text. Sits beside the sheet's "Copy plan"
/// capsule (see `MarketsView.fullPlanText`) and offers a second transport for the
/// SAME string — `ShareLink` (Mail/Messages/AirDrop/etc. via the system share sheet)
/// as the primary tap, plus a "Save as file…" alternative via a context menu (macOS
/// has no long-press; a context menu is the platform-idiomatic substitute) that
/// writes `NSSavePanel`-chosen `<symbol>-plan.txt`.
///
/// HONESTY: this view never composes plan content — it only transports the exact
/// `planText` string its caller (an existing tested builder, e.g. `fullPlanText`)
/// already produced. The shared/saved artifact is byte-identical to what "Copy plan"
/// puts on the clipboard; there is exactly one plan-text source in the app.
struct PlanShareButton: View {
    let planText: String
    let symbol: String
    /// Icon glyph point size — pass the caller's own scaled-metric font so this
    /// button visually matches its sibling icon buttons (no font tokens of its own).
    var iconSize: CGFloat = 11

    @State private var saveError: String?

    var body: some View {
        ShareLink(item: planText) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(DS.Palette.surfaceStroke, lineWidth: 1))
        }
        .buttonStyle(LuxPressStyle())
        .help("Share this trade plan (Mail, Messages, AirDrop, and more). Right-click for \"Save as file…\".")
        .contextMenu {
            Button("Save as file…") { saveToFile() }
        }
        .alert("Couldn't save plan", isPresented: .constant(saveError != nil), presenting: saveError) { _ in
            Button("OK") { saveError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    /// NSSavePanel writing the identical `planText` string as UTF-8, suggested
    /// filename "<symbol>-plan.txt". No fabrication: whatever save fails, the
    /// error is surfaced (never silently swallowed) per the app's honesty floor.
    private func saveToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(symbol)-plan.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try planText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            saveError = error.localizedDescription
        }
    }
}
