// Mirrors SmsWireV2Test.kt (r40 review R40-R1): the app SMS wire v2 against the Bridge's shared
// vectors, the copy Fixtures/smswire/vectors.lock names. This app sends every frame byte for byte
// as the Bridge does, encrypted ones included (the vectors' fixed nonces), and reads every one, so
// "sara" and "¡" are two SMS again.
import Crypto
import Foundation
import XCTest

@testable import MeshSatEngine
@testable import MeshSatWire

struct SmsWireV2Vectors: Decodable {
    struct Expect: Decodable {
        let status: String
        let text: String?
        /// A key opened the SMS (the lock), apart from whether it reads (r41 review V1).
        let encrypted: Bool
    }
    struct Vector: Decodable {
        let name: String
        let text: String?
        let mode: Int?
        let codec: Int?
        let frameHex: String?
        let nonceHex: String?
        let wireHex: String
        let sms: String
        let expect: Expect
    }

    let version: Int
    let keyHex: String
    let vectors: [Vector]
    let negative: [Vector]
    let legacy: [Vector]

    struct Locked {
        let lock: [String: String]
        let bytes: Data
        let vectors: SmsWireV2Vectors
    }

    static func load() throws -> Locked {
        let lockURL = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "lock", subdirectory: "Fixtures/smswire"))
        var lock: [String: String] = [:]
        for line in try String(contentsOf: lockURL, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { lock[String(parts[0])] = String(parts[1]) }
        }
        let bytes = try Data(contentsOf: lockURL.deletingLastPathComponent().appendingPathComponent(try XCTUnwrap(lock["file"])))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return Locked(lock: lock, bytes: bytes, vectors: try decoder.decode(SmsWireV2Vectors.self, from: bytes))
    }
}

final class SmsWireV2Tests: XCTestCase {
    private func open(_ key: String) -> ([UInt8]) -> [UInt8]? {
        { try? AesGcmCrypto.decrypt($0, hexKey: key) }
    }

    func testTheCopyIsTheLockedOne() throws {
        let loaded = try SmsWireV2Vectors.load()
        let sha = SHA256.hash(data: loaded.bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sha, loaded.lock["sha256"])
        XCTAssertEqual(loaded.vectors.vectors.count, 28)
        XCTAssertEqual(loaded.vectors.negative.count, 4)
        XCTAssertEqual(loaded.vectors.legacy.count, 4)
    }

    func testEveryVectorReadsAsTypedClearOrSealed() throws {
        let v = try SmsWireV2Vectors.load().vectors
        for c in v.vectors {
            let raw = try XCTUnwrap(Base64Std.decode(c.sms), c.name)
            XCTAssertEqual(
                SmsWireV2.read(raw, open: open(v.keyHex)),
                .text(try XCTUnwrap(c.expect.text), encrypted: c.mode == 1, codec: UInt8(try XCTUnwrap(c.codec))), c.name)
            // And through the receive path the app uses, with a wrong key tried first.
            let d = SmsWire.decode(c.sms, keys: [AesGcmCrypto.generateKey(), v.keyHex])
            XCTAssertEqual(d.text, c.expect.text, c.name)
            XCTAssertEqual(d.wasEncrypted, c.expect.encrypted, c.name)
            XCTAssertEqual(d.wasCompressed, c.codec != Int(SmsWireV2.codecText), c.name)
        }
    }

    func testThisAppSendsEveryVectorByteForByte() throws {
        let v = try SmsWireV2Vectors.load().vectors
        for c in v.vectors {
            let text = try XCTUnwrap(c.text, c.name)
            let frame = SmsWireV2.frame(text, smaz2: true)
            XCTAssertEqual(Hex.encode(frame), c.frameHex, c.name)
            let wire: [UInt8]
            if c.mode == 0 {
                wire = SmsWireV2.wire(frame)
                // The composer's own path: a clear frame goes only when something was compressed.
                let e = SmsWire.encode(text, smaz2: true)
                XCTAssertEqual(e.body, frame[0] == SmsWireV2.codecText ? text : c.sms, c.name)
            } else {
                let nonce = hexBytes(try XCTUnwrap(c.nonceHex))
                wire = try SmsWireV2.wire(frame) { try AesGcmCrypto.encrypt($0, hexKey: v.keyHex, fixedNonce: nonce) }
                // The composer's path draws its own nonce: the frame inside is the vector's.
                let e = SmsWire.encode(text, encryptionKey: v.keyHex, smaz2: true)
                let sent = try XCTUnwrap(Base64Std.decode(e.body))
                XCTAssertEqual(Array(sent.prefix(2)), [SmsWireV2.version, SmsWireV2.modeAesGcm], c.name)
                XCTAssertEqual(try AesGcmCrypto.decrypt(Array(sent.dropFirst(2)), hexKey: v.keyHex), frame, c.name)
                XCTAssertTrue(e.encrypted, c.name)
            }
            XCTAssertEqual(Hex.encode(wire), c.wireHex, c.name)
            XCTAssertEqual(Base64Std.encode(wire), c.sms, c.name)
        }
    }

