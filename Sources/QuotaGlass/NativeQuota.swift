import Foundation
import WebKit

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
        if let importedId = account.importedId {
            ImportedAccountStore.saveTokens(
                ImportedTokens(accessToken: newAccess, refreshToken: newRefresh, idToken: newId ?? account.idToken, expiresAtMillis: nil),
                accountId: "codex:" + importedId
            )
        } else {
            writeBack(accessToken: newAccess, refreshToken: newRefresh, idToken: newId)
        }
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
        case .imported(let id):
            ImportedAccountStore.saveTokens(
                ImportedTokens(accessToken: accessToken, refreshToken: refreshToken, idToken: nil, expiresAtMillis: millis),
                accountId: "claude:" + id
            )
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

// MARK: - Sakana

struct SakanaUsageResult {
    var five: NativeWindow?
    var weekly: NativeWindow?
    var plan: String?
    var primaryText: String
    var secondaryText: String?
    var detailText: String?
}

enum SakanaUsage {
    static let modelsEndpoint = URL(string: "https://api.sakana.ai/v1/models")!
    static let billingEndpoint = URL(string: "https://console.sakana.ai/billing?_rsc=quotaglass")!

    @MainActor
    static func debugReport() async -> String {
        var lines: [String] = ["Sakana debug:"]
        let wkCookies = await SakanaConsoleSession.webKitCookies()
        let storageCookies = SakanaConsoleSession.sharedStorageCookies()
        let cookies = SakanaConsoleSession.deduplicate(wkCookies + storageCookies)
        let relevant = SakanaConsoleSession.relevantCookies(from: cookies)
        lines.append("cookies total: \(cookies.count), wk: \(wkCookies.count), shared: \(storageCookies.count), sakana: \(relevant.count)")
        if relevant.isEmpty {
            lines.append("sakana cookies: <none>")
        } else {
            let summary = relevant
                .sorted { $0.name < $1.name }
                .map { "\($0.name)@\($0.domain)" }
                .joined(separator: ", ")
            lines.append("sakana cookies: \(summary)")
        }

        guard !relevant.isEmpty else { return lines.joined(separator: "\n") }
        let cookieHeader = SakanaConsoleSession.cookieHeader(from: relevant)
        var req = URLRequest(url: billingEndpoint)
        req.setValue("1", forHTTPHeaderField: "RSC")
        req.setValue("1", forHTTPHeaderField: "Next-Router-Prefetch")
        req.setValue("text/x-component", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("https://console.sakana.ai/billing?tab=payAsYouGo", forHTTPHeaderField: "Referer")
        req.setValue("QuotaGlass", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 25

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            lines.append("billing status: \(status), bytes: \(data.count)")
            let text = String(data: data, encoding: .utf8) ?? ""
            lines.append("contains login text: \(text.contains("Login with Google") || text.contains("Sign in"))")
            if let parsed = parseConsoleBilling(text) {
                lines.append("parsed primary: \(parsed.primaryText)")
                lines.append("parsed secondary: \(parsed.secondaryText ?? "<none>")")
                lines.append("parsed five: \(parsed.five?.usedPercent.description ?? "<none>")")
                lines.append("parsed weekly: \(parsed.weekly?.usedPercent.description ?? "<none>")")
            } else {
                lines.append("parsed: <none>")
                lines.append("sample: \(String(text.prefix(500)).replacingOccurrences(of: "\n", with: " "))")
            }
        } catch {
            lines.append("billing error: \(error.localizedDescription)")
        }

        return lines.joined(separator: "\n")
    }

    static func fetch(apiKey: String?) async -> SakanaUsageResult? {
        let modelCount: Int?
        if let apiKey {
            guard let count = await validateKey(apiKey: apiKey) else { return nil }
            modelCount = count
        } else {
            modelCount = nil
        }
        var result = SakanaUsageResult(
            five: nil,
            weekly: nil,
            plan: "API",
            primaryText: apiKey == nil ? "Console" : "API key OK",
            secondaryText: modelCount.map { "\($0) models" },
            detailText: "console billing not logged in"
        )

        if let cached = SakanaUsageCache.load() {
            result.five = cached.five
            result.weekly = cached.weekly
            result.plan = cached.plan ?? result.plan
            result.primaryText = cached.primaryText
            result.secondaryText = cached.secondaryText ?? result.secondaryText
            result.detailText = cached.detailText
        }

        if let billing = await fetchConsoleBilling() {
            result.five = billing.five
            result.weekly = billing.weekly
            result.plan = billing.plan ?? result.plan
            result.primaryText = billing.primaryText
            result.secondaryText = billing.secondaryText ?? result.secondaryText
            result.detailText = billing.detailText
        } else if let apiKey,
                  let endpoint = configuredUsageEndpoint(),
           let billing = await fetchBilling(apiKey: apiKey, endpoint: endpoint) {
            result.five = billing.five
            result.weekly = billing.weekly
            result.plan = billing.plan ?? result.plan
            result.primaryText = billing.primaryText
            result.secondaryText = billing.secondaryText ?? result.secondaryText
            result.detailText = billing.detailText
        }

        return result
    }

    private static func validateKey(apiKey: String) async -> Int? {
        var req = URLRequest(url: modelsEndpoint)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("QuotaGlass", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (root["data"] as? [Any])?.count ?? 0
    }

    private static func configuredUsageEndpoint() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let raw = env["QG_SAKANA_USAGE_URL"] ?? env["QG_SAKANA_BILLING_URL"]
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func fetchBilling(apiKey: String, endpoint: URL) async -> SakanaUsageResult? {
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("QuotaGlass", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 25
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseBilling(root)
    }

    private static func fetchConsoleBilling() async -> SakanaUsageResult? {
        guard let cookieHeader = await SakanaConsoleSession.cookieHeader() else { return nil }
        var req = URLRequest(url: billingEndpoint)
        req.setValue("1", forHTTPHeaderField: "RSC")
        req.setValue("1", forHTTPHeaderField: "Next-Router-Prefetch")
        req.setValue("text/x-component", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("https://console.sakana.ai/billing?tab=payAsYouGo", forHTTPHeaderField: "Referer")
        req.setValue("QuotaGlass", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 25
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8),
              !text.contains("Login with Google") else {
            return nil
        }
        return parseConsoleBilling(text)
    }

    static func parseConsoleBilling(_ text: String) -> SakanaUsageResult? {
        let fiveUsed = firstRegexNumber(in: text, pattern: #"5-hour[\s\S]{0,400}?([0-9]+(?:\.[0-9]+)?)% used"#)
        let weeklyUsed = firstRegexNumber(in: text, pattern: #"Weekly[\s\S]{0,400}?([0-9]+(?:\.[0-9]+)?)% used"#)
        let datePattern = #"([A-Za-z]+ \d{1,2}, \d{4} at \d{1,2}:\d{2} [AP]M)"#
        let fiveReset = firstRegexString(in: text, pattern: #"5-hour[\s\S]{0,400}?Resets on\s+\#(datePattern)"#).flatMap(parseConsoleDate)
        let weeklyReset = firstRegexString(in: text, pattern: #"Weekly[\s\S]{0,400}?Resets on\s+\#(datePattern)"#).flatMap(parseConsoleDate)
        let credit = firstRegexNumber(in: text, pattern: #"Credit balance[\s\S]{0,300}?\$([0-9,]+(?:\.[0-9]+)?)"#)
        let paygTotal = firstRegexNumber(in: text, pattern: #"Total:\s*\$([0-9,]+(?:\.[0-9]+)?)"#)
        let plan = firstRegexString(in: text, pattern: #"\b(Standard|Pro|Max)\b"#)

        guard fiveUsed != nil || weeklyUsed != nil || credit != nil || paygTotal != nil else { return nil }

        let five = fiveUsed.map { NativeWindow(usedPercent: $0, resetsAt: fiveReset) }
        let weekly = weeklyUsed.map { NativeWindow(usedPercent: $0, resetsAt: weeklyReset) }
        let primary = paygTotal.map { money($0) } ?? five.map { "\(Int(max(0, min(100, 100 - $0.usedPercent)).rounded()))% left" } ?? "Console"
        let secondary = credit.map { "\(money($0)) credit" }
            ?? weekly.map { "WK \(Int(max(0, min(100, 100 - $0.usedPercent)).rounded()))%" }

        return SakanaUsageResult(
            five: five,
            weekly: weekly,
            plan: plan ?? "API",
            primaryText: primary,
            secondaryText: secondary,
            detailText: "console billing"
        )
    }

    private static func parseBilling(_ root: [String: Any]) -> SakanaUsageResult {
        let five = parseWindow(firstDict(root, keys: ["five_hour", "fiveHour", "primary_window", "primaryWindow"]))
        let weekly = parseWindow(firstDict(root, keys: ["weekly", "seven_day", "sevenDay", "secondary_window", "secondaryWindow"]))
        let cost = firstNumber(root, keys: ["current_period_usage_usd", "currentPeriodUsageUsd", "total_cost_usd", "totalCostUsd", "used_amount_usd", "usedAmountUsd", "amount_usd", "amountUsd"])
        let credit = firstNumber(root, keys: ["credit_balance_usd", "creditBalanceUsd", "remaining_credit_usd", "remainingCreditUsd", "balance_usd", "balanceUsd"])
        let tokens = firstNumber(root, keys: ["total_tokens", "totalTokens"])
        let plan = firstString(root, keys: ["plan", "plan_type", "planType", "billing_mode", "billingMode"])

        let primary: String
        if let cost {
            primary = money(cost)
        } else if let tokens {
            primary = compactTokenCount(tokens)
        } else if let five {
            primary = "\(Int(max(0, min(100, 100 - five.usedPercent)).rounded()))% left"
        } else {
            primary = "Usage"
        }

        let secondary: String?
        if let credit {
            secondary = "\(money(credit)) credit"
        } else if let weekly {
            secondary = "WK \(Int(max(0, min(100, 100 - weekly.usedPercent)).rounded()))%"
        } else {
            secondary = nil
        }

        return SakanaUsageResult(
            five: five,
            weekly: weekly,
            plan: plan,
            primaryText: primary,
            secondaryText: secondary,
            detailText: "billing JSON"
        )
    }

    private static func parseWindow(_ dict: [String: Any]?) -> NativeWindow? {
        guard let dict else { return nil }
        let used = number(dict["used_percent"])
            ?? number(dict["usedPercent"])
            ?? number(dict["utilization"])
            ?? number(dict["used"])
            ?? 0
        var resetsAt: Date?
        if let s = dict["resets_at"] as? String ?? dict["reset_at"] as? String ?? dict["resetAt"] as? String {
            resetsAt = parseDate(s)
        } else if let n = number(dict["resets_at"] ?? dict["reset_at"] ?? dict["resetAt"]) {
            resetsAt = Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
        } else if let n = number(dict["reset_after_seconds"] ?? dict["resetAfterSeconds"]) {
            resetsAt = Date(timeIntervalSinceNow: n)
        }
        return NativeWindow(usedPercent: used, resetsAt: resetsAt)
    }

    private static func firstDict(_ root: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let dict = root[key] as? [String: Any] { return dict }
        }
        for value in root.values {
            if let dict = value as? [String: Any], let found = firstDict(dict, keys: keys) { return found }
            if let array = value as? [[String: Any]] {
                for item in array {
                    if let found = firstDict(item, keys: keys) { return found }
                }
            }
        }
        return nil
    }

    private static func firstNumber(_ root: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = number(root[key]) { return value }
        }
        for value in root.values {
            if let dict = value as? [String: Any], let found = firstNumber(dict, keys: keys) { return found }
            if let array = value as? [[String: Any]] {
                for item in array {
                    if let found = firstNumber(item, keys: keys) { return found }
                }
            }
        }
        return nil
    }

    private static func firstString(_ root: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = root[key] as? String, !value.isEmpty { return value }
        }
        for value in root.values {
            if let dict = value as? [String: Any], let found = firstString(dict, keys: keys) { return found }
            if let array = value as? [[String: Any]] {
                for item in array {
                    if let found = firstString(item, keys: keys) { return found }
                }
            }
        }
        return nil
    }

    private static func number(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let value = any as? String { return Double(value) }
        return nil
    }

    private static func firstRegexNumber(in text: String, pattern: String) -> Double? {
        guard let raw = firstRegexString(in: text, pattern: pattern) else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: ""))
    }

    private static func firstRegexString(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func parseConsoleDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return formatter.date(from: value)
    }

    private static func parseDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }

    private static func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = value < 10 ? 2 : 0
        return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
    }

    private static func compactTokenCount(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM tok", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK tok", value / 1_000) }
        return "\(Int(value.rounded())) tok"
    }
}

enum SakanaUsageCache {
    private static let prefix = "sakana.console.visible."

    static func save(_ usage: SakanaUsageResult) {
        let defaults = UserDefaults.standard
        defaults.set(usage.five?.usedPercent, forKey: prefix + "fiveUsed")
        defaults.set(usage.five?.resetsAt?.timeIntervalSince1970, forKey: prefix + "fiveReset")
        defaults.set(usage.weekly?.usedPercent, forKey: prefix + "weeklyUsed")
        defaults.set(usage.weekly?.resetsAt?.timeIntervalSince1970, forKey: prefix + "weeklyReset")
        defaults.set(usage.plan, forKey: prefix + "plan")
        defaults.set(usage.primaryText, forKey: prefix + "primary")
        defaults.set(usage.secondaryText, forKey: prefix + "secondary")
        defaults.set(Date().timeIntervalSince1970, forKey: prefix + "savedAt")
    }

    static func load() -> SakanaUsageResult? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: prefix + "savedAt") != nil else { return nil }
        let five = window(defaults: defaults, usedKey: "fiveUsed", resetKey: "fiveReset")
        let weekly = window(defaults: defaults, usedKey: "weeklyUsed", resetKey: "weeklyReset")
        guard five != nil || weekly != nil else { return nil }
        return SakanaUsageResult(
            five: five,
            weekly: weekly,
            plan: defaults.string(forKey: prefix + "plan"),
            primaryText: defaults.string(forKey: prefix + "primary") ?? "Console",
            secondaryText: defaults.string(forKey: prefix + "secondary"),
            detailText: "console page"
        )
    }

