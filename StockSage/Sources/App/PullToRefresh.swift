#if os(iOS)
import SwiftUI
import Combine

// MARK: - Pull-to-Refresh Extension (iOS enhancement, 2026-07-27)
//
// Adds native iOS pull-to-refresh gesture to any scrollable view with proper
// haptic feedback and loading states. Integrates with StockSageStore's refresh
// mechanism for manual quote updates.

extension View {
    /// Adds pull-to-refresh with haptic feedback and loading indicator
    /// Usage: `.pullToRefresh { await doRefresh() }`
    @ViewBuilder
    func pullToRefresh(action: @escaping () async -> Void) -> some View {
        #if os(iOS)
        self.refreshable {
            HapticFeedback.trigger(.light)
            await action()
            HapticFeedback.trigger(.success)
        }
        #else
        self
        #endif
    }
}

// MARK: - Manual Refresh Button
/// A reusable refresh button component that works on both iOS and macOS
/// Includes proper loading state, accessibility, and haptic feedback
struct RefreshButton: View {
    let action: () async -> Void
    @State private var isRefreshing = false
    
    var body: some View {
        Button {
            Task {
                guard !isRefreshing else { return }
                #if os(iOS)
                HapticFeedback.trigger(.light)
                #endif
                isRefreshing = true
                await action()
                isRefreshing = false
                #if os(iOS)
                HapticFeedback.trigger(.success)
                #endif
            }
        } label: {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(isRefreshing)
        .accessibilityLabel("Refresh prices")
        .accessibilityHint("Updates all stock prices from the market")
        .help("Refresh prices")
    }
}

// MARK: - Pull-to-Refresh Indicator
/// Custom pull-to-refresh indicator that matches the app's design system
/// Shows during refresh with accent color animation
struct RefreshIndicator: View {
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DS.Palette.accent)
                .frame(width: 8, height: 8)
                .scaleEffect(isAnimating ? 1.2 : 0.8)
                .animation(
                    .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                    value: isAnimating
                )
            
            Circle()
                .fill(DS.Palette.accent.opacity(0.7))
                .frame(width: 8, height: 8)
                .scaleEffect(isAnimating ? 1.2 : 0.8)
                .animation(
                    .easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(0.2),
                    value: isAnimating
                )
            
            Circle()
                .fill(DS.Palette.accent.opacity(0.5))
                .frame(width: 8, height: 8)
                .scaleEffect(isAnimating ? 1.2 : 0.8)
                .animation(
                    .easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(0.4),
                    value: isAnimating
                )
        }
        .padding(.vertical, 8)
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Refresh State Manager
/// Centralized refresh state manager for coordinating UI updates across views
@MainActor
final class RefreshStateManager: ObservableObject {
    static let shared = RefreshStateManager()
    
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var refreshError: String?
    
    private init() {}
    
    /// Performs a refresh with proper state management
    func performRefresh(_ action: () async throws -> Void) async {
        guard !isRefreshing else { return }
        
        isRefreshing = true
        refreshError = nil
        
        do {
            try await action()
            lastRefreshDate = .now
            #if os(iOS)
            HapticFeedback.trigger(.success)
            #endif
        } catch {
            refreshError = error.localizedDescription
            #if os(iOS)
            HapticFeedback.trigger(.error)
            #endif
        }
        
        isRefreshing = false
    }
    
    /// Returns a human-readable "last updated" string
    var lastRefreshText: String? {
        guard let date = lastRefreshDate else { return nil }
        
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: date, relativeTo: .now))"
    }
}

// MARK: - Refresh Status Bar
/// Shows refresh status with last update time and error messages
struct RefreshStatusBar: View {
    @ObservedObject var manager = RefreshStateManager.shared
    
    var body: some View {
        HStack(spacing: 8) {
            if manager.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text("Updating prices...")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            } else if let error = manager.refreshError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Palette.dangerSoft)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(DS.Palette.dangerSoft)
                    .lineLimit(1)
            } else if let lastUpdate = manager.lastRefreshText {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DS.Palette.successSoft)
                Text(lastUpdate)
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(DS.Palette.surface, in: Capsule())
        .transition(.scale.combined(with: .opacity))
    }
}

#Preview {
    VStack(spacing: 20) {
        RefreshButton {
            try? await Task.sleep(for: .seconds(2))
        }
        
        RefreshIndicator()
        
        RefreshStatusBar()
    }
    .padding()
    .background(DS.Gradient.bg)
}
#endif
