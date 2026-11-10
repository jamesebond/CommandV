import AppKit
import ApplicationServices
import PasteCore

@MainActor
enum Paster {
    /// Called when the clip was copied but ⌘V could not be injected (no Accessibility permission).
    static var onNotice: ((String) -> Void)?

    private static var didPromptForAccessibility = false

    /// Shows the system Accessibility prompt if we aren't trusted. At most once per session.
    @discardableResult
    static func promptForAccessibilityOnce() -> Bool {
        if AXIsProcessTrusted() { return true }
        guard !didPromptForAccessibility else { return false }
        didPromptForAccessibility = true
        let key = "AXTrustedCheckOptionPrompt"   // value of kAXTrustedCheckOptionPrompt (the global isn't concurrency-safe)
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// True from the start of `paste` until its ⌘V task has finished or aborted. While busy, new pastes are refused.
    private(set) static var isBusy = false

    /// `completion(true)` fires exactly once, as soon as the clipboard write succeeded (the user can then ⌘V
    /// manually even if auto-paste can't run). `completion(false)` fires when resolving/writing failed, or
    /// immediately (without touching the pasteboard) when another paste is still in progress.
    /// `onFinished` fires once the busy window ends (after the ⌘V was posted or the paste was abandoned),
    /// but only for pastes that actually started.
    static func paste(_ clip: Clip, plainText: Bool, monitor: ClipboardMonitor, target: NSRunningApplication? = nil,
                      completion: (@MainActor (Bool) -> Void)? = nil,
                      onFinished: (@MainActor () -> Void)? = nil) {
        guard !isBusy else { onNotice?("Still pasting…"); completion?(false); return }
        isBusy = true
        func end() { isBusy = false; onFinished?() }

        let panel = PanelController.shared
        let prev = target ?? panel?.previousApp
        // Cleared once this paste completes or is abandoned (prev is already captured).
        defer { panel?.clearPreviousApp() }
        // Resolve everything before touching the pasteboard.
        guard let payload = ClipContentResolver.resolve(clip, plainText: plainText) else {
            onNotice?("Couldn't paste: the saved item is missing")
            completion?(false)
            end()
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        guard commit(payload, to: pb) else {
            // The pasteboard was already cleared and partly written; don't capture that as a clip.
            monitor.markSelfWrite()
            onNotice?("Couldn't paste: the clipboard write failed")
            completion?(false)
            end()
            return
        }
        // Must come AFTER the write: records the current changeCount.
        monitor.markSelfWrite()
        completion?(true)

        panel?.hide()

        guard AXIsProcessTrusted() else {
            promptForAccessibilityOnce()
            prev?.activate()
            onNotice?("Copied—grant Accessibility to paste automatically, or press ⌘V")
            end()
            return
        }
        guard let prev else {
            onNotice?("Copied—couldn't find the app to paste into")
            end()
            return
        }
        Task { @MainActor in
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == prev.processIdentifier {
                try? await Task.sleep(for: .milliseconds(50))
            } else {
                prev.activate()
                var waited = 0
                while NSWorkspace.shared.frontmostApplication?.processIdentifier != prev.processIdentifier {
                    if waited >= 500 {
                        onNotice?("Copied—couldn't switch back to the app to paste")
                        end()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                    waited += 20
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
            postCommandV()
            end()
        }
    }

    /// Legacy pasteboard flavors for the UTIs `ClipContentResolver` uses (`.html` and `.rtf` are not the public UTIs).
    private static func pasteboardType(for uti: String) -> NSPasteboard.PasteboardType {
        switch uti {
        case ClipContentResolver.html: .html
        case ClipContentResolver.rtf: .rtf
        default: NSPasteboard.PasteboardType(uti)
        }
    }

    private static func commit(_ content: ClipContent, to pb: NSPasteboard) -> Bool {
        if !content.fileURLs.isEmpty { return pb.writeObjects(content.fileURLs.map { $0 as NSURL }) }
        var ok = true
        for r in content.representations { ok = pb.setData(r.data, forType: pasteboardType(for: r.typeIdentifier)) && ok }
        if let s = content.string { ok = pb.setString(s, forType: .string) && ok }
        return ok
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
