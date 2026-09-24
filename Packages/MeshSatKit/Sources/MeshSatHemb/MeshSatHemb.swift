// MeshSatHemb: HeMB bonding (hemb/), the standalone RLNC (rlnc/) and Reed-Solomon FEC (fec/)
// of MeshSat Android. Wire formats follow the Bridge's internal/hemb (frame magic "HM",
// GF(256) 0x11B/0x03) and are pinned by the Go-produced byte arrays in the tests.

public enum MeshSatHemb {
    public static let module = "MeshSatHemb"
    /// The two bytes every HeMB frame starts with (hemb/HembFrame.kt).
    public static let frameMagic: [UInt8] = [0x48, 0x4D]  // "HM"
}
