// Mirrors reticulum/RnsResource.kt: a Reticulum Resource, the reliable chunked transfer over an
// established link, with per-chunk acknowledgment (MESHSAT-223), and its wire formats.
import Crypto
import Foundation
import MeshSatWire

public enum RnsTransferState: Sendable, Equatable {
    case advertising  // sender advertised, waiting for the request
    case transferring  // chunks being sent or received
    case complete  // all chunks received, hash verified
    case failed  // timeout or hash mismatch
}

public final class RnsResource: @unchecked Sendable {
    public let id: [UInt8]  // 16 bytes (truncated hash of the payload)
    public let totalSize: Int
    public let chunkSize: Int
    public let chunkCount: Int
    public let payloadHash: [UInt8]  // SHA-256 of the whole payload
    public let isOutbound: Bool
    public let linkId: [UInt8]
    public let createdAt: Int64
    private let lock = NSLock()
    private var stateValue: RnsTransferState
    private var receivedChunks: [Int: [UInt8]] = [:]
    private var ackedChunks: Set<Int> = []

    public init(
        id: [UInt8], totalSize: Int, chunkSize: Int, chunkCount: Int, payloadHash: [UInt8], state: RnsTransferState, isOutbound: Bool,
        linkId: [UInt8], createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.id = id
        self.totalSize = totalSize
        self.chunkSize = chunkSize
        self.chunkCount = chunkCount
        self.payloadHash = payloadHash
        self.stateValue = state
        self.isOutbound = isOutbound
        self.linkId = linkId
        self.createdAt = createdAt
    }

    public var idHex: String { Hex.encode(id) }

    public var state: RnsTransferState {
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

    private var doneCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return isOutbound ? ackedChunks.count : receivedChunks.count
    }

    /// 0.0 to 1.0.
    public var progress: Float { chunkCount == 0 ? 1 : Float(doneCount) / Float(chunkCount) }
    public var isComplete: Bool { doneCount >= chunkCount }

    /// Record a received chunk (inbound).
    public func addChunk(index: Int, data: [UInt8]) {
        guard (0..<chunkCount).contains(index) else { return }
        lock.lock()
        receivedChunks[index] = data
        lock.unlock()
    }

    /// Mark a chunk acknowledged (outbound).
    public func ackChunk(_ index: Int) {
        guard (0..<chunkCount).contains(index) else { return }
        lock.lock()
        ackedChunks.insert(index)
        lock.unlock()
    }

    /// Chunks not yet acknowledged, for retransmission.
    public func pendingChunks() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<chunkCount).filter { !ackedChunks.contains($0) }
    }

    /// The whole payload from the received chunks, or nil when one is missing.
    public func reassemble() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard receivedChunks.count >= chunkCount else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(totalSize)
        for i in 0..<chunkCount {
            guard let chunk = receivedChunks[i] else { return nil }
            out += chunk.prefix(max(0, totalSize - out.count))
        }
        return out
    }

    public func verifyHash(_ payload: [UInt8]) -> Bool { Array(SHA256.hash(data: payload)) == payloadHash }

    /// A resource for sending, and its chunks.
    public static func forSending(_ payload: [UInt8], chunkSize: Int, linkId: [UInt8]) -> (resource: RnsResource, chunks: [[UInt8]]) {
        let hash = Array(SHA256.hash(data: payload))
        let chunkCount = (payload.count + chunkSize - 1) / chunkSize
        var chunks: [[UInt8]] = []
        var offset = 0
        for _ in 0..<chunkCount {
            let end = min(offset + chunkSize, payload.count)
            chunks.append(Array(payload[offset..<end]))
            offset = end
        }
        let resource = RnsResource(
            id: Array(hash.prefix(RnsConstants.destHashLen)), totalSize: payload.count, chunkSize: chunkSize, chunkCount: chunkCount,
            payloadHash: hash, state: .advertising, isOutbound: true, linkId: linkId)
        return (resource, chunks)
    }

    // swiftlint:disable function_parameter_count
    /// A resource for receiving, from an advertisement (Android's six parameters kept).
    public static func forReceiving(id: [UInt8], totalSize: Int, chunkSize: Int, chunkCount: Int, payloadHash: [UInt8], linkId: [UInt8])
        -> RnsResource
    {
        RnsResource(
            id: id, totalSize: totalSize, chunkSize: chunkSize, chunkCount: chunkCount, payloadHash: payloadHash, state: .transferring,
            isOutbound: false, linkId: linkId)
    }
    // swiftlint:enable function_parameter_count
}

