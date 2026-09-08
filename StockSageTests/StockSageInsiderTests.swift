import Testing
import Foundation
@testable import StockSage

// SEC Form 4 insider parsing. The fixtures below use the REAL element shapes observed in a live
// AAPL filing (accession 0001140361-26-025622), not invented markup.

@Suite("Insider transactions (SEC Form 4)")
struct StockSageInsiderTests {

    typealias I = StockSageInsider

    /// The exact structure that motivated this design: an officer "disposing" 16,238 shares where
    /// the codes are M (option exercise) and F (tax withholding). Nothing here is a decision.
    private let mechanicalFiling = """
    <ownershipDocument>
      <issuer><issuerTradingSymbol>AAPL</issuerTradingSymbol></issuer>
      <reportingOwner><reportingOwnerId><rptOwnerName>Newstead Jennifer</rptOwnerName></reportingOwnerId>
        <reportingOwnerRelationship><isOfficer>true</isOfficer>
        <officerTitle>SVP, GC and Secretary</officerTitle></reportingOwnerRelationship></reportingOwner>
      <nonDerivativeTable>
        <nonDerivativeTransaction>
          <transactionCoding><transactionCode>M</transactionCode></transactionCoding>
          <transactionAmounts><transactionShares><value>30104</value></transactionShares>
          <transactionAcquiredDisposedCode><value>A</value></transactionAcquiredDisposedCode></transactionAmounts>
        </nonDerivativeTransaction>
        <nonDerivativeTransaction>
          <transactionCoding><transactionCode>F</transactionCode></transactionCoding>
          <transactionAmounts><transactionShares><value>16238</value></transactionShares>
          <transactionPricePerShare><value>296.42</value></transactionPricePerShare>
          <transactionAcquiredDisposedCode><value>D</value></transactionAcquiredDisposedCode></transactionAmounts>
        </nonDerivativeTransaction>
      </nonDerivativeTable>
    </ownershipDocument>
    """

    private let purchaseFiling = """
    <ownershipDocument>
      <issuer><issuerTradingSymbol>NVDA</issuerTradingSymbol></issuer>
      <reportingOwner><reportingOwnerId><rptOwnerName>Doe John</rptOwnerName></reportingOwnerId>
        <reportingOwnerRelationship><officerTitle>Director</officerTitle></reportingOwnerRelationship></reportingOwner>
      <nonDerivativeTable>
        <nonDerivativeTransaction>
          <transactionCoding><transactionCode>P</transactionCode></transactionCoding>
          <transactionAmounts><transactionShares><value>5000</value></transactionShares>
          <transactionPricePerShare><value>196.51</value></transactionPricePerShare>
          <transactionAcquiredDisposedCode><value>A</value></transactionAcquiredDisposedCode></transactionAmounts>
        </nonDerivativeTransaction>
      </nonDerivativeTable>
    </ownershipDocument>
    """

    // MARK: the core honesty rule

    @Test("tax withholding and option exercises are NEVER shown as insider selling")
    func mechanicalActivityIsExcluded() throws {
        // This is the whole point. A naive parser reports "SVP disposed 16,238 shares" — bearish
        // sounding, and false. The insider exercised options and the company withheld shares for
        // tax. No decision was made.
        let s = try #require(I.parseForm4(mechanicalFiling))
        #expect(s.symbol == "AAPL")
        #expect(s.discretionary.isEmpty, "M and F are not market decisions")
        #expect(s.nonDiscretionaryCount == 2, "but their existence must still be reported")
        #expect(!s.isEmpty, "'activity, none discretionary' differs from 'no activity'")
        #expect(s.netBuyValue == nil)
    }

    @Test("an open-market purchase is surfaced with its full detail")
    func openMarketPurchaseSurfaces() throws {
        let s = try #require(I.parseForm4(purchaseFiling))
        let t = try #require(s.discretionary.first)
        #expect(s.discretionary.count == 1)
        #expect(t.code == .openMarketPurchase)
        #expect(t.acquired)
        #expect(t.shares == 5000)
        #expect(t.pricePerShare == 196.51)
        // 5000 x 196.51 = 982,550 exactly
        #expect(abs((t.dollarValue ?? 0) - 982_550) < 1e-6)
        #expect(abs((s.netBuyValue ?? 0) - 982_550) < 1e-6)
        #expect(t.officerTitle == "Director")
    }

    // MARK: code classification

