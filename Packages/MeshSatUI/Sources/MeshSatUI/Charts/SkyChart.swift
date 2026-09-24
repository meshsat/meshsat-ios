// Mirrors ui/components/SkyChart.kt (MESHSAT-1300): predicted passes with the modem's real signal
// and its satellite sessions on one time axis, the Bridge's "Signal vs passes" chart. A pass is a
// triangle from AOS to LOS whose apex is its peak elevation on a 0 to 90 degree scale, signal
// readings sit on a 0 to 5 bar scale over the same time axis, and sessions are dots on the
// baseline. `compact` is the Home widget; the full size is the passes screen, with both scales
// and tap to inspect. SkyGeometry is pure and has the same tests as Android's.
import MeshSatSatellite
import SwiftUI

/// One Iridium signal reading, 0 to 5 bars, at a unix second.
public struct SkySignal: Sendable, Equatable {
    public let atSec: Int64
    public let bars: Int
    public init(atSec: Int64, bars: Int) {
        self.atSec = atSec
        self.bars = bars
    }
}

/// One satellite session (SBDIX) and whether the gateway took it: the Bridge's "GSS" dots.
public struct SkySession: Sendable, Equatable {
    public let atSec: Int64
    public let ok: Bool
    public init(atSec: Int64, ok: Bool) {
        self.atSec = atSec
        self.ok = ok
    }
}

public enum SkyGeometry {
    public static func x(_ tsSec: Int64, _ startSec: Int64, _ endSec: Int64, left: CGFloat, width: CGFloat) -> CGFloat {
        left + CGFloat(Double(tsSec - startSec) / Double(endSec - startSec)) * width
    }

    public static func elevY(_ deg: Double, bottom: CGFloat, height: CGFloat) -> CGFloat { bottom - CGFloat(deg / 90) * height }
    public static func barsY(_ bars: Double, bottom: CGFloat, height: CGFloat) -> CGFloat {
        bottom - CGFloat(min(5, max(0, bars)) / 5) * height
    }

    /// Readings averaged into steps of `stepSec`, one point per step (at its middle). A reading a
    /// minute over twelve hours is 720 points in a few hundred pixels; averaged, the line reads.
    public static func averaged(_ signals: [SkySignal], stepSec: Int64) -> [(atSec: Int64, bars: Double)] {
        if stepSec <= 60 { return signals.sorted { $0.atSec < $1.atSec }.map { ($0.atSec, Double($0.bars)) } }
        var buckets: [Int64: [Int]] = [:]
        for s in signals { buckets[s.atSec / stepSec, default: []].append(s.bars) }
        return buckets.keys.sorted().map { b in (b * stepSec + stepSec / 2, Double(buckets[b]!.reduce(0, +)) / Double(buckets[b]!.count)) }
    }

    /// The step that leaves about `minGapPx` between points across `widthPx`, never under a minute.
    public static func stepFor(spanSec: Int64, widthPx: CGFloat, minGapPx: CGFloat) -> Int64 {
        let points = max(1, widthPx / minGapPx)
        return max(60, Int64(Double(spanSec) / Double(points)))
    }

    public struct Triangle: Equatable {
        public let x1: CGFloat
        public let xMid: CGFloat
        public let x2: CGFloat
        public let peakY: CGFloat
    }

    // AOS and LOS on the baseline, clipped to the plot's sides, the apex half way between them at
    // the peak elevation. The Bridge clips first and then finds the middle, and so does this.
    // Seven parameters as on Android, so the tests read the same.
    // swiftlint:disable:next function_parameter_count
    public static func triangle(
        _ p: PassPrediction, _ startSec: Int64, _ endSec: Int64, left: CGFloat, width: CGFloat, bottom: CGFloat, height: CGFloat
    ) -> Triangle {
        let x1 = max(left, x(Int64(p.aos.value), startSec, endSec, left: left, width: width))
        let x2 = min(left + width, x(Int64(p.los.value), startSec, endSec, left: left, width: width))
        return Triangle(x1: x1, xMid: (x1 + x2) / 2, x2: x2, peakY: elevY(p.peakElevDeg, bottom: bottom, height: height))
    }

