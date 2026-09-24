// Mirrors the keys and defaults of data/SettingsRepository.kt. The key strings are the
// contract: a settings export from one app must read on the other, so every key is spelled
// here once, with the default the Kotlin flow falls back to. The store that reads and writes
// them (UserDefaults + Keychain) is SettingsRepository in MeshSatStore; secrets never go to
// UserDefaults, they are named in `SecretKey` and live in the Keychain, as Android's
// SecureKeyStore keeps them in the Keystore.
import Foundation

/// One setting: its key as Android spells it, and the value it has until set.
public struct Setting<Value: Sendable>: Sendable {
    public let key: String
    public let defaultValue: Value
    public init(_ key: String, default defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

public enum SettingsKey {
    public static let encryptionEnabled = Setting("encryption_enabled", default: false)
    public static let autoDecryptSms = Setting("auto_decrypt_sms", default: true)
    /// Phone number of the Pi's modem.
    public static let meshsatPiPhone = Setting("meshsat_pi_phone", default: "")
    /// The MeshSat node to reconnect to at start and after a drop; empty after Disconnect. On
    /// iOS the value is the peripheral identifier, not a MAC.
    public static let meshtasticBleAddress = Setting("meshtastic_ble_address", default: "")
    /// Take the node's 9603 while connected to a MeshSat node (MESHSAT-1236).
    public static let iridiumNodePipeEnabled = Setting("iridium_node_pipe_enabled", default: true)
    /// The HC-05 of a RockBLOCK 9704; Bluetooth Classic, so never set on iOS.
    public static let iridium9704BtAddress = Setting("iridium9704_bt_address", default: "")
    public static let msvqscEnabled = Setting("msvqsc_enabled", default: false)
    /// "auto" or "2" to "8".
    public static let msvqscStages = Setting("msvqsc_stages", default: "3")
    public static let deadmanEnabled = Setting("deadman_enabled", default: false)
    public static let deadmanTimeoutMin = Setting("deadman_timeout_min", default: "120")
    public static let mqttBrokerUrl = Setting("mqtt_broker_url", default: "")
    public static let mqttDeviceId = Setting("mqtt_device_id", default: "")
    public static let mqttUsername = Setting("mqtt_username", default: "")
    public static let mqttEnabled = Setting("mqtt_enabled", default: false)

    // Per-channel compression: "off", "msvqsc", "smaz2". Mesh is kept only so an old export
    // still imports; mesh text always goes out as typed (MESHSAT-1286).
    public static let compressMesh = Setting("compress_mesh", default: "off")
    public static let compressIridium = Setting("compress_iridium", default: "off")
    public static let compressSms = Setting("compress_sms", default: "off")
    public static let compressMqtt = Setting("compress_mqtt", default: "off")

    public static func compress(channel: String) -> Setting<String>? {
        switch channel {
        case "mesh": compressMesh
        case "iridium": compressIridium
        case "sms": compressSms
        case "mqtt": compressMqtt
        default: nil
        }
    }

    // APRS
    public static let aprsEnabled = Setting("aprs_enabled", default: false)
    public static let aprsCallsign = Setting("aprs_callsign", default: "")
    public static let aprsSsid = Setting("aprs_ssid", default: "10")
    public static let aprsKissHost = Setting("aprs_kiss_host", default: "localhost")
    public static let aprsKissPort = Setting("aprs_kiss_port", default: "8001")
    public static let aprsFrequency = Setting("aprs_frequency_mhz", default: "144.800")
    /// "kiss" or "is" (MESHSAT-230).
    public static let aprsMode = Setting("aprs_mode", default: "kiss")
    public static let aprsIsServer = Setting("aprs_is_server", default: "rotate.aprs2.net")
    public static let aprsIsPort = Setting("aprs_is_port", default: "14580")
    public static let aprsIsPasscode = Setting("aprs_is_passcode", default: "-1")
    public static let aprsIsFilterRange = Setting("aprs_is_filter_range_km", default: "100")
    public static let aprsIsBeaconEnabled = Setting("aprs_is_beacon_enabled", default: false)
    public static let aprsIsBeaconInterval = Setting("aprs_is_beacon_interval_min", default: "10")

    // Reticulum (MESHSAT-268, 394)
    public static let rnsTcpEnabled = Setting("rns_tcp_enabled", default: false)
    public static let rnsTcpHost = Setting("rns_tcp_host", default: "")
    public static let rnsTcpPort = Setting("rns_tcp_port", default: "4242")
    public static let rnsTcpTls = Setting("rns_tcp_tls", default: false)
    public static let rnsAnnounceInterval = Setting("rns_announce_interval_min", default: "10")
    public static let rnsTcpListenPort = Setting("rns_tcp_listen_port", default: "4242")
    public static let rnsTransportEnabled = Setting("rns_transport_enabled", default: true)

    // Offline map
    public static let offlineMapEnabled = Setting("offline_map_enabled", default: true)
    public static let offlineMapFile = Setting("offline_map_file", default: "")

    // Protocol enhancements (MESHSAT-407)
    public static let dtnCustodyEnabled = Setting("dtn_custody_enabled", default: false)
    public static let fecLoraPercent = Setting("fec_lora_percent", default: "30")
    public static let fecSbdPercent = Setting("fec_sbd_percent", default: "20")
    public static let timeSyncEnabled = Setting("time_sync_enabled", default: true)
    public static let rlncEnabled = Setting("rlnc_enabled", default: false)

    // Hub Reporter (MESHSAT-292)
    public static let hubEnabled = Setting("hub_enabled", default: false)
    public static let hubUrl = Setting("hub_url", default: "")
    public static let hubBridgeId = Setting("hub_bridge_id", default: "")
    public static let hubCallsign = Setting("hub_callsign", default: "")
    public static let hubUsername = Setting("hub_username", default: "")
    /// The provisioning bundle's mqtt_topic_prefix (MESHSAT-1324): "meshsat" or "meshsat/{tenant}".
    public static let hubTopicPrefix = Setting("hub_topic_prefix", default: "meshsat")
    /// Seconds, as a string.
    public static let hubHealthInterval = Setting("hub_health_interval", default: "30")
    // Hub relay client (MESHSAT-1157): on by default whenever the Hub is configured.
    public static let hubRelayEnabled = Setting("hub_relay_enabled", default: true)
    /// The bridge id the phone tunnels to. Blank = relay not started.
    public static let hubRelayTarget = Setting("hub_relay_target", default: "")
    /// Hub API base URL override. Blank = derived from the MQTT URL.
    public static let hubRelayUrl = Setting("hub_relay_url", default: "")
    // mTLS (MESHSAT-387); the client key is a secret.
    public static let hubClientCertPem = Setting("hub_client_cert_pem", default: "")
    public static let hubCaCertPem = Setting("hub_ca_cert_pem", default: "")

    // TAK (MESHSAT-451)
    public static let takEnabled = Setting("tak_enabled", default: false)
    public static let takCallsignPrefix = Setting("tak_callsign_prefix", default: "MESHSAT")
    /// Android broadcasts to ATAK by intent; iOS has no such thing, the key is kept for exports.
    public static let takAtakBroadcast = Setting("tak_atak_broadcast", default: true)
    public static let takMqttExport = Setting("tak_mqtt_export", default: true)

    // App
    /// Start the gateway after a phone restart (MESHSAT-1249). On iOS this means: relaunch on
    /// a Bluetooth event through state restoration; there is no boot receiver.
    public static let startOnBoot = Setting("start_on_boot", default: false)
    public static let dashboardOrder = Setting("dashboard_card_order", default: "")
    /// Night mode: the app in red only, for night vision (MESHSAT-1249).
    public static let nightMode = Setting("night_mode", default: false)
    /// Home's "Getting started" list was hidden by the user.
    public static let checklistDismissed = Setting("checklist_dismissed", default: false)
    /// Master switch for local release telemetry (MESHSAT-494). Nothing leaves the device.
    public static let telemetryEnabled = Setting("telemetry_enabled", default: true)

    // SOS (MESHSAT-1249)
    /// EmergencyContact.encode of the people an SOS goes to by SMS.
    public static let sosContacts = Setting("sos_contacts", default: "")
    /// The name an SOS gives for the person who needs help.
    public static let sosName = Setting("sos_name", default: "")
    /// The IMEI of the last satellite modem this phone talked to.
    public static let lastModemImei = Setting("last_modem_imei", default: "")
    /// The SOS in progress or last sent, as JSON (SosRun), so it survives a restart.
    public static let sosRun = Setting("sos_run", default: "")
}

/// Values that live only in the secure store (Android: SecureKeyStore in the Keystore; iOS: the
/// Keychain). The names are Android's, so an export or a support conversation means the same.
public enum SecretKey {
    public static let encryptionKey = "encryption_key"
    public static let mqttPassword = "mqtt_password"
    public static let mqttCertPin = "mqtt_cert_pin"
    public static let mqttCertPinBackup = "mqtt_cert_pin_backup"
    public static let hubPassword = "hub_password"
    public static let hubClientKeyPem = "hub_client_key_pem"
    /// engine/SigningService.kt
    public static let signingPrivateKey = "signing_private_key"
    public static let signingPublicKey = "signing_public_key"
    /// routing/Identity.kt
    public static let routingSigningPrivate = "routing_signing_key_private"
    public static let routingSigningPublic = "routing_signing_key_public"
    public static let routingEncryptionPrivate = "routing_encryption_key_private"
    public static let routingEncryptionPublic = "routing_encryption_key_public"
}

/// What Identity and SigningService need from the secure store (Android's KeyValueStore).
public protocol KeyValueStore: AnyObject, Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func remove(_ key: String)
    func contains(_ key: String) -> Bool
}

/// A KeyValueStore in memory, for tests and previews.
public final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
    public func set(_ key: String, _ value: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }
    public func remove(_ key: String) {
        lock.lock()
        values[key] = nil
        lock.unlock()
    }
    public func contains(_ key: String) -> Bool { get(key) != nil }
}
