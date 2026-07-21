import Foundation
import CryptoKit
import Network
import Security

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
    /// Generates a PKCE verifier from the system CSPRNG. New call sites should
    /// surface this error instead of silently continuing with weak randomness.
    static func generateVerifier() throws -> String {
        base64url(try randomBytes(count: 32))
    }

    /// OAuth state is generated independently from the PKCE verifier so the
    /// verifier itself is never disclosed in an authorization URL.
    static func generateState() throws -> String {
        base64url(try randomBytes(count: 32))
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

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PKCEGenerationError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }
}

enum PKCEGenerationError: LocalizedError {
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            return "无法生成安全随机数（错误码：\(status)）"
        }
    }
}

enum OAuthLoginError: LocalizedError {
    case badResponse(String)
    case portInUse
    case cancelled
    case stateMismatch
    case missingState

    var errorDescription: String? {
        switch self {
        case .badResponse(let detail): return "登录失败：\(detail)"
        case .portInUse: return "本地端口 1455 被占用（是否有 codex CLI 正在登录？），关掉后重试"
        case .cancelled: return "登录已取消"
        case .stateMismatch: return "回调校验失败（state 不匹配），请重试"
        case .missingState: return "授权码缺少 state，请重新打开浏览器授权"
        }
    }
}

// MARK: - Claude

enum ClaudeOAuth {
    static let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"

    static func authorizeURL(verifier: String, state: String) -> URL {
        var comps = URLComponents(string: "https://claude.ai/oauth/authorize")!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: ClaudeRefresher.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return comps.url!
    }

    /// Exchanges Claude's pasted `code#state` value after validating that the
    /// returned state belongs to this login attempt.
    static func exchange(
        pastedCode: String,
        verifier: String,
        expectedState: String
    ) async throws -> (ImportedAccount, ImportedTokens) {
        let code = try validatedPastedCode(pastedCode, expectedState: expectedState)

        let response = try await OAuthHTTP.postForm(
            to: ClaudeRefresher.tokenEndpoint,
            parameters: [
                (name: "grant_type", value: "authorization_code"),
                (name: "code", value: code),
                (name: "code_verifier", value: verifier),
                (name: "client_id", value: ClaudeRefresher.clientID),
                (name: "redirect_uri", value: redirectURI),
                (name: "state", value: expectedState),
            ]
        )
        let access = response.accessToken
        let refresh = response.refreshToken
        let expiresMillis = Int((Date().timeIntervalSince1970 + (response.expiresIn ?? 3600)) * 1000)

        // Token responses may carry account info; take what's there.
        let accountInfo = response.account
        let email = accountInfo?.emailAddress ?? accountInfo?.email
        let accountId = [
            accountInfo?.uuid,
            accountInfo?.id,
            accountInfo?.accountUuid,
            accountInfo?.accountId,
            email,
        ]
            .compactMap { $0 }
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

    /// Pure parsing entry point kept internal for unit tests.
    static func parsePastedCode(_ pastedCode: String) throws -> (code: String, state: String) {
        let value = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = value.firstIndex(of: "#") else {
            throw OAuthLoginError.missingState
        }
        let code = String(value[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let state = String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw OAuthLoginError.badResponse("授权码为空") }
        guard !state.isEmpty else { throw OAuthLoginError.missingState }
        return (code, state)
    }

    /// Pure validation entry point: no network or credential persistence.
    static func validatedPastedCode(_ pastedCode: String, expectedState: String) throws -> String {
        let (code, returnedState) = try parsePastedCode(pastedCode)
        guard statesMatch(returnedState, expectedState) else {
            throw OAuthLoginError.stateMismatch
        }
        return code
    }

    private static func statesMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return SHA256.hash(data: Data(lhs.utf8)) == SHA256.hash(data: Data(rhs.utf8))
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
        let response = try await OAuthHTTP.postForm(
            to: URL(string: issuer + "/oauth/token")!,
            parameters: [
                (name: "grant_type", value: "authorization_code"),
                (name: "code", value: code),
                (name: "redirect_uri", value: redirectURI),
                (name: "client_id", value: CodexRefresher.clientID),
                (name: "code_verifier", value: verifier),
            ]
        )
        let access = response.accessToken
        let refresh = response.refreshToken
        let idToken = response.idToken

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
    enum CallbackRequest: Equatable {
        case success(code: String)
        case denied
        case malformedCallback
        case invalidState
        case notFound
        case malformedRequest
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "quotaglass.loopback")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var completion: ((Result<(code: String, state: String), Error>) -> Void)?
    private var expectedState: String?
    private let maximumRequestBytes = 16_384

    init() {
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start(
        expectedState: String,
        completion: @escaping (Result<(code: String, state: String), Error>) -> Void
    ) throws {
        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            // Accept IPv4/IPv6 loopback callbacks, but never expose the OAuth
            // receiver to another device on the local network.
            parameters.acceptLocalOnly = true
            listener = try NWListener(using: parameters, on: 1455)
        } catch {
            throw OAuthLoginError.portInUse
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(.failure(OAuthLoginError.portInUse)) }
        }
        // Every mutable field is confined to `queue`. Network callbacks already
        // arrive there; synchronizing setup and cancellation removes the race
        // between a dismissed login sheet and a late callback.
        queue.sync {
            self.completion = completion
            self.expectedState = expectedState
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    func cancel() {
        let cleanup = {
            self.listener?.cancel()
            self.listener = nil
            self.completion = nil
            self.expectedState = nil
        }
        // `begin()` immediately binds a replacement listener on the same port,
        // so cancellation must finish before it returns. Avoid a deadlock if a
        // future caller invokes cancel from the callback queue itself.
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            cleanup()
        } else {
            queue.sync(execute: cleanup)
        }
    }

    private func finish(_ result: Result<(code: String, state: String), Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion else { return }
        self.completion = nil
        expectedState = nil
        listener?.cancel()
        listener = nil
        completion(result)
    }

    private func handle(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var requestData = accumulated
            if let data { requestData.append(data) }
            guard requestData.count <= self.maximumRequestBytes else {
                self.respond(connection, body: "Request too large", status: "413 Content Too Large")
                return
            }

            if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                guard let request = String(data: requestData, encoding: .utf8),
                      let expectedState = self.expectedState else {
                    self.respond(connection, body: "Bad request", status: "400 Bad Request")
                    return
                }
                self.process(
                    Self.parseRequest(request, expectedState: expectedState),
                    expectedState: expectedState,
                    connection: connection
                )
            } else if isComplete || error != nil {
                self.respond(connection, body: "Incomplete request", status: "400 Bad Request")
            } else {
                self.receiveRequest(on: connection, accumulated: requestData)
            }
        }
    }

