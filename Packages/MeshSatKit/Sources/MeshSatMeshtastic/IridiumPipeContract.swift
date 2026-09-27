// Mirrors ble/IridiumBlePipe.kt's IridiumPipeContract: the node's serial pipe from Bluetooth
// to the RockBLOCK 9603 (meshsat-esp32 docs/IRIDIUM-BLE.md owns this contract; changes go
// through that repo). The pipe runs on the same GATT connection as the Meshtastic service.
//
// Version 2 (MESHSAT-1378) adds STATS (the node's satellite health, read + notify) and PASS
// (pass windows the phone writes, so the node's own routing can time its sessions), and lets
// STATUS carry a flags byte and the signal after the owner. A client reads only what is there:
// STATUS of 2 or 4 bytes, STATS of 52 or more.

public enum IridiumPipeContract {
    public static let serviceUUID = "b3d305a2-7310-4877-ad12-8e245e71951a"
    /// Phone to modem, write.
    public static let rxUUID = "b9e2d4ba-f386-4728-b77a-7df7121db7a9"
    /// Modem to phone, notify. Subscribing to TX is what claims the modem.
    public static let txUUID = "469354dc-4c89-41ed-b939-d707c7a11f49"
    /// [version, owner] or, from version 2, [version, owner, flags, csq]. Read after
    /// subscribing, and notified on change.
    public static let statusUUID = "69a4064d-78b9-46e5-a30a-1862e553245a"
    /// The node's satellite health, 52 bytes little-endian, read + notify (on change, at most
    /// every 2 s). Independent of who owns the modem.
    public static let statsUUID = "9c22cf07-2256-4fc2-b6ee-ab0ceb12198d"
    /// Pass windows from the phone, write with response; a write replaces the node's list.
    /// Accepted from any client on the service, whoever owns the modem.
    public static let passUUID = "5c1000e8-f411-4f3d-a4c9-5ee0610a8e66"

    /// The node buffers this much inbound data; writes are paced against it.
    public static let nodeInboundBytes = 1024
    /// Chunks smaller than this are never sent (the node's pipe reads at least 20 bytes).
    public static let minChunkBytes = 20
    /// What this app writes when it has to name a version: the first contract.
    public static let statusVersion: UInt8 = 1
    public static let statusVersion2: UInt8 = 2
    public static let statsVersion: UInt8 = 2
    public static let statsLength = 52
    public static let passListVersion: UInt8 = 1
    public static let passListMax = 8
    /// "Unknown" for the signal byte and the u32 ages.
    public static let unknownByte: UInt8 = 0xFF
    public static let unknownU32: UInt32 = 0xFFFF_FFFF

    public enum Owner: UInt8, Sendable, Equatable {
        case none = 0
        case phone = 1
        case node = 2
    }