    private static func window(defaults: UserDefaults, usedKey: String, resetKey: String) -> NativeWindow? {
        guard defaults.object(forKey: prefix + usedKey) != nil else { return nil }
        let reset: Date?
        if defaults.object(forKey: prefix + resetKey) != nil {
            reset = Date(timeIntervalSince1970: defaults.double(forKey: prefix + resetKey))
        } else {
            reset = nil
        }
        return NativeWindow(usedPercent: defaults.double(forKey: prefix + usedKey), resetsAt: reset)
    }
}

enum SakanaConsoleSession {
    @MainActor
    static func cookieHeader() async -> String? {
        let wkCookies = await webKitCookies()
        let storageCookies = sharedStorageCookies()
        let relevant = relevantCookies(from: deduplicate(wkCookies + storageCookies))
        guard !relevant.isEmpty else { return nil }
        return cookieHeader(from: relevant)
    }

    @MainActor
    static func webKitCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    static func sharedStorageCookies() -> [HTTPCookie] {
        HTTPCookieStorage.shared.cookies ?? []
    }

    static func relevantCookies(from cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { cookie in
            cookie.domain == "console.sakana.ai"
                || cookie.domain == ".console.sakana.ai"
                || cookie.domain == ".sakana.ai"
                || cookie.domain.hasSuffix(".sakana.ai")
        }
    }

