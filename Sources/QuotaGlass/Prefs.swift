import Foundation
import ServiceManagement
import UserNotifications

extension Notification.Name {
    static let qgPrefsChanged = Notification.Name("QGPrefsChanged")
}

/// Accounts shown in the menu bar when the user has not configured anything:
/// the first Codex account plus the first Claude account.
func defaultMenuBarKeys(_ quotas: [QuotaSnapshot]) -> Set<String> {
    var keys = Set<String>()
    if let codex = quotas.first(where: { $0.isCodex }) { keys.insert(accountKey(codex)) }
    if let claude = quotas.first(where: { $0.isClaude }) { keys.insert(accountKey(claude)) }
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

    @Published var notifyLowQuota: Bool {
        didSet {
            defaults.set(notifyLowQuota, forKey: "notifyLowQuota")
            if notifyLowQuota { QuotaNotifier.requestAuthorization() }
        }
    }

    /// Background refresh cadence in seconds.
    @Published var refreshInterval: Int {
        didSet { defaults.set(refreshInterval, forKey: "refreshInterval") }
    }

    private init() {
        menuBarShow = (defaults.dictionary(forKey: "menuBarShow") as? [String: Bool]) ?? [:]
        notifyLowQuota = defaults.object(forKey: "notifyLowQuota") as? Bool ?? true
        let stored = defaults.integer(forKey: "refreshInterval")
        refreshInterval = stored == 0 ? 300 : stored
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

    /// UNUserNotificationCenter traps when running as a bare executable.
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(_ quotas: [QuotaSnapshot]) {
        guard PrefsStore.shared.notifyLowQuota, Self.available else { return }
        for quota in quotas where !quota.isStale {
            let key = accountKey(quota)
            let remaining = quota.fiveHourRemaining
            if remaining >= 35 {
                notifiedTier[key] = 0
                continue
            }
            let tier = remaining < 10 ? 2 : (remaining < 30 ? 1 : 0)
            guard tier > (notifiedTier[key] ?? 0) else { continue }
            notifiedTier[key] = tier
            let name = AliasStore.shared.alias(for: key) ?? quota.displaySubtitle
            send(
                title: "\(displayTitle(quota)) · \(name) 额度告警",
                body: "5 小时窗口剩余 \(Int(remaining.rounded()))%，\(quota.fiveHourReset) 重置"
            )
        }
    }

    private func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
