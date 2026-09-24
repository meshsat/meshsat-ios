// The TLE fetcher's HTTP on URLSession: a GET with headers and a timeout, answering the
// status and the body (satellite/TleFetcher.kt uses HttpURLConnection the same way).
import Foundation
import MeshSatSatellite

public struct UrlSessionTleHttp: TleHttp {
    public init() {}

    public func get(_ url: String, headers: [String: String], timeoutSeconds: Double) async throws -> (Int, Data) {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: u, timeoutInterval: timeoutSeconds)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
