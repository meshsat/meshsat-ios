// Mirrors ble/NodeFirmwareRelease.kt (MESHSAT-1672): the published MeshSat node firmware, as
// meshsat-firmware puts it on GitHub. Every release carries one app image per node build and
// a `manifest.json` that names them, and the manifest of the latest release is always at
// `manifestURL`:
//
//     {"schema": 1, "version": "2.8.0.4012de5", "tag": "meshsat-node-2.8.0.4012de5",
//      "commit": "<sha>", "released_at": "<ISO 8601>",
//      "images": [{"env": "meshsat-tbeam-s3-rockblock9704",
//                  "file": "firmware-meshsat-tbeam-s3-rockblock9704-2.8.0.4012de5.bin",
//                  "size": 2419024, "sha256": "<64 hex>"}]}
//
// The phone asks only when someone taps "Check for update"; nothing here runs on its own. An image
// is taken only for the node's own build (pio_env, exact match) and only when its size and SHA-256
// are the manifest's; `NodeFirmwareImage.check` then runs as for a file. The download itself is
// MeshSatPlatform's NodeFirmwareFetcher.
import Crypto
import Foundation

public enum NodeFirmwareRelease {
    public static let manifestURL = "https://github.com/meshsat/meshsat-firmware/releases/latest/download/manifest.json"
    public static let downloadBase = "https://github.com/meshsat/meshsat-firmware/releases/download/"
    public static let schema = 1
    public static let maxManifestBytes = 64 * 1024

    public struct Image: Sendable, Equatable {
        public let env: String
        public let file: String
        public let size: Int
        public let sha256: String
        public init(env: String, file: String, size: Int, sha256: String) {
            self.env = env
            self.file = file
            self.size = size
            self.sha256 = sha256
        }
    }

    public struct Manifest: Sendable, Equatable {
        public let version: String
        public let tag: String
        public let commit: String
        public let releasedAt: String
        public let images: [Image]
    }

    public enum Parsed: Sendable, Equatable {
        case ok(Manifest)
        case refused(String)
    }

    public enum Pick: Sendable, Equatable {
        case found(Manifest, Image)
        case refused(String)
    }

    /// The manifest's bytes, checked field by field; anything off refuses the whole release.
    public static func parse(_ data: [UInt8]) -> Parsed {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(data))) as? [String: Any] else {
            return .refused("The release list could not be read.")
        }
        let schemaValue = int(o["schema"]) ?? -1
        if schemaValue != schema {
            return .refused("The release list is in a newer format (schema \(schemaValue)). Update MeshSat first.")
        }
        let version = string(o["version"]).trimmingCharacters(in: .whitespaces)
        let tag = string(o["tag"]).trimmingCharacters(in: .whitespaces)
        if version.isEmpty || !isSafeName(tag) { return .refused("The release list names no version.") }
        guard let arr = o["images"] as? [Any] else { return .refused("The release list has no firmware images.") }
        var images: [Image] = []
        for entry in arr {
            guard let it = entry as? [String: Any] else { return .refused("The release list has a broken image entry.") }
            let env = string(it["env"]).trimmingCharacters(in: .whitespaces)
            let file = string(it["file"]).trimmingCharacters(in: .whitespaces)
            let size = int(it["size"]) ?? -1
            let sha = string(it["sha256"]).trimmingCharacters(in: .whitespaces).lowercased()
            if env.isEmpty || !isSafeName(file) || size <= 0 || size > NodeFirmwareImage.appSlotBytes || !isHex64(sha) {
                return .refused("The release list has a broken image entry (\(env)).")
            }
            images.append(Image(env: env, file: file, size: size, sha256: sha))
        }
        if images.isEmpty { return .refused("The release list has no firmware images.") }
        return .ok(Manifest(version: version, tag: tag, commit: string(o["commit"]), releasedAt: string(o["released_at"]), images: images))
    }

    /// The image built for `nodeEnv`, by exact name: a 9603 node never takes the 9704 build.
    public static func pick(_ manifest: Manifest, nodeEnv: String) -> Pick {
        if nodeEnv.trimmingCharacters(in: .whitespaces).isEmpty {
            return .refused("The node did not say which firmware build it runs; reconnect to the node and try again.")
        }
        guard let image = manifest.images.first(where: { $0.env == nodeEnv }) else {
            return .refused("Release \(manifest.version) has no firmware for this node's build (\(nodeEnv)).")
        }
        return .found(manifest, image)
    }

    /// The image's download address: the tag and file are plain names, so they need no escaping.
    public static func imageURL(_ manifest: Manifest, _ image: Image) -> String { downloadBase + manifest.tag + "/" + image.file }

    /// Nil when `bytes` are the manifest's image, else why not.
    public static func verify(_ bytes: [UInt8], _ image: Image) -> String? {
        if bytes.count != image.size { return "The download is \(bytes.count) bytes, the release says \(image.size). Try again." }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if sha != image.sha256 { return "The download does not match the release's SHA-256. Nothing was sent to the node." }
        return nil
    }

    /// True when the node already runs `manifest`'s version ("2.8.0.4012de5" against "2.8.0.4012de5").
    /// The last part is the build's commit hash, so versions are only equal or different: a
    /// different one is offered as "available", never as newer.
    public static func isCurrent(_ manifest: Manifest, running: String) -> Bool {
        let r = running.trimmingCharacters(in: .whitespaces)
        return !r.isEmpty && r == manifest.version
    }

    /// `^[A-Za-z0-9._-]+$`, as Android's SAFE_NAME.
    static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty
            && s.unicodeScalars.allSatisfy { c in
                switch c {
                case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": return true
                default: return false
                }
            }
    }

    static func isHex64(_ s: String) -> Bool {
        s.unicodeScalars.count == 64
            && s.unicodeScalars.allSatisfy { c in
                switch c {
                case "0"..."9", "a"..."f": return true
                default: return false
                }
            }
    }

    /// org.json's optString: a string as it is, a number or a bool in its text form, else "".
    private static func string(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    /// org.json's optInt/optLong: a number, or a string holding one; nil otherwise.
    private static func int(_ v: Any?) -> Int? {
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}
