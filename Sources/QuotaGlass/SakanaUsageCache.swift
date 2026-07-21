import Foundation

enum SakanaUsageCache {
    private static let basePrefix = "sakana.console.visible.v2."
    private static let currentSessionKey = basePrefix + "currentSession"
    /// Console HTML changes frequently; a cache is a short outage fallback,
    /// not an indefinite source of seemingly live billing data.
    private static let maximumAge: TimeInterval = 15 * 60

    static func save(
        _ usage: SakanaUsageResult,
        sessionKey: String,
        defaults: UserDefaults = .standard
    ) {
        if let previous = defaults.string(forKey: currentSessionKey), previous != sessionKey {
            clear(sessionKey: previous, defaults: defaults)
        }
        let prefix = cachePrefix(sessionKey)
        defaults.set(usage.five?.usedPercent, forKey: prefix + "fiveUsed")
        defaults.set(usage.five?.resetsAt?.timeIntervalSince1970, forKey: prefix + "fiveReset")
        defaults.set(usage.weekly?.usedPercent, forKey: prefix + "weeklyUsed")
        defaults.set(usage.weekly?.resetsAt?.timeIntervalSince1970, forKey: prefix + "weeklyReset")
        defaults.set(usage.plan, forKey: prefix + "plan")
        defaults.set(usage.primaryText, forKey: prefix + "primary")
        defaults.set(usage.secondaryText, forKey: prefix + "secondary")
        defaults.set(usage.detailText, forKey: prefix + "detail")
        defaults.set(Date().timeIntervalSince1970, forKey: prefix + "savedAt")
        defaults.set(sessionKey, forKey: currentSessionKey)
    }

    static func load(
        sessionKey: String,
        maxAge: TimeInterval = maximumAge,
        defaults: UserDefaults = .standard
    ) -> SakanaUsageResult? {
        let prefix = cachePrefix(sessionKey)
        guard defaults.object(forKey: prefix + "savedAt") != nil else { return nil }
        let savedAt = Date(timeIntervalSince1970: defaults.double(forKey: prefix + "savedAt"))
        let age = Date().timeIntervalSince(savedAt)
        guard age >= -60, age <= maxAge else { return nil }
        let five = window(defaults: defaults, prefix: prefix, usedKey: "fiveUsed", resetKey: "fiveReset")
        let weekly = window(defaults: defaults, prefix: prefix, usedKey: "weeklyUsed", resetKey: "weeklyReset")
        guard five != nil || weekly != nil || defaults.string(forKey: prefix + "primary") != nil else { return nil }
        let detail = defaults.string(forKey: prefix + "detail") ?? "console page"
        return SakanaUsageResult(
            five: five,
            weekly: weekly,
            plan: defaults.string(forKey: prefix + "plan"),
            primaryText: defaults.string(forKey: prefix + "primary") ?? "Console",
            secondaryText: defaults.string(forKey: prefix + "secondary"),
            detailText: "\(detail) · cached",
            fetchedAt: savedAt,
            isCached: true
        )
    }

    static func cachePrefix(_ sessionKey: String) -> String {
        basePrefix + sessionKey + "."
    }

    static func clear(sessionKey: String, defaults: UserDefaults = .standard) {
        let prefix = cachePrefix(sessionKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        if defaults.string(forKey: currentSessionKey) == sessionKey {
            defaults.removeObject(forKey: currentSessionKey)
        }
    }

    private static func window(
        defaults: UserDefaults,
        prefix: String,
        usedKey: String,
        resetKey: String
    ) -> NativeWindow? {
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
