// Mirrors bt/Iridium9704Spp.kt (MESHSAT-245, MESHSAT-1507): the RockBLOCK 9704 IMT driver, JSPR
// (JSON Serial Protocol for REST, 230400 baud) over a byte link, the node's BLE Iridium pipe, as
// IridiumATDriver runs the 9603 over it. iOS had no 9704 driver (MESHSAT-1513). [MESHSAT-1624]
//
// Requests go out as "METHOD target {json}\r" with a space after every colon and comma, as the
// official RockBLOCK-9704 C library writes them: the modem's parser answers compact JSON with
// 407 BAD_JSON. Answers come back as "CODE target {json}\r"; code 299 is unsolicited: signal, MO
// segment requests and status, MT notification, segments and status, handled one at a time in
// the order they came. The modem segments an MO itself: it asks for each segment and the host
// answers with its bytes in base64, up to 1446 at a time. Every message ends in a CRC-16/XMODEM
// (poly 0x1021, init 0), big-endian: added on MO, checked and taken off on MT.
//
// An accepted message stays in the modem until it goes or is cancelled, so a send that walks away
// on a timeout leaves it there and the retry queues a second copy (the Bridge's 20 message soak of
// 21 Sep 2026: 7 duplicates, MESHSAT-1282). As the Bridge does (internal/transport/jspr.go,
// cmd/jspr-helper), a send with no final status after 150 s is cancelled by its message_id with
// Ground Control's PUT messageOriginateStatus {"action": "cancel"}, and the modem's one answer for
// that id settles it within 20 s: cancelled (a retry is safe) or mo_ack_received (it went).
import Foundation
import Logging
import MeshSatNet
import MeshSatWire

