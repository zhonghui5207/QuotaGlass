import SwiftUI

extension Notification.Name {
    static let qgOpenSettings = Notification.Name("QGOpenSettings")
}

/// Stable identity for an account row, used as the alias key.
func accountKey(_ snapshot: QuotaSnapshot) -> String {
    snapshot.serviceName + "·" + snapshot.accountName
}

/// User-assigned account aliases, persisted in UserDefaults.
@MainActor
final class AliasStore: ObservableObject {
    static let shared = AliasStore()
    private let defaultsKey = "accountAliases"
    @Published private(set) var aliases: [String: String]

    private init() {
        aliases = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
    }

    func alias(for key: String) -> String? {
        let value = aliases[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    func setAlias(_ alias: String, for key: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { aliases.removeValue(forKey: key) } else { aliases[key] = trimmed }
        UserDefaults.standard.set(aliases, forKey: defaultsKey)
        // Menu-bar badge may render alias initials; let it redraw.
        NotificationCenter.default.post(name: .qgPrefsChanged, object: nil)
    }
}

// MARK: - Settings window content

struct SettingsRootView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject private var aliases = AliasStore.shared
    @ObservedObject private var prefs = PrefsStore.shared
    @State private var draftAliases: [String: String] = [:]
    @State private var draftMenuBarShow: [String: Bool] = [:]
    @State private var draftLaunchAtLogin = false
    @State private var draftNotifyLowQuota = true
    @State private var draftRefreshInterval = 300
    @State private var didJustSave = false
    @State private var loginSheet: LoginSheet?

    enum LoginSheet: String, Identifiable {
        case claude, codex, sakana
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                accountsSection
                Divider()
                generalSection
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider()

            footer
        }
        .frame(width: 500)
        .onAppear(perform: resetDrafts)
        .onChange(of: draftLaunchAtLogin) { _, _ in didJustSave = false }
        .onChange(of: draftNotifyLowQuota) { _, _ in didJustSave = false }
        .onChange(of: draftRefreshInterval) { _, _ in didJustSave = false }
        .sheet(item: $loginSheet) { sheet in
            switch sheet {
            case .claude: ClaudeLoginSheet(store: store)
            case .codex: CodexLoginSheet(store: store)
            case .sakana: SakanaLoginSheet(store: store)
            }
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("账号")
                        .font(.system(size: 15, weight: .semibold))
                    Text("设置别名，并选择要显示在菜单栏徽章里的账号。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("添加账号") {
                    Button("登录 Claude 账号…") { loginSheet = .claude }
                    Button("登录 Codex 账号…") { loginSheet = .codex }
                    Button("登录 Sakana Console…") { loginSheet = .sakana }
                    Divider()
                    Button("恢复归档展示") { restoreArchivedAccounts() }
                        .disabled(prefs.archivedAccountKeys.isEmpty)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if store.quotas.isEmpty {
                Text("还没有读到账号。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.quotas.enumerated()), id: \.element.id) { index, snapshot in
                        if index > 0 { Divider().padding(.leading, 2) }
                        row(for: snapshot)
                            .padding(.vertical, 9)
                    }
                }
            }
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("通用")
                .font(.system(size: 15, weight: .semibold))

            HStack {
                Toggle("开机自启", isOn: $draftLaunchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Toggle("低额度通知", isOn: $draftNotifyLowQuota)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("5 小时窗口剩余 <30% 和 <10% 时各提醒一次")
            }

            HStack(spacing: 12) {
                Text("后台刷新间隔")
                    .font(.system(size: 13))
                Picker("", selection: $draftRefreshInterval) {
                    Text("5 分钟").tag(300)
                    Text("10 分钟").tag(600)
                    Text("15 分钟").tag(900)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(saveStatusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("还原", action: resetDrafts)
                .disabled(!hasChanges)
            Button("保存", action: saveDrafts)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private var saveStatusText: String {
        if didJustSave { return "修改已保存" }
        return hasChanges ? "有未保存更改" : "设置已保存"
    }

    private func row(for snapshot: QuotaSnapshot) -> some View {
        let key = accountKey(snapshot)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(displayTitle(snapshot))
                        .font(.system(size: 13, weight: .medium))
                    if snapshot.importedId != nil {
                        Text("导入")
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(accountSubtitle(snapshot))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            TextField("别名", text: aliasDraftBinding(for: key))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            Toggle("菜单栏", isOn: menuBarDraftBinding(for: key))
                .toggleStyle(.checkbox)
            Button {
                removeOrArchive(snapshot)
            } label: {
                if snapshot.importedId == nil {
                    Label("归档", systemImage: "archivebox")
                        .font(.system(size: 11))
                        .labelStyle(.titleAndIcon)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .help(snapshot.importedId == nil ? "归档这个展示，并取消菜单栏显示" : "移除这个导入的账号")
        }
    }

    private func removeOrArchive(_ snapshot: QuotaSnapshot) {
        if let importedId = snapshot.importedId {
            removeImported(id: importedId)
        } else {
            archiveSnapshot(snapshot)
        }
    }

    private func removeImported(id: String) {
        if let account = ImportedAccountStore.loadAll().first(where: { $0.id == id }) {
            ImportedAccountStore.remove(account)
        }
        store.removeQuota(importedId: id)
        Task { await store.refresh() }
    }

    private func archiveSnapshot(_ snapshot: QuotaSnapshot) {
        let key = accountKey(snapshot)
        prefs.archiveAccount(key: key)
        draftAliases.removeValue(forKey: key)
        draftMenuBarShow.removeValue(forKey: key)
        store.archiveQuota(key: key)
    }

    private func restoreArchivedAccounts() {
        prefs.restoreArchivedAccounts()
        store.applyVisibilityPreferences()
        Task { await store.refresh() }
    }

    private func accountSubtitle(_ snapshot: QuotaSnapshot) -> String {
        func withWarning(_ text: String) -> String {
            if let warning = snapshot.warningText {
                return "\(text) · \(warning)"
            }
            return text
        }
        if snapshot.isAPIUsage {
            let primary = snapshot.apiPrimaryText ?? "API"
            if let secondary = snapshot.apiSecondaryText, !secondary.isEmpty {
                return withWarning("\(snapshot.accountName) · \(primary) · \(secondary)")
            }
            return withWarning("\(snapshot.accountName) · \(primary)")
        }
        return withWarning("\(snapshot.accountName) · 5H \(Int(snapshot.fiveHourRemaining.rounded()))%")
    }

    private func aliasDraftBinding(for key: String) -> Binding<String> {
        Binding(
            get: { draftAliases[key] ?? "" },
            set: {
                didJustSave = false
                draftAliases[key] = $0
            }
        )
    }

    private func menuBarDraftBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { draftMenuBarShow[key] ?? currentMenuBarValue(for: key) },
            set: {
                didJustSave = false
                draftMenuBarShow[key] = $0
            }
        )
    }

    private var hasChanges: Bool {
        if draftLaunchAtLogin != prefs.launchAtLogin { return true }
        if draftNotifyLowQuota != prefs.notifyLowQuota { return true }
        if draftRefreshInterval != prefs.refreshInterval { return true }

        for snapshot in store.quotas {
            let key = accountKey(snapshot)
            if normalized(draftAliases[key] ?? "") != normalized(aliases.alias(for: key) ?? "") {
                return true
            }
            if (draftMenuBarShow[key] ?? currentMenuBarValue(for: key)) != currentMenuBarValue(for: key) {
                return true
            }
        }
        return false
    }

    private func resetDrafts() {
        draftAliases = Dictionary(uniqueKeysWithValues: store.quotas.map { snapshot in
            let key = accountKey(snapshot)
            return (key, aliases.alias(for: key) ?? "")
        })
        draftMenuBarShow = Dictionary(uniqueKeysWithValues: store.quotas.map { snapshot in
            let key = accountKey(snapshot)
            return (key, currentMenuBarValue(for: key))
        })
        draftLaunchAtLogin = prefs.launchAtLogin
        draftNotifyLowQuota = prefs.notifyLowQuota
        draftRefreshInterval = prefs.refreshInterval
    }

    private func saveDrafts() {
        for snapshot in store.quotas {
            let key = accountKey(snapshot)
            aliases.setAlias(draftAliases[key] ?? "", for: key)
        }

        var nextMenuBarShow = prefs.menuBarShow
        let defaults = defaultMenuBarKeys(store.quotas)
        for snapshot in store.quotas {
            let key = accountKey(snapshot)
            let draftValue = draftMenuBarShow[key] ?? defaults.contains(key)
            if draftValue == defaults.contains(key) {
                nextMenuBarShow.removeValue(forKey: key)
            } else {
                nextMenuBarShow[key] = draftValue
            }
        }
        prefs.menuBarShow = nextMenuBarShow
        prefs.notifyLowQuota = draftNotifyLowQuota
        prefs.refreshInterval = draftRefreshInterval
        prefs.setLaunchAtLogin(draftLaunchAtLogin)
        resetDrafts()
        didJustSave = true
    }

    private func currentMenuBarValue(for key: String) -> Bool {
        prefs.menuBarShow[key] ?? defaultMenuBarKeys(store.quotas).contains(key)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
