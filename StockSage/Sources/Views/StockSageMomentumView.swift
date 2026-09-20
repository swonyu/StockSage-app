#if os(macOS)
import SwiftUI

/// Saved, descriptive candle context. This view never collects data or starts an assessment.
struct StockSageMomentumView: View {
    let market: StockSageMomentum.Market?
    let stock: StockSageMomentum.Stock?

    init(market: StockSageMomentum.Market? = nil, stock: StockSageMomentum.Stock? = nil) {
        self.market = market
        self.stock = stock
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 16) {
                if let market {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Market proxy momentum", systemImage: "chart.xyaxis.line").font(.headline)
                        Text("SPY and QQQ price changes · completed minutes")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(market.note).font(.caption).fixedSize(horizontal: false, vertical: true)
                        timestamp("Captured", market.capturedAt)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            seriesCard(market.spy, now: timeline.date).frame(minWidth: 240, idealWidth: 240, maxWidth: .infinity)
                            seriesCard(market.qqq, now: timeline.date).frame(minWidth: 240, idealWidth: 240, maxWidth: .infinity)
                        }
                        VStack(spacing: 12) {
                            seriesCard(market.spy, now: timeline.date)
                            seriesCard(market.qqq, now: timeline.date)
                        }
                    }
                }
                if let stock {
                    Label("\(stock.symbol) stock momentum", systemImage: "waveform.path").font(.headline)
                    seriesCard(stock.series, now: timeline.date)
                    volumeCard(stock.volumeAcceleration, asOf: stock.series.asOf, now: timeline.date)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            relativeCard(stock.vsSPY, proxy: "SPY", now: timeline.date).frame(minWidth: 260, idealWidth: 260, maxWidth: .infinity)
                            relativeCard(stock.vsQQQ, proxy: "QQQ", now: timeline.date).frame(minWidth: 260, idealWidth: 260, maxWidth: .infinity)
                        }
                        VStack(spacing: 12) {
                            relativeCard(stock.vsSPY, proxy: "SPY", now: timeline.date)
                            relativeCard(stock.vsQQQ, proxy: "QQQ", now: timeline.date)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func seriesCard(_ series: StockSageMomentum.Series, now: Date) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(series.symbol) · \(series.sessionLabel)").font(.subheadline.weight(.semibold))
                Text(ageLabel(asOf: series.asOf, available: series.verifiedMinutes, now: now))
                    .font(.caption).foregroundStyle(.secondary)
                if let asOf = series.asOf { timestamp("Last completed minute ends", asOf) }
                ForEach(series.returns) { value in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(value.minutes) min").font(.subheadline.weight(.medium))
                            Spacer(minLength: 8)
                            Text(value.percent.map(percent) ?? "Unavailable").monospacedDigit()
                        }
                        if let start = value.start, let end = value.end, value.percent != nil {
                            Text("\(stamp(start)) → \(stamp(end)) · \(value.sessionLabel)")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(value.note).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(series.note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                timestamp("Captured", series.capturedAt)
                Text("Close-to-close references, not live quotes or executable fills.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func relativeCard(_ windows: [StockSageMomentum.Relative], proxy: String, now: Date) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Stock relative to \(proxy)").font(.subheadline.weight(.semibold))
                Text("Percentage-point difference on matching intervals; this is not market breadth.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(windows) { value in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(value.minutes) min").font(.subheadline.weight(.medium))
                            Spacer(minLength: 8)
                            Text(value.differencePercentagePoints.map { signed($0) + " pp" } ?? "Unavailable")
                                .monospacedDigit()
                        }
                        if let stock = value.stockPercent, let reference = value.proxyPercent,
                           let start = value.start, let end = value.end {
                            Text("Stock \(percent(stock)) · \(proxy) \(percent(reference))")
                                .font(.caption).monospacedDigit()
                            Text("\(stamp(start)) → \(stamp(end)) · \(value.sessionLabel)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(ageLabel(asOf: end, available: true, now: now)).font(.caption)
                        } else {
                            Text(value.note).font(.caption)
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                }
                Text("The shared endpoint may be older than the latest stock candle; each interval is dated above.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func volumeCard(_ volume: StockSageMomentum.VolumeAcceleration, asOf: Date?, now: Date) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Five-minute volume acceleration").font(.subheadline.weight(.semibold))
                if let multiple = volume.multiple, let latest = volume.latestFiveMinuteVolume,
                   let mean = volume.meanPrecedingVolume {
                    Text("\(multiple.formatted(.number.precision(.fractionLength(2))))× preceding-window mean")
                        .font(.title3.weight(.semibold)).monospacedDigit()
                    Text("Latest five minutes: \(latest.formatted(.number.precision(.fractionLength(0)))) shares. Mean of the preceding three nonoverlapping five-minute windows: \(mean.formatted(.number.precision(.fractionLength(0)))) shares.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(ageLabel(asOf: asOf, available: true, now: now)).font(.caption)
                    if let start = volume.start, let end = volume.end {
                        Text("Twenty-minute coverage: \(stamp(start)) → \(stamp(end))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Unavailable").font(.subheadline.weight(.medium))
                }
                Text(volume.note).font(.caption).fixedSize(horizontal: false, vertical: true)
                Text("Unvalidated alert defaults: Micro cap absolute five-minute change ≥3%; Large cap ≥1%; both require volume acceleration ≥3× and twenty consecutive positive-volume completed minutes. Rising and falling moves are descriptive alerts, not qualified Buys or entry/stop/target plans. This measure is separate from time-matched daily RVOL.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timestamp(_ label: String, _ date: Date) -> some View {
        Text("\(label): \(stamp(date))").font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func stamp(_ date: Date) -> String { date.ISO8601Format() }
    private func signed(_ value: Double) -> String {
        (value > 0 ? "+" : "") + value.formatted(.number.precision(.fractionLength(2)))
    }
    private func percent(_ value: Double) -> String { signed(value) + "%" }
    private func ageLabel(asOf: Date?, available: Bool, now: Date) -> String {
        guard available, let asOf else { return "Verified completed-minute coverage unavailable" }
        return (0...StockSageMomentum.maximumAge).contains(now.timeIntervalSince(asOf))
            ? "Fresh completed-minute snapshot · at most 180 seconds old"
            : "Historical snapshot · no longer eligible for a fresh momentum alert"
    }
}
#endif
