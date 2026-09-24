// Mirrors reticulum/RnsAnnounce.kt: the DATA portion of an ANNOUNCE packet.
//
//   [0:64]    public_key (X25519 encryption 32B + Ed25519 signing 32B)
//   [64:74]   name_hash (10 bytes)
//   [74:84]   random_hash (10 bytes: 5 random + 5 timestamp)
//   [84:148]  signature (Ed25519, 64 bytes) over the hash material
//   [148..]   app_data (optional)
// With a ratchet, ratchet_public_key_id (10 bytes) sits before the signature.
import Crypto
import Foundation
import MeshSatCrypto

public struct RnsAnnounce: Sendable, Equatable {
    public static let randomHashLen = 10
    /// Full identity length: encryption key (32) + signing key (32).
    public static let identityLen = RnsConstants.pubKeyLen * 2
    /// Minimum announce data size (no ratchet, no app data): 64 + 10 + 10 + 64 = 148.
    public static let minSize = identityLen + RnsConstants.nameHashLen + randomHashLen + RnsConstants.sigLen

    public var encryptionPub: [UInt8]  // 32 bytes (X25519)
    public var signingPub: [UInt8]  // 32 bytes (Ed25519)
    public var nameHash: [UInt8]  // 10 bytes
    public var randomHash: [UInt8]  // 10 bytes
    public var ratchetId: [UInt8]?  // 10 bytes, optional
    public var signature: [UInt8]  // 64 bytes
    public var appData: [UInt8]?

    public init(
        encryptionPub: [UInt8], signingPub: [UInt8], nameHash: [UInt8], randomHash: [UInt8], ratchetId: [UInt8]? = nil,
        signature: [UInt8], appData: [UInt8]? = nil
    ) {
        self.encryptionPub = encryptionPub
        self.signingPub = signingPub
        self.nameHash = nameHash
        self.randomHash = randomHash
        self.ratchetId = ratchetId
        self.signature = signature
        self.appData = appData
    }

    /// The announce data for RnsPacket.data.
    public func marshal() -> [UInt8] {
        var out = encryptionPub + signingPub + nameHash + randomHash
        if let ratchetId { out += ratchetId }
        out += signature
        if let appData { out += appData }
        return out
    }

    /// What is signed: dest_hash + encryption_pub + signing_pub + name_hash + random_hash
    /// [+ ratchet_id] [+ app_data]. The dest hash comes from the packet header.
    public func hashMaterial(destHash: [UInt8]) -> [UInt8] {
        var out = destHash + encryptionPub + signingPub + nameHash + randomHash
        if let ratchetId { out += ratchetId }
        if let appData { out += appData }
        return out
    }

    /// The signature and the destination hash's integrity against the keys.
    public func verify(destHash: [UInt8]) -> Bool {
        let identityHash = RnsDestination.identityHash(encryptionPub: encryptionPub, signingPub: signingPub)
        guard RnsDestination.truncatedHash(nameHash + identityHash) == destHash else { return false }
        return Identity.verifyWithRaw(signingPub, data: hashMaterial(destHash: destHash), signature: signature)
    }

    /// announce_hash = SHA-256(dest_hash + random_hash)[:16], for deduplication.
    public func announceHash(destHash: [UInt8]) -> [UInt8] { RnsDestination.truncatedHash(destHash + randomHash) }

    /// A signed announce and its destination hash. `now` is seconds since the epoch.
    public static func create(
        encryptionPub: [UInt8], signingPub: [UInt8], appName: String = RnsDestination.appName,
        aspects: [String] = [RnsDestination.aspectNode], appData: [UInt8]? = nil, now: Int64 = Int64(Date().timeIntervalSince1970),
        sign: ([UInt8]) -> [UInt8]
    ) -> (announce: RnsAnnounce, destHash: [UInt8]) {
        let nHash = RnsDestination.nameHash(appName, aspects: aspects)
        let destHash = RnsDestination.computeDestHash(
            encryptionPub: encryptionPub, signingPub: signingPub, appName: appName, aspects: aspects)
        // Random hash: 5 bytes random + 5 bytes timestamp
        let ts = UInt32(truncatingIfNeeded: now)
        var rHash = (0..<5).map { _ in UInt8.random(in: 0...255) }
        rHash += [UInt8((ts >> 24) & 0xFF), UInt8((ts >> 16) & 0xFF), UInt8((ts >> 8) & 0xFF), UInt8(ts & 0xFF), UInt8((ts >> 28) & 0x0F)]
        var announce = RnsAnnounce(
            encryptionPub: encryptionPub, signingPub: signingPub, nameHash: nHash, randomHash: rHash, ratchetId: nil, signature: [],
            appData: appData)
        announce.signature = sign(announce.hashMaterial(destHash: destHash))
        return (announce, destHash)
    }

    /// Parse announce data from a received packet's data field.
    public static func unmarshal(_ data: [UInt8], hasRatchet: Bool = false) throws -> RnsAnnounce {
        let minSize = hasRatchet ? minSize + RnsConstants.ratchetIdLen : minSize
        guard data.count >= minSize else { throw RnsPacket.FormatError("announce data too short: \(data.count) < \(minSize)") }
        var i = 0
        func take(_ n: Int) -> [UInt8] {
            defer { i += n }
            return Array(data[i..<i + n])
        }
        let encPub = take(RnsConstants.pubKeyLen)
        let sigPub = take(RnsConstants.pubKeyLen)
        let nHash = take(RnsConstants.nameHashLen)
        let rHash = take(randomHashLen)
        let ratchetId: [UInt8]? = hasRatchet ? take(RnsConstants.ratchetIdLen) : nil
        let sig = take(RnsConstants.sigLen)
        let appData: [UInt8]? = i < data.count ? Array(data[i...]) : nil
        return RnsAnnounce(
            encryptionPub: encPub, signingPub: sigPub, nameHash: nHash, randomHash: rHash, ratchetId: ratchetId, signature: sig,
            appData: appData)
    }
}

/// MeshSat's app_data for announces: device type and capability flags.
public enum MeshSatAppData {
    public static let deviceBridge: UInt8 = 0x01
    public static let deviceAndroid: UInt8 = 0x02
    public static let deviceHub: UInt8 = 0x03
    /// The iPhone announces as the phone app: the Bridge and the Hub know only three kinds.
    public static let deviceIos: UInt8 = deviceAndroid
    public static let capMesh: UInt8 = 0x01  // LoRa/Meshtastic
    public static let capSatellite: UInt8 = 0x02  // Iridium
    public static let capSms: UInt8 = 0x04  // native SMS
    public static let capAprs: UInt8 = 0x08  // AX.25/APRS
    public static let capMqtt: UInt8 = 0x10  // MQTT/internet
    /// Transport node capability flag.
    public static let capTransportNode: UInt8 = 0x20
    public static let minSize = 2

    public struct Decoded: Sendable, Equatable {
        public let deviceType: UInt8
        public let capabilities: UInt8
    }

    public static func encode(deviceType: UInt8, capabilities: UInt8) -> [UInt8] { [deviceType, capabilities] }

    public static func decode(_ data: [UInt8]) -> Decoded? {
        guard data.count >= minSize else { return nil }
        return Decoded(deviceType: data[0], capabilities: data[1])
    }
}
