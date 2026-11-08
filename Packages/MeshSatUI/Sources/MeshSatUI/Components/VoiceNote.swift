// Mirrors ui/components/VoiceNote.kt (MESHSAT-1735): the microphone on the chat composer (a note
// records while the button is held and ends when the finger lifts or at 30 s, with the speech
// recogniser listening beside it), the pending attachments above the message box, the transcript
// proposal, and the voice note and photo cards in the bubbles. With VoiceOver, where holding is
// awkward, a double tap starts the note and another ends it.
import MeshSatLXMF
import MeshSatPlatform
import MeshSatStore
import SwiftUI
import UIKit

/// What the composer holds before a send.
struct PendingNote: Equatable {
    var ogg: [UInt8]
    var ms: Int64
}

struct RecordNoteButton: View {
    let onNote: (PendingNote) -> Void
    let onTranscript: (String) -> Void
    var enabled = true
    @Environment(GatewayModel.self) private var model
    @State private var recorder: VoiceRecorder?
    @State private var transcriber: SpeechTranscriber?
    @State private var elapsedMs: Int64 = 0
    @State private var watch: [Task<Void, Never>] = []
    @State private var starting = false
    // Goes back to false by itself when the gesture is cancelled too, as by the permission alert.
    @GestureState private var fingerDown = false

    private var recording: Bool { recorder != nil }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: recording ? "mic.fill" : "mic")
                .resizable().scaledToFit().frame(width: 20, height: 20)
                .foregroundStyle(recording ? MSColors.red : (enabled ? MSColors.teal : MSColors.textMuted))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).updating($fingerDown) { _, down, _ in down = true })
                .onChange(of: fingerDown) { _, down in
                    if down {
                        if !recording, enabled { begin(whileHeld: true) }
                    } else if recording {
                        end()
                    }
                }
                .accessibilityLabel(recording ? "Stop the voice note" : "Hold to record a voice note")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { recording ? end() : begin() }
            if recording {
                Text("Recording, \(AttachmentPolicy.seconds(elapsedMs))").msText(.labelMedium, color: MSColors.red)
            }
        }
    }

    private func begin(whileHeld: Bool = false) {
        guard !starting else { return }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            guard await VoiceRecorder.requestPermission() else {
                model.showToast("The microphone is not allowed for MeshSat. Allow it in the iPhone's Settings.")
                return
            }
            _ = await SpeechTranscriber.requestPermission()
            // Nothing else can run from here until the recorder is set: a finger that lifted
            // during the wait above has asked for nothing, and no lift would ever end this one.
            if whileHeld, !fingerDown { return }
            let r = VoiceRecorder()
            let t = SpeechTranscriber()
            r.onBuffer = { [t] buffer in t.append(buffer) }
            do {
                try r.start()
            } catch {
                model.showToast("\(error)")
                return
            }
            t.start { text in
                Task { @MainActor in if let text, !text.isEmpty { onTranscript(text) } }
            }
            recorder = r
            transcriber = t
            elapsedMs = 0
            let elapsed = r.elapsedMs.subscribe()
            let maxed = r.reachedMax.subscribe()
            watch = [
                Task { @MainActor in for await ms in elapsed { elapsedMs = ms } },
                Task { @MainActor in
                    for await hit in maxed where hit {
                        end()
                        return
                    }
                },
            ]
        }
    }

    private func end() {
        guard let r = recorder else { return }
        recorder = nil
        for t in watch { t.cancel() }
        watch = []
        let note = r.stop()
        transcriber?.stop()
        transcriber = nil
        // A tap shorter than the encoder's start-up is not a note.
        guard !note.ogg.isEmpty, note.durationMs >= 300 else { return }
        onNote(PendingNote(ogg: note.ogg, ms: note.durationMs))
    }
}

/// The attachments waiting for Send, each with a way to drop it, and the policy line under them.
struct PendingAttachments: View {
    let note: PendingNote?
    let photo: [UInt8]?
    let transport: String
    let onDropNote: () -> Void
    let onDropPhoto: () -> Void

