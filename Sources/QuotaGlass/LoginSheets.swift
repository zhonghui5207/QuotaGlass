import SwiftUI
import AppKit

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
