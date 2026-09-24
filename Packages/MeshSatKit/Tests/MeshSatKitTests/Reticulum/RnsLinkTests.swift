// Ports RnsLinkTest.kt (HKDF, signalling, link request and proof data, link encryption), and
// adds the full handshake through two link managers, which Android tests only on a device.
import XCTest

@testable import MeshSatCrypto
@testable import MeshSatReticulum

final class RnsLinkTests: XCTestCase {
    private let zero16 = [UInt8](repeating: 0, count: 16)
    private let zero32 = [UInt8](repeating: 0, count: 32)

    func testHkdf() {
        XCTAssertEqual(RnsHkdf.extract(salt: zero16, ikm: zero32).count, 32)
        let prk = RnsHkdf.extract(salt: nil, ikm: (0..<32).map { UInt8($0) })
        XCTAssertEqual(RnsHkdf.expand(prk: prk, info: nil, length: 64).count, 64)
        let secret = (0..<32).map { UInt8($0) }
        let salt = (0..<16).map { UInt8(0xFF - $0) }
        XCTAssertEqual(RnsHkdf.derive(length: 64, from: secret, salt: salt), RnsHkdf.derive(length: 64, from: secret, salt: salt))
        XCTAssertNotEqual(
            RnsHkdf.derive(length: 32, from: secret, salt: [UInt8](repeating: 1, count: 16)),
            RnsHkdf.derive(length: 32, from: secret, salt: [UInt8](repeating: 2, count: 16)))
        let keys = RnsHkdf.deriveLinkKeys(sharedSecret: secret, salt: zero16, isInitiator: true)
        XCTAssertEqual(keys.send.count, 32)
        XCTAssertEqual(keys.recv.count, 32)
        let aa = [UInt8](repeating: 0xAA, count: 16)
        let i = RnsHkdf.deriveLinkKeys(sharedSecret: secret, salt: aa, isInitiator: true)
        let r = RnsHkdf.deriveLinkKeys(sharedSecret: secret, salt: aa, isInitiator: false)
        XCTAssertEqual(i.send, r.recv)
        XCTAssertEqual(i.recv, r.send)
        XCTAssertEqual(RnsHkdf.derive(length: 32, from: secret, salt: nil), RnsHkdf.derive(length: 32, from: secret, salt: zero32))
        XCTAssertNotEqual(
            RnsHkdf.derive(length: 32, from: secret, salt: zero16, context: Array("info1".utf8)),
            RnsHkdf.derive(length: 32, from: secret, salt: zero16, context: Array("info2".utf8)))
    }

