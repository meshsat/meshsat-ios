// Mirrors ProvisionImporter.apply and ProvisionClaim's use of the app in crypto/Provision*.kt
// (MESHSAT-1324): the claimed bundle goes into the settings, the Keychain and the credentials
// table, and the Hub client is started again on the new credentials, which is what Android's
// GatewayService.scheduleRestart achieves for the whole service.
import Foundation
import MeshSatEngine
import MeshSatHub
import MeshSatStore

/// The applier the claim holds; the gateway sets itself after its own init.
final class ProvisionApplierBox: ProvisionApplier, @unchecked Sendable {
    weak var gateway: GatewayController?
    func apply(_ bundle: ProvisionImporter.ProvisionBundle) async throws {
        guard let gateway else { throw ProvisionImporter.ProvisionError("the gateway is gone") }
        try await gateway.applyProvision(bundle)
    }
}

extension GatewayController {
    /// Everything the Hub's provisioning bundle sets, in Android's order.
    public func applyProvision(_ bundle: ProvisionImporter.ProvisionBundle) async throws {
        settings.set(SettingsKey.hubUrl, bundle.mqttUrl)
        settings.set(SettingsKey.hubBridgeId, bundle.bridgeId)
        settings.set(SettingsKey.hubUsername, bundle.username)
        settings.setHubPassword(bundle.password)
        settings.set(SettingsKey.hubEnabled, true)
        if !bundle.clientCertPem.isEmpty { settings.set(SettingsKey.hubClientCertPem, bundle.clientCertPem) }
        if !bundle.clientKeyPem.isEmpty { settings.setHubClientKeyPem(bundle.clientKeyPem) }
        if !bundle.caCertPem.isEmpty { settings.set(SettingsKey.hubCaCertPem, bundle.caCertPem) }
        if !bundle.reticulumTcp.isEmpty {
            let parts = bundle.reticulumTcp.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 2 {
                settings.set(SettingsKey.rnsTcpHost, String(parts[0]))
                settings.set(SettingsKey.rnsTcpPort, String(parts[1]))
                settings.set(SettingsKey.rnsTcpEnabled, true)
                settings.set(SettingsKey.rnsTransportEnabled, true)
            }
        }
        if !bundle.clientCertPem.isEmpty, !bundle.clientKeyPem.isEmpty {
            try await db.providerCredentials.upsert(
                ProviderCredential(
                    id: "hub_mtls_\(bundle.bridgeId)", provider: "hub_mqtt", name: "Hub mTLS (\(bundle.bridgeId))",
                    credType: "mtls_bundle", encryptedData: Data((bundle.clientCertPem + "\n" + bundle.clientKeyPem).utf8),
                    certNotAfter: bundle.certExpiry.isEmpty ? nil : bundle.certExpiry, certSubject: "CN=\(bundle.bridgeId)",
                    version: 1, source: "qr", receivedAt: clock.nowMs()))
        }
        Self.log.info("Hub provisioned: \(bundle.bridgeId) -> \(bundle.mqttUrl)")
        // The gateway reads the Hub settings when the Hub client starts (MESHSAT-749).
        await restartHubReporter()
    }

    /// The Hub client and the relay stopped and started again on the settings as they are now.
    public func restartHubReporter() async {
        if let hub = hubReporter {
            setHubReporter(nil)
            interfaceManager.setOffline("hub_0")
            await hub.stop()
        }
        if settings.get(SettingsKey.hubEnabled) { interfaceManager.enable("hub_0") } else { interfaceManager.disable("hub_0") }
        initHubReporter()
        // The relay rides on the same identity, so it starts again on it too.
        stopHubRelay()
        if settings.get(SettingsKey.hubRelayTarget).isEmpty {
            interfaceManager.disable(RelayBridgeTransport.interfaceId)
        } else {
            interfaceManager.enable(RelayBridgeTransport.interfaceId)
        }
        initHubRelay()
    }

    /// A `meshsat://provision/` link the app was opened with, confirmed by the ProvisionLinkDialog.
    public func openProvisionLink(_ url: String) {
        guard ProvisionImporter.isProvisionUrl(url) else { return }
        pendingProvisionLink.send(url)
    }
}
