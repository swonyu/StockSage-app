import Foundation

/// Controls whether external/non-local tools are allowed.
/// Default = .localOnly to maintain the local-first philosophy.
///
/// `current` is derived from the user's web-access Settings toggle on each
/// read, so flipping the switch and starting a new chat is enough to retire or
/// surface the web tools. Set it explicitly to force a mode for testing.
enum ToolPolicy {
    case localOnly
    case allowExternalTools

    /// Mutable override. `nil` (the default) means "read from user settings".
    /// Set to a concrete case to force-pin the policy regardless of settings.
    nonisolated(unsafe) static var override: ToolPolicy? = nil

    /// The policy in effect right now. Computed from `override` if set,
    /// otherwise from the user's web-access toggle in Settings.
    nonisolated static var current: ToolPolicy {
        if let override { return override }
        return isWebAccessEnabled ? .allowExternalTools : .localOnly
    }

    // MARK: - Setting accessors (nonisolated, actor-safe)

    nonisolated static var isWebAccessEnabled: Bool {
        AppSettings.boolDefaultTrue(AppSettings.Keys.webAccess)
    }

    // Pre-computed predicate to avoid `==` on `ToolPolicy` from nonisolated
    // contexts (which would drag the main-actor Equatable conformance across
    // the actor boundary — a Swift-6 error).
    nonisolated static var isExternalAllowed: Bool {
        // Offline Mode is the STRONGER constraint: it short-circuits even if
        // the user has `webAccess` on (or a test override pins `.allowExternalTools`).
        // Net effect: with offline ON, the model never sees `web_search` /
        // `fetch_url` in its tool list and the instructions menu announces them
        // as disabled — no chance of accidentally going to the network.
        if AppSettings.isOfflineOnly { return false }
        switch current {
        case .allowExternalTools: return true
        case .localOnly:          return false
        }
    }

    /// Returns the exact user- and model-facing refusal string when web tools
    /// are disabled by policy (webAccess off or Offline Mode), or nil when
    /// allowed. Single source of truth for the two reasons + Offline precedence.
    /// Callers (WebSearchTool, FetchURLTool, Ollama executor) should use:
    ///   guard ToolPolicy.isExternalAllowed else { return ToolPolicy.webToolsDisabledReason() ?? "..." }
    /// This eliminates the prior 3-site string drift (FM tools vs. Ollama vs. menu)
    /// while preserving every observable message byte-for-byte.
    nonisolated static func webToolsDisabledReason() -> String? {
        guard !isExternalAllowed else { return nil }
        if AppSettings.isOfflineOnly {
            return "Offline Mode is on — web access is disabled."
        } else {
            return "Web access is turned off in Settings."
        }
    }

    // MARK: - Command risk vocabulary (single source of truth)

