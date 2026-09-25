// Mirrors crypto/MsvqscCodebook.kt and the quantiser of crypto/MsvqscEncoder.kt: the
// residual-VQ codebook ("MSVQ": version, stages, K, dim, then float32 vectors) and the corpus
// index ("MCIX": version, count, dim, then text and embedding per entry). Decoding sums the
// stage vectors and picks the nearest corpus sentence by cosine similarity; encoding
// quantises an embedding stage by stage. Neither needs a machine-learning runtime.
import Foundation

public enum MsvqscError: Error, Equatable {
    case tooShort(String)
    case badMagic(String)
    case dimMismatch(corpus: Int, codebook: Int)
    case indexOutOfRange(index: Int, stage: Int, k: Int)
    case noCorpus
}

public final class MsvqscCodebook: Sendable {
    public static let codebookMagic = "MSVQ"
    public static let corpusMagic = "MCIX"

    public let version: Int
    public let stages: Int
    public let k: Int
    public let dim: Int
    /// [stage][entry] flattened to dim floats each.
    let vectors: [[[Float]]]
    public let corpus: [String]
    let corpusEmbeddings: [[Float]]

    init(version: Int, stages: Int, k: Int, dim: Int, vectors: [[[Float]]], corpus: [String], corpusEmbeddings: [[Float]]) {
        self.version = version
        self.stages = stages
        self.k = k
        self.dim = dim
        self.vectors = vectors
        self.corpus = corpus
        self.corpusEmbeddings = corpusEmbeddings
    }

    /// The two files' bytes.
    public static func load(codebook: [UInt8], corpusIndex: [UInt8]) throws -> MsvqscCodebook {
        let cb = try parseCodebook(codebook)
        let (texts, embeddings) = try parseCorpusIndex(corpusIndex, expectedDim: cb.dim)
        return MsvqscCodebook(
            version: cb.version, stages: cb.stages, k: cb.k, dim: cb.dim, vectors: cb.vectors, corpus: texts, corpusEmbeddings: embeddings)
    }

    struct RawCodebook {
        let version: Int
        let stages: Int
        let k: Int
        let dim: Int
        let vectors: [[[Float]]]
    }

    static func parseCodebook(_ data: [UInt8]) throws -> RawCodebook {
        guard data.count >= 10 else { throw MsvqscError.tooShort("codebook \(data.count) bytes") }
        let magic = String(decoding: data[0..<4], as: UTF8.self)
        guard magic == codebookMagic else { throw MsvqscError.badMagic(magic) }
        var r = LEReader(data, at: 4)
        let version = Int(r.u8())
        let stages = Int(r.u8())
        let k = Int(r.u16())
        let dim = Int(r.u16())
        guard data.count >= 10 + stages * k * dim * 4 else { throw MsvqscError.tooShort("codebook vectors") }
        var vectors: [[[Float]]] = []
        vectors.reserveCapacity(stages)
        for _ in 0..<stages {
            var entries: [[Float]] = []
            entries.reserveCapacity(k)
            for _ in 0..<k { entries.append(r.floats(dim)) }
            vectors.append(entries)
        }
        return RawCodebook(version: version, stages: stages, k: k, dim: dim, vectors: vectors)
    }

    static func parseCorpusIndex(_ data: [UInt8], expectedDim: Int) throws -> ([String], [[Float]]) {
        guard data.count >= 11 else { throw MsvqscError.tooShort("corpus index \(data.count) bytes") }
        let magic = String(decoding: data[0..<4], as: UTF8.self)
        guard magic == corpusMagic else { throw MsvqscError.badMagic(magic) }
        var r = LEReader(data, at: 4)
        _ = r.u8()  // version
        let count = Int(r.i32())
        let dim = Int(r.u16())
        guard dim == expectedDim else { throw MsvqscError.dimMismatch(corpus: dim, codebook: expectedDim) }
        var texts: [String] = []
        var embeddings: [[Float]] = []
        for _ in 0..<max(0, count) {
            let len = Int(r.u16())
            guard r.remaining >= len + dim * 4 else { throw MsvqscError.tooShort("corpus entry") }
            texts.append(String(decoding: r.bytes(len), as: UTF8.self))
            embeddings.append(r.floats(dim))
        }
        return (texts, embeddings)
    }

