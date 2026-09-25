// Mirrors crypto/SimpleWordPieceTokenizer.kt: the WordPiece tokenizer of all-MiniLM-L6-v2,
// from its vocab.txt: lower-case, split on whitespace, longest-match subwords with "##".
import Foundation

public struct WordPieceTokenizer: Sendable {
    public static let maxSeqLen = 128

    public struct Tokens: Sendable, Equatable {
        public let ids: [Int]
        public let attentionMask: [Int]
    }

    private let vocab: [String: Int]
    let unkId: Int
    let clsId: Int
    let sepId: Int

    /// The vocabulary file's text, one token per line, its line number the id.
    public init(vocabText: String) {
        var vocab: [String: Int] = [:]
        for (idx, line) in vocabText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let token = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            vocab[token] = idx
        }
        self.vocab = vocab
        unkId = vocab["[UNK]"] ?? 100
        clsId = vocab["[CLS]"] ?? 101
        sepId = vocab["[SEP]"] ?? 102
    }

    public var vocabSize: Int { vocab.count }

    public func tokenize(_ text: String) -> Tokens {
        var tokens = [clsId]
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for word in words {
            let sub = wordPiece(word)
            if tokens.count + sub.count >= Self.maxSeqLen - 1 { break }
            tokens += sub
        }
        tokens.append(sepId)
        return Tokens(ids: tokens, attentionMask: [Int](repeating: 1, count: tokens.count))
    }

    private func wordPiece(_ word: String) -> [Int] {
        let chars = Array(word)
        var result: [Int] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var found = false
            while start < end {
                let piece = String(chars[start..<end])
                let sub = start == 0 ? piece : "##" + piece
                if let id = vocab[sub] {
                    result.append(id)
                    start = end
                    found = true
                    break
                }
                end -= 1
            }
            if !found {
                result.append(unkId)
                start += 1
            }
        }
        return result
    }
}
