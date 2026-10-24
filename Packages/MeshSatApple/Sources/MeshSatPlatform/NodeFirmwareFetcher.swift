// Mirrors NodeFirmwareRelease.Fetcher in ble/NodeFirmwareRelease.kt (MESHSAT-1672): the network
// side of "Check for update". HTTPS only, GitHub's redirects to its download host followed, sizes
// capped; nothing runs unless someone taps the button.
import Foundation
import MeshSatMeshtastic

public struct NodeFirmwareFetcher: Sendable {
    public struct FetchError: Error, Sendable, CustomStringConvertible {
        public let description: String
    }

    let timeoutSeconds: Double

    public init(timeoutSeconds: Double = 20) { self.timeoutSeconds = timeoutSeconds }

    public func manifest() async -> NodeFirmwareRelease.Parsed {
        do {
            return NodeFirmwareRelease.parse(try await get(NodeFirmwareRelease.manifestURL, maxBytes: NodeFirmwareRelease.maxManifestBytes))
        } catch {
            return .refused("Could not reach the release list: \(String(describing: error)).")
        }
    }

    /// The image's bytes, at most its size; `onProgress` gets the fraction read.
    public func download(
        _ manifest: NodeFirmwareRelease.Manifest, _ image: NodeFirmwareRelease.Image, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [UInt8] {
        try await get(NodeFirmwareRelease.imageURL(manifest, image), maxBytes: image.size, onProgress: onProgress)
    }

    private func get(_ url: String, maxBytes: Int, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> [UInt8] {
        guard let u = URL(string: url), u.scheme == "https" else { throw FetchError(description: "not an HTTPS address") }
        var request = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds)
        request.setValue("meshsat-ios-node-firmware", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if response.url?.scheme != "https" { throw FetchError(description: "the download left HTTPS") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw FetchError(description: "no release published yet") }
        if code != 200 { throw FetchError(description: "HTTP \(code)") }
        var out: [UInt8] = []
        out.reserveCapacity(min(maxBytes, 4 * 1024 * 1024))
        for try await b in bytes {
            out.append(b)
            if out.count > maxBytes { throw FetchError(description: "the answer is larger than expected") }
            if out.count % (64 * 1024) == 0 { onProgress?(Double(out.count) / Double(maxBytes)) }
        }
        onProgress?(Double(out.count) / Double(max(maxBytes, 1)))
        return out
    }
}
