// Mirrors audio/OggOpus.kt (MESHSAT-1735): the Ogg Opus container (RFC 3533 pages, RFC 7845
// headers) a voice note travels in as LXMF audio mode 0x10, what Sideband writes and plays.
// AVAudioConverter speaks raw Opus packets, as Android's codec does, so this wraps them on the way
// out and unwraps them on the way in. Packets stay under 65 025 bytes and never span a page, which
// every note satisfies by a wide margin.
import Foundation

public struct OggError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum OggOpus {
    /// Opus packets always count at 48 kHz, whatever the input rate.
    public static let rate48k = 48_000

    /// The identification header (RFC 7845 5.1).
    public struct Head: Sendable, Equatable {
        public var channels: Int
        public var preSkip: Int
        public var inputSampleRate: Int
        public var outputGain: Int

        public init(channels: Int, preSkip: Int, inputSampleRate: Int, outputGain: Int = 0) {
            self.channels = channels
            self.preSkip = preSkip
            self.inputSampleRate = inputSampleRate
            self.outputGain = outputGain
        }

        public func encode() -> [UInt8] {
            var out = Array("OpusHead".utf8)
            out.append(1)
            out.append(UInt8(truncatingIfNeeded: channels))
            out.le16(preSkip)
            out.le32(UInt32(truncatingIfNeeded: inputSampleRate))
            out.le16(outputGain)
            out.append(0)  // mapping family 0: mono or stereo, no table
            return out
        }

        public static func parse(_ b: [UInt8]) throws -> Head {
            guard b.count >= 19, String(decoding: b[0..<8], as: UTF8.self) == "OpusHead" else { throw OggError("not an OpusHead") }
            let preSkip = Int(b[10]) | Int(b[11]) << 8
            let rate = Int(b[12]) | Int(b[13]) << 8 | Int(b[14]) << 16 | Int(b[15]) << 24
            let gain = Int(Int16(bitPattern: UInt16(b[16]) | UInt16(b[17]) << 8))
            return Head(channels: Int(b[9]), preSkip: preSkip, inputSampleRate: rate, outputGain: gain)
        }
    }

    /// A parsed stream: the header, the audio packets in order, and how long it plays.
    public struct Stream: Sendable {
        public let head: Head
        public let packets: [[UInt8]]

        /// Samples at 48 kHz across every packet, from the packets' own table-of-contents bytes.
        public var samples48k: Int64 { packets.reduce(0) { $0 + Int64(OggOpus.packetSamples48k($1)) } }
        public var durationMs: Int64 { max(0, samples48k - Int64(head.preSkip)) * 1000 / Int64(OggOpus.rate48k) }
    }

    /// Wraps `packets` (each one Opus packet) into an Ogg Opus stream: the two header pages, then
    /// audio pages of `packetsPerPage` packets, the last one marked end of stream.
    public static func write(
        head: Head, packets: [[UInt8]], serial: UInt32 = 0x4D53_4154, packetsPerPage: Int = 50, vendor: String = "MeshSat"
    ) throws -> [UInt8] {
        var out: [UInt8] = []
        var seq: UInt32 = 0
        out += try page(serial: serial, seq: seq, granule: 0, type: 0x02, packets: [head.encode()])
        seq += 1
        out += try page(serial: serial, seq: seq, granule: 0, type: 0, packets: [tags(vendor)])
        seq += 1
        if packets.isEmpty {
            out += try page(serial: serial, seq: seq, granule: 0, type: 0x04, packets: [])
            return out
        }
        var granule: Int64 = 0
        var i = 0
        while i < packets.count {
            let end = min(i + packetsPerPage, packets.count)
            let slice = Array(packets[i..<end])
            for p in slice { granule += Int64(packetSamples48k(p)) }
            out += try page(serial: serial, seq: seq, granule: granule, type: end == packets.count ? 0x04 : 0, packets: slice)
            seq += 1
            i = end
        }
        return out
    }

    /// Reads the first logical stream of an Ogg Opus file; throws `OggError` on anything else.
    public static func read(_ data: [UInt8]) throws -> Stream {
        var reader = PageReader(data: data)
        try reader.run()
        let packets = reader.packets
        guard packets.count >= 2 else { throw OggError("no opus headers") }
        let head = try Head.parse(packets[0])
        guard String(decoding: packets[1].prefix(8), as: UTF8.self) == "OpusTags" else {
            throw OggError("second packet is not OpusTags")
        }
        return Stream(head: head, packets: Array(packets[2...]))
    }

    /// True when `data` starts like an Ogg Opus stream.
    public static func looksLikeOggOpus(_ data: [UInt8]) -> Bool {
        data.count > 36 && String(decoding: data[0..<4], as: UTF8.self) == "OggS"
            && String(decoding: data[28..<36], as: UTF8.self) == "OpusHead"
    }

