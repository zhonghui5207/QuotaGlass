import Foundation

// MARK: - Sakana

struct SakanaUsageResult: Sendable {
    var five: NativeWindow?
    var weekly: NativeWindow?
    var plan: String?
    var primaryText: String
    var secondaryText: String?
    var detailText: String?
    var fetchedAt: Date = Date()
    /// A bounded console cache is useful fallback data, but is never live data.
    var isCached: Bool = false
}

enum SakanaUsageFetchOutcome: Sendable {
    case success(SakanaUsageResult)
    /// No API key, browser session, or unexpired console cache was present.
    case unavailable
    case failure(String)
}

/// API-key requests never follow redirects: otherwise a configured endpoint
/// could move the bearer credential outside the host policy checked below.
private final class SakanaNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum SakanaUsage {
    static let modelsEndpoint = URL(string: "https://api.sakana.ai/v1/models")!
    static let billingEndpoint = URL(string: "https://console.sakana.ai/billing?_rsc=quotaglass")!

    /// One shared ephemeral session for redirect-blocking requests. The
    /// delegate is stateless, so the previous per-request session creation
    /// (plus immediate invalidation) was pure churn.
    private static let noRedirectSession: URLSession = {
        URLSession(configuration: .ephemeral, delegate: SakanaNoRedirectDelegate(), delegateQueue: nil)
    }()

