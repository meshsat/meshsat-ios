// Mirrors bt/IridiumSpp.kt: the Iridium 9603N AT command driver over a byte link, the node's
// BLE Iridium pipe since MESHSAT-1236. What costs money is decided here, once, for every caller:
// each AT+SBDIX that reaches the gateway is billed, even with an empty MO buffer. After status
// 32 or 36 no SBDIX is sent for `sbdixHoldMs`. The MO buffer is cleared after every session,
// sent or not, as the Bridge does (internal/transport/direct_sat.go). An unsolicited "SBDRING"
// (a waiting MT message) is reported on `ringAlerts`; checking the mailbox is the caller's
// decision, never a timer's.
//
// Key AT commands: AT&K0 flow control off; AT+CSQF last signal reading (free, at once);
// AT+CSQ fresh reading (free, up to 50 s); AT+SBDWB write MO (340 B max); AT+SBDIX session
// (billed, 11-90 s); AT+SBDSX status (free); AT+SBDRB read MT, binary [len 2B BE][data][sum 2B BE];
// AT+SBDD0 clear MO; AT+SBDD1 clear MT.
import Foundation
import MeshSatNet

public enum IridiumDriverError: Error, Equatable, Sendable {
    case notConnected
    case protocolError(String)
    case timeout(String)
}

