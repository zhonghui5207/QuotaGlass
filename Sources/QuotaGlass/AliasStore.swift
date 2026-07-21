import SwiftUI

extension Notification.Name {
    static let qgOpenSettings = Notification.Name("QGOpenSettings")
}

/// Stable identity for an account row, used as the alias key.
func accountKey(_ snapshot: QuotaSnapshot) -> String {
    snapshot.identity.storageKey
}

/// Pre-v2 identity retained solely for one-way preference migration.
func legacyAccountKey(_ snapshot: QuotaSnapshot) -> String {
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

    /// Copy instead of move: the former display-name key may represent more
    /// than one account once provider identities make collisions visible.
    func migrateAlias(from legacyKey: String, to stableKey: String) {
        guard aliases[stableKey] == nil,
              let value = aliases[legacyKey] else { return }
        aliases[stableKey] = value
        UserDefaults.standard.set(aliases, forKey: defaultsKey)
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
    @State private var accountOperationError: String?
    @State private var importedAccounts: [ImportedAccount] = []

    enum LoginSheet: String, Identifiable {
        case claude, codex, sakana
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    accountsSection
                    Divider()
                    generalSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 18)
            }

            Divider()

            footer
        }
        .frame(minWidth: 430, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .onAppear {
            reloadImportedAccounts()
            resetDrafts()
        }
        .onChange(of: draftLaunchAtLogin) { _, _ in didJustSave = false }
        .onChange(of: draftNotifyLowQuota) { _, _ in didJustSave = false }
        .onChange(of: draftRefreshInterval) { _, _ in didJustSave = false }
        .sheet(item: $loginSheet, onDismiss: reloadImportedAccounts) { sheet in
            switch sheet {
            case .claude: ClaudeLoginSheet(store: store)
            case .codex: CodexLoginSheet(store: store)
            case .sakana: SakanaLoginSheet(store: store)
            }
        }
        .alert(
            "账号操作失败",
            isPresented: Binding(
                get: { accountOperationError != nil },
                set: { if !$0 { accountOperationError = nil } }
            )
        ) {
            Button("好", role: .cancel) { accountOperationError = nil }
        } message: {
            Text(accountOperationError ?? "未知错误")
        }
    }

    private var accountsSection: some View {
        let missingImported = importedAccountsWithoutQuotaRows
        return VStack(alignment: .leading, spacing: 12) {
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

            if store.quotas.isEmpty && missingImported.isEmpty {
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
                    ForEach(Array(missingImported.enumerated()), id: \.element.storageKey) { index, account in
                        if !store.quotas.isEmpty || index > 0 { Divider().padding(.leading, 2) }
                        missingImportedRow(account)
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
        if snapshot.importedId != nil {
            removeImported(snapshot)
        } else {
            archiveSnapshot(snapshot)
        }
    }

    private func removeImported(_ snapshot: QuotaSnapshot) {
        guard let id = snapshot.importedId else { return }
        let service: ImportedAccount.Service
        switch snapshot.identity.provider {
        case .codex:
            service = .codex
        case .claude:
            service = .claude
        case .sakana, .debug:
            accountOperationError = "这个账号不是可移除的 OAuth 账号。"
            return
        }

        let account = ImportedAccount(
            id: id,
            service: service,
            email: snapshot.accountName,
            planType: snapshot.planName,
            addedAt: .distantPast
        )
        removeImported(account, quotaKey: accountKey(snapshot))
    }

    private func removeImported(_ account: ImportedAccount, quotaKey: String? = nil) {
        store.cancelRefreshForCredentialMutation()
        do {
            try ImportedAccountStore.removeReporting(account)
        } catch {
            accountOperationError = error.localizedDescription
            // The attempted mutation invalidated the in-flight discovery pass.
            // Restore monitoring immediately when the credential was not removed.
            Task { await store.forceRefresh() }
            return
        }

        let key = quotaKey ?? QuotaAccountIdentity(
            provider: account.service == .codex ? .codex : .claude,
            source: "imported",
            stableID: account.id
        ).storageKey
        aliases.setAlias("", for: key)
        prefs.menuBarShow.removeValue(forKey: key)
        prefs.archivedAccountKeys.remove(key)
        draftAliases.removeValue(forKey: key)
        draftMenuBarShow.removeValue(forKey: key)
        importedAccounts.removeAll { $0.service == account.service && $0.id == account.id }
        store.removeQuota(key: key)
        Task { await store.forceRefresh() }
    }

    private var importedAccountsWithoutQuotaRows: [ImportedAccount] {
        let loaded = Set(store.quotas.compactMap { snapshot -> String? in
            guard let id = snapshot.importedId else { return nil }
            switch snapshot.identity.provider {
            case .codex: return ImportedAccountStore.tokenKey(service: .codex, id: id)
            case .claude: return ImportedAccountStore.tokenKey(service: .claude, id: id)
            case .sakana, .debug: return nil
            }
        })
        return importedAccounts.filter { !loaded.contains($0.storageKey) }
    }

    private func missingImportedRow(_ account: ImportedAccount) -> some View {
        let status = missingImportedStatus(for: account)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.service == .codex ? "Codex" : "Claude Code")
                    .font(.system(size: 13, weight: .medium))
                Text("\(account.email ?? account.id) · \(status.text)")
                    .font(.system(size: 11))
                    .foregroundStyle(status.color)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                removeImported(account)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("移除这个未加载的导入账号")
        }
    }

    private func missingImportedStatus(for account: ImportedAccount) -> (text: String, color: Color) {
        if store.linkedImportedAccountKeys.contains(account.storageKey) {
            return ("与本地 CLI 凭据相同，可移除这条冗余导入", .secondary)
        }
        switch store.state {
        case .loading:
            return ("正在加载用量…", .secondary)
        case .idle:
            return ("等待首次刷新", .secondary)
        case .loaded:
            return ("暂未返回用量，可手动刷新", .secondary)
        case .failed:
            return ("用量或凭据加载失败，可刷新重试", .orange)
        }
    }

    private func reloadImportedAccounts() {
        do {
            importedAccounts = try ImportedAccountStore.loadAllReporting()
        } catch {
            accountOperationError = error.localizedDescription
        }
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
            let details = [snapshot.warningText, snapshot.refreshErrorText]
                .compactMap { $0 }
                .map(safeAccountMessage)
            return ([text] + details).joined(separator: " · ")
        }
        if snapshot.isAPIUsage {
            let primary = snapshot.apiPrimaryText ?? "API"
            if let secondary = snapshot.apiSecondaryText, !secondary.isEmpty {
                return withWarning("\(snapshot.accountName) · \(primary) · \(secondary)")
            }
            return withWarning("\(snapshot.accountName) · \(primary)")
        }
        if let remaining = snapshot.fiveHourRemaining {
            return withWarning("\(snapshot.accountName) · 5H \(Int(remaining.rounded()))%")
        }
        return withWarning("\(snapshot.accountName) · 5H 暂无数据")
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

    private func safeAccountMessage(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return singleLine.count <= 100 ? singleLine : String(singleLine.prefix(97)) + "..."
    }
}
