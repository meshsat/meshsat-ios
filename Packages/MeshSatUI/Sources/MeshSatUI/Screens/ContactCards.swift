// Mirrors ui/screens/ContactCards.kt (MESHSAT-566, MESHSAT-575): handing a card over, face to
// face. One person shows "My card", the other scans it, and both read the same fingerprint off
// their screens. The signature proves the card was made by the key it carries and has not been
// altered; the fingerprint, read aloud, is what ties that key to the person standing there. A
// card that arrived any other way is kept as IMPORTED, because nothing says who passed it on.
import CoreImage.CIFilterBuiltins
import MeshSatCrypto
import MeshSatEngine
import MeshSatMeshtastic
import SwiftUI

struct ContactCardsSection: View {
    @Environment(GatewayModel.self) private var model
    @State private var contacts: [Contact] = []
    @State private var showMyCard = false
    @State private var pending: (card: ContactQR.Card, trust: ContactQR.Trust)?
    @State private var showPaste = false
    @State private var scanning = false
    @State private var pasteText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("People you carry").msText(.titleMedium)
            Text("Cards swapped face to face by QR code. Read the fingerprint aloud to each other: it is what says the card is theirs.")
                .msText(.bodySmall, color: MSColors.textMuted).padding(.top, 4).padding(.bottom, 12)
            // Two buttons to a row: three did not fit a phone's width.
            HStack(spacing: 8) {
                MSOutlinedButton("My card") { showMyCard = true }
                MSOutlinedButton("Scan a card") { scanning = true }
            }
            HStack { MSTextButton("Paste a card instead") { showPaste = true } }
            if contacts.isEmpty {
                Text("No cards yet.").msText(.bodySmall, color: MSColors.textMuted).padding(.top, 12)
            } else {
                ForEach(contacts, id: \.fingerprint) { c in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.name).msText(.bodyLarge)
                        Text(c.fingerprint).msText(.bodySmall, mono: true, color: MSColors.textMuted)
                        Text(trustLine(c)).msText(.bodySmall, color: MSColors.textMuted)
                        HStack {
                            MSTextButton("Forget") { Task { try? await model.gateway.db.contacts.delete(c.fingerprint) } }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .msCard()
        .padding(.vertical, 8)
        .task {
            do {
                for try await list in model.gateway.db.contacts.observeAll() { contacts = list }
            } catch {}
        }
        .fullScreenCover(isPresented: $scanning) {
            QRScannerSheet(prompt: "Scan the other phone's card") { code in
                scanning = false
                if let code, !code.isEmpty { read(code, trust: .scanned) }
            }
        }
        .overlay {
            if showMyCard { MyCardDialog(onDismiss: { showMyCard = false }) }
            if showPaste { pasteDialog }
            if let pending { addDialog(pending.card, pending.trust) }
        }
    }

    private func trustLine(_ c: Contact) -> String {
        var s = c.trust == ContactQR.Trust.scanned.rawValue ? "Scanned in person" : "Imported as text"
        if !c.meshNodeId.isEmpty { s += " \u{00B7} mesh \(c.meshNodeId)" }
        if !c.bridgeId.isEmpty { s += " \u{00B7} \(c.bridgeId)" }
        return s
    }

    private func read(_ text: String, trust: ContactQR.Trust) {
        switch ContactQR.decode(text) {
        case .ok(let card): pending = (card, trust)
        case .badSignature: model.showToast("That card has been altered since it was made. Not saved.")
        case .malformed: model.showToast("That is a MeshSat card, but a damaged one.")
        case .notACard: model.showToast("That is not a MeshSat contact card.")
        }
    }

    private var pasteDialog: some View {
        MSAlertDialog(
            "Paste a card", onDismiss: { showPaste = false },
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "A card that did not come through the camera is kept as imported: the signature still holds, "
                            + "but nothing says who passed it on."
                    )
                    .msText(.bodySmall, color: MSColors.textMuted)
                    MSOutlinedTextField(text: $pasteText, label: "meshsat:contact:1:...")
                }
            },
            buttons: {
                MSTextButton("Cancel") { showPaste = false }
                MSTextButton("Read it") {
                    showPaste = false
                    read(pasteText, trust: .imported)
                }
            })
    }

    private func addDialog(_ card: ContactQR.Card, _ trust: ContactQR.Trust) -> some View {
        MSAlertDialog(
            "Add \(card.name)?", onDismiss: { pending = nil },
            content: {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Check this fingerprint against the one on their screen. If it differs, the card is not theirs.")
                        .msText(.bodySmall, color: MSColors.textMuted)
                    Text(card.fingerprint).msText(.titleMedium, mono: true).padding(.vertical, 8)
                    if !card.meshNodeId.isEmpty { Text("Mesh node \(card.meshNodeId)").msText(.bodySmall, color: MSColors.textMuted) }
                    if !card.bridgeId.isEmpty { Text("Hub \(card.bridgeId)").msText(.bodySmall, color: MSColors.textMuted) }
                    Text(trust == .scanned ? "Scanned from a screen in front of you." : "Imported as text.")
                        .msText(.bodySmall, color: MSColors.textMuted).padding(.top, 8)
                }
            },
            buttons: {
                MSTextButton("Cancel") { pending = nil }
                MSTextButton("Add") {
                    let c = Contact(
                        fingerprint: card.fingerprint, name: card.name, signingPub: Data(card.signingPubRaw).base64EncodedString(),
                        meshNodeId: card.meshNodeId, bridgeId: card.bridgeId, trust: trust.rawValue, issuedAt: card.issuedAtSec,
                        addedAt: Int64(Date().timeIntervalSince1970 * 1000))
                    pending = nil
                    Task { try? await model.gateway.db.contacts.upsert(c) }
                }
            })
    }
}

