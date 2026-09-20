#if os(macOS)
import Foundation
import Testing
@testable import StockSage

@Suite("Owner-phone Telegram", .serialized)
@MainActor struct StockSageTelegramTests {
    private typealias Telegram = StockSageTelegram

    @MainActor private final class Fixture {
        let directory: URL
        let now = Date(timeIntervalSince1970: 1_789_900_000)
        let token = "123456:synthetic_test_token_abcdefghijklmnop"
        var savedToken: String?
        var credentialReadFails = false
        var nonce = "00112233445566778899aabbccddeeff"
        var requests: [URLRequest] = []
        var updates: [[String: Any]] = []
        var allowed = true
        var revision = "policy-A"
        var writerAllowed = true
        var failSend = false
        var alternateResponseURL = false
        var responseBody: Data?
        var sendChat: Int64 = 42
        var beforeSendReply: (() async -> Void)?
        var sawPersistedAttempt = false

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("telegram-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func clean() { try? FileManager.default.removeItem(at: directory) }
        var stateURL: URL { directory.appendingPathComponent("state.json") }
        func make() -> Telegram {
            Telegram(credentials: .init(read: {
                if self.credentialReadFails { throw StockSageMassiveCredential.Failure.unavailable }
                return self.savedToken
            }, write: { self.savedToken = $0 }),
                directory: directory, transport: { request in try await self.respond(request) },
                now: { self.now }, nonce: { self.nonce }, allowed: { self.allowed },
                policyRevision: { self.revision }, requireWriter: {
                    if !self.writerAllowed { throw CocoaError(.fileWriteNoPermission) }
                })
        }
        func message(chat: Int64 = 42, type: String = "private", isBot: Bool = false,
                     text: String? = nil, dateOffset: TimeInterval = 0) -> [String: Any] {
            ["update_id": chat, "message": ["message_id": 7, "date": Int(now.addingTimeInterval(dateOffset).timeIntervalSince1970),
                "chat": ["id": chat, "type": type], "from": ["id": chat, "is_bot": isBot, "first_name": "Fixture"],
                "text": text ?? "/start stocksage_\(nonce)"]]
        }
        func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let method = request.url!.lastPathComponent
            var result: Any = ["id": 123456, "is_bot": true, "first_name": "Fixture", "username": "FixtureBot"]
            if method == "getUpdates" { result = updates }
            if method == "sendMessage" {
                let bytes = try Data(contentsOf: stateURL)
                sawPersistedAttempt = String(decoding: bytes, as: UTF8.self).contains("delivery-one")
                await beforeSendReply?()
                if failSend { throw NSError(domain: "SECRET \(token) https://api.telegram.org/private", code: 9) }
                result = ["message_id": 81, "date": Int(now.timeIntervalSince1970), "chat": ["id": sendChat, "type": "private"]]
            }
            let url = alternateResponseURL ? URL(string: "https://example.invalid/redirect")! : request.url!
            let data = try responseBody ?? JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
            return (data,
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        func ready() async throws -> Telegram {
            let service = make()
            await service.saveAndVerify(token: token)
            updates = [message()]
            await service.verifyPairing()
            try #require(service.isReady)
            return service
        }
        var sends: [URLRequest] { requests.filter { $0.url?.lastPathComponent == "sendMessage" } }
    }

    @Test func verifiesBotThenPairsOnlyTheExactRecentPrivateStartWithoutConsumingUpdates() async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = f.make()
        await service.saveAndVerify(token: f.token)
        #expect(f.savedToken == f.token)
        #expect(service.botUsername == "FixtureBot")
        let url = try #require(service.pairingURL)
        #expect(url.host == "t.me" && url.path == "/FixtureBot")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ==
                [URLQueryItem(name: "start", value: "stocksage_" + f.nonce)])
        #expect(!service.isReady)
        f.updates = [f.message()]
        await service.verifyPairing()
        #expect(service.isReady)
        let request = try #require(f.requests.last)
        #expect(request.url?.lastPathComponent == "getUpdates")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["offset"] == nil && body?["allowed_updates"] == nil)
        #expect(!f.requests.contains { ["setWebhook", "deleteWebhook", "sendMessage"].contains($0.url!.lastPathComponent) })
        #expect(f.make().isReady, "The verified private chat must survive a restart with the same secure token")
        let persisted = try String(contentsOf: f.stateURL, encoding: .utf8)
        #expect(!persisted.contains(f.token) && !persisted.contains("api.telegram.org"))
    }

