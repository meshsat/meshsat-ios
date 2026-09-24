// Mirrors reticulum/RnsConstants.kt: Reticulum Network Stack protocol constants, wire-compatible
// with the Python RNS reference implementation.
//
// Packet header byte 1 (flags) bit layout (MSB to LSB):
//   [7:6] header_type   0=HEADER_1 (single addr), 1=HEADER_2 (transport, two addrs)
//   [5]   context_flag  0=no context byte, 1=context byte present
//   [4]   propagation   0=BROADCAST (local), 1=TRANSPORT (routed)
//   [3:2] dest_type     0=SINGLE, 1=GROUP, 2=PLAIN, 3=LINK
//   [1:0] packet_type   0=DATA, 1=ANNOUNCE, 2=LINKREQUEST, 3=PROOF
// Packet header byte 2: hop count (0 to 255)
import Foundation

public enum RnsConstants {
    // Protocol
    public static let mtu = 500
    public static let headerMinSize = 19  // 2 + 1 + 16 (HEADER_1)
    public static let headerMaxSize = 35  // 2 + 1 + 16 + 16 (HEADER_2)
    public static let ifacMinSize = 1
    public static let mdu = mtu - headerMaxSize - ifacMinSize  // 464
    public static let encryptedMdu = 383
    // Hash and key sizes
    public static let truncatedHashLength = 128  // bits
    public static let destHashLen = truncatedHashLength / 8  // 16 bytes
    public static let nameHashLen = 10  // 80 bits / 8
    public static let identityHashLen = destHashLen  // 16 bytes
    public static let fullHashLen = 32  // SHA-256
    public static let keySize = 512  // bits (256 encryption + 256 signing)
    public static let sigLen = 64  // Ed25519 signature
    public static let pubKeyLen = 32  // X25519 or Ed25519 public key
    public static let ratchetKeyLen = 32  // X25519 ratchet public key
    // Header types (2 bits, positions 7:6)
    public static let header1 = 0x00  // Single destination address
    public static let header2 = 0x01  // Transport: transport_id + destination
    // Packet types (2 bits, positions 1:0)
    public static let packetData = 0x00
    public static let packetAnnounce = 0x01
    public static let packetLinkRequest = 0x02
    public static let packetProof = 0x03
    // Destination types (2 bits, positions 3:2)
    public static let destSingle = 0x00  // Ephemeral ECDH per-packet encryption
    public static let destGroup = 0x01  // Pre-shared AES-256 symmetric key
    public static let destPlain = 0x02  // No encryption
    public static let destLink = 0x03  // Per-link ECDH forward secrecy
    // Propagation types (1 bit, position 4)
    public static let propagationBroadcast = 0x00  // Local delivery only
    public static let propagationTransport = 0x01  // Network-wide routing
    // Context types (1 byte, after address fields)
    public static let ctxNone: UInt8 = 0x00
    public static let ctxResource: UInt8 = 0x01
    public static let ctxResourceAdv: UInt8 = 0x02
    public static let ctxResourceReq: UInt8 = 0x03
    public static let ctxResourceHmu: UInt8 = 0x04
    public static let ctxResourcePrf: UInt8 = 0x05
    public static let ctxResourceIcl: UInt8 = 0x06
    public static let ctxResourceRcl: UInt8 = 0x07
    public static let ctxCacheRequest: UInt8 = 0x08
    public static let ctxRequest: UInt8 = 0x09
    public static let ctxResponse: UInt8 = 0x0A
    public static let ctxPathResponse: UInt8 = 0x0B
    public static let ctxCommand: UInt8 = 0x0C
    public static let ctxCommandStatus: UInt8 = 0x0D
    public static let ctxChannel: UInt8 = 0x0E
    // Protocol enhancements (MESHSAT-407): must match the Bridge's wire format byte for byte
    public static let ctxTimeSyncReq: UInt8 = 0x14
    public static let ctxTimeSyncResp: UInt8 = 0x15
    public static let ctxCustodyOffer: UInt8 = 0x16
    public static let ctxCustodyAck: UInt8 = 0x17
    public static let ctxRlnc: UInt8 = 0x18
    public static let ctxKeepalive: UInt8 = 0xFA
    public static let ctxLinkIdentify: UInt8 = 0xFB
    public static let ctxLinkClose: UInt8 = 0xFC
    public static let ctxLinkProof: UInt8 = 0xFD
    public static let ctxLrrtt: UInt8 = 0xFE
    public static let ctxLrProof: UInt8 = 0xFF
    // Announce
    public static let randomHashLen = 10  // 5 bytes random + 5 bytes timestamp
    public static let maxHops = 128
    public static let announceCap = 2  // percent of interface bandwidth
    // Link
    public static let linkTimeoutPerHop = 6  // seconds
    public static let linkKeepalive = 360  // seconds (default)
    public static let linkStaleTime = 720  // seconds
    // Ratchet
    public static let ratchetExpiry = 2_592_000  // seconds (30 days)
    public static let ratchetIdLen = 10  // 80 bits
}

/// Receives a raw Reticulum packet from an interface: (interfaceId, packet).
public typealias RnsReceiveCallback = @Sendable (String, [UInt8]) -> Void

/// Mirrors reticulum/RnsInterface.kt: the contract every Reticulum interface meets (mesh,
/// Iridium, MQTT, TCP, the Hub relay, the BLE peripheral).
public protocol RnsInterface: AnyObject, Sendable {
    /// Unique interface identifier (e.g. "mesh_0", "iridium_0", "hub_relay").
    var interfaceId: String { get }
    /// Human-readable name (e.g. "Meshtastic BLE", "Hub relay").
    var name: String { get }
    /// Largest Reticulum packet this interface carries, in bytes.
    var mtu: Int { get }
    /// Cost per message in USD cents (0 = free), for routing.
    var costCents: Int { get }
    /// Online and able to send and receive right now.
    var isOnline: Bool { get }
    /// Estimated latency in milliseconds, for path costs. 0 = negligible.
    var latencyMs: Int { get }
    /// Some interfaces (an APRS beacon) are send-only.
    var isBidirectional: Bool { get }
    /// Send an already marshalled packet. nil on success, an error message on failure.
    func send(_ packet: [UInt8]) async -> String?
    func setReceiveCallback(_ callback: RnsReceiveCallback?)
    func start() async
    func stop() async
}
