import Foundation

// Shared value types for the native quota pipeline: the usage-window sample,
// per-account failures, the aggregate load report, and credential write-back
// errors.

struct NativeWindow: Sendable {
    var usedPercent: Double
    var resetsAt: Date?
}

/// Decodes a nested value leniently: if the wrapped type fails to decode
/// (missing/malformed fields), `.value` is nil instead of failing the whole
/// parent. This lets a partial API response surface whatever windows it has.
struct LenientValue<Wrapped: Decodable & Sendable>: Decodable, Sendable {
    var value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }

    init(value: Wrapped?) {
        self.value = value
    }
}

struct NativeQuotaFailure: Sendable, Equatable {
    var identity: QuotaAccountIdentity
    var serviceName: String
    var accountName: String
    var message: String
}

struct NativeQuotaLoadReport: Sendable {
    var successes: [QuotaSnapshot]
    var failures: [NativeQuotaFailure]
    /// Sources that actually contained a credential/session/cache. An absent
    /// optional integration (such as an unlogged-in Sakana Console) is not one.
    var credentialCount: Int
    var globalErrors: [String] = []
    /// Imported metadata that resolves to an already-loaded local credential.
    /// Settings keeps these visible as removable duplicates, not failures.
    var linkedImportedAccountKeys: Set<String> = []
}

enum NativeCredentialPersistenceError: LocalizedError {
    case readFile(label: String, path: String, reason: String)
    case invalidFile(label: String, path: String)
    case encode(label: String, reason: String)
    case writeFile(label: String, path: String, reason: String)
    case credentialsChanged(label: String)
    case readKeychain(label: String)

    var errorDescription: String? {
        switch self {
        case .readFile(let label, let path, let reason):
            return "读取\(label)凭据失败（\(path)）：\(reason)"
        case .invalidFile(let label, let path):
            return "\(label)凭据格式无效（\(path)）"
        case .encode(let label, let reason):
            return "编码\(label)凭据失败：\(reason)"
        case .writeFile(let label, let path, let reason):
            return "写入\(label)凭据失败（\(path)）：\(reason)"
        case .credentialsChanged(let label):
            return "\(label)凭据已由其他进程更新，未覆盖较新的凭据"
        case .readKeychain(let label):
            return "读取\(label)钥匙串凭据失败"
        }
    }
}