    @Test(arguments: ["wrong-nonce", "group", "bot", "stale", "future", "forwarded", "backlog", "ambiguous"])
    func unrelatedOrAmbiguousUpdatesNeverChooseARecipient(kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = f.make()
        await service.saveAndVerify(token: f.token)
        _ = try #require(service.pairingURL)
        switch kind {
        case "wrong-nonce": f.updates = [f.message(text: "/start stocksage_someone_else")]
        case "group": f.updates = [f.message(chat: -42, type: "group")]
        case "bot": f.updates = [f.message(isBot: true)]
        case "stale": f.updates = [f.message(dateOffset: -601)]
        case "future": f.updates = [f.message(dateOffset: 30)]
        case "forwarded":
            var update = f.message()
            var message = update["message"] as! [String: Any]
            message["forward_origin"] = ["type": "user"]
            update["message"] = message
            f.updates = [update]
        case "backlog": f.updates = Array(repeating: f.message(), count: 100)
        default: f.updates = [f.message(), f.message(chat: 43)]
        }
        await service.verifyPairing()
        #expect(!service.isReady && f.sends.isEmpty)
    }

    @Test func deliveryAttemptPrecedesPOSTAndSameIDCannotSendAfterReload() async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = try await f.ready()
        let first = await service.send(text: "Public research fixture.", deliveryID: "delivery-one", stillValid: { true })
        #expect(first == .delivered(messageID: 81))
        #expect(f.sawPersistedAttempt)
        let request = try #require(f.sends.first)
        let requestBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(request.httpMethod == "POST" && request.timeoutInterval <= 20)
        #expect(request.url?.scheme == "https" && request.url?.host == "api.telegram.org")
        #expect((body["chat_id"] as? NSNumber)?.int64Value == 42)
        #expect(body["text"] as? String == "Public research fixture.")
        #expect(body["parse_mode"] == nil && body["allow_paid_broadcast"] == nil)
        let reloaded = f.make()
        let duplicate = await reloaded.send(text: "Changed content must not repeat an attempted ID.",
            deliveryID: "delivery-one", stillValid: { true })
        #expect(duplicate == .alreadyAttempted && f.sends.count == 1)
    }

    @Test func unknownDeliveryIsDurableNeverRetriedAndDoesNotExposeTheRawError() async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = try await f.ready()
        f.failSend = true
        let result = await service.send(text: "Public research fixture.", deliveryID: "delivery-one", stillValid: { true })
        #expect(result == .unknown)
        #expect(!service.status.contains(f.token) && !service.status.contains("https://") && !service.status.contains("SECRET"))
        let reloaded = f.make()
        let duplicate = await reloaded.send(text: "Public research fixture.", deliveryID: "delivery-one", stillValid: { true })
        #expect(duplicate == .alreadyAttempted && f.sends.count == 1)
    }

    @Test(arguments: ["remove-token", "replace-pairing", "policy-roundtrip", "expired-setup", "wrong-chat"])
    func postDispatchInvalidationCannotPublishSuccess(kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = try await f.ready()
        var valid = true
        var replacementStatus: String?
        f.beforeSendReply = {
            switch kind {
            case "remove-token": service.removeToken()
            case "replace-pairing":
                await service.saveAndVerify(token: "123456:replacement_test_token_abcdefghijkl")
                f.updates = [f.message(chat: 43)]
                await service.verifyPairing()
                replacementStatus = service.status
            case "policy-roundtrip": f.revision = "policy-B"
            case "expired-setup": valid = false
            default: break
            }
        }
        if kind == "wrong-chat" { f.sendChat = 43 }
        let result = await service.send(text: "Public research fixture.", deliveryID: "delivery-one", stillValid: { valid })
        #expect(result == .unknown)
        if kind == "remove-token" {
            #expect(!service.isReady && f.savedToken == nil)
            #expect(service.status == "Telegram token removed. Alerts are disabled.")
            #expect(f.make().status == service.status)
        }
        if kind == "replace-pairing" {
            let expected = try #require(replacementStatus)
            #expect(service.isReady && service.status == expected)
            #expect(expected == "Telegram is ready for this paired private chat.")
            #expect(f.make().status == expected)
        }
        let retry = await service.send(text: "Public research fixture.", deliveryID: "delivery-one", stillValid: { true })
        #expect(retry != .delivered(messageID: 81) && f.sends.count == 1)
    }

    @Test(arguments: ["missing", "changed", "unavailable"])
    func reloadDoesNotAdvertiseReadinessWithoutTheMatchingSecureToken(kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try await f.ready()
        let original = try Data(contentsOf: f.stateURL)
        let requests = f.requests.count
        switch kind {
        case "missing": f.savedToken = nil
        case "changed": f.savedToken = "123456:replacement_test_token_abcdefghijkl"
        default: f.credentialReadFails = true
        }
        let reloaded = f.make()
        #expect(!reloaded.isReady && reloaded.botUsername == nil && reloaded.pairingURL == nil)
        #expect(reloaded.status == "Telegram Keychain access failed or the token changed. Alerts are disabled; verify the token again.")
        #expect(f.requests.count == requests)
        #expect(try Data(contentsOf: f.stateURL) == original)
    }

    @Test func credentialRotationAndRemovalCannotReuseTheOldPairing() async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = try await f.ready()
        let originalRevision = service.pairingRevision
        await service.saveAndVerify(token: "654321:replacement_test_token_abcdefghijkl")
        #expect(!service.isReady && service.pairingRevision != originalRevision)
        let blocked = await service.send(text: "Public fixture.", deliveryID: "delivery-one", stillValid: { true })
        #expect(blocked == .blocked && f.sends.isEmpty)
        let replacementRevision = service.pairingRevision
        service.removeToken()
        #expect(service.pairingRevision != replacementRevision)
        #expect(!service.isReady && service.pairingURL == nil && f.savedToken == nil)
        #expect(!f.make().isReady)
    }

    @Test(arguments: ["writer", "expired", "offline"])
    func failedAdmissionNeverStartsTheSend(kind: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = try await f.ready()
        let original = try Data(contentsOf: f.stateURL)
        if kind == "writer" { f.writerAllowed = false }
        if kind == "offline" { f.allowed = false }
        let result = await service.send(text: "Public fixture.", deliveryID: "delivery-one", stillValid: { kind != "expired" })
        #expect(result == .blocked && f.sends.isEmpty)
        #expect(try Data(contentsOf: f.stateURL) == original)
    }

    @Test func corruptLedgerPreventsDeliveryAndIsNotReplacedBySetup() async throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try await f.ready()
        let bytes = Data("{broken saved ledger".utf8)
        try bytes.write(to: f.stateURL)
        let reloaded = f.make()
        #expect(!reloaded.isReady)
        await reloaded.saveAndVerify(token: f.token)
        let result = await reloaded.send(text: "Public fixture.", deliveryID: "delivery-one", stillValid: { true })
        #expect(result == .blocked && f.sends.isEmpty)
        #expect(try Data(contentsOf: f.stateURL) == bytes)
        reloaded.removeToken()
        #expect(f.savedToken == nil && !reloaded.isReady)
        #expect(try Data(contentsOf: f.stateURL) == bytes)
    }

    @Test(arguments: ["redirect", "oversized", "ok-false", "wrong-bot"])
    func transportRejectsSubstitutedResponseIdentityAndDisablesCredentialPersistence(kind: String) async throws {
        let configuration = Telegram.session.configuration
        #expect(Telegram.session.delegate is StockSageHTTP.NoRedirect)
        #expect(configuration.urlCache == nil && configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil && !configuration.httpShouldSetCookies)
        #expect(configuration.timeoutIntervalForResource <= 20)
        let f = try Fixture(); defer { f.clean() }
        switch kind {
        case "redirect": f.alternateResponseURL = true
        case "oversized": f.responseBody = Data(repeating: 32, count: Telegram.maximumResponseBytes + 1)
        case "ok-false": f.responseBody = Data(#"{"ok":false,"description":"fixture private error"}"#.utf8)
        default: f.responseBody = Data(#"{"ok":true,"result":{"id":999,"is_bot":true,"username":"OtherBot"}}"#.utf8)
        }
        let service = f.make()
        await service.saveAndVerify(token: f.token)
        #expect(service.botUsername == nil && !service.isReady && service.pairingURL == nil)
        #expect(!service.status.contains(f.token) && !service.status.contains("https://"))
    }
}
#endif
