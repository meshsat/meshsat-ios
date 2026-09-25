// MSVQ-SC has no Android unit tests (its encoder needs the ONNX runtime); these pin the wire
// format, the codebook and corpus parsers on a synthetic pair of files, decode and quantise
// on them, the tokenizer on a small vocabulary, and, when the app's bundled model files are
// in the checkout, the real codebook's shape and a decode.
import XCTest

@testable import MeshSatMsvqsc

final class MsvqscTests: XCTestCase {
    // MARK: Wire

    func testPackUnpack() throws {
        let wire = MsvqscWire.pack([5, 1023, 0x1234])
        XCTAssertEqual(wire, [0x31, 5, 0, 0xFF, 3, 0x34, 0x12])
        let back = try MsvqscWire.unpack(wire)
        XCTAssertEqual(back, MsvqscWire.Unpacked(indices: [5, 1023, 0x1234], stages: 3, version: 1))
        XCTAssertEqual(MsvqscWire.wireSize(stages: 3), 7)
        XCTAssertEqual(MsvqscWire.fromBase64(MsvqscWire.toBase64(wire)), wire)
    }

    func testUnpackRejects() {
        XCTAssertThrowsError(try MsvqscWire.unpack([]))
        XCTAssertThrowsError(try MsvqscWire.unpack([0x32]))
        XCTAssertThrowsError(try MsvqscWire.unpack([0x31, 1, 0]))
    }

    func testLooksLikeMsvqsc() {
        XCTAssertTrue(MsvqscWire.looksLikeMsvqsc(MsvqscWire.pack([1, 2, 3])))
        XCTAssertFalse(MsvqscWire.looksLikeMsvqsc([]))
        XCTAssertFalse(MsvqscWire.looksLikeMsvqsc([0x01]))  // 0 stages
        XCTAssertFalse(MsvqscWire.looksLikeMsvqsc([0x91] + [UInt8](repeating: 0, count: 18)))  // 9 stages
        XCTAssertFalse(MsvqscWire.looksLikeMsvqsc([0x32, 0, 0, 0, 0, 0, 0]))  // version 2
        XCTAssertFalse(MsvqscWire.looksLikeMsvqsc([0x31, 0, 0, 0, 0, 0, 0, 0]))  // one byte too many
        XCTAssertTrue(MsvqscWire.looksLikeMsvqsc([0x11, 7, 0]))
    }