    /// RFC 5869 test case 1, so the HMAC order is provably the standard's.
    func testHkdfRfc5869Vector() {
        let ikm = [UInt8](repeating: 0x0b, count: 22)
        let salt: [UInt8] = (0x00...0x0c).map { UInt8($0) }
        let info: [UInt8] = (0xf0...0xf9).map { UInt8($0) }
        let okm = RnsHkdf.derive(length: 42, from: ikm, salt: salt, context: info)
        let expected =
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
        XCTAssertEqual(okm.map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testSignalling() throws {
        let data = RnsSignalling(mtu: 340, encryptionMode: .aes256Gcm).marshal()
        XCTAssertEqual(data.count, 3)
        let parsed = try RnsSignalling.unmarshal(data)
        XCTAssertEqual(parsed.mtu, 340)
        XCTAssertEqual(parsed.encryptionMode, .aes256Gcm)
        XCTAssertEqual(RnsSignalling().mtu, RnsConstants.mtu)
        XCTAssertEqual(RnsSignalling().encryptionMode, .aes256Gcm)
        XCTAssertEqual(try RnsSignalling.unmarshal(RnsSignalling(encryptionMode: .aes256Cbc).marshal()).encryptionMode, .aes256Cbc)
        XCTAssertEqual(try RnsSignalling.unmarshal([0, 0, 1]).mtu, RnsConstants.mtu)
    }

    func testLinkRequestAndProofData() throws {
        let ephPub = (0..<32).map { UInt8($0) }
        let sigPub = (0..<32).map { UInt8(32 + $0) }
        let req = RnsLinkRequest(ephemeralPub: ephPub, signingPub: sigPub, signalling: RnsSignalling())
        let data = req.marshal()
        XCTAssertEqual(data.count, 67)
        let parsed = try RnsLinkRequest.unmarshal(data)
        XCTAssertEqual(parsed.ephemeralPub, ephPub)
        XCTAssertEqual(parsed.signingPub, sigPub)
        XCTAssertEqual(parsed.signalling.mtu, RnsConstants.mtu)
        let destHash = [UInt8](repeating: 0xAA, count: 16)
        let packet = try RnsPacket.unmarshal(RnsPacket.linkRequest(destHash: destHash, requestData: data).marshal())
        XCTAssertEqual(packet.packetType, RnsConstants.packetLinkRequest)
        XCTAssertEqual(packet.destHash, destHash)
        XCTAssertEqual(try RnsLinkRequest.unmarshal(packet.data).signalling.mtu, RnsConstants.mtu)

        let sig = (0..<64).map { UInt8($0) }
        let ephPub2 = (0..<32).map { UInt8(64 + $0) }
        let proofData = RnsLinkProof(signature: sig, ephemeralPub: ephPub2, signalling: RnsSignalling()).marshal()
        XCTAssertEqual(proofData.count, 99)
        let parsedProof = try RnsLinkProof.unmarshal(proofData)
        XCTAssertEqual(parsedProof.signature, sig)
        XCTAssertEqual(parsedProof.ephemeralPub, ephPub2)
        let linkId = [UInt8](repeating: 0xBB, count: 16)
        let proofPacket = try RnsPacket.unmarshal(RnsPacket.proof(destHash: linkId, proofData: proofData).marshal())
        XCTAssertEqual(proofPacket.packetType, RnsConstants.packetProof)
        XCTAssertEqual(proofPacket.destHash, linkId)
    }

    func testLinkIds() {
        XCTAssertEqual(RnsLinkManager.computeLinkId([UInt8](repeating: 0, count: 67)).count, 16)
        let req = (0..<67).map { UInt8($0) }
        XCTAssertEqual(RnsLinkManager.computeLinkId(req), RnsLinkManager.computeLinkId(req))
        XCTAssertNotEqual(
            RnsLinkManager.computeLinkId([UInt8](repeating: 1, count: 67)), RnsLinkManager.computeLinkId([UInt8](repeating: 2, count: 67)))
        XCTAssertEqual(RnsLink.linkIdLen, 16)
        XCTAssertEqual(RnsLinkRequest.size, 67)
        XCTAssertEqual(RnsLinkProof.size, 99)
    }

    private func pair(_ mode: RnsEncryptionMode) -> (RnsLink, RnsLink) {
        let key1 = (0..<32).map { UInt8($0) }
        let key2 = (0..<32).map { UInt8(32 + $0) }
        let sender = RnsLink(
            id: zero16, destHash: zero16, state: .active, encryptionMode: mode, sendKey: key1, recvKey: key2, isInitiator: true)
        let receiver = RnsLink(
            id: zero16, destHash: zero16, state: .active, encryptionMode: mode, sendKey: key2, recvKey: key1, isInitiator: false)
        return (sender, receiver)
    }

    func testGcmRoundTrip() throws {
        let (s, r) = pair(.aes256Gcm)
        let plaintext = Array("hello reticulum link".utf8)
        XCTAssertEqual(try r.decrypt(try s.encrypt(plaintext)), plaintext)
        let ct = try s.encrypt(Array("test".utf8))
        XCTAssertGreaterThanOrEqual(ct.count, 12 + 4 + 16)
        XCTAssertNotEqual(try s.encrypt(Array("same".utf8)), try s.encrypt(Array("same".utf8)))
        // The nonce is the send counter, big-endian, in the first 8 of 12 bytes (Android's putLong).
        let first = try pair(.aes256Gcm).0.encrypt([1])
        XCTAssertEqual(Array(first.prefix(12)), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testCbcRoundTrip() throws {
        let (s, r) = pair(.aes256Cbc)
        let plaintext = Array("hello CBC mode".utf8)
        XCTAssertEqual(try r.decrypt(try s.encrypt(plaintext)), plaintext)
        let ct = try s.encrypt(Array("test".utf8))
        XCTAssertGreaterThanOrEqual(ct.count, 16 + 16)
        // PKCS#7 padded: 16-byte IV + a whole number of blocks.
        XCTAssertEqual((ct.count - 16) % 16, 0)
    }

    func testAnInactiveLinkRefusesToEncrypt() {
        let link = RnsLink(id: zero16, destHash: zero16, state: .pending, sendKey: zero32, recvKey: zero32, isInitiator: true)
        XCTAssertThrowsError(try link.encrypt([1]))
    }

    func testHandshakeSizes() {
        let req = RnsPacket.linkRequest(destHash: zero16, requestData: [UInt8](repeating: 0, count: RnsLinkRequest.size))
        XCTAssertTrue(RnsPacket.validateSize(req))
        XCTAssertEqual(req.wireSize(), 85)
        let proof = RnsPacket.proof(destHash: zero16, proofData: [UInt8](repeating: 0, count: RnsLinkProof.size))
        XCTAssertTrue(RnsPacket.validateSize(proof))
        XCTAssertEqual(proof.wireSize(), 117)
        XCTAssertLessThanOrEqual(85 + 117, 340)
    }

    /// The whole handshake: A asks B, B proves, A verifies, and both encrypt for each other.
    func testFullHandshakeBetweenTwoNodes() throws {
        let a = Identity.generate()
        let b = Identity.generate()
        let aDest = RnsDestination.computeDestHash(encryptionPub: a.encryptionPubRaw, signingPub: a.signingPubRaw)
        let bDest = RnsDestination.computeDestHash(encryptionPub: b.encryptionPubRaw, signingPub: b.signingPubRaw)
        let aLinks = RnsLinkManager(identity: a, localDestHash: aDest)
        let bLinks = RnsLinkManager(identity: b, localDestHash: bDest)
        let request = aLinks.initiateLink(destHash: bDest)
        XCTAssertEqual(aLinks.linkCount().pending, 1)
        let proof = try XCTUnwrap(bLinks.handleLinkRequest(request))
        XCTAssertEqual(bLinks.linkCount().links, 1)
        XCTAssertNil(bLinks.handleLinkRequest(request), "the same request twice makes no second link")
        let aLink = try XCTUnwrap(aLinks.handleLinkProof(proof, signingPubRaw: b.signingPubRaw))
        XCTAssertEqual(aLinks.linkCount().pending, 0)
        XCTAssertEqual(aLinks.linkCount().links, 1)
        XCTAssertEqual(aLink.destHash, bDest)
        XCTAssertTrue(aLink.isInitiator)
        let bLink = try XCTUnwrap(bLinks.getLink(aLink.id))
        XCTAssertEqual(bLink.encryptionMode, .aes256Gcm)
        XCTAssertEqual(aLink.sharedSecret, bLink.sharedSecret)
        XCTAssertEqual(try bLink.decrypt(try aLink.encrypt(Array("a to b".utf8))), Array("a to b".utf8))
        XCTAssertEqual(try aLink.decrypt(try bLink.encrypt(Array("b to a".utf8))), Array("b to a".utf8))
        XCTAssertEqual(aLinks.activeLinks().count, 1)
        aLinks.closeLink(aLink.id)
        XCTAssertEqual(aLinks.activeLinks().count, 0)
        XCTAssertEqual(aLink.state, .closed)
    }

    func testAProofSignedByTheWrongKeyIsRefused() throws {
        let a = Identity.generate()
        let b = Identity.generate()
        let bDest = RnsDestination.computeDestHash(encryptionPub: b.encryptionPubRaw, signingPub: b.signingPubRaw)
        let aLinks = RnsLinkManager(identity: a, localDestHash: [UInt8](repeating: 1, count: 16))
        let bLinks = RnsLinkManager(identity: b, localDestHash: bDest)
        let proof = try XCTUnwrap(bLinks.handleLinkRequest(aLinks.initiateLink(destHash: bDest, encryptionMode: .aes256Cbc)))
        XCTAssertNil(aLinks.handleLinkProof(proof, signingPubRaw: Identity.generate().signingPubRaw))
        XCTAssertEqual(aLinks.linkCount().pending, 0, "a failed proof consumes the pending request")
        XCTAssertEqual(aLinks.linkCount().links, 0)
    }

    func testLinkRequestForSomeoneElseIsIgnored() {
        let b = Identity.generate()
        let bLinks = RnsLinkManager(identity: b, localDestHash: [UInt8](repeating: 7, count: 16))
        let aLinks = RnsLinkManager(identity: Identity.generate(), localDestHash: [UInt8](repeating: 1, count: 16))
        XCTAssertNil(bLinks.handleLinkRequest(aLinks.initiateLink(destHash: [UInt8](repeating: 9, count: 16))))
    }
}

final class IdentityTests: XCTestCase {
    final class MemoryStore: IdentityStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func get(_ key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }
        func set(_ key: String, _ value: String) {
            lock.lock()
            values[key] = value
            lock.unlock()
        }
    }

    func testGenerateSignVerify() {
        let id = Identity.generate()
        XCTAssertEqual(id.signingPubRaw.count, 32)
        XCTAssertEqual(id.encryptionPubRaw.count, 32)
        XCTAssertEqual(id.destHash.count, 16)
        XCTAssertEqual(id.destHashHex.count, 32)
        let sig = id.sign(Array("hello".utf8))
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(id.verify(Array("hello".utf8), signature: sig))
        XCTAssertFalse(id.verify(Array("hellp".utf8), signature: sig))
        XCTAssertTrue(Identity.verifyWithRaw(id.signingPubRaw, data: Array("hello".utf8), signature: sig))
        XCTAssertFalse(Identity.verifyWithRaw([1, 2, 3], data: Array("hello".utf8), signature: sig))
    }

    func testDestHashOrderIsSigningThenEncryption() {
        let id = Identity.generate()
        XCTAssertEqual(id.destHash, Identity.computeDestHash(signingPubRaw: id.signingPubRaw, encryptionPubRaw: id.encryptionPubRaw))
        XCTAssertNotEqual(id.destHash, Identity.computeDestHash(signingPubRaw: id.encryptionPubRaw, encryptionPubRaw: id.signingPubRaw))
    }

    func testLoadOrGeneratePersistsAndReloads() {
        let store = MemoryStore()
        let first = Identity.loadOrGenerate(store: store)
        XCTAssertNotNil(store.get("routing_signing_key_private"))
        XCTAssertNotNil(store.get("routing_encryption_key_public"))
        let second = Identity.loadOrGenerate(store: store)
        XCTAssertEqual(first.destHash, second.destHash)
        XCTAssertEqual(first.signingPubRaw, second.signingPubRaw)
        store.set("routing_signing_key_private", "not hex")
        let third = Identity.loadOrGenerate(store: store)
        XCTAssertNotEqual(first.destHash, third.destHash, "a corrupt store means a new identity, as on Android")
    }

    func testEcdhAgrees() {
        let a = Identity.generate()
        let b = Identity.generate()
        XCTAssertEqual(a.sharedSecret(with: b.encryptionPubRaw), b.sharedSecret(with: a.encryptionPubRaw))
        XCTAssertEqual(a.sharedSecret(with: b.encryptionPubRaw)?.count, 32)
        XCTAssertNil(a.sharedSecret(with: [1, 2]))
    }
}
