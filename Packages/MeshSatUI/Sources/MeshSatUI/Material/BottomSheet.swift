// The Material 3 ModalBottomSheet as Android draws it: a scrim, the surface container with
// 28 dp top corners and a 32 x 4 dp drag handle, sliding up from the bottom. Native iOS sheets
// are not used (parity rule); the sheet is drawn in-tree so night mode reaches it.
import SwiftUI

public struct MSModalBottomSheet<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    public init(onDismiss: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.onDismiss = onDismiss
        self.content = content
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.32).ignoresSafeArea().onTapGesture(perform: onDismiss)
            VStack(spacing: 0) {
                Capsule().fill(MSColors.textMuted.opacity(0.4)).frame(width: 32, height: 4).padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 20).onEnded { g in if g.translation.height > 40 { onDismiss() } })
                content()
            }
            .frame(maxWidth: .infinity)
            .background(
                MSColors.surface,
                in: UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 28)
            )
            .transition(.move(edge: .bottom))
        }
        .ignoresSafeArea(edges: .bottom)
    }
}
