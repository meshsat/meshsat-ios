// Mirrors the protocol half of ble/NodeOtaTransport.kt (MESHSAT-1672): the phone's side of
// Meshtastic's ESP32 OTA loader protocol over Bluetooth, written from the loader's README and code
// (github.com/meshtastic/esp32-unified-ota v1.0.1, the loader in app1 of every MeshSat image), not
// taken from Meshtastic-Android. The CoreBluetooth half (scan, connect, subscribe) is
// MeshSatBLE's NodeOtaTransport; the exchange itself runs here, over `NodeOtaLink`, so it is
// tested on Linux.
//
// The loader advertises `serviceUUID`, takes text and data on `writeUUID` and answers on
// `notifyUUID`, one text line per answer ending in \n:
// 1. "OTA <size> <sha256 hex>\n" (write with response); the SHA-256 must be the one the node was
//    handed in AdminMessage.ota_request, or the loader answers "ERR Hash Rejected". It answers
//    "ERASING", then "OK" once app0 is erased.
// 2. The image in chunks of at most MTU-3 bytes (and 512), one GATT write per chunk, never ahead:
//    each chunk is answered "ACK" (the loader drains a 520-byte buffer per answer and drops what
//    does not fit), the last one "OK" after the loader checked the SHA-256 and set app0 to boot.
//    It restarts into the new firmware about 2 s later.
// 3. Any "ERR ..." ends the update. There is no PIN on the loader and one connection at a time.
import Foundation
import MeshSatNet

public enum NodeOtaProtocol {
    public static let serviceUUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
    public static let writeUUID = "62ec0272-3ec5-11eb-b378-0242ac130005"
    public static let notifyUUID = "62ec0272-3ec5-11eb-b378-0242ac130003"
    /// The loader's receive buffer is 520 bytes.
    public static let maxChunk = 512

    public static let eraseTimeoutMs: Int64 = 60_000
    public static let ackTimeoutMs: Int64 = 10_000
    public static let verifyTimeoutMs: Int64 = 30_000

    public static func otaCommand(size: Int, sha256Hex: String) -> String { "OTA \(size) \(sha256Hex.lowercased())\n" }

    /// One GATT write per chunk, at most MTU-3 bytes and 512.
    public static func chunkSize(mtu: Int) -> Int { min(max(mtu - 3, 20), maxChunk) }

    /// The same from CoreBluetooth's largest write without response, which is already MTU-3.
    public static func chunkSize(maxWrite: Int) -> Int { min(max(maxWrite, 20), maxChunk) }

    public enum Reply: Sendable, Equatable {
        case ok
        case ack
        case erasing
        case error(String)
        case other(String)
    }

    public static func parseReply(_ line: String) -> Reply {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "OK" || t.hasPrefix("OK ") { return .ok }
        if t == "ACK" { return .ack }
        if t == "ERASING" { return .erasing }
        if t.hasPrefix("ERR") {
            let text = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return .error(text.isEmpty ? "unspecified error" : text)
        }
        return .other(t)
    }

    public enum Step: Sendable, Equatable {
        case connecting
        case erasing
        case sending(sent: Int, total: Int)
        case verifying
    }

    public enum Outcome: Sendable, Equatable {
        case done
        /// `loaderHasImage` true once the loader accepted the OTA command: app0 is erased, retry
        /// with the same file.
        case failed(String, loaderHasImage: Bool)
    }

