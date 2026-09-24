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
        .init(id: 1, icon: "magnifyingglass", title: "Choose your trading window",
              detail: "Open Same-day pick for one intraday candidate with a buy entry, stop and target, or choose the separate 1–7 and 7–14 trading-day Top 5 pages. These runs start manually. Separately enabled Micro cap and Large cap watching can request automatic reviews; switching tabs does not start a manual run."),
        .init(id: 2, icon: "list.number", title: "Separate rankings from qualified picks",
              detail: "Each trading-day page shows its own deterministic ranked five when enough completed research exists. Ranked stocks can fail the strict screen; only Qualified stocks passed it. The separate model comparison selects from eligible Buy / Strong Buy opinions. Same-day research can return no pick when its checks fail."),
        .init(id: 3, icon: "doc.text.magnifyingglass", title: "Read the evidence and uncertainty",
              detail: "Open a result to inspect its dated sources, warnings and coverage gaps. Check the price source and timestamp. Model opinions and the ranking are unvalidated; they are not forecasts or win probabilities."),
        .init(id: 4, icon: "clock.arrow.circlepath", title: "Return to Saved research",
              detail: "Completed runs keep the original results and evidence. You can request an outcome check after the first monitoring New York session has fully ended. Strict comparison scenarios finish at the first verified stop or target event, otherwise at the 7th or 14th session close. Older runs retain their recorded policy. Later outcomes never rewrite the original opinions; missing prices remain unavailable."),
        .init(id: 5, icon: "star", title: "Follow companies with Watchlist and Chat",
              detail: "Add symbols in Watchlist or ask Chat, such as “add RKLB to watchlist.” Chat can help you inspect your evidence. Adding a symbol does not place an order."),
        .init(id: 6, icon: "scalemass", title: "Review the planned risk",
              detail: "Sizing estimates risk at the planned stop. Gaps, actual fills and costs can make the loss larger. Review all warnings and assumptions; a copied plan still needs your own broker review before any real trade."),
        .init(id: 7, icon: "book.closed", title: "Keep your records in Library",
              detail: "Open Library → Holdings & journal → Journal to record a trade you made, including planned and actual fill prices. Log trade opens an unsaved draft. Review the close preview and recorded units before saving a close; editing the journal does not execute a broker order."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Welcome to StockSage")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        Text("One same-day pick and separate Top 5 research for 1–7 and 7–14 trading days. Find automatic cap watching on its own pages, and saved research, Chat and your records in Library.")
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
                        Text("Have a StockSage backup? Open Library → Holdings & journal → Journal → Data → Restore backup to select the backup file on your iPhone.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