    /// Green from 3 bars, amber at 1 and 2, red at 0: the Bridge's thresholds (Android's signalArgb).
    public static func signalRgb(_ bars: Int) -> UInt32 {
        if bars >= 3 { return 0x10B981 }
        if bars >= 1 { return 0xF59E0B }
        return 0xEF4444
    }

    public static func signalColor(_ bars: Double) -> Color { Color(hex: signalRgb(Int(bars.rounded()))) }

    /// Label times on whole multiples of `stepSec` inside the window.
    public static func ticks(_ startSec: Int64, _ endSec: Int64, stepSec: Int64) -> [Int64] {
        var out: [Int64] = []
        var t = Int64((Double(startSec) / Double(stepSec)).rounded(.up)) * stepSec
        while t < endSec {
            out.append(t)
            t += stepSec
        }
        return out
    }

    public static func overlaps(_ p: PassPrediction, _ startSec: Int64, _ endSec: Int64) -> Bool {
        Int64(p.los.value) > startSec && Int64(p.aos.value) < endSec
    }
}

public struct SkyChart: View {
    let passes: [PassPrediction]
    let signals: [SkySignal]
    let sessions: [SkySession]
    let startSec: Int64
    let endSec: Int64
    let nowSec: Int64
    let compact: Bool
    let windowLabel: String?
    @State private var tapX: CGFloat?

    private static let indigo = Color(hex: 0x818CF8)
    private static let indigoActive = Color(hex: 0xA5B4FC)
    private static let signalGreen = Color(hex: 0x10B981)
    private static let nowAmber = Color(hex: 0xF59E0B)
    private static let sessionOk = Color(hex: 0xE879F9)
    private static let sessionFail = Color(hex: 0xF87171)
    private static let grid = Color(hex: 0x374151)

    public init(
        passes: [PassPrediction], signals: [SkySignal], sessions: [SkySession], startSec: Int64, endSec: Int64, nowSec: Int64,
        compact: Bool,
        windowLabel: String? = nil
    ) {
        self.passes = passes
        self.signals = signals
        self.sessions = sessions
        self.startSec = startSec
        self.endSec = endSec
        self.nowSec = nowSec
        self.compact = compact
        self.windowLabel = windowLabel
    }

