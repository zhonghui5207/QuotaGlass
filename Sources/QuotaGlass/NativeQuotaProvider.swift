import Foundation

// MARK: - Provider

struct NativeQuotaProvider: Sendable {
    private enum PreparedRequest: Sendable {
        case codex(
            identity: QuotaAccountIdentity,
            accountName: String,
            plan: String?,
            credentialWarning: String?,
            importedId: String?,
            accessToken: String,
            accountId: String?
        )
        case claude(
            identity: QuotaAccountIdentity,
            accountName: String,
            plan: String?,
            credentialWarning: String?,
            importedId: String?,
            accessToken: String
        )
        case sakana(
            identity: QuotaAccountIdentity,
            accountName: String,
            apiKey: String
        )
        case sakanaConsole(identity: QuotaAccountIdentity)

        var isOptionalConsole: Bool {
            if case .sakanaConsole = self { return true }
            return false
        }
    }

    private enum FetchResult: Sendable {
        case success(QuotaSnapshot)
        case failure(NativeQuotaFailure)
        case unavailable
    }

    private struct IndexedFetchResult: Sendable {
        var index: Int
        var result: FetchResult
    }

    func loadQuotas() async -> NativeQuotaLoadReport {
        var requests: [PreparedRequest] = []
        var failures: [NativeQuotaFailure] = []
        var credentialCount = 0
        let importedAccounts: [ImportedAccount]
        var globalErrors: [String] = []
        do {
            importedAccounts = try ImportedAccountStore.loadAllReporting()
        } catch {
            importedAccounts = []
            globalErrors.append(error.localizedDescription)
        }
        var importedCredentials: [ImportedCredential] = []
        for account in importedAccounts {
            do {
                guard let tokens = try ImportedAccountStore.loadTokensReporting(
                    accountId: ImportedAccountStore.tokenKey(account)
                ) else {
                    failures.append(importedCredentialFailure(account, detail: "钥匙串中没有凭据"))
                    continue
                }
                importedCredentials.append(ImportedCredential(account: account, tokens: tokens))
            } catch {
                failures.append(importedCredentialFailure(account, detail: error.localizedDescription))
            }
        }

        // Token refresh can write credential files/keychain items. Keep this
        // preparation phase serial, then parallelize only read-only usage calls.
        var linkedImportedAccountKeys = Set<String>()
        let codexDiscovery = codexAccounts(importedCredentials: importedCredentials)
        linkedImportedAccountKeys.formUnion(codexDiscovery.linkedImportedAccountKeys)
        for var codex in codexDiscovery.accounts {
            credentialCount += 1
            let identity = codexIdentity(codex)
            let accountName = codex.email ?? "Codex"
            guard let token = await CodexRefresher.ensureFresh(&codex), !token.isEmpty else {
                failures.append(NativeQuotaFailure(
                    identity: identity,
                    serviceName: "Codex",
                    accountName: accountName,
                    message: "Codex access token 不可用"
                ))
                continue
            }
            requests.append(.codex(
                identity: identity,
                accountName: accountName,
                plan: codex.planType,
                credentialWarning: codex.credentialWarning,
                importedId: codex.importedId,
                accessToken: token,
                accountId: codex.accountId
            ))
        }

        let claudeDiscovery = ClaudeAuthReader.loadAll(importedCredentials: importedCredentials)
        linkedImportedAccountKeys.formUnion(claudeDiscovery.linkedImportedAccountKeys)
        for var claude in claudeDiscovery.accounts {
            credentialCount += 1
            let identity = claudeIdentity(claude)
            let accountName = claude.displayAccount
            var importedId: String?
            if case .imported(let id) = claude.source { importedId = id }
            guard let token = await ClaudeRefresher.ensureFresh(&claude), !token.isEmpty else {
                failures.append(NativeQuotaFailure(
                    identity: identity,
                    serviceName: "Claude",
                    accountName: accountName,
                    message: "Claude access token 不可用"
                ))
                continue
            }
            requests.append(.claude(
                identity: identity,
                accountName: accountName,
                plan: claude.subscriptionType,
                credentialWarning: claude.credentialWarning,
                importedId: importedId,
                accessToken: token
            ))
        }

        let sakanaAccounts = SakanaAuthReader.loadAll()
        credentialCount += sakanaAccounts.count
        for sakana in sakanaAccounts {
            requests.append(.sakana(
                identity: sakanaIdentity(sakana),
                accountName: sakana.accountName,
                apiKey: sakana.apiKey
            ))
        }
        // Console billing is a separate identity from API keys. Always probe it;
        // the optional request disappears cleanly when no session/cache exists.
        requests.append(.sakanaConsole(identity: QuotaAccountIdentity(
            provider: .sakana,
            source: "console",
            stableID: "console.sakana.ai"
        )))

        let fetched = await fetchWithConcurrencyLimit(requests, limit: 4)
        var snapshots: [QuotaSnapshot] = []
        for (request, result) in zip(requests, fetched) {
            switch result {
            case .success(let snapshot):
                snapshots.append(snapshot)
                if request.isOptionalConsole { credentialCount += 1 }
            case .failure(let failure):
                failures.append(failure)
                if request.isOptionalConsole { credentialCount += 1 }
            case .unavailable:
                break
            }
        }

        let archivedKeys = await MainActor.run { PrefsStore.shared.archivedAccountKeys }
        snapshots = annotatePotentialClaudeCredentialClones(snapshots, excluding: archivedKeys)
        return NativeQuotaLoadReport(
            successes: snapshots,
            failures: failures,
            credentialCount: credentialCount,
            globalErrors: globalErrors,
            linkedImportedAccountKeys: linkedImportedAccountKeys
        )
    }

