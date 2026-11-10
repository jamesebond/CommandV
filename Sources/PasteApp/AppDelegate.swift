import AppKit
import SwiftUI
import PasteCore

/// Lets the monitor callback (created first) reach the stack controller (created after the monitor).
final class StackBox: @unchecked Sendable { @MainActor var controller: StackController? }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: PanelController?
    private var hotKey: HotKey?
    private var stackHotKey: HotKey?
    private var stackController: StackController?
    private var stackCount: Int?
    private(set) var store: ClipStore?
    private(set) var monitor: ClipboardMonitor?
    private var pauseItem: NSMenuItem?
    private var paused = false
    private let appearance = AppearanceModel()
    private lazy var settings = SettingsModel(appearance: appearance)
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appearance.apply()

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PasteClone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stack = StackBox()
        do {
            let store = try ClipStore(path: dir.appendingPathComponent("history.sqlite").path)
            self.store = store
            let prefs = settings.preferences
            let monitor = ClipboardMonitor(store: store, rules: CaptureRules(excludedBundleIDs: prefs.excludedBundleIDs)) { clip in
                // OCR new image clips in the background (never on main); skip clips that already have text.
                if clip.kind == .image, clip.ocrText == nil {
                    Task.detached(priority: .utility) {
                        await OCRIndexer(store: store).index(clip: clip)
                        DispatchQueue.main.async { NotificationCenter.default.post(name: .clipStored, object: nil) }
                    }
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .clipStored, object: nil)
                    MainActor.assumeIsolated { stack.controller?.handleNewClip(clip) }
                }
            }
            self.monitor = monitor
            monitor.start()
        } catch {
            NSLog("PasteClone: failed to open store: \(error)")
        }

        let stackController = StackController(monitor: monitor, store: store)
        stack.controller = stackController
        self.stackController = stackController
        stackController.onChange = { [weak self] count in self?.stackCount = count; self?.refreshTitle() }
        stackController.shortcutName = { [weak self] in self?.settings.stackShortcut.displayString ?? Shortcut.defaultStack.displayString }
        NotificationCenter.default.addObserver(forName: .clipsDeleted, object: nil, queue: .main) { [weak stackController] _ in
            MainActor.assumeIsolated { stackController?.pruneDeleted() }
        }
        stackController.onNotice = { [weak self] msg in self?.flash(msg) }

        let model = PanelViewModel(store: store, monitor: monitor)
        let appearance = self.appearance
        let panel = PanelController { PanelView(model: model, appearance: appearance) }
        panel.keyActions = PanelController.KeyActions(
            move: { model.moveSelection($0) },
            paste: { model.pasteSelected(plain: $0) },
            delete: { model.handleDeleteKey() },
            deleteActive: { model.deleteKeyActive },
            escape: { model.handleEscape() },
            isEditing: { model.isEditingPinboard })
        PanelController.shared = panel
        self.panel = panel
        // ⇧⌘V: pastes the next stack item while a stack is running, otherwise toggles the panel.
        let prefs = settings.preferences
        hotKey = HotKey(id: 1, keyCode: prefs.panelShortcut.keyCode, modifiers: prefs.panelShortcut.modifiers) { [weak panel, weak stackController] in
            if let sc = stackController, sc.isOn, sc.stack.isActive { sc.pasteNext() } else { panel?.toggle() }
        }
        // ⇧⌘C: toggle stack mode.
        stackHotKey = HotKey(id: 2, keyCode: prefs.stackShortcut.keyCode, modifiers: prefs.stackShortcut.modifiers) { [weak stackController] in stackController?.toggle() }

        for (hk, name) in [(hotKey, "panel"), (stackHotKey, "stack")] where hk?.registrationStatus != noErr {
            NSLog("PasteClone: couldn't register the \(name) shortcut (status \(hk?.registrationStatus ?? -1))")
        }

        settings.store = store
        settings.applyShortcut = { [weak self] target, shortcut in
            guard let hk = target == .panel ? self?.hotKey : self?.stackHotKey else { return }
            try hk.update(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
        }
        settings.suspendHotKeys = { [weak self] in self?.hotKey?.suspend(); self?.stackHotKey?.suspend() }
        settings.resumeHotKeys = { [weak self] in self?.retryHotKeys() }
        settings.applyPaused = { [weak self] value in self?.setPaused(value) }
        settings.applyExcluded = { [weak self] ids in self?.monitor?.updateRules(CaptureRules(excludedBundleIDs: ids)) }

        setupMainMenu()
        setupStatusItem()
        // The status item exists now, so a shortcut that failed to register can flash a notice.
        retryHotKeys()
        // Ask for Accessibility once at launch (auto-paste needs it); copy-only fallback remains if refused.
        Paster.promptForAccessibilityOnce()
        Paster.onNotice = { [weak self] msg in self?.flash(msg) }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "PasteClone")
        item.button?.toolTip = "PasteClone"
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openPanel), keyEquivalent: "").target = self
        let pause = NSMenuItem(title: "Pause capture", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseItem = pause
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openPanel() { panel?.show() }

    @objc private func togglePause() { setPaused(!paused); settings.paused = paused }

    private func setPaused(_ value: Bool) {
        paused = value
        if paused { monitor?.stop() } else { monitor?.markSelfWrite(); monitor?.start() }
        pauseItem?.state = paused ? .on : .off
        pauseItem?.title = paused ? "Resume capture" : "Pause capture"
    }

    /// Settings is a regular window, so alerts and sheets work there (unlike the non-activating panel).
    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: settings)))
            w.title = "PasteClone settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
            // The window is kept alive when closed, so don't rely on onDisappear to end a recording.
            for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.settings.stopRecording() }
                }
            }
        }
        settings.refreshLaunchAtLogin()
        retryHotKeys()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// An accessory app has no menu bar, but a main menu still routes ⌘, ⌘W ⌘Q while our windows are key.
    /// Re-registers any hotkey that isn't active (after recording, or on opening Settings) and reports failures.
    private func retryHotKeys() {
        for hk in [hotKey, stackHotKey] {
            guard let hk, let c = hk.combination else { continue }
            let status = hk.resume()
            if status != noErr {
                let name = shortcutDisplayString(keyCode: c.keyCode, modifiers: c.modifiers)
                NSLog("PasteClone: couldn't register \(name) (status \(status))")
                flash("Couldn't register \(name)—it may be used by another app")
            }
        }
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(withTitle: "Close window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit PasteClone", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Standard Edit menu: nil targets route to the first responder, so ⌘V/⌘C/⌘X/⌘A/⌘Z work in text fields.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select all", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Brief status-item notice (no alerts).
    private func flash(_ message: String) {
        guard let button = statusItem?.button else { return }
        button.toolTip = message
        button.title = " " + message
        flashToken += 1
        let token = flashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.refreshTitle()
        }
    }

    private var flashToken = 0

    private func refreshTitle() {
        guard let button = statusItem?.button else { return }
        flashToken += 1
        button.title = stackCount.map { " Stack: \($0)" } ?? ""
        button.toolTip = "PasteClone"
    }
}
