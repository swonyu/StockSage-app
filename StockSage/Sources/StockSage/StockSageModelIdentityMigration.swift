import Foundation

/// One-time migration for a saved Qwen managed-profile setting (Qwen removal Step 6).
///
/// Fail-closed alone is not what actually happens after Step 5: a persisted
/// `localModelServerModel == "qwen3.5-9b"` at `127.0.0.1:1234` still produces a valid `Config`
/// (the model is free text, only trimmed and <=512 bytes), but it no longer satisfies the
/// deleted managed-profile check, so `requiresStrictOutput` silently goes false -- disabling the
/// `response_format` schema, the truncated-verdict rejection, the post-response context gate, the
/// fail-closed identity check, the doubled output reservation and its retry, and the managed half
/// of the quit-unload guard, ALL AT ONCE, while `probe()` still reports "reachable" through the
/// generic OpenAI-compatible fallback. That is fail-OPEN -- the single most dangerous outcome of
/// this whole change. `Config.isRetiredManagedIdentity` closes that hole as a backstop; this
/// migration exists so a real owner setting moves forward instead of relying on the backstop
/// alone to explain what happened.
enum StockSageModelIdentityMigration {
    static let markerKey = "stocksage.modelSettings.migratedTo"
    static let inProgress = "gemma-4-31b-qat.v1.inProgress"
    static let done = "gemma-4-31b-qat.v1"

    /// Called once from `StockSageApp.init()`, guarded the same way as
    /// `StockSageMassiveCredential.beginLaunch` -- never from `applicationDidFinishLaunching`,
    /// which runs in the XCTest host and would rewrite the owner's real `UserDefaults.standard`
    /// during `xcodebuild test`.
    static func migrate(defaults: UserDefaults) {
        typealias S = StockSageLocalModelServer
        guard defaults.string(forKey: markerKey) != done else { return }
        guard let savedModel = defaults.string(forKey: S.modelKey) else {
            // A fresh install has no saved model at all; it gets the new default constant and
            // must never be marked unmigrated.
            defaults.set(done, forKey: markerKey)
            return
        }
        let trimmed = savedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasSuffix(":latest") ? String(trimmed.dropLast(":latest".count)) : trimmed
        let savedURL = defaults.string(forKey: S.urlKey) ?? ""
        // A previous run that wrote the model half but crashed before the URL half looks like
        // "already on gemmaModel" -- detect that half-migrated state by checking whether the
        // saved URL is actually one of the two endpoints this migration would have produced.
        let isHalfMigrated = stripped == S.gemmaModel && !isManagedGemmaEndpoint(savedURL)
        guard S.retiredManagedIdentities.contains(stripped) || isHalfMigrated else {
            // Not a retired identity and not a half-migrated one: a deliberate choice (including
            // an already-correct Gemma setting) is never overridden.
            defaults.set(done, forKey: markerKey)
            return
        }
        defaults.set(inProgress, forKey: markerKey)
        let destinationURL = isManagedGemmaEndpoint(savedURL) ? savedURL : S.lmStudioURL
        // Model first, then URL: URL-first would transiently produce the retired model paired
        // with the new URL, which is a worse intermediate state than the one being migrated away
        // from. Because the destination is a pure function of the ORIGINAL saved pair (read
        // above, not re-read here), re-running this after a crash between these two writes always
        // recomputes the same destination and completes correctly.
        S.setSetting(S.gemmaModel, for: S.modelKey, defaults: defaults)
        S.setSetting(destinationURL, for: S.urlKey, defaults: defaults)
        defaults.set(done, forKey: markerKey)
    }

    private static func isManagedGemmaEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return StockSageLocalModelServer.isLoopback(url) && url.port.map { [1234, 18080].contains($0) } == true
    }
}
