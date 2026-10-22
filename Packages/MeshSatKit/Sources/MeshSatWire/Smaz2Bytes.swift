// Mirrors codec/Smaz2Bytes.kt (MESHSAT-1623): SMAZ2 on bytes, byte for byte as the MeshSat
// Bridge writes and reads it (meshsat internal/compress). The default table is
// github.com/lib-x/smaz2 with its quirks; the Meshtastic table is the Bridge's own compressor,
// whose table repeats some words and indexes each by its last entry. Both work on the text's
// UTF-8 bytes; nothing is turned into characters on the way.
//
// Smaz2 keeps the SMS path's existing behaviour and is left as it is. [MESHSAT-1624]
import Foundation

/// The SMAZ2 word table a smaz2 or smaz2g step names (its `dict` param).
public enum Smaz2Dict: Sendable, Equatable {
    case `default`
    case meshtastic

    /// The step param as the Bridge reads it: "meshtastic", anything else the default.
    public static func of(_ name: String?) -> Smaz2Dict { name == "meshtastic" ? .meshtastic : .default }
}

/// A SMAZ2 body that does not decode: the bytes are not what a sender writes.
public struct Smaz2Error: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum Smaz2Bytes {
    /// SMAZ2 of `src` with `dict`; empty for empty input, as the Bridge's.
    public static func compress(_ src: [UInt8], dict: Smaz2Dict) -> [UInt8] {
        if src.isEmpty { return [] }
        switch dict {
        case .meshtastic: return compressMeshtastic(src)
        case .default: return compressDefault(src)
        }
    }

    /// The bytes `c` compressed with `dict`; throws `Smaz2Error` on a body no sender writes.
    public static func decompress(_ c: [UInt8], dict: Smaz2Dict) throws -> [UInt8] {
        if c.isEmpty { return [] }
        switch dict {
        case .meshtastic: return try decompressMeshtastic(c)
        case .default: return try decompressDefault(c)
        }
    }

    // MARK: Default table: github.com/lib-x/smaz2 v0.1.0, its quirks included

    private static func compressDefault(_ s: [UInt8]) -> [UInt8] {
        var dst: [UInt8] = []
        dst.reserveCapacity(s.count)
        var verbatimLen = 0
        var pos = 0
        while pos < s.count {
            // The first word of the table the text starts with, not the longest.
            if s.count - pos >= 4, let wordIdx = firstDefaultWord(s, pos) {
                let len = Smaz2.wordBytes[wordIdx].count
                if s[pos] == space {
                    // Never true (a word does not start with a space), kept as lib-x has it.
                    dst += [8, UInt8(wordIdx)]
                    pos += 1
                } else if s.count - pos > len, s[pos + len] == space {
                    dst += [7, UInt8(wordIdx)]
                    pos += 1
                } else {
                    dst += [6, UInt8(wordIdx)]
                }
                pos += len
                verbatimLen = 0
                continue
            }
            if s.count - pos >= 2, let b = defaultBigrams.index(s[pos], s[pos + 1]) {
                dst.append(0x80 | b)
                pos += 2
                verbatimLen = 0
                continue
            }
            let ch = s[pos]
            // Bytes 1-8 are escape codes to every decoder, so each goes out as its own verbatim run
            // (1, the byte), as the Bridge's compressor does since MESHSAT-1626; lib-x wrote them as
            // they are and the text came back as other bytes.
            if (1...8).contains(ch) {
                dst += [1, ch]
                pos += 1
                verbatimLen = 0
                continue
            }
            verbatimLen += 1
            if verbatimLen == 1 {
                dst += [1, ch]
            } else {
                dst.append(ch)
                dst[dst.count - (verbatimLen + 1)] = UInt8(verbatimLen)
                if verbatimLen == 5 { verbatimLen = 0 }
            }
            pos += 1
        }
        return dst
    }