public actor Iridium9704Driver {
    // MARK: Constants (the Kotlin companion object)
    public static let jsprTimeoutMs: Int64 = 10_000
    /// Through the node's Bluetooth pipe a constellationState answer can take longer than 2 s, and a
    /// missed one used to read as 0 bars (MESHSAT-1670).
    public static let signalTimeoutMs: Int64 = SignalFreshness.pollTimeoutMs
    /// How often the driver looks whether a signal reading is due (MESHSAT-1670): it asks the modem
    /// only when no reading came for SignalFreshness.pollIntervalMs and no send is under way.
    public static let signalCheckMs: Int64 = 5_000
    /// The poll loop's pause between looks at the link; shorter while a send is under way, as the
    /// modem gives up on its segment request after about 360 ms (MESHSAT-1674).
    public static let pollPauseMs: Int64 = 50
    public static let pollPauseSendingMs: Int64 = 10
    /// Before a command, a half-arrived line is given this long to finish (MESHSAT-1674).
    public static let partialLineGraceMs: Int64 = 20
    public static let moBudgetMs: Int64 = 150_000
    public static let moCancelSettleMs: Int64 = 20_000
    /// A send's answer when the modem never settled its cancel: the message may still go out.
    public static let moCancelUnanswered = "cancel_unanswered"
    /// The largest segment the modem asks for at once.
    public static let maxSegmentSize = 1446
    /// IMT topic for raw payloads; the Reticulum interface sends on it too (MESHSAT-1553).
    public static let rawTopic = 244
    /// Max IMT message size (100 KB).
    public static let imtMaxSize = 100_000

    /// True when a messageOriginateStatus naming `statusId` settles the send in flight as
    /// `inFlightId`. The modem reports every message it holds, including those the node or another
    /// client queued on it (MESHSAT-1507), so another id never settles this send. A status without
    /// an id (-1) still does, as before.
    public static func moStatusSettles(inFlightId: Int, statusId: Int) -> Bool { statusId < 0 || statusId == inFlightId }

    /// The bars after a signal read: the modem's answer, or the last reading when it did not answer
    /// in time. An unanswered read used to set 0, so the app showed 0/5 while the modem was sending
    /// (MSC-2 unit 0001, 24 Oct 2026, MESHSAT-1670); the Bridge keeps its last reading the same way
    /// (internal/transport/direct_imt.go GetSignal and GetSignalFast).
    public static func signalAfterPoll(previous: Int, answeredBars: Int?) -> Int {
        guard let answeredBars else { return previous }
        return min(max(answeredBars, 0), 5)
    }

    public enum State: Sendable, Equatable {
        case disconnected, connecting, connected, initializing, ready
    }

    public enum MoStatus: Sendable, Equatable {
        case idle, pending, segmenting, complete, failed
    }

    public struct ModemInfo: Sendable, Equatable {
        public var imei = ""
        public var serial = ""
        public var firmwareVersion = ""
        public var hardwareVersion = ""
        public var boardTemp = 0
        public init(
            imei: String = "", serial: String = "", firmwareVersion: String = "", hardwareVersion: String = "", boardTemp: Int = 0
        ) {
            self.imei = imei
            self.serial = serial
            self.firmwareVersion = firmwareVersion
            self.hardwareVersion = hardwareVersion
            self.boardTemp = boardTemp
        }
    }

    // MARK: Observed state
    public private(set) var state: State = .disconnected {
        didSet { if state != oldValue { stateChanges.send(state) } }
    }
    public private(set) var signal = 0
    public private(set) var modemInfo = ModemInfo()
    public private(set) var moStatus: MoStatus = .idle

    public nonisolated let stateChanges = Broadcast<State>(replayLatest: true)
    /// Every reading, polled or unsolicited, repeated values included.
    public nonisolated let signalReadings = Broadcast<Int>(bufferSize: 1)
    /// The last signal reading and its time, nil until the modem gave one on this link (MESHSAT-1670).
    public nonisolated let reading = StateBroadcast<SignalReading?>(nil)
    /// The signal reads' round trips on this link, for the bench (MESHSAT-1670).
    public nonisolated let pollStats = StateBroadcast<SignalPollStats>(SignalPollStats())
    /// The last MO segment request and how fast this app answered it (MESHSAT-1674).
    public nonisolated let segmentTiming = StateBroadcast<SegmentTiming?>(nil)
    public nonisolated let errors = Broadcast<String>()

    // MARK: Internals
    private static let log = Logger(label: "Iridium9704")
    private let clock: DriverClock
    /// One JSPR exchange at a time, the poll loop's reads included (Android's serialLock).
    private let serial = AsyncMutex()
    private let input = PipeInputBuffer()
    private var link: ModemLink?
    private var attachTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var signalWatchTask: Task<Void, Never>?
    private var polling = false
    private var pollRoundTrips: [Int64] = []
    private var pollsAnswered = 0
    private var pollsMissed = 0
    /// Where a message that came in goes, e.g. to be stored and shown.
    private var mtSink: (@Sendable ([UInt8]) async throws -> Void)?
    private var unsolicited: [JsprResponse] = []
    private var handlingUnsolicited = false

    // MO state
    private var moPayload: [UInt8]?
    /// The whole payload as one segment's data, encoded when the send starts, so the answer to the
    /// modem's usual single segment request is ready at once (MESHSAT-1674).
    private var moPayloadB64: String?
    private var moStartedAtMs: Int64 = 0
    private var moMessageId = 0
    private var moTopicId = Iridium9704Driver.rawTopic
    private var moRequestRef = 0
    private var nextRequestRef = 1
    private var moFinalStatus = ""

    // MT state. The buffer grows as segments land, zero-filled as Android's array of
    // message_length_max bytes is, so an announced length is never allocated up front.
    private var mtBuffer: [UInt8]?
    private var mtLengthMax = 0
    private var mtReceived = 0
    private var mtMessageId = 0
    private var mtTopicId = 0

    public init(clock: DriverClock = SystemDriverClock()) {
        self.clock = clock
    }

    public func setMtSink(_ sink: (@Sendable ([UInt8]) async throws -> Void)?) {
        mtSink = sink
    }

    /// Bytes the modem sent that no read has taken yet.
    nonisolated var bufferedInput: Int { input.available }

    // MARK: Link

    /// Use the node's Iridium pipe as the serial link, as the 9603 driver does: the node has given
    /// this phone the modem, the bytes are JSPR at 230400 on the node's UART. The init runs as
    /// after an SPP connect; its first request may be answered MALFORMED because the node's reset
    /// text sits in the modem's parser, and the init retries after a drain.
    public func attach(_ newLink: ModemLink) {
        detach()
        link = newLink
        input.clear()
        let input = self.input
        newLink.setReceiver { bytes in input.offer(bytes) }
        forgetReadings()
        state = .connected
        attachTask = Task { [weak self] in await self?.initialize(newLink) }
    }

    /// `attach` only while the driver is idle, as one step: the pipe observer and its retry can
    /// both find the 9704 down at the same moment, and two inits on one link would read each
    /// other's replies.
    public func attachIfIdle(_ newLink: ModemLink) -> Bool {
        guard state == .disconnected else { return false }
        attach(newLink)
        return true
    }

    /// True while the driver rides the node's pipe, including after an init over it failed.
    public var onNodePipe: Bool { link != nil }

    /// Stop using the node's pipe without closing it; the node keeps the modem powered.
    public func detach() {
        guard let old = link else { return }
        polling = false
        pollTask?.cancel()
        pollTask = nil
        signalWatchTask?.cancel()
        signalWatchTask = nil
        attachTask?.cancel()
        attachTask = nil
        old.setReceiver(nil)
        link = nil
        state = .disconnected
    }

    // MARK: JSPR initialization sequence

    private func initialize(_ forLink: ModemLink) async {
        guard link === forLink else { return }
        state = .initializing
        do {
            input.clear()
            await clock.sleep(ms: 5)  // settling time after the drain (per the official library)
            try await negotiateApiVersion(forLink)

            // Step 2: the SIM.
            try ensure(forLink)
            let simInterface = try await sendJspr("GET", "simConfig").map { Self.optString($0.json, "interface", "") }
            if simInterface != "internal" {
                _ = try await sendJspr("PUT", "simConfig", JsprBody([("interface", .string("internal"))]))
                await clock.sleep(ms: 500)
                // Drain the unsolicited simStatus.
                await serial.acquire()
                input.clear()
                serial.release()
            }

            // Step 3: the operational state, active.
            try ensure(forLink)
            let current = try await sendJspr("GET", "operationalState").map { Self.optString($0.json, "state", "") }
            if current != "active" {
                if current != "inactive" {
                    _ = try await sendJspr("PUT", "operationalState", JsprBody([("state", .string("inactive"))]))
                    await clock.sleep(ms: 200)
                }
                _ = try await sendJspr("PUT", "operationalState", JsprBody([("state", .string("active"))]))
            }

            // Step 4: hardware info, then the firmware version from the modem's own firmware query:
            // hwInfo carries only the hardware version, which the firmware field used to repeat. [MESHSAT-1630]
            try ensure(forLink)
            if let hw = try await sendJspr("GET", "hwInfo")?.json {
                try ensure(forLink)
                let firmware = Self.firmwareVersion(try await sendJspr("GET", "firmware", JsprBody([("slot", .string("primary"))]))?.json)
                modemInfo = ModemInfo(
                    imei: Self.optString(hw, "imei", ""), serial: Self.optString(hw, "serial_number", ""),
                    firmwareVersion: firmware, hardwareVersion: Self.optString(hw, "hw_version", ""),
                    boardTemp: Self.optInt(hw, "board_temp", 0))
            }

            // Step 5: the signal.
            try ensure(forLink)
            await pollSignal()
            await clock.sleep(ms: 100)  // the modem needs settling time after begin
            try ensure(forLink)
            state = .ready
            Self.log.info("9704 initialized: \(modemInfo)")
            startPollLoop(forLink)
            startSignalWatch(forLink)
        } catch {
            // A detach meanwhile is not a failed init.
            guard link === forLink else { return }
            errors.send("9704 init failed: \(error)")
            state = .disconnected
        }
    }

    /// The API version, up to 3 attempts as the Go driver: an active one is taken, else the first
    /// supported one is set (as the official C library does).
    private func negotiateApiVersion(_ forLink: ModemLink) async throws {
        for attempt in 1...3 {
            try ensure(forLink)
            if attempt > 1 {
                await clock.sleep(ms: 5)
                input.clear()
            }
            guard let resp = try await sendJspr("GET", "apiVersion")?.json else { continue }
            if resp["active_version"] is [String: Any] { return }
            if let versions = resp["supported_versions"] as? [Any], let first = versions.first {
                guard let version = first as? [String: Any] else {
                    throw IridiumDriverError.protocolError("supported_versions[0] is not an object")
                }
                _ = try await sendJspr("PUT", "apiVersion", JsprBody([("active_version", .object(JsprBody(version)))]))
                return
            }
        }
        throw IridiumDriverError.protocolError("Failed to negotiate API version after 3 attempts")
    }

    private func ensure(_ forLink: ModemLink) throws {
        guard link === forLink, !Task.isCancelled else { throw IridiumDriverError.notConnected }
    }

    // MARK: JSPR serial I/O

    /// Send a JSPR request and wait for the answer naming its target, or any error answer (the
    /// modem may use another target then); nil on a timeout. Unsolicited (299) lines read while
    /// waiting are queued for their handlers.
    /// The modem's firmware version as the official RockBLOCK 9704 C library makes it
    /// (`rbGetFirmwareVersion`): "v" major.minor.patch from `GET firmware {"slot": "primary"}`, or ""
    /// when the modem did not answer. [MESHSAT-1630]
    static func firmwareVersion(_ json: [String: Any]?) -> String {
        guard let v = json?["version"] as? [String: Any], let major = v["major"] as? Int, let minor = v["minor"] as? Int,
            let patch = v["patch"] as? Int
        else { return "" }
        return "v\(major).\(minor).\(patch)"
    }

    private func sendJspr(
        _ method: String, _ target: String, _ payload: JsprBody = JsprBody([]), timeoutMs: Int64 = Iridium9704Driver.jsprTimeoutMs
    ) async throws -> JsprResponse? {
        guard let forLink = link else { throw IridiumDriverError.notConnected }
        await serial.acquire()
        defer { serial.release() }
        // The link may have changed hands while this request waited for the line.
        guard link === forLink else { throw IridiumDriverError.notConnected }
        await clearBeforeCommand(forLink)
        try await forLink.write(Array("\(method) \(target) \(Self.spacedJson(payload.text))\r".utf8))

        let deadline = clock.nowMs() + timeoutMs
        while clock.nowMs() < deadline {
            let remaining = deadline - clock.nowMs()
            if remaining <= 0 { break }
            guard let resp = try await readJsprResponse(remaining, on: forLink) else { continue }
            if resp.code == 299 {
                // A segment request is answered here and now, the rest handed on (MESHSAT-1674).
                await dispatchUnsolicited(resp, on: forLink)
                continue
            }
            if resp.target == target || resp.code >= 400 {
                if resp.code != 200 { Self.log.warning("JSPR \(method) \(target) -> \(resp.code)") }
                return resp
            }
            Self.log.debug("JSPR discard: expected=\(target) got=\(resp.target)")
        }
        Self.log.warning("JSPR timeout: \(method) \(target)")
        return nil
    }

    /// One JSPR line, or nil on a timeout; whatever arrived by then is parsed.
    private func readJsprResponse(_ timeoutMs: Int64, on forLink: ModemLink) async throws -> JsprResponse? {
        var buf: [UInt8] = []
        let deadline = clock.nowMs() + timeoutMs
        while clock.nowMs() < deadline {
            guard link === forLink else { throw IridiumDriverError.notConnected }
            guard let b = input.read() else {
                await clock.sleep(ms: 5)
                continue
            }
            // Non-printable bytes before the response code are dropped (the modem may send DC1 on boot).
            if buf.isEmpty, b != 0x0D, b < 0x20 || b > 0x7E { continue }
            if b == 0x0D {
                if buf.isEmpty { continue }
                return Self.parseJsprLine(buf)
            }
            buf.append(b)
        }
        return buf.isEmpty ? nil : Self.parseJsprLine(buf)
    }

    /// "CODE target {json}": nil when the line does not start with a code from 200 to 500.
    static func parseJsprLine(_ line: [UInt8]) -> JsprResponse? {
        guard line.count >= 3, let code = Int(String(decoding: line[0..<3], as: UTF8.self)), (200...500).contains(code) else {
            return nil
        }
        var pos = 3
        while pos < line.count, line[pos] == 0x20 { pos += 1 }
        guard let targetEnd = line[pos...].firstIndex(of: 0x20) else {
            // A target only, no JSON.
            let target = String(decoding: line[pos...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return JsprResponse(code: code, target: target, json: [:], jsonText: "")
        }
        let target = String(decoding: line[pos..<targetEnd], as: UTF8.self)
        let text = String(decoding: line[(targetEnd + 1)...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var json: [String: Any] = [:]
        if text.hasPrefix("{"), let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            json = parsed
        }
        return JsprResponse(code: code, target: target, json: json, jsonText: text)
    }

    // MARK: Poll loop: the unsolicited 299 lines

    private func startPollLoop(_ forLink: ModemLink) {
        polling = true
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.pollOnce(forLink) else { return }
            }
        }
    }

    /// Reads one line if one is waiting and queues it when it is unsolicited; false once the loop
    /// should stop.
    private func pollOnce(_ forLink: ModemLink) async -> Bool {
        guard polling, link === forLink else { return false }
        await serial.acquire()
        var resp: JsprResponse?
        var failure: Error?
        if input.available > 0 {
            do {
                resp = try await readJsprResponse(1000, on: forLink)
            } catch {
                failure = error
            }
        }
        if failure == nil, let resp, resp.code == 299 { await dispatchUnsolicited(resp, on: forLink) }
        serial.release()
        if let failure {
            if polling, link === forLink {
                errors.send("9704 poll error: \(failure)")
                detach()
            }
            return false
        }
        await clock.sleep(ms: moStatus == .idle ? Self.pollPauseMs : Self.pollPauseSendingMs)
        return true
    }

    /// An unsolicited frame, from whichever reader holds the line: the modem's request for an MO
    /// segment is answered right here, ahead of anything else (MESHSAT-1674); every other frame is
    /// queued for `handleUnsolicited` in the order it came.
    private func dispatchUnsolicited(_ resp: JsprResponse, on forLink: ModemLink) async {
        if resp.target == "messageOriginateSegment" {
            await answerSegment(resp.json, readAtMs: clock.nowMs(), on: forLink)
            return
        }
        enqueueUnsolicited(resp)
    }

    /// Before a command (MESHSAT-1674): whatever the link holds is read, every complete unsolicited
    /// frame is dispatched and the rest dropped (an answer that came too late, the node's reset
    /// text). Clearing the buffer threw away a segment request that had just arrived, and the modem
    /// failed the send with segment_not_supplied. A half-arrived line gets `partialLineGraceMs` to
    /// finish. The caller holds the line.
    private func clearBeforeCommand(_ forLink: ModemLink) async {
        var buf: [UInt8] = []
        var quietUntil = clock.nowMs() + Self.partialLineGraceMs
        while true {
            if let b = input.read() {
                quietUntil = clock.nowMs() + Self.partialLineGraceMs
                if b == 0x0D {
                    if !buf.isEmpty {
                        if let frame = Self.parseJsprLine(buf), frame.code == 299 {
                            await dispatchUnsolicited(frame, on: forLink)
                        } else {
                            Self.log.debug("JSPR dropped before a command: \(String(decoding: buf, as: UTF8.self))")
                        }
                        buf.removeAll()
                    }
                    continue
                }
                if buf.isEmpty && (b < 0x20 || b > 0x7E) { continue }
                buf.append(b)
            } else {
                if buf.isEmpty || clock.nowMs() >= quietUntil { break }
                await clock.sleep(ms: 2)
            }
        }
    }

    /// Unsolicited lines other than segment requests go to their handlers one at a time, in
    /// arrival order: an MT's segments never overtake its notification.
    private func enqueueUnsolicited(_ resp: JsprResponse) {
        unsolicited.append(resp)
        guard !handlingUnsolicited else { return }
        handlingUnsolicited = true
        Task { await self.drainUnsolicited() }
    }

    private func drainUnsolicited() async {
        while !unsolicited.isEmpty {
            let resp = unsolicited.removeFirst()
            await handleUnsolicited(resp)
        }
        handlingUnsolicited = false
    }

    private func handleUnsolicited(_ resp: JsprResponse) async {
        switch resp.target {
        case "constellationState":
            // An event without the field is no reading, never 0 bars (MESHSAT-1670).
            if resp.json["signal_bars"] != nil {
                recordReading(Self.optInt(resp.json, "signal_bars", 0))
                Self.log.debug("Signal: \(signal)/5")
            }
        case "messageOriginateSegment":
            // Answered by the reader that read it (dispatchUnsolicited); never queued.
            break
        case "messageOriginateStatus": handleMoStatus(resp.json)
        case "messageTerminate": handleMtNotification(resp.json)
        case "messageTerminateSegment": handleMtSegment(resp.json)
        case "messageTerminateStatus": await handleMtStatus(resp.json)
        default: Self.log.debug("Unsolicited: \(resp.code) \(resp.target) \(resp.jsonText)")
        }
    }

    // MARK: MO (mobile originated)

    /// Starts a send of up to 100 KB and returns at once; `moStatus` follows it. False when not
    /// ready, busy with another send, or too long.
    public func sendMessage(_ data: [UInt8], topicId: Int = Iridium9704Driver.rawTopic) -> Bool {
        guard state == .ready, moStatus == .idle, data.count <= Self.imtMaxSize else { return false }
        let crc = Self.crc16(data)
        let payloadWithCrc = data + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        moPayload = payloadWithCrc
        moPayloadB64 = Self.jsprSegmentData(payloadWithCrc)
        moStartedAtMs = clock.nowMs()
        moTopicId = topicId
        moRequestRef = nextRequestRef
        nextRequestRef = nextRequestRef % 100 + 1
        moStatus = .pending
        let request = JsprBody([
            ("topic_id", .int(topicId)), ("message_length", .int(payloadWithCrc.count)), ("request_reference", .int(moRequestRef)),
        ])
        Task { await self.originate(request) }
        return true
    }

    private func originate(_ request: JsprBody) async {
        do {
            let resp = try await sendJspr("PUT", "messageOriginate", request)?.json
            let messageResponse = resp.map { Self.optString($0, "message_response", "") } ?? ""
            if messageResponse == "message_accepted" {
                moMessageId = resp.map { Self.optInt($0, "message_id", 0) } ?? 0
                moStatus = .segmenting
                Self.log.debug("MO accepted: id=\(moMessageId)")
            } else {
                Self.log.warning("MO rejected: \(messageResponse)")
                moStatus = .failed
                moFinalStatus = messageResponse
                errors.send("MO rejected: \(messageResponse)")
            }
        } catch {
            moStatus = .failed
            errors.send("MO send failed: \(error)")
        }
    }

    /// Sends and waits for the final MO status: the status string, nil when the send never
    /// started or was never accepted, or `moCancelUnanswered` when a cancel after the budget was
    /// never settled.
    public func sendMessageBlocking(_ data: [UInt8], topicId: Int = Iridium9704Driver.rawTopic) async -> String? {
        guard sendMessage(data, topicId: topicId) else { return nil }
        if let status = await awaitMoFinal(Self.moBudgetMs) { return status }
        switch moStatus {
        case .complete, .failed:
            // The answer landed as the budget ran out.
            let status = moFinalStatus
            resetMoStatus()
            return status
        case .segmenting:
            break
        default:
            // Never accepted: nothing of this send is in the modem.
            resetMoStatus()
            return nil
        }
        let id = moMessageId
        Self.log.warning("MO \(id): no final status in \(Self.moBudgetMs / 1000) s; cancelling it in the modem")
        let cancel = JsprBody([("topic_id", .int(moTopicId)), ("message_id", .int(id)), ("action", .string("cancel"))])
        let answer = try? await sendJspr("PUT", "messageOriginateStatus", cancel)
        if answer != nil, let status = await awaitMoFinal(Self.moCancelSettleMs) { return status }
        Self.log.warning("MO \(id): the modem did not settle the cancel; the message may still go out")
        resetMoStatus()
        return Self.moCancelUnanswered
    }

    /// The final status of the send in flight, once `handleMoStatus` has it, or nil after `budgetMs`.
    private func awaitMoFinal(_ budgetMs: Int64) async -> String? {
        let deadline = clock.nowMs() + budgetMs
        while clock.nowMs() < deadline {
            switch moStatus {
            case .complete, .failed:
                let status = moFinalStatus
                resetMoStatus()
                return status
            default:
                await clock.sleep(ms: 100)
            }
        }
        return nil
    }

    /// The modem asks for a segment of the MO payload (299 messageOriginateSegment
    /// {segment_start, segment_length}); the answer is PUT messageOriginateSegment {data: base64}.
    ///
    /// Called by the reader that holds the line, the moment the request is read (MESHSAT-1674):
    /// the 9704 gives up after about 360 ms, and behind the node's pipe a request that waited for a
    /// signal read or an MT's handling failed the send with segment_not_supplied. The answer echoes
    /// the request's own topic and message id, as Ground Control's library does, so it never waits
    /// for the accept to be booked; it goes out on the link's urgent lane. `readAtMs` is when the
    /// request was read.
    private func answerSegment(_ json: [String: Any], readAtMs: Int64, on forLink: ModemLink) async {
        guard let payload = moPayload else { return }
        let segStart = Self.optInt(json, "segment_start", 0)
        let segLen = Self.optInt(json, "segment_length", 0)
        // Negative values are refused here too: Android would throw on them.
        guard segStart >= 0, segLen >= 0, segLen <= payload.count, segStart <= payload.count - segLen else {
            Self.log.warning("MO segment request out of bounds: start=\(segStart) len=\(segLen) payload=\(payload.count)")
            return
        }
        let data =
            segStart == 0 && segLen == payload.count && moPayloadB64 != nil
            ? moPayloadB64 ?? "" : Self.jsprSegmentData(Array(payload[segStart..<(segStart + segLen)]))
        let segment = JsprBody([
            ("topic_id", .int(json["topic_id"] != nil ? Self.optInt(json, "topic_id", moTopicId) : moTopicId)),
            ("message_id", .int(json["message_id"] != nil ? Self.optInt(json, "message_id", moMessageId) : moMessageId)),
            ("segment_length", .int(segLen)), ("segment_start", .int(segStart)), ("data", .string(data)),
        ])
        guard link === forLink else { return }
        do {
            try await forLink.writeUrgent(Array("PUT messageOriginateSegment \(Self.spacedJson(segment.text))\r".utf8))
            let timing = SegmentTiming(
                askedAfterMs: readAtMs - moStartedAtMs, answeredInMs: clock.nowMs() - readAtMs, segmentLength: segLen)
            segmentTiming.send(timing)
            let line = "MO segment sent: start=\(segStart) len=\(segLen), asked \(timing.askedAfterMs) ms after the send, "
            Self.log.debug("\(line)answered in \(timing.answeredInMs) ms")
        } catch {
            Self.log.error("Failed to send MO segment: \(error)")
        }
    }

    private func handleMoStatus(_ json: [String: Any]) {
        let status = Self.optString(json, "final_mo_status", "")
        let id = Self.optInt(json, "message_id", -1)
        guard moStatus == .segmenting, Self.moStatusSettles(inFlightId: moMessageId, statusId: id) else {
            // A message this phone is not waiting for: it neither settles nor blocks the next send.
            Self.log.info("MO status for message \(id), not this phone's send: \(status)")
            return
        }
        moFinalStatus = status
        if status == "mo_ack_received" {
            moStatus = .complete
        } else {
            moStatus = .failed
            errors.send("MO failed: \(status)")
        }
        moPayload = nil
        moPayloadB64 = nil
    }

    /// Back to idle after a send's outcome was taken.
    public func resetMoStatus() {
        moStatus = .idle
        moPayload = nil
        moPayloadB64 = nil
        moFinalStatus = ""
    }

    // MARK: MT (mobile terminated)

    private func handleMtNotification(_ json: [String: Any]) {
        mtTopicId = Self.optInt(json, "topic_id", 0)
        mtMessageId = Self.optInt(json, "message_id", 0)
        mtLengthMax = max(0, Self.optInt(json, "message_length_max", 0))
        mtBuffer = []
        mtReceived = 0
        Self.log.debug("MT incoming: id=\(mtMessageId) topic=\(mtTopicId) maxLen=\(mtLengthMax)")
    }

    private func handleMtSegment(_ json: [String: Any]) {
        guard let have = mtBuffer?.count else { return }
        let segStart = Self.optInt(json, "segment_start", 0)
        guard let decoded = Self.jsprSegmentBytes(Self.optString(json, "data", "")) else {
            Self.log.error("MT segment base64 decode failed")
            return
        }
        guard segStart >= 0, decoded.count <= mtLengthMax, segStart <= mtLengthMax - decoded.count else {
            Self.log.warning("MT segment out of bounds: start=\(segStart) len=\(decoded.count) buf=\(mtLengthMax)")
            return
        }
        let end = segStart + decoded.count
        if have < end { mtBuffer?.append(contentsOf: [UInt8](repeating: 0, count: end - have)) }
        mtBuffer?.replaceSubrange(segStart..<end, with: decoded)
        mtReceived += decoded.count
        Self.log.debug("MT segment: start=\(segStart) len=\(decoded.count)")
    }

    private func handleMtStatus(_ json: [String: Any]) async {
        let status = Self.optString(json, "final_mt_status", "")
        let buf = mtBuffer
        let received = mtReceived
        mtBuffer = nil
        mtReceived = 0
        guard status == "complete" else {
            Self.log.warning("MT failed: \(status)")
            errors.send("MT failed: \(status)")
            return
        }
        guard var bytes = buf, received >= 2 else { return }
        // Overlapping segments can add up past the announced length, where Android would throw.
        guard received <= mtLengthMax else {
            errors.send("MT failed: \(received) bytes received, \(mtLengthMax) announced")
            return
        }
        if bytes.count < received { bytes += [UInt8](repeating: 0, count: received - bytes.count) }
        // Verify and strip the CRC-16.
        let payload = Array(bytes[0..<(received - 2)])
        let expected = Int(bytes[received - 2]) << 8 | Int(bytes[received - 1])
        let actual = Self.crc16(payload)
        if actual == expected {
            Self.log.debug("MT complete: \(payload.count) bytes, CRC OK")
            await deliverMt(payload)
        } else {
            Self.log.warning("MT CRC mismatch: expected=\(String(expected, radix: 16)) actual=\(String(actual, radix: 16))")
            // Handed on anyway: the application layer can decide.
            await deliverMt(payload)
            errors.send("MT message CRC mismatch")
        }
    }

    private func deliverMt(_ payload: [UInt8]) async {
        guard let sink = mtSink else {
            Self.log.warning("MT message of \(payload.count) bytes and nowhere to store it")
            return
        }
        do {
            try await sink(payload)
        } catch {
            errors.send("Storing the message that came in failed: \(error)")
        }
    }

    // MARK: Signal / status

    /// The JSPR link is usable for commands: Connected, Initializing (the init uses it) or Ready.
    private var isWireReady: Bool { state == .connected || state == .initializing || state == .ready }

    /// Poll the signal strength, 0-5: the answer, or the last reading when the modem did not answer
    /// (which then stays as old as it is, MESHSAT-1670). Each answered read's round trip goes into
    /// `pollStats`.
    @discardableResult
    public func pollSignal() async -> Int {
        guard isWireReady else { return 0 }
        do {
            let startMs = clock.nowMs()
            let resp = try await sendJspr("GET", "constellationState", timeoutMs: Self.signalTimeoutMs)
            let answered = resp.flatMap { $0.json["signal_bars"] != nil ? Self.optInt($0.json, "signal_bars", 0) : nil }
            notePoll(answered == nil ? nil : clock.nowMs() - startMs)
            if let answered {
                recordReading(answered)
            } else {
                Self.log.debug("Signal: no answer in \(Self.signalTimeoutMs / 1000) s, keeping \(signal)/5")
            }
            return Self.signalAfterPoll(previous: signal, answeredBars: answered)
        } catch {
            errors.send("9704 signal poll failed: \(error)")
            return signal
        }
    }

    /// A reading the modem gave, by answer or by event (MESHSAT-1670).
    private func recordReading(_ bars: Int) {
        let b = min(max(bars, 0), 5)
        signal = b
        reading.send(SignalReading(bars: b, atMs: clock.nowMs()))
        signalReadings.send(b)
    }

    /// The SIM status as the modem's JSON text, nil when not answered.
    public func simStatus() async -> String? {
        guard isWireReady else { return nil }
        do {
            return try await sendJspr("GET", "simStatus")?.jsonText
        } catch {
            errors.send("9704 simStatus failed: \(error)")
            return nil
        }
    }
}

// MARK: Pure helpers with tests

extension Iridium9704Driver.State {
    /// The state as the Hub's birth reads it (Android's HubReporter.imtStatus): ready is the one
    /// state the modem sends and receives in, so it is "online"; disconnected is "offline", every
    /// state on the way up "binding". A ready modem read "offline" on Android until MESHSAT-1623.
    public var hubStatus: String {
        switch self {
        case .ready: "online"
        case .disconnected: "offline"
        default: "binding"
        }
    }
}

extension Iridium9704Driver {
    /// One JSPR segment's data field: standard base64, no line breaks.
    public static func jsprSegmentData(_ segment: [UInt8]) -> String { Base64Std.encode(segment) }

    /// A JSPR segment's data field back to its bytes, lenient as Java's MIME decoder and
    /// android.util.Base64.DEFAULT are: anything outside the alphabet (a line break) is skipped,
    /// padding may be left off. Nil where Java throws: a lone last character, or padding that does
    /// not close a unit. Written out, so Linux and Apple decode alike.
    public static func jsprSegmentBytes(_ data: String) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(data.utf8.count * 3 / 4)
        var bits: UInt32 = 0
        var pending = 0
        var it = data.utf8.makeIterator()
        var padded = false
        while let c = it.next() {
            if c == UInt8(ascii: "=") {
                padded = true
                break
            }
            guard let v = sextet(c) else { continue }
            bits = bits << 6 | UInt32(v)
            pending += 1
            if pending == 4 {
                out += [UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
                bits = 0
                pending = 0
            }
        }
        if padded {
            // "=" opening a unit is too much padding; after two characters a second "=" must follow.
            if pending == 0 { return nil }
            if pending == 2, it.next() != UInt8(ascii: "=") { return nil }
            // After the padding nothing of the alphabet may follow.
            while let c = it.next() {
                if sextet(c) != nil { return nil }
            }
        }
        switch pending {
        case 1: return nil
        case 2: out.append(UInt8(bits >> 4 & 0xFF))
        case 3: out += [UInt8(bits >> 10 & 0xFF), UInt8(bits >> 2 & 0xFF)]
        default: break
        }
        return out
    }

    private static func sextet(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x41...0x5A: c - 0x41
        case 0x61...0x7A: c - 0x61 + 26
        case 0x30...0x39: c - 0x30 + 52
        case 0x2B: 62
        case 0x2F: 63
        default: nil
        }
    }

    /// CRC-16/CCITT-FALSE as Android names it; with init 0 it is CRC-16/XMODEM ("123456789" is 0x31C3).
    public static func crc16(_ data: [UInt8]) -> Int {
        var crc = 0
        for b in data {
            let tableIndex = ((crc >> 8) ^ Int(b)) & 0xFF
            crc = ((crc << 8) ^ Int(crc16Table[tableIndex])) & 0xFFFF
        }
        return crc
    }

    private static let crc16Table: [UInt16] = (0..<256).map { i in
        var crc = i << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        return UInt16(crc & 0xFFFF)
    }

    /// A space after every colon and comma outside strings, as the official RockBLOCK-9704 C
    /// library writes its JSON: the modem's parser rejects compact JSON with 407 BAD_JSON.
    public static func spacedJson(_ json: String) -> String {
        if json == "{}" { return json }
        var out = String.UnicodeScalarView()
        var inString = false
        var previous: Unicode.Scalar?
        for ch in json.unicodeScalars {
            if ch == "\"", previous != "\\" { inString.toggle() }
            out.append(ch)
            if !inString, ch == ":" || ch == "," { out.append(" ") }
            previous = ch
        }
        return String(out)
    }

    /// org.json's optString: a string as it is, a number in its text, else the fallback.
    static func optString(_ json: [String: Any], _ key: String, _ fallback: String) -> String {
        switch json[key] {
        case let s as String: s
        case let i as Int: String(i)
        case let d as Double: String(d)
        default: fallback
        }
    }

    /// org.json's optInt: a number cut to an integer, a numeric string read as one, else the fallback.
    static func optInt(_ json: [String: Any], _ key: String, _ fallback: Int) -> Int {
        let number: Double
        switch json[key] {
        case let i as Int: return i
        case let d as Double: number = d
        case let s as String:
            guard let d = Double(s.trimmingCharacters(in: .whitespaces)) else { return fallback }
            number = d
        default: return fallback
        }
        guard number.isFinite else { return fallback }
        return Int(max(min(number, Double(Int32.max)), Double(Int32.min)))
    }
}

