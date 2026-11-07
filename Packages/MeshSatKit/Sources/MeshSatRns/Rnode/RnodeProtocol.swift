// Mirrors rnode/RnodeProtocol.kt (MESHSAT-1553 P4, here MESHSAT-1735): the RNode host protocol
// (RNS/Interfaces/RNodeInterface.py, the Bridge's internal/rnode): KISS frames whose command byte
// configures and reads the LoRa radio, and CMD_DATA frames that carry raw Reticulum packets.
import Foundation

public enum RnodeProtocol {
    public static let cmdData: UInt8 = 0x00
    public static let cmdFrequency: UInt8 = 0x01
    public static let cmdBandwidth: UInt8 = 0x02
    public static let cmdTxPower: UInt8 = 0x03
    public static let cmdSf: UInt8 = 0x04
    public static let cmdCr: UInt8 = 0x05
    public static let cmdRadioState: UInt8 = 0x06
    public static let cmdRadioLock: UInt8 = 0x07
    public static let cmdDetect: UInt8 = 0x08
    public static let cmdLeave: UInt8 = 0x0A
    public static let cmdStALock: UInt8 = 0x0B
    public static let cmdLtALock: UInt8 = 0x0C
    public static let cmdReady: UInt8 = 0x0F
    public static let cmdStatRx: UInt8 = 0x21
    public static let cmdStatTx: UInt8 = 0x22
    public static let cmdStatRssi: UInt8 = 0x23
    public static let cmdStatSnr: UInt8 = 0x24
    public static let cmdStatChtm: UInt8 = 0x25
    public static let cmdStatPhyprm: UInt8 = 0x26
    public static let cmdStatBat: UInt8 = 0x27
    public static let cmdStatCsma: UInt8 = 0x28
    public static let cmdStatTemp: UInt8 = 0x29
    public static let cmdRandom: UInt8 = 0x40
    public static let cmdPlatform: UInt8 = 0x48
    public static let cmdMcu: UInt8 = 0x49
    public static let cmdFwVersion: UInt8 = 0x50
    public static let cmdReset: UInt8 = 0x55
    public static let cmdError: UInt8 = 0x90

    public static let detectReq: UInt8 = 0x73
    public static let detectResp: UInt8 = 0x46
    public static let radioStateOff: UInt8 = 0x00
    public static let radioStateOn: UInt8 = 0x01

    public static let errorInitRadio: UInt8 = 0x01
    public static let errorTxFailed: UInt8 = 0x02
    public static let errorEepromLocked: UInt8 = 0x03
    public static let errorQueueFull: UInt8 = 0x04
    public static let errorMemoryLow: UInt8 = 0x05
    public static let errorModemTimeout: UInt8 = 0x06

    public static let platformAvr: UInt8 = 0x90
    public static let platformEsp32: UInt8 = 0x80
    public static let platformNrf52: UInt8 = 0x70

    public static let resetMagic: UInt8 = 0xF8

    /// The largest data frame payload.
    public static let hwMtu = 508
    /// Converts a reported RSSI byte to dBm.
    public static let rssiOffset = 157
    public static let requiredFwMajor = 1
    public static let requiredFwMinor = 52
    public static let freqMin: Int64 = 137_000_000
    public static let freqMax: Int64 = 3_000_000_000

    /// The radio parameters an RNode is configured with.
    public struct Params: Sendable, Equatable {
        public var frequency: Int64  // Hz
        public var bandwidth: Int64  // Hz
        public var txPower: Int  // dBm
        public var sf: Int
        public var cr: Int
        public var staLock: Double  // airtime limit short, percent, 0 = not set
        public var ltaLock: Double  // airtime limit long, percent

        public init(frequency: Int64, bandwidth: Int64, txPower: Int, sf: Int, cr: Int, staLock: Double = 0, ltaLock: Double = 0) {
            self.frequency = frequency
            self.bandwidth = bandwidth
            self.txPower = txPower
            self.sf = sf
            self.cr = cr
            self.staLock = staLock
            self.ltaLock = ltaLock
        }

        /// The RNodeInterface range checks, or nil.
        public func validate() -> String? {
            if frequency < freqMin || frequency > freqMax { return "frequency \(frequency) Hz outside \(freqMin)..\(freqMax)" }
            if bandwidth < 7800 || bandwidth > 1_625_000 { return "bandwidth \(bandwidth) Hz outside 7800..1625000" }
            if txPower < 0 || txPower > 37 { return "tx power \(txPower) dBm outside 0..37" }
            if sf < 5 || sf > 12 { return "spreading factor \(sf) outside 5..12" }
            if cr < 5 || cr > 8 { return "coding rate \(cr) outside 5..8" }
            if staLock < 0 || staLock > 100 || ltaLock < 0 || ltaLock > 100 { return "airtime limits must be 0..100 percent" }
            return nil
        }

        /// The on-air bit rate (RNodeInterface.updateBitrate).
        public func bitrate() -> Double { RnodeProtocol.bitrate(sf: sf, cr: cr, bw: bandwidth) }
    }

    public static func bitrate(sf: Int, cr: Int, bw: Int64) -> Double {
        guard sf != 0, cr != 0, bw != 0 else { return 0 }
        let symbolsPerSecond = Double(bw) / 1000 / pow(2, Double(sf))
        return Double(sf) * (4.0 / Double(cr)) * symbolsPerSecond * 1000
    }

