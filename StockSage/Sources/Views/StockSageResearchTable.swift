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
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
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

    private final class ScrollView: NSScrollView {
        private var fittedWidth: CGFloat = 0
        override func layout() {
            super.layout()
            let width = contentView.bounds.width
            guard width > 0, width != fittedWidth, let table = documentView as? NSTableView else { return }
            fittedWidth = width
            table.sizeToFit()
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
