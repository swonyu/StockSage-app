import Foundation
import CryptoKit
#if os(macOS)
import Darwin
#endif

/// Public-evidence assessment through the owner's Codex subscription.
/// Codex can inherit owner-level instructions; this is not a context-free chat or conversation-memory bridge.
/// Scheduling belongs to the caller. This boundary never retries or starts a background turn.
@MainActor enum StockSageCodexResearch {
    static let model = "gpt-6-astra"
    nonisolated struct Audit: Codable, Equatable, Sendable {
        let requestedModel: String
        let requestedEffort: String
        let reportedModel: String?
        let cliVersion: String
        let terminalStatus: String
        let systemSHA256: String
        let userSHA256: String
        let schemaSHA256: String
        let inputTokens: Int?
        let outputTokens: Int?
        let elapsedMilliseconds: Int
    }
    nonisolated struct Completion: Sendable { let text: String; let audit: Audit }
    nonisolated struct Failure: Error, Sendable {
        let message: String
        let audit: Audit?
    }
    #if os(macOS)
    nonisolated struct Invocation: Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let directory: URL
        let input: Data
        let deadline: Date
        /// Non-generation metadata RPC. Never thread/start, turn/start or account mutation.
        var rpcMethod: String? = nil
        var finalFile: URL? = nil
    }
    nonisolated struct ProcessOutput: Sendable {
        var status: Int32
        var stdout = Data()
        var stderr = Data()
    }
    typealias Executor = @MainActor (Invocation) async throws -> ProcessOutput

    private static let executable = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
    private static let supportedVersion = "0.155.0-alpha.9.2"
    private static let disabledFeatures = ["apps", "plugins", "remote_plugin", "memories", "multi_agent", "multi_agent_v2",
        "browser_use", "browser_use_external", "browser_use_full_cdp_access", "in_app_browser", "code_mode", "code_mode_host",
        "shell_tool", "unified_exec", "skill_search", "hooks", "skill_mcp_dependency_install", "chronicle", "tool_suggest", "auth_elicitation", "view_image", "image_generation"]
    private static var processes: [UUID: Process] = [:]
    private static var generation = UUID()
    private static var busy = false
    private static let maximumStream = 262_144
    private static let maximumFinal = 8_192

    private enum Rejection: Error { case unavailable, auth, isolation, model, output, overflow, interrupted }
    private static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private static func quoted(_ value: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), as: UTF8.self)
    }

    private static func overrides(in directory: URL, disabledMCP: [String]) -> [String] {
        let values = ["model=\(quoted(model))", "model_provider=\"openai\"", "model_reasoning_effort=\"ultra\"",
            "forced_login_method=\"chatgpt\"", "approval_policy=\"never\"", "project_doc_max_bytes=0",
            "web_search=\"disabled\"", "memories.use_memories=false", "memories.generate_memories=false",
            "developer_instructions=\"\"", "instructions=\"\"",
            "model_instructions_file=\(quoted(directory.appendingPathComponent("instructions.md").path))",
            "default_permissions=\"research\"",
            "permissions.research.filesystem={\":minimal\"=\"read\",\":workspace_roots\"=\"read\"}",
            "permissions.research.network.enabled=false"]
            + disabledMCP.map { "mcp_servers.\($0).enabled=false" }
        return ["--strict-config"] + values.flatMap { ["-c", $0] }
            + disabledFeatures.flatMap { ["--disable", $0] } + ["--enable", "skip_host_skill_discovery"]
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Rejection.output }
        return value
    }
    private static func rows(_ data: Data) throws -> [[String: Any]] {
        guard data.count <= maximumStream else { throw Rejection.overflow }
        return try data.split(separator: 10).filter { !$0.isEmpty }.map { try object(Data($0)) }
    }
    private static func rpcResult(_ output: ProcessOutput) throws -> [String: Any] {
        guard output.status == 0, output.stderr.count <= 32_768 else { throw Rejection.isolation }
        let replies = try rows(output.stdout).filter { ($0["id"] as? Int) == 2 }
        guard replies.count == 1, replies[0]["error"] == nil, let result = replies[0]["result"] as? [String: Any] else { throw Rejection.isolation }
        return result
    }
    private static func flag(_ value: Any?, is expected: Bool) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue == expected
    }
    private static func nonnull(_ values: [String: Any]) -> [String: Any] { values.filter { !($0.value is NSNull) } }

    /// Only inspect whitelisted settings in memory; configuration can contain unrelated secrets.
    private static func verifyConfiguration(_ value: [String: Any], directory: URL, requireDisabledMCP: Bool) throws -> [String] {
        func absent(_ key: String) -> Bool { value[key] == nil || value[key] is NSNull }
        func empty(_ key: String) -> Bool { absent(key) || value[key] as? String == "" }
        guard value["model"] as? String == model, value["model_provider"] as? String == "openai",
              value["model_reasoning_effort"] as? String == "ultra", value["forced_login_method"] as? String == "chatgpt",
              absent("openai_base_url"), value["chatgpt_base_url"] as? String == "https://chatgpt.com/backend-api/",
              value["model_instructions_file"] as? String == directory.appendingPathComponent("instructions.md").path,
              empty("developer_instructions"), empty("instructions"), empty("compact_prompt"),
              absent("experimental_compact_prompt_file"), absent("model_catalog_json"),
              value["approval_policy"] as? String == "never", value["project_doc_max_bytes"] as? Int == 0,
              value["web_search"] as? String == "disabled", value["default_permissions"] as? String == "research",
              let features = value["features"] as? [String: Any],
              disabledFeatures.allSatisfy({ flag(features[$0], is: false) }), flag(features["skip_host_skill_discovery"], is: true),
              let memories = value["memories"] as? [String: Any], flag(memories["use_memories"], is: false), flag(memories["generate_memories"], is: false),
              let profiles = value["permissions"] as? [String: [String: Any]], let profile = profiles["research"],
              profile["extends"] == nil || profile["extends"] is NSNull,
              profile["workspace_roots"] == nil || profile["workspace_roots"] is NSNull,
              let filesystem = profile["filesystem"] as? [String: Any],
              nonnull(filesystem) as NSDictionary == [":minimal": "read", ":workspace_roots": "read"] as NSDictionary,
              let network = profile["network"] as? [String: Any], flag(network["enabled"], is: false) else { throw Rejection.isolation }
        let providers = value["model_providers"] as? [String: [String: Any]] ?? [:]
        // The built-in provider needs no custom URL, bearer source, headers or auth command.
        guard nonnull(providers["openai"] ?? [:]).isEmpty else { throw Rejection.isolation }
        let servers = value["mcp_servers"] as? [String: [String: Any]] ?? [:]
        // This CLI splits override keys on dots; quoted table components become literal quote characters.
        let nameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard servers.count <= 64, servers.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128
                && $0.unicodeScalars.allSatisfy(nameCharacters.contains) }),
              !requireDisabledMCP || servers.values.allSatisfy({ flag($0["enabled"], is: false) }) else { throw Rejection.isolation }
        return servers.keys.sorted()
    }

    static func complete(system: String, user: String, schema: Data, deadline: Date,
        allowed: @escaping @MainActor () -> Bool, executor: Executor? = nil) async -> Result<Completion, Failure> {
        guard !busy else { return .failure(.init(message: "A Codex research assessment is already running.", audit: nil)) }
        let token = generation, began = ContinuousClock.now
        func active() -> Bool { !Task.isCancelled && generation == token && allowed() && deadline.timeIntervalSinceNow > 0 }
        guard active(), deadline.timeIntervalSince1970.isFinite, !system.isEmpty, !user.isEmpty,
              system.utf8.count <= 32_768, user.utf8.count <= 65_536, schema.count <= 32_768,
              (try? object(schema)) != nil else {
            return .failure(.init(message: "Codex research was cancelled, expired, or its public input could not be verified.", audit: nil))
        }
        busy = true
        defer { busy = false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stocksage-codex-" + UUID().uuidString, isDirectory: true)
        var version = "unverified"
        func audit(_ status: String, reported: String? = nil, usage: [String: Any] = [:]) -> Audit {
            let duration = began.duration(to: .now).components
            let milliseconds = max(0, min(86_400_000, Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15))
            func count(_ key: String) -> Int? {
                guard let n = usage[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue, (0...1_000_000_000).contains(n.doubleValue) else { return nil }
                return n.intValue
            }
            return .init(requestedModel: model, requestedEffort: "ultra", reportedModel: reported, cliVersion: version,
                terminalStatus: status, systemSHA256: digest(Data(system.utf8)), userSHA256: digest(Data(user.utf8)), schemaSHA256: digest(schema),
                inputTokens: count("input_tokens"), outputTokens: count("output_tokens"), elapsedMilliseconds: Int(milliseconds))
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let systemFile = directory.appendingPathComponent("instructions.md"), schemaFile = directory.appendingPathComponent("schema.json")
            for (file, bytes) in [(systemFile, Data(system.utf8)), (schemaFile, schema)] {
                try bytes.write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            let environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin",
                               "TMPDIR": directory.path, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
            func execute(_ args: [String], input: Data = Data(), rpc: String? = nil, final: URL? = nil) async throws -> ProcessOutput {
                guard active() else { throw Rejection.interrupted }
                let invocation = Invocation(executable: executable, arguments: args, environment: environment,
                    directory: directory, input: input, deadline: rpc == nil && args.contains("exec") ? deadline : min(deadline, Date().addingTimeInterval(15)),
                    rpcMethod: rpc, finalFile: final)
                let output = try await (executor ?? { try await run($0, allowed: active) })(invocation)
                guard active() else { throw Rejection.interrupted }
                guard output.stdout.count <= maximumStream, output.stderr.count <= 32_768 else { throw Rejection.overflow }
                return output
            }
            let versionOutput = try await execute(["--version"])
            guard versionOutput.status == 0, String(data: versionOutput.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "codex-cli " + supportedVersion else { throw Rejection.unavailable }
            version = supportedVersion
            let login = try await execute(["login", "status", "-c", "forced_login_method=\"chatgpt\""])
            guard login.status == 0, String(data: login.stdout + login.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "Logged in using ChatGPT" else { throw Rejection.auth }
            let initial = try rpcResult(await execute(["app-server"] + overrides(in: directory, disabledMCP: []), rpc: "config/read"))
            guard let initialConfig = initial["config"] as? [String: Any] else { throw Rejection.isolation }
            let names = try verifyConfiguration(initialConfig, directory: directory, requireDisabledMCP: false)
            let settings = overrides(in: directory, disabledMCP: names)
            let verified = try rpcResult(await execute(["app-server"] + settings, rpc: "config/read"))
            guard let verifiedConfig = verified["config"] as? [String: Any] else { throw Rejection.isolation }
            _ = try verifyConfiguration(verifiedConfig, directory: directory, requireDisabledMCP: true)
            let catalog = try rpcResult(await execute(["app-server"] + settings, rpc: "model/list"))
            guard let models = catalog["data"] as? [[String: Any]], models.contains(where: {
                $0["model"] as? String == model && ($0["supportedReasoningEfforts"] as? [[String: Any]])?.contains(where: { $0["reasoningEffort"] as? String == "ultra" }) == true
            }) else { throw Rejection.model }
            guard try boundedFile(systemFile, maximum: 32_768) == Data(system.utf8),
                  try boundedFile(schemaFile, maximum: 32_768) == schema else { throw Rejection.isolation }
            let final = directory.appendingPathComponent("final.json")
            let output = try await execute(["exec", "--ignore-user-config"] + settings + ["--ephemeral", "--skip-git-repo-check",
                "--model", model, "--json", "--output-schema", schemaFile.path, "--output-last-message", final.path, "-"],
                input: Data(user.utf8), final: final)
            guard output.status == 0 else { throw Rejection.output }
            let events = try rows(output.stdout)
            var completed: [[String: Any]] = [], messages: [String] = [], reported: String?
            for event in events {
                if let value = event["model"] as? String {
                    guard value == model else { throw Rejection.model }; reported = value
                }
                switch event["type"] as? String {
                case "thread.started", "turn.started": break
                case "turn.completed": completed.append(event)
                case "item.started", "item.updated", "item.completed":
                    guard let item = event["item"] as? [String: Any], let kind = item["type"] as? String,
                          ["agent_message", "reasoning"].contains(kind) else { throw Rejection.output }
                    if kind == "agent_message", event["type"] as? String == "item.completed" {
                        guard let text = item["text"] as? String else { throw Rejection.output }; messages.append(text)
                    }
                default: throw Rejection.output
                }
            }
            guard completed.count == 1, events.filter({ $0["type"] as? String == "thread.started" }).count == 1,
                  events.filter({ $0["type"] as? String == "turn.started" }).count == 1,
                  events.last?["type"] as? String == "turn.completed", let message = messages.last else { throw Rejection.output }
            let data = try boundedFile(final, maximum: maximumFinal)
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty,
                  text.trimmingCharacters(in: .whitespacesAndNewlines) == message.trimmingCharacters(in: .whitespacesAndNewlines),
                  (try? object(data)) != nil else { throw Rejection.output }
            return .success(.init(text: text, audit: audit("completed", reported: reported, usage: completed[0]["usage"] as? [String: Any] ?? [:])))
        } catch {
            let reason: String
            switch error as? Rejection {
            case .auth: reason = "Codex requires an existing ChatGPT subscription sign-in. No API-key fallback was used."
            case .isolation: reason = "Codex research isolation could not be verified. No opinion was accepted."
            case .model: reason = "Codex did not verify the requested GPT-6 Astra Ultra model contract."
            case .overflow: reason = "Codex exceeded the bounded research output size. No opinion was accepted."
            case .interrupted: reason = "Codex research was cancelled or its request deadline expired."
            case .output: reason = "Codex did not finish one usable structured research response."
            default: reason = "The supported Codex CLI could not complete this research request."
            }
            return .failure(.init(message: reason, audit: audit("rejected")))
        }
    }

    static func stopAll() {
        generation = UUID()
        for process in processes.values where process.isRunning { process.terminate() }
    }

    private static func boundedFile(_ file: URL, maximum: Int) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size > 0, size <= maximum else { throw Rejection.overflow }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count == size, bytes.count <= maximum else { throw Rejection.overflow }
        return bytes
    }

    /// Pipe callbacks only collect bounded bytes. They never log CLI output or touch UI state.
    private nonisolated final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var overflow = false
        private var ended = false
        private let maximum: Int
        init(_ maximum: Int) { self.maximum = maximum }
        func append(_ bytes: Data) {
            lock.lock(); defer { lock.unlock() }
            if bytes.isEmpty { ended = true }
            if bytes.count > maximum - data.count { overflow = true }
            data.append(bytes.prefix(maximum - data.count))
        }
        func snapshot() -> (Data, Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (data, overflow, ended) }
    }

    static func run(_ invocation: Invocation, allowed: @escaping @MainActor () -> Bool) async throws -> ProcessOutput {
        guard allowed(), !Task.isCancelled, invocation.deadline > Date() else { throw Rejection.interrupted }
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        let out = Buffer(maximumStream), err = Buffer(32_768), id = UUID()
        process.executableURL = invocation.executable; process.arguments = invocation.arguments
        process.environment = invocation.environment; process.currentDirectoryURL = invocation.directory
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errors.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }
        defer {
            processes.removeValue(forKey: id)
            output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
            for handle in [input.fileHandleForWriting, output.fileHandleForReading, errors.fileHandleForReading] { try? handle.close() }
        }
        try process.run(); processes[id] = process
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        var initialized = false, requested = false, finishedRPC = false
        var pendingInput = Data(), written = 0, inputClosed = false
        let descriptor = input.fileHandleForWriting.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1, fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            throw Rejection.unavailable
        }
        func send(_ value: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: value); bytes.append(10)
            pendingInput.append(bytes)
        }
        do {
            if invocation.rpcMethod != nil {
                try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "stocksage_research", "version": "1.0"], "capabilities": ["experimentalApi": true]]])
            } else {
                pendingInput = invocation.input
            }
            while true {
                let (stdout, overflow, ended) = out.snapshot(), (_, stderrOverflow, stderrEnded) = err.snapshot()
                guard !overflow, !stderrOverflow else { throw Rejection.overflow }
                guard allowed(), !Task.isCancelled, invocation.deadline > Date() else { throw Rejection.interrupted }
                if let file = invocation.finalFile, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumFinal { throw Rejection.overflow }
                if let method = invocation.rpcMethod {
                    let lines = stdout.split(separator: 10, omittingEmptySubsequences: true)
                    for line in lines {
                        guard let value = try? object(Data(line)) else { continue }
                        if value["id"] as? Int == 1 {
                            guard value["error"] == nil, value["result"] != nil else { throw Rejection.isolation }
                            initialized = true
                        }
                        if value["id"] as? Int == 2 { finishedRPC = true }
                    }
                    if initialized, !requested {
                        try send(["method": "initialized", "params": [:]])
                        let params: [String: Any] = method == "config/read" ? ["includeLayers": false] : ["limit": 100, "includeHidden": false]
                        try send(["id": 2, "method": method, "params": params])
                        requested = true
                    }
                }
                if !inputClosed, written < pendingInput.count {
                    let count = pendingInput.withUnsafeBytes { bytes in
                        Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), min(4096, bytes.count - written))
                    }
                    if count > 0 { written += count }
                    else if count < 0, errno != EAGAIN, errno != EINTR { throw Rejection.output }
                }
                if !inputClosed, written == pendingInput.count, invocation.rpcMethod == nil || finishedRPC {
                    try input.fileHandleForWriting.close(); inputClosed = true
                }
                if !process.isRunning, ended, stderrEnded {
                    return .init(status: process.terminationStatus, stdout: stdout, stderr: err.snapshot().0)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            if process.isRunning {
                process.terminate()
                // This short cleanup wait must still run when the parent Task is cancelled.
                await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                let cleanupDeadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < cleanupDeadline {
                    await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
                }
            }
            throw error
        }
    }
    #endif
}
