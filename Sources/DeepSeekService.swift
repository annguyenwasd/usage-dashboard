import Foundation

enum DeepSeekService {
    private struct BalanceResponse: Decodable {
        let balance_infos: [BalanceInfo]
    }

    private struct BalanceInfo: Decodable {
        let currency: String
        let total_balance: String
    }

    private struct LocalRow: Decodable {
        let todayTokens: Int
        let todayRequests: Int
        let last5hTokens: Int
        let weekTokens: Int
        let weekRequests: Int
    }

    struct DeepSeekError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func fetch() async -> Loadable<DeepSeekUsage> {
        do {
            let balance = try await fetchBalance()
            let usage = localUsage()
            return .loaded(DeepSeekUsage(
                balanceUSD: balance,
                todayTokens: usage?.todayTokens ?? 0,
                last5hTokens: usage?.last5hTokens ?? 0,
                weekTokens: usage?.weekTokens ?? 0,
                todayRequests: usage?.todayRequests ?? 0,
                weekRequests: usage?.weekRequests ?? 0,
                localUsageError: usage == nil ? "local usage unavailable" : nil
            ))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func fetchBalance() async throws -> Double {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            throw DeepSeekError(message: "Invalid balance URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try apiKey())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DeepSeekError(message: "Balance request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekError(message: "Balance request returned no HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeepSeekError(message: "Balance HTTP \(http.statusCode): \(body.prefix(200))")
        }

        let body: BalanceResponse
        do {
            body = try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            throw DeepSeekError(message: "Unexpected balance response: \(error.localizedDescription)")
        }
        guard let info = body.balance_infos.first(where: { $0.currency.uppercased() == "USD" })
                ?? body.balance_infos.first,
              let amount = Double(info.total_balance) else {
            throw DeepSeekError(message: "DeepSeek response has no usable balance")
        }
        return amount
    }

    private static func apiKey() throws -> String {
        let path = "/Users/annguyenvanchuc/workspace/secrets/.dsh"
        let raw: String
        do {
            raw = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw DeepSeekError(message: "Cannot read DeepSeek key at \(path)")
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw DeepSeekError(message: "DeepSeek key file is empty")
        }
        return key
    }

    private static func localUsage() -> LocalRow? {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/db/db.sqlite").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let midnight = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        let windows: [(name: String, since: Int64, countRequests: Bool)] = [
            ("today", midnight, true),
            ("last5h", now - 5 * 3600 * 1000, false),
            ("week", now - 7 * 24 * 3600 * 1000, true)
        ]
        let selects = windows.flatMap { window -> [String] in
            var parts = [
                "(SELECT COALESCE(SUM(input_tokens + output_tokens), 0) FROM model_usage WHERE provider_id='deepseek' AND status='completed' AND started_at >= \(window.since)) AS \(window.name)Tokens"
            ]
            if window.countRequests {
                parts.append("(SELECT COUNT(DISTINCT logical_request_id) FROM model_usage WHERE provider_id='deepseek' AND status='completed' AND started_at >= \(window.since)) AS \(window.name)Requests")
            }
            return parts
        }
        let sql = "SELECT " + selects.joined(separator: ", ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", dbPath, sql]
        let stdout = Pipe()
        process.standardOutput = stdout
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let rows = try? JSONDecoder().decode([LocalRow].self, from: output) else { return nil }
        return rows.first
    }
}
