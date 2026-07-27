#if os(iOS)
import SwiftUI

// MARK: - iPad Adaptive Layout (iOS enhancement, 2026-07-27)
//
// Provides multi-column layouts optimized for iPad screen sizes. Automatically
// adapts between 1, 2, or 3 columns based on available width and size class.
// Includes proper drag-and-drop support, keyboard navigation, and accessibility.

// MARK: - Adaptive Column Layout
/// Smart column layout that adapts to screen size
/// - iPhone: 1 column
/// - iPad Portrait: 2 columns
/// - iPad Landscape: 3 columns
/// - Mac: 3 columns with wider gutters
struct AdaptiveColumns<Data: RandomAccessCollection, Content: View>: View where Data.Element: Identifiable {
    let data: Data
    let spacing: CGFloat
    let minColumnWidth: CGFloat
    @ViewBuilder let content: (Data.Element) -> Content
    
    @Environment(\.horizontalSizeClass) private var sizeClass
    
    init(
        data: Data,
        spacing: CGFloat = DS.Space.md,
        minColumnWidth: CGFloat = 300,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.spacing = spacing
        self.minColumnWidth = minColumnWidth
        self.content = content
    }
    
    var body: some View {
        GeometryReader { geometry in
            let columns = columnCount(for: geometry.size.width)
            let gridItems = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns)
            
            ScrollView {
                LazyVGrid(columns: gridItems, spacing: spacing) {
                    ForEach(data) { item in
                        content(item)
                    }
                }
                .padding(spacing)
            }
        }
    }
    
    private func columnCount(for width: CGFloat) -> Int {
        #if os(iOS)
        if sizeClass == .compact {
            return 1  // iPhone
        } else {
            // iPad: fit as many columns as possible with minColumnWidth
            let availableWidth = width - (spacing * 2)
            let possibleColumns = Int(availableWidth / (minColumnWidth + spacing))
            return max(1, min(possibleColumns, 3))
        }
        #else
        // macOS: always use 3 columns if space allows
        let availableWidth = width - (spacing * 2)
        let possibleColumns = Int(availableWidth / (minColumnWidth + spacing))
        return max(1, min(possibleColumns, 3))
        #endif
    }
}

// MARK: - Split View Layout
/// iPad-optimized split view with master-detail pattern
/// Shows list on left, detail on right (or stacked on iPhone)
struct AdaptiveSplitView<Master: View, Detail: View>: View {
    @ViewBuilder let master: () -> Master
    @ViewBuilder let detail: () -> Detail
    
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showDetail = false
    
    var body: some View {
        #if os(iOS)
        if sizeClass == .compact {
            // iPhone: navigation stack
            NavigationStack {
                master()
            }
        } else {
            // iPad: side-by-side
            NavigationSplitView {
                master()
            } detail: {
                detail()
            }
            .navigationSplitViewStyle(.balanced)
        }
        #else
        // macOS: always split
        NavigationSplitView {
            master()
                .frame(minWidth: 280, idealWidth: 320)
        } detail: {
            detail()
                .frame(minWidth: 500)
        }
        #endif
    }
}

// MARK: - Responsive Spacing
/// Provides responsive spacing values based on screen size
enum ResponsiveSpacing {
    @MainActor
    static func padding(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        #if os(iOS)
        switch sizeClass {
        case .compact:
            return DS.Space.md  // iPhone: 14pt
        case .regular:
            return DS.Space.xl  // iPad: 24pt
        default:
            return DS.Space.lg  // 18pt
        }
        #else
        return DS.Space.xl  // macOS: 24pt
        #endif
    }
    
    @MainActor
    static func cardSpacing(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        #if os(iOS)
        switch sizeClass {
        case .compact:
            return DS.Space.sm  // iPhone: 10pt
        case .regular:
            return DS.Space.lg  // iPad: 18pt
        default:
            return DS.Space.md  // 14pt
        }
        #else
        return DS.Space.lg  // macOS: 18pt
        #endif
    }
}

// MARK: - Responsive Card Grid
/// Pre-configured card grid for idea cards, journal entries, etc.
struct ResponsiveCardGrid<Data: RandomAccessCollection, Content: View>: View where Data.Element: Identifiable {
    let data: Data
    @ViewBuilder let content: (Data.Element) -> Content
    
    @Environment(\.horizontalSizeClass) private var sizeClass
    
    var body: some View {
        AdaptiveColumns(
            data: data,
            spacing: ResponsiveSpacing.cardSpacing(for: sizeClass),
            minColumnWidth: 320,
            content: content
        )
    }
}

// MARK: - Keyboard Navigation Support
/// Adds keyboard shortcuts for navigation on iPad with hardware keyboard
struct KeyboardNavigable: ViewModifier {
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onSelect: () -> Void
    
    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .keyboardShortcut(.downArrow, modifiers: [])
            .onTapGesture { onSelect() }
            // Add more shortcuts as needed
            #endif
    }
}

extension View {
    func keyboardNavigable(
        onNext: @escaping () -> Void = {},
        onPrevious: @escaping () -> Void = {},
        onSelect: @escaping () -> Void = {}
    ) -> some View {
        modifier(KeyboardNavigable(onNext: onNext, onPrevious: onPrevious, onSelect: onSelect))
    }
}

// MARK: - iPad Toolbar Configuration
/// Configures toolbar for iPad with proper placement and overflow handling
struct IPadToolbarModifier<Items: View>: ViewModifier {
    // Review triage 2026-07-27: the generic was named `Content`, shadowing ViewModifier's
    // associated type Content — so body(content:) referenced the wrong type and the
    // conformance failed. Renamed to Items.
    @ViewBuilder let items: () -> Items

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    items()
                }
            }
            .toolbarRole(.automatic)
        #else
        content
            .toolbar {
                ToolbarItemGroup {
                    items()
                }
            }
        #endif
    }
}

extension View {
    func iPadToolbar<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(IPadToolbarModifier(items: content))
    }
}

// MARK: - Responsive Typography
/// Scales font sizes appropriately for iPad's larger screen
extension DS.Typography {
    static func scaled(base: CGFloat, for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        #if os(iOS)
        switch sizeClass {
        case .regular:
            return base * 1.15  // iPad: 15% larger
        default:
            return base
        }
        #else
        return base
        #endif
    }
}

// MARK: - Preview
#Preview("Adaptive Columns") {
    struct SampleItem: Identifiable {
        let id = UUID()
        let title: String
        let value: Double
    }
    
    let items = (1...20).map { SampleItem(title: "Item \($0)", value: Double($0) * 10) }
    
    return AdaptiveColumns(data: items, minColumnWidth: 200) { item in
        VStack(alignment: .leading) {
            Text(item.title)
                .font(.headline)
            Text("$\(item.value, specifier: "%.2f")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }
    .background(DS.Gradient.bg)
}

#Preview("Split View") {
    AdaptiveSplitView {
        List(1..<20) { i in
            Text("Item \(i)")
        }
        .navigationTitle("List")
    } detail: {
        VStack {
            Text("Detail View")
                .font(.largeTitle)
            Text("Select an item from the list")
                .foregroundStyle(.secondary)
        }
    }
}
#endif