    /// The samples (at 48 kHz) one Opus packet decodes to, from its table-of-contents byte (RFC 6716
    /// 3.1): configurations 0-11 are SILK at 10/20/40/60 ms, 12-15 hybrid at 10/20 ms, 16-31 CELT at
    /// 2.5/5/10/20 ms; code 3 packets carry their frame count in the next byte.
    public static func packetSamples48k(_ p: [UInt8]) -> Int {
        guard let toc = p.first.map(Int.init) else { return 0 }
        let config = toc >> 3
        let frameSamples: Int
        if config < 12 {
            frameSamples = [480, 960, 1920, 2880][config & 3]
        } else if config < 16 {
            frameSamples = [480, 960][config & 1]
        } else {
            frameSamples = [120, 240, 480, 960][config & 3]
        }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = p.count > 1 ? Int(p[1]) & 0x3F : 0
        }
        return frameSamples * frames
    }

    /// The Ogg page checksum: CRC-32 with polynomial 0x04c11db7, no reflection, no initial or final xor.
    public static func crc(_ b: [UInt8]) -> UInt32 {
        var r: UInt32 = 0
        for x in b { r = (r << 8) ^ table[Int(((r >> 24) ^ UInt32(x)) & 0xFF)] }
        return r
    }

    private static let table: [UInt32] = (0..<256).map { i in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    private static func tags(_ vendor: String) -> [UInt8] {
        var out = Array("OpusTags".utf8)
        let v = Array(vendor.utf8)
        out.le32(UInt32(v.count))
        out += v
        out.le32(0)
        return out
    }

    /// One page; `type` is the header type byte (0x02 stream start, 0x04 stream end).
    private static func page(serial: UInt32, seq: UInt32, granule: Int64, type: UInt8, packets: [[UInt8]]) throws -> [UInt8] {
        var lacing: [UInt8] = []
        var body: [UInt8] = []
        for p in packets {
            guard p.count < 255 * 255 else { throw OggError("packet of \(p.count) bytes does not fit a page") }
            var left = p.count
            while left >= 255 {
                lacing.append(255)
                left -= 255
            }
            lacing.append(UInt8(left))
            body += p
        }
        guard lacing.count <= 255 else { throw OggError("too many segments for one page") }
        var out = Array("OggS".utf8)
        out.append(0)
        out.append(type)
        out.le64(UInt64(bitPattern: granule))
        out.le32(serial)
        out.le32(seq)
        out.le32(0)
        out.append(UInt8(lacing.count))
        out += lacing
        out += body
        let c = crc(out)
        out[22] = UInt8(c & 0xFF)
        out[23] = UInt8((c >> 8) & 0xFF)
        out[24] = UInt8((c >> 16) & 0xFF)
        out[25] = UInt8((c >> 24) & 0xFF)
        return out
    }

    static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }
}

/// OggOpus.read's page walk: the packets of the first logical stream, CRC and sequence checked.
private struct PageReader {
    let data: [UInt8]
    var packets: [[UInt8]] = []
    private var pos = 0
    private var serial: UInt32?
    private var expectedSeq: UInt32 = 0
    private var partial: [UInt8] = []
    private var sawEos = false

    init(data: [UInt8]) { self.data = data }

    mutating func run() throws {
        while pos + 27 <= data.count, !sawEos { try readPage() }
    }

    private mutating func readPage() throws {
        guard String(decoding: data[pos..<pos + 4], as: UTF8.self) == "OggS" else { throw OggError("no page at \(pos)") }
        guard data[pos + 4] == 0 else { throw OggError("ogg version \(data[pos + 4])") }
        let type = data[pos + 5]
        let pageSerial = OggOpus.le32(data, pos + 14)
        let seq = OggOpus.le32(data, pos + 18)
        let crc = OggOpus.le32(data, pos + 22)
        let nseg = Int(data[pos + 26])
        let headerLen = 27 + nseg
        guard pos + headerLen <= data.count else { throw OggError("truncated segment table at \(pos)") }
        let bodyLen = data[(pos + 27)..<(pos + headerLen)].reduce(0) { $0 + Int($1) }
        let pageLen = headerLen + bodyLen
        guard pos + pageLen <= data.count else { throw OggError("truncated page at \(pos)") }
        var copy = Array(data[pos..<pos + pageLen])
        for k in 22...25 { copy[k] = 0 }
        guard OggOpus.crc(copy) == crc else { throw OggError("bad page crc at \(pos)") }
        if serial == nil {
            guard type & 0x02 != 0 else { throw OggError("first page is not a stream start") }
            serial = pageSerial
        }
        if pageSerial == serial {
            guard seq == expectedSeq else { throw OggError("page sequence \(seq), expected \(expectedSeq)") }
            expectedSeq += 1
            collect(type: type, nseg: nseg, headerLen: headerLen)
            if type & 0x04 != 0 { sawEos = true }
        }
        pos += pageLen
    }

    private mutating func collect(type: UInt8, nseg: Int, headerLen: Int) {
        var p = pos + headerLen
        if type & 0x01 == 0 { partial = [] }
        for s in 0..<nseg {
            let len = Int(data[pos + 27 + s])
            partial += data[p..<p + len]
            p += len
            if len < 255 {
                packets.append(partial)
                partial = []
            }
        }
    }
}

extension Array where Element == UInt8 {
    fileprivate mutating func le16(_ v: Int) {
        append(UInt8(truncatingIfNeeded: v))
        append(UInt8(truncatingIfNeeded: v >> 8))
    }

    fileprivate mutating func le32(_ v: UInt32) {
        for s in [0, 8, 16, 24] { append(UInt8(truncatingIfNeeded: v >> UInt32(s))) }
    }

    fileprivate mutating func le64(_ v: UInt64) {
        for s in stride(from: 0, to: 64, by: 8) { append(UInt8(truncatingIfNeeded: v >> UInt64(s))) }
    }
}
