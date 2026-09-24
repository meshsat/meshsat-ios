// Mirrors SatelliteSkyCard in ui/screens/DashboardScreen.kt: the Home widget of the sky chart,
// three hours back and three ahead, shown only when there is a reading or a pass to show, and
// a tap opens the passes screen.
import MeshSatStore
import SwiftUI

struct SatelliteSkyCard: View {
    @Environment(GatewayModel.self) private var model
    @Environment(Router.self) private var router
    @State private var nowSec = Int64(Date().timeIntervalSince1970)
    @State private var signals: [SkySignal] = []
    @State private var sessions: [SkySession] = []

    private var start: Int64 { nowSec - 3 * 3600 }
    private var end: Int64 { nowSec + 3 * 3600 }

    var body: some View {
        Group {
            if !(signals.isEmpty && model.passes.allSatisfy { !SkyGeometry.overlaps($0, start, end) }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Satellite signal and passes").msText(.titleMedium)
                    Button {
                        router.navigate(.passes)
                    } label: {
                        SkyChart(
                            passes: model.passes, signals: signals, sessions: sessions, startSec: start, endSec: end, nowSec: nowSec,
                            compact: true,
                            windowLabel: "3 h back, 3 h ahead")
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .msCard()
            }
        }
        .task { await observe() }
    }

    // Queried again every ten minutes so the window moves; new rows arrive in between by themselves.
    private func observe() async {
        let db = model.gateway.db
        while !Task.isCancelled {
            nowSec = Int64(Date().timeIntervalSince1970)
            let since = (nowSec - 3 * 3600) * 1000
            let window = Task {
                try? await Task.sleep(nanoseconds: 600_000_000_000)
            }
            let iridium = Task {
                do {
                    for try await rows in db.signals.getSince(source: "iridium", since: since) {
                        signals = rows.map { SkySignal(atSec: $0.timestamp / 1000, bars: $0.value) }
                    }
                } catch {}
            }
            let gss = Task {
                do {
                    for try await rows in db.signals.getSince(source: "gss", since: since) {
                        sessions = rows.map { SkySession(atSec: $0.timestamp / 1000, ok: $0.value >= 1) }
                    }
                } catch {}
            }
            let tick = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    nowSec = Int64(Date().timeIntervalSince1970)
                }
            }
            await window.value
            iridium.cancel()
            gss.cancel()
            tick.cancel()
        }
    }
}
