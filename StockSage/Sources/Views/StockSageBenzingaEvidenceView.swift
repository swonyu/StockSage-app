import SwiftUI

/// Captured values only: rendering never reads a client, preferences, Store or provider.
struct StockSageBenzingaEvidenceView: View {
    let capturedSnapshot: StockSageBenzinga.Snapshot
    let projection: StockSageBenzinga.Projection?

    init(capturedSnapshot: StockSageBenzinga.Snapshot) {
        self.capturedSnapshot = capturedSnapshot
        projection = StockSageBenzinga.projection(capturedSnapshot, maximumUTF8Bytes: 12_000)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Benzinga via Massive · \(capturedSnapshot.symbol)").font(.subheadline.bold())
                Text("Captured \(capturedSnapshot.capturedAt.ISO8601Format()). Historical source snapshot, not a live quote or complete coverage.")
                    .foregroundStyle(.secondary)
                if let projection {
                    ForEach(Array(projection.statusLines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                    }
                    DisclosureGroup("Captured checks and retained records · \(projection.records.count)") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(capturedSnapshot.pages.enumerated()), id: \.offset) { _, page in
                                Text(verbatim: Self.checkLabel(page)).foregroundStyle(.secondary)
                            }
                            ForEach(projection.records) { record in
                                Self.recordContent(record)
                            }
                            ForEach(Self.omissionLines(for: projection), id: \.self) { line in
                                Text(verbatim: line)
                            }
                        }
                    }
                } else {
                    ForEach(StockSageBenzinga.Product.allCases, id: \.rawValue) { product in
                        Text("\(product.label): status projection unavailable within the display budget.")
                    }
                }
                Text("Attributed provider claims, not instructions or executable prices. Guidance is an issuer expectation; analyst targets and consensus are opinions. Model requests may omit whole records to fit; consult the supplied/cited facts for their actual selection.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    nonisolated static func omissionLines(for projection: StockSageBenzinga.Projection) -> [String] {
        var lines: [String] = []
        if projection.notEligibleCount > 0 {
            lines.append("\(projection.notEligibleCount) records excluded by evidence eligibility or validation rules.")
        }
        if projection.cappedRecordCount > 0 {
            lines.append("\(projection.cappedRecordCount) records beyond the retained cap of 3 per product.")
        }
        if projection.trimmedRecordCount > 0 {
            lines.append("\(projection.trimmedRecordCount) retained records not shown in this panel.")
        }
        return lines
    }

    /// Use the same whole source text as the model projection; never invent a source date.
    @ViewBuilder static func recordContent(_ record: StockSageBenzinga.Record) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: record.sourceText)
            if let link = record.link, link.scheme?.lowercased() == "https",
               link.host != nil, link.user == nil, link.password == nil {
                Link("Open source", destination: link)
                    .accessibilityLabel("Open \(record.product.label) source for \(record.symbol ?? "referenced metadata")")
            }
        }
        .font(.caption)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    nonisolated static func checkLabel(_ page: StockSageBenzinga.Page) -> String {
        let query = "\(page.query.product.label) · \(page.query.subject)"
        if page.status == .notChecked { return query + " · Not checked" }
        if case .unavailable(.priorAuthenticationRejection) = page.status {
            return query + " · " + statusLabel(page.status) + " · Decision recorded " + page.checkedAt.ISO8601Format()
        }
        return query + " · " + statusLabel(page.status)
            + " · Locally checked \(page.checkedAt.ISO8601Format())"
            + " · \(page.records.count) retained, \(page.excludedCount) excluded"
            + (page.hasMore ? " · More results exist; continuation not retrieved." : "")
    }

    nonisolated private static func statusLabel(_ status: StockSageBenzinga.Status) -> String {
        switch status {
        case .notChecked: return "Not checked"
        case .answered: return "Answered (bounded response)"
        case .partial: return "Partial response"
        case .unavailable(let failure):
            switch failure {
            case .invalidQuery: return "Unavailable: unsupported query"
            case .missingCredential: return "Unavailable: Massive credential missing"
            case .unauthorized: return "Unavailable: authentication rejected"
            case .priorAuthenticationRejection(let subject, let checkedAt):
                return "Not requested: this product rejected authentication for \(subject) at \(checkedAt.ISO8601Format()); retry this evidence after the short cache expires, or use Settings → Data sources → Test connection to clear the cached rejection, then reopen this evidence. Test connection checks snapshot access only."
            case .entitlement: return "Unavailable: product access denied"
            case .throttled: return "Unavailable: rate limited"
            case .transport: return "Unavailable: transport failure"
            case .timedOut: return "Unavailable: timed out"
            case .cancelled: return "Unavailable: cancelled"
            case .policyDenied: return "Unavailable: external access disabled"
            case .obsoleteCredential: return "Unavailable: credential changed"
            case .malformed: return "Unavailable: malformed response"
            case .oversized: return "Unavailable: response exceeded size limit"
            case .http(let code): return "Unavailable: HTTP \(code)"
            }
        }
    }
}
