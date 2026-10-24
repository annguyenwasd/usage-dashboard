import Foundation

enum JevService {
    private struct Usage: Decodable {
        let creditsRemainingUsd: Double?

        enum CodingKeys: String, CodingKey {
            case creditsRemainingUsd = "credits_remaining_usd"
        }
    }

    private struct Payload: Decodable {
        let usage: Usage?
    }

    // the decide call is the only documented source of the prepaid balance, so each poll is a tiny billed request
    static func fetchBalance() async throws -> Double {
        let key = try readKey()
        guard let url = URL(string: "https://jevtypesafeai.com/api/v1/decide") else {
            throw QuotaError(message: "Invalid Jev URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = Data(#"{"state":"ping","questions":{"g":{"type":"noul","instructions":"0"}}}"#.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QuotaError(message: "Jev request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError(message: "Jev request returned no HTTP response")
        }
        if http.statusCode == 402 {
            throw QuotaError(message: "Jev balance is empty — top up at jevtypesafeai.com/pricing")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw QuotaError(message: "Jev HTTP \(http.statusCode): \(body.prefix(200))")
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw QuotaError(message: "Unexpected Jev response: \(error.localizedDescription)")
        }
        guard let credits = payload.usage?.creditsRemainingUsd else {
            throw QuotaError(message: "Jev response is missing credits_remaining_usd")
        }
        return credits
    }

    private static func readKey() throws -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("workspace/secrets/.jev")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw QuotaError(message: "Missing Jev key at ~/workspace/secrets/.jev")
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw QuotaError(message: "Jev key file is empty")
        }
        return key
    }
}
