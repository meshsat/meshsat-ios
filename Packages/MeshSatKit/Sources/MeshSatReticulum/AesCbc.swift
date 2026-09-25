// AES-256-CBC with PKCS#7 padding, the cipher of a Reticulum-compatible link (mode 0x00). On
// Apple platforms it is CommonCrypto, the operating system's own, so the app's export
// compliance declaration ("no non-exempt encryption": every cipher is Apple's) stays true; on
// Linux it is swift-crypto's _CryptoExtras (BoringSSL). Same bytes either way, pinned by
// AesCbcTests against an OpenSSL vector.
import Foundation

#if canImport(CommonCrypto)
import CommonCrypto
#else
import Crypto
import _CryptoExtras
#endif

public enum AesCbc {
    public struct CipherError: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public static func encrypt(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        try check(key: key, iv: iv)
        #if canImport(CommonCrypto)
        return try crypt(CCOperation(kCCEncrypt), plaintext, key: key, iv: iv)
        #else
        return Array(try AES._CBC.encrypt(plaintext, using: SymmetricKey(data: key), iv: AES._CBC.IV(ivBytes: iv)))
        #endif
    }

    public static func decrypt(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        try check(key: key, iv: iv)
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { throw CipherError("ciphertext is not whole blocks") }
        #if canImport(CommonCrypto)
        return try crypt(CCOperation(kCCDecrypt), ciphertext, key: key, iv: iv)
        #else
        return Array(try AES._CBC.decrypt(ciphertext, using: SymmetricKey(data: key), iv: AES._CBC.IV(ivBytes: iv)))
        #endif
    }

    private static func check(key: [UInt8], iv: [UInt8]) throws {
        guard key.count == 32 else { throw CipherError("key must be 32 bytes") }
        guard iv.count == 16 else { throw CipherError("iv must be 16 bytes") }
    }

    #if canImport(CommonCrypto)
    private static func crypt(_ op: CCOperation, _ input: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        let capacity = input.count + kCCBlockSizeAES128
        var out = [UInt8](repeating: 0, count: capacity)
        var moved = 0
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                input.withUnsafeBytes { i in
                    out.withUnsafeMutableBytes { o in
                        CCCrypt(
                            op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, v.baseAddress,
                            i.baseAddress, input.count, o.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CipherError("CommonCrypto status \(status)") }
        return Array(out.prefix(moved))
    }
    #endif
}
