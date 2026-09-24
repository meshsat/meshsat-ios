// The Material 3 AlertDialog as Android draws it: a 16 dp radius surface on a scrim, headlineSmall
// title, the text, and the buttons right-aligned with the dismiss button before the confirm one.
// Every dialog is in-tree, so night mode's colour effect covers it (parity rule).
import SwiftUI

public struct MSAlertDialog<Content: View, Buttons: View>: View {
    let title: String
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons

    public init(
        _ title: String, onDismiss: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder buttons: @escaping () -> Buttons
    ) {
        self.title = title
        self.onDismiss = onDismiss
        self.content = content
        self.buttons = buttons
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea().onTapGesture(perform: onDismiss)
            VStack(alignment: .leading, spacing: 16) {
                Text(title).msText(.headlineSmall)
                content()
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    buttons()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(MSColors.surface, in: RoundedRectangle(cornerRadius: MSRadius.dialog, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MSRadius.dialog, style: .continuous).stroke(MSColors.border, lineWidth: 1))
            .padding(.horizontal, 24)
        }
    }
}

/// Material's indeterminate CircularProgressIndicator, sized by the caller.
public struct MSCircularProgress: View {
    let size: CGFloat
    let stroke: CGFloat
    let color: Color
    @State private var spinning = false

    public init(size: CGFloat = 24, stroke: CGFloat = 3, color: Color = MSColors.signalOrange) {
        self.size = size
        self.stroke = stroke
        self.color = color
    }

    public var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.8)
            .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