    /// The flags byte of STATUS v2 and STATS.
    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// A satellite session is in flight.
        public static let sessionInFlight = Flags(rawValue: 1 << 0)
        /// A message waits at the gateway.
        public static let messageWaiting = Flags(rawValue: 1 << 1)
        /// The modem answers AT.
        public static let modemAnswers = Flags(rawValue: 1 << 2)
        /// The node's inbound buffer is nearly full.
        public static let inboundCongested = Flags(rawValue: 1 << 3)
    }

    public struct Status: Sendable, Equatable {
        public let version: UInt8
        public let owner: Owner
        /// Nil on a version 1 STATUS (two bytes).
        public let flags: Flags?
        /// 0 to 5; nil on a version 1 STATUS or when the node never read it (0xFF).
        public let csq: Int?
        public init(version: UInt8, owner: Owner, flags: Flags? = nil, csq: Int? = nil) {
            self.version = version
            self.owner = owner
            self.flags = flags
            self.csq = csq
        }
    }

    /// nil for an empty value, an unknown version or an unknown owner byte, as Android's
    /// parseStatus. Version 1 is `[01][owner]`; version 2 is `[02][owner][flags][csq]` and is
    /// read as far as it goes, so a two-byte version 2 still names its owner.
    public static func parseStatus(_ bytes: [UInt8]) -> Status? {
        guard bytes.count >= 2, bytes[0] == statusVersion || bytes[0] == statusVersion2, let owner = Owner(rawValue: bytes[1]) else {
            return nil
        }
        guard bytes[0] == statusVersion2, bytes.count >= 4 else { return Status(version: bytes[0], owner: owner) }
        return Status(version: bytes[0], owner: owner, flags: Flags(rawValue: bytes[2]), csq: signalBars(bytes[3]))
    }

    /// The signal byte as bars, nil when the node never read it.
    static func signalBars(_ byte: UInt8) -> Int? {
        byte == unknownByte ? nil : Int(byte)
    }

    // MARK: STATS

    /// The node's satellite health, as STATS carries it (IRIDIUM-BLE.md, "Version 2 additions").
    public struct Stats: Sendable, Equatable {
        public let version: UInt8
        public let owner: Owner?
        public let flags: Flags
        /// 0 to 5 as the modem last reported it, nil when never read.
        public let csq: Int?
        /// Age of that reading in seconds, nil when never read.
        public let csqAgeS: UInt32?
        /// Satellite sessions since boot, by any owner.
        public let sessions: UInt32
        /// MO status of the last session, -1 before the first.
        public let lastMoStatus: Int
        public let lastMomsn: Int
        /// MT status of the last session, -1 before the first.
        public let lastMtStatus: Int
        /// Messages still queued at the gateway after the last session.
        public let lastMtQueued: Int
        /// Age of the last session in seconds, nil before the first.
        public let lastSessionAgeS: UInt32?
        public let uptimeS: UInt32
        /// Reboots by the node's Bluetooth watchdog, lifetime.
        public let watchdogReboots: UInt32
        /// Bytes a client wrote faster than the modem took them, since boot.
        public let phoneBytesDropped: UInt32
        /// Sessions opened by the node's own routing since boot, and what they carried.
        public let nodeSessions: UInt32
        public let nodeSent: UInt32
        public let nodeReceived: UInt32
        /// The node's own sessions today, and its daily cap.
        public let daySessionsUsed: Int
        public let daySessionsCap: Int

        public init(
            version: UInt8, owner: Owner?, flags: Flags, csq: Int?, csqAgeS: UInt32?, sessions: UInt32, lastMoStatus: Int,
            lastMomsn: Int, lastMtStatus: Int, lastMtQueued: Int, lastSessionAgeS: UInt32?, uptimeS: UInt32,
            watchdogReboots: UInt32, phoneBytesDropped: UInt32, nodeSessions: UInt32, nodeSent: UInt32, nodeReceived: UInt32,
            daySessionsUsed: Int, daySessionsCap: Int
        ) {
            self.version = version
            self.owner = owner
            self.flags = flags
            self.csq = csq
            self.csqAgeS = csqAgeS
            self.sessions = sessions
            self.lastMoStatus = lastMoStatus
            self.lastMomsn = lastMomsn
            self.lastMtStatus = lastMtStatus
            self.lastMtQueued = lastMtQueued
            self.lastSessionAgeS = lastSessionAgeS
            self.uptimeS = uptimeS
            self.watchdogReboots = watchdogReboots
            self.phoneBytesDropped = phoneBytesDropped
            self.nodeSessions = nodeSessions
            self.nodeSent = nodeSent
            self.nodeReceived = nodeReceived
            self.daySessionsUsed = daySessionsUsed
            self.daySessionsCap = daySessionsCap
        }
    }

    /// nil when shorter than 52 bytes or not version 2. Read by offset; extra bytes are ignored.
    public static func parseStats(_ b: [UInt8]) -> Stats? {
        guard b.count >= statsLength, b[0] == statsVersion else { return nil }
        let csqAge = u32(b, 4)
        let sessionAge = u32(b, 20)
        return Stats(
            version: b[0], owner: Owner(rawValue: b[1]), flags: Flags(rawValue: b[2]), csq: signalBars(b[3]),
            csqAgeS: csqAge == unknownU32 ? nil : csqAge, sessions: u32(b, 8), lastMoStatus: i16(b, 12), lastMomsn: u16(b, 14),
            lastMtStatus: i16(b, 16), lastMtQueued: u16(b, 18), lastSessionAgeS: sessionAge == unknownU32 ? nil : sessionAge,
            uptimeS: u32(b, 24), watchdogReboots: u32(b, 28), phoneBytesDropped: u32(b, 32), nodeSessions: u32(b, 36),
            nodeSent: u32(b, 40), nodeReceived: u32(b, 44), daySessionsUsed: Int(b[48]), daySessionsCap: Int(b[49]))
    }

    static func u16(_ b: [UInt8], _ at: Int) -> Int {
        Int(b[at]) | Int(b[at + 1]) << 8
    }

    static func i16(_ b: [UInt8], _ at: Int) -> Int {
        Int(Int16(bitPattern: UInt16(b[at]) | UInt16(b[at + 1]) << 8))
    }

    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    // MARK: PASS

    /// One pass window as the node takes it: when it starts, how long it lasts, how high it gets.
    public struct PassWindow: Sendable, Equatable {
        public let startEpochS: UInt32
        public let durationS: UInt16
        public let maxElevationDeg: UInt8
        public init(startEpochS: UInt32, durationS: UInt16, maxElevationDeg: UInt8) {
            self.startEpochS = startEpochS
            self.durationS = durationS
            self.maxElevationDeg = maxElevationDeg
        }
    }

    /// `[01][n][n x (u32 start, u16 duration, u8 elevation)]`, little-endian, at most eight
    /// windows (the first eight given, so pass them soonest first).
    public static func encodePassList(_ windows: [PassWindow]) -> [UInt8] {
        let kept = windows.prefix(passListMax)
        var out: [UInt8] = [passListVersion, UInt8(kept.count)]
        out.reserveCapacity(2 + kept.count * 7)
        for w in kept {
            out += le32(w.startEpochS)
            out += [UInt8(w.durationS & 0xFF), UInt8(w.durationS >> 8)]
            out.append(w.maxElevationDeg)
        }
        return out
    }

    static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