    @Test("only P and S count as discretionary")
    func codeClassification() {
        #expect(I.Code(rawCode: "P").isDiscretionary)
        #expect(I.Code(rawCode: "S").isDiscretionary)
        for mechanical in ["M", "F", "A", "G"] {
            #expect(!I.Code(rawCode: mechanical).isDiscretionary, "\(mechanical) is not a decision")
        }
        #expect(I.Code(rawCode: "p") == .openMarketPurchase)     // case-insensitive
        #expect(I.Code(rawCode: " S ") == .openMarketSale)       // whitespace-tolerant
        #expect(I.Code(rawCode: "ZZ") == .other)                 // unknown never guesses
        #expect(!I.Code(rawCode: "ZZ").isDiscretionary)
    }

    // MARK: guards

    @Test("a sale nets NEGATIVE against a purchase")
    func salesNetNegative() throws {
        let sale = purchaseFiling
            .replacingOccurrences(of: "<transactionCode>P</transactionCode>",
                                  with: "<transactionCode>S</transactionCode>")
            .replacingOccurrences(of: "<value>A</value>", with: "<value>D</value>")
        let s = try #require(I.parseForm4(sale))
        #expect(s.discretionary.first?.code == .openMarketSale)
        #expect(abs((s.netBuyValue ?? 0) + 982_550) < 1e-6, "a sale must subtract, not add")
    }

    @Test("non-Form-4 and malformed input return nil rather than a fabricated summary")
    func malformedReturnsNil() {
        #expect(I.parseForm4("") == nil)
        #expect(I.parseForm4("<html>not a filing</html>") == nil)
        #expect(I.parseForm4("<ownershipDocument></ownershipDocument>") == nil)   // no symbol
    }

    @Test("merging filings keeps every discretionary row and the excluded count")
    func mergeIsAdditive() throws {
        let a = try #require(I.parseForm4(purchaseFiling))
        let b = try #require(I.parseForm4(mechanicalFiling))
        let m = I.merge([a, b], symbol: "NVDA")
        #expect(m.discretionary.count == 1)
        #expect(m.nonDiscretionaryCount == 2)
    }

    @Test("the caveat states both the legality and the lack of validation")
    func caveatIsHonest() {
        #expect(I.caveat.contains("public"))
        #expect(I.caveat.contains("UNVALIDATED"))
        #expect(I.caveat.lowercased().contains("tax withholding"))
    }

    // MARK: transactionDate parsing (W4 — insider items need a date to be citable)

    @Test("a discretionary transaction carries its parsed transactionDate")
    func transactionDateParses() throws {
        // transactionDate sits at the transaction level in SEC's real schema, alongside
        // transactionCoding — inserted there, not inside transactionAmounts.
        let withDate = purchaseFiling.replacingOccurrences(
            of: "<transactionCoding><transactionCode>P</transactionCode></transactionCoding>",
            with: "<transactionCoding><transactionCode>P</transactionCode></transactionCoding>"
                + "<transactionDate><value>2026-08-15</value></transactionDate>")
        let s = try #require(I.parseForm4(withDate))
        let t = try #require(s.discretionary.first)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expected = utc.date(from: DateComponents(year: 2026, month: 8, day: 15))
        #expect(t.date == expected)
    }

    @Test("a transaction with no transactionDate in the filing carries a nil date — never fabricated")
    func transactionDateNilWhenAbsent() throws {
        let s = try #require(I.parseForm4(purchaseFiling))
        let t = try #require(s.discretionary.first)
        #expect(t.date == nil)
    }

