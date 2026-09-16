import Foundation
import Testing
@testable import StockSage

// Qwen removal Step 6: the one-time migration for a saved Qwen managed-profile setting, plus its
// fail-closed backstop (Config.isRetiredManagedIdentity). Every case uses an injected
// UserDefaults(suiteName:) with removePersistentDomain in defer, per the repo convention -- never
// UserDefaults.standard, which would touch this machine's real settings.
@Suite("Model identity migration (Qwen removal Step 6)")
struct StockSageModelIdentityMigrationTests {
    typealias S = StockSageLocalModelServer
    typealias Migration = StockSageModelIdentityMigration

    private func suite(_ name: String) -> (UserDefaults, () -> Void) {
        let id = "ModelIdentityMigration.\(name).\(UUID())"
        let defaults = UserDefaults(suiteName: id)!
        return (defaults, { defaults.removePersistentDomain(forName: id) })
    }

    @Test func retiredLMStudioIdentityMigratesModelOnlyAndKeepsItsEndpoint() {
        let (defaults, cleanup) = suite(#function); defer { cleanup() }
        defaults.set("qwen3.5-9b", forKey: S.modelKey)
        defaults.set(S.lmStudioURL, forKey: S.urlKey)
        Migration.migrate(defaults: defaults)
        #expect(defaults.string(forKey: S.modelKey) == S.gemmaModel)
        #expect(defaults.string(forKey: S.urlKey) == S.lmStudioURL)
        #expect(defaults.string(forKey: Migration.markerKey) == Migration.done)
    }

    @Test func retiredOllamaIdentityMovesToTheManagedLMStudioProfile() {
        let (defaults, cleanup) = suite(#function); defer { cleanup() }
        defaults.set("qwen3.8", forKey: S.modelKey)
        defaults.set("http://127.0.0.1:11434", forKey: S.urlKey)
        Migration.migrate(defaults: defaults)
        #expect(defaults.string(forKey: S.modelKey) == S.gemmaModel)
        #expect(defaults.string(forKey: S.urlKey) == S.lmStudioURL)
        #expect(defaults.string(forKey: Migration.markerKey) == Migration.done)
    }

    @Test func aDeliberateNonRetiredModelIsNeverRewritten() {
        let (defaults, cleanup) = suite(#function); defer { cleanup() }
        defaults.set("owners-custom-model", forKey: S.modelKey)
        defaults.set("http://192.168.1.5:8000", forKey: S.urlKey)
        Migration.migrate(defaults: defaults)
        #expect(defaults.string(forKey: S.modelKey) == "owners-custom-model")
        #expect(defaults.string(forKey: S.urlKey) == "http://192.168.1.5:8000")
        #expect(defaults.string(forKey: Migration.markerKey) == Migration.done)

        // Already correct, deliberate Gemma settings are also left alone.
        let (defaults2, cleanup2) = suite(#function + ".gemma"); defer { cleanup2() }
        defaults2.set(S.gemmaModel, forKey: S.modelKey)
        defaults2.set(S.runPodURL, forKey: S.urlKey)
        Migration.migrate(defaults: defaults2)
        #expect(defaults2.string(forKey: S.modelKey) == S.gemmaModel)
        #expect(defaults2.string(forKey: S.urlKey) == S.runPodURL)
    }

    @Test func migrationRunsOnceAndDoesNotStompALaterOwnerChoice() {
        let (defaults, cleanup) = suite(#function); defer { cleanup() }
        defaults.set("qwen3.5-9b", forKey: S.modelKey)
        defaults.set(S.lmStudioURL, forKey: S.urlKey)
        Migration.migrate(defaults: defaults)
        #expect(defaults.string(forKey: S.modelKey) == S.gemmaModel)
        // The owner deliberately switches away afterward.
        defaults.set("http://127.0.0.1:11434", forKey: S.urlKey)
        defaults.set("owners-later-choice", forKey: S.modelKey)
        Migration.migrate(defaults: defaults)
        #expect(defaults.string(forKey: S.modelKey) == "owners-later-choice",
                "A completed migration must never re-run and overwrite a later owner choice")
        #expect(defaults.string(forKey: S.urlKey) == "http://127.0.0.1:11434")
    }

    @Test func migrationBumpsTheSettingsRevision() {
        let (defaults, cleanup) = suite(#function); defer { cleanup() }
        defaults.set("qwen3.5-9b", forKey: S.modelKey)
        defaults.set(S.lmStudioURL, forKey: S.urlKey)
        let before = S.settingsRevision(defaults)
        Migration.migrate(defaults: defaults)
        #expect(S.settingsRevision(defaults) != before,
                "In-flight requests must be invalidated by a migration that changes the model")
    }

    @Test func anInterruptedMigrationCompletesOnTheNextLaunch() {
        let (defaults, cleanup) = suite(#function); defer { cleanup() }
        // Simulates a crash between the model write and the URL write: model already moved to
        // Gemma, marker still inProgress, URL still the pre-migration Ollama default.
        defaults.set(Migration.inProgress, forKey: Migration.markerKey)
        defaults.set(S.gemmaModel, forKey: S.modelKey)
        defaults.set("http://127.0.0.1:11434", forKey: S.urlKey)
        Migration.migrate(defaults: defaults)
        #expect(defaults.string(forKey: S.modelKey) == S.gemmaModel)
        #expect(defaults.string(forKey: S.urlKey) == S.lmStudioURL,
                "The interrupted run must still complete to the destination its original pair implied")
        #expect(defaults.string(forKey: Migration.markerKey) == Migration.done)
    }

    @Test func migrationNeverEnablesAutomaticStartupOrChangesTheBackend() {
        let (defaults, cleanup) = suite(#function); defer { cleanup() }
        defaults.set("qwen3.5-9b", forKey: S.modelKey)
        defaults.set(S.lmStudioURL, forKey: S.urlKey)
        #expect(defaults.object(forKey: StockSageLocalModelStartup.enabledKey) == nil)
        #expect(defaults.object(forKey: S.backendKey) == nil)
        Migration.migrate(defaults: defaults)
        #expect(defaults.object(forKey: StockSageLocalModelStartup.enabledKey) == nil,
                "Auto-loading a 31B at launch stays the opt-in it is today")
        #expect(defaults.object(forKey: S.backendKey) == nil)
    }

    @Test func retiredQwenIdentitiesAreRefusedOnManagedPortsAndStillAllowedElsewhere() async throws {
        for (url, model) in [(S.lmStudioURL, "qwen3.5-9b"), (S.runPodURL, "qwen3.8"),
                             (S.lmStudioURL, "qwen3.8:latest")] {
            let config = try #require(S.config(url: url, model: model))
            #expect(config.isRetiredManagedIdentity, "\(model) @ \(url) must be refused")
            let probe = await S.probe(config)
            #expect(!probe.hasModel && probe.detail.contains("Qwen managed profile was removed"))
        }
        // Scope is deliberate: on :11434 or any other endpoint, a Qwen model remains a perfectly
        // serveable generic model -- no strict-output guarantee was ever claimed there.
        for (url, model) in [("http://127.0.0.1:11434", "qwen3.8"), ("http://127.0.0.1:11434", "qwen3.5-9b"),
                             ("http://fixture.invalid:1234", "qwen3.5-9b")] {
            let config = try #require(S.config(url: url, model: model))
            #expect(!config.isRetiredManagedIdentity, "\(model) @ \(url) must stay generic")
        }
    }
}
