import Foundation

@main
struct SelfTest {
    static func main() async {
        let quota: ZCodeQuota
        do {
            quota = try await ZCodeQuotaService.fetchQuota()
        } catch {
            FileHandle.standardError.write(Data("Z.ai quota failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }

        let zcode: [String: Any] = [
            "level": quota.level,
            "fiveHour": windowJSON(quota.fiveHour),
            "week": windowJSON(quota.week)
        ]

        var deepseek: [String: Any]
        switch await DeepSeekService.fetch() {
        case .loaded(let usage):
            var object: [String: Any] = [
                "balanceUSD": usage.balanceUSD,
                "todayTokens": usage.todayTokens,
                "last5hTokens": usage.last5hTokens,
                "weekTokens": usage.weekTokens,
                "todayRequests": usage.todayRequests,
                "weekRequests": usage.weekRequests
            ]
            if let localError = usage.localUsageError {
                object["localUsageError"] = localError
            }
            deepseek = object
        case .failed(let message):
            deepseek = ["error": message]
        case .idle, .loading:
            deepseek = ["error": "not loaded"]
        }

        var startPlan: [String: Any]
        do {
            let plan = try await StartPlanService.fetchBalance()
            startPlan = [
                "planName": plan.planName,
                "balances": plan.windows.map(windowJSON)
            ]
        } catch {
            startPlan = ["error": error.localizedDescription]
        }

        let output: [String: Any] = ["zcode": zcode, "startPlan": startPlan, "deepseek": deepseek]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) else {
            FileHandle.standardError.write(Data("Could not encode results\n".utf8))
            exit(1)
        }
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func windowJSON(_ window: QuotaWindow) -> [String: Any] {
        var object: [String: Any] = [
            "label": window.label,
            "used": window.used,
            "total": window.total,
            "remaining": window.remaining
        ]
        if let resetsAt = window.resetsAt {
            object[window.expires ? "expiresAt" : "resetsAt"] = ISO8601DateFormatter().string(from: resetsAt)
        }
        return object
    }
}
