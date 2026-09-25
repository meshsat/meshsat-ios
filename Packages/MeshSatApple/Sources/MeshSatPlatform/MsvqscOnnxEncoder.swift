// Mirrors crypto/MsvqscEncoder.kt: text to an MSVQ-SC frame through the all-MiniLM-L6-v2
// sentence encoder (encoder.onnx, ONNX Runtime), mean pooling and L2 normalisation, then the
// codebook's residual quantiser (MeshSatMsvqsc). Android runs the same model with ONNX Runtime
// for Android; the numbers are the same, so both apps write the same frames.
import Foundation
import Logging
import MeshSatMsvqsc
import OnnxRuntimeBindings

public final class MsvqscOnnxEncoder: MsvqscEncoding, @unchecked Sendable {
    private static let log = Logger(label: "MsvqscEncoder")
    private let tokenizer: WordPieceTokenizer
    private let codebook: MsvqscCodebook
    private let lock = NSLock()
    private let env: ORTEnv
    private let session: ORTSession
    private let inputNames: [String]
    private let outputName: String

    /// The model file, the vocabulary text and the loaded codebook; nil when the runtime cannot
    /// open the model.
    public init?(modelURL: URL, vocabText: String, codebook: MsvqscCodebook) {
        self.tokenizer = WordPieceTokenizer(vocabText: vocabText)
        self.codebook = codebook
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(2)
            let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
            self.env = env
            self.session = session
            inputNames = try session.inputNames()
            guard let first = try session.outputNames().first else { return nil }
            outputName = first
            let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? Int) ?? 0
            Self.log.info("ONNX encoder loaded (\(size / 1024 / 1024) MB), inputs \(inputNames)")
        } catch {
            Self.log.error("Failed to load ONNX encoder: \(error)")
            return nil
        }
    }

    /// The frame, or nil when the model run fails.
    public func encode(_ text: String, maxStages: Int = 3) -> [UInt8]? {
        guard let embedding = embed(text) else { return nil }
        return codebook.encode(embedding: embedding, maxStages: maxStages)
    }

    /// The pooled, normalised sentence embedding.
    public func embed(_ text: String) -> [Float]? {
        let tokens = tokenizer.tokenize(text)
        let seqLen = tokens.ids.count
        lock.lock()
        defer { lock.unlock() }
        do {
            let shape: [NSNumber] = [1, NSNumber(value: seqLen)]
            var ids = tokens.ids.map { Int64($0) }
            var mask = tokens.attentionMask.map { Int64($0) }
            let idsData = NSMutableData(bytes: &ids, length: seqLen * MemoryLayout<Int64>.size)
            let maskData = NSMutableData(bytes: &mask, length: seqLen * MemoryLayout<Int64>.size)
            let idsTensor = try ORTValue(tensorData: idsData, elementType: .int64, shape: shape)
            let maskTensor = try ORTValue(tensorData: maskData, elementType: .int64, shape: shape)
            var inputs: [String: ORTValue] = ["input_ids": idsTensor, "attention_mask": maskTensor]
            // Some exports of the model also take token_type_ids: zeros then.
            if inputNames.contains("token_type_ids") {
                var types = [Int64](repeating: 0, count: seqLen)
                let typesData = NSMutableData(bytes: &types, length: seqLen * MemoryLayout<Int64>.size)
                inputs["token_type_ids"] = try ORTValue(tensorData: typesData, elementType: .int64, shape: shape)
            }
            let outputs = try session.run(withInputs: inputs, outputNames: [outputName], runOptions: nil)
            guard let out = outputs[outputName] else { return nil }
            let info = try out.tensorTypeAndShapeInfo()
            let dims = info.shape.map(\.intValue)
            // [1, seq_len, dim]: mean pooling over the attended tokens, then L2 normalisation.
            guard dims.count == 3, dims[1] == seqLen else {
                Self.log.warning("Unexpected encoder output shape \(dims)")
                return nil
            }
            let dim = dims[2]
            let data = try out.tensorData() as Data
            let floats: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard floats.count >= seqLen * dim else { return nil }
            var pooled = [Float](repeating: 0, count: dim)
            var count: Float = 0
            for i in 0..<seqLen where tokens.attentionMask[i] == 1 {
                for d in 0..<dim { pooled[d] += floats[i * dim + d] }
                count += 1
            }
            if count > 0 { for d in 0..<dim { pooled[d] /= count } }
            let n = pooled.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if n > 0 { for d in 0..<dim { pooled[d] /= n } }
            return pooled
        } catch {
            Self.log.error("Encode failed: \(error)")
            return nil
        }
    }
}
