// MeshSatSatellite: mirrors satellite/ in MeshSat Android (Sgp4, TleParser, TleFetcher,
// PassPredictor, PassScheduler). Passes are predicted on the phone from the bundled orbit
// data, refreshed from CelesTrak when there is internet.

public enum MeshSatSatellite {
    public static let module = "MeshSatSatellite"
}