    /// The default auth.json account plus OAuth-imported ones. Only an exact
    /// token duplicate of the same workspace/user login is collapsed.
    private func codexAccounts(
        importedCredentials: [ImportedCredential]
    ) -> (accounts: [NativeCodexAccount], linkedImportedAccountKeys: Set<String>) {
        var accounts: [NativeCodexAccount] = []
        var linkedImportedAccountKeys = Set<String>()
        if let def = CodexAuthReader.load() { accounts.append(def) }
        let defaultStableAccountID = accounts.first?.stableAccountID

        for credential in importedCredentials where credential.account.service == .codex {
            let imported = credential.account
            let tokens = credential.tokens
            let importedParts = imported.id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let importedAccountId = importedParts.first.map(String.init)
            let importedUserId = importedParts.count > 1 ? String(importedParts[1]) : nil
            if let defaultAccount = accounts.first,
               let defaultStableAccountID,
               imported.id == defaultStableAccountID,
               defaultAccount.accessToken == tokens.accessToken,
               defaultAccount.refreshToken == tokens.refreshToken {
                accounts[0].linkedImportedIDs.append(imported.id)
                linkedImportedAccountKeys.insert(imported.storageKey)
                continue
            }
            accounts.append(NativeCodexAccount(
                email: imported.email,
                planType: imported.planType,
                accountId: importedAccountId,
                userId: importedUserId,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                idToken: tokens.idToken,
                importedId: imported.id
            ))
        }
        return (accounts, linkedImportedAccountKeys)
    }

    private func importedCredentialFailure(_ account: ImportedAccount, detail: String) -> NativeQuotaFailure {
        let service = account.service == .codex ? "Codex" : "Claude"
        return NativeQuotaFailure(
            identity: QuotaAccountIdentity(
                provider: account.service == .codex ? .codex : .claude,
                source: "imported",
                stableID: account.id
            ),
            serviceName: service,
            accountName: account.email ?? account.id,
            message: "导入账号凭据读取失败：\(detail)"
        )
    }

    private func fetchWithConcurrencyLimit(_ requests: [PreparedRequest], limit: Int) async -> [FetchResult] {
        guard !requests.isEmpty else { return [] }
        let concurrency = max(1, min(limit, requests.count))
        return await withTaskGroup(of: IndexedFetchResult.self, returning: [FetchResult].self) { group in
            for index in 0..<concurrency {
                let request = requests[index]
                group.addTask {
                    IndexedFetchResult(index: index, result: await fetch(request))
                }
            }

            var nextIndex = concurrency
            var indexed: [IndexedFetchResult] = []
            indexed.reserveCapacity(requests.count)
            while let value = await group.next() {
                indexed.append(value)
                if nextIndex < requests.count {
                    let index = nextIndex
                    let request = requests[index]
                    nextIndex += 1
                    group.addTask {
                        IndexedFetchResult(index: index, result: await fetch(request))
                    }
                }
            }
            return indexed.sorted { $0.index < $1.index }.map(\.result)
        }
    }

