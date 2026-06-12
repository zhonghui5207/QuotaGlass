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
    @State private var launchAtLogin = false
    @State private var loginSheet: LoginSheet?

    enum LoginSheet: String, Identifiable {
        case claude, codex
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("账号")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Menu("添加账号") {
                        Button("登录 Claude 账号…") { loginSheet = .claude }
                        Button("登录 Codex 账号…") { loginSheet = .codex }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Text("别名用于列表展示；勾选「菜单栏」的账号会显示在菜单栏徽章里。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if store.quotas.isEmpty {
                Text("还没有读到账号。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.quotas) { snapshot in
                    row(for: snapshot)
                }
            }

            Divider()

            Text("通用")
                .font(.system(size: 15, weight: .semibold))

            Toggle("开机自启", isOn: Binding(
                get: { launchAtLogin },
                set: { on in
                    prefs.setLaunchAtLogin(on)
                    launchAtLogin = prefs.launchAtLogin
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle("低额度通知（5 小时窗口剩余 <30% 和 <10% 时各提醒一次）", isOn: $prefs.notifyLowQuota)
                .toggleStyle(.switch)
                .controlSize(.small)

            HStack(spacing: 12) {
                Text("后台刷新间隔")
                    .font(.system(size: 13))
                Picker("", selection: $prefs.refreshInterval) {
                    Text("5 分钟").tag(300)
                    Text("10 分钟").tag(600)
                    Text("15 分钟").tag(900)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { launchAtLogin = prefs.launchAtLogin }
        .sheet(item: $loginSheet) { sheet in
            switch sheet {
            case .claude: ClaudeLoginSheet(store: store)
            case .codex: CodexLoginSheet(store: store)
            }
        }
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
                Text("\(snapshot.accountName) · 5H \(Int(snapshot.fiveHourRemaining.rounded()))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            TextField("别名", text: aliasBinding(for: key))
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
            Toggle("菜单栏", isOn: menuBarBinding(for: key))
                .toggleStyle(.checkbox)
            if let importedId = snapshot.importedId {
                Button {
                    removeImported(id: importedId)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("移除这个导入的账号")
            }
        }
    }

    private func removeImported(id: String) {
        if let account = ImportedAccountStore.loadAll().first(where: { $0.id == id }) {
            ImportedAccountStore.remove(account)
        }
        store.removeQuota(importedId: id)
        Task { await store.refresh() }
    }

    private func aliasBinding(for key: String) -> Binding<String> {
        Binding(
            get: { aliases.alias(for: key) ?? "" },
            set: { aliases.setAlias($0, for: key) }
        )
    }

    private func menuBarBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { prefs.menuBarShow[key] ?? defaultMenuBarKeys(store.quotas).contains(key) },
            set: { prefs.menuBarShow[key] = $0 }
        )
    }
}
