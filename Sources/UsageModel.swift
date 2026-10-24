import Foundation

struct ModelUsage: Sendable, Identifiable {
    let name: String
    let tokens: Int
    let share: Double

    var id: String { name }
}

struct QuotaWindow: Sendable, Identifiable {
    let id: String
    let label: String
    let used: Double
    let total: Double
    let remaining: Double
    let resetsAt: Date?
    let expires: Bool
    var models: [ModelUsage] = []

    init(id: String, label: String, used: Double, total: Double, remaining: Double, resetsAt: Date?, expires: Bool = false, models: [ModelUsage] = []) {
        self.id = id
        self.label = label
        self.used = used
        self.total = total
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.expires = expires
        self.models = models
    }

    func withModels(_ models: [ModelUsage]) -> QuotaWindow {
        var copy = self
        copy.models = models
        return copy
    }

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

struct StartPlanQuota: Sendable {
    let planName: String
    let windows: [QuotaWindow]
}

struct QuotaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
    let startPlan: Loadable<StartPlanQuota>
    let deepseek: Loadable<DeepSeekUsage>
    let jev: Loadable<Double>
    let updatedAt: Date?
}
