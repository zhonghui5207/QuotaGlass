import Foundation
import XCTest
@testable import QuotaGlass

final class SakanaUsageTests: XCTestCase {
    func testConsoleBillingParserExtractsWindowsPlanAndBillingValues() throws {
        let fixture = """
        Standard plan
        5-hour usage
        27.5% used
        Resets on July 20, 2026 at 3:45 PM
        Weekly usage
        66% used
        Resets on July 25, 2026 at 9:15 AM
        Credit balance $1,234.50
        Total: $12.25
        """

        let usage = try XCTUnwrap(SakanaUsage.parseConsoleBilling(fixture))

        XCTAssertEqual(usage.five?.usedPercent, 27.5)
        XCTAssertEqual(usage.weekly?.usedPercent, 66)
        XCTAssertNotNil(usage.five?.resetsAt)
        XCTAssertNotNil(usage.weekly?.resetsAt)
        XCTAssertEqual(usage.plan, "Standard")
        XCTAssertFalse(usage.primaryText.hasSuffix("% left"))
        XCTAssertTrue(usage.secondaryText?.hasSuffix(" credit") == true)
        XCTAssertEqual(usage.detailText, "console billing")
        XCTAssertFalse(usage.isCached)
    }

    func testConsoleBillingParserRejectsUnrelatedOrLoginHTML() {
        XCTAssertNil(SakanaUsage.parseConsoleBilling("<html><body>Login with Google</body></html>"))
        XCTAssertNil(SakanaUsage.parseConsoleBilling("<html><body>No usage values here</body></html>"))
    }

    func testConsoleCookieFilteringRespectsHostDomainPathAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let target = try XCTUnwrap(URL(string: "https://console.sakana.ai/billing?tab=payAsYouGo"))
        let cookies = try [
            makeCookie(name: "console-host", domain: "console.sakana.ai", path: "/billing"),
            makeCookie(name: "sakana-domain", domain: ".sakana.ai", path: "/"),
            makeCookie(name: "api-host", domain: "api.sakana.ai", path: "/"),
            makeCookie(name: "wrong-path", domain: "console.sakana.ai", path: "/settings"),
            makeCookie(
                name: "expired",
                domain: "console.sakana.ai",
                path: "/",
                expires: now.addingTimeInterval(-1)
            ),
        ]

        let filtered = SakanaConsoleSession.cookies(for: target, from: cookies, now: now)
        let names = Set(filtered.map(\.name))

        XCTAssertEqual(names, ["console-host", "sakana-domain"])
        XCTAssertFalse(names.contains("api-host"))
        XCTAssertFalse(names.contains("wrong-path"))
        XCTAssertFalse(names.contains("expired"))
    }

    func testConsoleCacheHonorsTTLAndRestoresDefaults() throws {
        let suite = "QuotaGlassTests.SakanaCache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessionKey = "unit-test-session"
        let prefix = SakanaUsageCache.cachePrefix(sessionKey)

        let reset = Date().addingTimeInterval(900)
        SakanaUsageCache.save(SakanaUsageResult(
            five: NativeWindow(usedPercent: 22.5, resetsAt: reset),
            weekly: NativeWindow(usedPercent: 48, resetsAt: nil),
            plan: "Pro",
            primaryText: "78% left",
            secondaryText: "WK 52%",
            detailText: "unit-test fixture"
        ), sessionKey: sessionKey, defaults: defaults)

        let cached = try XCTUnwrap(SakanaUsageCache.load(
            sessionKey: sessionKey,
            maxAge: 60,
            defaults: defaults
        ))
        XCTAssertEqual(cached.five?.usedPercent, 22.5)
        XCTAssertEqual(cached.weekly?.usedPercent, 48)
        XCTAssertEqual(cached.plan, "Pro")
        XCTAssertEqual(cached.primaryText, "78% left")
        XCTAssertEqual(cached.secondaryText, "WK 52%")
        XCTAssertTrue(cached.detailText?.contains("cached") == true)
        XCTAssertTrue(cached.isCached)

        defaults.set(Date().addingTimeInterval(-120).timeIntervalSince1970, forKey: prefix + "savedAt")
        XCTAssertNil(SakanaUsageCache.load(sessionKey: sessionKey, maxAge: 60, defaults: defaults))
        XCTAssertNil(SakanaUsageCache.load(sessionKey: "another-session", maxAge: 60, defaults: defaults))
    }

    func testUsageEndpointRequiresHTTPSAndSakanaHostByDefault() {
        XCTAssertNotNil(SakanaUsage.validatedUsageEndpoint(
            "https://api.sakana.ai/v1/billing",
            allowExternal: false
        ))
        XCTAssertNil(SakanaUsage.validatedUsageEndpoint(
            "http://api.sakana.ai/v1/billing",
            allowExternal: false
        ))
        XCTAssertNil(SakanaUsage.validatedUsageEndpoint(
            "https://example.com/collect",
            allowExternal: false
        ))
        XCTAssertNotNil(SakanaUsage.validatedUsageEndpoint(
            "https://example.com/billing",
            allowExternal: true
        ))
    }

    func testCookieFingerprintIsOrderIndependentAndSessionSpecific() throws {
        let first = try makeCookie(name: "session", domain: "console.sakana.ai", path: "/")
        let second = try makeCookie(name: "org", domain: ".sakana.ai", path: "/")
        let changed = try makeCookie(
            name: "session",
            domain: "console.sakana.ai",
            path: "/",
            value: "different-session"
        )

        XCTAssertEqual(
            SakanaConsoleSession.fingerprint(from: [first, second]),
            SakanaConsoleSession.fingerprint(from: [second, first])
        )
        XCTAssertNotEqual(
            SakanaConsoleSession.fingerprint(from: [first, second]),
            SakanaConsoleSession.fingerprint(from: [changed, second])
        )
    }

    func testCookieDeduplicationLetsVisibleWebSessionWin() throws {
        let shared = try makeCookie(
            name: "session",
            domain: "console.sakana.ai",
            path: "/",
            value: "older-shared-session"
        )
        let webKit = try makeCookie(
            name: "session",
            domain: "console.sakana.ai",
            path: "/",
            value: "visible-web-session"
        )

        let cookies = SakanaConsoleSession.deduplicate([shared, webKit])

        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies.first?.value, "visible-web-session")
    }
}

private func makeCookie(
    name: String,
    domain: String,
    path: String,
    expires: Date? = nil,
    value: String = "unit-test-value"
) throws -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [
        .name: name,
        .value: value,
        .domain: domain,
        .path: path,
    ]
    if let expires {
        properties[.expires] = expires
    }
    return try XCTUnwrap(HTTPCookie(properties: properties))
}
