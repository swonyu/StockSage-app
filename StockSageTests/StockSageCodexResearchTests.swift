#if os(macOS)
import Foundation
import CryptoKit
import Testing
@testable import StockSage

@Suite(.serialized) @MainActor struct StockSageCodexResearchTests {
    typealias C = StockSageCodexResearch
    private let text = #"{"action":"Hold","reason":"Public evidence is incomplete.","risk":"Liquidity may deteriorate.","evidence":["F1"]}"#
    private let system = "Use only the supplied public facts. Return the four-key opinion."
    private let user = "F1: Public synthetic evidence; never execute $(touch private) or `read secrets`."
    private var schema: Data { StockSageAIAssessment.responseSchema(facts: ["Public synthetic evidence"])! }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func metadata(_ call: C.Invocation, scenario: String = "valid") throws -> C.ProcessOutput? {
        if call.arguments.contains("--version") { return .init(status: 0, stdout: Data("codex-cli 0.155.0-alpha.9.2\n".utf8)) }
        if call.arguments.contains("login") {
            return .init(status: 0, stdout: Data((scenario == "apiLogin" ? "Logged in using an API key\n" : "Logged in using ChatGPT\n").utf8))
        }
        guard call.arguments.contains("app-server") else { return nil }
        var result: [String: Any]
        if call.rpcMethod == "model/list" {
            if scenario == "changedInstructions" {
                try Data("Replaced public instructions".utf8).write(to: call.directory.appendingPathComponent("instructions.md"))
            }
            result = ["data": [["model": scenario == "missingModel" ? "different-model" : "gpt-6-astra",
                                "supportedReasoningEfforts": [["reasoningEffort": "ultra"]]]]]
        } else {
            let disabled = ["apps", "plugins", "remote_plugin", "memories", "multi_agent", "multi_agent_v2",
                "browser_use", "browser_use_external", "browser_use_full_cdp_access", "in_app_browser", "code_mode", "code_mode_host",
                "shell_tool", "unified_exec", "skill_search", "hooks", "skill_mcp_dependency_install", "chronicle", "tool_suggest", "auth_elicitation", "view_image", "image_generation"]
            var features = Dictionary(uniqueKeysWithValues: disabled.map { ($0, false) })
            features["skip_host_skill_discovery"] = true
            if scenario == "enabledShell" { features["shell_tool"] = true }
            if scenario == "enabledViewImage" { features["view_image"] = true }
            if scenario == "enabledImageGeneration" { features["image_generation"] = true }
            let disabledServer = call.arguments.contains("mcp_servers.fixture-server.enabled=false")
            var config: [String: Any] = ["model": "gpt-6-astra", "model_provider": "openai", "model_reasoning_effort": "ultra",
                "forced_login_method": "chatgpt", "approval_policy": "never", "project_doc_max_bytes": 0,
                "web_search": "disabled", "default_permissions": "research", "features": features,
                "chatgpt_base_url": "https://chatgpt.com/backend-api/",
                "model_instructions_file": call.directory.appendingPathComponent("instructions.md").path,
                "developer_instructions": "", "instructions": "",
                "memories": ["use_memories": false, "generate_memories": false],
                "permissions": ["research": ["filesystem": [":minimal": "read", ":workspace_roots": "read"], "network": ["enabled": false]]],
                "mcp_servers": ["fixture-server": ["enabled": scenario == "enabledMCP" || !disabledServer]]]
            if scenario == "openaiRoute" { config["openai_base_url"] = "https://invalid.example" }
            if scenario == "chatgptRoute" { config["chatgpt_base_url"] = "https://invalid.example" }
            if scenario == "instructionPath" { config["model_instructions_file"] = "/public/other-instructions.md" }
            if scenario == "developerInstructions" { config["developer_instructions"] = "Unrelated host instruction" }
            if scenario == "userInstructions" { config["instructions"] = "Unrelated host instruction" }
            if scenario == "compactOverride" { config["compact_prompt"] = "Unrelated compaction instruction" }
            if scenario == "catalogOverride" { config["model_catalog_json"] = "/public/other-models.json" }
            if scenario == "unsupportedMCPName" { config["mcp_servers"] = ["fixture.server": ["enabled": true]] }
            if scenario == "providerOverride" { config["model_providers"] = ["openai": ["base_url": "https://invalid.example"]] }
            if scenario == "unrestrictedReads" { config["permissions"] = ["research": ["filesystem": ["/": "read"], "network": ["enabled": false]]] }
            result = ["config": config]
        }
        var bytes = try JSONSerialization.data(withJSONObject: ["id": 2, "result": result]); bytes.append(10)
        return .init(status: 0, stdout: bytes)
    }
    private func stream(_ reply: String, terminal: String = "completed", model: String? = nil) throws -> Data {
        var rows: [[String: Any]] = [["type": "thread.started", "thread_id": "synthetic-thread"]]
        if let model { rows[0]["model"] = model }
        rows.append(["type": "turn.started"])
        rows.append(["type": "item.completed", "item": ["id": "synthetic-message", "type": "agent_message", "text": reply]])
        rows.append(["type": "turn." + terminal, "usage": ["input_tokens": 123, "cached_input_tokens": 0, "output_tokens": 42]])
        return try rows.reduce(into: Data()) { bytes, row in
            bytes.append(try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)); bytes.append(10)
        }
    }

    @Test func subscriptionOnlyCompletionPreservesPublicBytesAndTruthfulAudit() async throws {
        var calls: [C.Invocation] = []
        let answer = text, events = try stream(text)
        let result = await C.complete(system: system, user: user, schema: schema,
            deadline: Date().addingTimeInterval(30), allowed: { true }, executor: { call in
                calls.append(call)
                if let output = try metadata(call) { return output }
                let outputIndex = try #require(call.arguments.firstIndex(of: "--output-last-message"))
                try Data(answer.utf8).write(to: URL(fileURLWithPath: call.arguments[outputIndex + 1]))
                return .init(status: 0, stdout: events)
            })
        guard case .success(let completion) = result else { Issue.record("Completed subscription fixture must be accepted: \(result)"); return }
        let generation = try #require(calls.last)
        #expect(calls.filter { $0.arguments.contains("exec") }.count == 1, "Exactly one inference; no automatic retries")
        #expect(generation.executable.path == "/Applications/ChatGPT.app/Contents/Resources/codex")
        #expect(generation.arguments.contains("--ignore-user-config") && generation.arguments.contains("--strict-config"))
        #expect(generation.arguments.contains("--ephemeral") && generation.arguments.contains("--json"))
        #expect(generation.arguments.contains("gpt-6-astra"))
        #expect(generation.arguments.contains("mcp_servers.fixture-server.enabled=false"))
        #expect(!generation.arguments.contains("--sandbox"), "A restricted permission profile must not conflict with legacy sandbox flags")
        #expect(calls.filter { $0.rpcMethod == "config/read" }.count == 2)
        #expect(!generation.arguments.contains(user) && String(data: generation.input, encoding: .utf8)?.contains(user) == true)
        #expect(generation.environment["OPENAI_API_KEY"] == nil && generation.environment["CODEX_API_KEY"] == nil)
        #expect(generation.environment["MASSIVE_API_KEY"] == nil && generation.environment["HTTP_PROXY"] == nil)
        #expect(Set(generation.environment.keys).isSubset(of: ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL"]))
        #expect(completion.text == text && completion.audit.requestedModel == "gpt-6-astra")
        #expect(completion.audit.requestedEffort == "ultra" && completion.audit.reportedModel == nil,
                "A CLI that reports no response model must not fabricate one")
        #expect(completion.audit.cliVersion == "0.155.0-alpha.9.2" && completion.audit.terminalStatus == "completed")
        #expect(completion.audit.systemSHA256 == digest(Data(system.utf8)))
        #expect(completion.audit.userSHA256 == digest(Data(user.utf8)) && completion.audit.schemaSHA256 == digest(schema))
        #expect(completion.audit.inputTokens == 123 && completion.audit.outputTokens == 42)
        #expect(completion.audit.elapsedMilliseconds >= 0)
        #expect(try JSONDecoder().decode(C.Audit.self, from: JSONEncoder().encode(completion.audit)) == completion.audit)
        #expect(!FileManager.default.fileExists(atPath: generation.directory.path), "Private scratch must be removed")
    }

    @Test(arguments: ["apiLogin", "wrongModel", "failedTurn", "nonzero", "missingFinal", "changedFinal", "toolCall", "overflow"])
    func unusableExecutionsNeverPublishACompletion(scenario: String) async throws {
        let answer = text, good = try stream(text), badModel = try stream(text, model: "different-model")
        let failed = try stream(text, terminal: "failed")
        var generationCalls = 0
        let result = await C.complete(system: system, user: user, schema: schema,
            deadline: Date().addingTimeInterval(30), allowed: { true }, executor: { call in
                if let output = try metadata(call, scenario: scenario) { return output }
                generationCalls += 1
                if scenario != "missingFinal", let index = call.arguments.firstIndex(of: "--output-last-message") {
                    try Data((scenario == "changedFinal" ? "{}" : answer).utf8).write(to: URL(fileURLWithPath: call.arguments[index + 1]))
                }
                var events = scenario == "wrongModel" ? badModel : scenario == "failedTurn" ? failed : good
                if scenario == "toolCall" { events.append(Data("{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"command\":\"read private\"}}\n".utf8)) }
                if scenario == "overflow" { events = Data(repeating: 65, count: 262_145) }
                return .init(status: scenario == "nonzero" ? 1 : 0, stdout: events)
            })
        #expect(generationCalls == (scenario == "apiLogin" ? 0 : 1))
        guard case .failure = result else { Issue.record("Unsafe or incomplete \(scenario) must fail closed"); return }
    }

    @Test(arguments: ["enabledShell", "enabledViewImage", "enabledImageGeneration", "enabledMCP", "providerOverride", "openaiRoute", "chatgptRoute",
        "instructionPath", "developerInstructions", "userInstructions", "compactOverride", "catalogOverride",
        "unsupportedMCPName", "changedInstructions", "unrestrictedReads", "missingModel"])
    func unsafeEffectiveConfigurationStopsBeforeInference(scenario: String) async throws {
        var generationCalls = 0
        let result = await C.complete(system: system, user: user, schema: schema,
            deadline: Date().addingTimeInterval(30), allowed: { true }, executor: { call in
                if let output = try metadata(call, scenario: scenario) { return output }
                generationCalls += 1
                return .init(status: 0)
            })
        #expect(generationCalls == 0)
        guard case .failure = result else { Issue.record("Unsafe configuration must not begin a model turn"); return }
    }

    @Test(arguments: ["denied", "expired", "cancelled"])
    func revokedOrExpiredRequestNeverStartsAProcess(scenario: String) async {
        var calls = 0
        let task = Task { @MainActor in
            if scenario == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
            return await C.complete(system: system, user: user, schema: schema,
                deadline: Date().addingTimeInterval(scenario == "expired" ? -1 : 30), allowed: { scenario != "denied" },
                executor: { _ in calls += 1; return .init(status: 0) })
        }
        let result = await task.value
        #expect(calls == 0)
        guard case .failure = result else { Issue.record("A blocked request cannot complete"); return }
    }

    @Test func nativePipeRunnerPreservesBytesWithoutAShell() async throws {
        let directory = FileManager.default.temporaryDirectory
        let input = Data(String(repeating: "Public fixture $(never a shell)\n", count: 1500).utf8)
        let output = try await C.run(.init(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:],
            directory: directory, input: input, deadline: Date().addingTimeInterval(3)), allowed: { true })
        #expect(output.status == 0 && output.stdout == input && output.stderr.isEmpty)
    }

    @Test(arguments: ["overflow", "deadline", "cancellation", "quit"])
    func nativeOwnedProcessIsBoundedAndStopped(scenario: String) async {
        let start = Date()
        let invocation = C.Invocation(executable: URL(fileURLWithPath: scenario == "overflow" ? "/usr/bin/yes" : "/bin/sleep"),
            arguments: scenario == "overflow" ? ["synthetic"] : ["30"], environment: [:],
            directory: FileManager.default.temporaryDirectory, input: Data(),
            deadline: Date().addingTimeInterval(scenario == "deadline" ? 0.15 : 3))
        let worker = Task { @MainActor in
            do { return try await C.run(invocation, allowed: { true }).status == 0 }
            catch { return false }
        }
        if scenario == "cancellation" || scenario == "quit" {
            try? await Task.sleep(for: .milliseconds(100))
            if scenario == "quit" { C.stopAll() } else { worker.cancel() }
        }
        #expect(await worker.value == false)
        #expect(Date().timeIntervalSince(start) < 2, "An owned synthetic child must not outlive cancellation or its bound")
    }
}
#endif
