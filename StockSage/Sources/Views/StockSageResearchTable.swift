#if os(macOS)
import AppKit
import SwiftUI

/// Owns row sizing so research updates do not enter SwiftUI's automatic-height insert path.
@MainActor
struct StockSageResearchTable: NSViewRepresentable {
    typealias Listing = StockSageHorizonResearch.Listing
    let rows: [Listing]
    @Binding var selection: String?
    let content: (Listing, Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.autoresizingMask = [.width]
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        // ponytail: current two-line cells fit 48 points; measure owned row heights if richer cells need more.
        table.rowHeight = 48
        table.intercellSpacing.height = 0
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        // User-set column widths are preserved across refits (see ScrollView.fitColumns),
        // so AppKit's own uniform autoresizing must not redistribute them behind our back.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        // ponytail: .inset style defaults to 17pt horizontal gutters. Six columns turned that
        // into 102pt of overhead, which pushed the six minimum widths (525pt) past the ~599pt
        // research pane and forced a horizontal scroller even with the inspector closed.
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.setAccessibilityLabel("Research results")
        table.setAccessibilityIdentifier("research.results.table")
        let specifications: [(String, CGFloat, CGFloat, CGFloat)] = [
            ("Stock", 80, 160, 300), ("Opinion", 90, 120, 200),
            ("Evidence", 95, 130, 180), ("Buy entry / close", 130, 145, 210),
            ("Stop", 65, 85, 110), ("Target", 65, 85, 110)
        ]
        for (index, spec) in specifications.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = spec.0
            column.minWidth = spec.1
            column.maxWidth = spec.3
            column.width = spec.2
            column.resizingMask = [.autoresizingMask, .userResizingMask]
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let scroll = ScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 672, height: 200))
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.update(self, table: table, scroll: scroll)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var parent: StockSageResearchTable
        private var rows: [Listing] = []
        private var isUpdating = false
        init(_ parent: StockSageResearchTable) { self.parent = parent }

        /// Records every column the user (or a caller) resizes so later refits leave it alone.
        /// `fitColumns` itself is excluded: its own adjustments must not latch a column as pinned.
        /// The table posts this notification on the main thread, and NSTableView's own delegate
        /// callback keeps the work inside the main actor without sending the notification across it.
        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table = notification.object as? NSTableView,
                  let scroll = table.enclosingScrollView as? ScrollView,
                  !scroll.isFitting,
                  let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn
            else { return }
            scroll.pin(column)
        }

        func update(_ value: StockSageResearchTable, table: NSTableView, scroll: NSScrollView) {
            isUpdating = true
            defer { isUpdating = false }
            let changed = rows != value.rows
            let origin = scroll.contentView.bounds.origin
            parent = value
            rows = value.rows
            if changed { table.reloadData() }
            // A refreshed closure can contain new evidence even when the listings are unchanged.
            table.enumerateAvailableRowViews { rowView, row in
                guard self.rows.indices.contains(row) else { return }
                for column in 0..<table.numberOfColumns {
                    guard let contentColumn = Int(table.tableColumns[column].identifier.rawValue) else { continue }
                    (rowView.view(atColumn: column) as? Cell)?.update(self.parent.content(self.rows[row], contentColumn))
                }
            }
            let selected = rows.firstIndex { $0.ticker == value.selection }
            let indexes = selected.map { IndexSet(integer: $0) } ?? IndexSet()
            if table.selectedRowIndexes != indexes {
                table.selectRowIndexes(indexes, byExtendingSelection: false)
            }
            if changed {
                var bounds = scroll.contentView.bounds
                bounds.origin = origin
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                // Incoming rows can change the scroller's presence and therefore the usable
                // width; re-fit so unpinned columns adapt while user widths stay exact.
                (scroll as? ScrollView)?.refit()
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            rows.indices.contains(row) ? rows[row].ticker : nil
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let identifier = tableColumn?.identifier,
                  let column = Int(identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? Cell ?? Cell()
            cell.identifier = identifier
            cell.update(parent.content(rows[row], column))
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table = notification.object as? NSTableView else { return }
            let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].ticker : nil
            if parent.selection != selected { parent.selection = selected }
        }
    }

    final class ScrollView: NSScrollView {
        private var fittedWidth: CGFloat = 0
        /// True while `fitColumns` is assigning widths, so its own resize notifications
        /// are not mistaken for a user drag.
        private(set) var isFitting = false
        /// Column identifiers the user has explicitly resized. Their widths are authoritative
        /// and survive refits; AppKit's sizeToFit would otherwise redistribute them away.
        var pinned: Set<String> = []
        /// The unpinned proportions to lay out against, captured once from the designed widths.
        /// Re-deriving these from the *current* widths on every pass would compound each
        /// pass's rounding, so a second refit at the same width could drift the layout.
        private var baseline: [String: CGFloat] = [:]

        override func layout() {
            super.layout()
            let width = contentView.bounds.width
            guard width > 0, width != fittedWidth, let table = documentView as? NSTableView else { return }
            fittedWidth = width
            fitColumns(table, available: width)
        }

        /// Re-fits columns after a data change without requiring a width change.
        func refit() {
            let width = contentView.bounds.width
            guard width > 0, let table = documentView as? NSTableView else { return }
            fitColumns(table, available: width)
        }

        /// Marks a column as user-owned and records its chosen width as the new baseline,
        /// so the value stays authoritative even if the column is later unpinned.
        func pin(_ column: NSTableColumn) {
            pinned.insert(column.identifier.rawValue)
            baseline[column.identifier.rawValue] = column.width
        }

        /// Re-fits columns to the viewport while preserving every user-set width.
        /// Columns the user has not touched absorb the remaining space proportionally,
        /// each clamped to its own minimum and maximum.
        func fitColumns(_ table: NSTableView, available: CGFloat) {
            let columns = table.tableColumns
            guard !columns.isEmpty else { return }
            let overhead = table.intercellSpacing.width * CGFloat(columns.count)
            let content = available - overhead
            guard content > 0 else { return }
            let free = columns.filter { !pinned.contains($0.identifier.rawValue) }
            guard !free.isEmpty else { return }
            isFitting = true
            defer { isFitting = false }
            let pinnedWidth = columns
                .filter { pinned.contains($0.identifier.rawValue) }
                .reduce(CGFloat(0)) { $0 + $1.width }
            // Capture the designed proportions once so repeated refits at the same width are
            // idempotent; without this, each pass reseeds from its own rounded output and drifts.
            for column in columns where baseline[column.identifier.rawValue] == nil {
                baseline[column.identifier.rawValue] = column.width
            }
            // Never ask the free columns for more or less than they can express.
            let floor = free.reduce(CGFloat(0)) { $0 + $1.minWidth }
            let ceiling = free.reduce(CGFloat(0)) { $0 + $1.maxWidth }
            let budget = max(floor, min(ceiling, content - pinnedWidth))
            let current = free.reduce(CGFloat(0)) { $0 + (baseline[$1.identifier.rawValue] ?? $1.width) }
            var widths = free.map { column -> CGFloat in
                let seed = baseline[column.identifier.rawValue] ?? column.width
                let share = current > 0 ? seed / current : 1 / CGFloat(free.count)
                return min(column.maxWidth, max(column.minWidth, (budget * share).rounded(.down)))
            }
            // Rounding and clamping leave a remainder; hand it to whichever columns still have room.
            var slack = budget - widths.reduce(0, +)
            var passes = 0
            while abs(slack) >= 0.5, passes < 64 {
                passes += 1
                var moved: CGFloat = 0
                for index in free.indices where abs(slack) >= 0.5 {
                    let column = free[index]
                    let room = slack > 0 ? column.maxWidth - widths[index] : column.minWidth - widths[index]
                    guard room != 0 else { continue }
                    let step = slack > 0 ? min(room, slack) : max(room, slack)
                    widths[index] += step
                    slack -= step
                    moved += abs(step)
                }
                if moved == 0 { break }
            }
            for (index, column) in free.enumerated() where column.width != widths[index] {
                column.width = widths[index]
            }
            // AppKit's .inset style adds horizontal padding that plain column arithmetic cannot
            // see, so verify against the table's own geometry and give back any real excess.
            // Measuring beats predicting: this holds whatever insets the style applies.
            var correction = 0
            while correction < 8 {
                correction += 1
                let last = table.rect(ofColumn: columns.count - 1).maxX
                let excess = last - available
                guard excess > 0.5 else { break }
                var remaining = excess
                var shrank = false
                for (index, column) in free.enumerated().reversed() where remaining > 0.5 {
                    let room = column.width - column.minWidth
                    guard room > 0.5 else { continue }
                    let step = min(room, remaining)
                    column.width -= step
                    widths[index] = column.width
                    remaining -= step
                    shrank = true
                }
                if !shrank { break }
            }
        }
    }

    private final class Cell: NSTableCellView {
        private let host = NSHostingView(rootView: AnyView(EmptyView()))
        init() {
            super.init(frame: .zero)
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        required init?(coder: NSCoder) { return nil }
        func update(_ content: AnyView) {
            host.rootView = AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
        }
    }
}
#endif
