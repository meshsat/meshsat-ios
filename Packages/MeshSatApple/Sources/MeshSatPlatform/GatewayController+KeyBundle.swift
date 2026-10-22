// Mirrors the key bundle half of SettingsScreen.kt and crypto/KeyBundleImporter.kt's app entry
// points (MESHSAT-495): a kit's meshsat://key/ QR code into the conversation keys, the provider
// credentials and the kit's pinned signing key. MESHSAT-1631.
import Foundation
import MeshSatEngine
import MeshSatStore

/// The app database as the importer's store.
struct DatabaseKeyBundleStore: KeyBundleStore {
    let db: AppDatabase
    func trust(_ bridgeHash: String) async throws -> BridgeTrust? { try await db.bridgeTrust.get(bridgeHash) }
    func upsertTrust(_ trust: BridgeTrust) async throws { try await db.bridgeTrust.upsert(trust) }
    func upsertConversationKey(_ key: ConversationKey) async throws { try await db.conversationKeys.upsert(key) }
    func upsertCredential(_ credential: ProviderCredential) async throws { try await db.providerCredentials.upsert(credential) }
}

extension GatewayController {
    /// Imports a scanned key bundle. `forceRepin` replaces the kit's pinned key, only after the
    /// person confirmed a `.keyMismatch`; that choice goes into the audit log, as on Android.
    public func importKeyBundle(_ url: String, forceRepin: Bool = false) async -> KeyBundleImporter.ImportResult {
        let r = await KeyBundleImporter.importFromURL(
            url, store: DatabaseKeyBundleStore(db: db), forceRepin: forceRepin, now: clock.nowMs())
        if forceRepin {
            let kit: String
            let outcome: String
            switch r {
            case .success(_, _, let hash):
                kit = hash
                outcome = "Success"
            case .keyMismatch(let hash, _, _, _):
                kit = hash
                outcome = "KeyMismatch"
            case .invalidSignature:
                kit = ""
                outcome = "InvalidSignature"
            case .malformed:
                kit = ""
                outcome = "Malformed"
            }
            await signingService?.auditEvent("bridge_key_repinned", detail: "kit=\(kit.prefix(16)) result=\(outcome)")
        }
        return r
    }
}
