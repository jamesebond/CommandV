import AppKit
import Observation
import PasteCore

/// The app-wide light/dark choice. Applies it through `NSApp.appearance` (so the panel and Settings follow)
/// and persists it. Shared by the panel's toggle button and the Settings picker.
@MainActor @Observable
final class AppearanceModel {
    private(set) var preference: AppearancePreference
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = Preferences.loadAppearance(from: defaults)
    }

    func set(_ new: AppearancePreference) {
        preference = new
        Preferences.save(appearance: new, to: defaults)
        apply()
    }

    /// Switches to the opposite of what is on screen now (not of the stored value, which may be "system").
    func toggle(currentlyDark: Bool) { set(currentlyDark ? .light : .dark) }

    func apply() {
        switch preference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