/// This phone's own card, as a QR code to hold up, with the fingerprint written under it.
struct MyCardDialog: View {
    let onDismiss: () -> Void
    @Environment(GatewayModel.self) private var model
    @State private var qr: UIImage?
    @State private var text = ""
    @State private var fingerprint = ""

    var body: some View {
        let identity = model.gateway.routingIdentity
        MSAlertDialog(
            "My card", onDismiss: onDismiss,
            content: {
                VStack(spacing: 0) {
                    if identity == nil {
                        Text("The gateway has not started yet, so this phone has no key to sign a card with.").msText(.bodyMedium)
                    } else {
                        if let qr {
                            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(width: 244, height: 244).padding(8)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("This phone's contact card as a QR code")
                        }
                        Text(fingerprint).msText(MSTextStyle(18, 24, .medium, relativeTo: .headline), mono: true).padding(.top, 12)
                        Text("Read this out to whoever scans it.").msText(.bodySmall, color: MSColors.textMuted)
                    }
                }
                .frame(maxWidth: .infinity)
            },
            buttons: {
                if !text.isEmpty {
                    MSTextButton("Copy") {
                        UIPasteboard.general.string = text
                        model.showToast("Card copied")
                    }
                }
                MSTextButton("Done", action: onDismiss)
            }
        )
        .task(id: "\(model.myInfo?.myNodeNum ?? 0)|\(model.nodes.count)") { make(identity) }
    }

    private func make(_ identity: Identity?) {
        guard let identity else { return }
        let myNum = model.myInfo?.myNodeNum ?? 0
        let myName = model.nodes.first { $0.nodeNum == myNum }?.longName ?? ""
        let name = String((myName.isEmpty ? "MeshSat phone" : myName).prefix(ContactQR.maxName))
        let card = ContactQR.Card(
            name: name, signingPubRaw: identity.signingPubRaw, meshNodeId: myNum != 0 ? MeshtasticProtocol.formatNodeId(myNum) : "",
            bridgeId: "", issuedAtSec: Int64(Date().timeIntervalSince1970))
        guard let encoded = try? ContactQR.encode(card, identity: identity) else { return }
        text = encoded
        fingerprint = card.fingerprint
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(encoded.utf8)
        filter.correctionLevel = "M"
        if let out = filter.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) {
            qr = UIImage(cgImage: cg)
        }
    }
}
