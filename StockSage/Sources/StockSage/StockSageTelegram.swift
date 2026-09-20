#if os(macOS)
import Foundation
import Combine
import CryptoKit
import Darwin

/// Public research alerts to one explicitly paired private chat; never trading orders.
@MainActor final class StockSageTelegram: ObservableObject {
    enum DeliveryResult: Equatable, Sendable {
        case delivered(messageID: Int64), alreadyAttempted, blocked, unknown
    }
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, URLResponse)
    static let shared = StockSageTelegram()
    static let maximumResponseBytes = 1_048_576
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)
    }()

    @Published private(set) var pairingRevision = UUID()
    @Published private(set) var isReady = false
    @Published private(set) var status = Notice.setup.text
    @Published private(set) var isBusy = false
    @Published private(set) var pairingURL: URL?
    @Published private(set) var botUsername: String?

    private enum Notice: String, Codable {
        case setup, pairing, ready, removed, storage, credential, invalidToken, unavailable, offline
        case expired, noMatch, ambiguous, busy, invalidMessage, staleAlert, attempted, sent, unknown
        var text: String {
            switch self {
            case .setup: "Telegram setup is not complete."
            case .pairing: "Bot verified. Open the private pairing link, press Start in your own Telegram account, then verify here within ten minutes."
            case .ready: "Telegram is ready for this paired private chat."
            case .removed: "Telegram token removed. Alerts are disabled."
            case .storage: "Telegram records could not be safely saved or read. Alerts are stopped; existing records were preserved."
            case .credential: "Telegram Keychain access failed or the token changed. Alerts are disabled; verify the token again."
            case .invalidToken: "Enter the bot token supplied by BotFather. The saved pairing was not changed."
            case .unavailable: "Telegram verification failed. Check the token and connection. Use a dedicated bot without another update reader or webhook."
            case .offline: "Telegram requires web access. Check Offline Mode and Web access in Settings."
            case .expired: "The pairing link expired or settings changed. Save and verify the token to create a new link."
            case .noMatch: "No matching recent private Start message was found. Open this pairing link in your own account, press Start, then verify again. Updates are not deleted."
            case .ambiguous: "More than one private chat used this link. Pairing was refused. Save and verify again for a new private link."
            case .busy: "A Telegram operation is already in progress."
            case .invalidMessage: "The alert text or delivery identity is invalid. Nothing was sent."
            case .staleAlert: "The alert was cancelled or is no longer a fresh active setup. Nothing was sent."
            case .attempted: "This alert was already attempted. It will not be sent again automatically."
            case .sent: "Telegram accepted the alert for the paired private chat. Phone display or reading is not confirmed."
            case .unknown: "Telegram delivery could not be confirmed. It may have arrived. This alert will not be retried automatically; check Telegram."
            }
        }
    }
    private enum Failure: Error { case storage, response, stale }
    private struct Bot: Codable { let id: Int64; let username: String }
    private struct Challenge: Codable { let nonce: String; let createdAt: Date }
    private struct Delivery: Codable {
        enum Outcome: String, Codable { case attempted, delivered, unknown }
        let at: Date
        let generation: UUID
        let chatID: Int64
        var outcome: Outcome
        var messageID: Int64?
    }
    private struct State: Codable {
        var version = 1
        var generation = UUID()
        var fingerprint: String?
        var bot: Bot?
        var challenge: Challenge?
        var chatID: Int64?
        var notice = Notice.setup
        var deliveries: [String: Delivery] = [:]
    }
    private struct User: Decodable { let id: Int64; let is_bot: Bool; let username: String? }
    private struct Chat: Decodable { let id: Int64; let type: String }
    private struct Forward: Decodable {}
    private struct Message: Decodable {
        let message_id: Int64?
        let date: Int64?
        let chat: Chat
        let from: User?
        let text: String?
        let forward_origin: Forward?
    }
    private struct Update: Decodable { let update_id: Int64; let message: Message? }
    private struct Reply<T: Decodable>: Decodable { let ok: Bool; let result: T? }

    private let credentials: StockSageMassiveCredential.Storage
    private let directory: URL?
    private let transport: Transport
    private let now: @MainActor () -> Date
    private let nonce: @MainActor () -> String
    private let allowed: @MainActor () -> Bool
    private let policyRevision: @MainActor () -> String?
    private let requireWriter: @MainActor () throws -> Void
    private var state = State()
    private var storageFailed = false
    private var operation: UUID?
    private var loadedExisting = false
    private static let maximumStateBytes = 4 * 1_024 * 1_024

    init(credentials: StockSageMassiveCredential.Storage? = nil, directory: URL? = nil,
         transport: Transport? = nil, now: @escaping @MainActor () -> Date = Date.init,
         nonce: @escaping @MainActor () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "") },
         allowed: @escaping @MainActor () -> Bool = { ToolPolicy.isExternalAllowed },
         policyRevision: @escaping @MainActor () -> String? = { AppSettings.policyRevision() },
         requireWriter: @escaping @MainActor () throws -> Void = { try StockSageRecordWriter.require(.standard) }) {
        // Merely instantiating shared in a test host must never touch owner storage or Keychain.
        self.credentials = credentials ?? (StockSageStore.isRunningTests
            ? .init(read: { nil }, write: { _ in throw Failure.storage })
            : StockSageMassiveCredential.keychain(service: "SA.StockSage.Telegram", account: "bot-token"))
        self.directory = directory ?? (StockSageStore.isRunningTests ? nil : FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("StockSage/Telegram", isDirectory: true))
        self.transport = transport ?? { request in
            try await StockSageHTTP.data(for: request, session: Self.session, maximumBytes: Self.maximumResponseBytes)
        }
        self.now = now; self.nonce = nonce; self.allowed = allowed
        self.policyRevision = policyRevision; self.requireWriter = requireWriter
        do { try reload(); publish() }
        catch { storageFailed = true; status = Notice.storage.text }
    }

    func saveAndVerify(token: String) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validToken(token) else { status = Notice.invalidToken.text; return }
        let id = begin()
        defer { end(id) }
        pairingRevision = UUID()
        isReady = false; pairingURL = nil; botUsername = nil
        do {
            try reload()
            try requireWriter()
            state.generation = pairingRevision; state.fingerprint = nil; state.bot = nil
            state.challenge = nil; state.chatID = nil; state.notice = .setup
            try persist() // Revoke the old pairing before any possibly partial credential write.
            try credentials.write(token)
            guard try credentials.read() == token else { throw Failure.stale }
            state.fingerprint = Self.digest(token)
            try persist()
        } catch {
            status = storageFailed ? Notice.storage.text : Notice.credential.text
            return
        }
        guard allowed(), !Task.isCancelled else { setNotice(.offline); return }
        let generation = state.generation, policy = policyRevision()
        do {
            let user: User = try await request("getMe", token: token, body: [:])
            guard current(token: token, generation: generation, policy: policy),
                  user.is_bot, user.id > 0, String(user.id) == token.split(separator: ":").first.map(String.init),
                  let username = user.username, Self.validUsername(username) else { throw Failure.response }
            let value = nonce(), clock = now()
            guard Self.validNonce(value), Self.validDate(clock) else { throw Failure.response }
            state.bot = Bot(id: user.id, username: username)
            state.challenge = Challenge(nonce: value, createdAt: clock)
            state.notice = .pairing
            try persist(); publish()
        } catch {
            if operation == id { setNotice(storageFailed ? .storage : .unavailable) }
        }
    }

    func verifyPairing() async {
        guard !isBusy else { status = Notice.busy.text; return }
        let id = begin(); defer { end(id) }
        do { try reload() } catch { failStorage(); return }
        guard let challenge = state.challenge, let token = try? credentials.read(),
              state.fingerprint == Self.digest(token), state.bot != nil,
              Self.validDate(now()), (0...600).contains(now().timeIntervalSince(challenge.createdAt)) else {
            pairingRevision = UUID(); state.generation = pairingRevision; state.challenge = nil
            isReady = false; pairingURL = nil; setNotice(.expired); return
        }
        guard allowed(), !Task.isCancelled else { setNotice(.offline); return }
        let generation = state.generation, policy = policyRevision()
        do {
            // No offset, allowed_updates or webhook mutation: preserve the user's update queue/settings.
            let updates: [Update] = try await request("getUpdates", token: token, body: ["limit": 100, "timeout": 0])
            guard current(token: token, generation: generation, policy: policy),
                  (0...600).contains(now().timeIntervalSince(challenge.createdAt)) else { throw Failure.stale }
            guard updates.count < 100 else { setNotice(.noMatch); return }
            let matches = Set(updates.compactMap { update -> Int64? in
                guard let message = update.message, message.chat.type == "private", message.chat.id > 0,
                      let from = message.from, !from.is_bot, from.id == message.chat.id,
                      message.forward_origin == nil, let date = message.date,
                      Double(date) >= floor(challenge.createdAt.timeIntervalSince1970),
                      Double(date) <= now().timeIntervalSince1970,
                      message.text == "/start stocksage_" + challenge.nonce else { return nil }
                return message.chat.id
            })
            guard matches.count == 1 else {
                if matches.count > 1 {
                    pairingRevision = UUID(); state.generation = pairingRevision
                    state.challenge = nil; pairingURL = nil; setNotice(.ambiguous)
                }
                else { setNotice(.noMatch) }
                return
            }
            pairingRevision = UUID(); state.generation = pairingRevision
            state.chatID = matches.first; state.challenge = nil; state.notice = .ready
            try persist(); publish()
        } catch {
            if operation == id { setNotice(storageFailed ? .storage : .unavailable) }
        }
    }

    func removeToken() {
        operation = nil; pairingRevision = UUID()
        isBusy = false; isReady = false; pairingURL = nil; botUsername = nil
        // A damaged ledger must not prevent explicitly removing the secure credential.
        // Preserve that ledger and still require this process's write authority.
        do { try requireWriter() } catch { status = Notice.storage.text; return }
        do {
            try reload()
            state.generation = pairingRevision; state.fingerprint = nil; state.bot = nil
            state.chatID = nil; state.challenge = nil; state.notice = .removed
            try persist()
        } catch { storageFailed = true }
        do {
            try credentials.write(nil)
            guard try credentials.read() == nil else { throw Failure.stale }
            status = storageFailed ? Notice.storage.text : Notice.removed.text
        } catch { status = Notice.credential.text }
    }

    func send(text: String, deliveryID: String,
              stillValid: @escaping @MainActor () -> Bool) async -> DeliveryResult {
        let waitingPairing = pairingRevision, waitingPolicy = policyRevision()
        while isBusy {
            guard !Task.isCancelled, allowed(), stillValid(), pairingRevision == waitingPairing,
                  policyRevision() == waitingPolicy else { status = Notice.staleAlert.text; return .blocked }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, pairingRevision == waitingPairing, policyRevision() == waitingPolicy else {
            status = Notice.staleAlert.text; return .blocked
        }
        do { try reload() } catch { failStorage(); return .blocked }
        guard state.deliveries[deliveryID] == nil else { status = Notice.attempted.text; return .alreadyAttempted }
        guard Self.validID(deliveryID), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 4_096 else { status = Notice.invalidMessage.text; return .blocked }
        guard allowed() else { status = Notice.offline.text; return .blocked }
        guard !Task.isCancelled, stillValid() else { status = Notice.staleAlert.text; return .blocked }
        guard let token = try? credentials.read(), Self.validToken(token),
              state.fingerprint == Self.digest(token), let chatID = state.chatID, state.bot != nil else {
            pairingRevision = UUID(); isReady = false; status = Notice.credential.text; return .blocked
        }
        let id = begin(); defer { end(id) }
        let generation = state.generation, policy = policyRevision(), clock = now()
        guard Self.validDate(clock) else { status = Notice.invalidMessage.text; return .blocked }
        do {
            try requireWriter()
            state.deliveries[deliveryID] = Delivery(at: clock, generation: generation, chatID: chatID, outcome: .attempted)
            state.notice = .attempted
            try persist() // Durable deduplication must precede the only POST, including uncertain outcomes.
        } catch { failStorage(); return .blocked }
        do {
            guard current(token: token, generation: generation, policy: policy), stillValid() else { throw Failure.stale }
            let message: Message = try await request("sendMessage", token: token,
                body: ["chat_id": chatID, "text": text, "link_preview_options": ["is_disabled": true]])
            guard current(token: token, generation: generation, policy: policy), stillValid(),
                  message.chat.type == "private", message.chat.id == chatID,
                  let messageID = message.message_id, messageID > 0 else { throw Failure.response }
            state.deliveries[deliveryID]?.outcome = .delivered
            state.deliveries[deliveryID]?.messageID = messageID
            state.notice = .sent
            try persist(); status = Notice.sent.text
            return .delivered(messageID: messageID)
        } catch {
            // A replacement token/pairing may have changed state while awaiting the response.
            // Reload that state and only amend this already-existing delivery record.
            do {
                try reload()
                guard state.deliveries[deliveryID] != nil else { throw Failure.storage }
                let ownsNotice = operation == id && state.generation == generation
                state.deliveries[deliveryID]?.outcome = .unknown
                state.deliveries[deliveryID]?.messageID = nil
                if ownsNotice { state.notice = .unknown }
                try persist()
                if ownsNotice { status = Notice.unknown.text }
            } catch { failStorage() }
            return .unknown
        }
    }

    private func begin() -> UUID { let id = UUID(); operation = id; isBusy = true; return id }
    private func end(_ id: UUID) { if operation == id { operation = nil; isBusy = false } }
    private func failStorage() { pairingRevision = UUID(); storageFailed = true; isReady = false; pairingURL = nil; status = Notice.storage.text }
    private func setNotice(_ value: Notice) {
        state.notice = value
        do { try persist(); status = value.text } catch { failStorage() }
    }
    private func publish() {
        pairingRevision = state.generation
        status = state.notice.text; botUsername = nil
        isReady = false; pairingURL = nil
        guard !storageFailed, let token = try? credentials.read(), Self.validToken(token),
              state.fingerprint == Self.digest(token) else {
            if state.fingerprint != nil { status = Notice.credential.text }
            return
        }
        guard let bot = state.bot else { return }
        botUsername = bot.username
        isReady = state.chatID != nil
        if let challenge = state.challenge, (0...600).contains(now().timeIntervalSince(challenge.createdAt)) {
            var url = URLComponents(); url.scheme = "https"; url.host = "t.me"; url.path = "/" + bot.username
            url.queryItems = [.init(name: "start", value: "stocksage_" + challenge.nonce)]
            pairingURL = url.url
        }
    }
    private func current(token: String, generation: UUID, policy: String?) -> Bool {
        guard !storageFailed, !Task.isCancelled, allowed(), policyRevision() == policy,
              state.generation == generation, (try? credentials.read()) == token else { return false }
        // Also reject another explicitly instantiated writer's saved credential generation.
        guard let saved = try? readState(), saved.generation == generation,
              saved.fingerprint == Self.digest(token) else { return false }
        return true
    }
    private func request<T: Decodable>(_ method: String, token: String, body: [String: Any]) async throws -> T {
        guard Self.validToken(token), allowed(), !Task.isCancelled,
              let url = URL(string: "https://api.telegram.org/bot" + token + "/" + method) else { throw Failure.stale }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport(request)
        guard data.count <= Self.maximumResponseBytes, let http = response as? HTTPURLResponse,
              http.url == url, http.statusCode == 200,
              http.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw Failure.response }
        let reply = try JSONDecoder().decode(Reply<T>.self, from: data)
        guard reply.ok, let result = reply.result else { throw Failure.response }
        return result
    }

    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func validToken(_ value: String) -> Bool {
        value.utf8.count <= 256 && value.range(of: #"\A[0-9]{1,20}:[A-Za-z0-9_-]{20,200}\z"#, options: .regularExpression) != nil
    }
    private static func validUsername(_ value: String) -> Bool {
        value.range(of: #"\A[A-Za-z][A-Za-z0-9_]{4,31}\z"#, options: .regularExpression) != nil
    }
    private static func validNonce(_ value: String) -> Bool {
        value.range(of: #"\A[A-Za-z0-9_-]{32,48}\z"#, options: .regularExpression) != nil
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func validDate(_ value: Date) -> Bool { value.timeIntervalSince1970.isFinite && value.timeIntervalSince1970 > 0 }
    private func validate(_ value: State) throws {
        guard value.version == 1, value.deliveries.count <= 10_000,
              value.fingerprint.map({ $0.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil }) ?? true,
              value.bot.map({ $0.id > 0 && Self.validUsername($0.username) && value.fingerprint != nil }) ?? true,
              value.chatID.map({ $0 > 0 && value.bot != nil && value.challenge == nil }) ?? true,
              value.challenge.map({ Self.validNonce($0.nonce) && Self.validDate($0.createdAt) && value.bot != nil }) ?? true,
              value.deliveries.allSatisfy({ key, record in
                  Self.validID(key) && Self.validDate(record.at) && record.chatID > 0 &&
                  (record.outcome == .delivered ? (record.messageID ?? 0) > 0 : record.messageID == nil)
              }) else { throw Failure.storage }
    }

    private func reload() throws {
        guard !storageFailed else { throw Failure.storage }
        do { state = try readState() }
        catch { storageFailed = true; throw error }
    }
    private func readState() throws -> State {
        guard let directory else { throw Failure.storage }
        try checkParents(directory)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT, !loadedExisting else { throw Failure.storage }
            return State()
        }
        defer { close(fd) }
        let data = try read("state.json", parent: fd, maximum: Self.maximumStateBytes)
        let marker = try read("initialized", parent: fd, maximum: 1)
        guard marker == nil || marker == Data([1]) else { throw Failure.storage }
        guard let data else {
            guard marker == nil, !loadedExisting else { throw Failure.storage }
            return State()
        }
        let decoded = try JSONDecoder().decode(State.self, from: data)
        try validate(decoded); loadedExisting = true
        return decoded
    }
    private func persist() throws {
        do {
            guard !storageFailed, let directory else { throw Failure.storage }
            try requireWriter(); try validate(state); try checkParents(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.storage }; defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid(), fchmod(fd, 0o700) == 0 else { throw Failure.storage }
            // Validate existing paths before replacement; never repair corruption by overwriting it.
            let marker = try read("initialized", parent: fd, maximum: 1)
            guard marker == nil || marker == Data([1]) else { throw Failure.storage }
            if let existing = try read("state.json", parent: fd, maximum: Self.maximumStateBytes) {
                try validate(try JSONDecoder().decode(State.self, from: existing))
            } else if loadedExisting || marker != nil { throw Failure.storage }
            let data = try JSONEncoder().encode(state)
            guard data.count <= Self.maximumStateBytes else { throw Failure.storage }
            try replace(data, name: "state.json", parent: fd)
            loadedExisting = true
            if try read("initialized", parent: fd, maximum: 1) == nil { try replace(Data([1]), name: "initialized", parent: fd) }
        } catch { storageFailed = true; isReady = false; throw error }
    }
    private func read(_ name: String, parent: Int32, maximum: Int) throws -> Data? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw Failure.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= maximum else { throw Failure.storage }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count == info.st_size else { throw Failure.storage }
        return bytes
    }
    private func replace(_ data: Data, name: String, parent: Int32) throws {
        let temporary = "." + UUID().uuidString + ".tmp"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.storage }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.storage }; offset += count
            }
        }
        guard fsync(fd) == 0, renameat(parent, temporary, parent, name) == 0 else { throw Failure.storage }
        if fsync(parent) != 0, errno != EINVAL, errno != ENOTSUP { throw Failure.storage }
    }
    private func checkParents(_ url: URL) throws {
        guard url.isFileURL else { throw Failure.storage }
        var path = url.standardizedFileURL
        while path.path != "/" {
            var info = stat()
            if lstat(path.path, &info) == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: path.path)
                    guard let expected = ["/var": "/private/var", "/tmp": "/private/tmp"][path.path],
                          target == expected || target == String(expected.dropFirst()) else { throw Failure.storage }
                }
            } else if errno != ENOENT { throw Failure.storage }
            path.deleteLastPathComponent()
        }
    }
}
#endif
