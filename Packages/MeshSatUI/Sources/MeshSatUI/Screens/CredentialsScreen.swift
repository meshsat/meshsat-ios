// Mirrors ui/screens/CredentialsScreen.kt: the Hub certificate and imported keys, with a PEM
// import from the Files app (Android: the document picker).
import MeshSatCrypto
import MeshSatEngine
import MeshSatStore
import SwiftUI

public struct CredentialsScreen: View {
    @Environment(GatewayModel.self) private var model
    @State private var credentials: [ProviderCredential] = []
    @State private var picking = false
    @State private var confirmDelete: ProviderCredential?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MSFilledButton("+ Import PEM", container: MSColors.teal, fullWidth: false) { picking = true }
                Spacer(minLength: 0)
            }
            if credentials.isEmpty {
                VStack(spacing: 4) {
                    Text("No credentials stored").msText(.titleMedium, color: MSColors.textMuted)
                    Text("Import PEM files or receive via Hub sync").msText(.bodySmall, color: MSColors.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(credentials, id: \.id) { cred in CredentialCard(cred: cred) { confirmDelete = cred } }
                    }
                }
            }
        }
        .padding(MSSpace.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MSColors.bg)
        .task {
            do {
                for try await list in model.gateway.db.providerCredentials.getAll() { credentials = list }
            } catch {}
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .item]) { result in
            guard case .success(let url) = result else { return }
            Task { await importPem(url) }
        }
        .overlay {
            if let cred = confirmDelete {
                MSAlertDialog(
                    "Delete Credential?", onDismiss: { confirmDelete = nil },
                    content: { Text("Remove '\(cred.name)' (\(cred.provider))? This cannot be undone.").msText(.bodyMedium) },
                    buttons: {
                        MSTextButton("Cancel", color: MSColors.textSecondary) { confirmDelete = nil }
                        MSFilledButton("Delete", container: MSColors.red, fullWidth: false) {
                            confirmDelete = nil
                            Task { try? await model.gateway.db.providerCredentials.deleteById(cred.id) }
                        }
                    })
            }
        }
    }

    private func importPem(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let pem = try String(contentsOf: url, encoding: .utf8)
            let info = try PemCertificate.parse(pem)
            try await model.gateway.db.providerCredentials.upsert(
                ProviderCredential(
                    id: UUID().uuidString, provider: "local", name: url.lastPathComponent.isEmpty ? "imported.pem" : url.lastPathComponent,
                    credType: "x509_cert", encryptedData: Data(pem.utf8), certNotAfter: info.notAfter, certSubject: info.subject,
                    certFingerprint: info.fingerprint, source: "local", receivedAt: Int64(Date().timeIntervalSince1970 * 1000)))
            model.showToast("Certificate imported")
        } catch {
            model.showToast("Import failed: \(error)")
        }
    }
}

private struct CredentialCard: View {
    let cred: ProviderCredential
    let onDelete: () -> Void

    private static let expired = Color(hex: 0xE57373)
    private static let nearExpiry = Color(hex: 0xFFC107)
    private static let valid = Color(hex: 0x4CAF50)

    private var expiryColor: Color {
        guard let notAfter = cred.certNotAfter, !notAfter.isEmpty else { return MSColors.textMuted }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        // The date part only: the Hub's notAfter is a full timestamp, and Android's
        // SimpleDateFormat reads the leading date and ignores the rest.
        guard let expiry = f.date(from: String(notAfter.prefix(10))) else { return MSColors.textMuted }
        let daysLeft = Int(expiry.timeIntervalSinceNow / 86_400)
        if daysLeft < 0 { return Self.expired }
        if daysLeft < 30 { return Self.nearExpiry }
        return Self.valid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(cred.name).msText(.bodyMedium)
                    HStack(spacing: 8) {
                        CredBadge(cred.provider)
                        CredBadge(cred.credType)
                        CredBadge(cred.source)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MSIconButton(MSIcon.delete, label: "Delete", tint: Self.expired, glyph: 18, action: onDelete)
            }
            Spacer().frame(height: 4)
            if !cred.certFingerprint.isEmpty {
                Text("SHA-256: \(cred.certFingerprint)").msText(.bodySmall, mono: true, color: MSColors.textMuted)
            }
            if !cred.certSubject.isEmpty { Text("Subject: \(cred.certSubject)").msText(.bodySmall, color: MSColors.textMuted).lineLimit(1) }
            if let notAfter = cred.certNotAfter, !notAfter.isEmpty {
                HStack(spacing: 4) {
                    if expiryColor == Self.expired || expiryColor == Self.nearExpiry {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(expiryColor)
                    }
                    Text("Expires: \(notAfter)").msText(.bodySmall, color: expiryColor)
                }
            }
            Text("v\(cred.version)").msText(.bodySmall, color: MSColors.textMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .msCard()
    }
}

private struct CredBadge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        if !text.isEmpty {
            Text(text).msText(.labelSmall, color: MSColors.teal).padding(.horizontal, 6).padding(.vertical, 2)
                .background(MSColors.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
