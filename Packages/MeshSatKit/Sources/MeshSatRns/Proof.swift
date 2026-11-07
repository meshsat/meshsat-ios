// Mirrors the Proof object of rns/Wire.kt (the Bridge's internal/reticulum/proof.go): the
// PROOF packet that answers a delivered single-destination packet (RNS/Packet.py's
// PacketReceipt), in its implicit (signature only) and explicit (hash || signature) forms, and
// its destination, the truncated hash of the packet it proves. Pinned by the proof.* vectors.
import Foundation

public enum Proof {
    public static let implicitLen = Rns.sigLen
    public static let explicitLen = Rns.fullHashLen + Rns.sigLen

    /// The HEADER_1 PROOF packet for `provedRaw`, addressed to its truncated hash.
    public static func packet(provedRaw: [UInt8], proofData: [UInt8]) throws -> [UInt8] {
        try Header(
            headerType: Rns.header1, destType: Rns.destSingle, packetType: Rns.packetProof,
            destHash: Header.truncatedPacketHash(provedRaw), context: Rns.ctxNone, data: proofData
        ).pack()
    }

    /// True when `proofData` proves `packetHash` under `sigPub`, in either form (PacketReceipt.validate_proof).
    public static func validate(_ proofData: [UInt8], packetHash: [UInt8], sigPub: [UInt8]) -> Bool {
        let sig: [UInt8]
        switch proofData.count {
        case implicitLen:
            sig = proofData
        case explicitLen:
            guard Array(proofData[0..<Rns.fullHashLen]) == packetHash else { return false }
            sig = Array(proofData[Rns.fullHashLen..<explicitLen])
        default:
            return false
        }
        return RnsIdentity.verifySignature(sigPub: sigPub, data: packetHash, signature: sig)
    }
}
