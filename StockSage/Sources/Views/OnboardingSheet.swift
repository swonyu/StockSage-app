import SwiftUI

// MARK: - First-trade onboarding (extension E5, 2026-07-16)
//
// A one-time checklist walking the documented first-real-trade journey: broker account →
// scan → read the honesty surfaces → size → gate → place → journal → close. Educational
// framing only (the app's standing disclaimer applies); nothing here fires orders or
// changes engine state. Shows once (`stocksage.onboarding.done`); reopenable from Settings.
// Also hosts the one-click "Import from Salehman AI" migration — the natural first-launch
// moment to bring over an existing journal/portfolio (StockSageBackup.importFromParentApp).

struct OnboardingSheet: View {
    @Binding var isPresented: Bool
    @AppStorage("stocksage.onboarding.done") private var onboardingDone = false
    @State private var importResult: String?

    private struct Step: Identifiable {
        let id: Int
        let icon: String
        let title: String
        let detail: String
    }

    private let steps: [Step] = [
        .init(id: 1, icon: "building.columns", title: "Open a broker account",
              detail: "Tadawul: a Saudi broker app (e.g. Al Rajhi Capital, SNB Capital, Alinma, Derayah). US/NASDAQ: a broker with international accounts (e.g. IBKR). This app never places orders — it prepares them for you."),
        .init(id: 2, icon: "magnifyingglass", title: "Run \"Find ideas\"",
              detail: "Scans the 901-name Tadawul + NASDAQ universe and ranks ideas. The first scan of the day takes a few minutes; results stream in."),
        .init(id: 3, icon: "exclamationmark.triangle", title: "Read the honesty labels",
              detail: "Win% is ASSUMED until your own trades calibrate it. EV is GROSS unless marked net. Signal strength is a rules-based score, NOT a probability. These labels are the product."),
        .init(id: 4, icon: "scalemass", title: "Size by the loss, not the hope",
              detail: "Enter your account size and risk % — the sizer computes shares so a stop-out loses exactly that fraction. SAR positions size correctly against a USD account."),
        .init(id: 5, icon: "checkmark.shield", title: "Check the pre-trade gate",
              detail: "The gate blocks setups with no stop, weak net reward:risk, or imminent earnings. A blocked idea exports a status report, never an order ticket."),
        .init(id: 6, icon: "doc.on.clipboard", title: "Copy the plan → place at your broker",
              detail: "The copied plan carries entry/stop/target (Tadawul tick-grid checked), size, and every warning. Type it into your broker exactly; the plan is the bridge."),
        .init(id: 7, icon: "book.closed", title: "Journal the fill",
              detail: "Record the trade with your PLANNED price and your actual FILL — the app measures your real execution cost from them. Your own fills are the one dataset no research can replace."),
        .init(id: 8, icon: "xmark.circle", title: "Close with your eyes open",
              detail: "The close form previews the exact P&L and R-multiple at your typed exit — in the position's own currency — before you confirm."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your first real trade — the honest path")
                .font(.title2.weight(.bold))
            Text("StockSage prepares decisions; it never executes them. Every number is labeled for what it is — an estimate, a measurement, or an assumption.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.icon)
                                .frame(width: 22)
                                .foregroundStyle(DS.Palette.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(step.id). \(step.title)").font(.callout.weight(.semibold))
                                Text(step.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 340)

            Divider()

            // Migration: the parent app's journal/portfolio, one click, honest result line.
            HStack(spacing: 10) {
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
                Spacer(minLength: 0)
            }


            HStack {
                Spacer()
                Button("Get started") {
                    onboardingDone = true
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 560)   // fixed mac sheet width — fenced: no iPhone is 560pt wide (review 2026-07-27)
        #else
        .frame(maxWidth: 560)
        #endif
    }
}
