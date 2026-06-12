import Foundation

// Token refresh + usage fetch for the natively-read CLI credentials, mapped into
// QuotaGlass's QuotaSnapshot model.

struct NativeWindow {
    var usedPercent: Double
    var resetsAt: Date?
}

enum NativeQuotaError: Error { case noCredentials }

// MARK: - Codex

enum CodexRefresher {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!

    /// Returns a usable access token, refreshing + writing back to auth.json if expired.
    static func ensureFresh(_ account: inout NativeCodexAccount) async -> String? {
        guard let access = account.accessToken else { return nil }
        if !isExpired(access) { return access }
        guard let refresh = account.refreshToken, !refresh.isEmpty else { return access }

        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refresh),
            .init(name: "client_id", value: clientID),
            .init(name: "scope", value: "openid profile email"),
        ]
        req.httpBody = (comps.percentEncodedQuery ?? "").data(using: .utf8)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = root["access_token"] as? String else {
            return access // best effort; usage call will surface auth failure
        }
        let newRefresh = root["refresh_token"] as? String ?? refresh
        let newId = root["id_token"] as? String
        account.accessToken = newAccess
        account.refreshToken = newRefresh
        if let newId { account.idToken = newId }
        writeBack(accessToken: newAccess, refreshToken: newRefresh, idToken: newId)
        return newAccess
    }

    static func isExpired(_ accessToken: String) -> Bool {
        guard let payload = NativeJWT.decodePayload(accessToken), let exp = payload["exp"] as? Double else { return true }
        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < 300
    }

    private static func writeBack(accessToken: String, refreshToken: String, idToken: String?) {
        let url = CodexAuthReader.authFileURL()
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var tokens = root["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = accessToken
        tokens["refresh_token"] = refreshToken
        if let idToken { tokens["id_token"] = idToken }
        root["tokens"] = tokens
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = iso.string(from: Date())
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url, options: [.atomic])
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
        if let accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rate = root["rate_limit"] as? [String: Any] ?? [:]
        return (
            parseWindow(rate["primary_window"] as? [String: Any]),
            parseWindow(rate["secondary_window"] as? [String: Any]),
            root["plan_type"] as? String
        )
    }

    private static func parseWindow(_ dict: [String: Any]?) -> NativeWindow? {
        guard let dict else { return nil }
        let used = (dict["used_percent"] as? Double) ?? Double(dict["used_percent"] as? Int ?? 0)
        var resetsAt: Date?
        if let n = dict["reset_at"] as? Double { resetsAt = Date(timeIntervalSince1970: n) }
        else if let i = dict["reset_at"] as? Int { resetsAt = Date(timeIntervalSince1970: Double(i)) }
        else if let s = dict["reset_after_seconds"] as? Double { resetsAt = Date(timeIntervalSinceNow: s) }
        else if let s = dict["reset_after_seconds"] as? Int { resetsAt = Date(timeIntervalSinceNow: Double(s)) }
        return NativeWindow(usedPercent: used, resetsAt: resetsAt)
    }
}

// MARK: - Claude

enum ClaudeRefresher {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!

