import AppKit
import ServiceManagement
import SwiftUI
import PasteCore

/// State and actions behind the settings window. AppDelegate supplies the closures that touch live objects.
@MainActor
final class SettingsModel: ObservableObject {
    enum ShortcutTarget { case panel, stack }

    @Published var panelShortcut: Shortcut
    @Published var stackShortcut: Shortcut
    @Published var excluded: [String]
    @Published var paused = false
    @Published var launchAtLogin = false
    @Published var launchMessage: String?
    @Published var historyMessage: String?
    /// Shared with the panel's toggle button, so both always agree and saved preferences never go stale.
    let appearance: AppearanceModel

    private let defaults: UserDefaults
    var store: ClipStore?
    /// Registers the shortcut live; throws with a user-facing message on failure.
    var applyShortcut: (ShortcutTarget, Shortcut) throws -> Void = { _, _ in }
    var applyPaused: (Bool) -> Void = { _ in }
    var applyExcluded: (Set<String>) -> Void = { _ in }
    /// Releases/restores the global hotkeys so the recorder can capture a combination that is currently in use.
    var suspendHotKeys: () -> Void = {}
    var resumeHotKeys: () -> Void = {}

    /// The one row currently recording (nil when none), its error message, and the single key monitor.
    @Published private(set) var recordingTarget: ShortcutTarget?
    @Published var recordingMessage: String?
    private var recordMonitor: Any?

    init(defaults: UserDefaults = .standard, appearance: AppearanceModel? = nil) {
        self.defaults = defaults
        self.appearance = appearance ?? AppearanceModel(defaults: defaults)
        let p = Preferences.load(from: defaults)
        panelShortcut = p.panelShortcut
        stackShortcut = p.stackShortcut
        excluded = p.excludedBundleIDs.sorted()
        refreshLaunchAtLogin()
    }

    var preferences: Preferences {
        Preferences(panelShortcut: panelShortcut, stackShortcut: stackShortcut, excludedBundleIDs: Set(excluded),
                    appearance: appearance.preference)
    }

