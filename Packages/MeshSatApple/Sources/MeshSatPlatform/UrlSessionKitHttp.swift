// MeshSatEngine.KitHttp on URLSession (Android's HttpURLConnection in kit/KitApiClient.kt,
// MESHSAT-1738, iOS MESHSAT-1820): one request to a field kit on the LAN, never following a
// redirect (a kit's token must not be sent on to another host), no cache, the body capped at 256 KB.
// Plain http to a local address is allowed by NSAllowsLocalNetworking in the app's Info.plist.
import Foundation
import MeshSatEngine

public struct UrlSessionKitHttp: KitHttp {
    static let maxBody = 256 * 1024

    public init() {}

    public func request(
        method: String, url: String, headers: [String: String], body: [UInt8]?, timeoutSeconds: Double
    ) async throws -> KitApiClient.Response {
        guard let u = URL(string: url) else { throw KitRequestError("not an address: \(url)") }
        var request = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let body { request.httpBody = Data(body) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request, delegate: RefuseRedirects())
        } catch let e as URLError {
            // The host and the failure, never the request's headers.
            throw KitRequestError("\(u.host ?? url): \(e.localizedDescription)")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return KitApiClient.Response(code: code, body: String(decoding: data.prefix(Self.maxBody), as: UTF8.self))
    }
}

extension GatewayController {
    /// The field kits reached directly on the LAN (Setup > Field kits on your network).
    public var kits: [KitConnection] { KitConnection.decodeList(settings.get(SettingsKey.kitsLan)) }

    public func putKit(_ kit: KitConnection) {
        var list = kits
        if let i = list.firstIndex(where: { $0.id == kit.id }) { list[i] = kit } else { list.append(kit) }
        settings.set(SettingsKey.kitsLan, KitConnection.encodeList(list))
    }

    /// The kit goes, and its token with it.
    public func removeKit(_ id: String) {
        settings.set(SettingsKey.kitsLan, KitConnection.encodeList(kits.filter { $0.id != id }))
        settings.removeSecret(KitConnection.tokenKey(id))
    }

    public func kitApiToken(_ id: String) -> String { settings.secret(KitConnection.tokenKey(id)) }

    /// A blank token removes it: the kit is asked without one.
    public func setKitApiToken(_ id: String, _ token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { settings.removeSecret(KitConnection.tokenKey(id)) } else { settings.setSecret(KitConnection.tokenKey(id), t) }
    }

    /// One GET of the kit's /api/status, with its token when one is held.
    public func checkKit(url: String, token: String) async -> KitProbe.Result {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = KitApiClient(baseUrl: url, token: t, http: UrlSessionKitHttp(), log: { Self.log.info("Kit \($0)") })
        return await KitProbe.check(client, hasToken: !t.isEmpty)
    }
}