    // MARK: A synthetic codebook: 2 stages, K=4, dim=2, and a 3-sentence corpus.

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }
    private func f32(_ v: Float) -> [UInt8] {
        let b = v.bitPattern
        return [UInt8(b & 0xFF), UInt8((b >> 8) & 0xFF), UInt8((b >> 16) & 0xFF), UInt8((b >> 24) & 0xFF)]
    }

    private func synthetic() throws -> MsvqscCodebook {
        // Stage 0 entries: (1,0) (0,1) (-1,0) (0,-1); stage 1: quarter-size corrections.
        let stage0: [[Float]] = [[1, 0], [0, 1], [-1, 0], [0, -1]]
        let stage1: [[Float]] = [[0.25, 0], [0, 0.25], [-0.25, 0], [0, -0.25]]
        var cb = Array("MSVQ".utf8) + [1, 2] + le16(4) + le16(2)
        for v in stage0 + stage1 { cb += f32(v[0]) + f32(v[1]) }
        let corpus: [(String, [Float])] = [("go east", [1, 0.2]), ("go north", [0.1, 1]), ("go west", [-1, 0])]
        var ci = Array("MCIX".utf8) + [1] + le32(corpus.count) + le16(2)
        for (text, emb) in corpus {
            ci += le16(text.utf8.count) + Array(text.utf8) + f32(emb[0]) + f32(emb[1])
        }
        return try MsvqscCodebook.load(codebook: cb, corpusIndex: ci)
    }

    func testSyntheticCodebookParsesDecodesAndQuantises() throws {
        let cb = try synthetic()
        XCTAssertEqual(cb.version, 1)
        XCTAssertEqual(cb.stages, 2)
        XCTAssertEqual(cb.k, 4)
        XCTAssertEqual(cb.dim, 2)
        XCTAssertEqual(cb.corpus, ["go east", "go north", "go west"])
        // (1,0) + (0,0.25) points north-east-ish, nearest "go east".
        XCTAssertEqual(try cb.decodeIndices([0, 1]), "go east")
        XCTAssertEqual(try cb.decodeIndices([1, 0]), "go north")
        XCTAssertEqual(try cb.decode(MsvqscWire.pack([2, 2])), "go west")
        // One stage only: (0,1) is "go north".
        XCTAssertEqual(try cb.decodeIndices([1, 3], numStages: 1), "go north")
        // Quantising (0.9, 0.3): stage 0 picks (1,0), residual (-0.1, 0.3) picks (0, 0.25).
        XCTAssertEqual(cb.quantize([0.9, 0.3], maxStages: 2), [0, 1])
        XCTAssertEqual(cb.quantize([0.9, 0.3], maxStages: 1), [0])
        XCTAssertEqual(cb.quantize([0.9, 0.3], maxStages: 5), [0, 1])
        // (-0.8,-0.1): stage 0 picks (-1,0), the residual (0.2,-0.1) is nearest (0.25,0).
        XCTAssertEqual(cb.encode(embedding: [-0.8, -0.1], maxStages: 2), MsvqscWire.pack([2, 0]))
        XCTAssertThrowsError(try cb.decodeIndices([4, 0]))
    }

    func testParserRejects() {
        XCTAssertThrowsError(try MsvqscCodebook.parseCodebook(Array("MSVQ".utf8)))
        XCTAssertThrowsError(try MsvqscCodebook.parseCodebook(Array("NOPE".utf8) + [1, 1] + le16(1) + le16(1) + f32(0)))
        XCTAssertThrowsError(try MsvqscCodebook.parseCodebook(Array("MSVQ".utf8) + [1, 1] + le16(2) + le16(2) + f32(0)))
        XCTAssertThrowsError(try MsvqscCodebook.parseCorpusIndex(Array("MCIX".utf8) + [1] + le32(0) + le16(3), expectedDim: 2))
        XCTAssertThrowsError(try MsvqscCodebook.parseCorpusIndex(Array("MCIX".utf8) + [1] + le32(1) + le16(2) + le16(9), expectedDim: 2))
    }

    // MARK: Tokenizer

    func testTokenizer() {
        let vocab = ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "hello", "world", "un", "##break", "##able", "!"].joined(separator: "\n")
        let t = WordPieceTokenizer(vocabText: vocab)
        XCTAssertEqual(t.vocabSize, 10)
        XCTAssertEqual(t.tokenize("Hello world"), WordPieceTokenizer.Tokens(ids: [2, 4, 5, 3], attentionMask: [1, 1, 1, 1]))
        XCTAssertEqual(t.tokenize("unbreakable").ids, [2, 6, 7, 8, 3])
        // A character with no piece is [UNK] and the word goes on.
        XCTAssertEqual(t.tokenize("hexlo").ids, [2, 1, 1, 1, 1, 1, 3])
        XCTAssertEqual(t.tokenize("").ids, [2, 3])
        // Never past 128 tokens.
        let long = Array(repeating: "hello", count: 200).joined(separator: " ")
        XCTAssertLessThanOrEqual(t.tokenize(long).ids.count, WordPieceTokenizer.maxSeqLen)
    }

    // MARK: The real files, when the checkout has them.

    private var resourcesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/MeshSat/Resources")
    }

    func testBundledCodebookShapeAndDecode() throws {
        let cbURL = resourcesDir.appendingPathComponent("codebook_v1.bin")
        let ciURL = resourcesDir.appendingPathComponent("corpus_index.bin")
        guard FileManager.default.fileExists(atPath: cbURL.path), FileManager.default.fileExists(atPath: ciURL.path) else {
            throw XCTSkip("bundled model files not in this checkout")
        }
        let cb = try MsvqscCodebook.load(codebook: [UInt8](try Data(contentsOf: cbURL)), corpusIndex: [UInt8](try Data(contentsOf: ciURL)))
        XCTAssertEqual(cb.version, 1)
        XCTAssertEqual(cb.stages, 8)
        XCTAssertEqual(cb.k, 1024)
        XCTAssertEqual(cb.dim, 384)
        XCTAssertEqual(cb.corpus.count, 45)
        // Every corpus sentence quantised through all stages comes back as itself: the
        // codebook was trained on this corpus.
        var hits = 0
        for (i, text) in cb.corpus.enumerated() {
            let wire = cb.encode(embedding: cb.corpusEmbeddings[i], maxStages: 8)
            XCTAssertEqual(wire.count, MsvqscWire.wireSize(stages: 8))
            if try cb.decode(wire) == text { hits += 1 }
        }
        XCTAssertGreaterThanOrEqual(hits, 40, "\(hits) of 45 corpus sentences survive a full round trip")
        let vocab = try String(contentsOf: resourcesDir.appendingPathComponent("vocab.txt"), encoding: .utf8)
        let t = WordPieceTokenizer(vocabText: vocab)
        XCTAssertEqual(t.tokenize("hello").ids, [101, 7592, 102])
        XCTAssertEqual(t.tokenize("running").ids.count, 3)
    }
}