    static func cookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    static func deduplicate(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        var seen: Set<String> = []
        var result: [HTTPCookie] = []
        for cookie in cookies.reversed() {
            let key = [cookie.domain, cookie.path, cookie.name].joined(separator: "\u{1F}")
            if seen.insert(key).inserted { result.append(cookie) }
        }
        return result.reversed()
    }
}

// MARK: - Provider

struct NativeQuotaProvider {
    func loadQuotas() async throws -> [QuotaSnapshot] {
        var result: [QuotaSnapshot] = []

        for var codex in codexAccounts() {
            if let token = await CodexRefresher.ensureFresh(&codex),
               let usage = await CodexUsage.fetch(accessToken: token, accountId: codex.accountId) {
                result.append(snapshot(
                    service: "Codex",
                    account: codex.email ?? "Codex",
                    plan: codex.planType,
                    five: usage.five,
                    weekly: usage.weekly,
                    importedId: codex.importedId
                ))
            }
        }

        for var claude in ClaudeAuthReader.loadAll() {
            if let token = await ClaudeRefresher.ensureFresh(&claude),
               let usage = await ClaudeUsage.fetch(accessToken: token) {
                var importedId: String?
                if case .imported(let id) = claude.source { importedId = id }
                result.append(snapshot(
                    service: "Claude",
                    account: claude.displayAccount,
                    plan: claude.subscriptionType,
                    five: usage.five,
                    weekly: usage.weekly,
                    importedId: importedId
                ))
            }
        }

        let sakanaAccounts = SakanaAuthReader.loadAll()
        for sakana in sakanaAccounts {
            if let usage = await SakanaUsage.fetch(apiKey: sakana.apiKey) {
                result.append(sakanaSnapshot(account: sakana.accountName, usage: usage))
            }
        }
        if sakanaAccounts.isEmpty, let usage = await SakanaUsage.fetch(apiKey: nil) {
            result.append(sakanaSnapshot(account: "Console", usage: usage))
        }

        if result.isEmpty { throw NativeQuotaError.noCredentials }
        return result
    }

