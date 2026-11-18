import SwiftUI

struct StockSagePersonalSizerView: View {
    @State private var account = ""
    @State private var risk = ""
    @State private var entry = ""
    @State private var stop = ""
    @State private var currency = ""
    @State private var hundredths = false
    private var unit: StockSagePriceDenomination? {
        StockSagePriceDenomination.manualDeclaration(currencyInput: currency, hundredths: hundredths)
    }
    private var result: PositionSize? {
        guard let account = StockSageInput.positiveAmount(account),
              let risk = StockSageInput.positiveAmount(risk), risk <= 100,
              let entry = StockSageInput.positiveAmount(entry),
              let stop = StockSageInput.positiveAmount(stop) else { return nil }
        return StockSagePositionSizer.recordedSize(accountMajor: account, riskFraction: risk / 100,
            entry: entry, stop: stop, denomination: unit)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Planned stop-risk calculator").font(.title2.bold())
            Text("Use your own inputs in one currency. This estimates whole shares from a chosen stop distance; it does not choose a trade, send an order or verify a price.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            StockSageDenominationFields(currency: $currency, hundredths: $hundredths)
            field("Account value in major currency units", text: $account, id: "account")
            field("Risk percent (greater than 0, up to 100)", text: $risk, id: "risk")
            field("Entry in the selected price units", text: $entry, id: "entry")
            field("Stop in the same price units", text: $stop, id: "stop")
            if let result, let unit {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(result.shares) whole shares").font(.title3.bold())
                    Text("Planned stop risk: \(StockSageCurrency.approxAmount(result.dollarsAtRisk, symbol: "", denomination: unit))")
                    Text("Notional: \(StockSageCurrency.approxAmount(result.notional, symbol: "", denomination: unit))")
                    Text(String(format: "Notional is %.2f%% of the entered account.", result.pctOfAccount))
                    if result.shares == 0 { Text("The entered risk budget is below one whole share.").foregroundStyle(.secondary) }
                    if result.pctOfAccount > 100 { Text("The calculated notional exceeds the entered account value.").foregroundStyle(DS.Palette.warningSoft) }
                }
                .accessibilityIdentifier("personalSizer.result")
            } else {
                Text("Enter all values and an explicit currency. Entry and stop must differ. Values that overflow or cannot be represented leave the calculation unavailable.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Assumes a fill at the stop and ignores fees, slippage, gaps, lot rules and financing. Actual losses can exceed the planned amount.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: 780, alignment: .leading)
            .navigationTitle("Stop-risk calculator")
    }
    private func field(_ label: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout)
            TextField(label, text: text).textFieldStyle(.roundedBorder).decimalKeyboardOnIOS(true)
                .accessibilityIdentifier("personalSizer.\(id)")
        }
    }
}
