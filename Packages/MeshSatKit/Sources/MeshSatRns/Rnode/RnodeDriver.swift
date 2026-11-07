// Mirrors rnode/RnodeDriver.kt (MESHSAT-1553 P4, here MESHSAT-1735): one RNode
// (RNS/Interfaces/RNodeInterface.py, the Bridge's internal/rnode/driver.go). Detect the device,
// push frequency, bandwidth, TX power, spreading factor, coding rate and airtime limits, verify the
// radio reports them back, then exchange raw Reticulum packets as KISS data frames, with READY flow
// control. Kotlin's blocking waits are the clock's sleeps here, so tests run on a fast clock.
import Foundation
import MeshSatNet

/// The bytes to and from an RNode: a BLE Nordic UART on the phone, a pty or a fake in tests. Reads
/// arrive through `RnodeDriver.feed`.
public protocol RnodeLink: AnyObject, Sendable {
    /// Writes every byte or throws.
    func write(_ b: [UInt8]) throws
    func close()
}

public final class RnodeDriver: @unchecked Sendable {
    public enum Transport: Sendable { case serial, tcp, ble }

    public struct Options: Sendable {
        public var name: String
        public var transport: Transport
        public var params: RnodeProtocol.Params
        public var flowControl: Bool
        /// A callsign sent as a data frame every `idIntervalMs` of transmitting, for bands that require it.
        public var idCallsign: String
        public var idIntervalMs: Int64
        /// Every data frame from the radio.
        public var onPacket: (@Sendable ([UInt8]) -> Void)?
        /// The device reported a fatal error or reset; the owner closes and reopens.
        public var onError: (@Sendable (String) -> Void)?
        public var log: @Sendable (String) -> Void
        public var clock: any DriverClock

        public init(
            name: String = "rnode", transport: Transport = .ble, params: RnodeProtocol.Params, flowControl: Bool = true,
            idCallsign: String = "", idIntervalMs: Int64 = 0, onPacket: (@Sendable ([UInt8]) -> Void)? = nil,
            onError: (@Sendable (String) -> Void)? = nil, log: @escaping @Sendable (String) -> Void = { _ in },
            clock: any DriverClock = SystemDriverClock()
        ) {
            self.name = name
            self.transport = transport
            self.params = params
            self.flowControl = flowControl
            self.idCallsign = idCallsign
            self.idIntervalMs = idIntervalMs
            self.onPacket = onPacket
            self.onError = onError
            self.log = log
            self.clock = clock
        }
    }

    private let link: any RnodeLink
    private let opts: Options
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var stats = RnodeProtocol.Stats()
    private var isOnline = false
    private var ready = false
    private var queue: [[UInt8]] = []
    private var firstTxMs: Int64 = 0
    private var closed = false
    private var lastErrorText: String?
    private let splitter: Kiss.Splitter

    public init(link: any RnodeLink, options: Options) {
        self.link = link
        self.opts = options
        let timeout: Int64
        switch options.transport {
        case .ble: timeout = 1250
        case .tcp: timeout = 1500
        case .serial: timeout = 100
        }
        splitter = Kiss.Splitter(maxLen: RnodeProtocol.hwMtu + 1, timeoutMs: timeout)
    }

