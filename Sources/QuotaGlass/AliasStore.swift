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
    }
}

// MARK: - Settings window content

struct AliasSettingsView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject private var aliases = AliasStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("账号别名")
                    .font(.system(size: 15, weight: .semibold))
                Text("给每个账号起个名字,方便在列表里区分。留空则用默认。")
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
        }
        .padding(20)
        .frame(width: 400)
    }

    private func row(for snapshot: QuotaSnapshot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(snapshot))
                    .font(.system(size: 13, weight: .medium))
                Text("\(snapshot.accountName) · 5H \(Int(snapshot.fiveHourRemaining.rounded()))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            TextField("别名", text: binding(for: snapshot))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
        }
    }

    private func binding(for snapshot: QuotaSnapshot) -> Binding<String> {
        let key = accountKey(snapshot)
        return Binding(
            get: { aliases.alias(for: key) ?? "" },
            set: { aliases.setAlias($0, for: key) }
        )
    }
}