    static func hhmm(_ sec: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date(timeIntervalSince1970: Double(sec)))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, size in draw(ctx, size) }
                .frame(height: compact ? 104 : 220)
                .contentShape(Rectangle())
                .onTapGesture { p in if !compact { tapX = tapX == nil ? p.x : nil } }
            let legendMuted = Color(hex: 0x6B7280)
            HStack(spacing: 10) {
                legend("\u{25B2}", Self.indigo.opacity(0.7), "Pass", legendMuted)
                legend("\u{25CF}", Self.signalGreen, "Signal", legendMuted)
                legend("\u{25CF}", Self.sessionOk, compact ? "Session" : "Session sent", legendMuted)
                if !compact { legend("\u{25CF}", Self.sessionFail, "Session failed", legendMuted) }
                if let windowLabel { Text(windowLabel).msText(.labelSmall, color: legendMuted) }
            }
            .padding(.horizontal, 4)
        }
    }

    private func legend(_ mark: String, _ color: Color, _ label: String, _ muted: Color) -> some View {
        HStack(spacing: 0) {
            Text(mark).msText(.labelSmall, color: color)
            Text(" \(label)").msText(.labelSmall, color: muted)
        }
    }

    // swiftlint:disable:next function_body_length
    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width
        let h = size.height
        let padL: CGFloat = compact ? 6 : 22
        let padR: CGFloat = compact ? 6 : 24
        let plotTop: CGFloat = compact ? 6 : 14
        let plotBottom = h - (compact ? 14 : 22)
        let plotW = w - padL - padR
        let plotH = plotBottom - plotTop
        func xOf(_ ts: Int64) -> CGFloat { SkyGeometry.x(ts, startSec, endSec, left: padL, width: plotW) }
        let labelFont = MSFont.sans(compact ? 8 : 9)
        let labelColor = Color(hex: compact ? 0x4B5563 : 0x6B7280)
        // Grid at the bar positions
        for v in (compact ? 1 : 0)...5 {
            let y = SkyGeometry.barsY(Double(v), bottom: plotBottom, height: plotH)
            var line = Path()
            line.move(to: CGPoint(x: padL, y: y))
            line.addLine(to: CGPoint(x: w - padR, y: y))
            ctx.stroke(line, with: .color(Self.grid), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        }
        if !compact {
            for v in 0...5 {
                ctx.draw(
                    Text("\(v)").font(labelFont).foregroundColor(labelColor),
                    at: CGPoint(x: padL - 5, y: SkyGeometry.barsY(Double(v), bottom: plotBottom, height: plotH)), anchor: .trailing)
            }
            ctx.draw(
                Text("bars").font(labelFont).foregroundColor(labelColor), at: CGPoint(x: padL - 5, y: plotTop - 4), anchor: .bottomTrailing)
            let degColor = Self.indigo.opacity(0.5)
            for d in [0, 15, 30, 45, 60, 75, 90] {
                ctx.draw(
                    Text("\(d)").font(labelFont).foregroundColor(degColor),
                    at: CGPoint(x: w - padR + 5, y: SkyGeometry.elevY(Double(d), bottom: plotBottom, height: plotH)), anchor: .leading)
            }
            ctx.draw(
                Text("deg").font(labelFont).foregroundColor(degColor), at: CGPoint(x: w - padR + 5, y: plotTop - 4), anchor: .bottomLeading)
        }
        var plot = ctx
        plot.clip(to: Path(CGRect(x: padL, y: plotTop, width: plotW, height: plotH)))
        let visible = passes.filter { SkyGeometry.overlaps($0, startSec, endSec) }
        // Pass triangles, the background layer
        for p in visible {
            let t = SkyGeometry.triangle(p, startSec, endSec, left: padL, width: plotW, bottom: plotBottom, height: plotH)
            var path = Path()
            path.move(to: CGPoint(x: t.x1, y: plotBottom))
            path.addLine(to: CGPoint(x: t.xMid, y: t.peakY))
            path.addLine(to: CGPoint(x: t.x2, y: plotBottom))
            path.closeSubpath()
            let base = p.isActive ? Self.indigoActive : Self.indigo
            if compact {
                plot.fill(path, with: .color(base.opacity(p.isActive ? 0.35 : 0.15)))
            } else {
                plot.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [base.opacity(p.isActive ? 0.50 : 0.30), base.opacity(p.isActive ? 0.08 : 0.03)]),
                        startPoint: CGPoint(x: t.xMid, y: t.peakY), endPoint: CGPoint(x: t.xMid, y: plotBottom)))
            }
            plot.stroke(path, with: .color(base.opacity(p.isActive ? 0.5 : 0.2)), lineWidth: compact ? 0.5 : 1)
            if t.x2 - t.x1 > (compact ? 15 : 20) {
                plot.draw(
                    Text("\(Int(p.peakElevDeg))").font(MSFont.sans(compact ? 7 : 8)).foregroundColor(Self.indigoActive.opacity(0.6)),
                    at: CGPoint(x: t.xMid, y: t.peakY - 3), anchor: .bottom)
            }
        }
        // Signal: soft area, the line, then a dot per reading coloured by strength
        let step = SkyGeometry.stepFor(spanSec: endSec - startSec, widthPx: plotW, minGapPx: 3)
        let pts = SkyGeometry.averaged(signals.filter { $0.atSec >= startSec && $0.atSec <= endSec }, stepSec: step)
            .map { (CGPoint(x: xOf($0.atSec), y: SkyGeometry.barsY($0.bars, bottom: plotBottom, height: plotH)), $0.bars) }
        if pts.count > 1 {
            var area = Path()
            area.move(to: CGPoint(x: pts[0].0.x, y: plotBottom))
            for (o, _) in pts { area.addLine(to: o) }
            area.addLine(to: CGPoint(x: pts[pts.count - 1].0.x, y: plotBottom))
            area.closeSubpath()
            if compact {
                plot.fill(area, with: .color(Self.signalGreen.opacity(0.08)))
            } else {
                plot.fill(
                    area,
                    with: .linearGradient(
                        Gradient(colors: [Self.signalGreen.opacity(0.15), Self.signalGreen.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: plotTop),
                        endPoint: CGPoint(x: 0, y: plotBottom)))
            }
            var line = Path()
            line.move(to: pts[0].0)
            for (o, _) in pts.dropFirst() { line.addLine(to: o) }
            plot.stroke(line, with: .color(Self.signalGreen.opacity(0.7)), lineWidth: compact ? 1.2 : 1.5)
        }
        for (o, bars) in pts {
            let r: CGFloat = compact ? 1.4 : 1.8
            plot.fill(
                Path(ellipseIn: CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r)),
                with: .color(SkyGeometry.signalColor(bars).opacity(0.85)))
        }
        // Satellite sessions on the baseline
        for s in sessions where s.atSec >= startSec && s.atSec <= endSec {
            let r: CGFloat = compact ? 2 : 3
            let c = CGPoint(x: xOf(s.atSec), y: plotBottom - (compact ? 4 : 6))
            plot.fill(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                with: .color(s.ok ? Self.sessionOk.opacity(0.9) : Self.sessionFail.opacity(0.7)))
        }
        // Now
        let nowX = xOf(nowSec)
        var nowLine = Path()
        nowLine.move(to: CGPoint(x: nowX, y: plotTop))
        nowLine.addLine(to: CGPoint(x: nowX, y: plotBottom))
        plot.stroke(
            nowLine, with: .color(Self.nowAmber.opacity(compact ? 0.5 : 0.6)),
            style: StrokeStyle(lineWidth: compact ? 0.5 : 1, dash: [3, 2]))
        // Time labels: every hour on the widget, every 3 h (6 h past a day) on the screen
        let span = endSec - startSec
        let labelStep: Int64 = (compact || span <= 6 * 3600) ? 3600 : (span <= 24 * 3600 ? 3 * 3600 : 6 * 3600)
        for t in SkyGeometry.ticks(startSec, endSec, stepSec: labelStep) {
            let x = xOf(t)
            // Room for "now" (about 30 pt): "now" and "12:00" would read as one label
            if !compact, abs(x - nowX) < 30 { continue }
            ctx.draw(Text(Self.hhmm(t)).font(labelFont).foregroundColor(labelColor), at: CGPoint(x: x, y: h - 3), anchor: .bottom)
        }
        if !compact {
            ctx.draw(Text("now").font(labelFont).foregroundColor(Self.nowAmber), at: CGPoint(x: nowX, y: h - 3), anchor: .bottom)
        }
        // Tap to inspect (the Bridge's hover): the time, the highest pass there, the nearest reading
        if !compact, let tx = tapX, tx >= padL, tx <= w - padR {
            var cursor = Path()
            cursor.move(to: CGPoint(x: tx, y: plotTop))
            cursor.addLine(to: CGPoint(x: tx, y: plotBottom))
            ctx.stroke(cursor, with: .color(Color(hex: 0x9CA3AF).opacity(0.5)), lineWidth: 0.5)
            let ts = startSec + Int64(Double((tx - padL) / plotW) * Double(endSec - startSec))
            let over = visible.filter { Int64($0.aos.value) <= ts && ts <= Int64($0.los.value) }.max { $0.peakElevDeg < $1.peakElevDeg }
            let near = signals.min { abs($0.atSec - ts) < abs($1.atSec - ts) }.flatMap { abs($0.atSec - ts) < 15 * 60 ? $0 : nil }
            var lines = ["\(Self.hhmm(ts)) UTC"]
            if let over { lines.append("\(over.satellite) \(Int(over.peakElevDeg))°") }
            if let near { lines.append("Signal: \(near.bars) bars") }
            let boxW: CGFloat = 120
            let boxX = tx > w / 2 ? tx - boxW - 6 : tx + 6
            let lineH: CGFloat = 12
            ctx.fill(
                Path(CGRect(x: boxX, y: plotTop + 2, width: boxW, height: CGFloat(lines.count) * lineH + 6)),
                with: .color(Color(hex: 0x1F2937).opacity(0.95)))
            for (i, s) in lines.enumerated() {
                ctx.draw(
                    Text(s).font(labelFont).foregroundColor(Color(hex: 0xD1D5DB)),
                    at: CGPoint(x: boxX + 6, y: plotTop + 2 + lineH * CGFloat(i + 1)), anchor: .bottomLeading)
            }
        }
    }
}
