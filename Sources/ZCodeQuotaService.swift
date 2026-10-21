import Foundation
import CryptoKit

enum ZCodeQuotaService {
    struct QuotaError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

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
        let token = try accessToken()
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

    private static func accessToken() throws -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/v2/credentials.json")
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw QuotaError(message: "Cannot read credentials at \(url.path)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let encrypted = root["oauth:zai:access_token"] as? String else {
            throw QuotaError(message: "Credentials file has no oauth:zai:access_token")
        }
        return try decrypt(encrypted)
    }

    // shortcut: this enc:v1 layout is ZCode's internal format; decryption breaks if ZCode changes it.
    private static func decrypt(_ value: String) throws -> String {
        let prefix = "enc:v1:"
        guard value.hasPrefix(prefix) else {
            throw QuotaError(message: "Unsupported credential format")
        }
        let parts = value.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let nonce = base64url(String(parts[0])),
              let tag = base64url(String(parts[1])),
              let ciphertext = base64url(String(parts[2])) else {
            throw QuotaError(message: "Malformed encrypted credential")
        }

        let secret = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]
            ?? "zcode-credential-fallback:darwin:\(FileManager.default.homeDirectoryForCurrentUser.path):\(NSUserName())"
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))

        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(box, using: key)
            guard let token = String(data: plaintext, encoding: .utf8) else {
                throw QuotaError(message: "Decrypted credential is not UTF-8")
            }
            return token
        } catch {
            throw QuotaError(message: "Credential decryption failed")
        }
    }

    private static func base64url(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