    private static func decompressDefault(_ c: [UInt8]) throws -> [UInt8] {
        var res: [UInt8] = []
        res.reserveCapacity(c.count * 2)
        var i = 0
        while i < c.count {
            let b = Int(c[i])
            if b & 0x80 != 0 {
                let idx = (b & 0x7F) * 2
                res += [Smaz2.bigrams[idx], Smaz2.bigrams[idx + 1]]
                i += 1
            } else if (1...5).contains(b) {
                if i + 1 + b > c.count { throw Smaz2Error("smaz2: verbatim length \(b) overflows at position \(i)") }
                res += c[(i + 1)...(i + b)]
                i += 1 + b
            } else if (6...8).contains(b) {
                if i + 1 >= c.count { throw Smaz2Error("smaz2: word escape at end of input") }
                if b == 8 { res.append(space) }
                res += Smaz2.wordBytes[Int(c[i + 1])]
                if b == 7 { res.append(space) }
                i += 2
            } else {
                res.append(UInt8(b))
                i += 1
            }
        }
        return res
    }

    /// The first table word at `pos`, in table order. Only the words that start with the byte at
    /// `pos` can match, so only those are tried; the answer is the one the full scan gives.
    private static func firstDefaultWord(_ s: [UInt8], _ pos: Int) -> Int? {
        for idx in defaultWordsByFirstByte[Int(s[pos])] where startsWith(s, pos, Smaz2.wordBytes[idx]) {
            return idx
        }
        return nil
    }

    private static let defaultWordsByFirstByte: [[Int]] = {
        var out = [[Int]](repeating: [], count: 256)
        for (i, w) in Smaz2.wordBytes.enumerated() { out[Int(w[0])].append(i) }
        return out
    }()

    private static let defaultBigrams = BigramIndex(Smaz2.bigrams)

    // MARK: Meshtastic table: meshsat internal/compress/dict_meshtastic.go

    private static func compressMeshtastic(_ s: [UInt8]) -> [UInt8] {
        var dst: [UInt8] = []
        dst.reserveCapacity(s.count)
        var verbatimStart = -1
        var pos = 0
        while pos < s.count {
            // Space + word (8): the longest word of 4 or more bytes after the space.
            if s[pos] == space, pos + 1 < s.count, let word = longestMeshtasticWord(s, pos + 1) {
                verbatimStart = -1
                dst += [8, word.index]
                pos += 1 + word.length
                continue
            }
            // Word + space (7) or word (6): the longest word of 4 or more bytes.
            if let word = longestMeshtasticWord(s, pos) {
                verbatimStart = -1
                if pos + word.length < s.count, s[pos + word.length] == space {
                    dst += [7, word.index]
                    pos += word.length + 1
                } else {
                    dst += [6, word.index]
                    pos += word.length
                }
                continue
            }
            // Bigram: the first pair of the table that matches.
            if pos + 1 < s.count, let b = meshtasticBigrams.index(s[pos], s[pos + 1]) {
                verbatimStart = -1
                dst.append(0x80 | b)
                pos += 2
                continue
            }
            appendMeshtasticByte(s[pos], to: &dst, verbatimStart: &verbatimStart)
            pos += 1
        }
        return dst
    }

    /// A byte no word or bigram took: 0 and 9-127 as they are, bytes 1-8 and 128-255 in verbatim
    /// runs of up to 5.
    private static func appendMeshtasticByte(_ ch: UInt8, to dst: inout [UInt8], verbatimStart: inout Int) {
        if ch == 0 || (9...127).contains(ch) {
            verbatimStart = -1
            dst.append(ch)
        } else if verbatimStart >= 0, dst[verbatimStart] < 5 {
            dst[verbatimStart] += 1
            dst.append(ch)
            if dst[verbatimStart] == 5 { verbatimStart = -1 }
        } else {
            verbatimStart = dst.count
            dst += [1, ch]
        }
    }