/// Resource advertisement (context CTX_RESOURCE_ADV): id(16) hash(32) total_size(u32) chunk_size(u16) chunk_count(u16).
public enum RnsResourceAdv {
    public static let size = RnsConstants.destHashLen + RnsConstants.fullHashLen + 4 + 2 + 2  // 56

    public struct Parsed: Sendable, Equatable {
        public let resourceId: [UInt8]
        public let payloadHash: [UInt8]
        public let totalSize: Int
        public let chunkSize: Int
        public let chunkCount: Int
    }

    public static func marshal(_ r: RnsResource) -> [UInt8] {
        r.id + r.payloadHash + UInt32(r.totalSize).bytesBE + UInt16(r.chunkSize).bytesBE + UInt16(r.chunkCount).bytesBE
    }

    public static func unmarshal(_ data: [UInt8]) -> Parsed? {
        guard data.count >= size else { return nil }
        let n = RnsConstants.destHashLen
        let h = RnsConstants.fullHashLen
        return Parsed(
            resourceId: Array(data[0..<n]), payloadHash: Array(data[n..<n + h]), totalSize: Int(data.uint32BE(at: n + h) ?? 0),
            chunkSize: Int(data.uint16BE(at: n + h + 4) ?? 0), chunkCount: Int(data.uint16BE(at: n + h + 6) ?? 0))
    }
}

/// Resource chunk (context CTX_RESOURCE): id(16) chunk_index(u16) chunk_data.
public enum RnsResourceChunk {
    public static let headerSize = RnsConstants.destHashLen + 2  // 18

    public struct Parsed: Sendable, Equatable {
        public let resourceId: [UInt8]
        public let chunkIndex: Int
        public let chunkData: [UInt8]
    }

    public static func marshal(resourceId: [UInt8], chunkIndex: Int, chunkData: [UInt8]) -> [UInt8] {
        resourceId + UInt16(chunkIndex).bytesBE + chunkData
    }

    public static func unmarshal(_ data: [UInt8]) -> Parsed? {
        guard data.count >= headerSize else { return nil }
        let n = RnsConstants.destHashLen
        return Parsed(resourceId: Array(data[0..<n]), chunkIndex: Int(data.uint16BE(at: n) ?? 0), chunkData: Array(data[headerSize...]))
    }
}

/// Resource proof, the chunk ACK (context CTX_RESOURCE_PRF): id(16) chunk_index(u16).
public enum RnsResourceProof {
    public static let size = RnsConstants.destHashLen + 2  // 18

    public struct Parsed: Sendable, Equatable {
        public let resourceId: [UInt8]
        public let chunkIndex: Int
    }

    public static func marshal(resourceId: [UInt8], chunkIndex: Int) -> [UInt8] { resourceId + UInt16(chunkIndex).bytesBE }

    public static func unmarshal(_ data: [UInt8]) -> Parsed? {
        guard data.count >= size else { return nil }
        let n = RnsConstants.destHashLen
        return Parsed(resourceId: Array(data[0..<n]), chunkIndex: Int(data.uint16BE(at: n) ?? 0))
    }
}

/// Resource complete (context CTX_RESOURCE_ICL): id(16) status(1: 0x01 success, 0x00 failed).
public enum RnsResourceComplete {
    public static let size = RnsConstants.destHashLen + 1  // 17

    public struct Parsed: Sendable, Equatable {
        public let resourceId: [UInt8]
        public let success: Bool
    }

    public static func marshal(resourceId: [UInt8], success: Bool) -> [UInt8] { resourceId + [success ? 0x01 : 0x00] }

    public static func unmarshal(_ data: [UInt8]) -> Parsed? {
        guard data.count >= size else { return nil }
        return Parsed(resourceId: Array(data[0..<RnsConstants.destHashLen]), success: data[RnsConstants.destHashLen] == 0x01)
    }
}