    private static func u32(_ v: Int64) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8),
            UInt8(truncatingIfNeeded: v),
        ]
    }

    private static func u16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }

    /// The detect, firmware, platform and MCU queries sent on open.
    public static func detectBurst() -> [UInt8] {
        [Kiss.fend, cmdDetect, detectReq, Kiss.fend, cmdFwVersion, 0x00, Kiss.fend, cmdPlatform, 0x00, Kiss.fend, cmdMcu, 0x00, Kiss.fend]
    }

    public static func leave() -> [UInt8] { [Kiss.fend, cmdLeave, 0xFF, Kiss.fend] }
    public static func hardReset() -> [UInt8] { [Kiss.fend, cmdReset, resetMagic, Kiss.fend] }
    public static func setFrequency(_ hz: Int64) -> [UInt8] { Kiss.encode(cmdFrequency, u32(hz)) }
    public static func setBandwidth(_ hz: Int64) -> [UInt8] { Kiss.encode(cmdBandwidth, u32(hz)) }
    public static func setTxPower(_ dbm: Int) -> [UInt8] { Kiss.encode(cmdTxPower, [UInt8(truncatingIfNeeded: dbm)]) }
    public static func setSf(_ sf: Int) -> [UInt8] { Kiss.encode(cmdSf, [UInt8(truncatingIfNeeded: sf)]) }
    public static func setCr(_ cr: Int) -> [UInt8] { Kiss.encode(cmdCr, [UInt8(truncatingIfNeeded: cr)]) }
    public static func setStaLock(_ pct: Double) -> [UInt8] { Kiss.encode(cmdStALock, u16(Int(pct * 100))) }
    public static func setLtaLock(_ pct: Double) -> [UInt8] { Kiss.encode(cmdLtALock, u16(Int(pct * 100))) }
    public static func setRadioState(_ on: Bool) -> [UInt8] { Kiss.encode(cmdRadioState, [on ? radioStateOn : radioStateOff]) }
    public static func dataFrame(_ packet: [UInt8]) -> [UInt8] { Kiss.encode(cmdData, packet) }

    public static func platformName(_ p: UInt8) -> String {
        switch p {
        case platformAvr: "avr"
        case platformEsp32: "esp32"
        case platformNrf52: "nrf52"
        default: String(format: "0x%02x", p)
        }
    }

    /// The values the radio reports.
    public struct Stats: Sendable, Equatable {
        public var frequency: Int64 = 0
        public var bandwidth: Int64 = 0
        public var txPower = 0
        public var sf = 0
        public var cr = 0
        public var radioOn = false
        public var rssi = 0
        public var snr = 0.0
        public var quality = 0.0
        public var airtimeShort = 0.0
        public var airtimeLong = 0.0
        public var channelLoadShort = 0.0
        public var channelLoadLong = 0.0
        public var currentRssi = 0
        public var noiseFloor = 0
        public var interference: Int?
        public var staLock = 0.0
        public var ltaLock = 0.0
        public var symbolTimeMs = 0.0
        public var symbolRate = 0
        public var preambleSymbols = 0
        public var preambleTimeMs = 0
        public var csmaSlotTimeMs = 0
        public var csmaDifsMs = 0
        public var batteryState = 0
        public var batteryPercent = 0
        public var temperatureC: Int?
        public var firmwareMajor = 0
        public var firmwareMinor = 0
        public var platform: UInt8 = 0
        public var mcu: UInt8 = 0
        public var detected = false
        public var rxPackets: Int64 = 0
        public var txPackets: Int64 = 0
        public var rxBytes: Int64 = 0
        public var txBytes: Int64 = 0

        public init() {}

        public var bitrateBps: Double { RnodeProtocol.bitrate(sf: sf, cr: cr, bw: bandwidth) }
        public var firmware: String { "\(firmwareMajor).\(firmwareMinor)" }
    }

    /// A regional starting point; the four CrossTalk ships (RNodePresets.js), so a kit and its radios
    /// start on identical parameters.
    public struct Preset: Sendable, Equatable {
        public let id: String
        public let label: String
        public let description: String
        public let params: Params
    }

    public static let presets: [Preset] = [
        Preset(
            id: "us-915", label: "US 915 MHz (starter)",
            description: "Common US ISM starting point around 915 MHz. Match your mesh if it uses a different center frequency.",
            params: Params(frequency: 915_000_000, bandwidth: 125_000, txPower: 22, sf: 7, cr: 5)),
        Preset(
            id: "eu-868", label: "EU 868 MHz (starter)",
            description: "Common EU ISM starting point at 867.2 MHz from Reticulum examples. Confirm local rules and mesh settings.",
            params: Params(frequency: 867_200_000, bandwidth: 125_000, txPower: 14, sf: 8, cr: 5)),
        Preset(
            id: "au-915", label: "AU/NZ 915 MHz (starter)",
            description: "Common starting point in the AU/NZ 915 MHz ISM band. Confirm local rules and mesh settings.",
            params: Params(frequency: 915_000_000, bandwidth: 125_000, txPower: 22, sf: 7, cr: 5)),
        Preset(
            id: "ism-433", label: "433 MHz (starter)",
            description: "For 433 MHz-capable RNodes where that band is allowed. Not all Heltec boards support this.",
            params: Params(frequency: 433_000_000, bandwidth: 125_000, txPower: 12, sf: 7, cr: 5)),
    ]

    public static func preset(_ id: String) -> Preset? { presets.first { $0.id == id } }
}
