// Mirrors reticulum/RnsMeshtasticBleInterface.kt: a Reticulum interface over the Meshtastic
// radio, packets inside PRIVATE_APP (portnum 256) messages, fragmented for the LoRa payload
// limit (about 230 bytes) and reassembled on receive.
//
// Wire format within the Meshtastic Data payload:
//   Single fragment: [0x00] [Reticulum packet]
//   Multi fragment:  [header] [reassembly_id u16 BE] [fragment], header bits [7:6] = 0b01,
//                    [5:1] = fragment index (0 to 31), [0] = 1 when more fragments follow.
// The radio link is a protocol so the interface is testable here and MeshtasticCentral conforms.
import Crypto
import Foundation
import MeshSatNet
import MeshSatProto

/// The radio as this interface needs it (ble/MeshtasticBle.kt): ToRadio out, FromRadio in.
public protocol MeshRadioLink: AnyObject, Sendable {
    var isConnected: Bool { get }
    func sendToRadio(_ data: [UInt8])
    /// Every FromRadio protobuf the radio delivered.
    var receivedData: Broadcast<[UInt8]> { get }
}

public final class RnsMeshtasticBleInterface: RnsInterface, @unchecked Sendable {
    public static let portnumPrivateApp = 256
    public static let broadcastAddr: UInt32 = 0xFFFF_FFFF
    /// LoRa payload budget per Meshtastic packet: about 233 bytes at SF7/BW125, 230 kept as margin.
    public static let loraPayloadMax = 230
    static let singleHeaderSize = 1
    static let fragHeaderSize = 3
    /// Payload capacity per fragment.
    public static let fragPayloadMax = loraPayloadMax - fragHeaderSize  // 227
    static let maxFragments = 32
    static let reassemblyTimeoutMs: Int64 = 30_000
    static let maxReassemblySessions = 64
    static let fragMarker: UInt8 = 0x40

    public let interfaceId: String
    public let name: String
    /// The standard 500 bytes; fragmentation is transparent.
    public let mtu = RnsConstants.mtu
    public let costCents = 0
    public let latencyMs = 500
    public let isBidirectional = true
    public var isOnline: Bool { radio.isConnected }

    private let radio: any MeshRadioLink
    private let meshChannel: Int
    private let targetNode: UInt32
    private let now: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var receiveCallback: RnsReceiveCallback?
    private var collect: Task<Void, Never>?
    private var sessions: [Int: ReassemblySession] = [:]
    private var sessionOrder: [Int] = []

    private struct ReassemblySession {
        var fragments: [[UInt8]?] = Array(repeating: nil, count: RnsMeshtasticBleInterface.maxFragments)
        var receivedCount = 0
        var lastIndex = -1
        let createdAt: Int64
    }

    public init(
        radio: any MeshRadioLink, interfaceId: String = "mesh_rns_0", name: String = "Meshtastic BLE (Reticulum)", meshChannel: Int = 0,
        targetNode: UInt32 = RnsMeshtasticBleInterface.broadcastAddr,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.radio = radio
        self.interfaceId = interfaceId
        self.name = name
        self.meshChannel = meshChannel
        self.targetNode = targetNode
        self.now = now
        self.log = log
    }

    public func setReceiveCallback(_ callback: RnsReceiveCallback?) {
        lock.lock()
        receiveCallback = callback
        lock.unlock()
    }

    public func send(_ packet: [UInt8]) async -> String? {
        guard isOnline else { return "BLE not connected" }
        let fragments: [[UInt8]]
        do {
            fragments = try Self.fragment(packet)
        } catch {
            return "\(error)"
        }
        for frag in fragments { radio.sendToRadio(Self.encodePrivateAppToRadio(frag, to: targetNode, channel: meshChannel)) }
        log("Sent RNS packet (\(packet.count)B, \(fragments.count) frag) to mesh ch=\(meshChannel)")
        return nil
    }

    public func start() async {
        // Subscribed here, not inside the task: a FromRadio that arrives before the task runs
        // must not be lost (it was, under CI's parallel test load).
        let stream = radio.receivedData.subscribe()
        let task = Task { [weak self] in
            for await raw in stream { self?.handleRadioData(raw) }
        }
        replaceCollect(task)
    }

    public func stop() async { replaceCollect(nil) }

    private func replaceCollect(_ task: Task<Void, Never>?) {
        lock.lock()
        let old = collect
        collect = task
        if task == nil {
            sessions.removeAll()
            sessionOrder.removeAll()
        }
        lock.unlock()
        old?.cancel()
    }

    /// A FromRadio from the radio: PRIVATE_APP only, single or reassembled.
    func handleRadioData(_ raw: [UInt8]) {
        guard let payload = Self.parsePrivateAppPayload(raw), !payload.isEmpty else { return }
        let header = payload[0]
        if header == 0x00 {
            guard payload.count >= 2 else { return }
            deliver(Array(payload[Self.singleHeaderSize...]))
        } else if header & 0xC0 == Self.fragMarker {
            handleFragment(payload)
        } else {
            log("Unknown RNS encapsulation header: 0x\(String(header, radix: 16))")
        }
    }

