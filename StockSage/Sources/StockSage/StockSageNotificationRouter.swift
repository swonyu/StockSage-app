import Combine
import Foundation
import UserNotifications

/// A notification may open the app before SwiftUI has installed its listeners.
/// Keep the newest explicit tap until the workspace acknowledges that exact route.
@MainActor final class StockSageNotificationRouter: ObservableObject {
    static let shared = StockSageNotificationRouter()

    enum Destination: Equatable, Sendable { case research, symbol(String) }
    struct Route: Equatable, Identifiable, Sendable {
        let id = UUID()
        let destination: Destination
    }
    @Published private(set) var pending: Route?

    func receive(action: String, userInfo: [AnyHashable: Any]) {
        guard action == UNNotificationDefaultActionIdentifier else { return }
        if userInfo["stocksage.research.ready"] as? Bool == true {
            pending = Route(destination: .research)
        } else if let raw = userInfo["symbol"] as? String {
            let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !symbol.isEmpty, symbol.count <= 32 else { return }
            pending = Route(destination: .symbol(symbol))
        }
    }

    func acknowledge(_ id: UUID) {
        guard pending?.id == id else { return }
        pending = nil
    }
}
