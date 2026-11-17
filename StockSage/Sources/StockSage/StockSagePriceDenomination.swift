import Foundation

/// The denomination of the raw numbers in one quote or entered/imported record.
/// This value never derives currency or units from a ticker's spelling.
/// Provenance describes the source of the declaration; it is not a data license
/// or independent verification of a manual or imported value.
nonisolated struct StockSagePriceDenomination: Codable, Sendable, Equatable {
    enum RawUnitsPerMajor: Double, Codable, Sendable {
        case major = 1
        case hundredths = 100
    }

    enum Provenance: String, Codable, Sendable {
        case yahooChartMetadata
        case manualEntry
        case importedRecord
    }

    let currencyCode: String
    let rawUnitsPerMajor: RawUnitsPerMajor
    let provenance: Provenance

    init?(currencyCode: String, rawUnitsPerMajor: RawUnitsPerMajor,
          provenance: Provenance) {
        // Do not turn a minor-unit token such as GBp into the major currency GBP
        // by uppercasing it. The source-specific parser handles that explicitly.
        // XXX and XTS denote no currency/testing, not a usable money basis.
        guard currencyCode == currencyCode.uppercased(),
              currencyCode != "XXX", currencyCode != "XTS",
              Locale.commonISOCurrencyCodes.contains(currencyCode) else { return nil }
        self.currencyCode = currencyCode
        self.rawUnitsPerMajor = rawUnitsPerMajor
        self.provenance = provenance
    }

    static func manualDeclaration(currencyInput: String, hundredths: Bool) -> Self? {
        let raw = currencyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw != "GBp", raw.uppercased() != "GBX", raw != "ZAc" else { return nil }
        return Self(currencyCode: raw.uppercased(),
                    rawUnitsPerMajor: hundredths ? .hundredths : .major,
                    provenance: .manualEntry)
    }

    /// Currency and raw-unit metadata must accompany the requested instrument in
    /// this response. A missing field or unsupported convention stays unknown.
    /// This parser does not validate price freshness or history sampling.
    static func yahooMetadata(_ meta: [String: Any]?, requestedSymbol: String) -> Self? {
        guard let meta,
              !requestedSymbol.isEmpty,
              requestedSymbol == requestedSymbol.trimmingCharacters(in: .whitespacesAndNewlines),
              let reportedSymbol = meta["symbol"] as? String,
              reportedSymbol == reportedSymbol.trimmingCharacters(in: .whitespacesAndNewlines),
              reportedSymbol.uppercased() == requestedSymbol.uppercased(),
              let rawCurrency = meta["currency"] as? String else { return nil }

        let currency: String
        let units: RawUnitsPerMajor
        switch rawCurrency {
        case "GBp", "GBX": currency = "GBP"; units = .hundredths
        case "ZAc": currency = "ZAR"; units = .hundredths
        default: currency = rawCurrency; units = .major
        }
        return Self(currencyCode: currency, rawUnitsPerMajor: units,
                    provenance: .yahooChartMetadata)
    }

    /// Convert a raw amount into major currency units without turning a nonzero
    /// representable input into zero. This is only a unit conversion: consumers
    /// must separately enforce their domain, such as a strictly positive price.
    /// Finite signed cash amounts and zero are intentionally supported.
    func majorValue(rawValue: Double) -> Double? {
        guard rawValue.isFinite else { return nil }
        let converted = rawValue / rawUnitsPerMajor.rawValue
        guard converted.isFinite, rawValue == 0 || converted != 0 else { return nil }
        return converted
    }

    /// Label for RAW quote values. After majorValue, label the result with
    /// currencyCode instead; reusing this label would apply minor units twice.
    var quoteUnitLabel: String {
        switch (currencyCode, rawUnitsPerMajor) {
        case (_, .major): return currencyCode
        case ("GBP", .hundredths): return "GBp (100 = 1 GBP)"
        case ("ZAR", .hundredths): return "ZAc (100 = 1 ZAR)"
        case (_, .hundredths): return "\(currencyCode) hundredths (100 = 1 \(currencyCode))"
        }
    }

    /// Source wording is deliberately distinct for provider data, user entry
    /// and imports. Imported records are not promoted to provider verification.
    var provenanceLabel: String {
        switch provenance {
        case .yahooChartMetadata: return "Yahoo chart metadata"
        case .manualEntry: return "Entered by you"
        case .importedRecord: return "Imported record"
        }
    }

    var isProviderReported: Bool { provenance == .yahooChartMetadata }

    private enum CodingKeys: String, CodingKey {
        case currencyCode, rawUnitsPerMajor, provenance
    }

    /// Synthesized decoding would bypass the validated initializer. Invalid
    /// present metadata must fail decoding; callers can preserve an old record's
    /// missing optional denomination as nil without inventing a currency.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let currency = try values.decode(String.self, forKey: .currencyCode)
        let units = try values.decode(RawUnitsPerMajor.self, forKey: .rawUnitsPerMajor)
        let source = try values.decode(Provenance.self, forKey: .provenance)
        guard let validated = Self(currencyCode: currency, rawUnitsPerMajor: units,
                                   provenance: source) else {
            throw DecodingError.dataCorruptedError(forKey: .currencyCode, in: values,
                debugDescription: "A denomination requires a supported explicit ISO currency code.")
        }
        self = validated
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(currencyCode, forKey: .currencyCode)
        try values.encode(rawUnitsPerMajor, forKey: .rawUnitsPerMajor)
        try values.encode(provenance, forKey: .provenance)
    }
}
