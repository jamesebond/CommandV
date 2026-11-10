import AppKit
import Observation
import PasteCore

extension Notification.Name {
    /// Posted by PanelController.show().
    /// Posted by PanelController.hide().
    static let panelDidHide = Notification.Name("CommandV.panelDidHide")
    static let panelWillShow = Notification.Name("CommandV.panelWillShow")
    /// Posted (on the main queue) when the monitor stores a new clip.
    static let clipsDeleted = Notification.Name("CommandV.clipsDeleted")
    static let clipStored = Notification.Name("CommandV.clipStored")
}

@MainActor @Observable
final class PanelViewModel {
    enum Tab: Equatable, Hashable {
        case clipboard
        case pinboard(Int64)
    }

    static let clipLimit = 300

    /// Content-type filter choices (feeds `ClipFilter.kinds`).
    enum TypeChoice: String, CaseIterable, Identifiable {
        case all = "All", text = "Text", images = "Images", links = "Links", files = "Files"
        var id: String { rawValue }
        var kinds: Set<ClipKind> {
            switch self {
            case .all: []
            case .text: [.text, .richText]
            case .images: [.image]
            case .links: [.link]
            case .files: [.file]
            }
        }
    }

    /// Inline pinboard editor state; `id == nil` means creating a new pinboard.
    struct PinboardEdit: Equatable {
        var id: Int64?
        var name: String
        var colorHex: String
    }

    static let presetColors = ["#E5484D", "#F76B15", "#F5B50A", "#30A46C", "#12A594", "#3E63DD", "#8E4EC6", "#6F6E77"]

    var filter = ClipFilter() {
        didSet {
            if suppressReload { return }
            if filter.query != oldValue.query { scheduleReload() }
            else if filter.kinds != oldValue.kinds || filter.sourceBundleID != oldValue.sourceBundleID {
                reload(); selectFirst()
            }
        }
    }
    var sourceApps: [(bundleID: String, name: String)] = []
    var showFilters = false
    var pinboardEdit: PinboardEdit?
    /// While true the key monitor leaves Return/Esc/arrows/delete to the inline editor's text field.
    var isEditingPinboard: Bool { pinboardEdit != nil }
    var typeChoice: TypeChoice {
        TypeChoice.allCases.first { $0.kinds == filter.kinds } ?? .all
    }
    /// What to show when `clips` is empty.
    enum EmptyKind: Equatable { case nothingCopied, noResults, emptyPinboard }
    var emptyKind: EmptyKind {
        if isSearching || hasActiveFilters { return .noResults }
        if case .pinboard = activeTab { return .emptyPinboard }
        return .nothingCopied
    }
    var hasActiveFilters: Bool { !filter.kinds.isEmpty || filter.sourceBundleID != nil }
    var clips: [Clip] = []
    var selectedID: Int64?
    var activeTab: Tab = .clipboard {
        didSet { if activeTab != oldValue, !suppressReload { reload(); selectFirst() } }
    }
    var pinboards: [Pinboard] = []
    /// Bumped on every show so the view can re-focus the search field.
    var focusTick = 0

