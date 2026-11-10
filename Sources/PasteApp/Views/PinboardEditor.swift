import SwiftUI

/// Compact inline editor shown in the top bar: name field plus preset color dots.
/// Return confirms; Esc cancels (routed through `PanelViewModel.handleEscape`).
struct PinboardEditor: View {
    @Binding var edit: PanelViewModel.PinboardEdit
    var colors: [String] = PanelViewModel.presetColors
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    @FocusState private var nameFocused: Bool
    @State private var hadFocus = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.color(hex: edit.colorHex) ?? .gray)
                .frame(width: 9, height: 9)
            TextField("Pinboard name", text: $edit.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($nameFocused)
                .frame(width: 120)
                .onSubmit(onCommit)
                .onExitCommand(perform: onCancel)
            HStack(spacing: 5) {
                ForEach(colors, id: \.self) { hex in
                    // Tap gesture (not Button) so choosing a color never takes focus from the name field.
                    Circle()
                        .fill(Theme.color(hex: hex) ?? .gray)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(edit.colorHex == hex ? 0.9 : 0), lineWidth: 1.5).padding(-2))
                        .contentShape(Circle())
                        .onTapGesture { edit.colorHex = hex }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(Color.primary.opacity(0.12)))
        .onAppear { nameFocused = true }
        // Losing focus without a commit (clicking elsewhere) cancels, so the key monitor is never left disabled.
        .onChange(of: nameFocused) {
            if nameFocused { hadFocus = true } else if hadFocus { onCancel() }
        }
    }
}
