import Foundation
import SwiftUI

/// Read-only presentation for an already-computed correlation matrix.
/// Values, masks, cluster membership and thresholds remain owned by the existing model helpers.
struct CorrelationMatrixView: View {
    struct Cell: Identifiable, Equatable {
        struct ID: Hashable {
            let row: Int
            let column: Int
        }

        enum State: Equatable {
            case selfComparison, positive, negative, zero, undefined
        }

        let row: Int
        let column: Int
        let rowSymbol: String
        let columnSymbol: String
        let value: Double?
        let state: State

        var id: ID { ID(row: row, column: column) }

        var displayValue: String {
            guard let value else { return "—" }
            return value == 0 ? "0.00" : String(format: "%+.2f", value)
        }

        var fill: Color {
            let magnitude = min(abs(value ?? 0), 1)
            // Color is supplementary; keep white coefficient text legible at both extremes.
            return switch state {
            case .positive: DS.Palette.danger.opacity(0.18 + magnitude * 0.22)
            case .negative: DS.Palette.success.opacity(0.18 + magnitude * 0.22)
            case .selfComparison, .zero, .undefined: DS.Palette.surfaceAlt
            }
        }

        var accessibilityLabel: String {
            let pair = "Row \(rowSymbol), column \(columnSymbol)"
            switch state {
            case .selfComparison:
                return "\(pair): 1.00, self-comparison by matrix convention."
            case .positive:
                return "\(pair): correlation \(displayValue), positive co-movement in the displayed sample."
            case .negative:
                return "\(pair): correlation \(displayValue), opposite-direction co-movement in the displayed sample; not proof of a reliable hedge."
            case .zero:
                return "\(pair): correlation 0.00, no measured linear relationship in the displayed sample; not proof of independence."
            case .undefined:
                return "\(pair): correlation undefined; the coefficient could not be computed from the shared overlapping sample."
            }
        }
    }

    struct Presentation: Equatable {
        static let invalidMessage = "The last-computed correlation matrix has invalid dimensions or values, so no coefficients are shown."
        static let caveat = "Last-computed pairwise correlation of daily returns over the shared overlapping history. Positive values show same-direction sample co-movement; negative values show opposite-direction sample co-movement; zero means no measured linear relationship in this sample; — means undefined. Small samples and regime changes limit reliability. None establishes independence, a reliable hedge, or future behavior."

        let symbols: [String]
        let rows: [[Cell]]
        let cluster: CorrelationCluster?

        init?(_ source: CorrelationMatrix) {
            let count = source.symbols.count
            let legacyMask = source.defined.isEmpty
            guard count >= 2,
                  source.symbols.allSatisfy({ !$0.isEmpty }),
                  Set(source.symbols).count == count,
                  source.matrix.count == count,
                  source.matrix.allSatisfy({ $0.count == count }),
                  source.matrix.allSatisfy({ row in
                      row.allSatisfy { $0.isFinite && (-1...1).contains($0) }
                  }),
                  legacyMask || (source.defined.count == count
                      && source.defined.allSatisfy({ $0.count == count })) else { return nil }

            if !legacyMask {
                guard source.defined.indices.allSatisfy({ source.defined[$0][$0] }) else { return nil }
            }
            guard source.matrix.indices.allSatisfy({ source.matrix[$0][$0] == 1 }) else { return nil }
            for row in 0..<count {
                for column in (row + 1)..<count {
                    guard source.matrix[row][column] == source.matrix[column][row] else { return nil }
                    if !legacyMask {
                        guard source.defined[row][column] == source.defined[column][row],
                              source.defined[row][column] || source.matrix[row][column] == 0 else { return nil }
                    }
                }
            }

            symbols = source.symbols
            rows = source.symbols.indices.map { row in
                source.symbols.indices.map { column in
                    let defined = legacyMask || source.defined[row][column]
                    let value = source.matrix[row][column]
                    let state: Cell.State = if row == column {
                        .selfComparison
                    } else if !defined {
                        .undefined
                    } else if value > 0 {
                        .positive
                    } else if value < 0 {
                        .negative
                    } else {
                        .zero
                    }
                    return Cell(row: row, column: column,
                                rowSymbol: source.symbols[row], columnSymbol: source.symbols[column],
                                value: defined ? value : nil, state: state)
                }
            }
            cluster = StockSageCorrelationCluster.largest(source)
        }

