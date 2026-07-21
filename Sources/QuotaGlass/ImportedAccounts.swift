import Foundation
import Security

// Accounts added through the in-app OAuth login, as opposed to the ones
// auto-discovered from CLI credentials. Metadata lives in
// Application Support/QuotaGlass/accounts.json; tokens live in this app's own
// keychain namespace via SecItem (own items never trigger an auth prompt,
// unlike the /usr/bin/security channel used for the CLIs' items).

struct ImportedAccount: Codable, Equatable, Identifiable, Sendable {
    enum Service: String, Codable, Sendable { case codex, claude }
    /// Codex: `chatgpt_account_id[:chatgpt_user_id]`; Claude: email or UUID.
    var id: String
    var service: Service
    var email: String?
    var planType: String?
    var addedAt: Date

    var storageKey: String { ImportedAccountStore.tokenKey(self) }
}

struct ImportedTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresAtMillis: Int?
}

struct ImportedCredential: Sendable {
    var account: ImportedAccount
    var tokens: ImportedTokens
}

enum ImportedAccountStoreError: LocalizedError {
    case metadataRead(path: String, reason: String)
    case metadataDecode(path: String, reason: String)
    case metadataEncode(reason: String)
    case metadataWrite(path: String, reason: String)
    case unsupportedMetadataVersion(Int)
    case tokenEncode
    case tokenDecode
    case unexpectedKeychainItem
    case accountNoLongerExists
    case credentialsChanged
    case keychain(operation: String, status: OSStatus)
    case transaction(operation: String, primary: String, rollback: String)
    case unexpected(reason: String)

    var errorDescription: String? {
        switch self {
        case .metadataRead(let path, let reason):
            return "读取账号元数据失败（\(path)）：\(reason)"
        case .metadataDecode(let path, let reason):
            return "账号元数据格式无效（\(path)）：\(reason)"
        case .metadataEncode(let reason):
            return "编码账号元数据失败：\(reason)"
        case .metadataWrite(let path, let reason):
            return "写入账号元数据失败（\(path)）：\(reason)"
        case .unsupportedMetadataVersion(let version):
            return "不支持的账号元数据版本：\(version)"
        case .tokenEncode:
            return "编码账号凭据失败"
        case .tokenDecode:
            return "账号凭据格式无效"
        case .unexpectedKeychainItem:
            return "钥匙串返回了无法识别的账号凭据"
        case .accountNoLongerExists:
            return "账号已被移除，未写入过期刷新结果"
        case .credentialsChanged:
            return "账号凭据已由其他登录更新，未覆盖较新的凭据"
        case .keychain(let operation, let status):
            let systemMessage = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串\(operation)失败（\(status)：\(systemMessage)）"
        case .transaction(let operation, let primary, let rollback):
            return "\(operation)账号失败：\(primary)；恢复原状态也失败：\(rollback)"
        case .unexpected(let reason):
            return "账号存储发生未知错误：\(reason)"
        }
    }
}

enum ImportedAccountStore {
    static let keychainService = "com.quotaglass.accounts"
    private static let operationLock = NSRecursiveLock()

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

