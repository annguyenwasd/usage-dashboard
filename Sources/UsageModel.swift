import Foundation

struct QuotaWindow: Sendable, Identifiable {
    let id: String
    let label: String
    let used: Double
    let total: Double
    let remaining: Double
    let resetsAt: Date?

    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return min(max(used / total, 0), 1)
    }

    var remainingFraction: Double {
        guard total > 0 else { return 0 }
        return min(max(remaining / total, 0), 1)
    }
}

struct ZCodeQuota: Sendable {
    let level: String
    let fiveHour: QuotaWindow
    let week: QuotaWindow
}

struct DeepSeekUsage: Sendable {
    let balanceUSD: Double
    let todayTokens: Int
    let last5hTokens: Int
    let weekTokens: Int
    let todayRequests: Int
    let weekRequests: Int
    let localUsageError: String?
}

enum Loadable<T: Sendable>: Sendable {
    case idle
    case loading
    case loaded(T)
    case failed(String)
}

struct Snapshot: Sendable {
    let zcode: Loadable<ZCodeQuota>
    let deepseek: Loadable<DeepSeekUsage>
    let updatedAt: Date?
}
