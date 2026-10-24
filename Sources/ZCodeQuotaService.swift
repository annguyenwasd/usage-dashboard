import Foundation

enum ZCodeQuotaService {
    private struct Limit: Decodable {
        let number: Int
        let usage: Double
        let currentValue: Double
        let remaining: Double
        let nextResetTime: Double?
    }

    private struct Payload: Decodable {
        let limits: [Limit]
        let level: String?
    }

    private struct Envelope: Decodable {
        let data: Payload
    }

    static func fetchQuota() async throws -> ZCodeQuota {
        let token = try ZCodeCredentials.token("oauth:zai:access_token")
        guard let url = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit") else {
            throw QuotaError(message: "Invalid quota URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QuotaError(message: "Quota request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError(message: "Quota request returned no HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw QuotaError(message: "Quota HTTP \(http.statusCode): \(body.prefix(200))")
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw QuotaError(message: "Unexpected quota response: \(error.localizedDescription)")
        }
        guard let fiveHour = envelope.data.limits.first(where: { $0.number == 5 }),
              let week = envelope.data.limits.first(where: { $0.number == 1 }) else {
            throw QuotaError(message: "Quota response is missing a 5-hour or weekly window")
        }
        let fiveHourWindow = window(fiveHour, id: "5h", label: "5-hour window")
        let weekWindow = window(week, id: "week", label: "Weekly window")
        async let fiveHourModels = fetchModels(token: token, start: Date().addingTimeInterval(-5 * 3600), end: Date())
        // the weekly window ends at its reset time and spans the 7 days before it
        let weekEnd = weekWindow.resetsAt ?? Date()
        async let weekModels = fetchModels(token: token, start: weekEnd.addingTimeInterval(-7 * 24 * 3600), end: weekEnd)
        return ZCodeQuota(
            level: envelope.data.level ?? "unknown",
            fiveHour: fiveHourWindow.withModels(await fiveHourModels ?? []),
            week: weekWindow.withModels(await weekModels ?? [])
        )
    }

    // per-model split is hour-bucketed server-side, so a window range is only accurate to the hour
    private static func fetchModels(token: String, start: Date, end: Date) async -> [ModelUsage]? {
        guard var components = URLComponents(url: URL(string: "https://api.z.ai/api/monitor/usage/model-usage")!, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "startTime", value: rangeFormatter.string(from: start)),
            URLQueryItem(name: "endTime", value: rangeFormatter.string(from: end))
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return nil
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? parseModels(data)
    }

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parseModels(_ data: Data) throws -> [ModelUsage] {
        struct Summary: Decodable {
            let modelName: String
            let totalTokens: Double
        }
        struct Total: Decodable {
            let modelSummaryList: [Summary]?
        }
        struct Payload: Decodable {
            let modelSummaryList: [Summary]?
            let totalUsage: Total?
        }
        struct Envelope: Decodable {
            let code: Int?
            let data: Payload?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.code == nil || envelope.code == 200 else {
            throw QuotaError(message: "Model usage HTTP code \(envelope.code ?? -1)")
        }
        let summaries = envelope.data?.totalUsage?.modelSummaryList ?? envelope.data?.modelSummaryList ?? []
        let total = summaries.reduce(0.0) { $0 + $1.totalTokens }
        return summaries
            .filter { $0.totalTokens > 0 }
            .sorted { $0.totalTokens > $1.totalTokens }
            .map { ModelUsage(name: $0.modelName, tokens: Int($0.totalTokens), share: total > 0 ? $0.totalTokens / total : 0) }
    }

    private static func window(_ limit: Limit, id: String, label: String) -> QuotaWindow {
        QuotaWindow(
            id: id,
            label: label,
            used: limit.currentValue,
            total: limit.usage,
            remaining: max(limit.remaining, 0),
            resetsAt: limit.nextResetTime.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }
}
