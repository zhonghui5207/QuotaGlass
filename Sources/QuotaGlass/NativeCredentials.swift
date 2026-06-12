import Foundation
import Security

// Reads the standard credential files that the Claude Code and Codex CLIs write,
// so QuotaGlass works on any machine where those CLIs are logged in — no separate
// config or login UI. Mirrors the approach used by cc-bar.

enum NativeJWT {
    static func decodePayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var str = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = str.count % 4
        if pad > 0 { str.append(String(repeating: "=", count: 4 - pad)) }
        guard let data = Data(base64Encoded: str) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

struct NativeCodexAccount {
    var email: String?
    var planType: String?
    var accountId: String?
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    /// Set when this account came from the in-app OAuth login; token refreshes
    /// then write back to ImportedAccountStore instead of auth.json.
    var importedId: String?
}

struct NativeClaudeAccount {
    enum Source: Equatable { case file, keychain, imported(String) }
    var source: Source
    /// Which keychain service this came from, so refreshes write back to the right item.
    var keychainService: String?
    var email: String?
    var subscriptionType: String?
    var expiresAt: Date?
    var accessToken: String?
    var refreshToken: String?

    /// Short label distinguishing accounts when no email is present.
    var displayAccount: String {
        if let email, !email.isEmpty { return email }
        if let keychainService, let suffix = NativeClaudeAccount.suffix(of: keychainService) {
            return suffix
        }
        return "Default"
    }

    private static func suffix(of service: String) -> String? {
        let prefix = "Claude Code-credentials"
        guard service.hasPrefix(prefix) else { return nil }
        let rest = service.dropFirst(prefix.count)
        let trimmed = rest.drop(while: { $0 == "-" })
        return trimmed.isEmpty ? nil : String(trimmed)
    }
}

enum CodexAuthReader {
    static func authFileURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    /// Returns nil when no Codex credentials exist on this machine.
    static func load() -> NativeCodexAccount? {
        let url = authFileURL()
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let tokens = root["tokens"] as? [String: Any] ?? [:]
        let idToken = tokens["id_token"] as? String
        let accessToken = tokens["access_token"] as? String
        let refreshToken = tokens["refresh_token"] as? String
        let idClaims = idToken.flatMap { NativeJWT.decodePayload($0) }
        let accessClaims = accessToken.flatMap { NativeJWT.decodePayload($0) }

        var email = idClaims?["email"] as? String
        var planType: String?
        if let auth = idClaims?["https://api.openai.com/auth"] as? [String: Any] {
            planType = auth["chatgpt_plan_type"] as? String
        }
        if planType == nil, let auth = accessClaims?["https://api.openai.com/auth"] as? [String: Any] {
            planType = auth["chatgpt_plan_type"] as? String
        }
        if email == nil { email = accessClaims?["email"] as? String }

        let accountId = (tokens["account_id"] as? String)
            ?? authClaim("chatgpt_account_id", accessClaims)
            ?? authClaim("chatgpt_account_id", idClaims)

        return NativeCodexAccount(
            email: email,
            planType: planType,
            accountId: accountId,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken
        )
    }

    private static func authClaim(_ key: String, _ claims: [String: Any]?) -> String? {
        guard let auth = claims?["https://api.openai.com/auth"] as? [String: Any],
              let value = auth[key] as? String, !value.isEmpty else { return nil }
        return value
    }
}

enum ClaudeAuthReader {
    static func credentialsFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    /// All Claude Code logins on this machine: the standard credentials file (if any)
    /// plus every `Claude Code-credentials*` keychain item (covers multi-profile setups).
    /// De-duplicated by access token.
    static func loadAll() -> [NativeClaudeAccount] {
        var accounts: [NativeClaudeAccount] = []
        var seenTokens = Set<String>()

        func add(_ account: NativeClaudeAccount?) {
            guard let account, let token = account.accessToken, !token.isEmpty else { return }
            guard seenTokens.insert(token).inserted else { return }
            accounts.append(account)
        }

        if let data = try? Data(contentsOf: credentialsFileURL()), !data.isEmpty {
            var account = parse(data: data, source: .file, service: nil)
            if account?.email == nil { account?.email = emailFromConfig() }
            add(account)
        }

        for service in ClaudeKeychain.listServices() {
            if let data = ClaudeKeychain.read(service: service) {
                var account = parse(data: data, source: .keychain, service: service)
                if account?.email == nil, service == ClaudeKeychain.canonicalService {
                    account?.email = emailFromConfig()
                }
                add(account)
            }
        }

        for imported in ImportedAccountStore.loadAll() where imported.service == .claude {
            guard let tokens = ImportedAccountStore.loadTokens(accountId: ImportedAccountStore.tokenKey(imported)) else { continue }
            add(NativeClaudeAccount(
                source: .imported(imported.id),
                keychainService: nil,
                email: imported.email,
                subscriptionType: imported.planType,
                expiresAt: parseExpiry(tokens.expiresAtMillis.map(Double.init)),
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken
            ))
        }

        return accounts
    }

    private static func emailFromConfig() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any],
              let email = oauth["emailAddress"] as? String, !email.isEmpty else { return nil }
        return email
    }

    private static func parse(data: Data, source: NativeClaudeAccount.Source, service: String?) -> NativeClaudeAccount? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        let email = oauth["emailAddress"] as? String ?? oauth["email"] as? String
        let sub = oauth["subscriptionType"] as? String
        let accessToken = oauth["accessToken"] as? String ?? oauth["access_token"] as? String
        let refreshToken = oauth["refreshToken"] as? String ?? oauth["refresh_token"] as? String
        return NativeClaudeAccount(
            source: source,
            keychainService: service,
            email: email,
            subscriptionType: sub,
            expiresAt: parseExpiry(oauth["expiresAt"]),
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    static func parseExpiry(_ any: Any?) -> Date? {
        let raw: Double?
        if let n = any as? Double { raw = n }
        else if let s = any as? String { raw = Double(s) }
        else { raw = nil }
        guard let raw else { return nil }
        // Claude CLI stores epoch milliseconds.
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
    }
}

/// Reads/writes Claude Code credential blobs in the login keychain via /usr/bin/security.
enum ClaudeKeychain {
    static let canonicalService = "Claude Code-credentials"

    /// All generic-password services starting with the Claude Code prefix (canonical first).
    /// Listing attributes does not prompt for keychain access; reading each secret might.
    static func listServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return [canonicalService]
        }
        let services = items.compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix(canonicalService) }
        let unique = Array(Set(services)).sorted { a, _ in a == canonicalService }
        return unique.isEmpty ? [canonicalService] : unique
    }

    static func read(service: String) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0,
              let str = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !str.isEmpty else { return nil }
        return str.data(using: .utf8)
    }

    static func write(service: String, json: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["add-generic-password", "-U", "-s", service, "-a", NSUserName(), "-w", json]
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }
}
