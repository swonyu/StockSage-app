import Foundation
import Testing
@testable import StockSage

@Suite("Explicit quote and record denomination")
struct StockSagePriceDenominationTests {
    @Test func providerMetadataPreventsLondonAndCryptoTickerInference() throws {
        let londonUSD = try #require(StockSagePriceDenomination.yahooMetadata(
            ["symbol": "CSPX.L", "currency": "USD"], requestedSymbol: "CSPX.L"))
        #expect(londonUSD.currencyCode == "USD")
        #expect(londonUSD.rawUnitsPerMajor == .major)
        #expect(londonUSD.majorValue(rawValue: 725) == 725)

        let euroPair = try #require(StockSagePriceDenomination.yahooMetadata(
            ["symbol": "BTC-EUR", "currency": "EUR"], requestedSymbol: "BTC-EUR"))
        #expect(euroPair.currencyCode == "EUR")
        #expect(euroPair.majorValue(rawValue: 73_000) == 73_000)
        #expect(StockSagePriceDenomination.yahooMetadata(
            ["symbol": "CSPX.L"], requestedSymbol: "CSPX.L") == nil)
        #expect(StockSagePriceDenomination.yahooMetadata(
            ["symbol": "BTC-EUR"], requestedSymbol: "BTC-EUR") == nil)
    }

    @Test func providerMinorUnitsPreserveCaseAndHaveKnownConversions() throws {
        for token in ["GBp", "GBX"] {
            let basis = try #require(StockSagePriceDenomination.yahooMetadata(
                ["symbol": "BP.L", "currency": token], requestedSymbol: "BP.L"))
            #expect(basis.currencyCode == "GBP" && basis.rawUnitsPerMajor == .hundredths)
            #expect(basis.majorValue(rawValue: 512.5) == 5.125)
        }
        let cents = try #require(StockSagePriceDenomination.yahooMetadata(
            ["symbol": "EXAMPLE.JO", "currency": "ZAc"], requestedSymbol: "EXAMPLE.JO"))
        #expect(cents.currencyCode == "ZAR" && cents.rawUnitsPerMajor == .hundredths)
        #expect(cents.majorValue(rawValue: 24_500) == 245)

        for currency in ["GBP", "ZAR"] {
            let major = try #require(StockSagePriceDenomination.yahooMetadata(
                ["symbol": "SYNTHETIC", "currency": currency], requestedSymbol: "SYNTHETIC"))
            #expect(major.rawUnitsPerMajor == .major && major.majorValue(rawValue: 512.5) == 512.5)
        }
        for ambiguous in ["gbp", "Gbp", "gbx", "GBx", "ZAC", "zac", "GBP "] {
            #expect(StockSagePriceDenomination.yahooMetadata(
                ["symbol": "SYNTHETIC", "currency": ambiguous], requestedSymbol: "SYNTHETIC") == nil)
        }
    }

    @Test func parserRequiresInstrumentBindingAndWellFormedFields() {
        let invalid: [[String: Any]?] = [nil, [:], ["currency": "USD"],
            ["symbol": "OTHER", "currency": "USD"], ["symbol": "AAPL", "currency": 840],
            ["symbol": "AAPL", "currency": NSNull()], ["symbol": " AAPL", "currency": "USD"],
            ["symbol": "AAPL", "currency": ""], ["symbol": "AAPL", "currency": "NOT-A-CURRENCY"]]
        for payload in invalid {
            #expect(StockSagePriceDenomination.yahooMetadata(payload, requestedSymbol: "AAPL") == nil)
        }
        #expect(StockSagePriceDenomination.yahooMetadata(
            ["symbol": "aapl", "currency": "USD"], requestedSymbol: "AAPL") != nil)
        #expect(StockSagePriceDenomination.yahooMetadata(
            ["symbol": "AAPL", "currency": "USD"], requestedSymbol: "AAPL ") == nil)
        #expect(StockSagePriceDenomination.yahooMetadata(
            ["symbol": "", "currency": "USD"], requestedSymbol: "") == nil)
    }

    @Test func directConstructionRequiresExplicitUsableCurrency() {
        for currency in ["USD", "EUR", "GBP", "SAR", "JPY", "KWD"] {
            #expect(StockSagePriceDenomination(currencyCode: currency,
                rawUnitsPerMajor: .major, provenance: .manualEntry) != nil)
        }
        for invalid in ["", "usd", "USD ", " USD", "USD\n", "GBp", "GBX", "ZAc", "XXX", "XTS", "840", "AAPL"] {
            #expect(StockSagePriceDenomination(currencyCode: invalid,
                rawUnitsPerMajor: .major, provenance: .manualEntry) == nil)
        }
    }

    @Test func conversionRejectsNonfiniteAndTrueUnderflowButRetainsFiniteSubnormals() throws {
        let major = try #require(StockSagePriceDenomination(currencyCode: "USD",
            rawUnitsPerMajor: .major, provenance: .manualEntry))
        let minor = try #require(StockSagePriceDenomination(currencyCode: "GBP",
            rawUnitsPerMajor: .hundredths, provenance: .manualEntry))
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(major.majorValue(rawValue: value) == nil)
            #expect(minor.majorValue(rawValue: value) == nil)
        }
        #expect(minor.majorValue(rawValue: Double.leastNonzeroMagnitude) == nil)
        #expect(minor.majorValue(rawValue: -Double.leastNonzeroMagnitude) == nil)
        #expect(major.majorValue(rawValue: Double.leastNonzeroMagnitude) == Double.leastNonzeroMagnitude)
        let representable = try #require(minor.majorValue(rawValue: Double.leastNormalMagnitude))
        #expect(representable > 0 && representable < Double.leastNormalMagnitude)
        #expect(major.majorValue(rawValue: Double.greatestFiniteMagnitude) == Double.greatestFiniteMagnitude)
        #expect(minor.majorValue(rawValue: Double.greatestFiniteMagnitude)?.isFinite == true)
        #expect(minor.majorValue(rawValue: 12_345) == 123.45)
        #expect(minor.majorValue(rawValue: -12_345) == -123.45)
        #expect(minor.majorValue(rawValue: 0) == 0)
        #expect(minor.majorValue(rawValue: -Double.zero)?.sign == .minus)
    }

    @Test func sourceAndUnitLabelsKeepManualAndMinorValuesTruthful() throws {
        let declared = try #require(StockSagePriceDenomination(currencyCode: "GBP",
            rawUnitsPerMajor: .hundredths, provenance: .manualEntry))
        #expect(declared.quoteUnitLabel == "GBp (100 = 1 GBP)")
        #expect(declared.currencyCode == "GBP")
        #expect(!declared.isProviderReported)
        #expect(!declared.provenanceLabel.localizedCaseInsensitiveContains("provider"))
        #expect(!declared.provenanceLabel.localizedCaseInsensitiveContains("Yahoo"))
        let imported = try #require(StockSagePriceDenomination(currencyCode: "USD",
            rawUnitsPerMajor: .major, provenance: .importedRecord))
        #expect(imported.quoteUnitLabel == "USD" && !imported.isProviderReported)
        #expect(imported.provenanceLabel != declared.provenanceLabel)
        let yahoo = try #require(StockSagePriceDenomination.yahooMetadata(
            ["symbol": "TEST", "currency": "USD"], requestedSymbol: "TEST"))
        #expect(yahoo.isProviderReported && yahoo.provenanceLabel != imported.provenanceLabel)
        let otherMinor = try #require(StockSagePriceDenomination(currencyCode: "USD",
            rawUnitsPerMajor: .hundredths, provenance: .importedRecord))
        #expect(otherMinor.quoteUnitLabel == "USD hundredths (100 = 1 USD)")
    }

    @Test func persistedMetadataRoundTripsAndInvalidPresentMetadataCannotBypassValidation() throws {
        for source in [StockSagePriceDenomination.Provenance.yahooChartMetadata, .manualEntry, .importedRecord] {
            let original = try #require(StockSagePriceDenomination(currencyCode: "GBP",
                rawUnitsPerMajor: .hundredths, provenance: source))
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(StockSagePriceDenomination.self, from: data) == original)
        }
        let invalid = [
            #"{"currencyCode":"usd","rawUnitsPerMajor":1,"provenance":"manualEntry"}"#,
            #"{"currencyCode":"XXX","rawUnitsPerMajor":1,"provenance":"manualEntry"}"#,
            #"{"currencyCode":"USD","rawUnitsPerMajor":1000,"provenance":"importedRecord"}"#,
            #"{"currencyCode":"USD","rawUnitsPerMajor":0,"provenance":"importedRecord"}"#,
            #"{"currencyCode":"USD","rawUnitsPerMajor":1,"provenance":"inferredFromTicker"}"#,
            #"{"currencyCode":"USD","rawUnitsPerMajor":1}"#
        ]
        for json in invalid {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(StockSagePriceDenomination.self, from: Data(json.utf8))
            }
        }
    }

    @Test func legacyMissingMetadataStaysUnknownAndPreservesRecordValues() throws {
        for json in [#"{"symbol":"CSPX.L","rawPrice":725}"#,
                     #"{"symbol":"CSPX.L","rawPrice":725,"denomination":null}"#] {
            let record = try JSONDecoder().decode(PriceDenominationLegacyRecordFixture.self, from: Data(json.utf8))
            #expect(record.symbol == "CSPX.L" && record.rawPrice == 725)
            #expect(record.denomination == nil)
            let again = try JSONDecoder().decode(PriceDenominationLegacyRecordFixture.self, from: JSONEncoder().encode(record))
            #expect(again.symbol == record.symbol && again.rawPrice == record.rawPrice && again.denomination == nil)
        }
        let malformedPresent = #"{"symbol":"CSPX.L","rawPrice":725,"denomination":{"currencyCode":"USD","rawUnitsPerMajor":1000,"provenance":"manualEntry"}}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PriceDenominationLegacyRecordFixture.self, from: Data(malformedPresent.utf8))
        }
    }
}

private nonisolated struct PriceDenominationLegacyRecordFixture: Codable {
    let symbol: String
    let rawPrice: Double
    let denomination: StockSagePriceDenomination?
}