    /// The nearest corpus sentence to a frame.
    public func decode(_ wire: [UInt8]) throws -> String {
        let unpacked = try MsvqscWire.unpack(wire)
        return try decodeIndices(unpacked.indices, numStages: unpacked.stages)
    }

    public func decodeIndices(_ indices: [Int], numStages: Int? = nil) throws -> String {
        var reconstructed = [Float](repeating: 0, count: dim)
        for s in 0..<min(numStages ?? indices.count, stages, indices.count) {
            let idx = indices[s]
            guard (0..<k).contains(idx) else { throw MsvqscError.indexOutOfRange(index: idx, stage: s, k: k) }
            let v = vectors[s][idx]
            for d in 0..<dim { reconstructed[d] += v[d] }
        }
        guard !corpus.isEmpty else { throw MsvqscError.noCorpus }
        let reconNorm = Self.norm(reconstructed)
        var bestIdx = 0
        var bestSim: Float = -1
        for i in corpus.indices {
            let denom = reconNorm * Self.norm(corpusEmbeddings[i])
            if denom < 1e-8 { continue }
            let sim = Self.dot(reconstructed, corpusEmbeddings[i]) / denom
            if sim > bestSim {
                bestSim = sim
                bestIdx = i
            }
        }
        return corpus[bestIdx]
    }

    /// Residual quantisation of an embedding: the nearest entry per stage, the residual on.
    public func quantize(_ embedding: [Float], maxStages: Int) -> [Int] {
        let count = min(maxStages, stages)
        var residual = embedding
        var indices: [Int] = []
        for s in 0..<count {
            var bestIdx = 0
            var bestDist = Float.greatestFiniteMagnitude
            for e in 0..<k {
                let v = vectors[s][e]
                var dist: Float = 0
                for d in 0..<dim {
                    let diff = residual[d] - v[d]
                    dist += diff * diff
                }
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = e
                }
            }
            indices.append(bestIdx)
            let v = vectors[s][bestIdx]
            for d in 0..<dim { residual[d] -= v[d] }
        }
        return indices
    }

    /// Embedding to frame, for an encoder that already has the embedding.
    public func encode(embedding: [Float], maxStages: Int) -> [UInt8] {
        MsvqscWire.pack(quantize(embedding, maxStages: maxStages))
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }

    static func norm(_ v: [Float]) -> Float { dot(v, v).squareRoot() }
}

/// Text to an MSVQ-SC frame: the sentence encoder is platform code (ONNX Runtime on iOS).
public protocol MsvqscEncoding: Sendable {
    /// Nil when the encoder cannot embed the text.
    func encode(_ text: String, maxStages: Int) -> [UInt8]?
}

/// Little-endian reads over a byte array.
struct LEReader {
    private let data: [UInt8]
    private var i: Int
    init(_ data: [UInt8], at offset: Int) {
        self.data = data
        self.i = offset
    }
    var remaining: Int { data.count - i }
    mutating func u8() -> UInt8 {
        defer { i += 1 }
        return data[i]
    }
    mutating func u16() -> UInt16 {
        defer { i += 2 }
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }
    mutating func i32() -> Int32 {
        defer { i += 4 }
        return Int32(bitPattern: UInt32(data[i]) | (UInt32(data[i + 1]) << 8) | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24))
    }
    mutating func f32() -> Float {
        defer { i += 4 }
        let bits = UInt32(data[i]) | (UInt32(data[i + 1]) << 8) | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
        return Float(bitPattern: bits)
    }
    mutating func floats(_ n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        for j in 0..<n { out[j] = f32() }
        return out
    }
    mutating func bytes(_ n: Int) -> [UInt8] {
        defer { i += n }
        return Array(data[i..<(i + n)])
    }
}
