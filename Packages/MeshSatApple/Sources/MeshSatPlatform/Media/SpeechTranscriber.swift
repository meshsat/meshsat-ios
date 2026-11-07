// Mirrors audio/SpeechTranscriber.kt (MESHSAT-1735): the platform's speech recogniser listening
// beside the voice recorder, so a note can go as text where the bytes cannot (SMS, satellite, the
// mesh). What it heard is a proposal the sender confirms; a phone without a recogniser, or one the
// person did not allow, gives nothing and the text stays as typed. On the phone itself when iOS
// can (`requiresOnDeviceRecognition`), otherwise Apple's recogniser as iOS offers it.
import AVFoundation
import Foundation
import Speech

public final class SpeechTranscriber: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var partial = ""
    private var onDone: (@Sendable (String?) -> Void)?

    public init() {}

    /// Asks for speech recognition once; false when not allowed or not offered.
    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    public static var available: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && (SFSpeechRecognizer()?.isAvailable ?? false)
    }

    /// Starts listening; `onResult` gets the transcript, or nil, once (after `stop` or an error).
    public func start(onResult: @escaping @Sendable (String?) -> Void) {
        guard Self.available, let recognizer = SFSpeechRecognizer() else { return onResult(nil) }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        lock.lock()
        request = req
        partial = ""
        onDone = onResult
        lock.unlock()
        let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.finish(text.isEmpty ? nil : text)
                    return
                }
                self.lock.lock()
                if !text.isEmpty { self.partial = text }
                self.lock.unlock()
            }
            if error != nil { self.finish(nil) }
        }
        lock.lock()
        task = t
        lock.unlock()
    }

    /// One buffer from the recorder's tap.
    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let req = request
        lock.unlock()
        req?.append(buffer)
    }

    /// The finger lifted: ask for the final result.
    public func stop() {
        lock.lock()
        let req = request
        lock.unlock()
        req?.endAudio()
    }

    public func cancel() {
        lock.lock()
        let t = task
        task = nil
        request = nil
        onDone = nil
        lock.unlock()
        t?.cancel()
    }

    private func finish(_ text: String?) {
        lock.lock()
        let cb = onDone
        let fallback = partial
        onDone = nil
        request = nil
        task = nil
        lock.unlock()
        cb?(text ?? (fallback.isEmpty ? nil : fallback))
    }
}
