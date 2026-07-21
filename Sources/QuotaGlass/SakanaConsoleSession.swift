import Foundation
import CryptoKit
import WebKit

enum SakanaConsoleSession {
    struct Session: Sendable {
        var cookieHeader: String
        var cacheKey: String
    }

    @MainActor
    static func session() async -> Session? {
        let wkCookies = await webKitCookies()
        let storageCookies = sharedStorageCookies()
        let relevant = cookies(
            for: SakanaUsage.billingEndpoint,
            from: deduplicate(storageCookies + wkCookies)
        )
        guard !relevant.isEmpty else { return nil }
        return Session(
            cookieHeader: cookieHeader(from: relevant),
            cacheKey: fingerprint(from: relevant)
        )
    }

    @MainActor
    static func webKitCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    static func sharedStorageCookies() -> [HTTPCookie] {
        HTTPCookieStorage.shared.cookies ?? []
    }

    static func relevantCookies(from cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { cookie in
            cookie.domain == "console.sakana.ai"
                || cookie.domain == ".console.sakana.ai"
                || cookie.domain == ".sakana.ai"
                || cookie.domain.hasSuffix(".sakana.ai")
        }
    }

    /// Apply the target URL's domain/path/secure/expiry rules before copying
    /// WebKit cookies into a URLSession header. This avoids widening a cookie's
    /// browser scope merely because it belongs to another Sakana subdomain.
    static func cookies(for url: URL, from cookies: [HTTPCookie], now: Date = Date()) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isHTTPS = url.scheme?.lowercased() == "https"

        return cookies.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            if cookie.isSecure && !isHTTPS { return false }

            let rawDomain = cookie.domain.lowercased()
            let domainMatches: Bool
            if rawDomain.hasPrefix(".") {
                let domain = String(rawDomain.dropFirst())
                domainMatches = host == domain || host.hasSuffix("." + domain)
            } else {
                domainMatches = host == rawDomain
            }
            guard domainMatches else { return false }

            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            if requestPath == cookiePath { return true }
            guard requestPath.hasPrefix(cookiePath) else { return false }
            if cookiePath.hasSuffix("/") { return true }
            let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
            return boundary < requestPath.endIndex && requestPath[boundary] == "/"
        }
    }

    static func cookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Hash cookie material into a non-secret cache namespace. The raw session
    /// value is never persisted, logged, or used as a SwiftUI identity.
    static func fingerprint(from cookies: [HTTPCookie]) -> String {
        let canonical = cookies
            .map { [
                $0.domain.lowercased(),
                $0.path,
                $0.name,
                $0.value,
            ].joined(separator: "\u{1F}") }
            .sorted()
            .joined(separator: "\u{1E}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func deduplicate(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        var seen: Set<String> = []
        var result: [HTTPCookie] = []
        for cookie in cookies.reversed() {
            let key = [cookie.domain.lowercased(), cookie.path, cookie.name].joined(separator: "\u{1F}")
            if seen.insert(key).inserted { result.append(cookie) }
        }
        return result.reversed()
    }
}
