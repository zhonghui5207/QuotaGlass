import SwiftUI
import AppKit
import WebKit

// Sheets for the in-app OAuth "add account" flows, presented from settings.

// MARK: - Claude (browser + paste authorization code)

struct ClaudeLoginSheet: View {
    let store: QuotaStore
    @Environment(\.dismiss) private var dismiss

    @State private var verifier = ""
    @State private var state = ""
    @State private var pastedCode = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var loginTask: Task<Void, Never>?
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("登录 Claude 账号")
                .font(.system(size: 15, weight: .semibold))

            Text("1. 打开浏览器，用要添加的账号登录并授权\n2. 授权完成后页面会显示一串授权码\n3. 把授权码粘贴到下面，点「完成登录」")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button(verifier.isEmpty ? "准备浏览器授权" : "重新打开浏览器授权") {
                beginAuthorization()
            }

            TextField("粘贴授权码（形如 xxxx#yyyy）", text: $pastedCode)
                .textFieldStyle(.roundedBorder)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button("取消") { cancelAndDismiss() }
                Button(working ? "登录中…" : "完成登录") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        working
                            || verifier.isEmpty
                            || state.isEmpty
                            || pastedCode.trimmingCharacters(in: .whitespaces).isEmpty
                    )
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if verifier.isEmpty { beginAuthorization() }
        }
        .onDisappear(perform: invalidateAttempt)
    }

    @MainActor
    private func beginAuthorization() {
        invalidateAttempt()
        errorText = nil
        working = false
        pastedCode = ""

        do {
            verifier = try PKCE.generateVerifier()
            state = try PKCE.generateState()
            NSWorkspace.shared.open(ClaudeOAuth.authorizeURL(verifier: verifier, state: state))
        } catch {
            verifier = ""
            state = ""
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func finish() {
        let attempt = generation
        let attemptVerifier = verifier
        let attemptState = state
        let code = pastedCode
        working = true
        errorText = nil

        loginTask?.cancel()
        loginTask = Task { @MainActor in
            do {
                let (account, tokens) = try await ClaudeOAuth.exchange(
                    pastedCode: code,
                    verifier: attemptVerifier,
                    expectedState: attemptState
                )
                try Task.checkCancellation()
                guard attempt == generation else { return }
                try ImportedAccountStore.addReporting(account, tokens: tokens)
                guard attempt == generation else { return }
                Task { await store.forceRefresh() }
                dismiss()
            } catch is CancellationError {
                guard attempt == generation else { return }
                working = false
            } catch {
                guard attempt == generation else { return }
                errorText = error.localizedDescription
                working = false
            }
        }
    }

    @MainActor
    private func cancelAndDismiss() {
        invalidateAttempt()
        dismiss()
    }

    @MainActor
    private func invalidateAttempt() {
        generation &+= 1
        loginTask?.cancel()
        loginTask = nil
    }
}

// MARK: - Codex (browser + automatic loopback callback)

struct CodexLoginSheet: View {
    let store: QuotaStore
    @Environment(\.dismiss) private var dismiss

    @State private var verifier = ""
    @State private var state = ""
    @State private var server: LoopbackServer?
    @State private var statusText = "等待浏览器授权…"
    @State private var errorText: String?
    @State private var finished = false
    @State private var loginTask: Task<Void, Never>?
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("登录 Codex 账号")
                .font(.system(size: 15, weight: .semibold))

            Text("浏览器里用要添加的账号登录，授权后会自动跳回，无需手动操作。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if errorText == nil && !finished { ProgressView().controlSize(.small) }
                Text(statusText)
                    .font(.system(size: 12))
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Button("重新打开浏览器") {
                    begin()
                }
                Spacer()
                Button("取消") { cancelAndDismiss() }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: begin)
        .onDisappear(perform: invalidateAttempt)
    }

    @MainActor
    private func begin() {
        invalidateAttempt()
        let attempt = generation
        errorText = nil
        finished = false
        statusText = "等待浏览器授权…"

        do {
            verifier = try PKCE.generateVerifier()
            state = try PKCE.generateState()
        } catch {
            verifier = ""
            state = ""
            errorText = error.localizedDescription
            statusText = "无法准备安全登录"
            return
        }

        let attemptVerifier = verifier
        let attemptState = state
        let server = LoopbackServer()
        self.server = server
        do {
            try server.start(expectedState: attemptState) { result in
                Task { @MainActor in
                    handleCallback(
                        result,
                        generation: attempt,
                        verifier: attemptVerifier,
                        expectedState: attemptState
                    )
                }
            }
        } catch {
            errorText = error.localizedDescription
            statusText = "无法启动本地回调"
            self.server = nil
            return
        }
        NSWorkspace.shared.open(CodexOAuth.authorizeURL(verifier: attemptVerifier, state: attemptState))
    }

    @MainActor
    private func handleCallback(
        _ result: Result<(code: String, state: String), Error>,
        generation attempt: Int,
        verifier attemptVerifier: String,
        expectedState: String
    ) {
        guard attempt == generation else { return }
        server = nil
        switch result {
        case .failure(let error):
            errorText = error.localizedDescription
            statusText = "登录失败"
        case .success(let callback):
            guard callback.state == expectedState else {
                errorText = OAuthLoginError.stateMismatch.localizedDescription
                statusText = "登录失败"
                return
            }
            statusText = "正在换取 token…"
            loginTask?.cancel()
            loginTask = Task { @MainActor in
                do {
                    let (account, tokens) = try await CodexOAuth.exchange(
                        code: callback.code,
                        verifier: attemptVerifier
                    )
                    try Task.checkCancellation()
                    guard attempt == generation else { return }
                    try ImportedAccountStore.addReporting(account, tokens: tokens)
                    finished = true
                    statusText = "登录成功"
                    guard attempt == generation else { return }
                    Task { await store.forceRefresh() }
                    dismiss()
                } catch is CancellationError {
                    guard attempt == generation else { return }
                    statusText = "登录已取消"
                } catch {
                    guard attempt == generation else { return }
                    errorText = error.localizedDescription
                    statusText = "登录失败"
                }
            }
        }
    }

    @MainActor
    private func cancelAndDismiss() {
        invalidateAttempt()
        dismiss()
    }

    @MainActor
    private func invalidateAttempt() {
        generation &+= 1
        server?.cancel()
        server = nil
        loginTask?.cancel()
        loginTask = nil
    }
}

