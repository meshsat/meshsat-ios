// Mirrors reticulum/RnsLink.kt: a Reticulum-compatible cryptographic link between two nodes,
// and the handshake data carried inside RnsPacket.data. Link IDs are 16 bytes, keys come from
// HKDF, data is AES-256-GCM (MeshSat, preferred) or AES-256-CBC (Reticulum default).
import Crypto
import Foundation

public enum RnsLinkState: Sendable, Equatable {
    case pending  // request sent, waiting for proof
    case handshake  // proof received, confirming
    case active  // ECDH complete, symmetric keys derived
    case stale  // no activity for the stale time
    case closed  // explicitly closed or timed out
}

public enum RnsEncryptionMode: UInt8, Sendable, Equatable {
    case aes256Cbc = 0x00  // Reticulum default
    case aes256Gcm = 0x01  // MeshSat extension (preferred)

    public static func from(id: UInt8) -> RnsEncryptionMode { RnsEncryptionMode(rawValue: id) ?? .aes256Cbc }
}

public final class RnsLink: @unchecked Sendable {
    public static let linkIdLen = RnsConstants.destHashLen
    static let gcmNonceSize = 12
    static let cbcIvSize = 16

    public struct LinkError: Error, Equatable, Sendable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public let id: [UInt8]  // 16 bytes (truncated hash of the link request)
    public let destHash: [UInt8]  // 16 bytes (remote destination)
    public let encryptionMode: RnsEncryptionMode
    public let sharedSecret: [UInt8]?
    public let sendKey: [UInt8]?
    public let recvKey: [UInt8]?
    public let createdAt: Int64
    public let isInitiator: Bool
    private let lock = NSLock()
    private var stateValue: RnsLinkState
    private var sendNonce: UInt64 = 0
    private var recvNonce: UInt64 = 0
    private var lastActivityValue: Int64

    public init(
        id: [UInt8], destHash: [UInt8], state: RnsLinkState, encryptionMode: RnsEncryptionMode = .aes256Gcm,
        sharedSecret: [UInt8]? = nil, sendKey: [UInt8]? = nil, recvKey: [UInt8]? = nil, isInitiator: Bool,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.id = id
        self.destHash = destHash
        self.stateValue = state
        self.encryptionMode = encryptionMode
        self.sharedSecret = sharedSecret
        self.sendKey = sendKey
        self.recvKey = recvKey
        self.isInitiator = isInitiator
        self.createdAt = nowMs
        self.lastActivityValue = nowMs
    }

    public var state: RnsLinkState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stateValue
        }
        set {
            lock.lock()
            stateValue = newValue
            lock.unlock()
        }
    }

    public var lastActivity: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return lastActivityValue
        }
        set {
            lock.lock()
            lastActivityValue = newValue
            lock.unlock()
        }
    }

    public var idHex: String { id.map { String(format: "%02x", $0) }.joined() }

    /// Encrypt with the link's send key.
    public func encrypt(_ plaintext: [UInt8]) throws -> [UInt8] {
        guard state == .active, let sendKey else { throw LinkError("link not active") }
        switch encryptionMode {
        case .aes256Gcm:
            let nonce = nextSendNonce()
            let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: sendKey), nonce: AES.GCM.Nonce(data: nonce))
            return nonce + Array(sealed.ciphertext) + Array(sealed.tag)
        case .aes256Cbc:
            let iv = (0..<Self.cbcIvSize).map { _ in UInt8.random(in: 0...255) }
            return iv + (try AesCbc.encrypt(plaintext, key: sendKey, iv: iv))
        }
    }

    /// Decrypt with the link's receive key.
    public func decrypt(_ data: [UInt8]) throws -> [UInt8] {
        guard state == .active, let recvKey else { throw LinkError("link not active") }
        switch encryptionMode {
        case .aes256Gcm:
            guard data.count > Self.gcmNonceSize + 16 else { throw LinkError("ciphertext too short") }
            let nonce = Array(data[0..<Self.gcmNonceSize])
            let body = Array(data[Self.gcmNonceSize...])
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: body.dropLast(16), tag: body.suffix(16))
            noteRecv()
            return Array(try AES.GCM.open(box, using: SymmetricKey(data: recvKey)))
        case .aes256Cbc:
            guard data.count > Self.cbcIvSize else { throw LinkError("ciphertext too short") }
            let iv = Array(data[0..<Self.cbcIvSize])
            return try AesCbc.decrypt(Array(data[Self.cbcIvSize...]), key: recvKey, iv: iv)
        }
    }

    /// The 12-byte GCM nonce: the send counter, big-endian, in the last 8 bytes (Android's putLong).
    private func nextSendNonce() -> [UInt8] {
        lock.lock()
        let n = sendNonce
        sendNonce += 1
        lock.unlock()
        var nonce = [UInt8](repeating: 0, count: Self.gcmNonceSize)
        for i in 0..<8 { nonce[i] = UInt8((n >> (56 - 8 * UInt64(i))) & 0xFF) }
        return nonce
    }

    private func noteRecv() {
        lock.lock()
        recvNonce += 1
        lock.unlock()
    }
}

