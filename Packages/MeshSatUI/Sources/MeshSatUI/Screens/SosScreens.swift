// Mirrors ui/screens/SosScreens.kt (MESHSAT-1249): hold to send, an emergency contact list, sent
// through the retrying queue, a result screen per route, a banner on every screen while it is
// on, and a real test. On iOS each SMS route opens the Messages composer (no SMS API), and the
// contact picker is ContactsUI's, which hands over one row without a contacts permission.
import ContactsUI
import MeshSatEngine
import MeshSatWire
import SwiftUI

/// Where an SOS would go from this phone right now.
struct SosReach {
    let satellite: Bool
    let mesh: Bool
    let contacts: [EmergencyContact]
    let canSms: Bool
    let hub: Bool

    var sms: Bool { canSms && !contacts.isEmpty }
    var anywhere: Bool { satellite || mesh || sms || hub }

    /// "By satellite, the mesh, SMS to 2 people and the Hub."
    func sentence() -> String {
        var parts: [String] = []
        if satellite { parts.append("satellite") }
        if mesh { parts.append("the mesh") }
        if sms {
            parts.append(
                "SMS to " + (contacts.count == 1 ? (contacts[0].name.isEmpty ? "1 person" : contacts[0].name) : "\(contacts.count) people"))
        }
        if hub { parts.append("the Hub") }
        if parts.isEmpty {
            return canSms
                ? "An SOS has nowhere to go yet. Add emergency contacts, or connect your node."
                : "An SOS has nowhere to go yet. Connect your MeshSat node, or set up the Hub."
        }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        return "Sends your position by \(list), and keeps trying until you cancel."
    }

    @MainActor static func from(_ model: GatewayModel) -> SosReach {
        SosReach(
            satellite: !model.modemImei.isEmpty || !model.lastModemImei.isEmpty, mesh: model.meshPaired, contacts: model.sosContacts,
            canSms: model.canSendSms, hub: model.hubSetUp)
    }
}

/// The SOS card on Home: hold to send, or where the SOS in progress stands.
public struct SosCard: View {
    @Environment(GatewayModel.self) private var model
    @Environment(Router.self) private var router
    @State private var confirmSend = false
    @State private var confirmCancel = false
    @State private var confirmTest = false

    public init() {}