    /// The default auth.json account plus OAuth-imported ones, deduplicated by
    /// chatgpt_account_id (an imported copy of the CLI's account is dropped).
    private func codexAccounts() -> [NativeCodexAccount] {
        var accounts: [NativeCodexAccount] = []
        if let def = CodexAuthReader.load() { accounts.append(def) }
        let defaultAccountId = accounts.first?.accountId

        for imported in ImportedAccountStore.loadAll() where imported.service == .codex {
            if let defaultAccountId, imported.id.hasPrefix(defaultAccountId) { continue }
            guard let tokens = ImportedAccountStore.loadTokens(accountId: ImportedAccountStore.tokenKey(imported)) else { continue }
            accounts.append(NativeCodexAccount(
                email: imported.email,
                planType: imported.planType,
                accountId: imported.id.split(separator: ":").first.map(String.init),
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                idToken: tokens.idToken,
                importedId: imported.id
            ))
        }
        return accounts
    }

    private func snapshot(service: String, account: String, plan: String?, five: NativeWindow?, weekly: NativeWindow?, importedId: String?) -> QuotaSnapshot {
        QuotaSnapshot(
            serviceName: service,
            accountName: account,
            planName: planLabel(plan),
            fiveHourUsed: five?.usedPercent ?? 0,
            weeklyUsed: weekly?.usedPercent ?? 0,
            fiveHourReset: NativeQuotaProvider.formatReset(five?.resetsAt),
            weeklyReset: NativeQuotaProvider.formatReset(weekly?.resetsAt),
            source: importedId == nil ? "Native" : "Imported",
            fetchedAt: Date(),
            importedId: importedId
        )
    }

    private func sakanaSnapshot(account: String, usage: SakanaUsageResult) -> QuotaSnapshot {
        QuotaSnapshot(
            serviceName: "Sakana API",
            accountName: account,
            planName: planLabel(usage.plan),
            fiveHourUsed: usage.five?.usedPercent ?? 0,
            weeklyUsed: usage.weekly?.usedPercent ?? 0,
            fiveHourReset: NativeQuotaProvider.formatReset(usage.five?.resetsAt),
            weeklyReset: NativeQuotaProvider.formatReset(usage.weekly?.resetsAt),
            source: "Native",
            fetchedAt: Date(),
            presentation: .apiUsage,
            apiPrimaryText: usage.primaryText,
            apiSecondaryText: usage.secondaryText,
            apiDetailText: usage.detailText,
            importedId: nil
        )
    }

    private func planLabel(_ plan: String?) -> String {
        guard let plan, !plan.isEmpty else { return "" }
        let lower = plan.lowercased()
        if lower == "api" { return "API" }
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
