// Mirrors ble/NodeFirmwareImage.kt (MESHSAT-1672): a firmware image for a MeshSat node's update
// over Bluetooth, checked before anything is sent. It must be the plain ESP32 app image
// (`firmware-<env>-<version>.bin`, the one the OTA loader writes to app0), never a `.factory.bin`
// (bootloader, partition table and app from offset 0), it must fit the app slot, and it must have
// been built for the node's own PlatformIO env, which the node reports in MyNodeInfo.pio_env. A
// stock Meshtastic image would drop the Iridium pipe, so an image without the node's env name is
// refused.
import Crypto
import Foundation

public struct NodeFirmwareImage: Sendable, Equatable {
    public let bytes: [UInt8]
    public let sha256: [UInt8]
    /// The version string from the image's esp_app_desc, e.g. "2.8.0.fc4f3bb"; may be empty.
    public let version: String
    /// The project name from the image's esp_app_desc.
    public let project: String

    public var size: Int { bytes.count }
    public var sha256Hex: String { sha256.map { String(format: "%02x", $0) }.joined() }

    public enum Check: Sendable, Equatable {
        case ok(NodeFirmwareImage)
        case refused(String)
    }

    /// app0 and app1 of the 8 MB table the MeshSat T-Beam images use (default_8MB.csv): 0x330000 each.
    public static let appSlotBytes = 0x33_0000
    /// The smallest app image worth sending; anything smaller is not firmware.
    public static let minImageBytes = 64 * 1024

    private static let espImageMagic: UInt8 = 0xE9
    /// esp_app_desc_t follows the 24-byte image header and the first 8-byte segment header.
    private static let appDescOffset = 32
    private static let appDescMagic: UInt32 = 0xABCD_5432
    private static let appDescVersionOffset = appDescOffset + 16
    private static let appDescProjectOffset = appDescOffset + 48

    /// The checks, in order; `nodeEnv` is the node's pio_env (empty: the node did not say).
    public static func check(_ bytes: [UInt8], nodeEnv: String) -> Check { check(bytes, nodeEnv: nodeEnv, requireEnv: true) }

    /// The checks for a node waiting in its updater with no Meshtastic link, so no pio_env to
    /// compare (MESHSAT-1684): the image must still be an app image that fits, and the updater
    /// itself refuses, before erasing anything, every image but the one whose SHA-256 the node
    /// was handed when the update began.
    public static func checkForWaitingUpdater(_ bytes: [UInt8]) -> Check { check(bytes, nodeEnv: "", requireEnv: false) }

    private static func check(_ bytes: [UInt8], nodeEnv: String, requireEnv: Bool) -> Check {
        if bytes.count < minImageBytes { return .refused("The file is too small to be firmware (\(bytes.count) bytes).") }
        if bytes.count > appSlotBytes {
            return .refused(
                "The file is larger than the node's firmware slot. A .factory.bin is for a cable flash; pick the plain firmware-….bin.")
        }
        if bytes[0] != espImageMagic { return .refused("The file is not an ESP32 firmware image.") }
        if le32(bytes, appDescOffset) != appDescMagic {
            return .refused("The file is not an app image. A .factory.bin is for a cable flash; pick the plain firmware-….bin.")
        }
        if requireEnv {
            if nodeEnv.trimmingCharacters(in: .whitespaces).isEmpty {
                return .refused("The node did not say which firmware build it runs; reconnect to the node and try again.")
            }
            if !containsName(bytes, Array(nodeEnv.utf8)) {
                return .refused("This firmware was not built for this node (\(nodeEnv)). Pick the file named firmware-\(nodeEnv)-….bin.")
            }
        }
        return .ok(
            NodeFirmwareImage(
                bytes: bytes, sha256: Array(SHA256.hash(data: bytes)),
                version: cString(bytes, appDescVersionOffset, 32), project: cString(bytes, appDescProjectOffset, 32)))
    }

    private static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    private static func cString(_ b: [UInt8], _ at: Int, _ max: Int) -> String {
        guard at + max <= b.count else { return "" }
        var end = at
        while end < at + max && b[end] != 0 { end += 1 }
        return String(decoding: b[at..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// `name` as a whole name: not followed by another name character, so the 9603 build's env
    /// never matches inside the 9704 build's ("meshsat-tbeam-s3-rockblock" is the start of
    /// "meshsat-tbeam-s3-rockblock9704").
    static func containsName(_ haystack: [UInt8], _ name: [UInt8]) -> Bool {
        guard !name.isEmpty, name.count <= haystack.count else { return false }
        var i = 0
        let last = haystack.count - name.count
        while i <= last {
            if haystack[i] == name[0] && haystack[i..<(i + name.count)].elementsEqual(name) {
                let after = i + name.count
                if after >= haystack.count || !isNameByte(haystack[after]) { return true }
            }
            i += 1
        }
        return false
    }

    private static func isNameByte(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
            UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        let first = needle[0]
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first && haystack[i..<(i + needle.count)].elementsEqual(needle) { return true }
            i += 1
        }
        return false
    }
}
