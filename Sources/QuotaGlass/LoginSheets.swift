import SwiftUI
import AppKit
import WebKit

// Sheets for the in-app OAuth "add account" flows, presented from settings.

// MARK: - Claude (browser + paste authorization code)

struct ClaudeLoginSheet: View {
    let store: QuotaStore
    @Environment(\.dismiss) private var dismiss

    @State private var verifier = PKCE.verifier()
    @State private var pastedCode = ""
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("登录 Claude 账号")
                .font(.system(size: 15, weight: .semibold))

            Text("1. 打开浏览器，用要添加的账号登录并授权\n2. 授权完成后页面会显示一串授权码\n3. 把授权码粘贴到下面，点「完成登录」")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button("打开浏览器授权") {
                NSWorkspace.shared.open(ClaudeOAuth.authorizeURL(verifier: verifier))
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
                Button("取消") { dismiss() }
                Button(working ? "登录中…" : "完成登录") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || pastedCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func finish() {
        working = true
        errorText = nil
        Task { @MainActor in
            do {
                let (account, tokens) = try await ClaudeOAuth.exchange(pastedCode: pastedCode, verifier: verifier)
                ImportedAccountStore.add(account, tokens: tokens)
                await store.refresh()
                dismiss()
            } catch {
                errorText = error.localizedDescription
                working = false
            }
        }
    }
}

// MARK: - Codex (browser + automatic loopback callback)

struct CodexLoginSheet: View {
    let store: QuotaStore
    @Environment(\.dismiss) private var dismiss

    @State private var verifier = PKCE.verifier()
    @State private var state = PKCE.verifier()
    @State private var server: LoopbackServer?
    @State private var statusText = "等待浏览器授权…"
    @State private var errorText: String?
    @State private var finished = false

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
                    NSWorkspace.shared.open(CodexOAuth.authorizeURL(verifier: verifier, state: state))
                }
                Spacer()
                Button("取消") {
                    server?.cancel()
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: begin)
        .onDisappear { server?.cancel() }
    }

    private func begin() {
        let server = LoopbackServer()
        self.server = server
        do {
            try server.start { result in
                Task { @MainActor in handleCallback(result) }
            }
        } catch {
            errorText = error.localizedDescription
            statusText = "无法启动本地回调"
            return
        }
        NSWorkspace.shared.open(CodexOAuth.authorizeURL(verifier: verifier, state: state))
    }

    @MainActor
    private func handleCallback(_ result: Result<(code: String, state: String), Error>) {
        switch result {
        case .failure(let error):
            errorText = error.localizedDescription
            statusText = "登录失败"
        case .success(let callback):
            guard callback.state == state else {
                errorText = OAuthLoginError.stateMismatch.localizedDescription
                statusText = "登录失败"
                return
            }
            statusText = "正在换取 token…"
            Task { @MainActor in
                do {
                    let (account, tokens) = try await CodexOAuth.exchange(code: callback.code, verifier: verifier)
                    ImportedAccountStore.add(account, tokens: tokens)
                    finished = true
                    statusText = "登录成功"
                    await store.refresh()
                    dismiss()
                } catch {
                    errorText = error.localizedDescription
                    statusText = "登录失败"
                }
            }
        }
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
                    Button("取消") { dismiss() }
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
                onFinish: {
                    dismiss()
                    Task { await store.refresh() }
                }
            )
                .frame(width: 920, height: 680)
        }
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
    let onFinish: () -> Void

    final class Coordinator {
        weak var webView: WKWebView?
        var lastLoadedRequest: URL?
        var lastStatusRequest = 0
        var lastSaveRequest = 0
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
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if let requestedURL, context.coordinator.lastLoadedRequest != requestedURL {
            context.coordinator.lastLoadedRequest = requestedURL
            webView.load(URLRequest(url: requestedURL))
        } else if webView.url == nil {
            context.coordinator.lastLoadedRequest = url
            webView.load(URLRequest(url: url))
        }

        if context.coordinator.lastStatusRequest != statusRequest {
            context.coordinator.lastStatusRequest = statusRequest
            updateStatus(from: webView)
        }

        if context.coordinator.lastSaveRequest != saveRequest {
            context.coordinator.lastSaveRequest = saveRequest
            saveVisibleBilling(from: webView)
        }
    }

    private func updateStatus(from webView: WKWebView) {
        let currentURL = webView.url?.absoluteString ?? "about:blank"
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let sharedCookies = SakanaConsoleSession.sharedStorageCookies()
            let relevant = SakanaConsoleSession.relevantCookies(from: SakanaConsoleSession.deduplicate(cookies + sharedCookies))
            let names = relevant.map(\.name).sorted().joined(separator: ", ")
            let cookieText = relevant.isEmpty ? "无 Sakana cookie" : "\(relevant.count) 个 Sakana cookie: \(names)"
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                let parsed = (value as? String).flatMap(SakanaUsage.parseConsoleBilling)
                let parseText = parsed.map { "可解析：\($0.primaryText)，\($0.secondaryText ?? "Weekly 已读取")" } ?? "未解析到页面用量"
                DispatchQueue.main.async {
                    statusText = "当前页：\(currentURL)；WebKit \(cookies.count)，共享 \(sharedCookies.count)；\(cookieText)；\(parseText)"
                }
            }
        }
    }

    private func saveVisibleBilling(from webView: WKWebView) {
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, error in
            let text = value as? String ?? ""
            DispatchQueue.main.async {
                if let error {
                    statusText = "读取页面失败：\(error.localizedDescription)"
                    return
                }
                guard let usage = SakanaUsage.parseConsoleBilling(text) else {
                    statusText = "没能从当前页面解析到用量，请确认 Billing 页已经显示 Usage limit。"
                    return
                }
                SakanaUsageCache.save(usage)
                statusText = "已保存：\(usage.primaryText)，\(usage.secondaryText ?? "Weekly 已读取")"
                onFinish()
            }
        }
    }
}
