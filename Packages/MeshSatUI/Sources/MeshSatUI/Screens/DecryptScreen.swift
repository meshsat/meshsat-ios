// Mirrors ui/screens/DecryptScreen.kt: encrypt or decrypt text by hand with the conversation
// key, to check AES-256-GCM compatibility with the MeshSat Pi.
import MeshSatEngine
import MeshSatWire
import SwiftUI

public struct DecryptScreen: View {
    @Environment(GatewayModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @State private var inputText = ""
    @State private var outputText = ""
    @State private var errorText = ""
    @State private var lastOp = ""

    public init() {}

    public var body: some View {
        let key = settings.encryptionKey
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if key.isEmpty {
                    Text("No encryption key configured. Go to Settings to set one.").msText(.bodyMedium, color: MSColors.amber)
                }
                MSOutlinedTextField(text: $inputText, label: "Input text", focusedBorder: MSColors.teal, lineLimit: 8)
                    .onChange(of: inputText) { _, _ in errorText = "" }
                HStack(spacing: 8) {
                    MSFilledButton("Encrypt", container: MSColors.teal) { run(key: key, encrypt: true) }.disabled(key.isEmpty)
                    MSFilledButton("Decrypt", container: MSColors.amber) { run(key: key, encrypt: false) }.disabled(key.isEmpty)
                    MSFilledButton("Paste", container: MSColors.surface, labelColor: MSColors.textPrimary) {
                        if let clip = UIPasteboard.general.string, !clip.isEmpty {
                            inputText = clip
                            model.showToast("Pasted from clipboard")
                        }
                    }
                }
                if !errorText.isEmpty { Text(errorText).msText(.bodyMedium, color: MSColors.red) }
                if !outputText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lastOp == "encrypted" ? "Encrypted (base64):" : "Decrypted:")
                            .msText(.titleMedium, color: lastOp == "encrypted" ? MSColors.teal : MSColors.green)
                        Text(outputText).msText(.labelMedium).textSelection(.enabled)
                        MSFilledButton("Copy", container: MSColors.teal, fullWidth: false) {
                            UIPasteboard.general.string = outputText
                            model.showToast("Copied to clipboard")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .msCard()
                }
                Text(
                    "Paste a base64 ciphertext from an SMS to decrypt it, or type plaintext to encrypt it. Uses the AES-256-GCM key "
                        + "from Settings, which must match the key on MeshSat Pi."
                )
                .msText(.bodySmall, color: MSColors.textMuted)
            }
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
    }

    private func run(key: String, encrypt: Bool) {
        guard !key.isEmpty else {
            errorText = "No key configured"
            return
        }
        do {
            outputText =
                encrypt
                ? try AesGcmCrypto.encryptToBase64(inputText, hexKey: key)
                : try AesGcmCrypto.decryptFromBase64(inputText.trimmingCharacters(in: .whitespacesAndNewlines), hexKey: key)
            lastOp = encrypt ? "encrypted" : "decrypted"
            errorText = ""
        } catch {
            errorText = "\(encrypt ? "Encrypt" : "Decrypt") failed: \(error)"
            outputText = ""
        }
    }
}
