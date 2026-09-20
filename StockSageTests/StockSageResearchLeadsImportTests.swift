#if os(macOS)
import Foundation
import Testing
@testable import StockSage

@Suite("Local pasted research leads", .serialized)
@MainActor
struct StockSageResearchLeadsImportTests {
    private typealias Leads = StockSageResearchLeads
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func appendCanBeRereadAndSelectedWithoutChangingTheMessageDate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("whatsapp.json")
        #expect(try Leads.read(at: url) == nil)
        let messageDate = now.addingTimeInterval(-3_600)

        let added = try Leads.append(text: " \nQCOM has an unverified group claim.\n ",
            source: " \n ", date: messageDate, to: url, now: now)
        #expect(added)
        let document = try #require(try Leads.read(at: url))
        #expect(document.schema == 1)
        #expect(document.importedAt == now)
        #expect(document.messages.count == 1)
        let message = try #require(document.messages.first)
        #expect(!message.id.isEmpty)
        #expect(message.date == messageDate)
        #expect(message.source == "Pasted WhatsApp")
        #expect(message.text == "QCOM has an unverified group claim.")
        let selected = try #require(Leads.select(document, symbol: "QCOM", now: now))
        #expect(selected.messages.map(\.id) == [message.id])
        #expect(selected.prompt.contains("UNVERIFIED WHATSAPP"))
        #expect(selected.prompt.contains(message.text))
        #expect(Leads.select(document, symbol: "AMZN", now: now)?.messages.isEmpty == true)
    }

    @Test func appendPreservesExistingExportAndMessageProvenance() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("whatsapp.json")
        let oldDate = now.addingTimeInterval(-86_400)
        let oldMessage: [String: Any] = [
            "id": "original-message", "date": oldDate.ISO8601Format(),
            "source": "Original export", "text": "ORCL claim requiring verification.",
            "originalLine": 42, "provenance": ["kind": "export", "redacted": true]
        ]
        let sources: [[String: Any]] = [["name": "Original export", "sha256": "fixture-digest", "messages": 1]]
        let original: [String: Any] = [
            "schema": 1, "importedAt": oldDate.ISO8601Format(),
            "timezone": "Asia/Riyadh (assumed export timezone)", "sources": sources,
            "customExportMetadata": ["redactionVersion": 7], "messages": [oldMessage]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: url)

        let added = try Leads.append(text: "AMZN is another unverified claim.",
            source: "  Pasted group  ", date: now.addingTimeInterval(-60), to: url, now: now)
        #expect(added)
        let document = try #require(try Leads.read(at: url))
        #expect(document.importedAt == now)
        #expect(document.timezone == "Asia/Riyadh (assumed export timezone)")
        #expect(document.messages.count == 2)
        let retained = try #require(document.messages.first { $0.id == "original-message" })
        #expect(retained.date == oldDate)
        #expect(retained.source == "Original export")
        #expect(document.messages.first { $0.source == "Pasted group" }?.date == now.addingTimeInterval(-60))
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((raw["sources"] as? NSArray)?.isEqual(to: sources) == true)
        #expect((raw["customExportMetadata"] as? NSDictionary)?.isEqual(to: ["redactionVersion": 7]) == true)
        let rawMessages = try #require(raw["messages"] as? [[String: Any]])
        let rawOriginal = try #require(rawMessages.first { $0["id"] as? String == "original-message" })
        #expect(NSDictionary(dictionary: rawOriginal).isEqual(to: oldMessage))
    }

    @Test func exactDuplicateIsANoopAfterTrimming() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("whatsapp.json")
        // DatePicker can retain fractional seconds that ISO8601 persistence omits.
        let messageDate = now.addingTimeInterval(-59.75)
        let added = try Leads.append(text: "QCOM claim.", source: "Group",
            date: messageDate, to: url, now: now)
        #expect(added)
        let originalBytes = try Data(contentsOf: url)
        let duplicate = try Leads.append(text: " \nQCOM claim.\n", source: " Group ",
            date: messageDate, to: url, now: now.addingTimeInterval(60))
        #expect(!duplicate)
        #expect(try Data(contentsOf: url) == originalBytes)
        #expect(try Leads.read(at: url)?.messages.count == 1)
    }

    @Test func invalidInputNeverReplacesExistingMessages() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("whatsapp.json")
        let textAtLimit = "QCOM " + String(repeating: "a", count: 2_495)
        let sourceAtLimit = String(repeating: "s", count: 300)
        let added = try Leads.append(text: textAtLimit, source: sourceAtLimit,
            date: now, to: url, now: now)
        #expect(added)
        let originalBytes = try Data(contentsOf: url)
        let invalid: [(text: String, source: String, date: Date, clock: Date)] = [
            (" \n\t", "Group", now, now),
            (String(repeating: "a", count: 2_501), "Group", now, now),
            ("QCOM claim.", String(repeating: "s", count: 301), now, now),
            ("QCOM claim.", "Group", now.addingTimeInterval(1), now),
            ("QCOM claim.", "Group", Date(timeIntervalSince1970: .infinity), now),
            ("QCOM claim.", "Group", Date(timeIntervalSince1970: .nan), now),
            ("QCOM claim.", "Group", now, Date(timeIntervalSince1970: .infinity)),
            ("QCOM claim.", "Group", now, Date(timeIntervalSince1970: .nan))
        ]
        for input in invalid {
            #expect(throws: (any Error).self) {
                try Leads.append(text: input.text, source: input.source, date: input.date,
                    to: url, now: input.clock)
            }
            #expect(try Data(contentsOf: url) == originalBytes)
        }
    }

    @Test func unreadableOrUnsupportedDocumentsAreNeverReplaced() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("whatsapp.json")
        let message: [String: Any] = ["id": "original", "date": now.ISO8601Format(),
            "source": "Group", "text": "QCOM claim."]
        let unsupportedSchema: [String: Any] = ["schema": 2, "importedAt": now.ISO8601Format(),
            "timezone": "UTC", "messages": [message]]
        let excessiveCount: [String: Any] = ["schema": 1, "importedAt": now.ISO8601Format(),
            "timezone": "UTC", "messages": Array(repeating: message, count: 10_001)]
        let invalidDocuments = [
            Data("{not valid JSON".utf8),
            Data(repeating: 0x20, count: 5_000_001),
            try JSONSerialization.data(withJSONObject: unsupportedSchema),
            try JSONSerialization.data(withJSONObject: excessiveCount)
        ]
        for originalBytes in invalidDocuments {
            try originalBytes.write(to: url)
            #expect(throws: (any Error).self) { try Leads.read(at: url) }
            #expect(throws: (any Error).self) {
                try Leads.append(text: "AMZN new claim.", source: "Group", date: now, to: url, now: now)
            }
            #expect(try Data(contentsOf: url) == originalBytes)
        }
    }

    @Test func symbolicLinkIsRejectedWithoutChangingItsTarget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("original.json")
        let link = directory.appendingPathComponent("whatsapp.json")
        let original: [String: Any] = ["schema": 1, "importedAt": now.ISO8601Format(),
            "timezone": "UTC", "messages": []]
        let originalBytes = try JSONSerialization.data(withJSONObject: original)
        try originalBytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: (any Error).self) { try Leads.read(at: link) }
        #expect(throws: (any Error).self) {
            try Leads.append(text: "QCOM claim.", source: "Group", date: now, to: link, now: now)
        }
        #expect(try Data(contentsOf: target) == originalBytes)
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("stocksage-leads-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif
