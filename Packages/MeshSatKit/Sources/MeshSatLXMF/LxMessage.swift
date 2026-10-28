// Mirrors lxmf/LxMessage.kt (the Bridge's internal/lxmf/message.go): one LXMF message
// (LXMF/LXMessage.py, 1.2.x). Packed form:
//   dest (16) || source (16) || signature (64) || msgpack([timestamp, title, content, fields, [stamp]])
// The hash is SHA-256(dest || source || msgpack([timestamp, title, content, fields])); the
// signature covers that hashed part plus the hash.
import Crypto
import Foundation
import MeshSatRns
import MeshSatWire

/// How a message travels (LXMessage.OPPORTUNISTIC / DIRECT / PROPAGATED).
public enum LxMethod: Int, Sendable, Equatable {
    case opportunistic = 1
    case direct = 2
    case propagated = 3

    public static func of(_ code: Int) -> LxMethod? { LxMethod(rawValue: code) }
}

/// LXMessage.state.
public enum LxState: Int, Sendable, Equatable {
    case generating = 0
    case outbound = 1
    case sending = 2
    case sent = 4
    case delivered = 8
    case rejected = 253
    case cancelled = 254
    case failed = 255

    public var terminal: Bool { self == .delivered || self == .rejected || self == .cancelled || self == .failed }
}

/// How a direct message is put on the link: one packet, or a resource when it outgrows one
/// (LxmfRouter.Representation; the Go router's ContentSize() <= LinkMaxContent branch).
public enum LxRepresentation: Sendable, Equatable {
    case packet
    case resource
}

public struct LxmfError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }

    /// The attachments together exceed LxFields.maxAttachmentBytes (Go's ErrAttachmentsTooLarge).
    public static let attachmentsTooLarge = LxmfError("attachments exceed \(LxFields.maxAttachmentBytes) bytes")
}

public struct LxMessage: Sendable, Equatable {
    public static let appName = "lxmf"
    public static let deliveryName = "lxmf.delivery"
    public static let propagationName = "lxmf.propagation"
    public static let destLen = 16
    public static let sigLen = 64
    public static let stampLen = 32
    public static let timestampSize = 8
    public static let structOverhead = 8
    public static let overhead = 2 * destLen + sigLen + timestampSize + structOverhead  // 112
    /// Opportunistic single packet: ENCRYPTED_MDU - overhead + dest = 287 at MTU 500 (LXMF 1.2.x,
    /// ENCRYPTED_PACKET_MDU = RNS.Packet.ENCRYPTED_MDU; 1.1.0 added the timestamp size and allowed
    /// 295, which the Bridge's PacketMaxContent still says).
    public static let encryptedPacketMaxContent = Rns.encryptedMdu - overhead + destLen
    /// A link packet carries 431 - overhead = 319 bytes of content at MTU 500; above it a
    /// direct message travels as a resource (the router's threshold).
    public static let linkPacketMaxContent = Rns.linkMdu() - overhead
    /// The largest inbound resource a router accepts, bytes: LXMRouter.DELIVERY_LIMIT (1000 kB),
    /// Android's deliveryLimit. (The Bridge's MaxTransferBytes is 1 MiB.)
    public static let deliveryPerTransferLimit = 1000 * 1000

    // Field numbers (LXMF/LXMF.py)
    public static let fieldEmbeddedLxms: Int64 = 0x01
    public static let fieldTelemetry: Int64 = 0x02
    public static let fieldTelemetryStream: Int64 = 0x03
    public static let fieldIconAppearance: Int64 = 0x04
    public static let fieldFileAttachments: Int64 = 0x05
    public static let fieldImage: Int64 = 0x06
    public static let fieldAudio: Int64 = 0x07
    public static let fieldThread: Int64 = 0x08
    public static let fieldCommands: Int64 = 0x09
    public static let fieldResults: Int64 = 0x0A
    public static let fieldGroup: Int64 = 0x0B
    public static let fieldTicket: Int64 = 0x0C
    public static let fieldEvent: Int64 = 0x0D
    public static let fieldRnrRefs: Int64 = 0x0E
    public static let fieldRenderer: Int64 = 0x0F

    public var dest: [UInt8]
    public var source: [UInt8]
    public var timestamp: Double
    public var title: [UInt8]
    public var content: [UInt8]
    /// Fields by LXMF field number; unknown ones (Sideband telemetry, icons, tickets) are kept as they came.
    public var fields: [MpEntry]
    public var stamp: [UInt8]?
    public var hash: [UInt8] = []
    public var signature: [UInt8] = []
    public var packed: [UInt8] = []

    // Set on inbound
    public var signatureValid = false
    public var sourceKnown = false
    public var stampValid = false
    public var stampChecked = false
    public var stampValue = 0
    public var method: LxMethod?
    public var iface = ""
    public var receivedAtMs: Int64 = 0

    public init(
        dest: [UInt8], source: [UInt8], timestamp: Double = 0, title: [UInt8] = [], content: [UInt8] = [], fields: [MpEntry] = []
    ) {
        self.dest = dest
        self.source = source
        self.timestamp = timestamp
        self.title = title
        self.content = content
        self.fields = fields
    }

    public var hashHex: String { Hex.encode(hash) }
    public var destHex: String { Hex.encode(dest) }
    public var sourceHex: String { Hex.encode(source) }
    public var titleString: String { String(decoding: title, as: UTF8.self) }
    public var contentString: String { String(decoding: content, as: UTF8.self) }

    private func payloadValue(withStamp: Bool) -> MpValue {
        var items: [MpValue] = [.float(timestamp), .bin(title), .bin(content), .map(fields)]
        if withStamp, let s = stamp { items.append(.bin(s)) }
        return .array(items)
    }

    private func payloadBytes(withStamp: Bool) -> [UInt8] { Msgpack.pack(payloadValue(withStamp: withStamp)) }

    /// What the method choice is judged on: the packed payload minus timestamp and structure
    /// overhead (LXMessage.pack content_size).
    public func contentSize() -> Int { payloadBytes(withStamp: false).count - LxMessage.timestampSize - LxMessage.structOverhead }

    /// The size of the packed message as it travels (with the stamp).
    public var packedSize: Int { packed.count }

    /// One packet or a resource for a direct message of this content size (LxmfRouter line
    /// "representation = if (size > LINK_PACKET_MAX_CONTENT) RESOURCE else PACKET").
    public static func representation(forContentSize size: Int) -> LxRepresentation {
        size > linkPacketMaxContent ? .resource : .packet
    }

    /// Computes the hash, generates a stamp when `stampCost` > 0, signs with the source identity
    /// and produces the packed form (LXMessage.pack). `stamper` returns nil when it could not
    /// produce one in time. A zero timestamp becomes `now` (seconds since the epoch).
    public mutating func pack(
        source identity: RnsIdentity, stampCost: Int = 0, stamper: ((_ hash: [UInt8], _ cost: Int) -> [UInt8]?)? = nil,
        now: Double = Date().timeIntervalSince1970
    ) throws {
        if timestamp == 0 { timestamp = now }
        let payload = payloadBytes(withStamp: false)
        let hashed = dest + source + payload
        hash = Rns.sha256(hashed)
        if stampCost > 0, let stamper {
            guard let s = stamper(hash, stampCost) else { throw LxmfError("stamp generation failed") }
            stamp = s
        }
        signature = try identity.sign(hashed + hash)
        signatureValid = true
        packed = dest + source + signature + payloadBytes(withStamp: true)
    }

    /// Parses a packed message (LXMessage.unpack_from_bytes). The signature is verified when
    /// `sigPubOf` knows the source; a stamp, when present, is kept. Throws LxmfError on
    /// malformed input; unknown fields never fail.
    public static func unpack(_ packed: [UInt8], sigPubOf: ((_ source: [UInt8]) -> [UInt8]?)? = nil) throws -> LxMessage {
        guard packed.count >= 2 * destLen + sigLen + 1 else { throw LxmfError("packed message too short") }
        let dest = Array(packed[0..<destLen])
        let source = Array(packed[destLen..<2 * destLen])
        let sig = Array(packed[2 * destLen..<2 * destLen + sigLen])
        let payloadRaw = Array(packed[(2 * destLen + sigLen)...])
        let unpacked: (value: MpValue, consumed: Int)
        do {
            unpacked = try Msgpack.unpack(payloadRaw)
        } catch let e as MsgpackError {
            throw LxmfError("payload: \(e.description)")
        }
        guard let arr = unpacked.value.asArray else { throw LxmfError("payload is not an array") }
        guard unpacked.consumed == payloadRaw.count, arr.count >= 4 else { throw LxmfError("payload is not a 4-element array") }
        var m = LxMessage(dest: dest, source: source)
        if arr.count > 4, case .bin(let s) = arr[4] { m.stamp = s }
        switch arr[0] {
        case .float(let t): m.timestamp = t
        case .int(let t): m.timestamp = Double(t)
        default: m.timestamp = 0
        }
        m.title = arr[1].asBytes ?? []
        m.content = arr[2].asBytes ?? []
        m.fields = arr[3].asMap ?? []
        // The hash is over the re-encoding of the first four elements.
        let payload = Msgpack.pack(.array([arr[0], arr[1], arr[2], arr[3]]))
        let hashed = dest + source + payload
        m.hash = Rns.sha256(hashed)
        m.signature = sig
        m.packed = packed
        if let sigPubOf, let pub = sigPubOf(source) {
            m.sourceKnown = true
            m.signatureValid = RnsIdentity.verifySignature(sigPub: pub, data: hashed + m.hash, signature: sig)
        }
        return m
    }

    /// A fields map from field numbers, convenient for callers.
    public static func fieldsOf(_ entries: [(Int64, MpValue)]) -> [MpEntry] { MpValue.fields(entries) }
}

extension MpValue {
    /// The textual form of a field value, for display; binary values show their size.
    public var displayString: String {
        switch self {
        case .str(let s): return s
        case .bin(let b): return "(\(b.count) bytes)"
        case .int(let i): return String(i)
        case .uint64(let u): return String(u)
        case .float(let f): return String(f)
        case .bool(let b): return String(b)
        case .null: return "nil"
        case .array(let a): return "[\(a.count) items]"
        case .map(let m): return "{\(m.count) entries}"
        case .ext(let e): return "ext(\(e.count) bytes)"
        }
    }
}
