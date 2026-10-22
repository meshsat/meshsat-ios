// Mirrors HChainVectorsTest.kt (MESHSAT-1623): the kits' satellite H chain against the Bridge's
// own vectors. The copy in Fixtures/hchain is the file vectors.lock names, generated from the
// Bridge commit it records. Every vector is checked both ways, through the codec AND through the
// chain this app sends with. [MESHSAT-1624]
import Crypto
import Foundation
import MeshSatEngine
import XCTest

@testable import MeshSatWire

/// The vectors file as the Bridge writes it (meshsat internal/engine/h_chain_vectors_test.go).
struct HChainVectors: Decodable {
    struct Spec: Decodable {
        let protocolVersion: String
        let rollbackEgress: String
    }
    struct Table: Decodable {
        let words: [String]
        let bigrams: String
    }
    struct Tables: Decodable { let meshtastic: Table }
    struct Smaz2Vector: Decodable {
        let name, dict, text, textHex, compressedHex, decompressedHex: String
    }
    struct Smaz2gVector: Decodable {
        let name, dict, text, textHex, mode, frameHex: String
    }
    struct FrameReject: Decodable {
        let name, dict, bytesHex: String
    }
    struct Envelope: Decodable {
        let name, dict, text, keyHex, nonceHex, wireHex: String
        let wireLen: Int
    }
    struct EnvelopeReject: Decodable {
        let name, dict, keyHex, bytesHex: String
    }

    let name: String
    let version: Int
    let spec: Spec
    let dictionaries: Tables
    let smaz2: [Smaz2Vector]
    let smaz2g: [Smaz2gVector]
    let smaz2gReject: [FrameReject]
    let envelopes: [Envelope]
    let envelopeReject: [EnvelopeReject]
    /// The rollback chain as parallax runs it (Bridge fc8dee08, r33 review R33-R2).
    let legacyEnvelopes: [Envelope]
    let legacyReject: [EnvelopeReject]

    /// The lock's lines ("key value"), and the file it names as it is and decoded.
    struct Locked {
        let lock: [String: String]
        let bytes: Data
        let vectors: HChainVectors
    }

    static func load() throws -> Locked {
        let lockURL = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "lock", subdirectory: "Fixtures/hchain"))
        var lock: [String: String] = [:]
        for line in try String(contentsOf: lockURL, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { lock[String(parts[0])] = String(parts[1]) }
        }
        let file = try XCTUnwrap(lock["file"])
        let bytes = try Data(contentsOf: lockURL.deletingLastPathComponent().appendingPathComponent(file))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return Locked(lock: lock, bytes: bytes, vectors: try decoder.decode(HChainVectors.self, from: bytes))
    }
}

