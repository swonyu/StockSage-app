import Foundation
import Testing
import Darwin
@testable import StockSage

@MainActor struct StockSageRecordWriterTests {
    @Test func kernelLeaseExcludesCompetingDescriptorsAndReleasesWithoutDeletingTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("record-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("writer.lock")
        var lease: StockSageFileLock? = try StockSageFileLock(url: path)
        #expect(throws: StockSageFileLock.Failure.self) { try StockSageFileLock(url: path) }
        #if os(macOS)
        // Separate process, same explicit temporary path; no owner preferences or app launch.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = ["-e", "open(my $f, '+<', $ARGV[0]) or exit 90; flock($f, 2|4) and exit 91; exit(($!{EWOULDBLOCK} || $!{EAGAIN}) ? 0 : 92);", path.path]
        try child.run()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #endif
        withExtendedLifetime(lease) {}
        lease = nil
        #expect(FileManager.default.fileExists(atPath: path.path))
        let replacement = try StockSageFileLock(url: path)
        withExtendedLifetime(replacement) {}
    }

    @Test func unregisteredProfileCannotReadMutateOrRestoreRecords() throws {
        let suite = "unregistered-records-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let trade = TradeRecord(symbol: "TST", side: .long, entry: 100, stop: 90, target: 120,
                                shares: 1, openedAt: Date(timeIntervalSince1970: 100))
        let bytes = try JSONEncoder().encode([trade])
        let journalKey = "stocksage.journal.v1", paperKey = "stocksage.papertrades.v1"
        defaults.set(bytes, forKey: journalKey)
        defaults.set(bytes, forKey: paperKey)
        let journal = StockSageJournalStore(defaults: defaults)
        let paper = StockSagePaperTradeStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        #expect(!journal.hasLoadedRecords && !paper.hasLoadedRecords && !portfolio.hasLoadedRecords)
        #expect(!journal.add(trade))
        journal.remove(trade.id)
        paper.reset()
        #expect(!portfolio.add(symbol: "TST", shares: 1, costBasis: 100))
        #expect(throws: StockSageFileLock.Failure.self) { try journal.prepareBackupImport([trade]) }
        #expect(throws: StockSageFileLock.Failure.self) { try portfolio.prepareBackupImport([]) }
        #expect(throws: StockSageFileLock.Failure.self) {
            try StockSageRecordDeletions(defaults: defaults, recordKey: journalKey).mark([trade.id])
        }
        #expect(defaults.data(forKey: journalKey) == bytes && defaults.data(forKey: paperKey) == bytes)
        #expect(!defaults.bool(forKey: journalKey + ".deleted." + trade.id.uuidString))
        #expect(defaults.object(forKey: "stocksage_portfolio_v1") == nil)
        #expect(journal.lastError != nil && paper.lastError != nil && portfolio.lastError != nil)
        #expect(!StockSageRecordWriter.mayRead(.standard))
        #expect(StockSageRecordWriter.fixtureDefaults(suiteName: "SA.StockSage") == nil)
    }
}
