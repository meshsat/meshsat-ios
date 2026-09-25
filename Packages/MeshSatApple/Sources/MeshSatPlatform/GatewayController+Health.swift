// Mirrors the HealthScorer wiring of GatewayService.initFieldIntelligence and what the
// Diagnostics section reads (SettingsScreen.kt, SetupSection.Diagnostics): link health scores,
// the batch queue, the telemetry table, and the configuration document.
import Foundation
import MeshSatEngine
import MeshSatStore

extension GatewayController {
    /// The health scorer over the interface manager and the delivery and signal history.
    func initHealthScorer() {
        let mgr = interfaceManager
        let clock = self.clock
        let scorer = HealthScorer(statuses: { mgr.getAllStatus() }, store: GrdbHealthStore(db), now: { clock.nowMs() })
        safety.update { $0.healthScorer = scorer }
    }

    /// Every interface's score, or none while the scorer is not up.
    public func healthScores() async -> [HealthScore] {
        guard let scorer = safety.state.healthScorer else { return [] }
        return await scorer.scoreAll()
    }

    /// Messages waiting in the burst queue for the next satellite pass.
    public var burstPending: Int { safety.state.burst?.pending() ?? 0 }

    /// The batch, now, as the Hub's flush_burst does: the count sent, 0 when nothing waited.
    @discardableResult
    public func flushBurstNow() async -> Int { await flushBurst() }

    /// The newest telemetry rows, newest first (Android reads them at localhost:6051/api/telemetry).
    public func recentTelemetry(limit: Int = 50) async -> [TelemetryEntry] {
        (try? await db.telemetry.getRecent(limit: limit)) ?? []
    }

    /// The configuration as the Bridge exports it.
    public func exportConfiguration(yaml: Bool) async -> String {
        let manager = makeConfigManager()
        return (try? (yaml ? await manager.exportYaml() : await manager.export())) ?? ""
    }

    /// What an import would change, or the reason it cannot be read.
    public func previewConfiguration(_ text: String) async -> Result<DiffResult, ConfigError> {
        let manager = makeConfigManager()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = trimmed.hasPrefix("{") ? trimmed : ConfigManager.yamlToJson(trimmed)
        do {
            return .success(try await manager.diff(json))
        } catch let e as ConfigError {
            return .failure(e)
        } catch {
            return .failure(ConfigError("\(error)"))
        }
    }

    /// Replaces the configuration; the counts imported, or the reason it was refused.
    public func importConfiguration(_ text: String) async -> Result<[String: Int], ConfigError> {
        do {
            return .success(try await makeConfigManager().importAuto(text))
        } catch let e as ConfigError {
            return .failure(e)
        } catch {
            return .failure(ConfigError("\(error)"))
        }
    }
}
