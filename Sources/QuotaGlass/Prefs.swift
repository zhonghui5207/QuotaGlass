import Foundation
import ServiceManagement
@preconcurrency import UserNotifications

extension Notification.Name {
    static let qgPrefsChanged = Notification.Name("QGPrefsChanged")
}

/// Accounts shown in the menu bar when the user has not configured anything:
/// the first Codex, Claude, and Sakana API account.
func defaultMenuBarKeys(_ quotas: [QuotaSnapshot]) -> Set<String> {
    var keys = Set<String>()
    if let codex = quotas.first(where: { $0.isCodex }) { keys.insert(accountKey(codex)) }
    if let claude = quotas.first(where: { $0.isClaude }) { keys.insert(accountKey(claude)) }
    if let sakana = quotas.first(where: { $0.isSakana }) { keys.insert(accountKey(sakana)) }
    return keys
}

/// User preferences persisted in UserDefaults (except launch-at-login, which
/// lives in SMAppService).
@MainActor
final class PrefsStore: ObservableObject {
    static let shared = PrefsStore()
    private let defaults = UserDefaults.standard

    /// Per-account menu-bar visibility, keyed by accountKey. Accounts without
    /// an entry follow `defaultMenuBarKeys`.
    @Published var menuBarShow: [String: Bool] {
        didSet {
            defaults.set(menuBarShow, forKey: "menuBarShow")
            NotificationCenter.default.post(name: .qgPrefsChanged, object: nil)
        }
    }

    @Published var archivedAccountKeys: Set<String> {
        didSet {
            defaults.set(Array(archivedAccountKeys).sorted(), forKey: "archivedAccountKeys")
            NotificationCenter.default.post(name: .qgPrefsChanged, object: nil)
        }
    }

    @Published var notifyLowQuota: Bool {
        didSet {
            defaults.set(notifyLowQuota, forKey: "notifyLowQuota")
            if notifyLowQuota {
                QuotaNotifier.requestAuthorization()
            } else {
                QuotaNotifier.shared.reset()
            }
        }
    }

    /// Background refresh cadence in seconds.
    @Published var refreshInterval: Int {
        didSet { defaults.set(refreshInterval, forKey: "refreshInterval") }
    }

    private init() {
        menuBarShow = (defaults.dictionary(forKey: "menuBarShow") as? [String: Bool]) ?? [:]
        let archived = defaults.stringArray(forKey: "archivedAccountKeys")
            ?? defaults.stringArray(forKey: "hiddenAccountKeys")
            ?? []
        archivedAccountKeys = Set(archived)
        notifyLowQuota = defaults.object(forKey: "notifyLowQuota") as? Bool ?? true
        let stored = defaults.integer(forKey: "refreshInterval")
        refreshInterval = stored == 0 ? 300 : stored
        if notifyLowQuota { QuotaNotifier.requestAuthorization() }
    }

    func archiveAccount(key: String) {
        archivedAccountKeys.insert(key)
        menuBarShow[key] = false
    }

    func restoreArchivedAccounts() {
        archivedAccountKeys.removeAll()
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Dev binaries outside an .app bundle can't register; ignore.
        }
        objectWillChange.send()
    }
}

/// Low-quota system notifications: one alert when an account's 5-hour window
/// drops below 30% remaining, another below 10%. Re-arms once the window
/// resets (remaining climbs back above 35%).
@MainActor
final class QuotaNotifier {
    static let shared = QuotaNotifier()
    /// Highest tier already notified per account (1 = <30%, 2 = <10%).
    private var notifiedTier: [String: Int] = [:]
    /// Prevents duplicate submissions while UNUserNotificationCenter is still
    /// processing a previous request for the same account.
    private var pendingTier: [String: Int] = [:]
    private var cycleGeneration: [String: Int] = [:]

    /// UNUserNotificationCenter traps when running as a bare executable.
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func requestAuthorization() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        NSLog("QuotaGlass notification authorization failed: %@", error.localizedDescription)
                    } else if !granted {
                        NSLog("QuotaGlass notification authorization was declined")
                    }
                }
            case .denied:
                NSLog("QuotaGlass notifications are disabled in System Settings")
            case .authorized, .provisional, .ephemeral:
                break
            @unknown default:
                break
            }
        }
    }

    func reset() {
        let keys = Set(notifiedTier.keys).union(pendingTier.keys)
        for key in keys { cycleGeneration[key, default: 0] &+= 1 }
        notifiedTier.removeAll()
        pendingTier.removeAll()
    }

    func evaluate(_ quotas: [QuotaSnapshot]) {
        guard PrefsStore.shared.notifyLowQuota, Self.available else { return }
        for quota in quotas where !quota.isStale {
            if quota.isAPIUsage { continue }
            let key = accountKey(quota)
            guard let remaining = quota.fiveHourRemaining else { continue }
            if remaining >= 35 {
                if notifiedTier[key] != nil || pendingTier[key] != nil {
                    cycleGeneration[key, default: 0] &+= 1
                }
                notifiedTier.removeValue(forKey: key)
                pendingTier.removeValue(forKey: key)
                continue
            }
            let tier = remaining < 10 ? 2 : (remaining < 30 ? 1 : 0)
            let submittedTier = max(notifiedTier[key] ?? 0, pendingTier[key] ?? 0)
            guard tier > submittedTier else { continue }
            pendingTier[key] = tier
            let generation = cycleGeneration[key, default: 0]
            let name = AliasStore.shared.alias(for: key) ?? quota.displaySubtitle
            send(
                title: "\(displayTitle(quota)) · \(name) 额度告警",
                body: "5 小时窗口剩余 \(Int(remaining.rounded()))%，\(quota.fiveHourReset) 重置",
                accountKey: key,
                tier: tier,
                generation: generation
            )
        }
    }

    private func send(title: String, body: String, accountKey: String, tier: Int, generation: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.cycleGeneration[accountKey, default: 0] == generation else { return }
                if self.pendingTier[accountKey] == tier {
                    self.pendingTier.removeValue(forKey: accountKey)
                }
                if let error {
                    NSLog("QuotaGlass notification delivery failed: %@", error.localizedDescription)
                    return
                }
                self.notifiedTier[accountKey] = max(self.notifiedTier[accountKey] ?? 0, tier)
            }
        }
    }
}