// MARK: - Sakana (in-app console session)

struct SakanaLoginSheet: View {
    let store: QuotaStore
    @Environment(\.dismiss) private var dismiss
    @State private var pastedLoginURL = ""
    @State private var requestedURL: URL?
    @State private var statusRequest = 0
    @State private var saveRequest = 0
    @State private var statusText = "尚未检查登录状态"
    @State private var generation = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("登录 Sakana Console")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Google 登录可能会被内嵌浏览器拒绝；推荐用邮箱登录，把邮件里的登录链接粘贴到这里打开。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("取消") { cancelAndDismiss() }
                    Button("完成") {
                        statusText = "正在保存页面用量…"
                        saveRequest += 1
                    }
                    .keyboardShortcut(.defaultAction)
                }

                HStack(spacing: 8) {
                    TextField("粘贴 Sakana 登录邮件里的链接", text: $pastedLoginURL)
                        .textFieldStyle(.roundedBorder)
                    Button("从剪贴板打开") {
                        openClipboardLoginURL()
                    }
                    Button("打开链接") {
                        openPastedLoginURL()
                    }
                    .disabled(pastedLoginURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("回到 Billing") {
                        requestedURL = URL(string: "https://console.sakana.ai/billing?tab=payAsYouGo")
                    }
                    Button("检查状态") {
                        statusText = "正在检查…"
                        statusRequest += 1
                    }
                }

                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(14)

            Divider()

            SakanaWebView(
                url: URL(string: "https://console.sakana.ai/billing?tab=payAsYouGo")!,
                requestedURL: $requestedURL,
                statusRequest: $statusRequest,
                saveRequest: $saveRequest,
                statusText: $statusText,
                generation: $generation,
                onFinish: {
                    generation &+= 1
                    dismiss()
                    Task { await store.forceRefresh() }
                }
            )
                .frame(width: 920, height: 680)
        }
        .onDisappear {
            generation &+= 1
        }
    }

    @MainActor
    private func cancelAndDismiss() {
        generation &+= 1
        dismiss()
    }

    private func openPastedLoginURL() {
        let raw = pastedLoginURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        requestedURL = url
    }

    private func openClipboardLoginURL() {
        guard let raw = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        pastedLoginURL = raw
        requestedURL = url
    }
}

private struct SakanaWebView: NSViewRepresentable {
    let url: URL
    @Binding var requestedURL: URL?
    @Binding var statusRequest: Int
    @Binding var saveRequest: Int
    @Binding var statusText: String
    @Binding var generation: Int
    let onFinish: () -> Void

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var lastLoadedRequest: URL?
        var lastStatusRequest = 0
        var lastSaveRequest = 0
        var generation = 0
        var isActive = true
        var navigationSerial = 0

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            navigationSerial &+= 1
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        context.coordinator.webView = webView
        context.coordinator.lastLoadedRequest = url
        context.coordinator.generation = generation
        context.coordinator.isActive = true
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.generation = generation
        context.coordinator.isActive = true

