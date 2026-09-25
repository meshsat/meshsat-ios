// Mirrors initMsvqsc and the compression step of forwardToIridium in service/GatewayService.kt
// (MESHSAT-1329): the codebook and the corpus index from the app bundle (pure Swift, decode
// and quantise), the ONNX sentence encoder on top (embed), both into the transform pipeline;
// a satellite message on a lane set to "msvqsc" goes out as a versioned MSVQ-SC frame.
import Foundation
import MeshSatEngine
import MeshSatMsvqsc
import MeshSatWire

/// The codec's parts, one locked value (the GatewayController body is at the lint limit).
final class MsvqscParts: @unchecked Sendable {
    struct State {
        var codebook: MsvqscCodebook?
        var encoder: MsvqscOnnxEncoder?
    }
    private let lock = NSLock()
    private var value = State()
    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func update(_ change: (inout State) -> Void) {
        lock.lock()
        change(&value)
        lock.unlock()
    }
}

extension GatewayController {
    public var msvqscCodebook: MsvqscCodebook? { msvqsc.state.codebook }
    public var msvqscEncoder: MsvqscOnnxEncoder? { msvqsc.state.encoder }
    public var msvqscReady: Bool { msvqsc.state.encoder != nil }

    /// The four files ship in the app bundle, as Android's assets.
    static func bundledModelURL(_ name: String) -> URL? {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        return Bundle.main.url(forResource: parts[0], withExtension: parts.count > 1 ? parts[1] : nil)
    }

    /// GatewayService.initMsvqsc: in the background, the codebook first (12 MB, decode works
    /// from it alone), then the encoder (23 MB model).
    func initMsvqsc() {
        keep(
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                guard let cbURL = Self.bundledModelURL("codebook_v1.bin"), let ciURL = Self.bundledModelURL("corpus_index.bin") else {
                    Self.log.warning("MSVQ-SC: codebook files not in the bundle (compression disabled)")
                    return
                }
                do {
                    let codebook = try MsvqscCodebook.load(
                        codebook: [UInt8](try Data(contentsOf: cbURL)), corpusIndex: [UInt8](try Data(contentsOf: ciURL)))
                    msvqsc.update { $0.codebook = codebook }
                    transformPipeline.msvqscCodebook = codebook
                    Self.log.info("MSVQ-SC codebook loaded: \(codebook.stages) stages, K=\(codebook.k), dim=\(codebook.dim)")
                    guard let modelURL = Self.bundledModelURL("encoder.onnx"), let vocabURL = Self.bundledModelURL("vocab.txt") else {
                        Self.log.warning("MSVQ-SC: encoder files not in the bundle (decode only)")
                        return
                    }
                    let vocab = try String(contentsOf: vocabURL, encoding: .utf8)
                    guard let encoder = MsvqscOnnxEncoder(modelURL: modelURL, vocabText: vocab, codebook: codebook) else { return }
                    msvqsc.update { $0.encoder = encoder }
                    transformPipeline.msvqscEncoder = encoder
                    Self.log.info("MSVQ-SC encoder ready (\(codebook.stages) stages, K=\(codebook.k))")
                } catch {
                    Self.log.warning("MSVQ-SC init failed (compression disabled): \(error)")
                }
            })
    }

    /// The stage count from the settings: "auto" and anything unreadable mean 3.
    var msvqscStages: Int {
        let s = settings.get(SettingsKey.msvqscStages).trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s == "auto" ? 3 : (Int(s) ?? 3)
    }

    /// forwardToIridium's compression step: the text as a versioned MSVQ-SC frame when the
    /// satellite lane is set to "msvqsc" and the encoder is up; the text's bytes otherwise.
    func satelliteBytes(for text: String) -> [UInt8] {
        let plain = Array(text.utf8)
        guard settings.get(SettingsKey.compressIridium) == "msvqsc", let encoder = msvqsc.state.encoder else { return plain }
        let stages = msvqscStages
        guard let wire = encoder.encode(text, maxStages: stages) else { return plain }
        let data = ProtocolVersion.prependVersionByte(wire)
        Self.log.debug("Iridium TX compressed: \(text.count) chars to \(data.count) bytes (MSVQ-SC \(stages) stages)")
        return data
    }

    /// An inbound frame that is MSVQ-SC behind the version byte, as text; nil for anything else.
    func msvqscText(from payload: [UInt8]) -> String? {
        guard let codebook = msvqsc.state.codebook else { return nil }
        let stripped = ProtocolVersion.stripVersionByte(payload)
        guard stripped.version == ProtocolVersion.protoVersion1, MsvqscWire.looksLikeMsvqsc(stripped.data) else { return nil }
        return try? codebook.decode(stripped.data)
    }
}
