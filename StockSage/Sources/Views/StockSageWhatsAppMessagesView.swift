#if os(macOS)
import SwiftUI

struct StockSageWhatsAppButton: View {
    @State private var isPresented = false

    var body: some View {
        Button("WhatsApp messages", systemImage: "text.bubble") { isPresented = true }
            .accessibilityIdentifier("whatsapp.open")
            .sheet(isPresented: $isPresented) { StockSageWhatsAppMessagesView() }
    }
}

/// Manual, local excerpts. Opening or saving this sheet never starts inference or research.
struct StockSageWhatsAppMessagesView: View {
    var url: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("StockSageResearch/whatsapp.json")
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var source = ""
    @State private var messageDate = Date()
    @State private var document: StockSageResearchLeads.Document?
    @State private var issue: String?
    @State private var saved: String?
    @State private var confirmDiscard = false

    private var hasDraft: Bool { !text.isEmpty || !source.isEmpty }
    private var textCount: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var sourceCount: Int { source.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var canSave: Bool {
        (1...2_500).contains(textCount) && sourceCount <= 300 && messageDate <= Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("PRIVATE RESEARCH NOTES", systemImage: "lock")
                        .font(.caption.weight(.semibold)).foregroundStyle(DS.Palette.accentText)
                    Text("WhatsApp messages").font(.title.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Paste a message to keep it with your stock research.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { if hasDraft { confirmDiscard = true } else { dismiss() } }
                    .accessibilityIdentifier("whatsapp.done")
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Message text").font(.headline)
                        TextEditor(text: $text)
                            .font(.body).scrollContentBackground(.hidden)
                            .padding(8).frame(minHeight: 160)
                            .background(.background, in: .rect(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                            .accessibilityLabel("Paste WhatsApp message text")
                            .accessibilityIdentifier("whatsapp.text")
                        HStack(alignment: .top) {
                            Text("Include the exact stock ticker, such as ORCL. Save each message or short excerpt separately.")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 16)
                            Text("\(textCount.formatted()) / 2,500")
                                .monospacedDigit().foregroundStyle(textCount > 2_500 ? .red : .secondary)
                                .fixedSize()
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 20) { sourceField; dateField }
                        VStack(alignment: .leading, spacing: 16) { sourceField; dateField }
                    }
                    Label {
                        Text("Unverified context. Saving stays on this Mac. When you ask Chat about a ticker or assess one stock, matching excerpts may be sent to your configured model server. Remote servers receive those excerpts. No live WhatsApp connection or training.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "info.circle").foregroundStyle(DS.Palette.accentText) }
                    .padding(12).background(DS.Palette.surface, in: .rect(cornerRadius: 8))
                    if let issue {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DS.Palette.dangerSoft).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("whatsapp.issue")
                    }
                    if let saved {
                        Label(saved, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                            .accessibilityIdentifier("whatsapp.saved")
                    }
                    HStack {
                        Text("\((document?.messages.count ?? 0).formatted()) saved excerpts")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save excerpt") { save() }
                            .buttonStyle(.borderedProminent).disabled(!canSave || url == nil)
                            .accessibilityIdentifier("whatsapp.save")
                    }
                    if let messages = document?.messages, !messages.isEmpty {
                        Divider()
                        Text("Recently saved").font(.headline)
                        ForEach(Array(messages.suffix(3).reversed().enumerated()), id: \.offset) { _, message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(message.source) · \(message.date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(message.text).font(.callout).lineLimit(3).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(24)
            }
        }
        .frame(minWidth: 480, idealWidth: 660, minHeight: 480, idealHeight: 700)
        .background(DS.Palette.bgTop)
        .interactiveDismissDisabled(hasDraft)
        .confirmationDialog("Discard this unsaved excerpt?", isPresented: $confirmDiscard) {
            Button("Discard excerpt", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) { }
        } message: { Text("Previously saved messages will stay on this Mac.") }
        .onAppear { reload() }
    }

    private var sourceField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source · optional").font(.headline)
            TextField("Group or sender label", text: $source)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("whatsapp.source")
            Text(sourceCount > 300 ? "Source is too long: \(sourceCount.formatted()) / 300 characters."
                 : "Up to 300 characters. The sender is not verified.")
                .font(.caption).foregroundStyle(sourceCount > 300 ? DS.Palette.dangerSoft : DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
    }

    private var dateField: some View {
        VStack(alignment: .leading, spacing: 6) {
            DatePicker("Message date", selection: $messageDate, in: ...Date(), displayedComponents: .date)
                .accessibilityIdentifier("whatsapp.date")
            Text("Set the original date; it is not read from the pasted text. Only the last 30 days are eligible for retrieval.")
                .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
    }

    private func reload() {
        guard let url else { issue = "Local storage is unavailable. Your draft has not been saved."; return }
        do { document = try StockSageResearchLeads.read(at: url) }
        catch { issue = "Saved messages could not be read. Existing data has not been replaced." }
    }

    private func save() {
        guard let url else { return }
        do {
            let added = try StockSageResearchLeads.append(text: text, source: source, date: messageDate, to: url)
            issue = nil
            saved = added ? "Excerpt saved on this Mac. No research was started." : "This excerpt is already saved."
            text = ""; source = ""
            reload()
        } catch {
            saved = nil
            issue = "Saving could not be confirmed. Your draft is still here. Check the message length, date and storage access, then retry."
        }
    }
}
#endif
