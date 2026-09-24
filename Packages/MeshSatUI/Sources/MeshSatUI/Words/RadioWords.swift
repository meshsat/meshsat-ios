// Mirrors the words of ui/screens/RadioConfigScreen.kt and ui/components/RegionCheck.kt: what a
// region, a preset, a channel role or a pairing mode is called, and the warning when the
// radio's region does not fit the country the phone is in.
import Foundation
import MeshSatMeshtastic

enum RadioWords {
    static func regionLabel(_ code: Int) -> String {
        if code == MeshtasticProtocol.LoRaRegion.unset.code { return "Not set" }
        return MeshtasticProtocol.LoRaRegion(rawValue: code)?.label ?? "Region code \(code)"
    }

    static func presetLabel(_ code: Int) -> String { MeshtasticProtocol.ModemPreset(rawValue: code)?.label ?? "Preset code \(code)" }

    /// Spreading factor, bandwidth and coding rate of each preset, as the firmware sets them.
    static func presetDetails(_ code: Int) -> String? {
        switch code {
        case 0: "spreading factor 11, bandwidth 250 kHz, coding rate 4/5"
        case 1: "spreading factor 12, bandwidth 125 kHz, coding rate 4/8"
        case 2: "spreading factor 12, bandwidth 62.5 kHz, coding rate 4/8"
        case 3: "spreading factor 10, bandwidth 250 kHz, coding rate 4/5"
        case 4: "spreading factor 9, bandwidth 250 kHz, coding rate 4/5"
        case 5: "spreading factor 8, bandwidth 250 kHz, coding rate 4/5"
        case 6: "spreading factor 7, bandwidth 250 kHz, coding rate 4/5"
        case 7: "spreading factor 11, bandwidth 125 kHz, coding rate 4/8"
        case 8: "spreading factor 7, bandwidth 500 kHz, coding rate 4/5"
        default: nil
        }
    }

    static func roleLabel(_ role: Int) -> String {
        switch role {
        case 1: "Main channel"
        case 2: "Extra channel"
        default: "Off"
        }
    }

    static func roleHint(_ role: Int) -> String {
        switch role {
        case 1: "Every node on this mesh shares it."
        case 2: "A group channel beside the main one."
        default: "Not in use."
        }
    }

    /// What the channel key means, in words, and a one-line hint.
    static func channelKey(_ psk: [UInt8], role: Int) -> (label: String, hint: String) {
        if psk.isEmpty, role == 2 { return ("Channel key: same as the main channel", "It is as private as the main channel.") }
        if psk.isEmpty || (psk.count == 1 && psk[0] == 0) { return ("Channel key: none (not encrypted)", "Anyone in range can read it.") }
        if psk.count == 1 { return ("Channel key: default (not private)", "Every Meshtastic radio knows this key, so anyone can read it.") }
        return ("Channel key: private", "Only nodes that have this key can read it.")
    }

    static func pairingLabel(_ mode: Int) -> String {
        switch mode {
        case 0: "PIN shown on the node's screen"
        case 1: "Fixed PIN"
        case 2: "No PIN"
        default: "Pairing mode \(mode)"
        }
    }
}

/// Mirrors ui/components/RegionCheck.kt: the region a radio in the phone's country normally uses.
enum RegionCheck {
    // EU and EEA members, and the European countries that use the same 868 MHz rules.
    static let europe: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT",
        "RO", "SK", "SI", "ES", "SE", "IS", "LI", "NO", "CH", "GB", "AD", "MC", "SM", "VA", "GI", "FO", "IM", "JE", "GG", "AL", "BA", "ME",
        "MK", "RS", "XK", "MD",
    ]

    /// The phone's country as an upper-case ISO code ("NL"), or nil when it cannot tell. iOS has
    /// no SIM country for an app; the region setting is what there is.
    static func phoneCountry() -> String? {
        guard let iso = Locale.current.region?.identifier.uppercased(), iso.count == 2 else { return nil }
        return iso
    }

    /// The regions radios in `iso` normally use, or nil when this app does not know.
    static func expectedRegions(_ iso: String) -> [MeshtasticProtocol.LoRaRegion]? {
        if europe.contains(iso) { return [.eu868, .eu433] }
        switch iso {
        case "US", "CA", "PR": return [.us]
        case "AU": return [.anz]
        case "NZ": return [.anz, .nz865]
        case "CN": return [.cn]
        case "JP": return [.jp]
        case "KR": return [.kr]
        case "TW": return [.tw]
        case "RU": return [.ru]
        case "IN": return [.india]
        case "TH": return [.th]
        case "UA": return [.ua868, .ua433]
        case "MY": return [.my919, .my433]
        case "SG": return [.sg923]
        default: return nil
        }
    }

    static func countryName(_ iso: String) -> String { Locale.current.localizedString(forRegionCode: iso) ?? iso }

    /// A warning about `regionCode` for the phone's country `iso`, or nil when it fits or cannot be judged.
    static func warning(_ regionCode: Int, _ iso: String?) -> String? {
        if regionCode == MeshtasticProtocol.LoRaRegion.lora24.code { return nil }  // 2.4 GHz is allowed worldwide
        if regionCode == MeshtasticProtocol.LoRaRegion.unset.code {
            return "No region is set, so the radio does not transmit. Pick the region you are in."
        }
        guard let country = iso, let expected = expectedRegions(country) else { return nil }
        if expected.contains(where: { $0.code == regionCode }) { return nil }
        let names = expected.map(\.label).joined(separator: " or ")
        return "Your phone is set to \(countryName(country)), where radios use \(names). Check the region matches where you are: "
            + "the wrong one can be illegal there, and you will not hear nearby nodes."
    }
}