    /// Steps 1 and 2 above over a connected, subscribed loader: the command, the erase, every
    /// chunk against its ACK and the last against the loader's OK.
    public static func run(
        image: NodeFirmwareImage, link: any NodeOtaLink, lines: NodeOtaLines, clock: any DriverClock = SystemDriverClock(),
        onStep: @Sendable (Step) -> Void
    ) async -> Outcome {
        lines.drain()
        guard await link.writeCommand(Array(otaCommand(size: image.size, sha256Hex: image.sha256Hex).utf8)) else {
            return .failed("The node's updater did not take the update command.", loaderHasImage: false)
        }
        // ERASING, then OK once app0 is erased (several seconds for 3.3 MB).
        erase: while true {
            guard let line = await lines.next(timeoutMs: eraseTimeoutMs, clock: clock) else {
                return .failed("The node's updater did not finish erasing.", loaderHasImage: false)
            }
            switch parseReply(line) {
            case .erasing: onStep(.erasing)
            case .ok: break erase
            case .error(let text): return .failed("The node refused the update: \(text)", loaderHasImage: false)
            case .ack, .other: continue
            }
        }
        let chunk = chunkSize(maxWrite: link.maxWriteWithoutResponse())
        var sent = 0
        let total = image.size
        var lastPercent = -1
        while sent < total {
            let end = min(sent + chunk, total)
            guard await link.writeChunk(Array(image.bytes[sent..<end])) else {
                return .failed("A piece of the firmware could not be sent at byte \(sent).", loaderHasImage: true)
            }
            let last = end == total
            if last { onStep(.verifying) }
            guard let line = await lines.next(timeoutMs: last ? verifyTimeoutMs : ackTimeoutMs, clock: clock) else {
                return .failed("The node's updater stopped answering at byte \(end).", loaderHasImage: true)
            }
            switch parseReply(line) {
            case .ack:
                if last { return .failed("The node's updater wanted more than the whole image.", loaderHasImage: true) }
            case .ok:
                if !last { return .failed("The node's updater ended the transfer early at byte \(end).", loaderHasImage: true) }
            case .error(let text):
                return .failed("The node's updater refused the firmware: \(text)", loaderHasImage: true)
            case .erasing, .other:
                return .failed("The node's updater answered '\(line)' at byte \(end).", loaderHasImage: true)
            }
            sent = end
            let percent = Int(Int64(sent) * 100 / Int64(total))
            if percent != lastPercent {
                lastPercent = percent
                onStep(.sending(sent: sent, total: total))
            }
        }
        return .done
    }

    /// The node's answers to ota_request (AdminModule.cpp, firmware 2.8.0).
    public static func isHandoverAnswer(_ text: String) -> Bool {
        text.hasPrefix("Rebooting to") || text.range(of: "OTA", options: .caseInsensitive) != nil || text.hasPrefix("Unable to switch")
    }

    /// The handover answer that means the node is on its way into the loader.
    public static func isRebootingToBle(_ text: String) -> Bool { text.hasPrefix("Rebooting to") && text.contains("BLE") }
}

/// What the exchange needs from a connected, subscribed loader.
public protocol NodeOtaLink: AnyObject, Sendable {
    /// The largest write without response the link takes now (the MTU minus the ATT header).
    func maxWriteWithoutResponse() -> Int
    /// The OTA command, written with response; false when the write failed.
    func writeCommand(_ bytes: [UInt8]) async -> Bool
    /// One chunk, written without response; false when it could not be handed to the link.
    func writeChunk(_ bytes: [UInt8]) async -> Bool
}

/// The loader's answers as text lines, from notifications that may split or join them.
public final class NodeOtaLines: @unchecked Sendable {
    private let lock = NSLock()
    private var partial: [UInt8] = []
    private var queue: [String] = []
    private var closed = false

    public init() {}

    /// Append one notification's bytes; complete lines are queued without their line end.
    public func feed(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        queue.append(contentsOf: Self.splitLines(&partial, bytes))
    }

    /// The link went down: every wait ends now.
    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    public func drain() {
        lock.lock()
        queue.removeAll()
        lock.unlock()
    }

    /// The next line, or nil after `timeoutMs` or once the link is closed.
    public func next(timeoutMs: Int64, clock: any DriverClock) async -> String? {
        let deadline = clock.nowMs() + timeoutMs
        while true {
            switch take() {
            case .line(let line): return line
            case .closed: return nil
            case .empty: break
            }
            if clock.nowMs() >= deadline { return nil }
            await clock.sleep(ms: 10)
        }
    }

    private enum Taken {
        case line(String)
        case closed
        case empty
    }

    private func take() -> Taken {
        lock.lock()
        defer { lock.unlock() }
        if !queue.isEmpty { return .line(queue.removeFirst()) }
        return closed ? .closed : .empty
    }

    /// Append `bytes` to `partial` and return every complete line, without its line end; blank
    /// lines are dropped. Split on the byte 0x0A, not on Swift's Characters, in which "\r\n" is
    /// one.
    public static func splitLines(_ partial: inout [UInt8], _ bytes: [UInt8]) -> [String] {
        partial.append(contentsOf: bytes)
        var out: [String] = []
        while let nl = partial.firstIndex(of: 0x0A) {
            var line = Array(partial[..<nl])
            while line.last == 0x0D { line.removeLast() }
            partial.removeSubrange(...nl)
            let text = String(decoding: line, as: UTF8.self)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { out.append(text) }
        }
        return out
    }
}
