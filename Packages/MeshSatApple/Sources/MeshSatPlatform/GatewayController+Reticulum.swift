// Mirrors GatewayService.initReticulumTransportNode and initRnsTcp (MESHSAT-1326): the routing
// identity from the Keychain, the announce handler, the link manager, the path and forwarding
// tables, the interface map built from what is up (the node's mesh link, the 9603 driver, the
// TCP peer, the Hub relay), and the transport node over them. Locally addressed packets become
// messages of transport "reticulum"; HeMB frames are logged until the HeMB port lands.
import Foundation
import MeshSatCrypto
import MeshSatEngine
import MeshSatHub
import MeshSatNet
import MeshSatReticulum
import MeshSatStore
import MeshSatWire

/// The Keychain as the identity's store (Android: SecureKeyStore is the KeyValueStore).
final class KeychainIdentityStore: IdentityStore, @unchecked Sendable {
    private let store: any KeyValueStore
    init(_ store: any KeyValueStore) { self.store = store }
    func get(_ key: String) -> String? { store.get(key) }
    func set(_ key: String, _ value: String) { store.set(key, value) }
}

extension GatewayController {
    /// The TCP peer from the settings, reconnecting by itself; its state mirrored into tcp_rns_0.
    func initRnsTcp() {
        guard settings.get(SettingsKey.rnsTcpEnabled) else {
            Self.log.debug("RNS TCP disabled in settings")
            return
        }
        let host = settings.get(SettingsKey.rnsTcpHost)
        guard !host.isEmpty else {
            Self.log.warning("RNS TCP: host not configured")
            return
        }
        let port = Int(settings.get(SettingsKey.rnsTcpPort)) ?? RnsTcpInterface.defaultPort
        let useTls = settings.get(SettingsKey.rnsTcpTls) || port == 443
        var tls: TlsClientOptions?
        if useTls {
            tls = TlsClientOptions(
                clientCertPem: settings.get(SettingsKey.hubClientCertPem), clientKeyPem: settings.hubClientKeyPem,
                caCertPem: settings.get(SettingsKey.hubCaCertPem))
            if tls?.hasClientIdentity == true { Self.log.info("RNS TCP: mTLS material present (not applied on iOS yet)") }
        }
        let tcp = RnsTcpInterface(dialer: NWByteStreamDialer(), log: { Self.log.debug("\($0)") })
        // Wire receive before the node exists: packets that arrive early reach it once it does.
        tcp.setReceiveCallback { [weak self] ifaceId, raw in self?.rnsNode?.onPacketReceived(sourceInterface: ifaceId, raw) }
        tcp.connect(host: host, port: port, tls: tls)
        updateRnsParts { $0.tcp = tcp }
        keep(
            Task { [self] in
                for await state in tcp.state.subscribe() {
                    switch state {
                    case .connected: interfaceManager.setOnline(tcp.interfaceId)
                    case .disconnected: interfaceManager.setOffline(tcp.interfaceId)
                    case .error: interfaceManager.setError(tcp.interfaceId, tcp.error.value)
                    case .connecting: interfaceManager.setConnecting(tcp.interfaceId)
                    }
                }
            })
        Self.log.info("RNS TCP interface initialized: \(host):\(port)")
    }

    /// The Reticulum interfaces that exist right now, by id (GatewayService's rnsInterfaces).
    func rnsInterfaces() -> [String: any RnsInterface] {
        var map: [String: any RnsInterface] = [:]
        let parts = rnsParts
        if let mesh = parts.mesh { map[mesh.interfaceId] = mesh }
        if let iridium = parts.iridium { map[iridium.interfaceId] = iridium }
        if let tcp = parts.tcp { map[tcp.interfaceId] = tcp }
        if let relay = hubRelay { map[relay.interfaceId] = relay }
        return map
    }

    func initReticulumTransportNode() {
        guard settings.get(SettingsKey.rnsTransportEnabled) else {
            Self.log.info("Reticulum transport node disabled by settings")
            return
        }
        let announceMin = Int(settings.get(SettingsKey.rnsAnnounceInterval)) ?? 10
        let identity = Identity.loadOrGenerate(store: KeychainIdentityStore(settings.secure))
        updateRnsParts { $0.identity = identity }
        let announceHandler = RnsAnnounceHandler(identity: identity)
        announceHandler.startPruner()
        let localDestHash = announceHandler.localDestHash
        let linkManager = RnsLinkManager(identity: identity, localDestHash: localDestHash)
        // The always-present interfaces over the node link and the modem; they answer offline
        // until those connect (Android builds the same map lazily from what exists).
        let mesh = RnsMeshtasticBleInterface(radio: central, log: { Self.log.debug("\($0)") })
        let iridium = RnsIridiumInterface(driver: driver, log: { Self.log.debug("\($0)") })
        updateRnsParts {
            $0.mesh = mesh
            $0.iridium = iridium
        }
        let pathTable = RnsPathTable(interfaces: { [weak self] in Array((self?.rnsInterfaces() ?? [:]).values) })
        let forwardingTable = RnsForwardingTable()
        let node = RnsTransportNode(
            localDestHash: localDestHash, announceHandler: announceHandler, linkManager: linkManager, pathTable: pathTable,
            forwardingTable: forwardingTable, interfaces: { [weak self] in self?.rnsInterfaces() ?? [:] },
            announceIntervalMs: Int64(announceMin) * 60_000, log: { Self.log.debug("\($0)") })
        node.localDeliveryCallback = { [weak self] packet, sourceInterface in
            guard let self else { return }
            let text = String(decoding: packet.data, as: UTF8.self)
            Task { [self] in
                try? await db.messages.insert(
                    MessageRecord(
                        timestamp: clock.nowMs(), transport: "reticulum", direction: "rx",
                        sender: String(Hex.encode(packet.destHash).prefix(8)), text: text))
                interfaceManager.recordActivity(sourceInterface)
            }
        }
        node.hembCallback = { sourceInterface, frame in
            // HembReassemblyBuffer lands with the HeMB port; until then the frame is seen, not decoded.
            Self.log.info("hemb: received HeMB frame via \(sourceInterface) (\(frame.count)B), reassembly not ported yet")
        }
        keep(
            Task {
                await mesh.start()
                await iridium.start()
            })
        node.start()
        updateRnsParts { $0.node = node }
        Self.log.info("Reticulum Transport Node started: \(identity.destHashHex) (\(rnsInterfaces().count) interfaces)")
    }

    func stopReticulum() {
        let parts = rnsParts
        updateRnsParts { $0 = GatewayController.RnsParts(identity: $0.identity) }
        parts.node?.stop()
        parts.tcp?.disconnect()
        Task {
            await parts.mesh?.stop()
            await parts.iridium?.stop()
        }
    }
}
