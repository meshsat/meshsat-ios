// Mirrors the Material 3 NavigationBar of ui/MeshSatUI.kt: a Surface bar with five equal items,
// a 64 x 32 pill indicator in SurfaceLight behind the selected icon, the label 4 pt below,
// OffWhite when selected and TextMuted otherwise, the icon swapping from outlined to filled.
// Drawn by hand rather than with the native tab bar so both apps look the same.
import SwiftUI

public struct MSNavigationBar: View {
    let selected: Tab
    let onSelect: (Tab) -> Void

    public init(selected: Tab, onSelect: @escaping (Tab) -> Void) {
        self.selected = selected
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let isSelected = tab == selected
                Button {
                    onSelect(tab)
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isSelected ? MSColors.surfaceLight : Color.clear)
                                .frame(width: 64, height: 32)
                            MSIcon.tab(tab, filled: isSelected)
                                .resizable().scaledToFit()
                                .frame(width: 24, height: 24)
                        }
                        Text(tab.title).msText(.labelMedium, color: isSelected ? MSColors.offWhite : MSColors.textMuted)
                    }
                    .foregroundStyle(isSelected ? MSColors.offWhite : MSColors.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .frame(height: 80)
        .background(MSColors.surface.ignoresSafeArea(edges: .bottom))
    }
}