    func testAFrameThisAppDoesNotReadIsKeptAndASealedOneWithoutItsKeyToo() throws {
        let v = try SmsWireV2Vectors.load().vectors
        for c in v.negative {
            let raw = try XCTUnwrap(Base64Std.decode(c.sms), c.name)
            guard case .kept = SmsWireV2.read(raw, open: open(v.keyHex)) else {
                XCTFail("\(c.name): read \(SmsWireV2.read(raw, open: open(v.keyHex)))")
                continue
            }
            let d = SmsWire.decode(c.sms, keys: [v.keyHex])
            XCTAssertEqual(d.text, c.sms, "\(c.name): shown as it came")
            XCTAssertEqual(d.rawText, "", c.name)
            XCTAssertEqual(d.wasEncrypted, c.expect.encrypted, c.name)
        }
        for c in v.vectors where c.mode == 1 {
            let raw = try XCTUnwrap(Base64Std.decode(c.sms), c.name)
            XCTAssertEqual(SmsWireV2.read(raw, open: { _ in nil }), .kept(encrypted: false), c.name)
            XCTAssertEqual(
                SmsWire.decode(c.sms, keys: [AesGcmCrypto.generateKey()]),
                SmsWire.Decoded(text: c.sms, rawText: "", wasEncrypted: false, wasCompressed: false), c.name)
        }
    }

    /// Version 1 goes to the old rule, whose ambiguity stays: the SMAZ2 c2 a1 an old phone sent for
    /// "sara" is readable "¡", taken as the text, never decompressed.
    func testVersion1GoesToTheOldRule() throws {
        let v = try SmsWireV2Vectors.load().vectors
        for c in v.legacy where c.name != Self.overlap {
            let raw = try XCTUnwrap(Base64Std.decode(c.sms), c.name)
            XCTAssertEqual(SmsWireV2.read(raw, open: open(v.keyHex)), .notV2, c.name)
            if c.expect.encrypted {
                let d = SmsWire.decode(c.sms, keys: [v.keyHex])
                XCTAssertEqual(d.text, c.expect.text, c.name)
                XCTAssertTrue(d.wasEncrypted, c.name)
            }
        }
    }

    /// The r40 review's counterexamples, sent this app's way.
    func testSaraAndSataComeBackAsTyped() throws {
        let key = AesGcmCrypto.generateKey()
        for word in ["sara", "sata"] {
            let frame = SmsWireV2.frame(word, smaz2: true)
            XCTAssertEqual(frame.first, SmsWireV2.codecSmaz2)
            for keyed in [false, true] {
                let e = SmsWire.encode(word, encryptionKey: keyed ? key : nil, smaz2: true)
                XCTAssertEqual(
                    SmsWire.decode(e.body, keys: [key]),
                    SmsWire.Decoded(text: word, rawText: e.body, wasEncrypted: keyed, wasCompressed: true), word)
            }
        }
    }

    /// A version 1 SMS whose random nonce happens to start 02 01 still opens by the old rule.
    func testAVersion1NonceThatLooksLikeV2StillOpens() throws {
        let key = AesGcmCrypto.generateKey()
        let nonce: [UInt8] = [0x02, 0x01] + [UInt8](repeating: 0x33, count: 10)
        let text = "meet at the north bridge at noon"
        let sealed = try AesGcmCrypto.encrypt(Smaz2.compress(text), hexKey: key, fixedNonce: nonce)
        let body = Base64Std.encode(ProtocolVersion.prependVersionByte(sealed))
        XCTAssertEqual(SmsWire.decode(body, keys: [key]).text, text, "leading 01 then nonce 02 01: version 1")
        let bare = Base64Std.encode(sealed)
        XCTAssertEqual(Array((Base64Std.decode(bare) ?? []).prefix(2)), [0x02, 0x01])
        XCTAssertEqual(SmsWire.decode(bare, keys: [key]).text, text, "unversioned, the nonce reads 02 01")
    }

    static let overlap = "legacy_encrypted_clear_header_overlap"

    /// legacy_encrypted_clear_header_overlap (r41 review V2): an unversioned SMS the key opens whose
    /// bytes also parse as a clear v2 frame. The receive path takes the key's reading, with the lock,
    /// a wrong key tried first; without the key the clear frame is all there is.
    func testLegacyEncryptedClearHeaderOverlapReadsAsTheKeyOpensIt() throws {
        let v = try SmsWireV2Vectors.load().vectors
        let c = try XCTUnwrap(v.legacy.first { $0.name == Self.overlap })
        let raw = try XCTUnwrap(Base64Std.decode(c.sms))
        guard case .text(_, encrypted: false, codec: SmsWireV2.codecText) = SmsWireV2.read(raw, open: { _ in nil }) else {
            return XCTFail("the vector does not parse as a clear v2 frame")
        }
        let d = SmsWire.decode(c.sms, keys: [AesGcmCrypto.generateKey(), v.keyHex])
        XCTAssertEqual(d.text, c.expect.text)
        XCTAssertTrue(d.wasEncrypted)
    }
}