    public var body: some View {
        let reach = SosReach.from(model)
        let active = model.sosRun.flatMap { $0.active ? $0 : nil }
        let border = active == nil ? MSColors.border : (active!.test ? MSColors.amber : MSColors.red)
        VStack(alignment: .leading, spacing: 8) {
            if let active {
                Text(active.test ? "Alarm test running" : "SOS is on since \(Words.clock(active.id, "HH:mm"))")
                    .msText(.titleMedium, color: active.test ? MSColors.amber : MSColors.red)
                Text(SosProgress.summary(model.sosStatuses)).msText(.bodyMedium, color: MSColors.textSecondary)
                // A real emergency during a test: the hold still works, and replaces the test.
                if active.test {
                    HoldToSendButton(
                        label: "Hold 3 seconds for SOS", color: MSColors.red, onComplete: { model.startSos(test: false) },
                        onAccessibleActivate: { confirmSend = true })
                }
                HStack(spacing: 8) {
                    MSFilledButton("See where it went", container: MSColors.surfaceLight, labelColor: MSColors.offWhite) {
                        router.navigate(.sos)
                    }
                    MSOutlinedButton(active.test ? "Stop test" : "Cancel SOS") {
                        if active.test { model.cancelSos() } else { confirmCancel = true }
                    }
                }
            } else {
                Text("SOS").msText(.titleMedium)
                Text(reach.sentence()).msText(.bodyMedium, color: MSColors.textSecondary)
                if reach.anywhere {
                    HoldToSendButton(
                        label: "Hold 3 seconds for SOS", color: MSColors.red, onComplete: { model.startSos(test: false) },
                        onAccessibleActivate: { confirmSend = true })
                }
                HStack(spacing: 8) {
                    MSTextButton(
                        !reach.canSms ? "Connect your node" : (reach.contacts.isEmpty ? "Add emergency contacts" : "Emergency contacts"),
                        color: MSColors.offWhite
                    ) {
                        router.navigate(.setupSection(reach.canSms ? .safety : .node))
                    }
                    if reach.anywhere { MSTextButton("Test the alarm", color: MSColors.offWhite) { confirmTest = true } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MSSpace.card)
        .msCard(border: border)
        .overlay {
            if confirmSend {
                SendSosDialog(
                    onDismiss: { confirmSend = false },
                    onSend: {
                        confirmSend = false
                        model.startSos(test: false)
                    })
            }
            if confirmCancel {
                CancelSosDialog(
                    onDismiss: { confirmCancel = false },
                    onCancel: {
                        confirmCancel = false
                        model.cancelSos()
                    })
            }
            if confirmTest {
                TestAlarmDialog(
                    reach: reach, onDismiss: { confirmTest = false },
                    onTest: {
                        confirmTest = false
                        model.startSos(test: true)
                    })
            }
        }
    }
}

/// A strip under the status bar on every screen while an SOS or a test is on.
public struct SosBanner: View {
    @Environment(GatewayModel.self) private var model
    let onOpen: () -> Void

    public init(onOpen: @escaping () -> Void) { self.onOpen = onOpen }

    public var body: some View {
        if let active = model.sosRun, active.active {
            Button(action: onOpen) {
                Text(active.test ? "Alarm test running. Tap to see it." : "SOS is on. Tap to see where it went, or to cancel.")
                    .msText(.bodyMedium, color: MSColors.spaceBlack)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(active.test ? MSColors.amber : MSColors.red)
            }
            .buttonStyle(.plain)
        }
    }
}

/// The result screen: where each route of the SOS stands, and Cancel.
public struct SosScreen: View {
    @Environment(GatewayModel.self) private var model
    @Environment(Router.self) private var router
    @State private var confirmCancel = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let r = model.sosRun {
                    content(r)
                } else {
                    Text("No SOS has been sent from this phone.").msText(.bodyLarge)
                    MSTextButton("Emergency contacts and alarm test", color: MSColors.offWhite) { router.navigate(.setupSection(.safety)) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MSSpace.screen)
        }
        .background(MSColors.bg)
        .overlay {
            if confirmCancel {
                CancelSosDialog(
                    onDismiss: { confirmCancel = false },
                    onCancel: {
                        confirmCancel = false
                        model.cancelSos()
                    })
            }
        }
    }

    @ViewBuilder
    private func content(_ r: SosRun) -> some View {
        let statuses = model.sosStatuses
        let (title, color): (String, Color) =
            r.test && r.active
            ? ("Alarm test running", MSColors.amber)
            : r.test
                ? ("Alarm test finished", MSColors.textSecondary)
                : r.cancelledAt != nil
                    ? ("SOS cancelled at \(Words.clock(r.cancelledAt ?? 0, "HH:mm"))", MSColors.textSecondary)
                    : ("SOS is on", MSColors.red)
        Text(title).msText(.headlineSmall, color: color)
        let how = r.trigger == "checkin" ? "by the check-in timer" : "from this phone"
        let position: String =
            r.fix.map { f in "Position \(SosMessages.coordinates(f))" + (f.accuracyM.map { ", within \(Int($0.rounded())) m." } ?? ".") }
            ?? "Position unknown."
        Text("Started at \(Words.clock(r.id, "HH:mm")) \(how). \(position)").msText(.bodyMedium, color: MSColors.textSecondary)
        if r.cancelledAt != nil, !r.test {
            Text("Every route that carried the SOS is sending \"\(SosMessages.cancelText(name: r.name))\"").msText(
                .bodyMedium, color: MSColors.textSecondary)
        }
        VStack(alignment: .leading, spacing: 0) {
            if statuses.isEmpty { Text("Nothing could be sent.").msText(.bodyMedium).padding(12) }
            ForEach(Array(statuses.enumerated()), id: \.offset) { _, s in
                SosRouteRow(status: s, showCancel: r.cancelledAt != nil && !r.test)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .msCard()
        if !r.skipped.isEmpty {
            Text("Not used").msText(.titleSmall, color: MSColors.textSecondary)
            ForEach(r.skipped, id: \.self) { Text($0).msText(.bodySmall, color: MSColors.textMuted) }
        }
        if r.active {
            MSFilledButton(r.test ? "Stop test" : "Cancel SOS: I am safe", container: MSColors.surfaceLight, labelColor: MSColors.offWhite)
            {
                if r.test { model.cancelSos() } else { confirmCancel = true }
            }
            .padding(.top, 4)
        }
        MSTextButton("Emergency contacts and alarm test", color: MSColors.offWhite) { router.navigate(.setupSection(.safety)) }
    }
}

struct SosRouteRow: View {
    let status: SosRouteStatus
    let showCancel: Bool

    private var icon: (Image, Color) {
        switch status.state {
        case .sent: (MSIcon.done, MSColors.green)
        case .sending: (MSIcon.sync, MSColors.amber)
        case .waiting: (MSIcon.schedule, MSColors.amber)
        case .stopped: (MSIcon.block, MSColors.textMuted)
        case .failed: (MSIcon.errorOutline, MSColors.red)
        }
    }

    private func cancelWord(_ s: SosRouteStatus.State) -> String {
        switch s {
        case .sent: "sent"
        case .sending: "sending"
        case .waiting: "waiting to send"
        case .stopped: "stopped"
        case .failed: "failed"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.0.resizable().scaledToFit().frame(width: 20, height: 20).foregroundStyle(icon.1).padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                Text(status.label).msText(.bodyLarge)
                Text(status.detail).msText(.bodySmall, color: MSColors.textSecondary)
                if showCancel, let c = status.cancel {
                    Text("Cancellation: \(cancelWord(c))").msText(.bodySmall, color: MSColors.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

struct SendSosDialog: View {
    let onDismiss: () -> Void
    let onSend: () -> Void
    var body: some View {
        MSAlertDialog("Send an SOS?", onDismiss: onDismiss) {
            Text("Your position goes out on every route this phone has, and the phone keeps trying until you cancel.").msText(.bodyMedium)
        } buttons: {
            MSTextButton("Don't send", color: MSColors.offWhite, action: onDismiss)
            MSFilledButton("Send SOS", container: MSColors.red, fullWidth: false, action: onSend)
        }
    }
}

struct CancelSosDialog: View {
    let onDismiss: () -> Void
    let onCancel: () -> Void
    var body: some View {
        MSAlertDialog("Cancel the SOS?", onDismiss: onDismiss) {
            Text("Nothing more goes out, and everyone who got the SOS is told you are safe.").msText(.bodyMedium)
        } buttons: {
            MSTextButton("Keep it on", color: MSColors.offWhite, action: onDismiss)
            MSFilledButton("Cancel SOS", fullWidth: false, action: onCancel)
        }
    }
}

struct TestAlarmDialog: View {
    let reach: SosReach
    let onDismiss: () -> Void
    let onTest: () -> Void
    @Environment(GatewayModel.self) private var model

    var body: some View {
        let name = model.sosName.isEmpty ? model.hubCallsign : model.sosName
        let text = SosMessages.testText(name: name)
        // What each route carries, and what it costs: the satellite leg is a 31-byte position
        // report when the phone has a fix (one credit), the text otherwise.
        var parts: [String] = []
        if reach.satellite { parts.append("a position report to the Hub by satellite, 1 credit") }
        if reach.mesh { parts.append("the text on the mesh") }
        if reach.sms {
            parts.append(
                reach.contacts.count == 1
                    ? "the text by SMS to \(reach.contacts[0].name.isEmpty ? "1 contact" : reach.contacts[0].name), at your carrier's rate"
                    : "the text by SMS to \(reach.contacts.count) contacts, at your carrier's rate")
        }
        if reach.hub { parts.append("a test event to the Hub online") }
        let list = parts.count <= 1 ? parts.joined() : parts.dropLast().joined(separator: "; ") + "; and " + (parts.last ?? "")
        return MSAlertDialog("Test the alarm?", onDismiss: onDismiss) {
            Text("The test text is \"\(text)\". It goes as \(list). Nobody is alarmed, and the Hub does not raise an SOS.").msText(
                .bodyMedium)
        } buttons: {
            MSTextButton("Not now", color: MSColors.offWhite, action: onDismiss)
            MSFilledButton("Send the test", fullWidth: false, action: onTest)
        }
    }
}

/// Setup > Safety: who an SOS goes to, the name it gives, and the test.
public struct SosSettingsCard: View {
    @Environment(GatewayModel.self) private var model
    @State private var name: String?
    @State private var newName = ""
    @State private var newPhone = ""
    @State private var phoneError: String?
    @State private var confirmTest = false
    @State private var typing = false
    @State private var picking = false

    public init() {}

    public var body: some View {
        let reach = SosReach.from(model)
        let contacts = model.sosContacts
        VStack(alignment: .leading, spacing: 8) {
            Text("SOS").msText(.titleMedium)
            Text(reach.sentence()).msText(.bodySmall, color: MSColors.textSecondary)
            MSOutlinedTextField(
                text: Binding(
                    get: { name ?? model.sosName },
                    set: { v in
                        let clean = String(v.prefix(SosMessages.maxName))
                        name = clean
                        model.setSosName(clean.trimmingCharacters(in: .whitespaces))
                    }),
                placeholder: model.hubCallsign.isEmpty ? "A MeshSat user" : model.hubCallsign, label: "Your name in an SOS")
            if reach.canSms {
                Text("Emergency contacts").msText(.titleSmall).padding(.top, 4)
                Text("Each one gets an SMS with your position and a map link, sent from the Messages app when you tap Send.")
                    .msText(.bodySmall, color: MSColors.textMuted)
                ForEach(contacts, id: \.phone) { c in
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c.name.isEmpty ? c.phone : c.name).msText(.bodyMedium)
                            if !c.name.isEmpty { Text(c.phone).msText(.bodySmall, color: MSColors.textSecondary) }
                        }
                        .padding(.vertical, 8)
                        Spacer(minLength: 8)
                        MSIconButton(MSIcon.close, label: "Remove \(c.name.isEmpty ? c.phone : c.name)", tint: MSColors.textSecondary) {
                            model.setSosContacts(contacts.filter { $0 != c })
                        }
                    }
                    .padding(.leading, 12)
                    .background(MSColors.surfaceLight, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                if contacts.count < EmergencyContact.max {
                    // The phone's own contacts first (owner, 21 Sep 2026): nobody knows a number by
                    // heart, and a number typed under stress is a number typed wrong.
                    MSFilledButton("Choose from your contacts", fullWidth: false) {
                        phoneError = nil
                        picking = true
                    }
                    if !typing {
                        if let phoneError { Text(phoneError).msText(.bodySmall, color: MSColors.amber) }
                        MSTextButton("Or type a number", color: MSColors.textSecondary) { typing = true }
                    } else {
                        MSOutlinedTextField(text: $newName, label: "Name")
                        MSOutlinedTextField(
                            text: $newPhone, placeholder: "+31 6 1234 5678", label: "Phone number, with country code", keyboard: .phonePad)
                        if let phoneError { Text(phoneError).msText(.bodySmall, color: MSColors.amber) }
                        MSOutlinedButton("Add this number", enabled: !newPhone.trimmingCharacters(in: .whitespaces).isEmpty) {
                            addTyped(contacts)
                        }
                    }
                }
            } else {
                Text("This device cannot send SMS, so an SOS goes by satellite, the mesh and the Hub only.").msText(
                    .bodySmall, color: MSColors.textMuted)
            }
            Text("Test the alarm").msText(.titleSmall).padding(.top, 4)
            Text(
                "Sends a test on every route an SOS would take, and shows what got through. "
                    + "It says it is a test, and raises nothing at the Hub."
            )
            .msText(.bodySmall, color: MSColors.textMuted)
            let canTest = reach.anywhere && !(model.sosRun?.active ?? false)
            MSOutlinedButton("Test the alarm", enabled: canTest) { confirmTest = true }
            if !reach.anywhere { Text("A test needs somewhere to go first.").msText(.bodySmall, color: MSColors.textMuted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MSSpace.card)
        .msCard()
        .sheet(isPresented: $picking) {
            ContactPicker { picked in
                picking = false
                guard let picked else { return }
                switch EmergencyContact.adding(contacts, name: picked.name, rawPhone: picked.phone) {
                case .no(let why): phoneError = why
                case .ok(let list):
                    phoneError = nil
                    model.setSosContacts(list)
                }
            }
            .ignoresSafeArea()
        }
        .overlay {
            if confirmTest {
                TestAlarmDialog(
                    reach: reach, onDismiss: { confirmTest = false },
                    onTest: {
                        confirmTest = false
                        model.startSos(test: true)
                    })
            }
        }
    }

    private func addTyped(_ contacts: [EmergencyContact]) {
        switch EmergencyContact.adding(contacts, name: newName.replacingOccurrences(of: "\t", with: " "), rawPhone: newPhone) {
        case .no(let why): phoneError = why
        case .ok(let list):
            model.setSosContacts(list)
            newName = ""
            newPhone = ""
            typing = false
            phoneError = nil
        }
    }
}

/// The system contact picker for one phone number: no contacts permission, one row handed over.
struct ContactPicker: UIViewControllerRepresentable {
    let onPick: ((name: String, phone: String)?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let vc = CNContactPickerViewController()
        vc.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        vc.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        vc.predicateForSelectionOfProperty = NSPredicate(format: "key == 'phoneNumbers'")
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: ((name: String, phone: String)?) -> Void
        init(onPick: @escaping ((name: String, phone: String)?) -> Void) { self.onPick = onPick }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { onPick(nil) }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            let name = CNContactFormatter.string(from: contactProperty.contact, style: .fullName) ?? ""
            let phone = (contactProperty.value as? CNPhoneNumber)?.stringValue ?? ""
            onPick((name, phone))
        }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            let phone = contact.phoneNumbers.first?.value.stringValue ?? ""
            onPick((name, phone))
        }
    }
}
