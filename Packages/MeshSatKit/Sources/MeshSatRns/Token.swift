// Mirrors rns/Wire.kt (class Token), the Bridge's internal/reticulum/token.go:
// RNS.Cryptography.Token, a Fernet-style token without version and timestamp.
// iv(16) || AES-CBC(PKCS7(plaintext)) || HMAC-SHA256(iv || ciphertext)(32). A 64-byte key is
// AES-256 with signing key = key[:32] and encryption key = key[32:]; a 32-byte key is AES-128
// with 16-byte halves. The signing half comes FIRST. The cipher is MeshSatReticulum.AesCbc
// (CommonCrypto on the phone).
import Crypto
import Foundation
import MeshSatReticulum

public struct Token: Sendable {
    private let signingKey: [UInt8]
    private let encryptionKey: [UInt8]

    public init(key: [UInt8]) throws {
        switch key.count {
        case 32:
            signingKey = Array(key[0..<16])
            encryptionKey = Array(key[16..<32])
        case 64:
            signingKey = Array(key[0..<32])
            encryptionKey = Array(key[32..<64])
        default: throw WireError("token key must be 32 or 64 bytes, got \(key.count)")
        }
    }

    public func encrypt(_ data: [UInt8]) throws -> [UInt8] {
        let iv = Rns.randomBytes(Rns.aesBlock)
        let ct = try AesCbc.encrypt(data, key: encryptionKey, iv: iv)
        return iv + ct + mac(iv + ct)
    }

    public func verifyHmac(_ token: [UInt8]) -> Bool {
        guard token.count > 32 else { return false }
        let expected = mac(Array(token[0..<token.count - 32]))
        let given = Array(token[(token.count - 32)...])
        // Constant time: every byte is compared.
        var diff: UInt8 = 0
        for i in 0..<32 { diff |= expected[i] ^ given[i] }
        return diff == 0
    }

    /// Verifies the HMAC and decrypts, or throws WireError.
    public func decrypt(_ token: [UInt8]) throws -> [UInt8] {
        guard token.count >= Rns.aesBlock + Rns.aesBlock + 32 else { throw WireError("token too short (\(token.count) bytes)") }
        guard verifyHmac(token) else { throw WireError("token HMAC invalid") }
        let iv = Array(token[0..<Rns.aesBlock])
        let ct = Array(token[Rns.aesBlock..<token.count - 32])
        guard ct.count % Rns.aesBlock == 0 else { throw WireError("token ciphertext not block aligned") }
        do {
            return try AesCbc.decrypt(ct, key: encryptionKey, iv: iv)
        } catch {
            throw WireError("token padding invalid")
        }
    }

    private func mac(_ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: signingKey)))
    }
}
