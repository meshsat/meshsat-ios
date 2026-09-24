// Mirrors ui/components/ProvisionLinkDialog.kt and ui/components/ProvisionClaimHost.kt: the
// confirmation for a meshsat://provision deep link (MESHSAT-1235), and the claim shown wherever
// the person is in the app: the wait for the Hub, the credentials to confirm, and the outcome
// (MESHSAT-1306). Same words as Android.
import MeshSatHub
import SwiftUI

/// Confirmation for a `meshsat://provision/{bid}/{nonce}?hub={host}` deep link. The QR scanner
/// in Settings claims first and confirms after, because the user chose to scan. A link can be
/// fired by any app or page, so here nothing is fetched until the user has seen which Hub will
/// issue the credentials and for which bridge.
public struct ProvisionLinkDialog: View {
    @Environment(GatewayModel.self) private var model
    let url: String
    let onDone: () -> Void

    public init(url: String, onDone: @escaping () -> Void) {
        self.url = url
        self.onDone = onDone
    }

    public var body: some View {
        switch Result(catching: { try ProvisionImporter.parseLink(url) }) {
        case .failure(let e):
            Color.clear.onAppear {
                model.showToast("Provisioning link rejected: \(e)")
                onDone()
            }
        case .success(let request):
            MSAlertDialog("Provision Hub Connection", onDismiss: onDone) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Provision this phone as bridge \"\(request.bridgeId)\" with credentials from \(request.hubHost)?\n\n"
                            + "This will overwrite existing Hub settings. Only continue if you generated this link on your own Hub."
                    ).msText(.bodyMedium)
                    Text("Hub: \(request.hubHost)").msText(.bodySmall, color: MSColors.textMuted)
                }
            } buttons: {
                MSTextButton("Cancel", action: onDone)
                MSFilledButton("Provision", fullWidth: false) {
                    // The app claims and applies it from here on, wherever the person goes, and
                    // ProvisionClaimHost shows the wait (MESHSAT-1306).
                    model.provisionFromLink(request)
                    onDone()
                }
            }
        }
    }
}

/// Seconds since `startedMs`, ticking once a second while shown.
struct WaitedSeconds: View {
    let startedMs: Int64
    @State private var nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("Waiting for the Hub, \(max(0, (nowMs - startedMs) / 1000)) s").msText(.bodyMedium)
            .onReceive(tick) { _ in nowMs = Int64(Date().timeIntervalSince1970 * 1000) }
    }
}

/// Shows the provisioning claim wherever the person is in the app.
public struct ProvisionClaimHost: View {
    @Environment(GatewayModel.self) private var model
    /// "Hide" puts the wait away; the Hub card in Setup keeps showing it.
    @State private var hiddenSince: Int64 = 0

    public init() {}

    private var dismiss: () -> Void { { model.dismissProvision() } }
    private func hide(_ startedMs: Int64) -> () -> Void { { hiddenSince = startedMs } }

    public var body: some View {
        switch model.provisionState {
        case .idle:
            EmptyView()
        case .waiting(_, _, let startedMs, _):
            if hiddenSince != startedMs {
                MSAlertDialog("Getting the Hub's settings", onDismiss: hide(startedMs)) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            MSCircularProgress(size: 20, stroke: 2)
                            WaitedSeconds(startedMs: startedMs)
                        }
                        Text(
                            "The Hub gives this phone its new password once all its servers accept it. "
                                + "That usually takes about a minute. You can leave this screen; the phone keeps asking."
                        ).msText(.bodySmall, color: MSColors.textMuted)
                    }
                } buttons: {
                    MSTextButton("Cancel") { model.dismissProvision() }
                    MSTextButton("Hide") { hiddenSince = startedMs }
                }
            }
        case .ready(let bundle):
            MSAlertDialog("Use these Hub settings?", onDismiss: dismiss) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This phone becomes bridge \"\(bundle.bridgeId)\" on the Hub. Its current Hub settings are replaced.")
                        .msText(.bodyMedium)
                    Text("Hub: \(bundle.mqttUrl)").msText(.bodySmall, color: MSColors.textMuted)
                    if !bundle.certExpiry.isEmpty {
                        Text("Certificate expires: \(bundle.certExpiry)").msText(.bodySmall, color: MSColors.textMuted)
                    }
                    if !bundle.reticulumTcp.isEmpty {
                        Text("Reticulum: \(bundle.reticulumTcp)").msText(.bodySmall, color: MSColors.textMuted)
                    }
                }
            } buttons: {
                MSTextButton("Cancel") { model.dismissProvision() }
                MSFilledButton("Provision", fullWidth: false) { model.applyProvision() }
            }
        case .applied(let bridgeId):
            Color.clear.onAppear {
                model.showToast("Hub provisioned: \(bridgeId). Connecting to the Hub.")
                model.dismissProvision()
            }
        case .failed(let message):
            MSAlertDialog("No settings from the Hub", onDismiss: dismiss) {
                Text(message).msText(.bodyMedium)
            } buttons: {
                MSTextButton("OK") { model.dismissProvision() }
            }
        }
    }
}

/// Android's Toast: a short line at the bottom, gone after a few seconds (MSToastHost in Material later).
public struct MSToast: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .msText(.bodySmall)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(MSColors.surfaceLight, in: Capsule())
            .overlay(Capsule().stroke(MSColors.border, lineWidth: 1))
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
    }
}
