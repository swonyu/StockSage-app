import SwiftUI
import UniformTypeIdentifiers

struct StockSagePersonalBackupView: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var portfolio: StockSagePortfolio
    @ObservedObject var journal: StockSageJournalStore
    @ObservedObject var prices: StockSageManualPriceBook
    @State private var prepared: Data?
    @State private var preparedAt: Date?
    @State private var message: String?
    @State private var restoring = false
    @State private var confirmDeletePrices = false
    @State private var operation: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Back up your records").font(.title2.bold())
            Text("One JSON file includes holdings, journal records, watchlist, retained price alerts and every personal price observation. Recorded currencies, units, dates and IDs are preserved.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Settings, credentials, Chat and imported research are separate and are not included.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Prepare backup", systemImage: "externaldrive", action: prepareBackup)
                .buttonStyle(.borderedProminent).disabled(isBusy).accessibilityIdentifier("personalBackup.prepare")
            if let prepared, let preparedAt {
                ShareLink(item: StockSageBackup.JSONExport(data: prepared), preview: SharePreview("StockSage personal records")) {
                    Label("Save or share prepared JSON", systemImage: "square.and.arrow.up")
                }.buttonStyle(.bordered).disabled(isBusy).accessibilityIdentifier("personalBackup.share")
                Text("Snapshot prepared \(preparedAt.formatted(date: .abbreviated, time: .shortened)). Prepare it again after editing your records.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Restore backup", systemImage: "square.and.arrow.down") { restoring = true }
                .buttonStyle(.bordered).disabled(isBusy).accessibilityIdentifier("personalBackup.restore")
            Text("Restore validates the whole file before committing. It merges missing IDs and keeps your existing records; repeating the same restore does not create duplicates.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Backups support up to 50 MB of actual JSON bytes. Oversized files are refused without changing your records.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if isBusy {
                ProgressView("Preparing your records…").accessibilityIdentifier("personalBackup.progress")
                Button("Cancel operation", action: cancelOperation).buttonStyle(.bordered)
                    .accessibilityIdentifier("personalBackup.cancelWork")
            }
            if let message { Text(message).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("personalBackup.feedback") }
            Divider()
            Text("Personal price history").font(.headline)
            Text("\(prices.records.count) saved observations. These are separate from market-feed caches and your holdings.")
                .foregroundStyle(.secondary)
            Button("Delete personal price history", role: .destructive) { confirmDeletePrices = true }
                .buttonStyle(.bordered).disabled(isBusy || !prices.hasLoadedRecords || prices.records.isEmpty)
                .accessibilityIdentifier("personalBackup.deletePrices")
        }
        .padding(16).frame(maxWidth: 780, alignment: .leading)
        .navigationTitle("Backup & restore")
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in
            do { restoreBackup(try result.get()) }
            catch {
                let failure = error as NSError
                if failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError { message = error.localizedDescription }
            }
        }
        .onDisappear(perform: cancelOperation)
        .confirmationDialog("Delete personal price history?", isPresented: $confirmDeletePrices, titleVisibility: .visible) {
            Button("Delete all personal prices", role: .destructive) {
                if prices.removeAll() { prepared = nil; preparedAt = nil; message = "Personal price history deleted. Holdings and journal records were kept." }
                else { message = prices.lastError }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes your saved price observations. Holdings will have no personal mark until you record another. Save a JSON backup first if you want to restore them.") }
    }

    private func cancelOperation() {
        let wasBusy = isBusy
        requestID = UUID()
        operation?.cancel()
        operation = nil
        isBusy = false
        if wasBusy {
            message = "Cancellation requested. File or JSON work may still be finishing; another backup operation can start after it closes. No cancelled result will be applied."
        }
    }

    private func prepareBackup() {
        guard !isBusy else { return }
        let id = UUID()
        requestID = id; isBusy = true; message = nil
        operation = Task { @MainActor in
            defer { if requestID == id { isBusy = false; operation = nil } }
            do {
                let bytes = try await StockSageBackup.exportInBackground(journal: journal, portfolio: portfolio, store: store)
                try Task.checkCancellation()
                guard requestID == id else { return }
                prepared = bytes; preparedAt = Date()
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                prepared = nil; preparedAt = nil; message = error.localizedDescription
            }
        }
    }

    private func restoreBackup(_ url: URL) {
        guard !isBusy else { return }
        let id = UUID()
        requestID = id; isBusy = true; message = nil
        operation = Task { @MainActor in
            defer { if requestID == id { isBusy = false; operation = nil } }
            do {
                let validated = try await StockSageBackup.prepareRestore(from: url)
                try Task.checkCancellation()
                guard requestID == id else { return }
                // No await between the final ownership check and the existing
                // five-collection atomic merge against the current records.
                switch StockSageBackup.apply(validated, journal: journal, portfolio: portfolio, store: store) {
                case .success(let summary): message = summary.message; prepared = nil; preparedAt = nil
                case .failure(let error): message = error.localizedDescription
                }
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                message = error.localizedDescription
            }
        }
    }
}
