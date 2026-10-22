// Mirrors GatewayService.initHubDirectory (MESHSAT-1642): the tenant's signed directory from the
// Hub (HeMB-NG C9.5). The Hub pushes nothing to a phone, so it is read on every connect to the
// Hub and every 15 minutes while connected. MESHSAT-1643.
import Foundation
import MeshSatEngine
import MeshSatHub

extension GatewayController {
    static let hubDirectoryEveryNs: UInt64 = 15 * 60 * 1_000_000_000

    /// The reader for one Hub client; the one before it stops.
    func startHubDirectory(_ reporter: HubReporter, bridgeId: String) {
        let base = RelayTunnel.deriveHubApiBase(
            settings.get(SettingsKey.hubUrl), explicitApiUrl: settings.get(SettingsKey.hubRelayUrl))
        let password = settings.hubPassword
        var task: Task<Void, Never>?
        if base.isEmpty || password.isEmpty {
            Self.log.warning("Hub directory: Hub URL or password not configured")
        } else {
            let client = HubDirectoryClient(store: hubDirectory, http: UrlSessionHttpGetter(followRedirects: false))
            task = Task { [self] in
                var poller: Task<Void, Never>?
                for await state in reporter.state.subscribe() {
                    poller?.cancel()
                    poller = nil
                    guard state == .connected else { continue }
                    poller = Task {
                        while !Task.isCancelled {
                            report(await client.poll(hubApiBase: base, bridgeId: bridgeId, password: password))
                            try? await Task.sleep(nanoseconds: Self.hubDirectoryEveryNs)
                        }
                    }
                }
                poller?.cancel()
            }
        }
        setHubDirectoryTask(task)
    }

    private func report(_ outcome: HubDirectoryClient.Outcome) {
        switch outcome {
        case .applied(let r):
            let s = r.state
            Self.log.info(
                "Hub directory: version \(s.version), \(s.contacts.count) contacts, \(s.groups.count) groups, key \(s.keyId.prefix(12))")
        case .refused(let r):
            Self.log.warning("Hub directory refused: \(r.reason) \(r.detail)")
        case .failed(let message):
            Self.log.warning("Hub directory: \(message)")
        case .notModified:
            break
        }
    }

    /// The directory's context and key (MESHSAT-1643, r40 review R40-R3): another broker, bridge
    /// id, topic root or tenant starts the directory over, even under the same signing key; the
    /// bundle's key is pinned, never replaced by the HTTPS bootstrap. A bad key is the Hub's bug and
    /// must not cost the provisioning: the directory then starts over unpinned.
    func pinDirectoryKey(from bundle: ProvisionImporter.ProvisionBundle) {
        let context = HubDirectoryClient.provisioningContext(
            mqttUrl: bundle.mqttUrl, bridgeId: bundle.bridgeId, topicPrefix: bundle.topicPrefix, tenant: bundle.tenantId)
        let client = HubDirectoryClient(store: hubDirectory, http: UrlSessionHttpGetter(followRedirects: false))
        do {
            var der: [UInt8]?
            if !bundle.dirSignPub.isEmpty {
                guard let d = Data(base64Encoded: bundle.dirSignPub) else {
                    throw HubDirectoryClient.Failure("the directory key in the bundle is not base64")
                }
                der = Array(d)
            }
            try client.applyProvisioning(context: context, tenant: bundle.tenantId, pkix: der)
        } catch {
            Self.log.warning("Directory key in the bundle not pinned: \(error)")
            do {
                try client.applyProvisioning(context: context, tenant: bundle.tenantId, pkix: nil)
            } catch {
                Self.log.warning("Directory not reset for the new provisioning: \(error)")
            }
        }
    }
}
