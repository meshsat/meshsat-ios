// Mirrors audio/VoiceNotePlayer.kt (MESHSAT-1735): plays one voice note at a time. Android hands
// the Ogg file to MediaPlayer; here the Kit's OggOpus unwraps the packets, AVAudioConverter decodes
// them to 48 kHz PCM (Sideband's 60 ms packets as well as our 20 ms ones), the pre-skip is dropped,
// and an AVAudioPlayerNode plays it. Starting another note stops the one playing. `playing` names
// the attachment id that sounds now, or 0. Codec2 notes are shown without a play button, as on
// Android (there is no Codec2 decoder on either phone).
import AVFoundation
import Foundation
import MeshSatLXMF
import MeshSatNet

public final class VoiceNotePlayer: @unchecked Sendable {
    public static let shared = VoiceNotePlayer()

    /// The attachment id playing now, or 0.
    public let playing = StateBroadcast<Int64>(0)
    /// The last failure, "" when none.
    public let error = StateBroadcast<String>("")

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var current: Int64 = 0

    public func play(id: Int64, ogg: [UInt8]) {
        stop()
        error.send("")
        do {
            let pcm = try Self.decode(ogg)
            try start(id: id, pcm)
        } catch {
            self.error.send("Cannot play this note: \(error)")
            playing.send(0)
        }
    }

    private func start(id: Int64, _ pcm: AVAudioPCMBuffer) throws {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: pcm.format)
        try engine.start()
        lock.lock()
        self.engine = engine
        self.node = node
        current = id
        lock.unlock()
        playing.send(id)
        node.scheduleBuffer(pcm, at: nil, options: []) { [weak self] in self?.finished(id) }
        node.play()
    }

    private func finished(_ id: Int64) {
        lock.lock()
        let mine = current == id
        lock.unlock()
        if mine { stop() }
    }

    public func stop() {
        lock.lock()
        let engine = self.engine
        let node = self.node
        self.engine = nil
        self.node = nil
        current = 0
        lock.unlock()
        node?.stop()
        engine?.stop()
        playing.send(0)
    }

    /// The note as 48 kHz mono float PCM, its pre-skip dropped. Throws on anything but Ogg Opus.
    public static func decode(_ ogg: [UInt8]) throws -> AVAudioPCMBuffer {
        let stream = try OggOpus.read(ogg)
        guard let first = stream.packets.first else { throw OggError("an empty note") }
        let frames = OggOpus.packetSamples48k(first)
        var desc = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(frames),
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(1, stream.head.channels)), mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &desc),
            let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(max(1, stream.head.channels)),
                interleaved: false),
            let converter = AVAudioConverter(from: opus, to: pcmFormat)
        else { throw OggError("no Opus decoder") }
        let maxPacket = stream.packets.map(\.count).max() ?? 1
        let input = AVAudioCompressedBuffer(
            format: opus, packetCapacity: AVAudioPacketCount(stream.packets.count), maximumPacketSize: maxPacket)
        var offset = 0
        let base = input.data.assumingMemoryBound(to: UInt8.self)
        for (i, p) in stream.packets.enumerated() {
            p.withUnsafeBufferPointer { src in (base + offset).update(from: src.baseAddress!, count: p.count) }
            input.packetDescriptions?[i] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset), mVariableFramesInPacket: UInt32(OggOpus.packetSamples48k(p)), mDataByteSize: UInt32(p.count))
            offset += p.count
        }
        input.packetCount = AVAudioPacketCount(stream.packets.count)
        input.byteLength = UInt32(offset)
        let total = AVAudioFrameCount(max(stream.samples48k, 1))
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: total + 4096) else { throw OggError("no memory") }
        var given = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inStatus in
            if given {
                inStatus.pointee = .endOfStream
                return nil
            }
            given = true
            inStatus.pointee = .haveData
            return input
        }
        if status == .error { throw OggError("decoder: \(err?.localizedDescription ?? "failed")") }
        // RFC 7845 4.2: the first pre-skip samples are the encoder's warm-up, not the note.
        let skip = min(AVAudioFrameCount(stream.head.preSkip), out.frameLength)
        if skip > 0, let ch = out.floatChannelData {
            let keep = out.frameLength - skip
            for c in 0..<Int(pcmFormat.channelCount) { ch[c].update(from: ch[c] + Int(skip), count: Int(keep)) }
            out.frameLength = keep
        }
        return out
    }
}