    // MARK: General

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchMessage = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if on, SMAppService.mainApp.status == .requiresApproval {
                launchMessage = "Approve PasteClone in System Settings > General > Login Items."
            }
        } catch {
            launchMessage = "Couldn't change launch at login: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    func setPaused(_ value: Bool) {
        paused = value
        applyPaused(value)
    }

    // MARK: Shortcuts

    /// Returns an error message, or nil on success.
    func setShortcut(_ target: ShortcutTarget, _ new: Shortcut) -> String? {
        if let err = new.validationError { return err }
        let other = target == .panel ? stackShortcut : panelShortcut
        guard new != other else { return "\(new.displayString) is already used by the other shortcut." }
        do { try applyShortcut(target, new) } catch { return error.localizedDescription }
        switch target {
        case .panel: panelShortcut = new
        case .stack: stackShortcut = new
        }
        preferences.save(to: defaults)
        return nil
    }

    /// Starts recording for `target`, cancelling any other recording first, with exactly one monitor installed.
    func startRecording(_ target: ShortcutTarget) {
        stopRecording()
        recordingTarget = target
        recordingMessage = nil
        suspendHotKeys()
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleRecorded(event) }
            return nil
        }
    }

    func stopRecording() {
        if let m = recordMonitor { NSEvent.removeMonitor(m) }
        recordMonitor = nil
        guard recordingTarget != nil else { return }
        recordingTarget = nil
        resumeHotKeys()
    }

    private func handleRecorded(_ event: NSEvent) {
        guard let target = recordingTarget else { return }
        let mods = carbonModifiers(from: event.modifierFlags)
        if event.keyCode == 53 && mods == 0 { stopRecording(); return }   // Esc cancels
        let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
        // Hotkeys are suspended while recording, so resume before applying (re-registers the old combo,
        // which update() then replaces; on failure the old combo stays registered).
        resumeHotKeys()
        if let err = setShortcut(target, candidate) {
            recordingMessage = err
            suspendHotKeys()        // stay in recording mode so the user can try again
        } else {
            recordingMessage = nil
            recordingTarget = nil
            if let m = recordMonitor { NSEvent.removeMonitor(m) }
            recordMonitor = nil
        }
    }

    // MARK: Privacy

    private func commitExcluded(_ ids: Set<String>) {
        excluded = ids.sorted()
        preferences.save(to: defaults)
        applyExcluded(ids)
    }

    func removeExcluded(_ id: String) { commitExcluded(Set(excluded).subtracting([id])) }
    func resetExcluded() { commitExcluded(CaptureRules.defaultExcluded) }

    func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.message = "Choose an app whose copies PasteClone should never capture."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            historyMessage = nil
            let alert = NSAlert()
            alert.messageText = "Couldn't read that app's bundle ID"
            alert.informativeText = "\(url.lastPathComponent) doesn't declare a bundle identifier."
            alert.runModal()
            return
        }
        commitExcluded(Set(excluded).union([id]))
    }

    static func displayName(forBundleID id: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: History

    func clearHistory() {
        historyMessage = nil
        guard let store else { return }
        let count: Int
        do { count = try store.unpinnedClipCount() } catch { historyMessage = "Couldn't read history: \(error.localizedDescription)"; return }
        guard count > 0 else { historyMessage = "No unpinned clips to delete."; return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "This permanently deletes \(count) clip\(count == 1 ? "" : "s") and their saved images and files. Clips saved in pinboards are kept. This can't be undone."
        alert.addButton(withTitle: "Delete \(count) clip\(count == 1 ? "" : "s")")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let n = try store.deleteAll()
            historyMessage = "Deleted \(n) clip\(n == 1 ? "" : "s")."
            NotificationCenter.default.post(name: .clipStored, object: nil)
            NotificationCenter.default.post(name: .clipsDeleted, object: nil)
        } catch {
            historyMessage = "Couldn't clear history: \(error.localizedDescription)"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: Binding(get: { model.appearance.preference }, set: { model.appearance.set($0) })) {
                    Text("System").tag(AppearancePreference.system)
                    Text("Light").tag(AppearancePreference.light)
                    Text("Dark").tag(AppearancePreference.dark)
                }
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if let m = model.launchMessage { Text(m).font(.callout).foregroundStyle(.red) }
                Toggle("Pause capture", isOn: Binding(get: { model.paused }, set: { model.setPaused($0) }))
            }
            Section("Shortcuts") {
                ShortcutRow(model: model, title: "Open panel", target: .panel, shortcut: model.panelShortcut)
                ShortcutRow(model: model, title: "Toggle paste stack", target: .stack, shortcut: model.stackShortcut)
                Text("Click a shortcut, then press the new combination. Esc cancels.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Copies from these apps are never captured.").font(.callout).foregroundStyle(.secondary)
                List {
                    ForEach(model.excluded, id: \.self) { id in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(SettingsModel.displayName(forBundleID: id) ?? id)
                                if SettingsModel.displayName(forBundleID: id) != nil {
                                    Text(id).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button { model.removeExcluded(id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Remove")
                        }
                    }
                }
                .frame(minHeight: 110, idealHeight: 130)
                HStack {
                    Button("Add app…") { model.addExcludedApp() }
                    Button("Reset to defaults") { model.resetExcluded() }
                }
            }
            Section("History") {
                Button("Clear history…", role: .destructive) { model.clearHistory() }
                if let m = model.historyMessage { Text(m).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 700)
        .onAppear { model.refreshLaunchAtLogin() }
    }
}

/// Click-to-record shortcut button; recording state lives in the model so only one row records at a time.
struct ShortcutRow: View {
    @ObservedObject var model: SettingsModel
    let title: String
    let target: SettingsModel.ShortcutTarget
    let shortcut: Shortcut

    private var recording: Bool { model.recordingTarget == target }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button(recording ? "Press shortcut…" : shortcut.displayString) {
                    recording ? model.stopRecording() : model.startRecording(target)
                }
                .frame(minWidth: 110)
            }
            if recording, let m = model.recordingMessage { Text(m).font(.callout).foregroundStyle(.red) }
        }
        .onDisappear { if recording { model.stopRecording() } }
    }
}