    var body: some View {
        if note != nil || photo != nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let note {
                        chip("Voice note, \(AttachmentPolicy.seconds(note.ms)), \(AttachmentPolicy.size(note.ogg.count))", onDropNote)
                    }
                    if let photo { chip("Photo, \(AttachmentPolicy.size(photo.count))", onDropPhoto) }
                }
                if let line = AttachmentPolicy.note(
                    transport, audioBytes: note?.ogg.count ?? 0, audioMs: note?.ms ?? 0, imageBytes: photo?.count ?? 0)
                {
                    Text(line).msText(.bodySmall, color: AttachmentPolicy.carries(transport) ? MSColors.textSecondary : MSColors.amber)
                }
            }
        }
    }

    private func chip(_ text: String, _ drop: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text).msText(.labelMedium, color: MSColors.offWhite)
            MSIconButton(MSIcon.close, label: "Remove", tint: MSColors.textMuted, size: 20, glyph: 12, action: drop)
        }
        .padding(.leading, 8)
        .background(MSColors.teal.opacity(0.18), in: Capsule())
    }
}

/// "Heard: ..." with Use as text / Discard: what the recogniser made of the note, never sent by itself.
struct TranscriptProposal: View {
    let text: String
    let onUse: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Heard: \(text)").msText(.bodySmall, color: MSColors.textSecondary)
            HStack(spacing: 12) {
                MSTextButton("Use as text", color: MSColors.teal, action: onUse)
                MSTextButton("Discard", color: MSColors.textMuted, action: onDiscard)
            }
        }
    }
}

/// A voice note in a bubble: play/stop for Opus, a line for a Codec2 note this phone cannot decode.
struct VoiceNoteCard: View {
    let attachment: MessageAttachmentRecord
    @State private var playing: Int64 = 0
    @State private var error = ""

    var body: some View {
        let opus = attachment.mode >= LxFields.audioModeOpusFirst && attachment.mode <= LxFields.audioModeOpusLast
        let ms = opus ? ((try? OggOpus.read(attachment.data))?.durationMs ?? 0) : 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if opus {
                    let on = playing == attachment.id
                    MSIconButton(
                        Image(systemName: on ? "stop.fill" : "play.fill"), label: on ? "Stop" : "Play the voice note", tint: MSColors.teal,
                        size: 32, glyph: 16
                    ) {
                        if on {
                            VoiceNotePlayer.shared.stop()
                        } else {
                            VoiceNotePlayer.shared.play(id: attachment.id, ogg: attachment.data)
                        }
                    }
                    Text("Voice note, \(AttachmentPolicy.seconds(ms))").msText(.bodyMedium)
                } else {
                    Text(
                        "Voice note (\(LxFields.audioModeName(attachment.mode))), \(AttachmentPolicy.size(attachment.data.count)); "
                            + "this phone cannot play it"
                    ).msText(.bodySmall, color: MSColors.textMuted)
                }
            }
            if !error.isEmpty { Text(error).msText(.bodySmall, color: MSColors.red) }
        }
        .task {
            for await id in VoiceNotePlayer.shared.playing.subscribe() { playing = id }
        }
        .task {
            for await e in VoiceNotePlayer.shared.error.subscribe() { error = playing == attachment.id ? e : "" }
        }
    }
}

/// A photo in a bubble, as received (ImageIO reads WebP).
struct PhotoCard: View {
    let attachment: MessageAttachmentRecord

    var body: some View {
        if let image = UIImage(data: Data(attachment.data)) {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Photo, \(AttachmentPolicy.size(attachment.data.count))")
        } else {
            Text("Photo (\(attachment.format)), \(AttachmentPolicy.size(attachment.data.count)); this phone cannot show it")
                .msText(.bodySmall, color: MSColors.textMuted)
        }
    }
}