/// Hex both ways, failing the test on a bad vector rather than crashing it.
func hexBytes(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> [UInt8] {
    guard let b = Hex.decode(s) else {
        XCTFail("not hex: \(s.prefix(40))", file: file, line: line)
        return []
    }
    return b
}

final class HChainVectorsTests: XCTestCase {
    func testTheCopyIsTheLockedFile() throws {
        let loaded = try HChainVectors.load()
        let (lock, v) = (loaded.lock, loaded.vectors)
        let sha = SHA256.hash(data: loaded.bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sha, lock["sha256"])
        XCTAssertEqual(v.name, "meshsat-h-chain-vectors")
        XCTAssertEqual(v.version, 1)
        XCTAssertEqual(v.spec.protocolVersion, "01")
        print("h-chain vectors: bridge \(lock["bridge_commit"] ?? "?"), sha256 \(lock["sha256"] ?? "?")")
    }

    func testTheMeshtasticTableIsTheBridgesInOrderDuplicatesAndAll() throws {
        let table = try HChainVectors.load().vectors.dictionaries.meshtastic
        XCTAssertEqual(table.words.count, 256)
        XCTAssertEqual(table.words, Smaz2Bytes.meshtasticWords)
        // Not deduplicated: the Bridge's table repeats some words, and the compressor indexes each by its last entry.
        XCTAssertLessThan(Set(table.words).count, table.words.count)
        XCTAssertEqual(table.bigrams.count, 256)
        XCTAssertEqual(table.bigrams, Smaz2Bytes.meshtasticBigramTable)
    }

    func testSmaz2WithEitherTableMatchesTheBridgeBothWays() throws {
        let vectors = try HChainVectors.load().vectors.smaz2
        XCTAssertGreaterThanOrEqual(vectors.count, 30)
        var lossy = 0
        for x in vectors {
            let name = "\(x.name) (\(x.dict))"
            let dict = Smaz2Dict.of(x.dict)
            let text = hexBytes(x.textHex)
            XCTAssertEqual(Array(x.text.utf8), text, "\(name) text_hex")
            let z = hexBytes(x.compressedHex)
            XCTAssertEqual(Hex.encode(Smaz2Bytes.compress(text, dict: dict)), x.compressedHex, "\(name) compress")
            // What the Bridge's own decompressor returns, byte for byte, the text wherever it round trips.
            let back = try Smaz2Bytes.decompress(z, dict: dict)
            XCTAssertEqual(Hex.encode(back), x.decompressedHex, "\(name) decompress")
            if back != text {
                lossy += 1
                // Only the default table (lib-x) loses, and only bytes 0x01-0x08; the kits' table never does.
                XCTAssertEqual(dict, .default, "\(name) loses")
                XCTAssertTrue(text.contains { (1...8).contains($0) }, "\(name) loses")
            }
        }
        XCTAssertEqual(lossy, 1, "the one known lossy vector, default control_bytes")
    }

    /// The SMS codec (Smaz2, on String) compresses as the Bridge and reads every default-table
    /// vector back as the Bridge's own output, Greek, accented and emoji text included. [MESHSAT-1628]
    func testTheSmsCodecCompressesAsTheBridgeAndReadsItsMultibyteTextBack() throws {
        var checkedBack = 0, multibyte = 0
        for x in try HChainVectors.load().vectors.smaz2 where x.dict == "default" {
            XCTAssertEqual(Hex.encode(Smaz2.compress(x.text)), x.compressedHex, x.name)
            guard !x.text.isEmpty else { continue }
            let decompressed = hexBytes(x.decompressedHex)
            XCTAssertEqual(Smaz2.decompress(hexBytes(x.compressedHex)), String(decoding: decompressed, as: UTF8.self), x.name)
            checkedBack += 1
            if decompressed.contains(where: { $0 >= 0x80 }) { multibyte += 1 }
        }
        XCTAssertGreaterThanOrEqual(checkedBack, 15)
        XCTAssertGreaterThanOrEqual(multibyte, 3, "Greek, accented and emoji vectors")
    }

    func testSmaz2gFramesMatchTheBridgeBothWaysATieStaysRaw() throws {
        let vectors = try HChainVectors.load().vectors.smaz2g
        XCTAssertGreaterThanOrEqual(vectors.count, 30)
        var ties = 0
        for x in vectors {
            let dict = Smaz2Dict.of(x.dict)
            let text = hexBytes(x.textHex)
            let frame = Smaz2g.encode(text, dict: dict)
            XCTAssertEqual(Hex.encode(frame), x.frameHex, "\(x.name) frame")
            XCTAssertEqual(frame.first, x.mode == "raw" ? Smaz2g.modeRaw : Smaz2g.modeSmaz2, "\(x.name) mode")
            XCTAssertEqual(try Smaz2g.decode(frame, dict: dict), text, "\(x.name) decode")
            // Through the app's pipeline as well, the step the chain uses.
            let step = [TransformSpec(type: "smaz2g", params: ["dict": x.dict])]
            XCTAssertEqual(try TransformPipeline().applyEgress(text, step), frame, "\(x.name) pipeline")
            XCTAssertEqual(try TransformPipeline().applyIngress(frame, step), text, "\(x.name) pipeline back")
            if x.mode == "raw", !text.isEmpty, Smaz2Bytes.compress(text, dict: dict).count == text.count { ties += 1 }
        }
        XCTAssertGreaterThanOrEqual(ties, 1, "the vectors hold a size tie")
        XCTAssertEqual(Hex.encode(Smaz2g.encode([], dict: .meshtastic)), "00", "empty text is the one-byte raw frame")
    }

    func testMalformedFramesAreRefusedWithoutACrash() throws {
        let vectors = try HChainVectors.load().vectors.smaz2gReject
        XCTAssertGreaterThanOrEqual(vectors.count, 9)
        for x in vectors {
            let bytes = hexBytes(x.bytesHex)
            XCTAssertThrowsError(try Smaz2g.decode(bytes, dict: Smaz2Dict.of(x.dict)), "\(x.name) decoded") { error in
                XCTAssertTrue(error is Smaz2Error, "\(x.name): \(error)")
            }
            let step = [TransformSpec(type: "smaz2g", params: ["dict": x.dict])]
            XCTAssertThrowsError(try TransformPipeline().applyIngress(bytes, step), "\(x.name) decoded in the pipeline") { error in
                XCTAssertTrue(error is TransformError, "\(x.name): \(error)")
            }
        }
    }

    func testTheWholeHChainMatchesTheBridgeByteForByteBothWays() throws {
        let vectors = try HChainVectors.load().vectors.envelopes
        XCTAssertGreaterThanOrEqual(vectors.count, 8)
        var nonceOpensWithVersion = 0
        for x in vectors {
            let nonce = hexBytes(x.nonceHex)
            let text = Array(x.text.utf8)
            let wire = hexBytes(x.wireHex)
            if nonce.first == SatelliteChain.protocolVersion { nonceOpensWithVersion += 1 }

            // App to Bridge: the app's wire, with the vector's nonce, is the Bridge's wire. The kits'
            // chain is the Meshtastic table; a vector on another table runs its own steps.
            let pipeline = TransformPipeline()
            pipeline.fixedNonce = nonce
            let steps = [
                TransformSpec(type: "smaz2g", params: ["dict": x.dict]), TransformSpec(type: "encrypt", params: ["key": x.keyHex]),
            ]
            let sealed =
                x.dict == "meshtastic"
                ? try SatelliteChain.seal(text, keyHex: x.keyHex, pipeline: pipeline)
                : [SatelliteChain.protocolVersion] + (try pipeline.applyEgress(text, steps))
            XCTAssertEqual(Hex.encode(sealed), x.wireHex, "\(x.name) wire")
            XCTAssertEqual(sealed.count, x.wireLen, "\(x.name) wire_len")
            let z = Smaz2Bytes.compress(text, dict: Smaz2Dict.of(x.dict)).count
            XCTAssertEqual(sealed.count, SatelliteChain.overhead + min(text.count, z), "\(x.name) 30 + min(n, z)")

            // Bridge to app: the Bridge's wire opens to the text, and on the kits' table reads as a sealed text.
            XCTAssertEqual(try TransformPipeline().applyIngress(Array(wire.dropFirst()), steps), text, "\(x.name) open")
            if x.dict == "meshtastic" {
                XCTAssertEqual(try SatelliteChain.open(wire, keyHex: x.keyHex), text, "\(x.name) open")
                XCTAssertEqual(SatelliteChain.readMt(wire, keyHex: x.keyHex), .text(x.text, sealed: true, chain: .h), "\(x.name) readMt")
            }

            // The version byte once: the nonce follows it, whatever its first byte.
            XCTAssertEqual(wire.first, SatelliteChain.protocolVersion)
            XCTAssertEqual(Array(wire[1..<13]), nonce, "\(x.name) nonce after the version byte")
        }
        XCTAssertGreaterThanOrEqual(nonceOpensWithVersion, 1, "a vector's nonce starts with 0x01")
    }

    func testAWireThatDoesNotOpenIsRefusedAndNeverShownAsText() throws {
        let vectors = try HChainVectors.load().vectors.envelopeReject
        XCTAssertGreaterThanOrEqual(vectors.count, 7)
        for x in vectors {
            let bytes = hexBytes(x.bytesHex)
            XCTAssertThrowsError(try SatelliteChain.open(bytes, keyHex: x.keyHex), "\(x.name) opened") { error in
                XCTAssertTrue(error is TransformError, "\(x.name): \(error)")
            }
            let mt = SatelliteChain.readMt(bytes, keyHex: x.keyHex)
            // A wire without the version byte is not MeshSat's: a plain text as before, not a decode.
            if bytes.first == SatelliteChain.protocolVersion {
                guard case .unopened = mt else { return XCTFail("\(x.name) read as \(mt)") }
            } else {
                guard case .text(_, sealed: false, _) = mt else { return XCTFail("\(x.name) read as \(mt)") }
            }
        }
    }

    func testTheRollbackChainMatchesTheBridgeByteForByteBothWaysAsParallaxRunsIt() throws {
        let v = try HChainVectors.load().vectors
        XCTAssertTrue(v.spec.rollbackEgress.hasPrefix("[{\"type\":\"smaz2\"},"), "the spec names parallax's chain, smaz2 with no dict")
        XCTAssertGreaterThanOrEqual(v.legacyEnvelopes.count, 6)
        var nonceOpensWithVersion = 0
        for x in v.legacyEnvelopes {
            XCTAssertEqual(x.dict, "default", "\(x.name) table")
            let nonce = hexBytes(x.nonceHex)
            let text = Array(x.text.utf8)
            let wire = hexBytes(x.wireHex)
            if nonce.first == SatelliteChain.protocolVersion { nonceOpensWithVersion += 1 }

            // App to Bridge.
            let pipeline = TransformPipeline()
            pipeline.fixedNonce = nonce
            let sealed = try SatelliteChain.seal(text, keyHex: x.keyHex, pipeline: pipeline, chain: .legacy)
            XCTAssertEqual(Hex.encode(sealed), x.wireHex, "\(x.name) wire")
            XCTAssertEqual(sealed.count, x.wireLen, "\(x.name) wire_len")

            // Bridge to app, on the legacy setting and, while the ends switch, on the H setting too.
            XCTAssertEqual(try SatelliteChain.open(wire, keyHex: x.keyHex, chain: .legacy), text, "\(x.name) open")
            let want = SatelliteChain.MtMessage.text(x.text, sealed: true, chain: .legacy)
            XCTAssertEqual(SatelliteChain.readMt(wire, keyHex: x.keyHex, preferred: .legacy), want, "\(x.name) readMt legacy")
            XCTAssertEqual(SatelliteChain.readMt(wire, keyHex: x.keyHex, preferred: .h), want, "\(x.name) readMt from H")
            // One version byte, then base64 text.
            XCTAssertEqual(wire.first, SatelliteChain.protocolVersion)
            let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8)
            XCTAssertTrue(wire.dropFirst().allSatisfy { alphabet.contains($0) }, "\(x.name) base64 after the version byte")
        }
        XCTAssertGreaterThanOrEqual(nonceOpensWithVersion, 1, "a legacy vector's nonce starts with 0x01")
    }

    func testARollbackWireThatDoesNotOpenIsRefusedOnEitherSetting() throws {
        let vectors = try HChainVectors.load().vectors.legacyReject
        XCTAssertGreaterThanOrEqual(vectors.count, 5)
        for x in vectors {
            let bytes = hexBytes(x.bytesHex)
            XCTAssertThrowsError(try SatelliteChain.open(bytes, keyHex: x.keyHex, chain: .legacy), "\(x.name) opened") { error in
                XCTAssertTrue(error is TransformError, "\(x.name): \(error)")
            }
            for preferred in SatelliteChain.Chain.allCases {
                let mt = SatelliteChain.readMt(bytes, keyHex: x.keyHex, preferred: preferred)
                guard case .unopened = mt else { return XCTFail("\(x.name) on \(preferred) read as \(mt)") }
            }
        }
    }
}
