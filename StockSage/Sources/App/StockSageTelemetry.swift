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
    private(set) var recentDiagnostics: [String] = []
    private let maxEntries = 40

    func start() {
        MXMetricManager.shared.add(self)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    // Daily aggregated performance metrics (launch time, hang time, memory).
    func didReceive(_ payloads: [MXMetricPayload]) {
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
            record("METRICS \(p.timeStampBegin)…\(p.timeStampEnd) — " + parts.joined(separator: " · "))
        }
    }

    // Crash/hang/CPU/disk diagnostics with call stacks.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            for d in p.hangDiagnostics ?? [] {
                record("HANG \(d.hangDuration) — main thread stalled")
            }
            for d in p.cpuExceptionDiagnostics ?? [] {
                record("CPU EXCEPTION \(d.totalCPUTime) over \(d.totalSampledTime)")
            }
            for d in p.diskWriteExceptionDiagnostics ?? [] {
                record("DISK WRITE \(d.totalWritesCaused)")
            }
            for d in p.crashDiagnostics ?? [] {
                record("CRASH \(d.exceptionType?.stringValue ?? "?") code \(d.exceptionCode?.stringValue ?? "?")")
            }
        }
    }

    private func record(_ line: String) {
        recentDiagnostics.insert("\(Date().formatted(date: .abbreviated, time: .shortened)) \(line)", at: 0)
        if recentDiagnostics.count > maxEntries { recentDiagnostics.removeLast() }
        NSLog("STOCKSAGE-TELEMETRY %@", line)
    }
}
#endif
