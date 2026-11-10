import SwiftUI
import PasteCore

/// Top bar: magnifier toggle, search field (when open), tab pills.
struct SearchBarView: View {
    @Bindable var model: PanelViewModel
    var appearance: AppearanceModel
    var focus: FocusState<Bool>.Binding
    @State private var dropTarget: Int64?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Button {
                focus.wrappedValue = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    
            }
            .buttonStyle(.plain)
            .help("Search")

            do {
                HStack(spacing: 6) {
                    TextField("Search", text: $model.filter.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused(focus)
                    if !model.filter.query.isEmpty {
                        Button { model.filter.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: 220, height: 26)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            }

            filterButton

            tab(title: "Clipboard", systemImage: "clock", dot: nil, tab: .clipboard)
            ForEach(model.pinboards) { pb in
                if let edit = model.pinboardEdit, edit.id == pb.id {
                    PinboardEditor(edit: editBinding, onCommit: model.commitPinboardEdit, onCancel: model.cancelPinboardEdit)
                } else {
                    tab(title: pb.name, systemImage: nil, dot: Theme.color(hex: pb.colorHex) ?? .gray, tab: .pinboard(pb.id))
                        .contextMenu {
                            Button("Rename") { model.beginRename(pb) }
                            Button("Delete", role: .destructive) { model.deletePinboard(pb) }
                        }
                }
            }
            if let edit = model.pinboardEdit, edit.id == nil {
                PinboardEditor(edit: editBinding, onCommit: model.commitPinboardEdit, onCancel: model.cancelPinboardEdit)
            } else {
                Button { model.beginNewPinboard() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("New pinboard")
            }
            Spacer()
            appearanceButton
        }
    }

    /// Plain button (no popover or menu) so clicking it never takes key status from the panel.
    private var appearanceButton: some View {
        let dark = colorScheme == .dark
        let label = dark ? "Switch to light mode" : "Switch to dark mode"
        return Button { appearance.toggle(currentlyDark: dark) } label: {
            Image(systemName: dark ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var editBinding: Binding<PanelViewModel.PinboardEdit> {
        Binding(get: { model.pinboardEdit ?? .init(id: nil, name: "", colorHex: "#6F6E77") },
                set: { model.pinboardEdit = $0 })
    }

    private var filterButton: some View {
        HStack(spacing: 6) {
            Button { model.showFilters.toggle() } label: {
                Image(systemName: model.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.hasActiveFilters ? Color.accentColor : Color.secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Filters")
            if model.hasActiveFilters {
                Button("Clear filters") { model.clearFilters() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func tab(title: String, systemImage: String?, dot: Color?, tab: PanelViewModel.Tab) -> some View {
        let selected = model.activeTab == tab
        var pinboardID: Int64?
        if case .pinboard(let id) = tab { pinboardID = id }
        let targeted = pinboardID != nil && dropTarget == pinboardID
        return Button { model.activeTab = tab } label: {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .medium)) }
                if let dot { Circle().fill(dot).frame(width: 9, height: 9) }
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(targeted ? Color.green.opacity(0.28) : (selected ? Color.primary.opacity(0.12) : .clear)))
            .overlay(Capsule().strokeBorder(Color.green.opacity(targeted ? 0.9 : 0), lineWidth: 1.5))
            .overlay(alignment: .topTrailing) { if targeted { DropBadge().offset(x: 5, y: -6) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Accepts only the private clip-id flavor; foreign text or files dropped here are ignored.
        .onDrop(of: pinboardID == nil ? [] : [ClipDrag.clipIDType], isTargeted: Binding(
            get: { targeted },
            set: { over in
                if over { dropTarget = pinboardID } else if dropTarget == pinboardID { dropTarget = nil }
            })
        ) { providers in
            guard let pid = pinboardID,
                  let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(ClipDragID.typeIdentifier) })
            else { return false }
            let model = model
            // The decoded payload wins; the in-memory id is used only for a drag that started in this panel.
            provider.loadDataRepresentation(forTypeIdentifier: ClipDragID.typeIdentifier) { data, _ in
                let decoded = ClipDragID.decode(data)
                Task { @MainActor in
                    let panel = PanelController.shared
                    guard let id = decoded ?? panel?.activeDragClipID else { return }
                    if model.pin(clipID: id, to: pid) { panel?.noteDropOnTab() }
                }
            }
            return true
        }
    }
}

/// Green "+" badge shown on a pinboard tab while a card is dragged over it.
struct DropBadge: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(Circle().fill(Color.green))
    }
}

/// Filter chips: content type plus source app. Shown below the top bar when the filter button is on.
struct FilterRowView: View {
    @Bindable var model: PanelViewModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PanelViewModel.TypeChoice.allCases) { c in
                chip(c.rawValue, on: model.typeChoice == c) { model.setType(c) }
            }
            if !model.sourceApps.isEmpty {
                Divider().frame(height: 14).padding(.horizontal, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.sourceApps, id: \.bundleID) { app in
                            chip(app.name, on: model.filter.sourceBundleID == app.bundleID) { model.toggleSource(app.bundleID) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}
