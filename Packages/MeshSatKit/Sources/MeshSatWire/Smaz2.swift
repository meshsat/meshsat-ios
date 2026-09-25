// Mirrors codec/Smaz2.kt (MESHSAT-447): short-string compression with 128 bigrams and 256
// words, wire-compatible with the Bridge (github.com/lib-x/smaz2).
//
//   0x80|idx     a bigram
//   0x01..0x05   a verbatim run of N bytes
//   0x06         a word (next byte: its index)
//   0x07         a word and a trailing space
//   0x08         a leading space and a word
//   0x09..0x7F   a literal byte
import Foundation

public enum Smaz2 {
    static let bigrams = Array(
        ("intherreheanonesorteattistenntartondalitseediseangoulecomeneriroderaioicliofasetvetasiha"
            + "maecomceelllcaurlachhidihofonsotacnarssoprrtsassusnoiltsemctgeloeebetrnipeiepancpooldaad"
            + "viunamutwimoshyoaiewowosfiepttmiopiaweagsuiddoooirspplscaywaigeirylytuulivimabty").utf8)

    static let words: [String] = [
        "that", "this", "with", "from", "your", "have", "more", "will", "home",
        "about", "page", "search", "free", "other", "information", "time", "they",
        "what", "which", "their", "news", "there", "only", "when", "contact", "here",
        "business", "also", "help", "view", "online", "first", "been", "would", "were",
        "some", "these", "click", "like", "service", "than", "find", "date", "back",
        "people", "list", "name", "just", "over", "year", "into", "email", "health",
        "world", "next", "used", "work", "last", "most", "music", "data", "make",
        "them", "should", "product", "post", "city", "policy", "number", "such",
        "please", "available", "copyright", "support", "message", "after", "best",
        "software", "then", "good", "video", "well", "where", "info", "right", "public",
        "high", "school", "through", "each", "order", "very", "privacy", "book", "item",
        "company", "read", "group", "need", "many", "user", "said", "does", "under",
        "general", "research", "university", "january", "mail", "full", "review",
        "program", "life", "know", "days", "management", "part", "could", "great",
        "united", "real", "international", "center", "ebay", "must", "store", "travel",
        "comment", "made", "development", "report", "detail", "line", "term", "before",
        "hotel", "send", "type", "because", "local", "those", "using", "result",
        "office", "education", "national", "design", "take", "posted", "internet",
        "address", "community", "within", "state", "area", "want", "phone", "shipping",
        "reserved", "subject", "between", "forum", "family", "long", "based", "code",
        "show", "even", "black", "check", "special", "price", "website", "index",
        "being", "women", "much", "sign", "file", "link", "open", "today", "technology",
        "south", "case", "project", "same", "version", "section", "found", "sport",
        "house", "related", "security", "both", "county", "american", "game", "member",
        "power", "while", "care", "network", "down", "computer", "system", "three",
        "total", "place", "following", "download", "without", "access", "think",
        "north", "resource", "current", "media", "control", "water", "history",
        "picture", "size", "personal", "since", "including", "guide", "shop",
        "directory", "board", "location", "change", "white", "text", "small", "rating",
        "rate", "government", "child", "during", "return", "student", "shopping",
        "account", "site", "level", "digital", "profile", "previous", "form", "event",
        "love", "main", "another", "class", "still",
    ]
    static let wordBytes: [[UInt8]] = words.map { Array($0.utf8) }

    /// The original text, or nil for invalid or empty input. Bytes come back as Latin-1
    /// characters, as Kotlin's `toChar()` makes them.
    public static func decompress(_ data: [UInt8]) -> String? {
        guard !data.isEmpty else { return nil }
        var out = ""
        var i = 0
        while i < data.count {
            let b = Int(data[i])
            if b & 0x80 != 0 {
                let idx = (b & 0x7F) * 2
                guard idx + 1 < bigrams.count else { return nil }
                out.unicodeScalars.append(Unicode.Scalar(bigrams[idx]))
                out.unicodeScalars.append(Unicode.Scalar(bigrams[idx + 1]))
                i += 1
            } else if (1...5).contains(b) {
                guard i + b < data.count else { return nil }
                for j in 1...b { out.unicodeScalars.append(Unicode.Scalar(data[i + j])) }
                i += 1 + b
            } else if b == 6 || b == 7 || b == 8 {
                guard i + 1 < data.count else { return nil }
                let wordIdx = Int(data[i + 1])
                guard wordIdx < words.count else { return nil }
                if b == 8 { out += " " }
                out += words[wordIdx]
                if b == 7 { out += " " }
                i += 2
            } else {
                out.unicodeScalars.append(Unicode.Scalar(UInt8(b)))
                i += 1
            }
        }
        return out
    }

    public static func compress(_ input: String) -> [UInt8] {
        let sb = Array(input.utf8)
        var dst: [UInt8] = []
        var verbatimLen = 0
        var pos = 0
        while pos < sb.count {
            // A word of 4 or more characters.
            var wordMatch = false
            var wordIdx = 0
            var wordLen = 0
            if pos + 3 < sb.count {
                for (wi, word) in wordBytes.enumerated() where pos + word.count <= sb.count {
                    if sb[pos..<(pos + word.count)].elementsEqual(word) {
                        wordMatch = true
                        wordIdx = wi
                        wordLen = word.count
                        break
                    }
                }
            }
            if wordMatch {
                if sb[pos] == 0x20 {
                    dst += [8, UInt8(wordIdx)]
                    pos += 1
                } else if pos + wordLen < sb.count, sb[pos + wordLen] == 0x20 {
                    dst += [7, UInt8(wordIdx)]
                    pos += 1
                } else {
                    dst += [6, UInt8(wordIdx)]
                }
                pos += wordLen
                verbatimLen = 0
                continue
            }
            // A bigram.
            if pos + 1 < sb.count {
                let c0 = sb[pos]
                let c1 = sb[pos + 1]
                var bigramIdx = -1
                for bi in 0..<(bigrams.count / 2) where bigrams[bi * 2] == c0 && bigrams[bi * 2 + 1] == c1 {
                    bigramIdx = bi
                    break
                }
                if bigramIdx >= 0 {
                    dst.append(UInt8(0x80 | bigramIdx))
                    pos += 2
                    verbatimLen = 0
                    continue
                }
            }
            // Bytes 1 to 8 encode themselves.
            let ch = sb[pos]
            if (1...8).contains(ch) {
                dst.append(ch)
                pos += 1
                verbatimLen = 0
                continue
            }
            // Verbatim: a run marker followed by up to 5 bytes.
            verbatimLen += 1
            if verbatimLen == 1 {
                dst += [UInt8(verbatimLen), sb[pos]]
            } else {
                dst.append(sb[pos])
                dst[dst.count - (verbatimLen + 1)] = UInt8(verbatimLen)
                if verbatimLen == 5 { verbatimLen = 0 }
            }
            pos += 1
        }
        return dst
    }
}