    private func fetch(_ request: PreparedRequest) async -> FetchResult {
        switch request {
        case let .codex(identity, accountName, plan, credentialWarning, importedId, accessToken, accountId):
            guard let usage = await CodexUsage.fetch(accessToken: accessToken, accountId: accountId) else {
                return .failure(NativeQuotaFailure(
                    identity: identity,
                    serviceName: "Codex",
                    accountName: accountName,
                    message: failureMessage("Codex 用量请求失败", credentialWarning: credentialWarning)
                ))
            }
            guard usage.five != nil || usage.weekly != nil else {
                return .failure(NativeQuotaFailure(
                    identity: identity,
                    serviceName: "Codex",
                    accountName: accountName,
                    message: failureMessage("Codex 响应缺少用量窗口", credentialWarning: credentialWarning)
                ))
            }
            return .success(snapshot(
                identity: identity,
                service: "Codex",
                account: accountName,
                plan: usage.plan ?? plan,
                five: usage.five,
                weekly: usage.weekly,
                credentialWarning: credentialWarning,
                importedId: importedId
            ))

        case let .claude(identity, accountName, plan, credentialWarning, importedId, accessToken):
            guard let usage = await ClaudeUsage.fetch(accessToken: accessToken) else {
                return .failure(NativeQuotaFailure(
                    identity: identity,
                    serviceName: "Claude",
                    accountName: accountName,
                    message: failureMessage("Claude 用量请求失败", credentialWarning: credentialWarning)
                ))
            }
            guard usage.five != nil || usage.weekly != nil else {
                return .failure(NativeQuotaFailure(
                    identity: identity,
                    serviceName: "Claude",
                    accountName: accountName,
                    message: failureMessage("Claude 响应缺少用量窗口", credentialWarning: credentialWarning)
                ))
            }
            return .success(snapshot(
                identity: identity,
                service: "Claude",
                account: accountName,
                plan: plan,
                five: usage.five,
                weekly: usage.weekly,
                credentialWarning: credentialWarning,
                importedId: importedId
            ))

        case let .sakana(identity, accountName, apiKey):
            switch await SakanaUsage.fetchOutcome(apiKey: apiKey) {
            case .success(let usage):
                return .success(sakanaSnapshot(identity: identity, account: accountName, usage: usage))
            case .failure(let message):
                return .failure(NativeQuotaFailure(
                    identity: identity,
                    serviceName: "Sakana API",
                    accountName: accountName,
                    message: message
                ))
            case .unavailable:
                return .failure(NativeQuotaFailure(
                    identity: identity,
                    serviceName: "Sakana API",
                    accountName: accountName,
                    message: "Sakana API key 不可用"
                ))
            }

        case .sakanaConsole(let identity):
            switch await SakanaUsage.fetchOutcome(apiKey: nil) {
            case .success(let usage):
                return .success(sakanaSnapshot(identity: identity, account: "Console", usage: usage))
            case .failure(let message):
                return .failure(NativeQuotaFailure(
                    identity: identity,
                    serviceName: "Sakana API",
                    accountName: "Console",
                    message: message
                ))
            case .unavailable:
                return .unavailable
            }
        }
    }

    private func codexIdentity(_ account: NativeCodexAccount) -> QuotaAccountIdentity {
        if let importedId = account.importedId, !importedId.isEmpty {
            return QuotaAccountIdentity(provider: .codex, source: "imported", stableID: importedId)
        }
        if let stableAccountID = account.stableAccountID {
            return QuotaAccountIdentity(provider: .codex, source: "account", stableID: stableAccountID)
        }
        let tokenSubject = account.idToken.flatMap { NativeJWT.decodePayload($0)?["sub"] as? String }
            ?? account.accessToken.flatMap { NativeJWT.decodePayload($0)?["sub"] as? String }
        if let tokenSubject, !tokenSubject.isEmpty {
            return QuotaAccountIdentity(provider: .codex, source: "subject", stableID: tokenSubject)
        }
        return QuotaAccountIdentity(
            provider: .codex,
            source: "file",
            stableID: CodexAuthReader.authFileURL().standardizedFileURL.path
        )
    }

    private func claudeIdentity(_ account: NativeClaudeAccount) -> QuotaAccountIdentity {
        switch account.source {
        case .imported(let id):
            return QuotaAccountIdentity(provider: .claude, source: "imported", stableID: id)
        case .keychain:
            let service = account.keychainService ?? ClaudeKeychain.canonicalService
            let accountAttribute = account.keychainAccount ?? ""
            return QuotaAccountIdentity(
                provider: .claude,
                source: "keychain",
                stableID: service + "\u{1F}" + accountAttribute
            )
        case .file:
            return QuotaAccountIdentity(
                provider: .claude,
                source: "file",
                stableID: ClaudeAuthReader.credentialsFileURL().standardizedFileURL.path
            )
        }
    }

