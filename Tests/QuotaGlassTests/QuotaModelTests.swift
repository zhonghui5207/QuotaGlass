import XCTest
@testable import QuotaGlass

final class QuotaModelTests: XCTestCase {
    func testStableAccountKeysDoNotCollideForMatchingDisplayNames() {
        let first = makeSnapshot(
            identity: .init(provider: .codex, source: "imported", stableID: "organization-a/account-1"),
            accountName: "same@example.com"
        )
        var second = makeSnapshot(
            identity: .init(provider: .codex, source: "imported", stableID: "organization-b/account-1"),
            accountName: "same@example.com"
        )

        XCTAssertNotEqual(accountKey(first), accountKey(second))
        XCTAssertEqual(legacyAccountKey(first), legacyAccountKey(second))

        let originalSecondKey = accountKey(second)
        second.accountName = "renamed@example.com"
        XCTAssertEqual(accountKey(second), originalSecondKey)
    }

    func testMissingQuotaWindowsRemainUnknownInsteadOfBecomingFullyRemaining() {
        let snapshot = makeSnapshot(
            identity: .init(provider: .sakana, source: "api-key", stableID: "account-without-windows"),
            accountName: "API account",
            fiveHourUsed: nil,
            weeklyUsed: nil
        )

        XCTAssertNil(snapshot.fiveHourUsedPct)
        XCTAssertNil(snapshot.weeklyUsedPct)
        XCTAssertNil(snapshot.fiveHourRemaining)
        XCTAssertNil(snapshot.weeklyRemaining)
        XCTAssertFalse(snapshot.hasWindowData)
    }

    func testCodexWorkspaceIdentityIncludesUserID() {
        let first = NativeCodexAccount(
            email: "first@example.com",
            planType: "team",
            accountId: "workspace-id",
            userId: "user-1",
            accessToken: nil,
            refreshToken: nil,
            idToken: nil,
            importedId: nil
        )
        var second = first
        second.userId = "user-2"

        XCTAssertEqual(first.stableAccountID, "workspace-id:user-1")
        XCTAssertEqual(second.stableAccountID, "workspace-id:user-2")
        XCTAssertNotEqual(first.stableAccountID, second.stableAccountID)
    }
}

func makeSnapshot(
    identity: QuotaAccountIdentity,
    serviceName: String = "Codex",
    accountName: String,
    fiveHourUsed: Double? = 12,
    weeklyUsed: Double? = 34,
    fetchedAt: Date = Date()
) -> QuotaSnapshot {
    QuotaSnapshot(
        identity: identity,
        serviceName: serviceName,
        accountName: accountName,
        planName: "Pro",
        fiveHourUsed: fiveHourUsed,
        weeklyUsed: weeklyUsed,
        fiveHourReset: "2h",
        weeklyReset: "3d",
        source: "Unit Test",
        fetchedAt: fetchedAt
    )
}
