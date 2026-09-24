// MeshSatEngine: mirrors engine/ (Dispatcher, InterfaceManager, TransformPipeline, AckTracker,
// BurstQueue, CreditTracker, DeadManSwitch, GeofenceMonitor, HealthScorer, SatelliteLimits,
// SequenceTracker, SigningService, FailoverResolver), rules/, dedup/, ratelimit/, sos/,
// config/ConfigManager and the record types of data/ in MeshSat Android. Nothing here imports
// an Apple framework: persistence and platform services reach it through protocols.

public enum MeshSatEngine {
    public static let module = "MeshSatEngine"
}