    private func sakanaIdentity(_ account: NativeSakanaAccount) -> QuotaAccountIdentity {
        switch account.source {
        case .environment(let name):
            return QuotaAccountIdentity(provider: .sakana, source: "environment", stableID: name)
        case .dotenv(let url):
            return QuotaAccountIdentity(
                provider: .sakana,
                source: "dotenv",
                stableID: url.standardizedFileURL.path + "\u{1F}" + account.accountName
            )
        case .keychain(let service):
            return QuotaAccountIdentity(provider: .sakana, source: "keychain", stableID: service)
        }
    }

    private func snapshot(
        identity: QuotaAccountIdentity,
        service: String,
        account: String,
        plan: String?,
        five: NativeWindow?,
        weekly: NativeWindow?,
        credentialWarning: String?,
        importedId: String?
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            identity: identity,
            serviceName: service,
            accountName: account,
            planName: planLabel(plan),
            fiveHourUsed: five?.usedPercent,
            weeklyUsed: weekly?.usedPercent,
            fiveHourReset: NativeQuotaProvider.formatReset(five?.resetsAt),
            weeklyReset: NativeQuotaProvider.formatReset(weekly?.resetsAt),
            source: importedId == nil ? "Native" : "Imported",
            fetchedAt: Date(),
            warningText: credentialWarning == nil ? nil : "凭据未保存",
            importedId: importedId,
            refreshErrorText: credentialWarning
        )
    }

    private func sakanaSnapshot(identity: QuotaAccountIdentity, account: String, usage: SakanaUsageResult) -> QuotaSnapshot {
        QuotaSnapshot(
            identity: identity,
            serviceName: "Sakana API",
            accountName: account,
            planName: planLabel(usage.plan),
            fiveHourUsed: usage.five?.usedPercent,
            weeklyUsed: usage.weekly?.usedPercent,
            fiveHourReset: NativeQuotaProvider.formatReset(usage.five?.resetsAt),
            weeklyReset: NativeQuotaProvider.formatReset(usage.weekly?.resetsAt),
            source: usage.isCached ? "Cache" : "Native",
            fetchedAt: usage.fetchedAt,
            presentation: .apiUsage,
            apiPrimaryText: usage.primaryText,
            apiSecondaryText: usage.secondaryText,
            apiDetailText: usage.detailText,
            importedId: nil,
            isStale: usage.isCached
        )
    }

    /// Archived accounts are excluded: warning about a twin the user has hidden
    /// (and cannot see) reads as a false positive on the remaining visible row.
    private func annotatePotentialClaudeCredentialClones(_ snapshots: [QuotaSnapshot], excluding archivedKeys: Set<String>) -> [QuotaSnapshot] {
        var snapshots = snapshots
        var groups: [String: [Int]] = [:]
        for (index, snapshot) in snapshots.enumerated()
        where snapshot.isClaude
            && !archivedKeys.contains(accountKey(snapshot))
            && !archivedKeys.contains(legacyAccountKey(snapshot)) {
            guard snapshot.hasWindowData else { continue }
            let fingerprint = [
                quotaFingerprint(snapshot.fiveHourUsed),
                quotaFingerprint(snapshot.weeklyUsed),
                snapshot.fiveHourReset,
                snapshot.weeklyReset,
            ].joined(separator: "|")
            groups[fingerprint, default: []].append(index)
        }

        for indexes in groups.values where indexes.count > 1 {
            let accountNames = Set(indexes.map { snapshots[$0].accountName })
            guard accountNames.count > 1 else { continue }
            for index in indexes {
                snapshots[index].warningText = [snapshots[index].warningText, "可能同一登录"]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            }
        }
        return snapshots
    }

    private func quotaFingerprint(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "-"
    }

    private func failureMessage(_ base: String, credentialWarning: String?) -> String {
        guard let credentialWarning else { return base }
        return "\(base)；\(credentialWarning)"
    }

    private func planLabel(_ plan: String?) -> String {
        guard let plan, !plan.isEmpty else { return "" }
        let lower = plan.lowercased()
        if lower == "api" { return "API" }
        if lower.contains("prolite") || lower == "pro_lite" { return "Pro Lite" }
        if lower.contains("max") { return "Max" }
        if lower.contains("team") { return "Team" }
        if lower.contains("plus") { return "Plus" }
        if lower.contains("pro") { return "Pro" }
        return plan.capitalized
    }

    /// Formats a reset time as "M/d HH:mm (周X)" to match the previous checker style.
    static func formatReset(_ date: Date?) -> String {
        guard let date else { return "无" }
        return SharedFormatters.resetString(from: date)
    }
}
