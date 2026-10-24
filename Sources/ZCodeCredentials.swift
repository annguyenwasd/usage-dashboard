import Foundation
import CryptoKit

enum ZCodeCredentials {
    static func token(_ key: String) throws -> String {
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
              let encrypted = root[key] as? String else {
            throw QuotaError(message: "Credentials file has no \(key)")
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
