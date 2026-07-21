import Foundation

// Shared OAuth2 token-endpoint plumbing used by both the in-app login flows
// (authorization_code) and the background refreshers (refresh_token): builds
// the form-encoded body, validates the HTTP response, and decodes the token
// JSON into a typed model instead of ad-hoc [String: Any] casts.

struct OAuthTokenResponse: Decodable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var expiresIn: Double?
    /// Claude token responses may embed account metadata; Codex does not.
    var account: Account?

    struct Account: Decodable, Sendable {
        var email: String?
        var emailAddress: String?
        var uuid: String?
        var id: String?
        var accountUuid: String?
        var accountId: String?

        enum CodingKeys: String, CodingKey {
            case email
            case emailAddress = "email_address"
            case uuid
            case id
            case accountUuid = "account_uuid"
            case accountId = "account_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
        case account
    }
}

enum OAuthHTTP {
    /// POSTs form parameters to a token endpoint and decodes the standard
    /// OAuth2 token response. Every failure surfaces as OAuthLoginError so the
    /// login sheets can show it; refreshers swallow it with `try?`.
    static func postForm(
        to url: URL,
        parameters: [(name: String, value: String)]
    ) async throws -> OAuthTokenResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = parameters.map { .init(name: $0.name, value: $0.value) }
        req.httpBody = (comps.percentEncodedQuery ?? "").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw OAuthLoginError.badResponse("令牌服务响应无效")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OAuthLoginError.badResponse("令牌服务返回 HTTP \(http.statusCode)")
        }
        let response: OAuthTokenResponse
        do {
            response = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        } catch {
            throw OAuthLoginError.badResponse("令牌服务响应格式无效")
        }
        guard !response.accessToken.isEmpty else {
            throw OAuthLoginError.badResponse("令牌服务响应格式无效")
        }
        return response
    }
}