    @Test("missing transaction fields never borrow values from the next row",
          arguments: ["price", "date", "flag", "shares", "code", "mechanical"])
    func missingFieldsStayWithTheirTransaction(_ missing: String) throws {
        let code = missing == "mechanical" ? "M" : "P"
        let first = """
        <nonDerivativeTransaction>
          \(missing == "code" ? "" : "<transactionCoding><transactionCode>\(code)</transactionCode></transactionCoding>")
          \(missing == "date" ? "" : "<transactionDate><value>2026-08-14</value></transactionDate>")
          <transactionAmounts>
            \(missing == "shares" ? "" : "<transactionShares><value>100</value></transactionShares>")
            \(["price", "mechanical"].contains(missing) ? "" : "<transactionPricePerShare><value>10</value></transactionPricePerShare>")
            \(missing == "flag" ? "" : "<transactionAcquiredDisposedCode><value>A</value></transactionAcquiredDisposedCode>")
          </transactionAmounts>
        </nonDerivativeTransaction>
        """
        let xml = """
        <ownershipDocument><issuer><issuerTradingSymbol>NVDA</issuerTradingSymbol></issuer>
          <nonDerivativeTable>\(first)
            <nonDerivativeTransaction>
              <transactionCoding><transactionCode>S</transactionCode></transactionCoding>
              <transactionDate><value>2026-08-15</value></transactionDate>
              <transactionAmounts>
                <transactionShares><value>5000</value></transactionShares>
                <transactionPricePerShare><value>196.51</value></transactionPricePerShare>
                <transactionAcquiredDisposedCode><value>D</value></transactionAcquiredDisposedCode>
              </transactionAmounts>
            </nonDerivativeTransaction>
          </nonDerivativeTable>
        </ownershipDocument>
        """
        let summary = try #require(I.parseForm4(xml))
        let second = try #require(summary.discretionary.last)
        #expect(second.code == .openMarketSale)
        #expect(second.shares == 5000)
        #expect(second.pricePerShare == 196.51)
        #expect(!second.acquired)
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        #expect(second.date == day.date(from: "2026-08-15"))
        #expect(summary.nonDiscretionaryCount == (missing == "mechanical" ? 1 : 0))
        if ["shares", "code", "mechanical"].contains(missing) {
            #expect(summary.discretionary.count == 1)
        } else {
            #expect(summary.discretionary.count == 2)
            let first = try #require(summary.discretionary.first)
            #expect(first.shares == 100)
            #expect(first.acquired)
            if missing == "price" {
                #expect(first.pricePerShare == nil)
                #expect(summary.netBuyValue == nil, "a partial subtotal is not the net of all trades")
            }
            if missing == "date" { #expect(first.date == nil) }
        }
    }

    @Test("derivative contracts do not masquerade as Table I share trades")
    func derivativeTransactionsAreNotShares() throws {
        let xml = purchaseFiling.replacingOccurrences(of: "nonDerivative", with: "derivative")
        let summary = try #require(I.parseForm4(xml))
        #expect(summary.discretionary.isEmpty)
        #expect(summary.netBuyValue == nil)
    }

    @Test("invalid prices stay unknown and invalid share quantities are dropped",
          arguments: ["NaN", "inf", "-1"])
    func invalidAmountsAreNotMoney(_ invalid: String) throws {
        let badPrice = try #require(I.parseForm4(purchaseFiling.replacingOccurrences(of: "196.51", with: invalid)))
        #expect(badPrice.discretionary.count == 1)
        #expect(badPrice.discretionary.first?.pricePerShare == nil)
        #expect(badPrice.netBuyValue == nil)
        let badShares = try #require(I.parseForm4(purchaseFiling.replacingOccurrences(of: "5000", with: invalid)))
        #expect(badShares.discretionary.isEmpty)
    }

    @Test("overflow cannot produce an infinite transaction or net dollar value")
    func overflowingValueIsUnknown() throws {
        let summary = try #require(I.parseForm4(purchaseFiling.replacingOccurrences(of: "196.51", with: "1e308")))
        #expect(summary.discretionary.first?.dollarValue == nil)
        #expect(summary.netBuyValue == nil)
    }

    @Test("zero price is known, but zero or unrenderable share quantities are not trades")
    func zeroPriceAndShareBounds() throws {
        let free = try #require(I.parseForm4(purchaseFiling.replacingOccurrences(of: "196.51", with: "0")))
        #expect(free.discretionary.first?.pricePerShare == 0)
        #expect(free.netBuyValue == 0)
        for qty in ["0", "1e308", String(Double(Int.max))] {
            let summary = try #require(I.parseForm4(purchaseFiling.replacingOccurrences(of: "5000", with: qty)))
            #expect(summary.discretionary.isEmpty)
        }
    }

    // MARK: ToolPolicy gating (W4 — this feed hit the network unconditionally before)

    // `NSLock.lock()`/`.unlock()` are `noasync` — calling them directly inside an `async` test
    // function is a Swift 6 error, so the acquire/release each go through a plain (non-async)
    // helper the async test calls into instead.
    private static func lockAndOverride(_ policy: ToolPolicy) -> ToolPolicy? {
        ToolPolicyTestLock.lock.lock()
        let prior = ToolPolicy.override
        ToolPolicy.override = policy
        return prior
    }

    private static func unlockAndRestore(_ prior: ToolPolicy?) {
        ToolPolicy.override = prior
        ToolPolicyTestLock.lock.unlock()
    }

    @Test("recentActivity returns nil immediately when external access is off — the gate is the FIRST line, before any network call")
    func recentActivityGatedByToolPolicy() async {
        let prior = Self.lockAndOverride(.localOnly)
        // No network mock exists (and tests must never hit the network) — this only proves the
        // gate fires: if it did NOT, this call would attempt a real SEC fetch and either hang past
        // the test timeout or return non-nil from a live response, neither of which this asserts.
        let result = await I.recentActivity(for: "AAPL")
        Self.unlockAndRestore(prior)
        #expect(result == nil)
    }
}
