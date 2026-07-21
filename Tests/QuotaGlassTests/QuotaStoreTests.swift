import Foundation
import XCTest
@testable import QuotaGlass

final class QuotaStoreTests: XCTestCase {
    func testPartialReportKeepsFailedAccountAsStaleAndFreshAccountLive() async {
        await MainActor.run {
            let failedIdentity = QuotaAccountIdentity(
                provider: .codex,
                source: "unit-test",
                stableID: UUID().uuidString
            )
            let freshIdentity = QuotaAccountIdentity(
                provider: .claude,
                source: "unit-test",
                stableID: UUID().uuidString
            )
            let oldFailedSnapshot = makeSnapshot(
                identity: failedIdentity,
                accountName: "same@example.com",
                fiveHourUsed: 72,
                weeklyUsed: 81
            )
            let oldFreshSnapshot = makeSnapshot(
                identity: freshIdentity,
                serviceName: "Claude",
                accountName: "same@example.com",
                fiveHourUsed: 15,
                weeklyUsed: 25
            )

            let store = QuotaStore(notifyFreshQuotas: { _ in })
            store.apply(NativeQuotaLoadReport(
                successes: [oldFailedSnapshot, oldFreshSnapshot],
                failures: [],
                credentialCount: 2
            ))

            var refreshed = oldFreshSnapshot
            refreshed.fiveHourUsed = 31
            refreshed.weeklyUsed = 42
            refreshed.fetchedAt = Date().addingTimeInterval(1)
            store.apply(NativeQuotaLoadReport(
                successes: [refreshed],
                failures: [NativeQuotaFailure(
                    identity: failedIdentity,
                    serviceName: "Codex",
                    accountName: "same@example.com",
                    message: "temporary failure"
                )],
                credentialCount: 2
            ))

            let failed = store.quotas.first { $0.identity == failedIdentity }
            let fresh = store.quotas.first { $0.identity == freshIdentity }

            XCTAssertEqual(failed?.fiveHourUsed, 72)
            XCTAssertEqual(failed?.weeklyUsed, 81)
            XCTAssertEqual(failed?.isStale, true)
            XCTAssertEqual(failed?.refreshErrorText, "temporary failure")
            XCTAssertEqual(fresh?.fiveHourUsed, 31)
            XCTAssertEqual(fresh?.weeklyUsed, 42)
            XCTAssertEqual(fresh?.isStale, false)
            XCTAssertNil(fresh?.refreshErrorText)
            XCTAssertNotNil(store.lastRefresh)
            guard case .failed = store.state else {
                return XCTFail("A partial failure should be surfaced in store state")
            }
        }
    }

    func testKnownAccountFailureIsPreservedWhenNoCredentialCanBeLoaded() async {
        await MainActor.run {
            let identity = QuotaAccountIdentity(
                provider: .codex,
                source: "imported",
                stableID: UUID().uuidString
            )
            let store = QuotaStore(notifyFreshQuotas: { _ in })

            store.apply(NativeQuotaLoadReport(
                successes: [],
                failures: [NativeQuotaFailure(
                    identity: identity,
                    serviceName: "Codex",
                    accountName: "missing@example.com",
                    message: "导入账号凭据读取失败：钥匙串中没有凭据"
                )],
                credentialCount: 0
            ))

            guard case .failed(let message) = store.state else {
                return XCTFail("A known imported-account failure must remain visible")
            }
            XCTAssertTrue(message.contains("1 个账号"))
            XCTAssertFalse(message.contains("未发现 Codex、Claude 或 Sakana 凭据"))
        }
    }

    func testLinkedImportedCredentialStateTracksLatestDiscovery() async {
        await MainActor.run {
            let linkedKey = "codex:duplicate-account"
            let store = QuotaStore(notifyFreshQuotas: { _ in })

            store.apply(NativeQuotaLoadReport(
                successes: [],
                failures: [],
                credentialCount: 0,
                linkedImportedAccountKeys: [linkedKey]
            ))
            XCTAssertEqual(store.linkedImportedAccountKeys, [linkedKey])

            store.apply(NativeQuotaLoadReport(
                successes: [],
                failures: [],
                credentialCount: 0
            ))
            XCTAssertTrue(store.linkedImportedAccountKeys.isEmpty)
        }
    }

    func testLinkedCredentialCollapsesPreviouslyCachedImportedSnapshot() async {
        await MainActor.run {
            let importedID = "duplicate-account"
            var imported = makeSnapshot(
                identity: .init(provider: .codex, source: "imported", stableID: importedID),
                accountName: "duplicate@example.com"
            )
            imported.importedId = importedID
            let canonical = makeSnapshot(
                identity: .init(provider: .codex, source: "account", stableID: importedID),
                accountName: "duplicate@example.com"
            )
            let store = QuotaStore(notifyFreshQuotas: { _ in })
            store.apply(NativeQuotaLoadReport(
                successes: [imported],
                failures: [],
                credentialCount: 1
            ))

            store.apply(NativeQuotaLoadReport(
                successes: [canonical],
                failures: [],
                credentialCount: 1,
                linkedImportedAccountKeys: [
                    ImportedAccountStore.tokenKey(service: .codex, id: importedID)
                ]
            ))

            XCTAssertEqual(store.quotas.map(\.identity), [canonical.identity])
            XCTAssertEqual(store.state, .loaded)
        }
    }

