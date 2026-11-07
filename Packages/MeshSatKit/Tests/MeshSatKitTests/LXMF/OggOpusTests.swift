// Mirrors audio/OggOpusTest.kt: the Ogg Opus container around a note's packets (MESHSAT-1735).
import XCTest

@testable import MeshSatLXMF

final class OggOpusTests: XCTestCase {
    /// A 20 ms SILK packet (TOC config 1, code 0) of `n` bytes.
    private func silk20(_ n: Int, _ seed: Int) -> [UInt8] {
        (0..<n).map { $0 == 0 ? 0x08 : UInt8(truncatingIfNeeded: $0 * 31 + seed) }
    }

    func testCrcTableIsTheOggPolynomial() {
        XCTAssertEqual(OggOpus.crc([0]), 0)
        XCTAssertEqual(OggOpus.crc([1]), 0x04C1_1DB7)
        XCTAssertEqual(OggOpus.crc([2]), 0x0982_3B6E)
        XCTAssertEqual(OggOpus.crc([3]), 0x0D43_26D9)
        XCTAssertEqual(OggOpus.crc([0xFF]), 0xB1F7_40B4)
        XCTAssertEqual(OggOpus.crc(Array("OggS".utf8) + [0, 2]), 0xF163_7C67)
    }

    func testHeadRoundTrip() throws {
        let h = OggOpus.Head(channels: 1, preSkip: 312, inputSampleRate: 48_000, outputGain: -256)
        let b = h.encode()
        XCTAssertEqual(b.count, 19)
        XCTAssertEqual(String(decoding: b[0..<8], as: UTF8.self), "OpusHead")
        XCTAssertEqual(b[8], 1)
        XCTAssertEqual(try OggOpus.Head.parse(b), h)
    }

    func testPacketSamplesFromTheToc() {
        XCTAssertEqual(OggOpus.packetSamples48k([0x08]), 960)  // SILK NB 20 ms
        XCTAssertEqual(OggOpus.packetSamples48k([0x18]), 2880)  // SILK NB 60 ms (Sideband)
        XCTAssertEqual(OggOpus.packetSamples48k([0x09]), 1920)  // code 1: two 20 ms frames
        XCTAssertEqual(OggOpus.packetSamples48k([0x60]), 480)  // hybrid 10 ms
        XCTAssertEqual(OggOpus.packetSamples48k([0x80]), 120)  // CELT 2.5 ms
        XCTAssertEqual(OggOpus.packetSamples48k([0x0B, 0x03]), 2880)  // code 3: three 20 ms frames
        XCTAssertEqual(OggOpus.packetSamples48k([0x48]), 960)  // what Apple's encoder writes: SILK WB 20 ms
        XCTAssertEqual(OggOpus.packetSamples48k([]), 0)
    }

    func testWriteThenReadGivesTheSamePacketsAndDuration() throws {
        let head = OggOpus.Head(channels: 1, preSkip: 312, inputSampleRate: 48_000)
        let packets = (0..<123).map { silk20(20 + $0 % 50, $0) }
        let ogg = try OggOpus.write(head: head, packets: packets, packetsPerPage: 50)
        XCTAssertTrue(OggOpus.looksLikeOggOpus(ogg))
        let s = try OggOpus.read(ogg)
        XCTAssertEqual(s.head, head)
        XCTAssertEqual(s.packets, packets)
        XCTAssertEqual(s.samples48k, 123 * 960)
        XCTAssertEqual(s.durationMs, (123 * 960 - 312) * 1000 / 48_000)
        // Pages: 2 headers + ceil(123 / 50) = 3 audio pages; the last one carries the end flag.
        var pages = 0
        var pos = 0
        var lastType: UInt8 = 0
        while pos < ogg.count {
            let nseg = Int(ogg[pos + 26])
            let body = ogg[(pos + 27)..<(pos + 27 + nseg)].reduce(0) { $0 + Int($1) }
            lastType = ogg[pos + 5]
            pages += 1
            pos += 27 + nseg + body
        }
        XCTAssertEqual(pages, 5)
        XCTAssertEqual(lastType, 0x04)
    }

    func testLongPacketsLaceAcrossSegments() throws {
        let packets = [silk20(255, 1), silk20(510, 2), silk20(700, 3), silk20(1, 4)]
        let s = try OggOpus.read(try OggOpus.write(head: OggOpus.Head(channels: 1, preSkip: 0, inputSampleRate: 48_000), packets: packets))
        XCTAssertEqual(s.packets, packets)
    }

    func testCorruptionIsRefused() throws {
        let ogg = try OggOpus.write(head: OggOpus.Head(channels: 1, preSkip: 312, inputSampleRate: 48_000), packets: [silk20(30, 1)])
        var bad = ogg
        bad[bad.count - 1] ^= 0x55
        XCTAssertThrowsError(try OggOpus.read(bad))
        XCTAssertThrowsError(try OggOpus.read(Array("not ogg at all, really not".utf8)))
        XCTAssertThrowsError(try OggOpus.read(Array(ogg.dropLast(3))))
    }
}
