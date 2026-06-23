import Foundation
import CryptoKit
import Network

// In-app OAuth login for adding accounts.
//
// Claude: browser → claude.ai/oauth/authorize (code=true) → the page displays
// an authorization code the user pastes back → token exchange at
// platform.claude.com (same endpoint our refresher already uses). Flow matches
// current Claude Code CLI / opencode behavior.
//
// Codex: browser → auth.openai.com/oauth/authorize → loopback redirect to
// http://localhost:1455/auth/callback (the redirect URI registered for the
// codex CLI client id) → automatic code capture → token exchange.

enum PKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OAuthLoginError: LocalizedError {
    case badResponse(String)
    case portInUse
    case cancelled
    case stateMismatch

    var errorDescription: String? {
        switch self {
        case .badResponse(let detail): return "登录失败：\(detail)"
        case .portInUse: return "本地端口 1455 被占用（是否有 codex CLI 正在登录？），关掉后重试"
        case .cancelled: return "登录已取消"
        case .stateMismatch: return "回调校验失败（state 不匹配），请重试"
        }
    }
}

// MARK: - Claude

enum ClaudeOAuth {
    static let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"

    static func authorizeURL(verifier: String) -> URL {
        var comps = URLComponents(string: "https://claude.ai/oauth/authorize")!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: ClaudeRefresher.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: verifier),
        ]
        return comps.url!
    }

    /// Exchanges the pasted authorization code ("code#state" or bare code).
    static func exchange(pastedCode: String, verifier: String) async throws -> (ImportedAccount, ImportedTokens) {
        let code = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "#").first.map(String.init) ?? ""
        guard !code.isEmpty else { throw OAuthLoginError.badResponse("授权码为空") }

        var req = URLRequest(url: ClaudeRefresher.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "code_verifier", value: verifier),
            .init(name: "client_id", value: ClaudeRefresher.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "state", value: verifier),
        ]
        req.httpBody = (comps.percentEncodedQuery ?? "").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String else {
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? "未知错误"
            throw OAuthLoginError.badResponse(String(detail))
        }

        let refresh = root["refresh_token"] as? String
        let expiresIn = (root["expires_in"] as? Double) ?? Double(root["expires_in"] as? Int ?? 3600)
        let expiresMillis = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)

        // Token responses may carry account info; take what's there.
        let accountInfo = root["account"] as? [String: Any]
        let email = accountInfo?["email_address"] as? String ?? accountInfo?["email"] as? String
        let accountId = [
            accountInfo?["uuid"],
            accountInfo?["id"],
            accountInfo?["account_uuid"],
            accountInfo?["account_id"],
            email,
        ]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }
            ?? "token-\(tokenFingerprint(access))"

        let account = ImportedAccount(
            id: accountId,
            service: .claude,
            email: email,
            planType: nil,
            addedAt: Date()
        )
        let tokens = ImportedTokens(
            accessToken: access,
            refreshToken: refresh,
            idToken: nil,
            expiresAtMillis: expiresMillis
        )
        return (account, tokens)
    }

    private static func tokenFingerprint(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Codex

enum CodexOAuth {
    static let issuer = "https://auth.openai.com"
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let scopes = "openid profile email offline_access"

    static func authorizeURL(verifier: String, state: String) -> URL {
        var comps = URLComponents(string: issuer + "/oauth/authorize")!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: CodexRefresher.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: state),
            .init(name: "originator", value: "codex_cli_rs"),
        ]
        return comps.url!
    }

    static func exchange(code: String, verifier: String) async throws -> (ImportedAccount, ImportedTokens) {
        var req = URLRequest(url: URL(string: issuer + "/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "client_id", value: CodexRefresher.clientID),
            .init(name: "code_verifier", value: verifier),
        ]
        req.httpBody = (comps.percentEncodedQuery ?? "").data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String else {
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? "未知错误"
            throw OAuthLoginError.badResponse(String(detail))
        }

        let refresh = root["refresh_token"] as? String
        let idToken = root["id_token"] as? String

        let idClaims = idToken.flatMap { NativeJWT.decodePayload($0) }
        let accessClaims = NativeJWT.decodePayload(access)
        let email = idClaims?["email"] as? String ?? accessClaims?["email"] as? String
        var plan: String?
        var accountId: String?
        var userId: String?
        for claims in [idClaims, accessClaims] {
            if let auth = claims?["https://api.openai.com/auth"] as? [String: Any] {
                if plan == nil { plan = auth["chatgpt_plan_type"] as? String }
                if accountId == nil { accountId = auth["chatgpt_account_id"] as? String }
                if userId == nil { userId = auth["chatgpt_user_id"] as? String }
            }
        }
        guard let accountId, !accountId.isEmpty else {
            throw OAuthLoginError.badResponse("token 中没有 chatgpt_account_id")
        }
        let compositeId = userId.flatMap { $0.isEmpty ? nil : "\(accountId):\($0)" } ?? accountId

        let account = ImportedAccount(
            id: compositeId,
            service: .codex,
            email: email,
            planType: plan,
            addedAt: Date()
        )
        let tokens = ImportedTokens(
            accessToken: access,
            refreshToken: refresh,
            idToken: idToken,
            expiresAtMillis: nil
        )
        return (account, tokens)
    }
}

// MARK: - Loopback callback server (Codex)

/// Minimal one-shot HTTP listener on localhost:1455 that captures the OAuth
/// redirect, replies with a tiny success page, and hands back code + state.
final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "quotaglass.loopback")
    private var completion: ((Result<(code: String, state: String), Error>) -> Void)?

    func start(completion: @escaping (Result<(code: String, state: String), Error>) -> Void) throws {
        self.completion = completion
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: 1455)
        } catch {
            throw OAuthLoginError.portInUse
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(.failure(OAuthLoginError.portInUse)) }
        }
        listener.start(queue: queue)
    }

    func cancel() {
        listener?.cancel()
        listener = nil
        completion = nil
    }

    private func finish(_ result: Result<(code: String, state: String), Error>) {
        guard let completion else { return }
        self.completion = nil
        listener?.cancel()
        listener = nil
        completion(result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            // First line: GET /auth/callback?code=...&state=... HTTP/1.1
            let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : ""

            guard path.hasPrefix("/auth/callback"),
                  let comps = URLComponents(string: "http://localhost\(path)"),
                  let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
                  let state = comps.queryItems?.first(where: { $0.name == "state" })?.value else {
                self.respond(connection, body: "Not found", status: "404 Not Found")
                return
            }
            self.respond(
                connection,
                body: "<html><body style=\"font-family:-apple-system;text-align:center;padding-top:80px\"><h2>登录成功</h2><p>可以关掉这个页面，回到 QuotaGlass。</p></body></html>",
                status: "200 OK"
            )
            self.finish(.success((code: code, state: state)))
        }
    }

    private func respond(_ connection: NWConnection, body: String, status: String) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: payload.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
