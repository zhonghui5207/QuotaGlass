import Foundation

// MARK: - Claude

enum ClaudeRefresher {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!

    static func ensureFresh(_ account: inout NativeClaudeAccount) async -> String? {
        account.credentialWarning = nil
        guard let access = account.accessToken else { return nil }
        if let expiresAt = account.expiresAt, expiresAt.timeIntervalSinceNow > 30 { return access }
        if account.expiresAt == nil { return access }
        guard let refresh = account.refreshToken, !refresh.isEmpty else { return access }

        guard let response = try? await OAuthHTTP.postForm(
            to: tokenEndpoint,
            parameters: [
                (name: "grant_type", value: "refresh_token"),
                (name: "refresh_token", value: refresh),
                (name: "client_id", value: clientID),
            ]
        ), !Task.isCancelled else {
            return access
        }
        let newAccess = response.accessToken
        let newRefresh = response.refreshToken ?? refresh
        let expiresAt = Date(timeIntervalSinceNow: response.expiresIn ?? 3600)
        account.accessToken = newAccess
        account.refreshToken = newRefresh
        account.expiresAt = expiresAt
        var persistenceWarnings: [String] = []
        func persist(_ operation: () throws -> Void) {
            do { try operation() } catch { persistenceWarnings.append(error.localizedDescription) }
        }
        persist {
            try writeBackReporting(
                account: account,
                accessToken: newAccess,
                refreshToken: newRefresh,
                expiresAt: expiresAt,
                expectedAccessToken: access,
                expectedRefreshToken: refresh
            )
        }
        for linkedId in account.linkedImportedIDs {
            persist {
                try ImportedAccountStore.updateTokensReporting(
                    ImportedTokens(
                        accessToken: newAccess,
                        refreshToken: newRefresh,
                        idToken: nil,
                        expiresAtMillis: Int(expiresAt.timeIntervalSince1970 * 1000)
                    ),
                    service: .claude,
                    id: linkedId,
                    expectedAccessToken: access,
                    expectedRefreshToken: refresh
                )
            }
        }
        account.credentialWarning = persistenceWarnings.isEmpty
            ? nil
            : persistenceWarnings.joined(separator: "；")
        return newAccess
    }

    private static func writeBackReporting(
        account: NativeClaudeAccount,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        expectedAccessToken: String,
        expectedRefreshToken: String
    ) throws {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        switch account.source {
        case .imported(let id):
            try ImportedAccountStore.updateTokensReporting(
                ImportedTokens(accessToken: accessToken, refreshToken: refreshToken, idToken: nil, expiresAtMillis: millis),
                service: .claude,
                id: id,
                expectedAccessToken: expectedAccessToken,
                expectedRefreshToken: expectedRefreshToken
            )
        case .file:
            let url = ClaudeAuthReader.credentialsFileURL()
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw NativeCredentialPersistenceError.readFile(
                    label: "Claude",
                    path: url.path,
                    reason: error.localizedDescription
                )
            }
            guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NativeCredentialPersistenceError.invalidFile(label: "Claude", path: url.path)
            }
            var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
            let currentAccess = oauth["accessToken"] as? String ?? oauth["access_token"] as? String
            let currentRefresh = oauth["refreshToken"] as? String ?? oauth["refresh_token"] as? String
            guard currentAccess == expectedAccessToken, currentRefresh == expectedRefreshToken else {
                throw NativeCredentialPersistenceError.credentialsChanged(label: "Claude")
            }
            oauth["accessToken"] = accessToken
            oauth["refreshToken"] = refreshToken
            oauth["expiresAt"] = millis
            root["claudeAiOauth"] = oauth
            let output: Data
            do {
                output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            } catch {
                throw NativeCredentialPersistenceError.encode(label: "Claude", reason: error.localizedDescription)
            }
            do {
                try output.write(to: url, options: [.atomic])
            } catch {
                throw NativeCredentialPersistenceError.writeFile(
                    label: "Claude",
                    path: url.path,
                    reason: error.localizedDescription
                )
            }
        case .keychain:
            guard let service = account.keychainService,
                  let keychainAccount = account.keychainAccount,
                  let data = ClaudeKeychain.read(service: service, account: keychainAccount) else {
                throw NativeCredentialPersistenceError.readKeychain(label: "Claude")
            }
            guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NativeCredentialPersistenceError.invalidFile(label: "Claude", path: "Keychain/\(service)")
            }
            var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
            let currentAccess = oauth["accessToken"] as? String ?? oauth["access_token"] as? String
            let currentRefresh = oauth["refreshToken"] as? String ?? oauth["refresh_token"] as? String
            guard currentAccess == expectedAccessToken, currentRefresh == expectedRefreshToken else {
                throw NativeCredentialPersistenceError.credentialsChanged(label: "Claude")
            }
            oauth["accessToken"] = accessToken
            oauth["refreshToken"] = refreshToken
            oauth["expiresAt"] = millis
            root["claudeAiOauth"] = oauth
            let output: Data
            do {
                output = try JSONSerialization.data(withJSONObject: root, options: [])
            } catch {
                throw NativeCredentialPersistenceError.encode(label: "Claude", reason: error.localizedDescription)
            }
            try ClaudeKeychain.updateExistingReporting(
                service: service,
                account: keychainAccount,
                data: output
            )
        }
    }
}

enum ClaudeUsage {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(accessToken: String) async -> (five: NativeWindow?, weekly: NativeWindow?)? {
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let usage = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data) else {
            return nil
        }
        return (
            usage.fiveHour?.value?.nativeWindow,
            usage.sevenDay?.value?.nativeWindow
        )
    }
}

/// api.anthropic.com/api/oauth/usage payload.
struct ClaudeUsageResponse: Decodable, Sendable {
    var fiveHour: LenientValue<Window>?
    var sevenDay: LenientValue<Window>?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    struct Window: Decodable, Sendable {
        var utilization: Double?
        var resetsAt: ResetsAt?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var nativeWindow: NativeWindow? {
            guard let utilization else { return nil }
            return NativeWindow(usedPercent: utilization, resetsAt: resetsAt?.date)
        }
    }

    /// Anthropic has returned resets_at as both an ISO-8601 string and an
    /// epoch number; accept either.
    struct ResetsAt: Decodable, Sendable {
        var date: Date?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                date = Date(timeIntervalSince1970: seconds)
            } else if let text = try? container.decode(String.self) {
                date = SharedFormatters.iso8601Date(from: text)
            } else {
                date = nil
            }
        }
    }
}
