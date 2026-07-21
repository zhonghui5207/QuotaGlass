import XCTest
@testable import QuotaGlass

// Covers the Codable usage-response models and the shared OAuth token model,
// which previously lived as untested JSONSerialization [String: Any] parsing.

final class NativeUsageParsingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Codex usage

    func testCodexUsageDecodesBothWindowsAndPlan() throws {
        let response = try decode(CodexUsageResponse.self, """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 42, "reset_at": 1893456000 },
            "secondary_window": { "used_percent": 17.5, "reset_after_seconds": 3600 }
          }
        }
        """)

        XCTAssertEqual(response.planType, "pro")
        let five = try XCTUnwrap(response.rateLimit?.primaryWindow?.value?.nativeWindow)
        XCTAssertEqual(five.usedPercent, 42)
        XCTAssertEqual(five.resetsAt, Date(timeIntervalSince1970: 1893456000))

        let weekly = try XCTUnwrap(response.rateLimit?.secondaryWindow?.value?.nativeWindow)
        XCTAssertEqual(weekly.usedPercent, 17.5)
        XCTAssertNotNil(weekly.resetsAt)
    }

    func testCodexUsageAcceptsIntOrDoublePercent() throws {
        let response = try decode(CodexUsageResponse.self, """
        { "rate_limit": { "primary_window": { "used_percent": 7 } } }
        """)
        let five = try XCTUnwrap(response.rateLimit?.primaryWindow?.value?.nativeWindow)
        XCTAssertEqual(five.usedPercent, 7)
        XCTAssertNil(five.resetsAt)
    }

    func testCodexUsageMalformedWindowDoesNotFailWholeResponse() throws {
        // A garbage used_percent must blank only that window, not the decode.
        let response = try decode(CodexUsageResponse.self, """
        {
          "rate_limit": {
            "primary_window": { "used_percent": "not-a-number" },
            "secondary_window": { "used_percent": 55 }
          }
        }
        """)
        XCTAssertNil(response.rateLimit?.primaryWindow?.value?.nativeWindow)
        XCTAssertEqual(response.rateLimit?.secondaryWindow?.value?.nativeWindow?.usedPercent, 55)
    }

    func testCodexUsageMissingWindowYieldsNil() throws {
        let response = try decode(CodexUsageResponse.self, """
        { "plan_type": "plus" }
        """)
        XCTAssertNil(response.rateLimit)
        XCTAssertEqual(response.planType, "plus")
    }

    // MARK: - Claude usage

    func testClaudeUsageDecodesISOAndEpochResets() throws {
        let response = try decode(ClaudeUsageResponse.self, """
        {
          "five_hour": { "utilization": 33, "resets_at": "2026-01-02T03:04:05Z" },
          "seven_day": { "utilization": 61, "resets_at": 1893456000 }
        }
        """)

        let five = try XCTUnwrap(response.fiveHour?.value?.nativeWindow)
        XCTAssertEqual(five.usedPercent, 33)
        XCTAssertEqual(five.resetsAt, SharedFormatters.iso8601Date(from: "2026-01-02T03:04:05Z"))

        let weekly = try XCTUnwrap(response.sevenDay?.value?.nativeWindow)
        XCTAssertEqual(weekly.usedPercent, 61)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1893456000))
    }

    func testClaudeUsageMalformedWindowDoesNotFailWholeResponse() throws {
        let response = try decode(ClaudeUsageResponse.self, """
        {
          "five_hour": { "utilization": [1, 2] },
          "seven_day": { "utilization": 48 }
        }
        """)
        XCTAssertNil(response.fiveHour?.value?.nativeWindow)
        XCTAssertEqual(response.sevenDay?.value?.nativeWindow?.usedPercent, 48)
    }

    func testClaudeUsageWindowWithoutUtilizationIsNil() throws {
        let response = try decode(ClaudeUsageResponse.self, """
        { "five_hour": { "resets_at": "2026-01-02T03:04:05Z" } }
        """)
        XCTAssertNil(response.fiveHour?.value?.nativeWindow)
    }

    // MARK: - OAuth token response

    func testOAuthTokenResponseDecodesAllFields() throws {
        let response = try decode(OAuthTokenResponse.self, """
        {
          "access_token": "at-123",
          "refresh_token": "rt-456",
          "id_token": "id-789",
          "expires_in": 3600,
          "account": { "email_address": "a@example.com", "uuid": "u-1" }
        }
        """)
        XCTAssertEqual(response.accessToken, "at-123")
        XCTAssertEqual(response.refreshToken, "rt-456")
        XCTAssertEqual(response.idToken, "id-789")
        XCTAssertEqual(response.expiresIn, 3600)
        XCTAssertEqual(response.account?.emailAddress, "a@example.com")
        XCTAssertEqual(response.account?.uuid, "u-1")
    }

    func testOAuthTokenResponseToleratesMissingOptionals() throws {
        let response = try decode(OAuthTokenResponse.self, """
        { "access_token": "only-access" }
        """)
        XCTAssertEqual(response.accessToken, "only-access")
        XCTAssertNil(response.refreshToken)
        XCTAssertNil(response.idToken)
        XCTAssertNil(response.expiresIn)
        XCTAssertNil(response.account)
    }

    // MARK: - LenientValue

    func testLenientValueSurvivesWrongShape() throws {
        struct Outer: Decodable {
            var window: LenientValue<CodexUsageResponse.Window>?
        }
        let decoded = try decode(Outer.self, """
        { "window": "this should have been an object" }
        """)
        XCTAssertNotNil(decoded.window)
        XCTAssertNil(decoded.window?.value)
    }
}