    /// Centralized blocked vs. risky command markers. Documents the two-tier
    /// model: blocked ⊂ outright refused (before approval UI); risky ⊂ always
    /// re-confirm even under "Always run" session bypass.
    /// Source lists live here so ShellTool + CommandApprovalCenter + future
    /// places (e.g. audit, docs) stay in sync; adding "npm publish" or tightening
    /// ">" no longer requires editing 3 places.
    nonisolated enum CommandRisk {
        /// Dangerous operations/paths matched *anywhere* in the command (catches
        /// chains like "foo; rm -rf /" and path prefixes after lowercasing).
        static let blockedSubstrings: [String] = [
            "rm -rf /", "rm -rf /*", "rm -rf ~", "rm -rf ~/", "rm -fr /", "rm -rf .", "rm -rf *",
            ":(){", "fork()",
            "mkfs", "diskutil erasedisk", "diskutil erasevolume", "diskutil reformat",
            "diskutil partitiondisk", "dd if=", "of=/dev/",
            "/dev/disk", "/dev/rdisk", "/dev/sd", "> /dev/", ">/dev/",
            "> /etc/", ">/etc/", "csrutil disable", "spctl --master-disable", "nvram ",
            "chmod -r 000", "chmod 000", "chmod -r ", "chown -r", "chgrp -r",
        ]

        /// Destructive command *names* (leading token after path-strip, per
        /// ;|&|\n\r` segment). "eval"/"exec"/"source" close the variable bypass.
        static let blockedLeadingCommands: Set<String> = [
            "shutdown", "reboot", "halt", "poweroff",
            "sudo", "su", "doas",
            "killall", "mkfs", "fdisk", "newfs_apfs", "newfs_hfs", "diskutil",
            "eval", "exec", "source", "launchctl", "chgrp",
        ]

        /// Markers for commands that mutate/destroy/escalate/exfiltrate. These
        /// always force a re-confirmation even if the user hit "Always run" for the
        /// session. `looksRisky` is the ONLY gate on that bypass path, so this is a
        /// deliberately broad DENYLIST: over-confirming a benign command is a minor
        /// annoyance, but UNDER-confirming a destructive one is a security hole.
        /// (A truly safe-only gate would be an allowlist — a bigger UX change;
        /// tracked in the 2026-06-06 review. Until then we keep widening this.)
        static let riskyMarkers: [String] = [
            // delete / move / truncate / format
            "rm ", "rmdir", "mv ", "trash", "delete", "truncate", "format",
            // ANY output redirect: ">" subsumes ">>", " > ", and the bare "x>file"
            // form (writing a file — even a dotfile like ~/.zshrc — re-confirms).
            ">",
            // privilege / ownership / permissions
            "sudo", "doas", "chmod", "chown", "chgrp",
            // process control / destructive git
            "kill ", "killall", "git push", "git reset --hard", "git clean",
            // direct interpreter exec (arbitrary code): `python -c`, `node -e`, `sh -c`, …
            "python -c", "python3 -c", "node -e", "ruby -e", "perl -e", "php -r",
            "bash -c", "sh -c", "zsh -c", "osascript",
            // file copy / symlink / remote copy / fetch (overwrite + exfil building blocks)
            "tee ", "cp ", "ln ", "scp ", "ditto ", "curl ", "wget ",
            // persistence / system configuration
            "defaults write", "crontab", "launchctl", "systemsetup",
            // SwiftPM commands that MUTATE project structure: an agent ran
            // `swift package init` + `swift build` inside the Xcode source folder
            // and broke the build (a stray Package.swift + .build bundled as
            // resources, 2026-06-08). Force approval so it can't happen silently.
            "swift package", "swift build", "swift test",
        ]

        /// **Allowlist (additive safe fast-path).** Provably read-only command
        /// *names*: under NO flag combination can any of these mutate the
        /// filesystem, change permissions/ownership, kill processes, escalate
        /// privileges, run another program, or reach the network. A command made
        /// up ENTIRELY of these — across every chained segment, with no risky
        /// markers, redirects, command substitution, or pipe-into-interpreter —
        /// is safe to run without an approval prompt (see `isDefinitelySafe`).
        ///
        /// This is the allowlist the 2026-06-06 review called for: it only ever
        /// REDUCES prompts for the inspection commands the model runs constantly
        /// (`ls`/`cat`/`grep`/`stat`…), which keeps the real approval prompts
        /// meaningful instead of drowned in `ls` confirmations. It NEVER grants
        /// anything — `Shell.isBlocked` already ran — and any doubt falls through
        /// to the normal gate. Deliberately conservative: `git`/`find`/`sort`/`env`
        /// are OMITTED because some of their forms write, exec, or escalate.
        static let safeLeadingCommands: Set<String> = [
            "ls", "pwd", "echo", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep",
            "which", "whoami", "id", "date", "cal", "hostname", "uname", "arch",
            "df", "du", "file", "stat", "basename", "dirname", "realpath",
            "tree", "uptime", "sw_vers", "ps", "diff", "cmp", "nl", "cut",
        ]

        /// Shell features that can smuggle a second, unvetted command past the
        /// per-segment token check (command/process substitution, parameter
        /// expansion). Their presence forces the normal approval path. (`>`/`<`
        /// redirects are already covered: `>` is a risky marker and triggers
        /// `looksRisky`; input `<` can only re-read a file, still read-only.)
        private static let intentHiders: [String] = ["$(", "${", "`", "<(", ">("]

        /// True only when EVERY chained segment's leading token is in
        /// `safeLeadingCommands` AND the command carries no risky markers,
        /// command/process substitution, or pipe-into-interpreter. A single
        /// unrecognized token or risk signal → false (re-confirm). Pure +
        /// nonisolated, like `looksRisky`, so the same actor-safety/determinism
        /// contracts hold and it can be unit-tested directly.
        static func isDefinitelySafe(_ command: String) -> Bool {
            let lower = command.lowercased()
            // Any risk signal (">", "rm ", sudo, `… | sh`, …) disqualifies first.
            if looksRisky(lower) { return false }
            if intentHiders.contains(where: lower.contains) { return false }
            // Operator-aware split (mirrors `isBlocked`): collapse two-char
            // operators to a sentinel, then split on the control operators so
            // every segment's leading token gets checked.
            let sep = "\u{0}"
            let normalized = lower
                .replacingOccurrences(of: "&&", with: sep)
                .replacingOccurrences(of: "||", with: sep)
                .replacingOccurrences(of: "|&", with: sep)
            let segments = normalized.components(separatedBy: CharacterSet(charactersIn: ";|&\n\r`" + sep))
            var sawCommand = false
            for raw in segments {
                let segment = raw.trimmingCharacters(in: .whitespaces)
                if segment.isEmpty { continue }
                guard let firstToken = segment.split(separator: " ").first else { return false }
                let name = firstToken.split(separator: "/").last.map(String.init) ?? String(firstToken)
                guard safeLeadingCommands.contains(name) else { return false }
                sawCommand = true
            }
            return sawCommand   // false for an all-empty command (nothing to run)
        }

        /// Interpreters that, on the RECEIVING end of a pipe, mean "execute whatever
        /// was just produced" — i.e. `curl … | sh` / `… |bash` (remote/arbitrary
        /// code execution). Matched spacing-independently by `pipesIntoInterpreter`.
        private static let pipedInterpreters: Set<String> = [
            "sh", "bash", "zsh", "ksh", "fish", "python", "python3",
            "node", "ruby", "perl", "php", "osascript", "tclsh",
        ]

        /// Returns the matched blocked token (for the REFUSED message) or nil.
        /// Two-layer: substrings anywhere, then leading-token (path-stripped) against the Set.
        static func isBlocked(_ command: String) -> String? {
            let lower = command.lowercased()
            for pattern in blockedSubstrings where lower.contains(pattern) {
                return pattern
            }
            // Operator-aware split: collapse the TWO-char operators (&&, ||, |&)
            // to a single sentinel FIRST, so `&&` isn't mis-parsed as a doubled
            // single `&` (which left spurious empty segments). Then split on the
            // remaining control operators. `&&` (and) and `&` (background) both
            // separate commands, so every segment's leading token is still checked.
            let sep = "\u{0}"
            let normalized = lower
                .replacingOccurrences(of: "&&", with: sep)
                .replacingOccurrences(of: "||", with: sep)
                .replacingOccurrences(of: "|&", with: sep)
            let segments = normalized.components(separatedBy: CharacterSet(charactersIn: ";|&\n\r`" + sep))
            for raw in segments {
                let segment = raw.trimmingCharacters(in: .whitespaces)
                guard let firstToken = segment.split(separator: " ").first else { continue }
                let name = firstToken.split(separator: "/").last.map(String.init) ?? String(firstToken)
                if blockedLeadingCommands.contains(name) { return name }
            }
            return nil
        }

        /// True for commands that should re-confirm even under sessionBypass.
        /// Pure + nonisolated (no Date/random/shared state) — the determinism and
        /// actor-safety contracts are locked by `LooksRiskyDelegationTests`.
        static func looksRisky(_ command: String) -> Bool {
            let l = command.lowercased()
            if riskyMarkers.contains(where: { l.contains($0) }) { return true }
            return pipesIntoInterpreter(l)
        }

        /// Detects piping into a shell/interpreter regardless of spacing, e.g.
        /// `curl x | sh`, `wget y |bash`, `cat z | python3 -`. Splits on a single
        /// `|` (the `||` OR-operator is neutralized first) and checks each
        /// downstream segment's leading (path-stripped) token.
        private static func pipesIntoInterpreter(_ lower: String) -> Bool {
            let sentinel = "\u{0}"
            let segments = lower
                .replacingOccurrences(of: "||", with: sentinel)
                .components(separatedBy: "|")
            for seg in segments.dropFirst() {
                let trimmed = seg.trimmingCharacters(in: .whitespaces)
                guard let first = trimmed.split(separator: " ").first else { continue }
                let name = first.split(separator: "/").last.map(String.init) ?? String(first)
                if pipedInterpreters.contains(name) { return true }
            }
            return false
        }
    }
}
