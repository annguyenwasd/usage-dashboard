import Foundation

enum StartPlanService {
    // shortcut: app_version pinned to the installed ZCode; breaks on ZCode updates.
    private static let appVersion = "3.16.3"

    private struct Plan: Decodable {
        let name: String?
        let status: String?
    }

    private struct Balance: Decodable {
        let entitlementID: String
        let showName: String
        let totalUnits: Double
        let usedUnits: Double
        let remainingUnits: Double
        let expiresAt: Double?

        enum CodingKeys: String, CodingKey {
            case entitlementID = "entitlement_id"
            case showName = "show_name"
            case totalUnits = "total_units"
            case usedUnits = "used_units"
            case remainingUnits = "remaining_units"
            case expiresAt = "expires_at"
        }
    }

    private struct Payload: Decodable {
        let plans: [Plan]?
        let balances: [Balance]?
    }

    private struct Envelope: Decodable {
        let code: Int
        let data: Payload?
    }

    // shortcut: the balance endpoint rejects requests without ZCode client headers; breaks if ZCode changes them.
    static func fetchBalance() async throws -> StartPlanQuota {
        let token = try ZCodeCredentials.token("zcodejwttoken")
        guard let url = URL(string: "https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=\(appVersion)") else {
            throw QuotaError(message: "Invalid Start Plan URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ZCode/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue(appVersion, forHTTPHeaderField: "X-ZCode-App-Version")
        request.setValue("macos", forHTTPHeaderField: "X-Os-Category")
        if let deviceMid = deviceMid() {
            request.setValue(deviceMid, forHTTPHeaderField: "X-Device-Mid")
        }
        request.setValue("en", forHTTPHeaderField: "X-Client-Language")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Client-Timezone")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QuotaError(message: "Start Plan request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError(message: "Start Plan request returned no HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw QuotaError(message: "Start Plan HTTP \(http.statusCode): \(body.prefix(200))")
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw QuotaError(message: "Unexpected Start Plan response: \(error.localizedDescription)")
        }
        guard envelope.code == 0, let balances = envelope.data?.balances, !balances.isEmpty else {
            throw QuotaError(message: "No active Start Plan balance")
        }
        let planName = envelope.data?.plans?
            .first(where: { $0.status?.trimmingCharacters(in: .whitespaces).lowercased() == "active" })?
            .name ?? "Start Plan"
        return StartPlanQuota(
            planName: planName,
            windows: balances.map { balance in
                QuotaWindow(
                    id: balance.entitlementID,
                    label: balance.showName,
                    used: balance.usedUnits,
                    total: balance.totalUnits,
                    remaining: max(balance.remainingUnits, 0),
                    resetsAt: balance.expiresAt.map { Date(timeIntervalSince1970: $0) },
                    expires: true
                )
            }
        )
    }

    private static func deviceMid() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/v2/onboarding-record.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let mid = root["deviceMid"] as? String else { return nil }
        return mid
    }
}
