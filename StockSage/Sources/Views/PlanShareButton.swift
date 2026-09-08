import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit   // NSSavePanel for the "Save as file…" fallback — iOS's share sheet
                // already offers "Save to Files", so no iOS equivalent is needed.
#endif

/// Share/export button for a trade plan's text. Sits beside the sheet's "Copy plan"
/// capsule (see `MarketsView.fullPlanText`) and offers a second transport for the
/// SAME string — `ShareLink` (Mail/Messages/AirDrop/etc. via the system share sheet)
/// as the primary tap, plus a "Save as file…" alternative via a context menu (macOS
/// has no long-press; a context menu is the platform-idiomatic substitute) that
/// writes `NSSavePanel`-chosen `<symbol>-plan.txt`.
///
/// Rechecks the captured quote at transfer/save time, not merely when the view renders.
/// Plan content still comes from the existing builder; expired content becomes a draft status.
struct PlanShareButton: View {
    let planText: String
    let symbol: String
    let priceAsOf: Date?
    let isSample: Bool
    /// Icon glyph point size — pass the caller's own scaled-metric font so this
    /// button visually matches its sibling icon buttons (no font tokens of its own).
    var iconSize: CGFloat = 11

    @State private var saveError: String?

    private var document: PlanShareDocument {
        PlanShareDocument(planText: planText, symbol: symbol, priceAsOf: priceAsOf, isSample: isSample)
    }

    var body: some View {
        ShareLink(item: document, preview: SharePreview("\(symbol) plan")) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(DS.Palette.surfaceStroke, lineWidth: 1))
        }
        .buttonStyle(LuxPressStyle())
        .accessibilityLabel("Share plan")
        .help("Share this trade plan (Mail, Messages, AirDrop, and more). Right-click for \"Save as file…\".")
        #if os(macOS)
        .contextMenu {
            Button("Save as file…") { saveToFile() }
        }
        #endif
        .alert("Couldn't save plan", isPresented: .constant(saveError != nil), presenting: saveError) { _ in
            Button("OK") { saveError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    #if os(macOS)
    /// Recheck AFTER the modal panel closes: the quote may expire while choosing a file.
    private func saveToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(symbol)-plan.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.text().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            saveError = error.localizedDescription
        }
    }
    #endif
}

/// Immutable share payload. Native transfer requests can arrive after the sheet was opened.
struct PlanShareDocument: Transferable, Sendable {
    let planText: String
    let symbol: String
    let priceAsOf: Date?
    let isSample: Bool

    nonisolated func text(at now: Date = Date()) -> String {
        StockSageTradePlan.draftOnlyStatus(symbol: symbol, priceAsOf: priceAsOf,
                                          isSample: isSample, now: now) ?? planText
    }

    nonisolated static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { document in document.text() })
    }
}
