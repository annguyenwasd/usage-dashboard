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
        return ZCodeQuota(
            level: envelope.data.level ?? "unknown",
            fiveHour: window(fiveHour, id: "5h", label: "5-hour window"),
            week: window(week, id: "week", label: "Weekly window")
        )
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
