import Foundation

// MARK: - Where Claude Code keeps its OAuth credentials — pure core
//
// Claude Code names its Keychain item `Claude Code-credentials`, but ONLY when
// `CLAUDE_CONFIG_DIR` is unset. Once that env var is set — even to the default
// `~/.claude` — it appends `-<first 8 hex of sha256(NFC(configDir))>`, e.g.
// `Claude Code-credentials-13f379c8`. The plaintext fallback likewise lives at
// `<configDir>/.credentials.json`.
//
// A GUI app launched from Dock / login items never sees the shell's
// `CLAUDE_CONFIG_DIR`, so we can't know which naming Claude Code used. We
// therefore probe every plausible item and take the most recently modified
// one: the item the active login writes to (login + token refreshes) is the
// freshest, while a stale unsuffixed item left by an earlier login (often a
// different account) loses. Before this, the hard-coded unsuffixed name
// silently read the stale account's quota — or nothing.
//
// Pure: the SHA-256 and the `security` spawning are injected / live in
// CredentialStore + KeychainCLI (QuotaService.swift).
enum CredentialLocator {
    static let baseService = "Claude Code-credentials"

    /// Config dirs Claude Code may be using, in tie-break priority order:
    /// the env var (if this process has it), then the default `~/.claude`.
    static func candidateConfigDirs(envConfigDir: String?, home: String) -> [String] {
        var dirs: [String] = []
        if let env = envConfigDir, !env.isEmpty { dirs.append(env) }
        dirs.append((home as NSString).appendingPathComponent(".claude"))
        return dirs.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Plaintext credential files to try, in order.
    static func candidateCredentialFiles(envConfigDir: String?, home: String) -> [String] {
        candidateConfigDirs(envConfigDir: envConfigDir, home: home)
            .map { ($0 as NSString).appendingPathComponent(".credentials.json") }
    }

    /// Keychain service name Claude Code uses for `configDir` when
    /// `CLAUDE_CONFIG_DIR` is set. `sha256Hex` returns lowercase hex.
    static func suffixedService(configDir: String, sha256Hex: (String) -> String) -> String {
        let hash = sha256Hex(configDir.precomposedStringWithCanonicalMapping)
        return "\(baseService)-\(hash.prefix(8))"
    }

    /// Keychain items to probe, in tie-break priority order: suffixed item for
    /// an explicit env dir, the unsuffixed default, then the suffixed `~/.claude`
    /// (shell exports `CLAUDE_CONFIG_DIR=~/.claude` that the GUI app can't see).
    static func candidateServices(envConfigDir: String?, home: String,
                                  sha256Hex: (String) -> String) -> [String] {
        let dirs = candidateConfigDirs(envConfigDir: envConfigDir, home: home)
        var services: [String] = []
        if let env = envConfigDir, !env.isEmpty {
            services.append(suffixedService(configDir: env, sha256Hex: sha256Hex))
        }
        services.append(baseService)
        services += dirs.map { suffixedService(configDir: $0, sha256Hex: sha256Hex) }
        return services.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Extract the modification timestamp from `security find-generic-password`
    /// attribute output (`"mdat"<timedate>=0x… "20261010063029Z\000"`).
    /// The `YYYYMMDDhhmmssZ` form sorts lexically == chronologically.
    static func parseModDate(_ attributes: String) -> String? {
        for line in attributes.split(separator: "\n") where line.contains("\"mdat\"<timedate>=") {
            guard let r = line.range(of: #"\"[0-9]{14}Z"#, options: .regularExpression) else { return nil }
            return String(line[r].dropFirst())
        }
        return nil
    }

    /// The existing item with the newest modification date. Missing dates sort
    /// oldest; ties keep the earlier (higher-priority) candidate.
    static func pickNewest(_ found: [(service: String, modDate: String?)]) -> String? {
        var best: (service: String, modDate: String)?
        for item in found {
            let date = item.modDate ?? ""
            if best == nil || date > best!.modDate { best = (item.service, date) }
        }
        return best?.service
    }
}
