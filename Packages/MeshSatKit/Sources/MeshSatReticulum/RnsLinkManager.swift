// Mirrors reticulum/RnsLinkManager.kt: the two-packet Reticulum handshake.
//   1. Initiator sends LINKREQUEST to the responder.
//   2. Responder answers with a signed PROOF.
// After ECDH the symmetric keys come from HKDF with the link id as salt.
import Crypto
import Foundation
import MeshSatCrypto
import MeshSatWire

public final class RnsLinkManager: @unchecked Sendable {
    private let identity: Identity
    private let localDestHash: [UInt8]
    private let lock = NSLock()
    private var links: [String: RnsLink] = [:]
    private var pending: [String: PendingLink] = [:]

    /// Ephemeral state for a pending outbound link request (the key as its raw seed: Sendable).
    private struct PendingLink {
        let linkId: [UInt8]
        let destHash: [UInt8]
        let ephSeed: [UInt8]
        let signalling: RnsSignalling
    }

    public init(identity: Identity, localDestHash: [UInt8]) {
        self.identity = identity
        self.localDestHash = localDestHash
    }

    /// link_id = truncated_hash(request_data), 16 bytes.
    public static func computeLinkId(_ requestData: [UInt8]) -> [UInt8] { RnsDestination.truncatedHash(requestData) }

    /// A LINKREQUEST packet for `destHash`, ready to send.
    public func initiateLink(destHash: [UInt8], encryptionMode: RnsEncryptionMode = .aes256Gcm) -> [UInt8] {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let signalling = RnsSignalling(encryptionMode: encryptionMode)
        let req = RnsLinkRequest(
            ephemeralPub: Array(eph.publicKey.rawRepresentation), signingPub: identity.signingPubRaw, signalling: signalling)
        let reqData = req.marshal()
        let packet = RnsPacket.linkRequest(destHash: destHash, requestData: reqData)
        let linkId = Self.computeLinkId(reqData)
        lock.lock()
        pending[Hex.encode(linkId)] = PendingLink(
            linkId: linkId, destHash: destHash, ephSeed: Array(eph.rawRepresentation), signalling: signalling)
        lock.unlock()
        return packet.marshal()
    }

    /// An incoming link request addressed to us: the PROOF packet to send back, or nil.
    public func handleLinkRequest(_ raw: [UInt8]) -> [UInt8]? {
        guard let packet = try? RnsPacket.unmarshal(raw), packet.packetType == RnsConstants.packetLinkRequest,
            packet.destHash == localDestHash, let req = try? RnsLinkRequest.unmarshal(packet.data)
        else { return nil }
        let linkId = Self.computeLinkId(packet.data)
        let key = Hex.encode(linkId)
        lock.lock()
        let exists = links[key] != nil
        lock.unlock()
        if exists { return nil }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephPubRaw = Array(eph.publicKey.rawRepresentation)
        guard let sharedSecret = Identity.ecdh(eph, remotePublicRaw: req.ephemeralPub) else { return nil }
        let mode = req.signalling.encryptionMode
        let respSignalling = RnsSignalling(encryptionMode: mode)
        let signature = identity.sign(linkId + ephPubRaw + identity.signingPubRaw + respSignalling.marshal())
        let keys = RnsHkdf.deriveLinkKeys(sharedSecret: sharedSecret, salt: linkId, isInitiator: false)
        let link = RnsLink(
            id: linkId, destHash: [UInt8](repeating: 0, count: RnsConstants.destHashLen), state: .active, encryptionMode: mode,
            sharedSecret: sharedSecret, sendKey: keys.send, recvKey: keys.recv, isInitiator: false)
        lock.lock()
        links[key] = link
        lock.unlock()
        let proof = RnsLinkProof(signature: signature, ephemeralPub: ephPubRaw, signalling: respSignalling)
        return RnsPacket.proof(destHash: linkId, proofData: proof.marshal()).marshal()
    }

    /// An incoming link proof for our request: the established link, or nil when it fails.
    public func handleLinkProof(_ raw: [UInt8], signingPubRaw: [UInt8]) -> RnsLink? {
        guard let packet = try? RnsPacket.unmarshal(raw), packet.packetType == RnsConstants.packetProof,
            let proof = try? RnsLinkProof.unmarshal(packet.data)
        else { return nil }
        let key = Hex.encode(packet.destHash)  // the proof's dest hash IS the link id
        lock.lock()
        let pendingLink = pending.removeValue(forKey: key)
        lock.unlock()
        guard let pendingLink else { return nil }
        let signable = pendingLink.linkId + proof.ephemeralPub + signingPubRaw + proof.signalling.marshal()
        guard Identity.verifyWithRaw(signingPubRaw, data: signable, signature: proof.signature) else { return nil }
        guard let ephPrivate = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: pendingLink.ephSeed),
            let sharedSecret = Identity.ecdh(ephPrivate, remotePublicRaw: proof.ephemeralPub)
        else { return nil }
        let mode = proof.signalling.encryptionMode
        let keys = RnsHkdf.deriveLinkKeys(sharedSecret: sharedSecret, salt: pendingLink.linkId, isInitiator: true)
        let link = RnsLink(
            id: pendingLink.linkId, destHash: pendingLink.destHash, state: .active, encryptionMode: mode, sharedSecret: sharedSecret,
            sendKey: keys.send, recvKey: keys.recv, isInitiator: true)
        lock.lock()
        links[key] = link
        lock.unlock()
        return link
    }

    public func getLink(_ linkId: [UInt8]) -> RnsLink? {
        lock.lock()
        defer { lock.unlock() }
        return links[Hex.encode(linkId)]
    }

    public func activeLinks() -> [RnsLink] {
        lock.lock()
        defer { lock.unlock() }
        return links.values.filter { $0.state == .active }
    }

    public func closeLink(_ linkId: [UInt8]) {
        let key = Hex.encode(linkId)
        lock.lock()
        links[key]?.state = .closed
        links.removeValue(forKey: key)
        pending.removeValue(forKey: key)
        lock.unlock()
    }

    /// (pending, active) counts.
    public func linkCount() -> (pending: Int, links: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (pending.count, links.count)
    }
}
