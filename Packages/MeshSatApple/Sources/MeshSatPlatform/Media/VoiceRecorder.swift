// Mirrors audio/VoiceRecorder.kt (MESHSAT-1735): the microphone while a voice note is held. Android
// has MediaRecorder write Ogg Opus; here AVAudioEngine's input goes through two AVAudioConverters,
// to 48 kHz mono PCM and then to raw Opus packets (960 frames, 16 kbit/s, what the 7 Nov 2026 spike
// measured: SILK wideband, TOC 0x48, 312 frames of pre-skip), and the Kit's OggOpus wraps them. So
// the bytes go into FIELD_AUDIO as mode 0x10 and play unchanged in Sideband, MeshChat and Android.
// Stopped by the finger lifting, or `reachedMax` turns true at the length or the size limit.
// The PCM also goes to `onBuffer`, where the speech recogniser listens.
import AVFoundation
import Foundation
import MeshSatLXMF
import MeshSatNet

public enum VoiceRecorderError: Error, CustomStringConvertible {
    case microphoneDenied, cannotOpen(String)

    public var description: String {
        switch self {
        case .microphoneDenied: "The microphone is not allowed for MeshSat. Allow it in the iPhone's Settings."
        case .cannotOpen(let why): "The microphone could not be opened: \(why)"
        }
    }
}

public final class VoiceRecorder: @unchecked Sendable {
    public static let sampleRate = 48_000.0
    public static let bitRate = 16_000
    public static let framesPerPacket: AVAudioFrameCount = 960

    /// Milliseconds recorded so far, ten times a second.
    public let elapsedMs = StateBroadcast<Int64>(0)
    /// True once the note hit `maxMs` or `maxBytes`; the button ends it.
    public let reachedMax = StateBroadcast<Bool>(false)
    /// Every input buffer, for the speech recogniser (called on the audio thread).
    public var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    private let maxMs: Int64
    private let maxBytes: Int
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var toPcm: AVAudioConverter?
    private var toOpus: AVAudioConverter?
    private var pcmFormat: AVAudioFormat?
    private var opusFormat: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []
    private var packets: [[UInt8]] = []
    private var bytes = 0
    private var framesIn: AVAudioFramePosition = 0
    private var ended = false

    public init(maxMs: Int64 = AttachmentPolicy.maxNoteMs, maxBytes: Int = LxFields.maxAttachmentBytes) {
        self.maxMs = maxMs
        self.maxBytes = maxBytes
    }

    /// Whether this phone may record: asks once, as iOS shows the microphone question.
    public static func requestPermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) { return await AVAudioApplication.requestRecordPermission() }
        return false
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    public func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            throw VoiceRecorderError.cannotOpen("\(error.localizedDescription)")
        }
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
            let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
            let toPcm = AVAudioConverter(from: inFormat, to: pcm)
        else { throw VoiceRecorderError.cannotOpen("no input") }
        var desc = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &desc), let toOpus = AVAudioConverter(from: pcm, to: opus) else {
            throw VoiceRecorderError.cannotOpen("no Opus encoder")
        }
        toOpus.bitRate = Self.bitRate
        lock.lock()
        self.engine = engine
        self.toPcm = toPcm
        self.toOpus = toOpus
        pcmFormat = pcm
        opusFormat = opus
        pending = []
        packets = []
        bytes = 0
        framesIn = 0
        ended = false
        lock.unlock()
        elapsedMs.send(0)
        reachedMax.send(false)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in self?.take(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceRecorderError.cannotOpen(error.localizedDescription)
        }
    }

    /// One input buffer: to 48 kHz mono, into the encoder, the packets kept.
    private func take(_ buffer: AVAudioPCMBuffer) {
        onBuffer?(buffer)
        lock.lock()
        defer { lock.unlock() }
        guard !ended, let toPcm, let pcmFormat else { return }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return }
        var given = false
        _ = toPcm.convert(to: out, error: nil) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0 else { return }
        pending.append(out)
        framesIn += AVAudioFramePosition(out.frameLength)
        encode(flush: false)
        let ms = Int64(Double(framesIn) / Self.sampleRate * 1000)
        elapsedMs.send(ms)
        if ms >= maxMs || bytes >= maxBytes - 512 { reachedMax.send(true) }
    }

    /// Runs the Opus encoder over what is pending; at the end, flushes it. Under the lock.
    private func encode(flush: Bool) {
        guard let toOpus, let opusFormat else { return }
        while true {
            let out = AVAudioCompressedBuffer(
                format: opusFormat, packetCapacity: 16, maximumPacketSize: max(toOpus.maximumOutputPacketSize, 1500))
            var endSent = false
            let status = toOpus.convert(to: out, error: nil) { [self] _, inStatus in
                if !pending.isEmpty {
                    inStatus.pointee = .haveData
                    return pending.removeFirst()
                }
                if flush, !endSent {
                    endSent = true
                    inStatus.pointee = .endOfStream
                    return nil
                }
                inStatus.pointee = .noDataNow
                return nil
            }
            collect(out)
            if status != .haveData || out.packetCount == 0 { break }
        }
    }

    private func collect(_ out: AVAudioCompressedBuffer) {
        guard let descs = out.packetDescriptions else { return }
        let base = out.data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<Int(out.packetCount) {
            let d = descs[i]
            let p = Array(UnsafeBufferPointer(start: base + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
            if !p.isEmpty {
                packets.append(p)
                bytes += p.count
            }
        }
    }

    /// Ends the note: the Ogg Opus bytes and how long it plays; empty bytes when nothing was
    /// recorded (a tap, not a note).
    public func stop() -> (ogg: [UInt8], durationMs: Int64) {
        lock.lock()
        let engine = self.engine
        lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        lock.lock()
        encode(flush: true)
        ended = true
        let out = packets
        let preSkip = Int(toOpus?.primeInfo.leadingFrames ?? 312)
        self.engine = nil
        lock.unlock()
        deactivate()
        guard !out.isEmpty else { return ([], 0) }
        let head = OggOpus.Head(channels: 1, preSkip: preSkip == 0 ? 312 : preSkip, inputSampleRate: Int(Self.sampleRate))
        guard let ogg = try? OggOpus.write(head: head, packets: out), let stream = try? OggOpus.read(ogg) else { return ([], 0) }
        return (ogg, stream.durationMs)
    }

    public func cancel() {
        lock.lock()
        let engine = self.engine
        ended = true
        self.engine = nil
        packets = []
        pending = []
        lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        deactivate()
    }

    private func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
