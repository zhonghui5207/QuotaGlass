import XCTest
@testable import QuotaGlass

final class OAuthSecurityTests: XCTestCase {
    func testGeneratedVerifierAndStateUseBase64URLFormat() throws {
        let verifier = try PKCE.generateVerifier()
        let state = try PKCE.generateState()

        XCTAssertEqual(verifier.count, 43)
        XCTAssertEqual(state.count, 43)
        XCTAssertNotEqual(verifier, state)
        XCTAssertNotNil(verifier.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression))
        XCTAssertNotNil(state.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression))
        XCTAssertFalse(verifier.contains("="))
        XCTAssertFalse(state.contains("="))
    }

    func testChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        XCTAssertEqual(
            PKCE.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testClaudePastedCodeParsesAndValidatesMatchingState() throws {
        let parsed = try ClaudeOAuth.parsePastedCode("  authorization-code # expected-state\n")

        XCTAssertEqual(parsed.code, "authorization-code")
        XCTAssertEqual(parsed.state, "expected-state")
        XCTAssertEqual(
            try ClaudeOAuth.validatedPastedCode(
                "authorization-code#expected-state",
                expectedState: "expected-state"
            ),
            "authorization-code"
        )
    }

    func testClaudePastedCodeRejectsMissingState() {
        XCTAssertThrowsError(try ClaudeOAuth.parsePastedCode("authorization-code")) { error in
            guard case OAuthLoginError.missingState = error else {
                return XCTFail("Expected missingState, got \(error)")
            }
        }

        XCTAssertThrowsError(try ClaudeOAuth.parsePastedCode("authorization-code#   ")) { error in
            guard case OAuthLoginError.missingState = error else {
                return XCTFail("Expected missingState, got \(error)")
            }
        }
    }

    func testClaudePastedCodeRejectsMismatchedState() {
        XCTAssertThrowsError(
            try ClaudeOAuth.validatedPastedCode(
                "authorization-code#attacker-state",
                expectedState: "expected-state"
            )
        ) { error in
            guard case OAuthLoginError.stateMismatch = error else {
                return XCTFail("Expected stateMismatch, got \(error)")
            }
        }
    }

    func testLoopbackParserAcceptsOnlyMatchingState() {
        let valid = "GET /auth/callback?code=valid-code&state=expected HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let invalid = "GET /auth/callback?code=attacker-code&state=wrong HTTP/1.1\r\nHost: localhost\r\n\r\n"

        XCTAssertEqual(
            LoopbackServer.parseRequest(valid, expectedState: "expected"),
            .success(code: "valid-code")
        )
        XCTAssertEqual(
            LoopbackServer.parseRequest(invalid, expectedState: "expected"),
            .invalidState
        )
    }

    func testLoopbackParserHandlesOAuthDenialAndUnrelatedPaths() {
        let denied = "GET /auth/callback?error=access_denied&state=expected HTTP/1.1\r\n\r\n"
        let unrelated = "GET /favicon.ico HTTP/1.1\r\n\r\n"

        XCTAssertEqual(LoopbackServer.parseRequest(denied, expectedState: "expected"), .denied)
        XCTAssertEqual(LoopbackServer.parseRequest(unrelated, expectedState: "expected"), .notFound)
    }

    func testLoopbackParserRejectsAmbiguousOrMalformedCallbacks() {
        let duplicateState = "GET /auth/callback?code=ok&state=expected&state=expected HTTP/1.1\r\n\r\n"
        let codeAndError = "GET /auth/callback?code=ok&error=access_denied&state=expected HTTP/1.1\r\n\r\n"
        let providerError = "GET /auth/callback?error=server_error&state=expected HTTP/1.1\r\n\r\n"
        let extraRequestField = "GET /auth/callback?code=ok&state=expected HTTP/1.1 extra\r\n\r\n"

        XCTAssertEqual(LoopbackServer.parseRequest(duplicateState, expectedState: "expected"), .invalidState)
        XCTAssertEqual(LoopbackServer.parseRequest(codeAndError, expectedState: "expected"), .malformedCallback)
        XCTAssertEqual(LoopbackServer.parseRequest(providerError, expectedState: "expected"), .malformedCallback)
        XCTAssertEqual(LoopbackServer.parseRequest(extraRequestField, expectedState: "expected"), .malformedRequest)
    }
}
