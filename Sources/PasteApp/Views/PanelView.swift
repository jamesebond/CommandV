import SwiftUI
import PasteCore

struct PanelView: View {
    @Bindable var model: PanelViewModel
    var appearance: AppearanceModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SearchBarView(model: model, appearance: appearance, focus: $searchFocused)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            if model.showFilters {
                FilterRowView(model: model)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
            if model.clips.isEmpty { emptyState } else { strip }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusTick) { searchFocused = true }
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(model.clips) { clip in
                        ClipCardView(clip: clip, selected: clip.id == model.selectedID)
                            .id(clip.id)
                            .onTapGesture(count: 2) { model.paste(clip) }
                            .onTapGesture { model.selectedID = clip.id }
                            .onDrag {
                                PanelController.shared?.beginDrag(clipID: clip.id)
                                return ClipDrag.provider(for: clip)
                            }
                            .contextMenu { cardMenu(clip) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .onChange(of: model.selectedID) {
                guard let id = model.selectedID else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: model.focusTick) {
                if let id = model.selectedID { proxy.scrollTo(id, anchor: .leading) }
            }
        }
    }

    @ViewBuilder
    private func cardMenu(_ clip: Clip) -> some View {
        Menu("Add to pinboard") {
            if model.pinboards.isEmpty {
                Text("No pinboards yet")
            } else {
                ForEach(model.pinboards) { pb in
                    Button(pb.name) { model.pin(clipID: clip.id, to: pb.id) }
                }
            }
        }
        if clip.pinboardID != nil {
            Button("Remove from pinboard") { model.pin(clipID: clip.id, to: nil) }
        }
    }

    private var emptyState: some View {
        let kind = model.emptyKind
        return VStack(spacing: 10) {
            Image(systemName: kind == .noResults ? "magnifyingglass" : (kind == .emptyPinboard ? "pin" : "doc.on.clipboard"))
                .font(.system(size: 34, weight: .light))
            Text(kind == .noResults ? "No results" : (kind == .emptyPinboard ? "No clips in this pinboard yet" : "Nothing copied yet"))
                .font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(.secondary.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