    private static func decompressMeshtastic(_ c: [UInt8]) throws -> [UInt8] {
        var res: [UInt8] = []
        res.reserveCapacity(c.count * 2)
        var i = 0
        while i < c.count {
            let b = Int(c[i])
            if b >= 128 {
                let idx = b & 0x7F
                if idx * 2 + 1 >= meshtasticBigramBytes.count { throw Smaz2Error("smaz2: bigram index \(idx) out of range") }
                res += [meshtasticBigramBytes[idx * 2], meshtasticBigramBytes[idx * 2 + 1]]
                i += 1
            } else if (1...5).contains(b) {
                if i + 1 + b > c.count { throw Smaz2Error("smaz2: verbatim length \(b) overflows at position \(i)") }
                res += c[(i + 1)...(i + b)]
                i += 1 + b
            } else if (6...8).contains(b) {
                if i + 1 >= c.count { throw Smaz2Error("smaz2: word escape at end of input") }
                if b == 8 { res.append(space) }
                res += meshtasticWordBytes[Int(c[i + 1])]
                if b == 7 { res.append(space) }
                i += 2
            } else {
                res.append(UInt8(b))
                i += 1
            }
        }
        return res
    }

    /// The longest table word of 4 or more bytes at `pos`, with the index the Bridge's map gives
    /// it (a word listed twice: its last entry). The Bridge tries every length up to 40 against
    /// its map; no word is longer than 13 bytes, so trying the words that start with the byte at
    /// `pos` finds the same word.
    private static func longestMeshtasticWord(_ s: [UInt8], _ pos: Int) -> (index: UInt8, length: Int)? {
        var best: (index: UInt8, length: Int)?
        for w in meshtasticWordsByFirstByte[Int(s[pos])] where w.bytes.count >= 4 && w.bytes.count > (best?.length ?? 0) {
            if startsWith(s, pos, w.bytes) { best = (UInt8(w.index), w.bytes.count) }
        }
        return best
    }

    private static let meshtasticWordsByFirstByte: [[(bytes: [UInt8], index: Int)]] = {
        var lastIndex: [[UInt8]: Int] = [:]
        for (i, w) in meshtasticWordBytes.enumerated() { lastIndex[w] = i }
        var out = [[(bytes: [UInt8], index: Int)]](repeating: [], count: 256)
        for (w, i) in lastIndex.sorted(by: { $0.value < $1.value }) { out[Int(w[0])].append((w, i)) }
        return out
    }()

    private static let meshtasticBigrams = BigramIndex(meshtasticBigramBytes)

    // MARK: Shared helpers

    private static let space: UInt8 = 0x20

    private static func startsWith(_ s: [UInt8], _ pos: Int, _ word: [UInt8]) -> Bool {
        if s.count - pos < word.count { return false }
        for k in 0..<word.count where s[pos + k] != word[k] { return false }
        return true
    }

    /// The index of the first pair of a bigram table equal to two bytes, looked up in a table
    /// built once in table order, so a pair listed twice answers its first entry as a scan does.
    private struct BigramIndex: Sendable {
        private let first: [Int16]

        init(_ table: [UInt8]) {
            var first = [Int16](repeating: -1, count: 65_536)
            var i = 0
            while i + 1 < table.count {
                let key = Int(table[i]) << 8 | Int(table[i + 1])
                if first[key] < 0 { first[key] = Int16(i / 2) }
                i += 2
            }
            self.first = first
        }

        func index(_ b0: UInt8, _ b1: UInt8) -> UInt8? {
            let v = first[Int(b0) << 8 | Int(b1)]
            return v < 0 ? nil : UInt8(v)
        }
    }

    /// The Meshtastic table's bigrams, in table order (the Bridge's).
    static let meshtasticBigramTable =
        "intherreheanonesorteattistenntartondalitseediseangoulecomeneriroderaioicliofasetvetasiha"
        + "maecomceelllcaurlachhidihofonsotacnarssoprrtsassusnoiltsemctgeloeebetrnipeiepancpooldaad"
        + "viunamutwimoshyoaiewowosfiepttmiopiaweagsuiddoooirspplscaywaigeirylytuulivimabty"
    private static let meshtasticBigramBytes = Array(meshtasticBigramTable.utf8)

