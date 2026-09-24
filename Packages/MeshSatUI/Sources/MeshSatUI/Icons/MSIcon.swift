// The icons the app draws. Android uses Material Icons (outlined, filled when selected) plus
// two custom vectors (ic_transport_satellite, ic_transport_mesh). The Material set is imported
// as template SVG assets by scripts/import-material-icons.sh (MESHSAT-1321); until that
// import lands, each entry falls back to the nearest SF Symbol so the scaffold builds. The
// fallback is a stopgap, not the design: parity requires the Material glyphs.
import SwiftUI

public enum MSIcon {
    static func asset(_ name: String, fallback: String) -> Image {
        #if canImport(UIKit)
        if UIImage(named: name, in: .module, with: nil) != nil {
            return Image(name, bundle: .module).renderingMode(.template)
        }
        #endif
        return Image(systemName: fallback)
    }

    public static var transportSatellite: Image { asset("transport_satellite", fallback: "antenna.radiowaves.left.and.right") }
    public static var transportMesh: Image { asset("transport_mesh", fallback: "point.3.connected.trianglepath.dotted") }
    public static var sms: Image { asset("outlined_sms", fallback: "message") }
    public static var cloud: Image { asset("outlined_cloud", fallback: "cloud") }
    public static var myLocation: Image { asset("outlined_my_location", fallback: "location.circle") }
    public static var bluetooth: Image { asset("outlined_bluetooth", fallback: "dot.radiowaves.left.and.right") }
    public static var healthAndSafety: Image { asset("outlined_health_and_safety", fallback: "cross.case") }
    public static var lock: Image { asset("outlined_lock", fallback: "lock") }
    public static var map: Image { asset("outlined_map", fallback: "map") }
    public static var radio: Image { asset("outlined_radio", fallback: "radio") }
    public static var tune: Image { asset("outlined_tune", fallback: "slider.horizontal.3") }
    public static var build: Image { asset("outlined_build", fallback: "wrench") }
    public static var info: Image { asset("outlined_info", fallback: "info.circle") }
    public static var schedule: Image { asset("outlined_schedule", fallback: "clock") }
    public static var fence: Image { asset("outlined_fence", fallback: "square.grid.3x3") }
    public static var nightsStay: Image { asset("outlined_nights_stay", fallback: "moon") }
    public static var swapVert: Image { asset("outlined_swap_vert", fallback: "arrow.up.arrow.down") }

    public static func tab(_ tab: Tab, filled: Bool) -> Image {
        switch tab {
        case .home: asset(filled ? "filled_home" : "outlined_home", fallback: filled ? "house.fill" : "house")
        case .messages: asset(filled ? "filled_chat_bubble" : "outlined_chat_bubble_outline", fallback: filled ? "bubble.fill" : "bubble")
        case .map: asset(filled ? "filled_map" : "outlined_map", fallback: filled ? "map.fill" : "map")
        case .people: asset(filled ? "filled_group" : "outlined_group", fallback: filled ? "person.2.fill" : "person.2")
        case .setup: asset(filled ? "filled_tune" : "outlined_tune", fallback: "slider.horizontal.3")
        }
    }
}
