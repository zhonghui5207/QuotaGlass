import Foundation
import Security

// Accounts added through the in-app OAuth login, as opposed to the ones
// auto-discovered from CLI credentials. Metadata lives in
// Application Support/QuotaGlass/accounts.json; tokens live in this app's own
// keychain namespace via SecItem (own items never trigger an auth prompt,
// unlike the /usr/bin/security channel used for the CLIs' items).

struct ImportedAccount: Codable, Equatable, Identifiable {
    enum Service: String, Codable { case codex, claude }
    /// Codex: `chatgpt_account_id[:chatgpt_user_id]`; Claude: email or UUID.
    var id: String
    var service: Service
    var email: String?
    var planType: String?
    var addedAt: Date
}

struct ImportedTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAtMillis: Int?
}

enum ImportedAccountStore {
    static let keychainService = "com.quotaglass.accounts"

    // MARK: - Metadata (JSON file)

    private struct Payload: Codable {
        var version: Int = 1
        var accounts: [ImportedAccount] = []
    }

    static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("QuotaGlass", isDirectory: true)
            .appendingPathComponent("accounts.json", isDirectory: false)
    }

    static func loadAll() -> [ImportedAccount] {
        guard let data = try? Data(contentsOf: fileURL()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data), payload.version == 1 else { return [] }
        return payload.accounts
    }

    static func saveAll(_ accounts: [ImportedAccount]) {
        let url = fileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Payload(accounts: accounts)) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// Upsert: same id replaces the existing entry (re-login refreshes tokens).
    static func add(_ account: ImportedAccount, tokens: ImportedTokens) {
        var all = loadAll()
        all.removeAll { $0.id == account.id && $0.service == account.service }
        all.append(account)
        saveAll(all)
        saveTokens(tokens, accountId: tokenKey(account))
    }

    static func remove(_ account: ImportedAccount) {
        var all = loadAll()
        all.removeAll { $0.id == account.id && $0.service == account.service }
        saveAll(all)
        deleteTokens(accountId: tokenKey(account))
    }

    static func tokenKey(_ account: ImportedAccount) -> String {
        tokenKey(service: account.service, id: account.id)
    }

    static func tokenKey(service: ImportedAccount.Service, id: String) -> String {
        service.rawValue + ":" + id
    }

    // MARK: - Tokens (own keychain namespace, SecItem)

    static func loadTokens(accountId: String) -> ImportedTokens? {
        var query = baseQuery(account: accountId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let tokens = try? JSONDecoder().decode(ImportedTokens.self, from: data) else { return nil }
        return tokens
    }

    static func saveTokens(_ tokens: ImportedTokens, accountId: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(baseQuery(account: accountId) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account: accountId)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func deleteTokens(accountId: String) {
        SecItemDelete(baseQuery(account: accountId) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }
}
