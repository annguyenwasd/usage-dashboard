import Foundation

@main
struct SelfTest {
    static func main() async throws {
        try await assertMenuBarLabel()
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

    // the bar must headline the binding window: with the week exhausted, "5h 100%" is unusable quota
    private static func assertMenuBarLabel() async throws {
        func label(weekRemaining: Double, fiveHourRemaining: Double) async -> String {
            let week = QuotaWindow(id: "week", label: "Weekly window", used: 60000 - weekRemaining, total: 60000, remaining: weekRemaining, resetsAt: nil)
            let fiveHour = QuotaWindow(id: "5h", label: "5-hour window", used: 12000 - fiveHourRemaining, total: 12000, remaining: fiveHourRemaining, resetsAt: nil)
            let snapshot = Snapshot(
                zcode: .loaded(ZCodeQuota(level: "pro", fiveHour: fiveHour, week: week)),
                startPlan: .idle,
                deepseek: .idle,
                updatedAt: nil
            )
            return await MainActor.run {
                UsageStore(snapshot: snapshot).menuBarLabel
            }
        }
        let exhausted = await label(weekRemaining: 0, fiveHourRemaining: 12000)
        guard exhausted == "⚠ wk 0%" else {
            throw QuotaError(message: "exhausted week must headline '⚠ wk 0%', got '\(exhausted)'")
        }
        let healthy = await label(weekRemaining: 30000, fiveHourRemaining: 6000)
        guard healthy == "5h 50%" else {
            throw QuotaError(message: "healthy plan must headline the 5h window, got '\(healthy)'")
        }
        print("menuBarLabel ok: '\(exhausted)' / '\(healthy)'")
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