    private func process(_ callback: CallbackRequest, expectedState: String, connection: NWConnection) {
        switch callback {
        case .success(let code):
            respond(
                connection,
                body: "<html><body style=\"font-family:-apple-system;text-align:center;padding-top:80px\"><h2>登录成功</h2><p>可以关掉这个页面，回到 QuotaGlass。</p></body></html>",
                status: "200 OK"
            )
            finish(.success((code: code, state: expectedState)))
        case .denied:
            respond(connection, body: "登录已取消，可以关闭此页面。", status: "200 OK")
            finish(.failure(OAuthLoginError.cancelled))
        case .malformedCallback:
            respond(connection, body: "授权回调缺少必要参数。", status: "400 Bad Request")
            finish(.failure(OAuthLoginError.badResponse("授权回调缺少必要参数")))
        case .invalidState:
            // A stray or malicious request must not consume the one-shot login.
            respond(connection, body: "Invalid OAuth state", status: "400 Bad Request")
        case .notFound:
            respond(connection, body: "Not found", status: "404 Not Found")
        case .malformedRequest:
            respond(connection, body: "Bad request", status: "400 Bad Request")
        }
    }

    static func parseRequest(_ request: String, expectedState: String) -> CallbackRequest {
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            return .malformedRequest
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3,
              parts[0] == "GET",
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            return .malformedRequest
        }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(target)"),
              components.path == "/auth/callback" else {
            return .notFound
        }

        let items = components.queryItems ?? []
        let stateItems = items.filter { $0.name == "state" }
        let codeItems = items.filter { $0.name == "code" }
        let errorItems = items.filter { $0.name == "error" }
        guard stateItems.count == 1,
              let returnedState = stateItems[0].value,
              statesMatch(returnedState, expectedState) else {
            return .invalidState
        }
        guard !(codeItems.isEmpty == false && errorItems.isEmpty == false) else {
            return .malformedCallback
        }
        if codeItems.count == 1, let code = codeItems[0].value, !code.isEmpty {
            return .success(code: code)
        }
        if errorItems.count == 1, let error = errorItems[0].value {
            return error == "access_denied" ? .denied : .malformedCallback
        }
        return .malformedCallback
    }

    private static func statesMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return SHA256.hash(data: Data(lhs.utf8)) == SHA256.hash(data: Data(rhs.utf8))
    }

    private func respond(_ connection: NWConnection, body: String, status: String) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: payload.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
