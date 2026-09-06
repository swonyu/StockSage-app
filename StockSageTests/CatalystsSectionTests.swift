import Testing
import SwiftUI
@testable import StockSage

// Pure-helper pins for the catalysts tab view (owner request 2026-09-06, build step
// C3-view). Everything else in CatalystsSection needs a running app (it renders
// StockSageIdea/StockSageStore state); these three are the only parts pulled out as
// `nonisolated static func`/plain values specifically so they're checkable here.

@Suite("CatalystsSection — pure view helpers")
struct CatalystsSectionTests {

    @Test("one icon per catalyst Kind — all six cases")
    func iconPerKind() {
        #expect(CatalystsSection.iconName(for: .earnings) == "calendar.badge.exclamationmark")
        #expect(CatalystsSection.iconName(for: .volumeMove) == "bolt.horizontal.circle.fill")
        #expect(CatalystsSection.iconName(for: .extreme) == "arrow.up.right.circle")
        #expect(CatalystsSection.iconName(for: .regime) == "gauge.with.needle")
        #expect(CatalystsSection.iconName(for: .seasonality) == "calendar")
        #expect(CatalystsSection.iconName(for: .none) == "questionmark.circle")
    }

    @Test("action capsule fill matches the DS palette token per action")
    func actionFillMatchesPalette() {
        #expect(CatalystsSection.actionFill(for: .buy) == DS.Palette.successSoft)
        #expect(CatalystsSection.actionFill(for: .strongBuy) == DS.Palette.successSoft)
        #expect(CatalystsSection.actionFill(for: .hold) == DS.Palette.warningSoft)
        #expect(CatalystsSection.actionFill(for: .avoid) == Color.white.opacity(0.22))
        #expect(CatalystsSection.actionFill(for: .reduce) == DS.Palette.dangerSoft)
        #expect(CatalystsSection.actionFill(for: .sell) == DS.Palette.dangerSoft)
        // The gate must actually distinguish avoid from the two pastel tones it sits between.
        #expect(CatalystsSection.actionFill(for: .avoid) != DS.Palette.warningSoft)
    }

    @Test("Mode titles are Cards / Calendar, in that order")
    func modeTitles() {
        #expect(CatalystsSection.Mode.allCases.map(\.title) == ["Cards", "Calendar"])
    }
}
