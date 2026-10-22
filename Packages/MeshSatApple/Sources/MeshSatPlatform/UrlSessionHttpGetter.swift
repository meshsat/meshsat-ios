// MeshSatNet.HttpGetter on URLSession: the provisioning claim and every other plain GET the
// pure modules make (Android used HttpURLConnection the same way).
import Foundation
import MeshSatNet

public struct UrlSessionHttpGetter: HttpGetter {
    /// false answers a redirect as it came (its 3xx status) instead of following it: the
    /// directory key and the directory are taken only from the Hub that was asked (MESHSAT-1643,
    /// Android's instanceFollowRedirects = false).
    let followRedirects: Bool

    public init(followRedirects: Bool = true) { self.followRedirects = followRedirects }

    public func get(_ url: String, headers: [String: String], timeoutSeconds: Double) async throws -> HttpResponse {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: u, timeoutInterval: timeoutSeconds)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) =
            followRedirects
            ? try await URLSession.shared.data(for: request)
            : try await URLSession.shared.data(for: request, delegate: RefuseRedirects())
        let http = response as? HTTPURLResponse
        var hdrs: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let key = k as? String, let value = v as? String { hdrs[key] = value }
        }
        return HttpResponse(status: http?.statusCode ?? 0, headers: hdrs, body: Array(data))
    }
}

/// Stops every redirect of the task it is given to: the task completes with the 3xx itself.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
