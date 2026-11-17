import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// Numeric keyboards have no Return key. Every personal-record form keeps
    /// a visible native Done action in addition to interactive scroll dismissal.
    @ViewBuilder func personalRecordKeyboard() -> some View {
        #if os(iOS)
        self.scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil)
                    }
                    .accessibilityIdentifier("personalInput.done")
                }
            }
        #else
        self
        #endif
    }
}
