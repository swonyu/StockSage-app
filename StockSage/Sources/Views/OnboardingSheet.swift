import SwiftUI

// MARK: - Research and records onboarding
//
// Shows once (`stocksage.onboarding.done`) and can be reopened from Mac Settings.
// The Mac-only parent-app migration preserves the existing journal import behavior.

struct OnboardingSheet: View {
    @Binding var isPresented: Bool
    @AppStorage("stocksage.onboarding.done") private var onboardingDone = false
    #if os(macOS)
    @State private var importResult: String?
    #endif

    private struct Step: Identifiable {
        let id: Int
        let icon: String
        let title: String
        let detail: String
    }

    private let steps: [Step] = [
        .init(id: 1, icon: "magnifyingglass", title: "Start with your daily summary",
              detail: "Home shows the latest saved picks and predictions ready for review. Open Research, choose 1–7 or 7–14 trading days and run a scan. These are multi-session holding horizons, not intraday trades or long-term investment plans."),
        .init(id: 2, icon: "list.number", title: "Review up to five Buy / Strong Buy results",
              detail: "Each horizon shows at most five eligible opinions. Strong Buy comes before Buy; ties keep the scan's dated activity order. Fewer qualifying opinions means fewer results. Check completion, incomplete opinions and unchecked listings before drawing conclusions."),
        .init(id: 3, icon: "doc.text.magnifyingglass", title: "Read the evidence and uncertainty",
              detail: "Open a result to inspect its dated sources, warnings and coverage gaps. Check the price source and timestamp. Qwen opinions and the ranking are unvalidated; they are not forecasts or win probabilities."),
        .init(id: 4, icon: "clock.arrow.circlepath", title: "Return to Saved research",
              detail: "Completed runs keep a dated snapshot of the original results. Review the outcome after 7 trading days for the 1–7-day horizon, or 14 trading days for the 7–14-day horizon. Later outcomes do not rewrite the original opinions. Missing review prices remain unavailable; past results do not guarantee future returns."),
        .init(id: 5, icon: "star", title: "Follow companies with Watchlist and Chat",
              detail: "Add symbols in Watchlist or ask Chat, such as “add RKLB to watchlist.” Chat can help you inspect your evidence. Adding a symbol does not place an order."),
        .init(id: 6, icon: "scalemass", title: "Review the planned risk",
              detail: "Sizing estimates risk at the planned stop. Gaps, actual fills and costs can make the loss larger. Review all warnings and assumptions; a copied plan still needs your own broker review before any real trade."),
        .init(id: 7, icon: "book.closed", title: "Keep your records in Portfolio",
              detail: "Choose Journal to record a trade you made, including planned and actual fill prices. Log trade opens an unsaved draft. Review the close preview and recorded units before saving a close; editing the journal does not execute a broker order."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Welcome to StockSage")
                        .font(.title2.weight(.bold))
                    Text("Research for 1–7 and 7–14 trading days, with a saved record you can review later. Watchlist, Chat and your own records support that work.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.icon)
                                .fixedSize().frame(minWidth: 22, alignment: .leading)
                                .foregroundStyle(DS.Palette.accentText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(step.id). \(step.title)").font(.callout.weight(.semibold))
                                Text(step.detail).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Divider()
                    #if os(macOS)
                    parentAppImport
                    #else
                    Text("Have a StockSage backup? Open Portfolio → Journal → Data → Restore backup to select the backup file on your iPhone.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    #endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }

            Divider()

            HStack {
                Spacer()
                Button("Get started") {
                    onboardingDone = true
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .touchHitArea()
                .accessibilityIdentifier("onboarding.getStarted")
            }
        }
        #if os(macOS)
        .padding(24)
        .frame(width: 560, height: 640)
        #else
        .padding(16)
        .frame(maxWidth: 560, maxHeight: .infinity)
        #endif
        .background(DS.Palette.bgTop)
        .tint(DS.Palette.accent)
        .preferredColorScheme(.dark)
    }

    #if os(macOS)
    private var parentAppImport: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Import data from Salehman AI") {
                do {
                    if let parent = try StockSageBackup.importFromParentApp() {
                        let journal = StockSageJournalStore.shared
                        let result = journal.importNew(parent.trades)
                        importResult = "Imported \(result.added) journal trade\(result.added == 1 ? "" : "s")"
                            + (result.skipped > 0 ? " (\(result.skipped) already present)" : "")
                            + (result.rejected > 0 ? "; \(result.rejected) rejected/not saved — check journal errors" : "")
                            + ". Portfolio positions found: \(parent.positions.count) — add them from the Portfolio section."
                    } else {
                        importResult = "No Salehman AI data found on this Mac."
                    }
                } catch {
                    importResult = "Import failed: \(error.localizedDescription)"
                }
            }
            if let importResult {
                Text(importResult).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    #endif
}
