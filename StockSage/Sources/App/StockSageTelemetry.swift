import Foundation
#if os(iOS)
import MetricKit

/// MetricKit field telemetry — external-report item 10, owner-signed 2026-07-28.
///
/// The report asks for `MXMetricManagerSubscriber` so the three payload classes that actually
/// matter to a live-data app are captured from the field rather than guessed at:
///   • hang diagnostics  — main-thread stalls during market-data ingestion
///   • CPU exceptions    — a runaway loop burning battery behind the board
///   • disk-write        — excessive writes (the history cache is the obvious suspect)
///
/// Deliberately minimal and PRIVATE: payloads are summarised into a local log the owner can
/// read, and nothing is transmitted anywhere. StockSageX is a private build with no analytics
/// backend, and inventing one would be a privacy decision the owner never made.
final class StockSageTelemetry: NSObject, MXMetricManagerSubscriber {
    static let shared = StockSageTelemetry()

    /// Newest-first, capped — this is a debugging aid, not a database.
    @MainActor private(set) var recentDiagnostics: [String] = []
    private let maxEntries = 40

    func start() {
        MXMetricManager.shared.add(self)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    // MetricKit delivers on a BACKGROUND dispatch queue. These callbacks must therefore be
    // nonisolated: when they inherited main-actor isolation, Swift's executor check trapped
    // (EXC_BREAKPOINT in _dispatch_assert_queue_fail) and crashed the app AT LAUNCH — MetricKit
    // flushes pending payloads on launch, so the telemetry meant to observe crashes was causing
    // one. Formatting happens off-actor; only the state write hops to the main actor.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        var lines: [String] = []
        for p in payloads {
            var parts: [String] = []
            if let hang = p.applicationResponsivenessMetrics?.histogrammedApplicationHangTime {
                parts.append("hang buckets: \(hang.bucketEnumerator.allObjects.count)")
            }
            if let launch = p.applicationLaunchMetrics?.histogrammedTimeToFirstDraw {
                parts.append("first-draw buckets: \(launch.bucketEnumerator.allObjects.count)")
            }
            if let mem = p.memoryMetrics?.peakMemoryUsage {
                parts.append("peak memory: \(mem)")
            }
            lines.append("METRICS \(p.timeStampBegin)…\(p.timeStampEnd) — " + parts.joined(separator: " · "))
        }
        commit(lines)
    }

    // Crash/hang/CPU/disk diagnostics with call stacks. Same background-queue delivery.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var lines: [String] = []
        for p in payloads {
            for d in p.hangDiagnostics ?? [] {
                lines.append("HANG \(d.hangDuration) — main thread stalled")
            }
            for d in p.cpuExceptionDiagnostics ?? [] {
                lines.append("CPU EXCEPTION \(d.totalCPUTime) over \(d.totalSampledTime)")
            }
            for d in p.diskWriteExceptionDiagnostics ?? [] {
                lines.append("DISK WRITE \(d.totalWritesCaused)")
            }
            for d in p.crashDiagnostics ?? [] {
                lines.append("CRASH \(d.exceptionType?.stringValue ?? "?") code \(d.exceptionCode?.stringValue ?? "?")")
            }
        }
        commit(lines)
    }

    /// Hop the collected lines onto the main actor for the single state write.
    nonisolated private func commit(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        for line in lines { NSLog("STOCKSAGE-TELEMETRY %@", line) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for line in lines.reversed() {
                self.recentDiagnostics.insert(
                    "\(Date().formatted(date: .abbreviated, time: .shortened)) \(line)", at: 0)
            }
            if self.recentDiagnostics.count > self.maxEntries {
                self.recentDiagnostics.removeLast(self.recentDiagnostics.count - self.maxEntries)
            }
        }
    }

}
#endif