        var clusterMessage: String? {
            guard let cluster else { return nil }
            let threshold = String(format: "%+.2f", StockSageCorrelationCluster.threshold)
            let weakest = String(format: "%+.2f", cluster.minPairwise)
            return "Sample concentration flag: \(cluster.symbols.joined(separator: ", ")) — every pair was at or above \(threshold); weakest displayed pair \(weakest). This describes the last-computed sample only; future co-movement can change."
        }
    }

    @ScaledMetric(relativeTo: .caption) private var cellWidth: CGFloat = 52
    @ScaledMetric(relativeTo: .caption) private var cellHeight: CGFloat = 30
    @ScaledMetric(relativeTo: .caption) private var headerHeight: CGFloat = 28

    private let presentation: Presentation?

    init(matrix: CorrelationMatrix) {
        presentation = Self.presentation(for: matrix)
    }

    static func presentation(for matrix: CorrelationMatrix) -> Presentation? {
        Presentation(matrix)
    }

    @ViewBuilder var body: some View {
        if let presentation {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("Signed sample values: + together · − opposite · 0 no measured linear relationship · — undefined")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    wideMatrix(presentation)
                        .fixedSize(horizontal: true, vertical: false)
                    narrowMatrix(presentation)
                }

                if let warning = presentation.clusterMessage {
                    HStack(alignment: .top, spacing: DS.Space.xxs) {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(DS.Palette.danger)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(DS.Palette.dangerSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(Presentation.caveat)
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Last-computed correlation matrix, \(presentation.symbols.count) symbols")
        } else {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Label("Correlation unavailable", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(DS.Palette.warningSoft)
                Text(Presentation.invalidMessage)
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func wideMatrix(_ presentation: Presentation) -> some View {
        HStack(alignment: .top, spacing: DS.Space.xs) {
            rowHeaders(presentation)
            valueGrid(presentation)
        }
    }

    private func narrowMatrix(_ presentation: Presentation) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Label("Scroll columns to compare every symbol", systemImage: "arrow.left.and.right")
                .font(.caption2)
                .foregroundStyle(DS.Palette.textSecondary)
            HStack(alignment: .top, spacing: DS.Space.xs) {
                rowHeaders(presentation)
                ScrollView(.horizontal) {
                    valueGrid(presentation)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.visible, axes: .horizontal)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func rowHeaders(_ presentation: Presentation) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: DS.Space.xxs) {
            GridRow {
                Text("Row")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(height: headerHeight)
            }
            ForEach(presentation.symbols.indices, id: \.self) { row in
                GridRow {
                    Text(presentation.symbols[row])
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: cellHeight)
                        .accessibilityLabel("Row \(presentation.symbols[row])")
                }
            }
        }
    }

    private func valueGrid(_ presentation: Presentation) -> some View {
        Grid(alignment: .center, horizontalSpacing: DS.Space.xxs, verticalSpacing: DS.Space.xxs) {
            GridRow {
                ForEach(presentation.symbols.indices, id: \.self) { column in
                    Text(presentation.symbols[column])
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: cellWidth)
                        .frame(height: headerHeight)
                        .accessibilityLabel("Column \(presentation.symbols[column])")
                }
            }
            ForEach(presentation.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(presentation.rows[row]) { cell in
                        correlationCell(cell)
                    }
                }
            }
        }
    }

    private func correlationCell(_ cell: Cell) -> some View {
        return RoundedRectangle(cornerRadius: DS.Radius.well, style: .continuous)
            .fill(cell.fill)
            .frame(minWidth: cellWidth)
            .frame(height: cellHeight)
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.well, style: .continuous)
                    .stroke(cell.state == .undefined ? DS.Palette.textSecondary : DS.Palette.surfaceStroke,
                            style: StrokeStyle(lineWidth: 1,
                                               dash: cell.state == .undefined ? [3, 2] : []))
            }
            .overlay {
                Text(cell.displayValue)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(cell.state == .undefined
                        ? DS.Palette.textSecondary : DS.Palette.textPrimary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cell.accessibilityLabel)
    }
}
