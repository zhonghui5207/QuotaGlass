import Foundation
import AppKit

struct QuotaSnapshot: Identifiable, Equatable {
    enum Presentation: Equatable {
        case quotaWindows
        case apiUsage
    }

    let id = UUID()
    var serviceName: String
    var accountName: String
    var planName: String
    var fiveHourUsed: Double
    var weeklyUsed: Double
    var fiveHourReset: String
    var weeklyReset: String
    var source: String
    var fetchedAt: Date
    var presentation: Presentation = .quotaWindows
    var apiPrimaryText: String? = nil
    var apiSecondaryText: String? = nil
    var apiDetailText: String? = nil
    /// Set when this account was added via in-app OAuth login (removable in settings).
    var importedId: String? = nil
    /// True when this snapshot is retained from a previous successful fetch
    /// because the latest refresh did not include this account.
    var isStale: Bool = false

    var fiveHourRemaining: Double { max(0, min(100, 100 - fiveHourUsed)) }
    var weeklyRemaining: Double { max(0, min(100, 100 - weeklyUsed)) }

    /// Used percentage (clamped) — this is what the "用量" UI shows.
    var fiveHourUsedPct: Double { max(0, min(100, fiveHourUsed)) }
    var weeklyUsedPct: Double { max(0, min(100, weeklyUsed)) }

    /// Short label for the account, preferring a real plan name over the generic "Account".
    var displaySubtitle: String {
        if !planName.isEmpty && planName != "Account" { return planName }
        return accountName
    }

    var isClaude: Bool { serviceName.localizedCaseInsensitiveContains("Claude") }
    var isCodex: Bool { serviceName.localizedCaseInsensitiveContains("Codex") }
    var isSakana: Bool { serviceName.localizedCaseInsensitiveContains("Sakana") }
    var isAPIUsage: Bool { presentation == .apiUsage }
}

enum QuotaLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var quotas: [QuotaSnapshot] = [] {
        didSet { onChange?() }
    }
    @Published private(set) var state: QuotaLoadState = .idle
    @Published private(set) var lastRefresh: Date?

    var onChange: (() -> Void)?

    private let provider = NativeQuotaProvider()
    private let minimumRefreshInterval: TimeInterval = 60

    // Per-account cache so a transient fetch failure for one account never makes
    // it vanish from the UI. Keyed by service+account, ordered by first-seen.
    private var cache: [String: QuotaSnapshot] = [:]
    private var orderKeys: [String] = []

    private func key(for snapshot: QuotaSnapshot) -> String {
        snapshot.serviceName + "·" + snapshot.accountName
    }

    func primaryQuota(matching name: String) -> QuotaSnapshot? {
        quotas.first { $0.serviceName.localizedCaseInsensitiveContains(name) }
    }

    func refreshIfStale() async {
        await refreshIfOlder(than: minimumRefreshInterval)
    }

    /// Refresh only when the last successful fetch is older than `interval`.
    func refreshIfOlder(than interval: TimeInterval) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < interval { return }
        await refresh()
    }

    func refresh() async {
        state = .loading
        do {
            let fresh = try await provider.loadQuotas()
            merge(fresh)
            lastRefresh = Date()
            state = .loaded
            QuotaNotifier.shared.evaluate(quotas)
        } catch {
            // Total failure: keep whatever we already have (marked stale) rather
            // than wiping the UI; only fall back to demo data on a cold start.
            if cache.isEmpty {
                merge(Self.demoQuotas())
            } else {
                for k in cache.keys { cache[k]?.isStale = true }
                rebuild()
            }
            state = .failed(error.localizedDescription)
        }
    }

    /// Drop a removed imported account from the cache immediately (the merge
    /// path retains absent accounts by design, so removal must be explicit).
    func removeQuota(importedId: String) {
        let keys = cache.filter { $0.value.importedId == importedId }.map(\.key)
        for k in keys {
            cache.removeValue(forKey: k)
            orderKeys.removeAll { $0 == k }
        }
        rebuild()
    }

    /// Merge fresh snapshots into the cache. Accounts present in `fresh` are
    /// updated (live); accounts absent this round are retained from cache.
    private func merge(_ fresh: [QuotaSnapshot]) {
        for var snapshot in fresh {
            snapshot.isStale = false
            let k = key(for: snapshot)
            if cache[k] == nil { orderKeys.append(k) }
            cache[k] = snapshot
        }
        rebuild()
    }

    private func rebuild() {
        quotas = orderKeys.compactMap { cache[$0] }
    }

    static func demoQuotas() -> [QuotaSnapshot] {
        let now = Date()
        return [
            QuotaSnapshot(serviceName: "Codex", accountName: "Demo", planName: "Pro", fiveHourUsed: 3, weeklyUsed: 28, fiveHourReset: "4h 48m", weeklyReset: "5d 17h", source: "Demo", fetchedAt: now),
            QuotaSnapshot(serviceName: "Claude", accountName: "Demo", planName: "Max", fiveHourUsed: 18, weeklyUsed: 42, fiveHourReset: "3h 12m", weeklyReset: "4d 09h", source: "Demo", fetchedAt: now)
        ]
    }
}