    func testLegacyAccountPreferencesMigrateToStableKey() async {
        await MainActor.run {
            let unique = UUID().uuidString
            let snapshot = makeSnapshot(
                identity: .init(provider: .codex, source: "unit-test", stableID: unique),
                accountName: "migration-\(unique)@example.com"
            )
            let oldKey = legacyAccountKey(snapshot)
            let newKey = accountKey(snapshot)
            let aliases = AliasStore.shared
            let prefs = PrefsStore.shared

            aliases.setAlias("Legacy Alias", for: oldKey)
            prefs.menuBarShow[oldKey] = false
            prefs.archivedAccountKeys.insert(oldKey)
            defer {
                aliases.setAlias("", for: oldKey)
                aliases.setAlias("", for: newKey)
                prefs.menuBarShow.removeValue(forKey: oldKey)
                prefs.menuBarShow.removeValue(forKey: newKey)
                prefs.archivedAccountKeys.remove(oldKey)
                prefs.archivedAccountKeys.remove(newKey)
            }

            let store = QuotaStore(notifyFreshQuotas: { _ in })
            store.apply(NativeQuotaLoadReport(
                successes: [snapshot],
                failures: [],
                credentialCount: 1
            ))

            XCTAssertEqual(aliases.alias(for: newKey), "Legacy Alias")
            XCTAssertEqual(prefs.menuBarShow[newKey], false)
            XCTAssertTrue(prefs.archivedAccountKeys.contains(newKey))
            XCTAssertEqual(aliases.alias(for: oldKey), "Legacy Alias")
            XCTAssertEqual(prefs.menuBarShow[oldKey], false)
            XCTAssertTrue(prefs.archivedAccountKeys.contains(oldKey))
        }
    }

    func testRemovingOneStableKeyKeepsSameRawImportedIDFromAnotherProvider() async {
        await MainActor.run {
            var codex = makeSnapshot(
                identity: .init(provider: .codex, source: "imported", stableID: "shared-id"),
                accountName: "codex@example.com"
            )
            codex.importedId = "shared-id"
            var claude = makeSnapshot(
                identity: .init(provider: .claude, source: "imported", stableID: "shared-id"),
                serviceName: "Claude",
                accountName: "claude@example.com"
            )
            claude.importedId = "shared-id"

            let store = QuotaStore(notifyFreshQuotas: { _ in })
            store.apply(NativeQuotaLoadReport(
                successes: [codex, claude],
                failures: [],
                credentialCount: 2
            ))
            store.removeQuota(key: accountKey(codex))

            XCTAssertNil(store.quotas.first { $0.identity == codex.identity })
            XCTAssertNotNil(store.quotas.first { $0.identity == claude.identity })
        }
    }

    func testConcurrentRefreshesShareSingleProviderLoad() async {
        let identity = QuotaAccountIdentity(provider: .codex, source: "unit-test", stableID: UUID().uuidString)
        let report = NativeQuotaLoadReport(
            successes: [makeSnapshot(identity: identity, accountName: "single-flight@example.com")],
            failures: [],
            credentialCount: 1
        )
        let probe = QuotaLoadProbe(reports: [report], delay: .milliseconds(80))
        let store = await MainActor.run {
            QuotaStore(
                loadQuotas: { await probe.load() },
                notifyFreshQuotas: { _ in }
            )
        }

        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)

        let calls = await probe.callCount
        let loadedCount = await MainActor.run { store.quotas.count }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(loadedCount, 1)
    }

    func testForceRefreshRejectsCancelledOlderGeneration() async {
        let identity = QuotaAccountIdentity(provider: .codex, source: "unit-test", stableID: UUID().uuidString)
        var old = makeSnapshot(identity: identity, accountName: "generation@example.com")
        old.fiveHourUsed = 11
        var newest = old
        newest.fiveHourUsed = 77
        let probe = QuotaLoadProbe(
            reports: [
                NativeQuotaLoadReport(successes: [old], failures: [], credentialCount: 1),
                NativeQuotaLoadReport(successes: [newest], failures: [], credentialCount: 1),
            ],
            delay: .milliseconds(250)
        )
        let store = await MainActor.run {
            QuotaStore(
                loadQuotas: { await probe.load() },
                notifyFreshQuotas: { _ in }
            )
        }

        let first = Task { await store.refresh() }
        while await probe.callCount == 0 { await Task.yield() }
        await store.forceRefresh()
        await first.value

        let calls = await probe.callCount
        let used = await MainActor.run { store.quotas.first?.fiveHourUsed }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(used, 77)
    }
}

private actor QuotaLoadProbe {
    private var reports: [NativeQuotaLoadReport]
    private let delay: Duration
    private(set) var callCount = 0

    init(reports: [NativeQuotaLoadReport], delay: Duration) {
        self.reports = reports
        self.delay = delay
    }

    func load() async -> NativeQuotaLoadReport {
        let index = min(callCount, reports.count - 1)
        callCount += 1
        try? await Task.sleep(for: delay)
        return reports[index]
    }
}