    public var online: Bool { locked { isOnline } }
    public var lastError: String? { locked { lastErrorText } }
    public func currentStats() -> RnodeProtocol.Stats { locked { stats } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func write(_ b: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try link.write(b)
    }

    /// Bytes from the link, any size, any boundary.
    public func feed(_ bytes: [UInt8]) {
        let now = opts.clock.nowMs()
        let frames = locked { splitter.feed(bytes, nowMs: now) }
        for f in frames { handleFrame(f) }
        housekeeping()
    }

    /// RNodeInterface's configure_device: settle, detect, initialise the radio, validate what it
    /// reports. Nil when the radio is up, else why not.
    public func open() async -> String? {
        if let bad = opts.params.validate() { return fail(bad) }
        await opts.clock.sleep(ms: 2000)
        do { try write(RnodeProtocol.detectBurst()) } catch { return fail("write failed: \(error)") }
        // Python waits 0.2 s flat on serial then checks; a slow stack (and BLE, TCP) gets up to 5 s.
        let detectWait: Int64 = opts.transport == .serial ? 2000 : 5000
        await waitUntil(ms: detectWait) { $0.detected }
        // The version, platform and MCU replies follow the detect reply in the same burst.
        await waitUntil(ms: 500) { $0.firmwareMajor != 0 }
        let s = currentStats()
        guard s.detected else { return fail("device not detected") }
        let req = (RnodeProtocol.requiredFwMajor, RnodeProtocol.requiredFwMinor)
        if s.firmwareMajor < req.0 || (s.firmwareMajor == req.0 && s.firmwareMinor < req.1) {
            return fail("firmware \(s.firmware) is older than \(req.0).\(req.1)")
        }
        do { try await initRadio() } catch { return fail("radio init write failed: \(error)") }
        let validateWait: Int64
        switch opts.transport {
        case .ble: validateWait = 1000
        case .tcp: validateWait = 1500
        case .serial: validateWait = 250
        }
        let deadline = opts.clock.nowMs() + validateWait
        var problem = validate()
        while problem != nil, opts.clock.nowMs() <= deadline {
            await opts.clock.sleep(ms: 10)
            problem = validate()
        }
        if let problem { return fail(problem) }
        locked {
            isOnline = true
            ready = true
        }
        let p = opts.params
        opts.log(
            "rnode \(opts.name): configured and powered up, \(p.frequency) Hz bw \(p.bandwidth) sf \(p.sf) cr \(p.cr) \(p.txPower) dBm, "
                + "\(RnodeProtocol.platformName(s.platform)) firmware \(s.firmware)")
        return nil
    }

    private func waitUntil(ms: Int64, _ done: (RnodeProtocol.Stats) -> Bool) async {
        let deadline = opts.clock.nowMs() + ms
        while !done(currentStats()), opts.clock.nowMs() < deadline { await opts.clock.sleep(ms: 10) }
    }

    private func fail(_ why: String) -> String {
        locked { lastErrorText = why }
        opts.log("rnode \(opts.name): \(why)")
        return why
    }

    private func initRadio() async throws {
        let p = opts.params
        var cmds = [
            RnodeProtocol.setFrequency(p.frequency), RnodeProtocol.setBandwidth(p.bandwidth), RnodeProtocol.setTxPower(p.txPower),
            RnodeProtocol.setSf(p.sf), RnodeProtocol.setCr(p.cr),
        ]
        if p.staLock > 0 { cmds.append(RnodeProtocol.setStaLock(p.staLock)) }
        if p.ltaLock > 0 { cmds.append(RnodeProtocol.setLtaLock(p.ltaLock)) }
        cmds.append(RnodeProtocol.setRadioState(true))
        for c in cmds { try write(c) }
        if opts.transport == .ble { await opts.clock.sleep(ms: 2000) }
    }

    private func validate() -> String? {
        let p = opts.params
        let s = currentStats()
        var problems: [String] = []
        if s.frequency != 0, abs(s.frequency - p.frequency) > 100 { problems.append("frequency \(s.frequency) != \(p.frequency)") }
        if s.bandwidth != p.bandwidth { problems.append("bandwidth \(s.bandwidth) != \(p.bandwidth)") }
        if s.txPower != p.txPower { problems.append("txpower \(s.txPower) != \(p.txPower)") }
        if s.sf != p.sf { problems.append("sf \(s.sf) != \(p.sf)") }
        if !s.radioOn { problems.append("radio state off") }
        return problems.isEmpty ? nil : "radio did not confirm the configuration: \(problems)"
    }

    /// Transmits one Reticulum packet (RNodeInterface.process_outgoing); nil when sent or queued, else why not.
    @discardableResult
    public func send(_ packet: [UInt8]) -> String? {
        if packet.count > RnodeProtocol.hwMtu {
            return "packet of \(packet.count) bytes exceeds the RNode MTU of \(RnodeProtocol.hwMtu)"
        }
        let now = opts.clock.nowMs()
        let verdict: String?? = locked {
            guard isOnline else { return .some("rnode not online") }
            if opts.flowControl, !ready {
                queue.append(packet)
                return .some(nil)
            }
            if opts.flowControl { ready = false }
            if firstTxMs == 0 { firstTxMs = now }
            stats.txPackets += 1
            stats.txBytes += Int64(packet.count)
            return .none
        }
        if let decided = verdict { return decided }
        do {
            try write(RnodeProtocol.dataFrame(packet))
            return nil
        } catch {
            return "write failed: \(error)"
        }
    }

    private func processQueue() {
        let next: [UInt8]? = locked {
            ready = true
            return queue.isEmpty ? nil : queue.removeFirst()
        }
        if let next { send(next) }
    }

    /// The callsign identification Python does between reads.
    private func housekeeping() {
        guard !opts.idCallsign.isEmpty, opts.idIntervalMs > 0 else { return }
        let now = opts.clock.nowMs()
        let due = locked {
            guard isOnline, firstTxMs != 0, now > firstTxMs + opts.idIntervalMs else { return false }
            firstTxMs = 0
            return true
        }
        if due { try? write(RnodeProtocol.dataFrame(Array(opts.idCallsign.utf8))) }
    }

    /// Turns the radio off, says goodbye and closes the link.
    public func close() {
        let first = locked {
            if closed { return false }
            closed = true
            isOnline = false
            return true
        }
        guard first else { return }
        try? write(RnodeProtocol.setRadioState(false))
        try? write(RnodeProtocol.leave())
        link.close()
    }

    /// The link dropped underneath us.
    public func linkLost(_ why: String) {
        let report = locked {
            let was = isOnline
            isOnline = false
            return was && !closed
        }
        if report { failure("link lost: \(why)") }
    }

    private func failure(_ why: String) {
        locked { lastErrorText = why }
        opts.log("rnode \(opts.name): \(why)")
        opts.onError?(why)
    }

    private func handleFrame(_ f: Kiss.Frame) {
        let p = f.payload
        if f.cmd == RnodeProtocol.cmdData {
            locked {
                stats.rxPackets += 1
                stats.rxBytes += Int64(p.count)
            }
            if !p.isEmpty { opts.onPacket?(p) }
            return
        }
        var err: String?
        var readyNow = false
        locked {
            if applyConfigReport(f.cmd, p) || applyStatReport(f.cmd, p) { return }
            (err, readyNow) = applyControl(f.cmd, p)
        }
        if readyNow { processQueue() }
        if let err { failure(err) }
    }

    // MARK: Frame handlers, called under the lock

    private static func be16(_ p: [UInt8], _ i: Int) -> Int { Int(p[i]) << 8 | Int(p[i + 1]) }
    private static func be32(_ p: [UInt8], _ i: Int) -> Int64 {
        Int64(p[i]) << 24 | Int64(p[i + 1]) << 16 | Int64(p[i + 2]) << 8 | Int64(p[i + 3])
    }

    /// The radio echoing its configuration and identity. True when the command was one of those.
    private func applyConfigReport(_ cmd: UInt8, _ p: [UInt8]) -> Bool {
        applyRadioParams(cmd, p) || applyIdentity(cmd, p)
    }

    private func applyRadioParams(_ cmd: UInt8, _ p: [UInt8]) -> Bool {
        switch cmd {
        case RnodeProtocol.cmdFrequency: if p.count >= 4 { stats.frequency = Self.be32(p, 0) }
        case RnodeProtocol.cmdBandwidth: if p.count >= 4 { stats.bandwidth = Self.be32(p, 0) }
        case RnodeProtocol.cmdTxPower: if let v = p.first { stats.txPower = Int(v) }
        case RnodeProtocol.cmdSf: if let v = p.first { stats.sf = Int(v) }
        case RnodeProtocol.cmdCr: if let v = p.first { stats.cr = Int(v) }
        case RnodeProtocol.cmdRadioState: if let v = p.first { stats.radioOn = v != 0 }
        case RnodeProtocol.cmdStALock: if p.count >= 2 { stats.staLock = Double(Self.be16(p, 0)) / 100 }
        case RnodeProtocol.cmdLtALock: if p.count >= 2 { stats.ltaLock = Double(Self.be16(p, 0)) / 100 }
        default: return false
        }
        return true
    }

    private func applyIdentity(_ cmd: UInt8, _ p: [UInt8]) -> Bool {
        switch cmd {
        case RnodeProtocol.cmdFwVersion:
            if p.count >= 2 {
                stats.firmwareMajor = Int(p[0])
                stats.firmwareMinor = Int(p[1])
            }
        case RnodeProtocol.cmdPlatform: if let v = p.first { stats.platform = v }
        case RnodeProtocol.cmdMcu: if let v = p.first { stats.mcu = v }
        case RnodeProtocol.cmdDetect: if p.first == RnodeProtocol.detectResp { stats.detected = true }
        default: return false
        }
        return true
    }

    /// The radio's measurements. True when the command was one of those.
    private func applyStatReport(_ cmd: UInt8, _ p: [UInt8]) -> Bool {
        switch cmd {
        case RnodeProtocol.cmdStatRssi: if let v = p.first { stats.rssi = Int(v) - RnodeProtocol.rssiOffset }
        case RnodeProtocol.cmdStatSnr:
            if let v = p.first {
                stats.snr = Double(Int8(bitPattern: v)) * 0.25
                let qMin = -9 - (Double(stats.sf) - 7) * 2.5
                stats.quality = min(100, max(0, (stats.snr - qMin) / (6 - qMin) * 100))
            }
        case RnodeProtocol.cmdStatChtm: if p.count >= 11 { applyChannelTime(p) }
        case RnodeProtocol.cmdStatPhyprm:
            if p.count >= 12 {
                stats.symbolTimeMs = Double(Self.be16(p, 0)) / 1000
                stats.symbolRate = Self.be16(p, 2)
                stats.preambleSymbols = Self.be16(p, 4)
                stats.preambleTimeMs = Self.be16(p, 6)
                stats.csmaSlotTimeMs = Self.be16(p, 8)
                stats.csmaDifsMs = Self.be16(p, 10)
            }
        case RnodeProtocol.cmdStatBat:
            if p.count >= 2 {
                stats.batteryState = Int(p[0])
                stats.batteryPercent = min(100, Int(p[1]))
            }
        case RnodeProtocol.cmdStatTemp:
            if let v = p.first {
                let t = Int(v) - 120
                stats.temperatureC = (-30...90).contains(t) ? t : nil
            }
        default: return false
        }
        return true
    }

    private func applyChannelTime(_ p: [UInt8]) {
        stats.airtimeShort = Double(Self.be16(p, 0)) / 100
        stats.airtimeLong = Double(Self.be16(p, 2)) / 100
        stats.channelLoadShort = Double(Self.be16(p, 4)) / 100
        stats.channelLoadLong = Double(Self.be16(p, 6)) / 100
        stats.currentRssi = Int(p[8]) - RnodeProtocol.rssiOffset
        stats.noiseFloor = Int(p[9]) - RnodeProtocol.rssiOffset
        stats.interference = p[10] == 0xFF ? nil : Int(p[10]) - RnodeProtocol.rssiOffset
    }

    /// Errors, resets and READY: what the owner or the queue must act on.
    private func applyControl(_ cmd: UInt8, _ p: [UInt8]) -> (error: String?, ready: Bool) {
        switch cmd {
        case RnodeProtocol.cmdError:
            guard let code = p.first else { return (nil, false) }
            switch code {
            case RnodeProtocol.errorInitRadio: return ("hardware error: radio initialisation failure", false)
            case RnodeProtocol.errorTxFailed: return ("hardware error: transmit failure", false)
            case RnodeProtocol.errorMemoryLow, RnodeProtocol.errorModemTimeout, RnodeProtocol.errorQueueFull:
                opts.log("rnode \(opts.name): device reports a non-fatal hardware error " + String(format: "0x%02x", code))
                return (nil, false)
            default: return ("hardware error: code " + String(format: "0x%02x", code), false)
            }
        case RnodeProtocol.cmdReset:
            if p.first == RnodeProtocol.resetMagic, isOnline, stats.platform == RnodeProtocol.platformEsp32 {
                isOnline = false
                return ("device reset while online", false)
            }
            return (nil, false)
        case RnodeProtocol.cmdReady:
            return (nil, opts.flowControl)
        default:
            return (nil, false)
        }
    }
}
