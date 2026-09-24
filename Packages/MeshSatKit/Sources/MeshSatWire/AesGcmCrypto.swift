// Mirrors crypto/AesGcmCrypto.kt: AES-256-GCM as the Bridge's transform pipeline and the Hub
// expect it. Wire format [12-byte nonce][ciphertext + 16-byte tag]; base64 of that on text
// channels (SMS). The 64-hex-character key is shared between the Bridge and the apps.
import Crypto
import Foundation

public enum AesGcmCrypto {
    public static let nonceSize = 12
    public static let tagSize = 16

    public struct KeyError: Error, CustomStringConvertible {
        public let description: String
    }

    /// A random 256-bit key as 64 lower-case hex characters.
    public static func generateKey() -> String {
        Hex.encode(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    static func key(_ hexKey: String) throws -> SymmetricKey {
        guard let bytes = Hex.decode(hexKey), bytes.count == 32 else {
            throw KeyError(description: "Key must be 32 bytes (64 hex chars), got \(Hex.decode(hexKey)?.count ?? -1)")
        }
        return SymmetricKey(data: bytes)
    }

    /// [nonce][ciphertext + tag].
    public static func encrypt(_ plaintext: [UInt8], hexKey: String) throws -> [UInt8] {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: try key(hexKey), nonce: nonce)
        return Array(nonce) + Array(sealed.ciphertext) + Array(sealed.tag)
    }

    public static func decrypt(_ data: [UInt8], hexKey: String) throws -> [UInt8] {
        guard data.count > nonceSize + tagSize else { throw KeyError(description: "Data too short for AES-GCM") }
        let nonce = try AES.GCM.Nonce(data: data[0..<nonceSize])
        let body = data[nonceSize...]
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: body.dropLast(tagSize), tag: body.suffix(tagSize))
        return Array(try AES.GCM.open(box, using: try key(hexKey)))
    }

    /// Base64 of the wire format, for SMS.
    public static func encryptToBase64(_ plaintext: String, hexKey: String) throws -> String {
        Base64Std.encode(try encrypt(Array(plaintext.utf8), hexKey: hexKey))
    }

    public static func decryptFromBase64(_ base64Text: String, hexKey: String) throws -> String {
        guard let data = Base64Std.decode(base64Text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw KeyError(description: "Not base64")
        }
        return String(decoding: try decrypt(data, hexKey: hexKey), as: UTF8.self)
    }

    /// Looks like a MeshSat encrypted message: base64 holding at least a nonce and a tag.
    public static func looksEncrypted(_ text: String) -> Bool {
        guard text.count >= 24, let decoded = Base64Std.decode(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return decoded.count > nonceSize + tagSize
    }

    /// 64 hex characters, either case.
    public static func isValidHexKey(_ s: String) -> Bool { s.count == 64 && s.allSatisfy { $0.isHexDigit } }
}