    static func loadAllReporting() throws -> [ImportedAccount] {
        try synchronized {
            let url = fileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }

            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw ImportedAccountStoreError.metadataRead(path: url.path, reason: error.localizedDescription)
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload: Payload
            do {
                payload = try decoder.decode(Payload.self, from: data)
            } catch {
                throw ImportedAccountStoreError.metadataDecode(path: url.path, reason: error.localizedDescription)
            }
            guard payload.version == 1 else {
                throw ImportedAccountStoreError.unsupportedMetadataVersion(payload.version)
            }
            return payload.accounts
        }
    }

    static func saveAllReporting(_ accounts: [ImportedAccount]) throws {
        try synchronized {
            let url = fileURL()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let data: Data
            do {
                data = try encoder.encode(Payload(accounts: accounts))
            } catch {
                throw ImportedAccountStoreError.metadataEncode(reason: error.localizedDescription)
            }

            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: [.atomic])
            } catch {
                throw ImportedAccountStoreError.metadataWrite(path: url.path, reason: error.localizedDescription)
            }
        }
    }

    /// Upsert: same id replaces the existing entry (re-login refreshes tokens).
    /// The Keychain write happens first. If metadata persistence then fails, the
    /// previous Keychain bytes are restored so the two stores stay consistent.
    static func addReporting(_ account: ImportedAccount, tokens: ImportedTokens) throws {
        try synchronized {
            var all = try loadAllReporting()
            all.removeAll { $0.id == account.id && $0.service == account.service }
            all.append(account)

            let accountId = tokenKey(account)
            let previousData = try loadTokenDataReporting(accountId: accountId)
            try saveTokensReporting(tokens, accountId: accountId)

            do {
                try saveAllReporting(all)
            } catch {
                let primary = storeError(error)
                do {
                    if let previousData {
                        try saveTokenDataReporting(previousData, accountId: accountId)
                    } else {
                        try deleteTokensReporting(accountId: accountId)
                    }
                } catch {
                    let rollback = storeError(error)
                    throw ImportedAccountStoreError.transaction(
                        operation: "添加",
                        primary: primary.localizedDescription,
                        rollback: rollback.localizedDescription
                    )
                }
                throw primary
            }
        }
    }

    static func removeReporting(_ account: ImportedAccount) throws {
        try synchronized {
            var all = try loadAllReporting()
            all.removeAll { $0.id == account.id && $0.service == account.service }

            let accountId = tokenKey(account)
            let previousData = try loadTokenDataReporting(accountId: accountId)
            try deleteTokensReporting(accountId: accountId)

            do {
                try saveAllReporting(all)
            } catch {
                let primary = storeError(error)
                if let previousData {
                    do {
                        try saveTokenDataReporting(previousData, accountId: accountId)
                    } catch {
                        let rollback = storeError(error)
                        throw ImportedAccountStoreError.transaction(
                            operation: "移除",
                            primary: primary.localizedDescription,
                            rollback: rollback.localizedDescription
                        )
                    }
                }
                throw primary
            }
        }
    }

    static func tokenKey(_ account: ImportedAccount) -> String {
        tokenKey(service: account.service, id: account.id)
    }

    static func tokenKey(service: ImportedAccount.Service, id: String) -> String {
        service.rawValue + ":" + id
    }

    // MARK: - Tokens (own keychain namespace, SecItem)

    static func loadTokensReporting(accountId: String) throws -> ImportedTokens? {
        try synchronized {
            guard let data = try loadTokenDataReporting(accountId: accountId) else { return nil }
            do {
                return try JSONDecoder().decode(ImportedTokens.self, from: data)
            } catch {
                throw ImportedAccountStoreError.tokenDecode
            }
        }
    }

    static func saveTokensReporting(_ tokens: ImportedTokens, accountId: String) throws {
        try synchronized {
            let data: Data
            do {
                data = try JSONEncoder().encode(tokens)
            } catch {
                throw ImportedAccountStoreError.tokenEncode
            }
            try saveTokenDataReporting(data, accountId: accountId)
        }
    }

    /// Compare-and-swap update used by background token refreshes. Holding the
    /// store lock across metadata lookup, token comparison, and write prevents a
    /// cancelled old refresh from recreating a removed token or overwriting a
    /// newer in-app login.
    static func updateTokensReporting(
        _ tokens: ImportedTokens,
        service: ImportedAccount.Service,
        id: String,
        expectedAccessToken: String,
        expectedRefreshToken: String?
    ) throws {
        try synchronized {
            let accounts = try loadAllReporting()
            guard accounts.contains(where: { $0.service == service && $0.id == id }) else {
                throw ImportedAccountStoreError.accountNoLongerExists
            }

            let accountId = tokenKey(service: service, id: id)
            guard let current = try loadTokensReporting(accountId: accountId) else {
                throw ImportedAccountStoreError.accountNoLongerExists
            }
            guard current.accessToken == expectedAccessToken,
                  current.refreshToken == expectedRefreshToken else {
                throw ImportedAccountStoreError.credentialsChanged
            }
            try saveTokensReporting(tokens, accountId: accountId)
        }
    }

    static func deleteTokensReporting(accountId: String) throws {
        try synchronized {
            let status = SecItemDelete(baseQuery(account: accountId) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ImportedAccountStoreError.keychain(operation: "删除", status: status)
            }
        }
    }

    private static func loadTokenDataReporting(accountId: String) throws -> Data? {
        var query = baseQuery(account: accountId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ImportedAccountStoreError.keychain(operation: "读取", status: status)
        }
        guard let data = item as? Data else {
            throw ImportedAccountStoreError.unexpectedKeychainItem
        }
        return data
    }

    private static func saveTokenDataReporting(_ data: Data, accountId: String) throws {
        let query = baseQuery(account: accountId)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw ImportedAccountStoreError.keychain(operation: "写入", status: status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    private static func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try body()
    }

    private static func storeError(_ error: Error) -> ImportedAccountStoreError {
        if let error = error as? ImportedAccountStoreError { return error }
        return .unexpected(reason: error.localizedDescription)
    }
}
