// Mirrors the ConfigManager wiring of GatewayService.initSigningAndApi: the configuration
// export and import in the Bridge's format, with the evaluator told to read the rules again
// after an import (MESHSAT-1274). Android reaches it through its local API; here the
// diagnostics screen will.
import Foundation
import MeshSatEngine
import MeshSatStore

extension GatewayController {
    /// A manager over the store; cheap to make, so made per use.
    public func makeConfigManager() -> ConfigManager {
        ConfigManager(
            rules: db.accessRules, groups: db.objectGroups, failover: db.failoverGroups,
            onImported: { [weak self] in
                try? await self?.accessEvaluator?.reloadFromDb()
                self?.telemetryLogger?.recordEvent(tag: "ConfigManager", message: "Configuration imported")
            })
    }
}
