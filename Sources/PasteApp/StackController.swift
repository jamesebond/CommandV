import AppKit
import PasteCore

/// Paste Stack mode: while on, every new clip is queued; the paste hotkey drains the queue in order.
@MainActor
final class StackController {
    private(set) var stack = PasteStack()
    private(set) var isOn = false
    private let monitor: ClipboardMonitor?
    private let store: ClipStore?
    /// Called whenever mode or count changes; nil means stack mode is off.
    var onChange: ((Int?) -> Void)?
    var onNotice: ((String) -> Void)?

    /// `shortcutName` is the configured toggle shortcut, shown in the "stack is off" hint.
    var shortcutName: () -> String = { Shortcut.defaultStack.displayString }

    init(monitor: ClipboardMonitor?, store: ClipStore? = nil) { self.monitor = monitor; self.store = store }

    /// Drops queued clips that no longer exist in the store (deleted or cleared).
    func pruneDeleted() {
        guard let store, stack.isActive else { return }
        do {
            let alive = try store.existingClipIDs(among: stack.clipIDs)
            let dead = Set(stack.clipIDs).subtracting(alive)
            if !dead.isEmpty { stack.remove(clipIDs: dead); notifyChange() }
        } catch { NSLog("PasteClone: stack prune failed: \(error)") }
    }


    func toggle() {
        isOn.toggle()
        if !isOn { stack.clear() }
        notifyChange()
        onNotice?(isOn ? "Stack on" : "Stack off")
    }

    func handleNewClip(_ clip: Clip) {
        guard isOn else { return }
        stack.push(clip)
        notifyChange()
    }

    /// Peeks the next clip and only removes it once its clipboard write succeeded, so a failure loses nothing.
    /// Does nothing while a previous paste is still being delivered.
    func pasteNext() {
        guard isOn else { onNotice?("Stack is off—press \(shortcutName()) to start"); return }
        guard !Paster.isBusy else { return }
        pruneDeleted()   // pop-and-skip: never paste a clip that was deleted
        guard let monitor, let clip = stack.peekNext() else { onNotice?("Stack is empty"); return }
        // Global hotkey: the focused app is the frontmost one (we are an accessory app).
        let target = NSWorkspace.shared.frontmostApplication
        var finishedStack = false
        Paster.paste(clip, plainText: false, monitor: monitor, target: target, completion: { [weak self] ok in
            guard let self, ok else { return }   // on failure the item stays at the front of the stack
            _ = self.stack.popNext()
            if !self.stack.isActive { self.isOn = false; finishedStack = true }
            self.notifyChange()
        }, onFinished: { [weak self] in
            // Shown only after Paster is done, so it can't race Paster's own notices.
            if finishedStack { self?.onNotice?("Stack finished") }
        })
    }

    private func notifyChange() { onChange?(isOn ? stack.count : nil) }
}
