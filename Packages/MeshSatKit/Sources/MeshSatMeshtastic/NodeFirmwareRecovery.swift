// Mirrors the recovery session of ble/NodeFirmwareUpdater.kt and its NodeFirmwareKnown (MESHSAT-1684,
// review r63 finding R63-F1): the kept image, the node's address and what is known about the node's
// old firmware. Every attempt runs a new transport whose stage starts at "not commanded", so one
// attempt alone cannot say the old firmware is still there: an earlier attempt may have erased it
// or left that uncertain. The session merges each attempt's stage into what it knows and never goes
// down; a handover starts a new session at intact; a send straight to the updater merges in
// unknown; a finished update clears it. MeshSatPlatform's NodeFirmwareUpdater runs every attempt
// through `attempt` and takes its words from here, so this flow is the production one, tested on
// Linux.
import Foundation

public final class NodeFirmwareRecovery: @unchecked Sendable {
    /// What a recovery session knows about the node's old firmware, from weakest to strongest claim
    /// that it is gone. It only moves up: a later attempt that fails before its command does not
    /// bring an erased firmware back.
    public enum Known: Int, Sendable, Comparable {
        /// The session began at a handover from a running node and no attempt wrote its command.
        case intact = 0
        /// The session began with no history (a recovery after the app lost it).
        case unknown = 1
        /// An attempt wrote its command and nothing settled whether the loader erased.
        case mayBeErased = 2
        /// An attempt saw the loader finish erasing.
        case erased = 3

        public static func < (a: Known, b: Known) -> Bool { a.rawValue < b.rawValue }

        public static func of(_ stage: NodeOtaProtocol.Stage) -> Known {
            switch stage {
            case .notCommanded, .refused: .intact
            case .eraseUncertain: .mayBeErased
            case .erased: .erased
            }
        }

        public static func merge(_ known: Known?, _ next: Known) -> Known {
            guard let known, next <= known else { return next }
            return known
        }
    }

    /// The image and address kept for a retry, and what the session knows.
    public struct Kept: Sendable, Equatable {
        public let image: NodeFirmwareImage
        public let address: String
        public let known: Known
    }

    /// What an attempt leaves for the screen.
    public enum Result: Sendable, Equatable {
        case done
        /// The words for the failure; a retry with the kept image is always offered.
        case failed(String)
    }

    private let lock = NSLock()
    private var pending: NodeFirmwareImage?
    private var pendingAddress = ""
    private var knownValue: Known?

    public init() {}

    /// The kept image, its node and what is known, nil when no recovery is under way.
    public var kept: Kept? {
        lock.lock()
        defer { lock.unlock() }
        guard let pending else { return nil }
        return Kept(image: pending, address: pendingAddress, known: knownValue ?? .unknown)
    }

    /// What this recovery session knows about the node's old firmware; nil with no session.
    public var known: Known? {
        lock.lock()
        defer { lock.unlock() }
        return knownValue
    }

    /// The node accepted the handover (or dropped the link after the request) and is going to its
    /// loader. It was running its firmware a moment ago, so a new session starts at intact; what an
    /// older session knew was about a firmware the node has since replaced.
    public func began(_ image: NodeFirmwareImage, address: String) {
        lock.lock()
        defer { lock.unlock() }
        knownValue = nil
        keep(image, address, atLeast: .intact)
    }

    /// A file sent straight to a node waiting in its updater: nothing says what happened to this node
    /// before, so never "its firmware is still on it".
    public func beganByHand(_ image: NodeFirmwareImage, address: String) {
        lock.lock()
        defer { lock.unlock() }
        keep(image, address, atLeast: .unknown)
    }

    /// The caller holds the lock.
    private func keep(_ image: NodeFirmwareImage, _ address: String, atLeast: Known) {
        pending = image
        pendingAddress = address
        knownValue = Known.merge(knownValue, atLeast)
    }

    /// One attempt, as the updater runs it: its outcome merged into the session.
    public func attempt(_ run: () async -> NodeOtaProtocol.Outcome) async -> Result { record(await run()) }

    /// An attempt's outcome merged into what the session knows, never downgrading it; done clears it.
    public func record(_ outcome: NodeOtaProtocol.Outcome) -> Result {
        lock.lock()
        defer { lock.unlock() }
        switch outcome {
        case .done:
            pending = nil
            pendingAddress = ""
            knownValue = nil
            return .done
        case .failed(let reason, let stage):
            let now = Known.merge(knownValue, Known.of(stage))
            knownValue = now
            return .failed(reason + Self.whatTheNodeHas(now, refused: stage == .refused))
        }
    }

    /// The words when Bluetooth is off before an attempt: what the session knows, as it is.
    public func bluetoothOffText() -> String {
        "Bluetooth is off." + Self.whatTheNodeHas(known ?? .unknown, refused: false, bluetoothOff: true)
    }

    /// The sentence about the node's old firmware and what to do, shared with MeshSat Android word
    /// for word, after the attempt's own reason.
    public static func whatTheNodeHas(_ known: Known, refused: Bool, bluetoothOff: Bool = false) -> String {
        let state: String
        switch known {
        case .intact:
            state =
                refused
                ? "The node waits in its updater with its firmware still on it"
                : "The node waits in its updater with its firmware still on it and starts it only after an update"
        case .unknown: state = "The node waits in its updater, and whether its old firmware is still on it is not known"
        case .mayBeErased: state = "The node may have erased its firmware and waits in its updater"
        case .erased: state = "The node erased its firmware and waits in its updater"
        }
        let file = known == .unknown ? "the file the update started with" : refused ? "the file this update started with" : "the same file"
        let retry = bluetoothOff ? "switch Bluetooth on and retry" : "retry"
        return " \(state): \(retry) with \(file)."
    }
}
