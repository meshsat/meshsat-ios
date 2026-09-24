// The Material 3 Slider as Android draws it: a 4 dp inactive track in the surface variant, the
// active part and the 20 dp thumb in the primary colour, inside a 48 dp touch height.
import SwiftUI

public struct MSSlider: View {
    @Binding var value: Float
    let label: String

    public init(value: Binding<Float>, label: String) {
        _value = value
        self.label = label
    }

    public var body: some View {
        GeometryReader { g in
            let w = max(g.size.width - 20, 1)
            let x = CGFloat(min(max(value, 0), 1)) * w
            ZStack(alignment: .leading) {
                Capsule().fill(MSColors.surfaceLight).frame(height: 4).padding(.horizontal, 10)
                Capsule().fill(MSColors.signalOrange).frame(width: x + 10, height: 4).padding(.leading, 10)
                Circle().fill(MSColors.signalOrange).frame(width: 20, height: 20).offset(x: x)
            }
            .frame(height: MSSpace.touch)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in value = Float(min(max((v.location.x - 10) / w, 0), 1)) })
        }
        .frame(height: MSSpace.touch)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}