// MARK: The signal readings' bookkeeping (MESHSAT-1670), outside the actor's body for its length

extension Iridium9704Driver {
    private func notePoll(_ roundTripMs: Int64?) {
        if let roundTripMs {
            pollsAnswered += 1
            pollRoundTrips.append(roundTripMs)
            if pollRoundTrips.count > SignalPollStats.keep { pollRoundTrips.removeFirst(pollRoundTrips.count - SignalPollStats.keep) }
        } else {
            pollsMissed += 1
        }
        pollStats.send(SignalPollStats.of(pollRoundTrips, answered: pollsAnswered, missed: pollsMissed))
    }

    /// A new link starts with no reading and no round trips (MESHSAT-1670).
    private func forgetReadings() {
        reading.send(nil)
        pollRoundTrips.removeAll()
        pollsAnswered = 0
        pollsMissed = 0
        pollStats.send(SignalPollStats())
    }

    /// Fill the gaps between the modem's own constellationState events (MESHSAT-1670): ask when no
    /// reading came for SignalFreshness.pollIntervalMs, never while a send is under way.
    private func startSignalWatch(_ forLink: ModemLink) {
        signalWatchTask?.cancel()
        signalWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.signalWatchOnce(forLink) else { return }
            }
        }
    }

    /// One look at whether a reading is due; false once the watch should stop.
    private func signalWatchOnce(_ forLink: ModemLink) async -> Bool {
        await clock.sleep(ms: Self.signalCheckMs)
        guard polling, link === forLink else { return false }
        guard state == .ready, moStatus == .idle else { return true }
        let last = reading.value
        if last == nil || clock.nowMs() - (last?.atMs ?? 0) >= SignalFreshness.pollIntervalMs { await pollSignal() }
        return true
    }
}