    private func deliver(_ packet: [UInt8]) {
        guard packet.count >= 18 else { return }
        lock.lock()
        let cb = receiveCallback
        lock.unlock()
        cb?(interfaceId, packet)
    }

    // MARK: Fragmentation

    public struct TooLarge: Error, CustomStringConvertible {
        public let description: String
    }

    /// The Meshtastic Data payloads for a packet, each at most `loraPayloadMax` bytes.
    public static func fragment(_ packet: [UInt8]) throws -> [[UInt8]] {
        if packet.count + singleHeaderSize <= loraPayloadMax { return [[0x00] + packet] }
        let reassemblyId = computeReassemblyId(packet)
        let chunks = stride(from: 0, to: packet.count, by: fragPayloadMax).map {
            Array(packet[$0..<min($0 + fragPayloadMax, packet.count)])
        }
        guard chunks.count <= maxFragments else {
            throw TooLarge(description: "Packet too large: \(packet.count)B requires \(chunks.count) fragments (max \(maxFragments))")
        }
        return chunks.enumerated().map { index, chunk in
            let isLast = index == chunks.count - 1
            let header = fragMarker | UInt8((index & 0x1F) << 1) | (isLast ? 0 : 1)
            return [header, UInt8(reassemblyId >> 8), UInt8(reassemblyId & 0xFF)] + chunk
        }
    }

    private func handleFragment(_ payload: [UInt8]) {
        guard payload.count >= Self.fragHeaderSize else { return }
        let header = payload[0]
        let fragIndex = Int((header >> 1) & 0x1F)
        let more = header & 0x01 == 1
        let reassemblyId = Int(payload[1]) << 8 | Int(payload[2])
        let fragData = Array(payload[Self.fragHeaderSize...])
        var assembled: [UInt8]?
        lock.lock()
        pruneExpiredSessions()
        if sessions[reassemblyId] == nil {
            if sessions.count >= Self.maxReassemblySessions, let oldest = sessionOrder.first {
                sessions.removeValue(forKey: oldest)
                sessionOrder.removeFirst()
            }
            sessions[reassemblyId] = ReassemblySession(createdAt: now())
            sessionOrder.append(reassemblyId)
        }
        if var session = sessions[reassemblyId], session.fragments[fragIndex] == nil {
            session.fragments[fragIndex] = fragData
            session.receivedCount += 1
            if !more { session.lastIndex = fragIndex }
            if session.lastIndex >= 0 {
                let parts = session.fragments[0...session.lastIndex]
                if parts.allSatisfy({ $0 != nil }) {
                    assembled = parts.compactMap { $0 }.flatMap { $0 }
                    sessions.removeValue(forKey: reassemblyId)
                    sessionOrder.removeAll { $0 == reassemblyId }
                } else {
                    sessions[reassemblyId] = session
                }
            } else {
                sessions[reassemblyId] = session
            }
        }
        lock.unlock()
        if let assembled {
            log("Reassembled RNS packet: \(assembled.count)B")
            deliver(assembled)
        }
    }

    private func pruneExpiredSessions() {
        let t = now()
        for (id, s) in sessions where t - s.createdAt > Self.reassemblyTimeoutMs {
            sessions.removeValue(forKey: id)
            sessionOrder.removeAll { $0 == id }
        }
    }

    /// A 16-bit reassembly id: the first two bytes of the packet's SHA-256.
    static func computeReassemblyId(_ packet: [UInt8]) -> Int {
        let hash = Array(SHA256.hash(data: packet))
        return Int(hash[0]) << 8 | Int(hash[1])
    }

    // MARK: Meshtastic protobufs

    /// A fragment as a ToRadio with portnum 256 (PRIVATE_APP).
    public static func encodePrivateAppToRadio(_ payload: [UInt8], to: UInt32 = broadcastAddr, channel: Int = 0) -> [UInt8] {
        var data = Meshtastic_Data()
        data.portnum = .privateApp
        data.payload = Data(payload)
        var packet = Meshtastic_MeshPacket()
        packet.to = to
        packet.channel = UInt32(channel)
        packet.decoded = data
        var toRadio = Meshtastic_ToRadio()
        toRadio.packet = packet
        return Array((try? toRadio.serializedBytes()) ?? Data())
    }

    /// The PRIVATE_APP payload of a FromRadio, or nil when it is not one.
    public static func parsePrivateAppPayload(_ raw: [UInt8]) -> [UInt8]? {
        guard let fr = try? Meshtastic_FromRadio(serializedBytes: raw), case .packet(let p)? = fr.payloadVariant,
            case .decoded(let d)? = p.payloadVariant, d.portnum == .privateApp
        else { return nil }
        return Array(d.payload)
    }
}