        if let requestedURL, context.coordinator.lastLoadedRequest != requestedURL {
            context.coordinator.lastLoadedRequest = requestedURL
            webView.load(URLRequest(url: requestedURL))
        } else if webView.url == nil {
            context.coordinator.lastLoadedRequest = url
            webView.load(URLRequest(url: url))
        }

        if context.coordinator.lastStatusRequest != statusRequest {
            context.coordinator.lastStatusRequest = statusRequest
            updateStatus(from: webView, coordinator: context.coordinator)
        }

        if context.coordinator.lastSaveRequest != saveRequest {
            context.coordinator.lastSaveRequest = saveRequest
            saveVisibleBilling(from: webView, coordinator: context.coordinator)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.isActive = false
        coordinator.generation &+= 1
        coordinator.webView = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    private func updateStatus(from webView: WKWebView, coordinator: Coordinator) {
        let requestGeneration = coordinator.generation
        let navigationSerial = coordinator.navigationSerial
        let currentURL = webView.url?.absoluteString ?? "about:blank"
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let sharedCookies = SakanaConsoleSession.sharedStorageCookies()
            let relevant = SakanaConsoleSession.relevantCookies(
                from: SakanaConsoleSession.deduplicate(sharedCookies + cookies)
            )
            let names = relevant.map(\.name).sorted().joined(separator: ", ")
            let cookieText = relevant.isEmpty ? "无 Sakana cookie" : "\(relevant.count) 个 Sakana cookie: \(names)"
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                let parsed = (value as? String).flatMap(SakanaUsage.parseConsoleBilling)
                let parseText = parsed.map { "可解析：\($0.primaryText)，\($0.secondaryText ?? "Weekly 已读取")" } ?? "未解析到页面用量"
                DispatchQueue.main.async {
                    guard generation == requestGeneration,
                          coordinator.isActive,
                          coordinator.generation == requestGeneration,
                          coordinator.navigationSerial == navigationSerial else { return }
                    statusText = "当前页：\(currentURL)；WebKit \(cookies.count)，共享 \(sharedCookies.count)；\(cookieText)；\(parseText)"
                }
            }
        }
    }

    private func saveVisibleBilling(from webView: WKWebView, coordinator: Coordinator) {
        let requestGeneration = coordinator.generation
        let navigationSerial = coordinator.navigationSerial
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, error in
            let text = value as? String ?? ""
            if let error {
                DispatchQueue.main.async {
                    guard generation == requestGeneration,
                          coordinator.isActive,
                          coordinator.generation == requestGeneration,
                          coordinator.navigationSerial == navigationSerial else { return }
                    statusText = "读取页面失败：\(error.localizedDescription)"
                }
                return
            }
            guard let usage = SakanaUsage.parseConsoleBilling(text) else {
                DispatchQueue.main.async {
                    guard generation == requestGeneration,
                          coordinator.isActive,
                          coordinator.generation == requestGeneration,
                          coordinator.navigationSerial == navigationSerial else { return }
                    statusText = "没能从当前页面解析到用量，请确认 Billing 页已经显示 Usage limit。"
                }
                return
            }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { webCookies in
                let cookies = SakanaConsoleSession.cookies(
                    for: SakanaUsage.billingEndpoint,
                    from: SakanaConsoleSession.deduplicate(
                        SakanaConsoleSession.sharedStorageCookies() + webCookies
                    )
                )
                let sessionKey = cookies.isEmpty ? nil : SakanaConsoleSession.fingerprint(from: cookies)
                DispatchQueue.main.async {
                    guard generation == requestGeneration,
                          coordinator.isActive,
                          coordinator.generation == requestGeneration else { return }
                    guard coordinator.navigationSerial == navigationSerial else {
                        statusText = "页面已发生跳转，请在 Billing 页重新保存。"
                        return
                    }
                    guard let sessionKey else {
                        statusText = "页面已有用量，但没有找到可复用的 Sakana 登录会话。"
                        return
                    }
                    SakanaUsageCache.save(usage, sessionKey: sessionKey)
                    statusText = "已保存：\(usage.primaryText)，\(usage.secondaryText ?? "Weekly 已读取")"
                    onFinish()
                }
            }
        }
    }
}