/// One JSPR answer: its code, target and JSON object (empty when it carried none or not one).
struct JsprResponse {
    let code: Int
    let target: String
    let json: [String: Any]
    let jsonText: String
}

/// A JSPR request body in the order its fields are written, as Android's JSONObject keeps them.
struct JsprBody: Sendable {
    indirect enum Value: Sendable {
        case int(Int), double(Double), string(String), object(JsprBody)
    }

    let entries: [(String, Value)]

    init(_ entries: [(String, Value)]) { self.entries = entries }

    /// A parsed object written back, its keys sorted (the modem's version object is
    /// {major, minor, patch}, which sorts into the order the official library writes).
    init(_ json: [String: Any]) {
        entries = json.keys.sorted().compactMap { key -> (String, Value)? in
            switch json[key] {
            case let s as String: return (key, .string(s))
            case let i as Int: return (key, .int(i))
            case let d as Double: return (key, .double(d))
            case let o as [String: Any]: return (key, .object(JsprBody(o)))
            default: return nil
            }
        }
    }

    /// Compact JSON; spacedJson adds the spaces the modem wants.
    var text: String {
        "{" + entries.map { "\"" + Self.escape($0.0) + "\":" + Self.write($0.1) }.joined(separator: ",") + "}"
    }

    private static func write(_ value: Value) -> String {
        switch value {
        case .int(let i): String(i)
        case .double(let d): number(d)
        case .string(let s): "\"" + escape(s) + "\""
        case .object(let o): o.text
        }
    }

    /// A whole number without a fraction, as Android's JSONObject writes one.
    private static func number(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    let hex = String(ch.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }
}
