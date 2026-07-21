import Foundation
import AppKit

/// Provider-owned identity for one credential/account. The storage key is safe
/// to persist in UserDefaults and never contains an access token or API key.
struct QuotaAccountIdentity: Hashable, Sendable {
    enum Provider: String, Sendable {
        case codex
        case claude
        case sakana
        case debug
    }

    var provider: Provider
    /// Credential channel (for example `account`, `keychain`, or `imported`).
    var source: String
    /// A provider account id or a stable credential-source identifier.
    var stableID: String

    var storageKey: String {
        let encoded = Data(stableID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "account.v2.\(provider.rawValue).\(source).\(encoded)"
    }
}

struct QuotaSnapshot: Identifiable, Equatable, Sendable {
    enum Presentation: Equatable, Sendable {
        case quotaWindows
        case apiUsage
    }

    var identity: QuotaAccountIdentity
    /// SwiftUI identity intentionally follows the provider account identity so
    /// rows survive refreshes without delete/insert animation churn.
    var id: String { identity.storageKey }
    var serviceName: String
    var accountName: String
    var planName: String
    /// Nil means that the provider did not return this window. It must not be
    /// rendered or notified as if it were zero usage / 100% remaining.
    var fiveHourUsed: Double?
    var weeklyUsed: Double?
    var fiveHourReset: String
    var weeklyReset: String
    var source: String
    var fetchedAt: Date
    var presentation: Presentation = .quotaWindows
    var apiPrimaryText: String? = nil
    var apiSecondaryText: String? = nil
    var apiDetailText: String? = nil
    var warningText: String? = nil
    /// Set when this account was added via in-app OAuth login (removable in settings).
    var importedId: String? = nil
    /// True when the displayed values did not come from a live successful fetch.
    var isStale: Bool = false
    /// Account-scoped refresh failure retained for diagnostics/UI presentation.
    var refreshErrorText: String? = nil

    var fiveHourRemaining: Double? { fiveHourUsed.map { max(0, min(100, 100 - $0)) } }
    var weeklyRemaining: Double? { weeklyUsed.map { max(0, min(100, 100 - $0)) } }

    /// Used percentage (clamped) — this is what the "用量" UI shows.
    var fiveHourUsedPct: Double? { fiveHourUsed.map { max(0, min(100, $0)) } }
    var weeklyUsedPct: Double? { weeklyUsed.map { max(0, min(100, $0)) } }
    var hasWindowData: Bool { fiveHourUsed != nil || weeklyUsed != nil }

    /// Short label for the account. Claude Code cloud profiles often have no
    /// email in their credential blob, so preserve their keychain suffix here.
    var displaySubtitle: String {
        if isClaude, shouldShowAccountNameWithPlan {
            return "\(accountName) · \(planName)"
        }
        if !planName.isEmpty && planName != "Account" { return planName }
        return accountName
    }

    private var shouldShowAccountNameWithPlan: Bool {
        !accountName.isEmpty
            && accountName != "Default"
            && !accountName.contains("@")
            && !planName.isEmpty
            && planName != "Account"
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
    @Published private(set) var linkedImportedAccountKeys = Set<String>()

    var onChange: (() -> Void)?

    private let loadQuotas: @Sendable () async -> NativeQuotaLoadReport
    private let notifyFreshQuotas: ([QuotaSnapshot]) -> Void
    private let minimumRefreshInterval: TimeInterval = 60

    // Per-account cache so a transient fetch failure for one account never makes
    // it vanish from the UI. Keys are provider-owned stable account identities.
    private var cache: [String: QuotaSnapshot] = [:]
    private var orderKeys: [String] = []

    // All refresh entry points join this task. The generation check also prevents
    // a cancelled/invalidated request from committing after a newer refresh.
    private var refreshTask: Task<NativeQuotaLoadReport, Never>?
    private var refreshGeneration = 0
    private var activeRefreshGeneration = 0

    init(
        loadQuotas: @escaping @Sendable () async -> NativeQuotaLoadReport = {
            await NativeQuotaProvider().loadQuotas()
        },
        notifyFreshQuotas: @escaping ([QuotaSnapshot]) -> Void = {
            QuotaNotifier.shared.evaluate($0)
        }
    ) {
        self.loadQuotas = loadQuotas
        self.notifyFreshQuotas = notifyFreshQuotas
    }

    private func key(for snapshot: QuotaSnapshot) -> String {
        accountKey(snapshot)
    }

    func primaryQuota(matching name: String) -> QuotaSnapshot? {
        quotas.first { $0.serviceName.localizedCaseInsensitiveContains(name) }
    }

    func refreshIfStale() async {
        await refreshIfOlder(than: minimumRefreshInterval)
    }

    /// Refresh only when the last live successful fetch is older than `interval`.
    func refreshIfOlder(than interval: TimeInterval) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < interval { return }
        await refresh()
    }