    @ObservationIgnored private let store: ClipStore?
    @ObservationIgnored private let monitor: ClipboardMonitor?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(store: ClipStore?, monitor: ClipboardMonitor?) {
        self.store = store
        self.monitor = monitor
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .panelWillShow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelWillShow() }
        })
        observers.append(nc.addObserver(forName: .clipStored, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(nc.addObserver(forName: .panelDidHide, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinboardEdit = nil }
        })
        reload()
        selectFirst()
    }

    var isSearching: Bool { !filter.query.trimmingCharacters(in: .whitespaces).isEmpty }
    var selectedClip: Clip? { clips.first { $0.id == selectedID } }

    private func panelWillShow() {
        debounce?.cancel()
        debounce = nil
        // Reset without scheduling a delayed reload that could override an arrow key pressed right after opening.
        suppressReload = true
        pinboardEdit = nil
        filter.query = ""
        filter.kinds = []
        filter.sourceBundleID = nil
        showFilters = false
        activeTab = .clipboard
        suppressReload = false
        reload()
        selectFirst()
        focusTick += 1
    }

    /// While true, filter/tab changes don't trigger reloads (the caller reloads once itself).
    @ObservationIgnored private var suppressReload = false

    private func scheduleReload() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.debounce = nil
            self?.reload()
            self?.selectFirst()
        }
    }

    /// Runs a pending debounced query reload right now, so Return/arrows act on the results for what was typed.
    func flushPendingReload() {
        guard let pending = debounce else { return }
        pending.cancel()
        debounce = nil
        reload()
        selectFirst()
    }

    private func selectFirst() { selectedID = clips.first?.id }

    func reload() {
        guard let store else { clips = []; return }
        var f = filter
        if case .pinboard(let id) = activeTab { f.pinboardID = id }
        do {
            clips = try store.search(f, limit: Self.clipLimit)
            pinboards = try store.pinboards()
            sourceApps = try store.sourceApps()
        } catch {
            NSLog("CommandV: reload failed: \(error)")
            clips = []
        }
        if let s = selectedID, !clips.contains(where: { $0.id == s }) { selectedID = clips.first?.id }
        if selectedID == nil { selectedID = clips.first?.id }
    }

    func moveSelection(_ d: Int) {
        flushPendingReload()
        guard !clips.isEmpty else { return }
        guard let cur = clips.firstIndex(where: { $0.id == selectedID }) else { selectedID = clips[0].id; return }
        selectedID = clips[min(max(cur + d, 0), clips.count - 1)].id
    }

    func pasteSelected(plain: Bool) {
        flushPendingReload()
        guard let clip = selectedClip, let monitor else { return }
        Paster.paste(clip, plainText: plain, monitor: monitor)
    }

    func paste(_ clip: Clip, plain: Bool = false) {
        guard let monitor else { return }
        flushPendingReload()
        selectedID = clip.id
        Paster.paste(clip, plainText: plain, monitor: monitor)
    }

    func deleteSelected() {
        guard let store, let idx = clips.firstIndex(where: { $0.id == selectedID }) else { return }
        do { try store.deleteWithFiles(id: clips[idx].id) } catch { NSLog("CommandV: delete failed: \(error)"); return }
        let next = idx + 1 < clips.count ? clips[idx + 1].id : (idx > 0 ? clips[idx - 1].id : nil)
        selectedID = next
        reload()
        NotificationCenter.default.post(name: .clipsDeleted, object: nil)
    }

    /// Esc: clears a non-empty search, otherwise closes the panel. Single entry point for Esc.
    func handleEscape() {
        if isEditingPinboard { cancelPinboardEdit(); return }
        switch EscapeAction.forQuery(filter.query) {
        case .clearSearch: filter.query = ""
        case .closePanel: PanelController.shared?.hide()
        }
    }

    /// Delete key: removes the selected card only when the search field is empty; returns whether handled.
    var deleteKeyActive: Bool { filter.query.isEmpty }

    func handleDeleteKey() -> Bool {
        guard filter.query.isEmpty else { return false }
        deleteSelected()
        return true
    }

    // MARK: - Filters

    func setType(_ choice: TypeChoice) { filter.kinds = choice.kinds }

    func toggleSource(_ bundleID: String) {
        filter.sourceBundleID = filter.sourceBundleID == bundleID ? nil : bundleID
    }

    func clearFilters() {
        filter.kinds = []
        filter.sourceBundleID = nil
    }

    // MARK: - Pinboards

    func beginNewPinboard() {
        pinboardEdit = PinboardEdit(id: nil, name: "", colorHex: Self.presetColors[pinboards.count % Self.presetColors.count])
    }

    func beginRename(_ pb: Pinboard) {
        pinboardEdit = PinboardEdit(id: pb.id, name: pb.name, colorHex: pb.colorHex)
    }

    func cancelPinboardEdit() {
        guard pinboardEdit != nil else { return }
        pinboardEdit = nil
        focusTick += 1
    }

    func commitPinboardEdit() {
        guard let edit = pinboardEdit, let store else { pinboardEdit = nil; return }
        let name = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { cancelPinboardEdit(); return }
        do {
            if let id = edit.id {
                try store.renamePinboard(id: id, name: name)
            } else {
                let pb = try store.addPinboard(name: name, colorHex: edit.colorHex)
                pinboardEdit = nil
                reload()
                activeTab = .pinboard(pb.id)
                focusTick += 1
                return
            }
        } catch { NSLog("CommandV: pinboard save failed: \(error)") }
        pinboardEdit = nil
        reload()
        focusTick += 1
    }

    func deletePinboard(_ pb: Pinboard) {
        guard let store else { return }
        do { try store.deletePinboard(id: pb.id) } catch { NSLog("CommandV: pinboard delete failed: \(error)"); return }
        if activeTab == .pinboard(pb.id) { activeTab = .clipboard }
        reload()
    }

    @discardableResult
    func pin(clipID: Int64, to pinboardID: Int64?) -> Bool {
        guard let store else { return false }
        do { try store.setPinboard(clipID: clipID, pinboardID: pinboardID) } catch {
            NSLog("CommandV: pin failed: \(error)"); return false
        }
        reload()
        return true
    }
}