public actor IridiumATDriver {
    // MARK: Constants (the Kotlin companion object)
    public static let atTimeoutMs: Int64 = 5_000
    /// A fresh AT+CSQ can take up to 50 s while the modem acquires the network (the Bridge waits 60).
    public static let csqTimeoutMs: Int64 = 60_000
    /// AT+CSQF answers from the modem's last reading, in about 100 ms.
    public static let csqfTimeoutMs: Int64 = 5_000
    /// A fresh reading asked for because the last one was 0: usually two seconds, up to ten.
    public static let csqConfirmTimeoutMs: Int64 = 15_000
    /// At most one such confirmation a minute, so the 5-second poll during a pass cannot chain them.
    public static let csqConfirmIntervalMs: Int64 = 60_000
    public static let sbdixTimeoutMs: Int64 = 95_000
    public static let sbdixHoldMs: Int64 = 180_000
    public static let moMaxSize = 340
    public static let mtMaxSize = 270
    /// Failed writes in a row before the link counts as broken (MESHSAT-1270).
    public static let linkBrokenWrites = 3
    public static let wakeRetryMs: Int64 = 2_000
    /// Silent this long, the modem is reported as not answering; the checks go on, slower.
    public static let wakeGraceMs: Int64 = 60_000
    public static let silentRetryMs: Int64 = 30_000

    /// MO statuses where the message may have reached the gateway although the modem reports a
    /// failure: the session was cut after the upload (MAN0009, +SBDIX). Seen on flaneur, 19 Sep 2026.
    public static let moMaybeSent: Set<Int> = [10, 13, 17, 18, 19]

    /// What an +SBDIX MO status means, in plain words.
    public static func moStatusText(_ code: Int) -> String {
        switch code {
        case 0...4: "sent"
        case 10: "the gateway did not finish the call in time"
        case 11: "the modem's outgoing queue is full"
        case 12: "the message has too many segments"
        case 13: "the session did not complete"
        case 14: "the segment size is invalid"
        case 15: "the gateway denied access"
        case 16: "the modem is locked"
        case 17: "the gateway did not answer"
        case 18: "the radio link dropped"
        case 19: "the link failed"
        case 32: "no network service"
        case 33: "antenna fault"
        case 34: "the radio is switched off"
        case 35: "the modem is busy"
        case 36: "the gateway asked to try again later"
        case 37: "satellite messaging is paused by the network"
        case 38: "the network is limiting traffic"
        default: "failed"
        }
    }

    public enum State: Sendable, Equatable {
        case disconnected, connecting, connected
    }

    public struct ModemInfo: Sendable, Equatable {
        public var manufacturer = ""
        public var model = ""
        public var imei = ""
        public init(manufacturer: String = "", model: String = "", imei: String = "") {
            self.manufacturer = manufacturer
            self.model = model
            self.imei = imei
        }
    }

    public struct SbdixResult: Sendable, Equatable {
        public let moStatus: Int
        public let moMsn: Int
        public let mtStatus: Int
        public let mtMsn: Int
        public let mtLength: Int
        public let mtQueued: Int
        /// The message this session brought in, already read from the modem, or nil.
        public var mt: [UInt8]?
        public var moSuccess: Bool { (0...4).contains(moStatus) }
        public var mtAvailable: Bool { mtStatus == 1 }
    }

    public struct SbdsxResult: Sendable, Equatable {
        public let moFlag: Bool
        public let moMsn: Int
        public let mtFlag: Bool
        public let mtMsn: Int
        public let raFlag: Bool
        public let msgWaiting: Int
    }

    /// The outcome of a mailbox check the user asked for.
    public enum MailboxResult: Sendable, Equatable {
        case notConnected
        /// No session was started: the hold after a failed one runs for this many seconds more.
        case held(seconds: Int64)
        /// The session failed, e.g. status 32: the modem sees no satellite.
        case sessionFailed(moStatus: Int)
        case noAnswer
        /// The session ran: `received` messages were handed over, `stillQueued` more wait at the gateway.
        case checked(received: Int, stillQueued: Int)
    }

    // MARK: Observed state
    public private(set) var state: State = .disconnected {
        didSet { if state != oldValue { stateChanges.send(state) } }
    }
    public private(set) var linkBroken = false {
        didSet { if linkBroken != oldValue { linkBrokenChanges.send(linkBroken) } }
    }
    public private(set) var modemSilent = false {
        didSet { if modemSilent != oldValue { modemSilentChanges.send(modemSilent) } }
    }
    public private(set) var signal = 0
    public private(set) var modemInfo = ModemInfo()

    public nonisolated let stateChanges = Broadcast<State>(replayLatest: true)
    public nonisolated let linkBrokenChanges = Broadcast<Bool>(replayLatest: true)
    public nonisolated let modemSilentChanges = Broadcast<Bool>(replayLatest: true)
    /// One per crossing, so the service can re-establish the link and arm again.
    public nonisolated let linkFaults = Broadcast<Void>(bufferSize: 1)
    /// Each satellite session's outcome, true when the gateway took it (MO status 0-4).
    public nonisolated let sessionOutcomes = Broadcast<Bool>()
    /// Every reading, repeated values included: a good one is the queue's cue to send now.
    public nonisolated let signalReadings = Broadcast<Int>(bufferSize: 1)
    public nonisolated let errors = Broadcast<String>()
    /// The modem reported a waiting MT message (unsolicited SBDRING).
    public nonisolated let ringAlerts = Broadcast<Void>(bufferSize: 4)

    // MARK: Internals
    private let clock: DriverClock
    private let commands = AsyncMutex()
    private let input = PipeInputBuffer()
    private var link: ModemLink?
    private var attachTask: Task<Void, Never>?
    /// No SBDIX before this time: set after status 32/36.
    private var sbdixHeldUntil: Int64 = 0
    /// When a 0 from AT+CSQF was last confirmed with a fresh AT+CSQ.
    private var csqConfirmedAt: Int64 = 0
    private var writeFailures = 0
    /// Where a message brought in by any satellite session goes, e.g. to be stored and shown.
    private var mtSink: (@Sendable ([UInt8]) async throws -> Void)?

    public init(clock: DriverClock = SystemDriverClock()) {
        self.clock = clock
    }

    public func setMtSink(_ sink: (@Sendable ([UInt8]) async throws -> Void)?) {
        mtSink = sink
    }

    // MARK: Link

    /// Use the link and probe the modem; the state is Connected once the probe ran.
    public func attach(_ newLink: ModemLink) {
        detach()
        link = newLink
        writeFailures = 0
        input.clear()
        let watcher = LineWatcher(line: "SBDRING") { [ringAlerts] in ringAlerts.send(()) }
        let input = self.input
        newLink.setReceiver { bytes in
            input.offer(bytes)
            watcher.feed(bytes)
        }
        state = .connecting
        attachTask = Task { [weak self] in
            guard let self else { return }
            guard await self.awaitModem(newLink) else { return }
            await self.probeModem()
            await self.markConnected(if: newLink)
        }
    }

    private func markConnected(if forLink: ModemLink) {
        if link === forLink { state = .connected }
    }

    /// Stop using the link; the node keeps the modem powered.
    public func detach() {
        attachTask?.cancel()
        attachTask = nil
        link?.setReceiver(nil)
        link = nil
        modemSilent = false
        state = .disconnected
    }

    /// Repeat the probe's first command until the modem answers. A node that has just switched
    /// its modem on gives it about 10 s before it answers AT; a node without one never does.
    private func awaitModem(_ forLink: ModemLink) async -> Bool {
        let start = clock.nowMs()
        while link === forLink, !Task.isCancelled {
            let resp = (try? await sendAT("AT&K0")) ?? ""
            if resp.contains("OK") || resp.contains("ERROR") {
                modemSilent = false
                return link === forLink
            }
            let silent = clock.nowMs() - start >= Self.wakeGraceMs
            if silent, !modemSilent {
                modemSilent = true
                errors.send("The node's modem does not answer AT; still trying")
            }
            let until = clock.nowMs() + (silent ? Self.silentRetryMs : Self.wakeRetryMs)
            while clock.nowMs() < until, link === forLink, !Task.isCancelled {
                await clock.sleep(ms: 20)
            }
        }
        return false
    }

    // MARK: AT commands

    private func sendAT(_ command: String, timeoutMs: Int64 = IridiumATDriver.atTimeoutMs) async throws -> String {
        await commands.acquire()
        defer { commands.release() }
        return try await sendATLocked(command, timeoutMs: timeoutMs)
    }

    private func sendATLocked(_ command: String, timeoutMs: Int64) async throws -> String {
        guard let link else { throw IridiumDriverError.notConnected }
        // Drain anything pending; an unsolicited SBDRING in it was already seen by the watcher.
        input.clear()
        do {
            try await link.write(Array((command + "\r").utf8))
        } catch PipeError.writeFailed {
            // Only a write that did not get through counts. A node holding its own modem throws
            // notOwned, which is a handover, not a broken link.
            noteWriteFailed()
            throw PipeError.writeFailed
        }
        noteWriteLanded()

        var buf = [UInt8]()
        let deadline = clock.nowMs() + timeoutMs
        while clock.nowMs() < deadline {
            if let b = input.read() {
                buf.append(b)
                if Self.endsResponse(buf) { break }
            } else {
                await clock.sleep(ms: 10)
            }
        }
        return String(decoding: buf, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let okCR = Array("OK\r".utf8)
    private static let errorCR = Array("ERROR\r".utf8)
    private static let readyCR = Array("READY\r".utf8)

    private static func endsResponse(_ buf: [UInt8]) -> Bool {
        hasSuffix(buf, okCR) || hasSuffix(buf, errorCR) || hasSuffix(buf, readyCR)
    }

    private static func hasSuffix(_ buf: [UInt8], _ token: [UInt8]) -> Bool {
        buf.count >= token.count && Array(buf[(buf.count - token.count)...]) == token
    }

    /// A write did not reach the node. Past `linkBrokenWrites` in a row the link counts as broken:
    /// the driver leaves Connected, so every public method gates itself and iridium_0 goes offline,
    /// and one fault goes out for the service to act on (MESHSAT-1270).
    private func noteWriteFailed() {
        writeFailures += 1
        if writeFailures < Self.linkBrokenWrites { return }
        writeFailures = 0
        linkBroken = true
        state = .disconnected
        linkFaults.send(())
    }

    /// A write reached the node, so whatever was wrong with the link is over.
    private func noteWriteLanded() {
        writeFailures = 0
        linkBroken = false
    }

    /// The first line of the response that is neither the echoed command nor OK.
    private static func infoLine(_ resp: String) -> String {
        resp.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("AT") && $0 != "OK" } ?? ""
    }

    private func probeModem() async {
        do {
            // AT&K0 (flow control off) already went out in awaitModem.
            _ = try await sendAT("ATE0")
            // Unsolicited SBDRING when an MT message waits: the node has no RI wire.
            _ = try await sendAT("AT+SBDMTA=1")
            let mfr = Self.infoLine(try await sendAT("AT+CGMI"))
            let model = Self.infoLine(try await sendAT("AT+CGMM"))
            let imei = Self.infoLine(try await sendAT("AT+CGSN"))
            modemInfo = ModemInfo(manufacturer: mfr, model: model, imei: imei)
            _ = await pollSignal()
        } catch {
            errors.send("Modem probe failed: \(error)")
        }
    }

    private var isWireReady: Bool { state == .connected }

    /// Read the signal strength, 0-5, free. A regular poll asks AT+CSQF for the modem's last
    /// reading; a 0 is confirmed with AT+CSQ at most once a minute. `fresh` always asks for a
    /// new reading and waits the full minute for it, for a person who pressed a button.
    @discardableResult
    public func pollSignal(fresh: Bool = false) async -> Int {
        guard link != nil else { return 0 }
        do {
            var sig = try await readSignal(fresh ? "AT+CSQ" : "AT+CSQF", timeoutMs: fresh ? Self.csqTimeoutMs : Self.csqfTimeoutMs)
            if !fresh, sig == 0, clock.nowMs() - csqConfirmedAt >= Self.csqConfirmIntervalMs {
                csqConfirmedAt = clock.nowMs()
                sig = try await readSignal("AT+CSQ", timeoutMs: Self.csqConfirmTimeoutMs)
            }
            signal = sig
            signalReadings.send(sig)
            return sig
        } catch {
            errors.send("Signal poll failed: \(error)")
            return 0
        }
    }

    /// One signal command; 0 when the answer carries no reading.
    private func readSignal(_ command: String, timeoutMs: Int64) async throws -> Int {
        let resp = try await sendAT(command, timeoutMs: timeoutMs)
        return Self.firstInt(in: resp, after: ["+CSQF:", "+CSQ:"]) ?? 0
    }

    /// The integer following the first of `markers` found in `resp`.
    private static func firstInt(in resp: String, after markers: [String]) -> Int? {
        for m in markers {
            guard let r = resp.range(of: m) else { continue }
            let tail = resp[r.upperBound...].trimmingCharacters(in: .whitespaces)
            let digits = tail.prefix { $0.isNumber }
            if let v = Int(digits) { return v }
        }
        return nil
    }

    /// The comma-separated integers after `marker`, or nil when there are fewer than `count`.
    private static func ints(in resp: String, after marker: String, count: Int) -> [Int]? {
        guard let r = resp.range(of: marker) else { return nil }
        let line = resp[r.upperBound...].split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = line.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= count, parts.prefix(count).allSatisfy({ $0 != nil }) else { return nil }
        return parts.prefix(count).compactMap { $0 }
    }

    /// Check SBD status (AT+SBDSX), free, no RF needed.
    public func sbdStatus() async -> SbdsxResult? {
        guard isWireReady else { return nil }
        do {
            let resp = try await sendAT("AT+SBDSX")
            guard let v = Self.ints(in: resp, after: "+SBDSX:", count: 6) else { return nil }
            return SbdsxResult(moFlag: v[0] != 0, moMsn: v[1], mtFlag: v[2] != 0, mtMsn: v[3], raFlag: v[4] != 0, msgWaiting: v[5])
        } catch {
            errors.send("SBDSX failed: \(error)")
            return nil
        }
    }

    /// Write binary data to the MO buffer (AT+SBDWB). Max 340 bytes.
    public func writeMoBuffer(_ data: [UInt8]) async -> Bool {
        guard isWireReady else { return false }
        if data.count > Self.moMaxSize {
            errors.send("MO payload too large: \(data.count) > \(Self.moMaxSize)")
            return false
        }
        await commands.acquire()
        defer { commands.release() }
        do {
            do {
                let resp = try await sendATLocked("AT+SBDWB=\(data.count)", timeoutMs: Self.atTimeoutMs)
                guard resp.contains("READY") else {
                    errors.send("SBDWB not ready: \(resp)")
                    return false
                }
                guard let link else { throw IridiumDriverError.notConnected }
                // Payload + 2-byte checksum, one write so it leaves in as few chunks as the link allows.
                let checksum = data.reduce(0) { $0 + Int($1) }
                try await link.write(data + [UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF)])
                // "0" is success; 1 timeout, 2 bad checksum, 3 wrong size.
                let result = await readUntilOkOrTimeout(Self.atTimeoutMs)
                let code = result.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { $0.count == 1 && $0.first!.isNumber }
                if code != "0" { errors.send("SBDWB rejected: \(code ?? result.trimmingCharacters(in: .whitespacesAndNewlines))") }
                return code == "0"
            }
        } catch {
            errors.send("SBDWB failed: \(error)")
            return false
        }
    }

    /// Milliseconds until the next SBDIX may be sent, 0 if it may be sent now.
    public func sbdixHoldRemainingMs() -> Int64 {
        max(0, sbdixHeldUntil - clock.nowMs())
    }

    /// SBD session (AT+SBDIX), billed. Refused while held after status 32/36. The MO buffer is
    /// cleared afterwards whatever the outcome: the caller's queue keeps the message for a retry.
    public func sbdix(deliverMt: Bool = true, answeringRing: Bool = false) async -> SbdixResult? {
        guard isWireReady else { return nil }
        let hold = sbdixHoldRemainingMs()
        if hold > 0 {
            errors.send("SBDIX held for \(hold / 1000) s after a failed session")
            return nil
        }
        do {
            // +SBDIXA marks a session that answers a ring alert (MAN0009, +SBDIX[A]).
            let resp = try await sendAT(answeringRing ? "AT+SBDIXA" : "AT+SBDIX", timeoutMs: Self.sbdixTimeoutMs)
            guard let v = Self.ints(in: resp, after: "+SBDIX:", count: 6) else {
                // Never silent: a session whose answer cannot be read may still have sent.
                errors.send("The modem's answer to a satellite session could not be read")
                return nil
            }
            var result = SbdixResult(moStatus: v[0], moMsn: v[1], mtStatus: v[2], mtMsn: v[3], mtLength: v[4], mtQueued: v[5], mt: nil)
            if result.moStatus == 32 || result.moStatus == 36 { sbdixHeldUntil = clock.nowMs() + Self.sbdixHoldMs }
            sessionOutcomes.send(result.moSuccess)
            _ = await clearMoBuffer()
            // A message came in with this session: read it now, before another session overwrites it.
            var mt: [UInt8]?
            if result.mtAvailable, let read = await readMtBinary(), !read.isEmpty { mt = read }
            if let mt {
                if deliverMt {
                    var delivered = false
                    if let sink = mtSink {
                        do {
                            try await sink(mt)
                            delivered = true
                        } catch {
                            errors.send("Storing the message that came in failed: \(error)")
                        }
                    }
                    // Only once it is safely stored: the modem holds the message, and its MT flag
                    // stays up, until it is told to drop it (MESHSAT-1266).
                    if delivered { _ = await clearMtBuffer() }
                }
                result.mt = mt
            }
            return result
        } catch {
            errors.send("SBDIX failed: \(error)")
            return nil
        }
    }

    /// Clear the MO buffer (AT+SBDD0), so a later session does not send it again.
    public func clearMoBuffer() async -> Bool {
        guard isWireReady else { return false }
        do {
            return Self.infoLine(try await sendAT("AT+SBDD0")) == "0"
        } catch {
            errors.send("SBDD0 failed: \(error)")
            return false
        }
    }

    /// Clear the MT buffer (AT+SBDD1), once the message in it has been stored (MESHSAT-1266).
    public func clearMtBuffer() async -> Bool {
        guard isWireReady else { return false }
        do {
            return Self.infoLine(try await sendAT("AT+SBDD1")) == "0"
        } catch {
            errors.send("SBDD1 failed: \(error)")
            return false
        }
    }

    /// Read the MT buffer (AT+SBDRB), binary-safe. The message, an empty array when the buffer
    /// is empty, or nil on a transport or checksum error.
    public func readMtBinary() async -> [UInt8]? {
        guard isWireReady else { return nil }
        do {
            await commands.acquire()
            defer { commands.release() }
            return try await readMtBinaryLocked()
        } catch {
            errors.send("SBDRB failed: \(error)")
            return nil
        }
    }

    private func readMtBinaryLocked() async throws -> [UInt8] {
        guard let link else { throw IridiumDriverError.notConnected }
        input.clear()
        let command = Array("AT+SBDRB\r".utf8)
        try await link.write(command)

        var raw = [UInt8]()
        let deadline = clock.nowMs() + Self.atTimeoutMs
        var frameStart = -1
        var needed = -1
        while clock.nowMs() < deadline {
            guard let b = input.read() else {
                await clock.sleep(ms: 10)
                continue
            }
            raw.append(b)
            if frameStart < 0 {
                // With echo on the reply starts with the command itself.
                if raw.count < command.count, Array(command[0..<raw.count]) == raw {
                    continue
                } else if raw.count >= command.count, Array(raw[0..<command.count]) == command {
                    frameStart = command.count
                } else {
                    frameStart = 0
                }
            }
            if needed < 0, raw.count >= frameStart + 2 {
                let len = Int(raw[frameStart]) << 8 | Int(raw[frameStart + 1])
                if len > Self.mtMaxSize { throw IridiumDriverError.protocolError("SBDRB length \(len) > \(Self.mtMaxSize)") }
                needed = frameStart + 2 + len + 2
            }
            if needed >= 1, needed <= raw.count {
                let len = needed - frameStart - 4
                let msg = Array(raw[(frameStart + 2)..<(frameStart + 2 + len)])
                let sum = Int(raw[needed - 2]) << 8 | Int(raw[needed - 1])
                _ = await readUntilOkOrTimeout(Self.atTimeoutMs)
                if msg.reduce(0, { $0 + Int($1) }) & 0xFFFF != sum { throw IridiumDriverError.protocolError("SBDRB checksum mismatch") }
                return msg
            }
        }
        throw IridiumDriverError.timeout("SBDRB timed out")
    }

    /// Check the satellite mailbox on request. Billed: one SBDIX, at least one credit even when
    /// nothing waits. A message already in the MT buffer is read first, for free. The MO buffer
    /// is emptied first: outgoing messages belong to the delivery queue.
    public func checkMailbox(onMessage: @Sendable ([UInt8]) async -> Void) async -> MailboxResult {
        guard isWireReady else { return .notConnected }
        let hold = sbdixHoldRemainingMs()
        if hold > 0 { return .held(seconds: (hold + 999) / 1000) }

        let status = await sbdStatus()
        var received = 0
        if status?.mtFlag == true, let mt = await readMtBinary(), !mt.isEmpty {
            await onMessage(mt)
            received += 1
        }
        if status?.moFlag == true, !(await clearMoBuffer()) { return .noAnswer }
        // The session's message is handed over here, not through mtSink, so it is stored once.
        guard let result = await sbdix(deliverMt: false) else { return .noAnswer }
        if let mt = result.mt {
            await onMessage(mt)
            received += 1
        }
        if !result.moSuccess { return .sessionFailed(moStatus: result.moStatus) }
        return .checked(received: received, stillQueued: result.mtQueued)
    }

    /// Free end-to-end check of the link and the modem, with no satellite session: write `size`
    /// bytes (CR, LF and 0x00 included) to the MO buffer, copy them to the MT buffer (AT+SBDTC)
    /// and read them back (AT+SBDRB). Both buffers are cleared afterwards.
    public func loopbackTest(size: Int = 100) async -> Bool {
        guard isWireReady else { return false }
        let n = min(max(size, 1), Self.mtMaxSize)
        let payload: [UInt8] = (0..<n).map { i in
            switch i % 4 {
            case 0: 0x0D
            case 1: 0x0A
            case 2: 0x00
            default: UInt8(truncatingIfNeeded: i)
            }
        }
        defer { Task { _ = try? await self.sendAT("AT+SBDD2") } }
        guard await writeMoBuffer(payload) else { return false }
        guard let tc = try? await sendAT("AT+SBDTC"), tc.contains("OK") else { return false }
        let back = await readMtBinary()
        return back == payload
    }

    /// Read the MT buffer as UTF-8 text; nil when empty or unreadable.
    public func readMtBuffer() async -> String? {
        guard let data = await readMtBinary(), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func readUntilOkOrTimeout(_ timeoutMs: Int64) async -> String {
        var buf = [UInt8]()
        let deadline = clock.nowMs() + timeoutMs
        while clock.nowMs() < deadline {
            if let b = input.read() {
                buf.append(b)
                let s = String(decoding: buf, as: UTF8.self)
                if s.contains("OK") || s.contains("ERROR") { break }
            } else {
                await clock.sleep(ms: 10)
            }
        }
        return String(decoding: buf, as: UTF8.self)
    }
}
