import Foundation

// MARK: - Codex

enum CodexRefresher {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!

    /// Returns a usable access token, refreshing + writing back to auth.json if expired.
    static func ensureFresh(_ account: inout NativeCodexAccount) async -> String? {
        account.credentialWarning = nil
        guard let access = account.accessToken else { return nil }
        if !isExpired(access) { return access }
        guard let refresh = account.refreshToken, !refresh.isEmpty else { return access }

        guard let response = try? await OAuthHTTP.postForm(
            to: tokenEndpoint,
            parameters: [
                (name: "grant_type", value: "refresh_token"),
                (name: "refresh_token", value: refresh),
                (name: "client_id", value: clientID),
                (name: "scope", value: "openid profile email"),
            ]
        ), !Task.isCancelled else {
            return access // best effort; usage call will surface auth failure
        }
        let newAccess = response.accessToken
        let newRefresh = response.refreshToken ?? refresh
        let newId = response.idToken
        account.accessToken = newAccess
        account.refreshToken = newRefresh
        if let newId { account.idToken = newId }
        let updatedIdToken = newId ?? account.idToken
        var persistenceWarnings: [String] = []
        func persist(_ operation: () throws -> Void) {
            do { try operation() } catch { persistenceWarnings.append(error.localizedDescription) }
        }
        if let importedId = account.importedId {
            persist {
                try ImportedAccountStore.updateTokensReporting(
                    ImportedTokens(
                        accessToken: newAccess,
                        refreshToken: newRefresh,
                        idToken: updatedIdToken,
                        expiresAtMillis: nil
                    ),
                    service: .codex,
                    id: importedId,
                    expectedAccessToken: access,
                    expectedRefreshToken: refresh
                )
            }
        } else {
            persist {
                try writeBackReporting(
                    accessToken: newAccess,
                    refreshToken: newRefresh,
                    idToken: newId,
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
                            idToken: updatedIdToken,
                            expiresAtMillis: nil
                        ),
                        service: .codex,
                        id: linkedId,
                        expectedAccessToken: access,
                        expectedRefreshToken: refresh
                    )
                }
            }
        }
        account.credentialWarning = persistenceWarnings.isEmpty
            ? nil
            : persistenceWarnings.joined(separator: "；")
        return newAccess
    }

    static func isExpired(_ accessToken: String) -> Bool {
        guard let payload = NativeJWT.decodePayload(accessToken) else { return true }
        let exp = (payload["exp"] as? Double) ?? (payload["exp"] as? Int).map(Double.init)
        guard let exp else { return true }
        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < 300
    }

    private static func writeBackReporting(
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        expectedAccessToken: String,
        expectedRefreshToken: String
    ) throws {
        let url = CodexAuthReader.authFileURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NativeCredentialPersistenceError.readFile(
                label: "Codex",
                path: url.path,
                reason: error.localizedDescription
            )
        }
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeCredentialPersistenceError.invalidFile(label: "Codex", path: url.path)
        }
        var tokens = root["tokens"] as? [String: Any] ?? [:]
        guard tokens["access_token"] as? String == expectedAccessToken,
              tokens["refresh_token"] as? String == expectedRefreshToken else {
            throw NativeCredentialPersistenceError.credentialsChanged(label: "Codex")
        }
        tokens["access_token"] = accessToken
        tokens["refresh_token"] = refreshToken
        if let idToken { tokens["id_token"] = idToken }
        root["tokens"] = tokens
        root["last_refresh"] = SharedFormatters.iso8601String(from: Date())
        let output: Data
        do {
            output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw NativeCredentialPersistenceError.encode(label: "Codex", reason: error.localizedDescription)
        }
        do {
            try output.write(to: url, options: [.atomic])
        } catch {
            throw NativeCredentialPersistenceError.writeFile(
                label: "Codex",
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }
}

enum CodexUsage {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func fetch(accessToken: String, accountId: String?) async -> (five: NativeWindow?, weekly: NativeWindow?, plan: String?)? {
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        if let accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let usage = try? JSONDecoder().decode(CodexUsageResponse.self, from: data) else {
            return nil
        }
        return (
            usage.rateLimit?.primaryWindow?.value?.nativeWindow,
            usage.rateLimit?.secondaryWindow?.value?.nativeWindow,
            usage.planType
        )
    }
}

/// chatgpt.com/backend-api/wham/usage payload.
struct CodexUsageResponse: Decodable, Sendable {
    var planType: String?
    var rateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }

    struct RateLimit: Decodable, Sendable {
        var primaryWindow: LenientValue<Window>?
        var secondaryWindow: LenientValue<Window>?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable, Sendable {
        var usedPercent: Double?
        var resetAt: Double?
        var resetAfterSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case resetAfterSeconds = "reset_after_seconds"
        }

        var nativeWindow: NativeWindow? {
            guard let usedPercent else { return nil }
            let resetsAt = resetAt.map(Date.init(timeIntervalSince1970:))
                ?? resetAfterSeconds.map(Date.init(timeIntervalSinceNow:))
            return NativeWindow(usedPercent: usedPercent, resetsAt: resetsAt)
        }
    }
}
