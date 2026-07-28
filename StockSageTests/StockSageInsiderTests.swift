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
}
