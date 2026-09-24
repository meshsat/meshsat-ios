// The actions the Setup screens send the gateway (GatewayService.onStartCommand's other
// actions): a fresh signal reading, a restart of every transport, the Hub ping.
import Foundation
import MeshSatEngine
import MeshSatHub

extension GatewayController {
    /// A fresh AT+CSQ reading; can take up to a minute on a modem searching for the sky.
    public func pollSignal() async -> Int { await driver.pollSignal(fresh: true) }

    /// Stop and start every transport (GatewayService.scheduleRestart): the Hub, Reticulum, the
    /// node link, the dispatcher, all of it.
    public func restart() {
        stop()
        Task { [self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            start()
        }
    }

    /// The Hub's round trip in milliseconds, or nil when there is no connection.
    public func pingHub() async -> Int64? {
        guard let hub = hubReporter, hub.state.value == .connected else { return nil }
        return try? await hub.ping()
    }
}
