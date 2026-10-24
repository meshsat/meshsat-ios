// Mirrors bt/SignalReading.kt (MESHSAT-1670): one 9704 signal reading with the time it was taken,
// the rule for when the screens call it stale, and the signal reads' round trips for the bench;
// and the timing of the modem's MO segment request (MESHSAT-1674). The rule and the words are
// shared with MeshSat Android.

/// One 9704 signal reading and the time it was taken: from an answered `GET constellationState` or
/// an unsolicited `299 constellationState`. A read the modem did not answer is no reading, so it
/// never shows as 0 bars; an answered 0 is a real 0.
public struct SignalReading: Sendable, Equatable {
    public let bars: Int
    public let atMs: Int64
    public init(bars: Int, atMs: Int64) {
        self.bars = bars
        self.atMs = atMs
    }
}

/// How old a reading may be before the screen says so. A reading is fresh while its age is at most
/// two poll intervals plus the poll timeout, older is stale (shown with its age), and none since the
/// modem came up is "?". Delivered messages decide whether the satellite works, not the bars.
public enum SignalFreshness {
    /// The driver asks the modem when no reading came for this long; events usually come sooner.
    public static let pollIntervalMs: Int64 = 30_000
    /// How long one `GET constellationState` may take over the node's pipe.
    public static let pollTimeoutMs: Int64 = 6_000
    public static let staleAfterMs: Int64 = 2 * pollIntervalMs + pollTimeoutMs

    public enum Kind: Sendable, Equatable { case none, fresh, stale }

    public static func kind(_ reading: SignalReading?, nowMs: Int64) -> Kind {
        guard let reading else { return .none }
        return nowMs - reading.atMs <= staleAfterMs ? .fresh : .stale
    }

    /// "70 s", "4 min", "3 h": seconds below two minutes, minutes below two hours.
    public static func age(_ reading: SignalReading, nowMs: Int64) -> String {
        let s = max((nowMs - reading.atMs) / 1000, 0)
        if s < 120 { return "\(s) s" }
        if s < 120 * 60 { return "\(s / 60) min" }
        return "\(s / 3600) h"
    }

    /// "3/5", "3/5, last reading 4 min ago", or "?/5, no reading yet".
    public static func describe(_ reading: SignalReading?, nowMs: Int64) -> String {
        guard let reading else { return "?/5, no reading yet" }
        switch kind(reading, nowMs: nowMs) {
        case .stale: return "\(reading.bars)/5, last reading \(age(reading, nowMs: nowMs)) ago"
        default: return "\(reading.bars)/5"
        }
    }

    /// The short form for a lane: "3/5", "3/5 (4 min ago)" or "?/5".
    public static func compact(_ reading: SignalReading?, nowMs: Int64) -> String {
        guard let reading else { return "?/5" }
        switch kind(reading, nowMs: nowMs) {
        case .stale: return "\(reading.bars)/5 (\(age(reading, nowMs: nowMs)) ago)"
        default: return "\(reading.bars)/5"
        }
    }
}

/// The round trips of the signal reads on one connection, for the bench: the timeout over the
/// node's pipe is to be set from these, not by guess.
public struct SignalPollStats: Sendable, Equatable {
    public static let keep = 64

    public let answered: Int
    public let missed: Int
    public let minMs: Int64
    public let medianMs: Int64
    public let maxMs: Int64

    public init(answered: Int = 0, missed: Int = 0, minMs: Int64 = 0, medianMs: Int64 = 0, maxMs: Int64 = 0) {
        self.answered = answered
        self.missed = missed
        self.minMs = minMs
        self.medianMs = medianMs
        self.maxMs = maxMs
    }

    /// "120 / 310 / 2400 ms (14 answered, 1 missed)", or "" before the first read.
    public func describe() -> String {
        answered == 0 && missed == 0 ? "" : "\(minMs) / \(medianMs) / \(maxMs) ms (\(answered) answered, \(missed) missed)"
    }

    /// `roundTripsMs` are the last `keep` answered reads; `answered` counts all of them.
    public static func of(_ roundTripsMs: [Int64], answered: Int, missed: Int) -> SignalPollStats {
        guard !roundTripsMs.isEmpty else { return SignalPollStats(answered: answered, missed: missed) }
        let sorted = roundTripsMs.sorted()
        return SignalPollStats(
            answered: answered, missed: missed, minMs: sorted[0], medianMs: sorted[sorted.count / 2], maxMs: sorted[sorted.count - 1])
    }
}

/// One MO segment request and the app's answer (MESHSAT-1674): how long after `PUT messageOriginate`
/// the modem asked, and how long the app took from reading the request to handing its answer to the
/// link. The 9704 gives up after about 360 ms, counted at the modem.
public struct SegmentTiming: Sendable, Equatable {
    public let askedAfterMs: Int64
    public let answeredInMs: Int64
    public let segmentLength: Int
    public init(askedAfterMs: Int64, answeredInMs: Int64, segmentLength: Int) {
        self.askedAfterMs = askedAfterMs
        self.answeredInMs = answeredInMs
        self.segmentLength = segmentLength
    }

    /// "40 ms after the send, answered in 3 ms", as Android's Settings row.
    public func describe() -> String { "\(askedAfterMs) ms after the send, answered in \(answeredInMs) ms" }
}
