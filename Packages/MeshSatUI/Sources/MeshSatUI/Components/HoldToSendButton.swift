// Mirrors ui/components/HoldToSend.kt: a button that acts only after it has been held for
// `holdMs` (MESHSAT-1249), the SOS. It fills from the left while held, counts the seconds down,
// and empties again if let go early, so a pocket or a stray tap sends nothing. With VoiceOver,
// where holding is awkward, its activate action calls `onAccessibleActivate` instead, which asks
// for a confirmation. Timed by the clock, not by an animation, so reduced motion cannot send.
import SwiftUI

public struct HoldToSendButton: View {
    let label: String
    let color: Color
    let holdMs: Int64
    let onComplete: () -> Void
    let onAccessibleActivate: () -> Void
    @State private var progress: Double = 0
    @State private var holding = false
    @State private var startedAt: Date?
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    public init(
        label: String, color: Color, holdMs: Int64 = 3_000, onComplete: @escaping () -> Void, onAccessibleActivate: @escaping () -> Void
    ) {
        self.label = label
        self.color = color
        self.holdMs = holdMs
        self.onComplete = onComplete
        self.onAccessibleActivate = onAccessibleActivate
    }

    private var secondsLeft: Int { max(1, Int(ceil((1 - progress) * Double(holdMs) / 1000))) }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack(alignment: .leading) {
            shape.fill(color.opacity(0.10))
            GeometryReader { geo in
                Rectangle().fill(color.opacity(0.55)).frame(width: geo.size.width * progress)
            }
            Text(holding ? "Keep holding: \(secondsLeft)" : label)
                .msText(.titleMedium, color: progress > 0.5 ? MSColors.offWhite : color)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 64)
        .clipShape(shape)
        .overlay(shape.stroke(color, lineWidth: 2))
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !holding {
                        holding = true
                        startedAt = Date()
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    }
                }
                .onEnded { _ in
                    holding = false
                    startedAt = nil
                    withAnimation(.easeOut(duration: 0.25)) { progress = 0 }
                }
        )
        .onReceive(tick) { _ in
            guard holding, let startedAt else { return }
            let p = min(1, Date().timeIntervalSince(startedAt) * 1000 / Double(holdMs))
            progress = p
            if p >= 1 {
                holding = false
                self.startedAt = nil
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                onComplete()
                progress = 0
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onAccessibleActivate() }
    }
}
