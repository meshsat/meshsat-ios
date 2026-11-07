// Mirrors WelcomeScreen in ui/screens/Onboarding.kt (MESHSAT-1249, here MESHSAT-1834): shown
// before iOS's permission questions whenever one of them is still to be asked, so the first start
// does not open straight onto system dialogs with no word on what they are for. Android's words;
// the Bluetooth line stays because the node setup asks for it, in its own time. The gateway
// remembers what was explained (SettingsKey.welcomeAsked), so a refusal is not asked again.
import MeshSatPlatform
import SwiftUI

struct WelcomeScreen: View {
    /// The permissions this welcome asks for (GatewayController.welcomePending).
    let pending: [String]
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BrandLockup().frame(height: 32)
                Spacer().frame(height: 8)
                Text("Keeping people connected when the network is not.").msText(.headlineMedium)
                Text(
                    "This phone becomes a gateway. With a MeshSat node it sends and receives over the mesh radio and by satellite."
                )
                .msText(.bodyLarge, color: MSColors.textSecondary)
                Text("What the app asks for, and why").msText(.titleMedium).padding(.top, 8)
                reason(MSIcon.bluetooth, "Bluetooth", "To find your MeshSat node and talk to it over Bluetooth; asked when you pair it.")
                if pending.contains(GatewayController.welcomeLocation) {
                    reason(MSIcon.myLocation, "Location", "Your position for an SOS and the map.")
                }
                if pending.contains(GatewayController.welcomeNotifications) {
                    reason(
                        Image(systemName: "bell"), "Notifications",
                        "Incoming messages, a public warning, and an SOS in progress.")
                }
                Spacer().frame(height: 8)
                MSFilledButton("Continue", container: MSColors.teal) { onContinue() }
                    .frame(height: 52)
                Text("You can change any of these later in the iPhone's Settings for MeshSat.")
                    .msText(.bodySmall, color: MSColors.textMuted)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .background(MSColors.bg.ignoresSafeArea())
        .foregroundStyle(MSColors.offWhite)
        .preferredColorScheme(.dark)
    }

    private func reason(_ icon: Image, _ title: String, _ why: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            icon.resizable().scaledToFit().frame(width: 24, height: 24).foregroundStyle(MSColors.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).msText(.bodyLarge)
                Text(why).msText(.bodyMedium, color: MSColors.textSecondary)
            }
        }
    }
}