    /// The Meshtastic table in table order, duplicates included (the Bridge's).
    static let meshtasticWords: [String] = [
        "mesh", "node", "message", "channel", "signal", "radio", "frequency", "power",
        "antenna", "range", "gateway", "relay", "bridge", "network", "packet", "payload",
        "status", "battery", "voltage", "level", "percent", "position", "latitude", "longitude",
        "altitude", "heading", "speed", "distance", "bearing", "elevation", "terrain", "route",
        "satellite", "iridium", "modem", "serial", "port", "device", "sensor", "timestamp",
        "meshtastic", "location", "coordinates", "waypoint", "temperature", "humidity", "pressure", "weather",
        "connected", "offline", "online", "update", "received", "transmitted", "error", "warning",
        "critical", "enabled", "disabled", "configuration", "settings", "interface", "protocol", "timeout",
        "emergency", "rescue", "medical", "assistance", "helicopter", "vehicle", "boat", "shelter",
        "water", "food", "camp", "base", "standing", "moving", "stopped", "request",
        "respond", "acknowledge", "confirmed", "denied", "approved", "copy", "over", "roger",
        "affirmative", "negative", "clear", "blocked", "north", "south", "east", "west",
        "success", "failed", "pending", "queued", "delivered", "expired", "forwarded", "dropped",
        "retry", "noise", "interference", "coverage", "degrees", "meters", "kilometers", "knots",
        "duration", "interval", "threshold", "maximum", "minimum", "average", "total", "count",
        "report", "checksum", "baud", "cellular", "satellite", "webhook", "mqtt", "iridium",
        "that", "this", "with", "from", "your", "have", "more", "will",
        "home", "about", "time", "they", "what", "which", "their", "there",
        "only", "when", "here", "also", "help", "been", "would", "were",
        "some", "these", "like", "than", "find", "back", "just", "over",
        "into", "them", "should", "then", "good", "well", "where", "right",
        "high", "through", "each", "very", "read", "need", "many", "said",
        "does", "under", "full", "part", "could", "great", "send", "type",
        "because", "local", "those", "using", "result", "before", "make", "data",
        "area", "want", "show", "even", "check", "open", "today", "state",
        "both", "down", "system", "three", "total", "place", "without", "access",
        "think", "current", "control", "change", "small", "rate", "number", "line",
        "name", "list", "work", "last", "next", "used", "free", "other",
        "first", "world", "after", "best", "long", "based", "code", "being",
        "while", "care", "same", "found", "link", "text", "site", "form",
        "event", "love", "main", "still", "information", "service", "people", "year",
        "email", "group", "detail", "design", "board", "point", "test", "track",
    ]
    private static let meshtasticWordBytes: [[UInt8]] = meshtasticWords.map { Array($0.utf8) }
}

/// The smaz2g frame (HeMB-NG S3-1): one mode byte, then the text's UTF-8 bytes as they are
/// (0x00) or their SMAZ2 (0x01), taken only when strictly shorter. The Bridge's
/// `encodeSmaz2g` / `decodeSmaz2g`. [MESHSAT-1624]
public enum Smaz2g {
    public static let modeRaw: UInt8 = 0x00
    public static let modeSmaz2: UInt8 = 0x01

    public static func encode(_ text: [UInt8], dict: Smaz2Dict) -> [UInt8] {
        let z = Smaz2Bytes.compress(text, dict: dict)
        return z.count < text.count ? [modeSmaz2] + z : [modeRaw] + text
    }

    /// The text of `frame`; throws `Smaz2Error` for an empty frame, an unknown mode, an empty or
    /// malformed body.
    public static func decode(_ frame: [UInt8], dict: Smaz2Dict) throws -> [UInt8] {
        guard let mode = frame.first else { throw Smaz2Error("smaz2g: empty frame, no mode byte") }
        switch mode {
        case modeRaw:
            return Array(frame.dropFirst())
        case modeSmaz2:
            if frame.count == 1 { throw Smaz2Error("smaz2g: smaz2 mode with no data") }
            return try Smaz2Bytes.decompress(Array(frame.dropFirst()), dict: dict)
        default:
            throw Smaz2Error("smaz2g: unknown mode 0x" + Hex.encode([mode]))
        }
    }
}
