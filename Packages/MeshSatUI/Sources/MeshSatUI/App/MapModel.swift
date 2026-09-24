// Mirrors the state of ui/screens/MapScreen.kt: the latest position per node (debounced, a burst
// of TAK inserts would otherwise rebuild the markers many times over), the last day's tracks
// re-read every 30 s while the tab is on screen, the names the radio knows, the layers and the
// hidden set, and the detailed offline map chosen in Setup > Maps. One object for the life of
// the tab, which is never destroyed.
import Foundation
import MeshSatEngine
import MeshSatMeshtastic
import MeshSatPlatform
import MeshSatStore
import Observation

@Observable
@MainActor
public final class MapModel {
    /// How often tracks are read again while the map is on screen (B17: they were read once per process).
    static let trackRefreshMs: UInt64 = 30_000
    /// How far back a track reaches, and how many points all tracks together may hold.
    static let trackWindowMs: Int64 = 24 * 60 * 60_000
    static let trackMaxPoints = 5_000

    public private(set) var nodes: [NodePosition] = []
    public private(set) var tracks: [NodePosition] = []
    public private(set) var names: [Int64: String] = [:]
    public private(set) var now = Int64(Date().timeIntervalSince1970 * 1000)
    public private(set) var detailed: DetailedMap?
    public private(set) var offline = false
    public var showPhone = true
    public var showNodes = true
    public var showTracks = true
    // Hidden rather than shown, so a node that appears later is on the map by default and a new
    // position no longer resets the user's choices.
    public var hidden: Set<Int64> = []
    public var panelOpen = false
    var ticket: MapCommandTicket?
    private var seq = 0
    private var fittedNodes = false
    private var centredPhone = false
    private var tracksTask: Task<Void, Never>?
    private var started = false

    public init() {}

    /// The positions on the map: never the phone's own rows (node 0).
    public var mapNodes: [NodePosition] { nodes.filter { $0.nodeId != 0 } }
    public var shownNodes: [NodePosition] { showNodes ? mapNodes.filter { !hidden.contains($0.nodeId) } : [] }
    public var shownTracks: [NodePosition] { showTracks ? tracks.filter { !hidden.contains($0.nodeId) } : [] }

    func send(_ command: MapCommand) {
        seq += 1
        ticket = MapCommandTicket(seq: seq, command: command)
    }

    /// Starts the observations once; safe to call on every appearance.
    public func start(gateway: GatewayController, model: GatewayModel) {
        guard !started else { return }
        started = true
        let db = gateway.db
        Task { [weak self] in
            do {
                var pending: Task<Void, Never>?
                for try await list in db.nodePositions.getLatestPerNode() {
                    pending?.cancel()
                    pending = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled, let self else { return }
                        nodes = list
                        names = meshNodeNames(model.nodes)
                        firstView(phone: model.phoneFix)
                    }
                }
            } catch {}
        }
        Task { [weak self] in
            for await value in MapTiles.offline.subscribe() {
                self?.offline = value
                self?.worldOnlyZoom()
            }
        }
        // Staleness moves on with the clock, not only when a position arrives.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.now = Int64(Date().timeIntervalSince1970 * 1000)
            }
        }
    }

    /// Tracks are only re-read while the tab is on screen.
    public func setVisible(_ visible: Bool, gateway: GatewayController, model: GatewayModel) {
        tracksTask?.cancel()
        tracksTask = nil
        guard visible else { return }
        let db = gateway.db
        tracksTask = Task { [weak self] in
            while !Task.isCancelled {
                let since = Int64(Date().timeIntervalSince1970 * 1000) - Self.trackWindowMs
                if let rows = try? await db.nodePositions.getRecentTracks(sinceMs: since, maxPoints: Self.trackMaxPoints) {
                    self?.tracks = rows
                }
                self?.names = meshNodeNames(model.nodes)
                try? await Task.sleep(nanoseconds: Self.trackRefreshMs * 1_000_000)
            }
        }
    }

    public func phoneChanged(_ fix: PhoneFix?) { firstView(phone: fix) }

    /// Keeps the map on the chosen detailed map; switches when Setup > Maps changes.
    public func loadDetailed(enabled: Bool, filename: String) async {
        guard enabled, !filename.isEmpty else {
            detailed = nil
            worldOnlyZoom()
            return
        }
        let found = await Task.detached { MapTiles.detailedMap(filename) }.value
        detailed = found
        worldOnlyZoom()
    }

    // First view: everyone once positions exist; until then this phone, if its position is known.
    private func firstView(phone: PhoneFix?) {
        let nodes = mapNodes
        if !fittedNodes, !nodes.isEmpty {
            fittedNodes = true
            var points = nodes.map { ($0.latitude, $0.longitude) }
            if let phone { points.append((phone.latitude, phone.longitude)) }
            send(.fit(points: points, animate: false))
        } else if !fittedNodes, !centredPhone, let phone {
            centredPhone = true
            send(.centre(lat: phone.latitude, lon: phone.longitude, minZoom: 14, animate: false))
        }
    }

    // Offline with only the world overview (detail down to country level): zoom out once so the
    // map shows land instead of an empty dark grid at street level.
    private func worldOnlyZoom() {
        if offline, detailed == nil { send(.maxZoom(5)) }
    }

    /// People > Show on map: centre on that node once its position is known (MESHSAT-1249).
    /// Returns false when the node has not sent a position yet.
    public func focus(on nodeId: Int64) -> Bool? {
        if nodes.isEmpty { return nil }  // positions not loaded yet; runs again when they are
        guard let node = nodes.first(where: { $0.nodeId == nodeId }) else { return false }
        hidden.remove(node.nodeId)
        showNodes = true
        send(.centre(lat: node.latitude, lon: node.longitude, minZoom: 14, animate: true))
        return true
    }

    public func centreOn(_ node: NodePosition) {
        hidden.remove(node.nodeId)
        showNodes = true
        send(.centre(lat: node.latitude, lon: node.longitude, minZoom: 14, animate: true))
    }

    /// Returns false when the phone's position is not known.
    public func centreOnMe(_ fix: PhoneFix?) -> Bool {
        guard let fix else { return false }
        showPhone = true
        send(.centre(lat: fix.latitude, lon: fix.longitude, minZoom: 15, animate: true))
        return true
    }

    /// Returns false when there is nothing to show.
    public func showEveryone(_ fix: PhoneFix?) -> Bool {
        var points = shownNodes.map { ($0.latitude, $0.longitude) }
        if showPhone, let fix { points.append((fix.latitude, fix.longitude)) }
        guard !points.isEmpty else { return false }
        send(.fit(points: points, animate: true))
        return true
    }
}
