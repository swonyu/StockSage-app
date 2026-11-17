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

    #if os(iOS)
    private let steps: [Step] = [
        .init(id: 1, icon: "star", title: "Follow companies",
              detail: "Open Watchlist to save tickers and record personal prices with their currency, units and date. No data subscription is needed. Adding a ticker does not place an order."),
        .init(id: 2, icon: "briefcase", title: "Keep your holdings",
              detail: "Open Portfolio to record shares and cost in explicit units. Recorded marks value each currency separately. Unknown legacy cost units keep P&L unavailable."),
        .init(id: 3, icon: "bubble.left.and.bubble.right", title: "Ask about your evidence",
              detail: "Chat can explain captured app facts using built-in AI on supported devices. Availability depends on the device and language. It does not select or place trades."),
        .init(id: 4, icon: "books.vertical", title: "Use Library for other tools",
              detail: "Open Library for Backup & restore, a manual stop-risk calculator, and stored research and events. Core tools work offline without a paid account."),
        .init(id: 5, icon: "clock.arrow.circlepath", title: "Read saved research carefully",
              detail: "Reports already stored on this iPhone keep their original dates, model and evidence. They are read-only historical records. Mac research does not automatically sync here."),
        .init(id: 6, icon: "scalemass", title: "Review risks and assumptions",
              detail: "A planned stop may not limit your loss. Gaps, fills and costs can increase it. Recorded prices are not live quotes, and historical results do not predict future profits."),
        .init(id: 7, icon: "book.closed", title: "Keep a local journal",
              detail: "Open Portfolio, then Journal. Record actual entries and exits in the same declared units. Check the date and values before saving. Journal changes do not place broker orders."),
    ]
    #else
    private let steps: [Step] = [
        .init(id: 1, icon: "magnifyingglass", title: "Start a research run",
              detail: "Choose Same-day pick, 1–7 days or 7–14 days. Start each run yourself; changing tabs does not run research. Automatic watching has separate controls."),
        .init(id: 2, icon: "list.number", title: "Understand the labels",
              detail: "Ranked means sorted by the app. Qualified means the strict screen passed. These labels do not promise a profit, and some runs find no pick."),
        .init(id: 3, icon: "doc.text.magnifyingglass", title: "Check the evidence",
              detail: "Read source dates, price timestamps, warnings and missing information. Rankings and model opinions are unvalidated; they are not forecasts or odds of success."),
        .init(id: 4, icon: "clock.arrow.circlepath", title: "Find saved research",
              detail: "Open Library → Saved research to revisit earlier results and evidence. Request an outcome check when it becomes available. Original opinions stay unchanged; missing prices stay unavailable."),
        .init(id: 5, icon: "star", title: "Follow companies",
              detail: "Open Watchlist from Library to save companies. Chat can help you inspect your evidence. Adding a symbol does not place an order."),
        .init(id: 6, icon: "scalemass", title: "Treat risk figures as estimates",
              detail: "A planned stop may not limit your loss. Price gaps, fills and costs can increase it. Review warnings and assumptions before using a plan with your broker."),
        .init(id: 7, icon: "book.closed", title: "Keep a local journal",
              detail: "Open Library → Holdings & journal → Journal. Log trade starts an unsaved draft. Check prices, units and the close preview before saving. Journal changes do not place broker orders."),
    ]

    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Welcome to StockSage")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        Text({
                            #if os(iOS)
                            "Follow companies, keep your holdings and journal, and ask about the evidence in your app. Four tabs keep the main tools close."
                            #else
                            "Research ideas, follow companies and keep your trading records. Choose a time window, then review the evidence and risks."
                            #endif
                        }())
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.icon)
                                .fixedSize().frame(minWidth: 22, alignment: .leading)
                                .foregroundStyle(DS.Palette.accentText)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(step.id). \(step.title)").font(.callout.weight(.semibold))
                                    .accessibilityAddTraits(.isHeader)
                                    .accessibilityIdentifier("onboarding.step.\(step.id)")
                                Text(step.detail).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Divider()
                    #if os(macOS)
                    parentAppImport
                    #else
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bring your saved records").font(.headline)
                        Text("Have a StockSage backup? Open Library → Backup & restore → Restore backup.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("onboarding.restorePath")
                        Text("Select the backup file on your iPhone.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("onboarding.restoreFile")
                    }
                    #endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    onboardingDone = true
                    isPresented = false
                } label: {
                    Text("Get started")
                        #if os(iOS)
                        .frame(minHeight: 44)
                        #endif
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.getStarted")
            }
        }
        #if os(macOS)
        .padding(24)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 400, idealHeight: 640)
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
            Text("Bring your saved records").font(.headline)
            Text("Optionally import journal records from Salehman AI. Existing records stay in place.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            .accessibilityIdentifier("onboarding.import")
            if let importResult {
                Text(importResult).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    #endif
}
