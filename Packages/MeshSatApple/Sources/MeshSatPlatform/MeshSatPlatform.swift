// MeshSatPlatform: the replacement for service/GatewayService.kt (GatewayController,
// BackgroundCoordinator with the BGTask identifiers below and CLBackgroundActivitySession),
// location/, the Messages composer lane that stands in for sms/, map/ (MBTiles tiles), the
// diagnostics that replace api/LocalApiServer, crash capture and notifications.
import Foundation

public enum MeshSatPlatform {
    public static let module = "MeshSatPlatform"
    /// BGProcessingTask: connect to the Hub, publish birth and health, drain deliveries, refresh TLEs.
    public static let hubSyncTaskIdentifier = "net.meshsat.ios.hubsync"
    /// BGAppRefreshTask: recompute passes and a health ping.
    public static let refreshTaskIdentifier = "net.meshsat.ios.refresh"
    /// The deep link the Hub's provisioning QR carries: meshsat://provision/{bid}/{nonce}?hub=host
    public static let provisionURLScheme = "meshsat"
    public static let provisionURLHost = "provision"
}