    func refresh() async {
        let task: Task<NativeQuotaLoadReport, Never>
        let generation: Int

        if let inFlight = refreshTask {
            task = inFlight
            generation = activeRefreshGeneration
        } else {
            state = .loading
            refreshGeneration += 1
            generation = refreshGeneration
            activeRefreshGeneration = generation
            let loadQuotas = loadQuotas
            task = Task { await loadQuotas() }
            refreshTask = task
        }

        let report = await task.value
        guard generation == activeRefreshGeneration,
              generation == refreshGeneration,
              refreshTask != nil else { return }

        // Whichever waiter resumes first commits the shared result exactly once.
        refreshTask = nil
        apply(report)
    }

    /// Internal so pure merge/staleness behavior can be covered without network I/O.
    func apply(_ report: NativeQuotaLoadReport) {
        let successful = report.successes
        linkedImportedAccountKeys = report.linkedImportedAccountKeys

        // QG_SNAPSHOT is an explicit visual-debug entry point. Demo rows never
        // appear in a normal production launch, including a cold-start failure.
        if successful.isEmpty,
           ProcessInfo.processInfo.environment["QG_SNAPSHOT"] != nil {
            merge(Self.demoQuotas())
            lastRefresh = Date()
            state = .loaded
            return
        }

        merge(successful)
        removeLinkedImportedSnapshots(report.linkedImportedAccountKeys)
        markFailures(report.failures)
        let missingCount = markUnobservedCachedAccounts(
            observed: Set(successful.map(\.identity.storageKey) + report.failures.map(\.identity.storageKey))
        )

        if report.credentialCount == 0, report.failures.isEmpty {
            let reason = report.globalErrors.first ?? "未发现可用凭据"
            markAllCachedStale(reason: reason)
            state = .failed(report.globalErrors.first ?? "未发现 Codex、Claude 或 Sakana 凭据")
            return
        }

        let fresh = successful.filter { !$0.isStale }
        if !fresh.isEmpty {
            lastRefresh = Date()
            // Notifications must only inspect values confirmed by this live fetch.
            notifyFreshQuotas(fresh)
        }

        let issueCount = report.failures.count + missingCount
        if !report.globalErrors.isEmpty {
            let suffix = successful.isEmpty ? "" : "，其他账号已更新"
            state = .failed(report.globalErrors.joined(separator: "；") + suffix)
        } else if issueCount > 0 {
            let suffix = successful.isEmpty ? "" : "，其他账号已更新"
            let retained = cache.isEmpty ? "" : "，已保留旧数据"
            state = .failed("\(issueCount) 个账号刷新失败或凭据已不可用\(retained)\(suffix)")
        } else if fresh.isEmpty, !successful.isEmpty {
            state = .failed("当前仅有缓存数据，未取得实时用量")
        } else {
            state = .loaded
        }
    }

    /// Drop a removed imported account from the cache immediately (the merge
    /// path retains absent accounts by design, so removal must be explicit).
    func removeQuota(key: String) {
        invalidateRefresh()
        cache.removeValue(forKey: key)
        orderKeys.removeAll { $0 == key }
        rebuild()
    }

    /// Credential/session persistence is a side effect that changes discovery.
    /// Cancel any request prepared from the old credential set before mutating it.
    func cancelRefreshForCredentialMutation() {
        invalidateRefresh()
    }

    /// Never join an in-flight request that was prepared before a credential or
    /// browser-session change.
    func forceRefresh() async {
        invalidateRefresh()
        await refresh()
    }

    func archiveQuota(key: String) {
        cache.removeValue(forKey: key)
        orderKeys.removeAll { $0 == key }
        rebuild()
    }

    func applyVisibilityPreferences() {
        rebuild()
    }

    private func invalidateRefresh() {
        refreshGeneration += 1
        activeRefreshGeneration = refreshGeneration
        refreshTask?.cancel()
        refreshTask = nil
        if state == .loading {
            state = cache.isEmpty ? .idle : .loaded
        }
    }

    /// Merge successful snapshots into the cache. A provider may deliberately
    /// return a stale snapshot (currently a TTL-bounded Sakana console cache).
    private func merge(_ fresh: [QuotaSnapshot]) {
        if fresh.contains(where: { $0.source != "Demo" }) {
            removeDemoSnapshots()
        }
        for snapshot in fresh {
            migrateLegacyPreferences(for: snapshot)
            let k = key(for: snapshot)
            if cache[k] == nil { orderKeys.append(k) }
            cache[k] = snapshot
        }
        rebuild()
    }

