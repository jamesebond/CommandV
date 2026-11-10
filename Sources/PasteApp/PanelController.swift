import AppKit
import PasteCore
import SwiftUI

final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static var shared: PanelController?

    static let panelHeight: CGFloat = 362

    private var panel: PanelWindow?
    private let rootView: () -> AnyView
    /// Frontmost app at the moment the panel was shown; Paster re-activates it.
    private(set) var previousApp: NSRunningApplication?
    private(set) var isVisible = false
    /// Key actions supplied by the view model (wired in AppDelegate).
    struct KeyActions {
        var move: (Int) -> Void
        var paste: (_ plain: Bool) -> Void
        var delete: () -> Bool   // false = not handled (field edits text)
        var deleteActive: () -> Bool = { true }   // would ⌫ delete a card (vs. edit the search field)?
        var escape: () -> Void
        /// True while the inline pinboard editor owns the keyboard.
        var isEditing: () -> Bool = { false }
    }
    var keyActions: KeyActions?
    private var keyMonitor: Any?

    // MARK: Drag-out

    /// True from the start of a card drag until the mouse button is released. While set, losing key status
    /// (e.g. the destination app activating) must not hide the panel mid-drag.
    private(set) var isDragging = false
    /// The clip being dragged from this panel, from drag start until the post-drop hide check. The pinboard tabs
    /// fall back to it if the private flavor's payload can't be read.
    private(set) var activeDragClipID: Int64?
    private var dragTimer: Timer?
    /// Bumped on show, hide and drag start so a stale delayed hide can't act on a newer panel session.
    private var generation = 0
    private var dropHandledByTab = false
    private var dragStartChangeCount = 0
    private var dragStartMouse = NSPoint.zero

    /// Called when a card drag starts. Ignored unless the left button is down (the drag closure can be evaluated
    /// without a drag). `NSItemProvider` has no end callback, so a timer watches the mouse button; it runs in
    /// common modes because AppKit tracks the drag in a non-default run loop mode.
    @discardableResult
    func beginDrag(clipID: Int64) -> Bool {
        guard isVisible, NSEvent.pressedMouseButtons & 1 != 0 else { return false }
        endDragTracking()
        generation += 1
        isDragging = true
        activeDragClipID = clipID
        dropHandledByTab = false
        dragStartChangeCount = NSPasteboard(name: .drag).changeCount
        dragStartMouse = NSEvent.mouseLocation
        let started = Date()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The 120 s cap guarantees the panel can never stay pinned open by a missed mouse-up.
                if NSEvent.pressedMouseButtons & 1 != 0, Date().timeIntervalSince(started) < 120 { return }
                self.finishDrag()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        dragTimer = t
        return true
    }

    /// A pinboard tab accepted the drop: keep the panel open.
    func noteDropOnTab() { dropHandledByTab = true }

    private func endDragTracking() {
        dragTimer?.invalidate()
        dragTimer = nil
        isDragging = false
    }

    /// The mouse was released. Give the destination a moment, then hide, unless a pinboard tab took the drop.
    private func finishDrag() {
        endDragTracking()
        let gen = generation
        // A press can evaluate the drag closure too, so judge by what happened: did the drag pasteboard change
        // (a drag session wrote to it) or did the mouse travel? Otherwise it was a click and the panel stays.
        let pasteboardChanged = NSPasteboard(name: .drag).changeCount != dragStartChangeCount
        let m = NSEvent.mouseLocation
        let moved = Double(hypot(m.x - dragStartMouse.x, m.y - dragStartMouse.y))
        if !pasteboardChanged && moved <= DragOutcome.dragThreshold { activeDragClipID = nil; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen, !self.isDragging else { return }
                self.activeDragClipID = nil
                guard self.isVisible, let p = self.panel else { return }
                let outcome = DragOutcome.decide(pasteboardChanged: pasteboardChanged, movedDistance: moved,
                                                 mouseOverPanel: p.frame.contains(NSEvent.mouseLocation),
                                                 panelIsKey: p.isKeyWindow, pinnedOnTab: self.dropHandledByTab)
                if outcome == .hide { self.hide() }
            }
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel, let a = keyActions else { return false }
        // The inline pinboard editor handles Return/Esc/arrows/delete itself.
        if a.isEditing() { return false }
        // Don't steal keys while an input method is composing.
        if let tv = panel.firstResponder as? NSTextView, tv.hasMarkedText() { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: a.move(-1); return true
        case 124: a.move(1); return true
        case 36, 76: a.paste(shift); return true
        case 51:
            // A held key must not delete a card per repeat; only swallow repeats that would have deleted.
            if event.isARepeat { return a.deleteActive() }
            return a.delete()
        case 53: a.escape(); return true
        default: return false
        }
    }


    /// Paster calls this once a paste has completed or been abandoned.
    func clearPreviousApp() { previousApp = nil }

    init<V: View>(@ViewBuilder content: @escaping () -> V) {
        rootView = { AnyView(content()) }
        super.init()
    }

    private func makePanel() -> PanelWindow {
        let p = PanelWindow(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.onEscape = { [weak self] in
            if let a = self?.keyActions { a.escape() } else { self?.hide() }
        }

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        effect.layer?.masksToBounds = true

        let host = NSHostingView(rootView: rootView())
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        p.contentView = effect
        return p
    }

    private func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func show() {
        guard !isVisible else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front?.processIdentifier == ProcessInfo.processInfo.processIdentifier) ? previousApp : front
        let p = panel ?? makePanel()
        panel = p
        let vis = targetScreen().visibleFrame
        let full = targetScreen().frame
        let finalFrame = NSRect(x: full.minX, y: vis.minY, width: full.width, height: Self.panelHeight)
        var start = finalFrame
        start.origin.y -= Self.panelHeight
        p.setFrame(start, display: false)
        p.alphaValue = 0
        isVisible = true
        generation += 1
        NotificationCenter.default.post(name: .panelWillShow, object: nil)
        installKeyMonitor()
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(finalFrame, display: true)
            p.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible, let p = panel else { return }
        isVisible = false
        generation += 1
        activeDragClipID = nil
        endDragTracking()
        removeKeyMonitor()
        p.orderOut(nil)
        p.alphaValue = 1
        NotificationCenter.default.post(name: .panelDidHide, object: nil)
    }

    func toggle() { isVisible ? hide() : show() }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { if !isDragging { hide() } }
    }
}
