// Mirrors reticulum/RnsHkdf.kt: HKDF per RFC 5869 on HMAC-SHA256, used by Reticulum for the
// symmetric link keys derived from ECDH shared secrets. Written out rather than taken from
// swift-crypto's HKDF so the byte order of extract and expand stays visibly Android's.
import Crypto
import Foundation

public enum RnsHkdf {
    static let hashLen = 32

    /// HKDF-Extract: PRK = HMAC-SHA256(salt, IKM). A nil salt is hashLen zero bytes.
    public static func extract(salt: [UInt8]?, ikm: [UInt8]) -> [UInt8] {
        let key = SymmetricKey(data: salt ?? [UInt8](repeating: 0, count: hashLen))
        return Array(HMAC<SHA256>.authenticationCode(for: ikm, using: key))
    }

    /// HKDF-Expand: OKM = T(1) || T(2) || ... || T(N) truncated to `length`.
    public static func expand(prk: [UInt8], info: [UInt8]?, length: Int) -> [UInt8] {
        precondition(length <= 255 * hashLen, "requested length too large")
        let key = SymmetricKey(data: prk)
        let n = (length + hashLen - 1) / hashLen
        var okm = [UInt8]()
        okm.reserveCapacity(n * hashLen)
        var prev = [UInt8]()
        for i in 1...max(n, 1) where n > 0 {
            var mac = HMAC<SHA256>(key: key)
            mac.update(data: prev)
            if let info { mac.update(data: info) }
            mac.update(data: [UInt8(i)])
            prev = Array(mac.finalize())
            okm += prev
        }
        return Array(okm.prefix(length))
    }

    /// Full HKDF: extract then expand.
    public static func derive(length: Int, from ikm: [UInt8], salt: [UInt8]? = nil, context: [UInt8]? = nil) -> [UInt8] {
        expand(prk: extract(salt: salt, ikm: ikm), info: context, length: length)
    }

    /// Send and receive AES-256 keys for a Reticulum link: 64 bytes of key material split in
    /// two. Initiator: first 32 = send, second 32 = recv. Responder: the other way round.
    public static func deriveLinkKeys(sharedSecret: [UInt8], salt: [UInt8], isInitiator: Bool) -> (send: [UInt8], recv: [UInt8]) {
        let material = derive(length: 64, from: sharedSecret, salt: salt)
        let key1 = Array(material[0..<32])
        let key2 = Array(material[32..<64])
        return isInitiator ? (key1, key2) : (key2, key1)
    }
}
