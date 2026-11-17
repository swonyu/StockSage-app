import Testing
import Foundation
@testable import StockSage

// MARK: - cardIsStale per-card staleness predicate (POST2420-COPY item 1, 2026-07-08;
// extended for `priceAsOf` by the round-3 honesty hunt, same date)
//
// Pins MarketsView.cardIsStale(generatedAt:now:priceAsOf:) = generatedAt-stale (>4h old) OR
// priceAsOf-stale (not the same UTC calendar day as `now`, via StockSageScanChunking.utcDayKey).
// Every value below was HAND-DERIVED in a standalone script (scratchpad derive_cardisstale.swift
// for the generatedAt cases; scratchpad derive_priceasof.swift — reimplements the utcDayKey
// formula from its own doc comment, does NOT call the code under test — for the priceAsOf
// cases), not by calling this code — printed output pasted next to each assertion.

struct MarketsCardIsStaleTests {
    typealias M = MarketsView
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func straddlesTheFourHourBoundary() {
        // 3h59m elapsed: 14340.0s < 14400s (4h) -> NOT stale
        let threeH59m = Self.now.addingTimeInterval(-(3 * 3600 + 59 * 60))
        #expect(M.cardIsStale(generatedAt: threeH59m, now: Self.now) == false)

        // exactly 4h elapsed: 14400.0s -> strict '>' means the boundary itself is NOT stale
        let exactly4h = Self.now.addingTimeInterval(-(4 * 3600))
        #expect(M.cardIsStale(generatedAt: exactly4h, now: Self.now) == false)

        // 4h01m elapsed: 14460.0s > 14400s -> stale
        let fourH01m = Self.now.addingTimeInterval(-(4 * 3600 + 1 * 60))
        #expect(M.cardIsStale(generatedAt: fourH01m, now: Self.now) == true)
    }

    @Test func nilGeneratedAtIsNeverStale() {
        // No generatedAt (older/test-built ideas) -> can't judge -> not stale, never a false badge.
        #expect(M.cardIsStale(generatedAt: nil, now: Self.now) == false)
    }

    @Test func veryOldAndVeryFreshAreUnambiguous() {
        // 1 minute old -> nowhere near stale.
        #expect(M.cardIsStale(generatedAt: Self.now.addingTimeInterval(-60), now: Self.now) == false)
        // 24h old -> well past the 4h bar.
        #expect(M.cardIsStale(generatedAt: Self.now.addingTimeInterval(-24 * 3600), now: Self.now) == true)
    }

    // MARK: priceAsOf axis (derive_priceasof.swift: now dayKey == 11; a same-UTC-day priceAsOf
    // 1h earlier also dayKey 11 == not stale via this axis; 5-days-back priceAsOf dayKey == 6,
    // != 11 -> stale via this axis)

    @Test func todayLivePriceAsOfIsNotStaleViaThatAxis() {
        // Fresh generatedAt (1 minute old) so ONLY the priceAsOf axis is under test.
        let freshGeneratedAt = Self.now.addingTimeInterval(-60)
        // Same UTC day as `now` (1h earlier) -> priceAsOf axis says not stale.
        let todayAsOf = Self.now.addingTimeInterval(-3600)
        #expect(M.cardIsStale(generatedAt: freshGeneratedAt, now: Self.now, priceAsOf: todayAsOf) == false)
    }

    @Test func severalDaysOldPriceAsOfIsStaleEvenWithFreshGeneratedAt() {
        // Fresh generatedAt (1 minute old) — the analysis-time axis alone would say NOT stale —
        // but a 5-day-old price bar (cache-served on a weekend/offline) must still flag stale via
        // the priceAsOf axis (dayKey 6 vs now's dayKey 11 — genuinely different UTC days).
        let freshGeneratedAt = Self.now.addingTimeInterval(-60)
        let staleAsOf = Self.now.addingTimeInterval(-5 * 24 * 3600)
        #expect(M.cardIsStale(generatedAt: freshGeneratedAt, now: Self.now, priceAsOf: staleAsOf) == true)
    }

    @Test func nilPriceAsOfIsNeverStaleViaThatAxis() {
        // Fresh generatedAt + nil priceAsOf (older/test-built ideas without a history) -> the
        // priceAsOf axis can't judge -> must NOT falsely flag stale (honesty-floor: unknown
        // renders nothing, never a false badge). Overall result driven purely by generatedAt.
        let freshGeneratedAt = Self.now.addingTimeInterval(-60)
        #expect(M.cardIsStale(generatedAt: freshGeneratedAt, now: Self.now, priceAsOf: nil) == false)

        // And the default parameter (omitted entirely) must behave identically to nil.
        #expect(M.cardIsStale(generatedAt: freshGeneratedAt, now: Self.now) == false)
    }

    @Test func staleGeneratedAtStillStalesEvenWithLivePriceAsOf() {
        // Old generatedAt (24h) with a today priceAsOf: the generatedAt axis alone must still
        // flag stale (the extension is additive — EITHER axis firing stales the card).
        let staleGeneratedAt = Self.now.addingTimeInterval(-24 * 3600)
        let todayAsOf = Self.now.addingTimeInterval(-3600)
        #expect(M.cardIsStale(generatedAt: staleGeneratedAt, now: Self.now, priceAsOf: todayAsOf) == true)
    }
}