/// Signalling bytes for link establishment (3 bytes): mtu (uint16 big-endian, 0 = default) and
/// the encryption mode.
public struct RnsSignalling: Sendable, Equatable {
    public static let size = 3
    public var mtu: Int
    public var encryptionMode: RnsEncryptionMode

    public init(mtu: Int = RnsConstants.mtu, encryptionMode: RnsEncryptionMode = .aes256Gcm) {
        self.mtu = mtu
        self.encryptionMode = encryptionMode
    }

    public func marshal() -> [UInt8] { [UInt8((mtu >> 8) & 0xFF), UInt8(mtu & 0xFF), encryptionMode.rawValue] }

    public static func unmarshal(_ data: [UInt8], offset: Int = 0) throws -> RnsSignalling {
        guard data.count >= offset + size else { throw RnsPacket.FormatError("signalling too short") }
        let mtu = Int(data[offset]) << 8 | Int(data[offset + 1])
        return RnsSignalling(mtu: mtu == 0 ? RnsConstants.mtu : mtu, encryptionMode: .from(id: data[offset + 2]))
    }
}

/// Link request data (67 bytes) inside RnsPacket(type=LINKREQUEST, dest=target):
/// X25519 ephemeral public key, Ed25519 signing public key, signalling.
public struct RnsLinkRequest: Sendable, Equatable {
    public static let size = RnsConstants.pubKeyLen * 2 + RnsSignalling.size  // 67
    public var ephemeralPub: [UInt8]
    public var signingPub: [UInt8]
    public var signalling: RnsSignalling

    public init(ephemeralPub: [UInt8], signingPub: [UInt8], signalling: RnsSignalling) {
        self.ephemeralPub = ephemeralPub
        self.signingPub = signingPub
        self.signalling = signalling
    }

    public func marshal() -> [UInt8] { ephemeralPub + signingPub + signalling.marshal() }

    public static func unmarshal(_ data: [UInt8]) throws -> RnsLinkRequest {
        guard data.count >= size else { throw RnsPacket.FormatError("link request data too short: \(data.count) < \(size)") }
        let k = RnsConstants.pubKeyLen
        return RnsLinkRequest(
            ephemeralPub: Array(data[0..<k]), signingPub: Array(data[k..<2 * k]),
            signalling: try RnsSignalling.unmarshal(data, offset: 2 * k))
    }
}

/// Link proof data (99 bytes) inside RnsPacket(type=PROOF, dest=link_id): Ed25519 signature
/// over link_id + pub + sig_pub + signalling, the responder's X25519 ephemeral key, signalling.
public struct RnsLinkProof: Sendable, Equatable {
    public static let size = RnsConstants.sigLen + RnsConstants.pubKeyLen + RnsSignalling.size  // 99
    public var signature: [UInt8]
    public var ephemeralPub: [UInt8]
    public var signalling: RnsSignalling

    public init(signature: [UInt8], ephemeralPub: [UInt8], signalling: RnsSignalling) {
        self.signature = signature
        self.ephemeralPub = ephemeralPub
        self.signalling = signalling
    }

    public func marshal() -> [UInt8] { signature + ephemeralPub + signalling.marshal() }

    public static func unmarshal(_ data: [UInt8]) throws -> RnsLinkProof {
        guard data.count >= size else { throw RnsPacket.FormatError("link proof data too short: \(data.count) < \(size)") }
        let s = RnsConstants.sigLen
        let k = RnsConstants.pubKeyLen
        return RnsLinkProof(
            signature: Array(data[0..<s]), ephemeralPub: Array(data[s..<s + k]),
            signalling: try RnsSignalling.unmarshal(data, offset: s + k))
    }
}