    private func markFailures(_ failures: [NativeQuotaFailure]) {
        for failure in failures {
            let key = failure.identity.storageKey
            cache[key]?.isStale = true
            cache[key]?.refreshErrorText = failure.message
        }
        rebuild()
    }

    /// If a newly discovered CLI credential is byte-for-byte the same login as
    /// an imported one, keep the removable metadata row but collapse any older
    /// imported quota snapshot into the canonical live row.
    private func removeLinkedImportedSnapshots(_ linkedKeys: Set<String>) {
        guard !linkedKeys.isEmpty else { return }
        let keysToRemove = cache.compactMap { key, snapshot -> String? in
            guard let importedId = snapshot.importedId else { return nil }
            let linkedKey: String
            switch snapshot.identity.provider {
            case .codex:
                linkedKey = ImportedAccountStore.tokenKey(service: .codex, id: importedId)
            case .claude:
                linkedKey = ImportedAccountStore.tokenKey(service: .claude, id: importedId)
            case .sakana, .debug:
                return nil
            }
            return linkedKeys.contains(linkedKey) ? key : nil
        }
        guard !keysToRemove.isEmpty else { return }
        for key in keysToRemove { cache.removeValue(forKey: key) }
        orderKeys.removeAll { keysToRemove.contains($0) }
        rebuild()
    }

    private func markAllCachedStale(reason: String) {
        for key in cache.keys {
            cache[key]?.isStale = true
            cache[key]?.refreshErrorText = reason
        }
        rebuild()
    }

    @discardableResult
    private func markUnobservedCachedAccounts(observed: Set<String>) -> Int {
        var count = 0
        for key in cache.keys where !observed.contains(key) && cache[key]?.source != "Demo" {
            count += 1
            cache[key]?.isStale = true
            cache[key]?.refreshErrorText = "本轮未发现该账号凭据"
        }
        if count > 0 { rebuild() }
        return count
    }

    private func migrateLegacyPreferences(for snapshot: QuotaSnapshot) {
        let oldKey = legacyAccountKey(snapshot)
        let newKey = accountKey(snapshot)
        guard oldKey != newKey else { return }

        AliasStore.shared.migrateAlias(from: oldKey, to: newKey)

        let prefs = PrefsStore.shared
        if prefs.menuBarShow[newKey] == nil, let legacy = prefs.menuBarShow[oldKey] {
            // Keep the legacy entry: one old display-name key may legitimately
            // fan out to multiple newly distinguishable provider accounts.
            prefs.menuBarShow[newKey] = legacy
        }
        if prefs.archivedAccountKeys.contains(oldKey),
           !prefs.archivedAccountKeys.contains(newKey) {
            prefs.archivedAccountKeys.insert(newKey)
        }
    }

    private func rebuild() {
        let archived = PrefsStore.shared.archivedAccountKeys
        let next = orderKeys
            .filter { !archived.contains($0) }
            .compactMap { cache[$0] }
        // Skip no-op assignments: each publish re-renders the popover and
        // re-rasterizes the menu-bar badge, and one apply() can rebuild
        // several times in a row.
        guard next != quotas else { return }
        quotas = next
    }

    private func removeDemoSnapshots() {
        let demoKeys = cache.filter { $0.value.source == "Demo" }.map(\.key)
        for key in demoKeys {
            cache.removeValue(forKey: key)
            orderKeys.removeAll { $0 == key }
        }
    }

    static func demoQuotas() -> [QuotaSnapshot] {
        let now = Date()
        return [
            QuotaSnapshot(
                identity: .init(provider: .debug, source: "snapshot", stableID: "codex"),
                serviceName: "Codex",
                accountName: "Demo",
                planName: "Pro",
                fiveHourUsed: 3,
                weeklyUsed: 28,
                fiveHourReset: "4h 48m",
                weeklyReset: "5d 17h",
                source: "Demo",
                fetchedAt: now
            ),
            QuotaSnapshot(
                identity: .init(provider: .debug, source: "snapshot", stableID: "claude"),
                serviceName: "Claude",
                accountName: "Demo",
                planName: "Max",
                fiveHourUsed: 18,
                weeklyUsed: 42,
                fiveHourReset: "3h 12m",
                weeklyReset: "4d 09h",
                source: "Demo",
                fetchedAt: now
            ),
        ]
    }
}