    static func ensureFresh(_ account: inout NativeClaudeAccount) async -> String? {
        guard let access = account.accessToken else { return nil }
        if let expiresAt = account.expiresAt, expiresAt.timeIntervalSinceNow > 30 { return access }
        if account.expiresAt == nil { return access }
        guard let refresh = account.refreshToken, !refresh.isEmpty else { return access }

        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refresh),
            .init(name: "client_id", value: clientID),
        ]
        req.httpBody = (comps.percentEncodedQuery ?? "").data(using: .utf8)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = root["access_token"] as? String else {
            return access
        }
        let newRefresh = root["refresh_token"] as? String ?? refresh
        let expiresIn = (root["expires_in"] as? Double) ?? Double(root["expires_in"] as? Int ?? 3600)
        let expiresAt = Date(timeIntervalSinceNow: expiresIn)
        account.accessToken = newAccess
        account.refreshToken = newRefresh
        account.expiresAt = expiresAt
        writeBack(account: account, accessToken: newAccess, refreshToken: newRefresh, expiresAt: expiresAt)
        return newAccess
    }

    private static func writeBack(account: NativeClaudeAccount, accessToken: String, refreshToken: String, expiresAt: Date) {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        switch account.source {
        case .file:
            let url = ClaudeAuthReader.credentialsFileURL()
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = obj
            }
            var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
            oauth["accessToken"] = accessToken
            oauth["refreshToken"] = refreshToken
            oauth["expiresAt"] = millis
            root["claudeAiOauth"] = oauth
            if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: url, options: [.atomic])
            }
        case .keychain:
            let service = account.keychainService ?? ClaudeKeychain.canonicalService
            guard let data = ClaudeKeychain.read(service: service),
                  var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
            oauth["accessToken"] = accessToken
            oauth["refreshToken"] = refreshToken
            oauth["expiresAt"] = millis
            root["claudeAiOauth"] = oauth
            if let out = try? JSONSerialization.data(withJSONObject: root, options: []),
               let str = String(data: out, encoding: .utf8) {
                ClaudeKeychain.write(service: service, json: str)
            }
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
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (parseWindow(root["five_hour"] as? [String: Any]), parseWindow(root["seven_day"] as? [String: Any]))
    }

    private static func parseWindow(_ dict: [String: Any]?) -> NativeWindow? {
        guard let dict else { return nil }
        let used = (dict["utilization"] as? Double) ?? Double(dict["utilization"] as? Int ?? 0)
        var resetsAt: Date?
        if let s = dict["resets_at"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = iso.date(from: s)
            if resetsAt == nil {
                iso.formatOptions = [.withInternetDateTime]
                resetsAt = iso.date(from: s)
            }
        } else if let n = dict["resets_at"] as? Double {
            resetsAt = Date(timeIntervalSince1970: n)
        }
        return NativeWindow(usedPercent: used, resetsAt: resetsAt)
    }
}

// MARK: - Provider

struct NativeQuotaProvider {
    func loadQuotas() async throws -> [QuotaSnapshot] {
        var result: [QuotaSnapshot] = []

        if var codex = CodexAuthReader.load() {
            if let token = await CodexRefresher.ensureFresh(&codex),
               let usage = await CodexUsage.fetch(accessToken: token, accountId: codex.accountId) {
                result.append(snapshot(
                    service: "Codex",
                    account: codex.email ?? "Codex",
                    plan: codex.planType,
                    five: usage.five,
                    weekly: usage.weekly
                ))
            }
        }

        for var claude in ClaudeAuthReader.loadAll() {
            if let token = await ClaudeRefresher.ensureFresh(&claude),
               let usage = await ClaudeUsage.fetch(accessToken: token) {
                result.append(snapshot(
                    service: "Claude",
                    account: claude.displayAccount,
                    plan: claude.subscriptionType,
                    five: usage.five,
                    weekly: usage.weekly
                ))
            }
        }

        if result.isEmpty { throw NativeQuotaError.noCredentials }
        return result
    }

    private func snapshot(service: String, account: String, plan: String?, five: NativeWindow?, weekly: NativeWindow?) -> QuotaSnapshot {
        QuotaSnapshot(
            serviceName: service,
            accountName: account,
            planName: planLabel(plan),
            fiveHourUsed: five?.usedPercent ?? 0,
            weeklyUsed: weekly?.usedPercent ?? 0,
            fiveHourReset: NativeQuotaProvider.formatReset(five?.resetsAt),
            weeklyReset: NativeQuotaProvider.formatReset(weekly?.resetsAt),
            source: "Native",
            fetchedAt: Date()
        )
    }

    private func planLabel(_ plan: String?) -> String {
        guard let plan, !plan.isEmpty else { return "" }
        let lower = plan.lowercased()
        if lower.contains("prolite") || lower == "pro_lite" { return "Pro Lite" }
        if lower.contains("max") { return "Max" }
        if lower.contains("team") { return "Team" }
        if lower.contains("plus") { return "Plus" }
        if lower.contains("pro") { return "Pro" }
        return plan.capitalized
    }

    /// Formats a reset time as "M/d HH:mm (周X)" to match the previous checker style.
    static func formatReset(_ date: Date?) -> String {
        guard let date else { return "无" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm (EEE)"
        return formatter.string(from: date)
    }
}
