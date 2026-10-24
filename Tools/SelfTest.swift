import Foundation

@main
struct SelfTest {
    static func main() async throws {
        try await assertMenuBarLabel()
        try assertModelUsageParsing()
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

        var jev: [String: Any]
        do {
            jev = ["balanceUSD": try await JevService.fetchBalance()]
        } catch {
            jev = ["error": error.localizedDescription]
        }

        let output: [String: Any] = ["zcode": zcode, "startPlan": startPlan, "deepseek": deepseek, "jev": jev]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) else {
            FileHandle.standardError.write(Data("Could not encode results\n".utf8))
            exit(1)
        }
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    // the bar must headline the binding window: with the week exhausted, "5h 100%" is unusable quota
    private static func assertMenuBarLabel() async throws {
        func label(weekRemaining: Double, fiveHourRemaining: Double, startPools: Bool = false, deepseek: Loadable<DeepSeekUsage> = .idle, jev: Loadable<Double> = .idle) async -> String {
            let week = QuotaWindow(id: "week", label: "Weekly window", used: 60000 - weekRemaining, total: 60000, remaining: weekRemaining, resetsAt: nil)
            let fiveHour = QuotaWindow(id: "5h", label: "5-hour window", used: 12000 - fiveHourRemaining, total: 12000, remaining: fiveHourRemaining, resetsAt: nil)
            let pools: Loadable<StartPlanQuota> = startPools
                ? .loaded(StartPlanQuota(planName: "P", windows: [
                    QuotaWindow(id: "a", label: "GLM-5.3-Flash", used: 10, total: 100, remaining: 90, resetsAt: nil, expires: true),
                    QuotaWindow(id: "b", label: "GLM-4.7-Air", used: 0, total: 100, remaining: 100, resetsAt: nil, expires: true)
                ]))
                : .idle
            let snapshot = Snapshot(
                zcode: .loaded(ZCodeQuota(level: "pro", fiveHour: fiveHour, week: week)),
                startPlan: pools,
                deepseek: deepseek,
                jev: jev,
                updatedAt: nil
            )
            return await MainActor.run {
                UsageStore(snapshot: snapshot).menuBarLabel
            }
        }
        let exhausted = await label(weekRemaining: 0, fiveHourRemaining: 12000)
        guard exhausted == "⚠ P wk 0% · 5h 100%" else {
            throw QuotaError(message: "exhausted week must headline '⚠ P wk 0% · 5h 100%', got '\(exhausted)'")
        }
        let healthy = await label(weekRemaining: 30000, fiveHourRemaining: 6000)
        guard healthy == "P 5h 50% · wk 50%" else {
            throw QuotaError(message: "healthy plan must lead with the 5h window, got '\(healthy)'")
        }
        let perModel = await label(weekRemaining: 30000, fiveHourRemaining: 6000, startPools: true)
        guard perModel == "P 5h 50% · wk 50% │ S 5.3-Flash 90% · 4.7-Air 100%" else {
            throw QuotaError(message: "start plan pools must be tagged S and list per-model percents, got '\(perModel)'")
        }
        let balances = await label(
            weekRemaining: 30000, fiveHourRemaining: 6000, startPools: true,
            deepseek: .loaded(DeepSeekUsage(balanceUSD: 12.34, todayTokens: 0, last5hTokens: 0, weekTokens: 0, todayRequests: 0, weekRequests: 0, localUsageError: nil)),
            jev: .loaded(1.28)
        )
        guard balances == "P 5h 50% · wk 50% │ S 5.3-Flash 90% · 4.7-Air 100% │ DS $12.34 · Jev $1.28" else {
            throw QuotaError(message: "balances must be tagged DS and Jev, got '\(balances)'")
        }
        print("menuBarLabel ok: '\(exhausted)' / '\(healthy)' / '\(perModel)' / '\(balances)'")
    }

    private static func assertModelUsageParsing() throws {
        let sample = #"{"code":200,"data":{"modelSummaryList":[{"modelName":"GLM-5.3","totalTokens":300,"sortOrder":1},{"modelName":"GLM-5.3-Flash","totalTokens":100,"sortOrder":2},{"modelName":"empty","totalTokens":0,"sortOrder":3}]}}"#
        let models = try ZCodeQuotaService.parseModels(Data(sample.utf8))
        guard models.map(\.name) == ["GLM-5.3", "GLM-5.3-Flash"], models[0].tokens == 300, abs(models[0].share - 0.75) < 0.001 else {
            throw QuotaError(message: "model usage parse wrong: \(models)")
        }
        print("model usage parse ok: \(models.map { "\($0.name)=\($0.tokens)" })")
    }

    private static func windowJSON(_ window: QuotaWindow) -> [String: Any] {
        var object: [String: Any] = [
            "label": window.label,
            "used": window.used,
            "total": window.total,
            "remaining": window.remaining
        ]
        if !window.models.isEmpty {
            object["models"] = window.models.map { ["name": $0.name, "tokens": $0.tokens, "share": $0.share] }
        }
        if let resetsAt = window.resetsAt {
            object[window.expires ? "expiresAt" : "resetsAt"] = ISO8601DateFormatter().string(from: resetsAt)
        }
        return object
    }
}