    @MainActor
    static func debugReport() async -> String {
        var lines: [String] = ["Sakana debug:"]
        let wkCookies = await SakanaConsoleSession.webKitCookies()
        let storageCookies = SakanaConsoleSession.sharedStorageCookies()
        // WebKit is the source the user can see and just authenticated in. Put
        // it last because deduplicate intentionally keeps the last duplicate.
        let cookies = SakanaConsoleSession.deduplicate(storageCookies + wkCookies)
        let relevant = SakanaConsoleSession.cookies(for: billingEndpoint, from: cookies)
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
            let (data, resp) = try await dataWithoutRedirect(for: req)
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

    static func fetchOutcome(apiKey: String?) async -> SakanaUsageFetchOutcome {
        if let apiKey {
            guard let modelCount = await validateKey(apiKey: apiKey) else {
                return .failure("Sakana API key 验证失败")
            }

            var result = SakanaUsageResult(
                five: nil,
                weekly: nil,
                plan: "API",
                primaryText: "API key OK",
                secondaryText: "\(modelCount) models",
                detailText: "API key validated"
            )

            // Billing returned for one key must never be overlaid with the
            // browser-console cache (which may belong to another organization).
            if let endpoint = configuredUsageEndpoint() {
                if let billing = await fetchBilling(apiKey: apiKey, endpoint: endpoint) {
                    result = billing
                } else {
                    result.detailText = "API key validated · billing unavailable"
                }
            }
            return .success(result)
        }

        guard let session = await SakanaConsoleSession.session() else { return .unavailable }
        let cached = SakanaUsageCache.load(sessionKey: session.cacheKey)

        if let billing = await fetchConsoleBilling(cookieHeader: session.cookieHeader) {
            SakanaUsageCache.save(billing, sessionKey: session.cacheKey)
            return .success(billing)
        }
        if let cached { return .success(cached) }
        return .failure("Sakana Console 用量请求失败")
    }

    private static func validateKey(apiKey: String) async -> Int? {
        var req = URLRequest(url: modelsEndpoint)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("QuotaGlass", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await dataWithoutRedirect(for: req),
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
        return validatedUsageEndpoint(
            raw,
            allowExternal: env["QG_ALLOW_EXTERNAL_SAKANA_USAGE_URL"] == "1"
        )
    }

    static func validatedUsageEndpoint(_ raw: String, allowExternal: Bool) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil else { return nil }
        let isSakanaHost = host == "sakana.ai" || host.hasSuffix(".sakana.ai")
        guard isSakanaHost || allowExternal else { return nil }
        return url
    }

    private static func fetchBilling(apiKey: String, endpoint: URL) async -> SakanaUsageResult? {
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("QuotaGlass", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 25
        guard let (data, resp) = try? await dataWithoutRedirect(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseBilling(root)
    }

    private static func dataWithoutRedirect(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await noRedirectSession.data(for: request)
    }

    private static func fetchConsoleBilling(cookieHeader: String) async -> SakanaUsageResult? {
        var req = URLRequest(url: billingEndpoint)
        req.setValue("1", forHTTPHeaderField: "RSC")
        req.setValue("1", forHTTPHeaderField: "Next-Router-Prefetch")
        req.setValue("text/x-component", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("https://console.sakana.ai/billing?tab=payAsYouGo", forHTTPHeaderField: "Referer")
        req.setValue("QuotaGlass", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 25
        guard let (data, resp) = try? await dataWithoutRedirect(for: req),
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
        let fiveReset = firstRegexString(in: text, pattern: #"5-hour[\s\S]{0,400}?Resets on\s+\#(datePattern)"#).flatMap(SharedFormatters.consoleDate)
        let weeklyReset = firstRegexString(in: text, pattern: #"Weekly[\s\S]{0,400}?Resets on\s+\#(datePattern)"#).flatMap(SharedFormatters.consoleDate)
        let credit = firstRegexNumber(in: text, pattern: #"Credit balance[\s\S]{0,300}?\$([0-9,]+(?:\.[0-9]+)?)"#)
        let paygTotal = firstRegexNumber(in: text, pattern: #"Total:\s*\$([0-9,]+(?:\.[0-9]+)?)"#)
        let plan = firstRegexString(in: text, pattern: #"\b(Standard|Pro|Max)\b"#)

        guard fiveUsed != nil || weeklyUsed != nil || credit != nil || paygTotal != nil else { return nil }

        let five = fiveUsed.map { NativeWindow(usedPercent: $0, resetsAt: fiveReset) }
        let weekly = weeklyUsed.map { NativeWindow(usedPercent: $0, resetsAt: weeklyReset) }
        let primary = paygTotal.map { SharedFormatters.usdString(from: $0) } ?? five.map { "\(Int(max(0, min(100, 100 - $0.usedPercent)).rounded()))% left" } ?? "Console"
        let secondary = credit.map { "\(SharedFormatters.usdString(from: $0)) credit" }
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
            primary = SharedFormatters.usdString(from: cost)
        } else if let tokens {
            primary = compactTokenCount(tokens)
        } else if let five {
            primary = "\(Int(max(0, min(100, 100 - five.usedPercent)).rounded()))% left"
        } else {
            primary = "Usage"
        }

        let secondary: String?
        if let credit {
            secondary = "\(SharedFormatters.usdString(from: credit)) credit"
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
        guard let used = number(dict["used_percent"])
            ?? number(dict["usedPercent"])
            ?? number(dict["utilization"])
            ?? number(dict["used"]) else { return nil }
        var resetsAt: Date?
        if let s = dict["resets_at"] as? String ?? dict["reset_at"] as? String ?? dict["resetAt"] as? String {
            resetsAt = SharedFormatters.iso8601Date(from: s)
        } else if let n = number(dict["resets_at"] ?? dict["reset_at"] ?? dict["resetAt"]) {
            resetsAt = Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
        } else if let n = number(dict["reset_after_seconds"] ?? dict["resetAfterSeconds"]) {
            resetsAt = Date(timeIntervalSinceNow: n)
        }
        return NativeWindow(usedPercent: used, resetsAt: resetsAt)
    }

    /// Top-level keys are always checked first (priority-ordered), then the
    /// search recurses — but only this deep. Billing payloads wrap values in at
    /// most a couple of layers; an unbounded search could latch onto an
    /// unrelated deeply-nested field sharing a generic name.
    private static let maximumSearchDepth = 4

    private static func firstDict(_ root: [String: Any], keys: [String], depth: Int = 0) -> [String: Any]? {
        guard depth <= maximumSearchDepth else { return nil }
        for key in keys {
            if let dict = root[key] as? [String: Any] { return dict }
        }
        for value in root.values {
            if let dict = value as? [String: Any], let found = firstDict(dict, keys: keys, depth: depth + 1) { return found }
            if let array = value as? [[String: Any]] {
                for item in array {
                    if let found = firstDict(item, keys: keys, depth: depth + 1) { return found }
                }
            }
        }
        return nil
    }

    private static func firstNumber(_ root: [String: Any], keys: [String], depth: Int = 0) -> Double? {
        guard depth <= maximumSearchDepth else { return nil }
        for key in keys {
            if let value = number(root[key]) { return value }
        }
        for value in root.values {
            if let dict = value as? [String: Any], let found = firstNumber(dict, keys: keys, depth: depth + 1) { return found }
            if let array = value as? [[String: Any]] {
                for item in array {
                    if let found = firstNumber(item, keys: keys, depth: depth + 1) { return found }
                }
            }
        }
        return nil
    }

    private static func firstString(_ root: [String: Any], keys: [String], depth: Int = 0) -> String? {
        guard depth <= maximumSearchDepth else { return nil }
        for key in keys {
            if let value = root[key] as? String, !value.isEmpty { return value }
        }
        for value in root.values {
            if let dict = value as? [String: Any], let found = firstString(dict, keys: keys, depth: depth + 1) { return found }
            if let array = value as? [[String: Any]] {
                for item in array {
                    if let found = firstString(item, keys: keys, depth: depth + 1) { return found }
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

    private static func compactTokenCount(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM tok", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK tok", value / 1_000) }
        return "\(Int(value.rounded())) tok"
    }
}
