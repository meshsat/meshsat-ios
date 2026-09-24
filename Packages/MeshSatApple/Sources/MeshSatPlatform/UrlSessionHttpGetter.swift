// MeshSatNet.HttpGetter on URLSession: the provisioning claim and every other plain GET the
// pure modules make (Android used HttpURLConnection the same way).
import Foundation
import MeshSatNet

public struct UrlSessionHttpGetter: HttpGetter {
    public init() {}

    public func get(_ url: String, headers: [String: String], timeoutSeconds: Double) async throws -> HttpResponse {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: u, timeoutInterval: timeoutSeconds)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        var hdrs: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let key = k as? String, let value = v as? String { hdrs[key] = value }
        }
        return HttpResponse(status: http?.statusCode ?? 0, headers: hdrs, body: Array(data))
    }
}
