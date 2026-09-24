// Mirrors ui/components/Chrome.kt: SubScreen (the 56 dp header with a back arrow and the
// title, then a divider), GroupTitle (titleSmall in TextSecondary, 16/20/4 padding) and
// NavRow (64 dp minimum, a 24 dp tinted icon, titleMedium, an 8 dp state dot with a detail
// line in TextSecondary, a muted chevron).
import SwiftUI

public struct SubScreen<Content: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    public init(_ title: String, onBack: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.onBack = onBack
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: onBack) {
                    Image(systemName: "arrow.backward")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(MSColors.textPrimary)
                        .frame(width: MSSpace.touch, height: MSSpace.touch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Text(title).msText(.titleLarge)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: MSSpace.subScreenHeader)
            MSDivider()
            content()
        }
        .background(MSColors.bg)
    }
}

public struct GroupTitle: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .msText(.titleSmall, color: MSColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MSSpace.groupTitleSides)
            .padding(.top, MSSpace.groupTitleTop)
            .padding(.bottom, MSSpace.groupTitleBottom)
    }
}

public struct MSDivider: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(MSColors.border).frame(height: 1)
    }
}

public struct NavRow: View {
    let icon: Image
    let tint: Color
    let title: String
    let detail: String?
    let dot: Color?
    let action: () -> Void

    public init(
        icon: Image, tint: Color = MSColors.textSecondary, title: String, detail: String? = nil,
        dot: Color? = nil, action: @escaping () -> Void
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.detail = detail
        self.dot = dot
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                icon.resizable().scaledToFit().frame(width: 24, height: 24).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).msText(.titleMedium)
                    if let detail {
                        HStack(spacing: 6) {
                            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                            Text(detail).msText(.bodyMedium, color: MSColors.textSecondary).lineLimit(2)
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(MSColors.textMuted).font(.system(size: 17))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: MSSpace.navRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
