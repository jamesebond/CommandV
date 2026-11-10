import Foundation
import AppKit

/// A global keyboard shortcut in Carbon terms (virtual key code + Carbon modifier mask).
public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode; self.modifiers = modifiers
    }

    public static let carbonCmd: UInt32 = 0x0100
    public static let carbonShift: UInt32 = 0x0200
    public static let carbonOption: UInt32 = 0x0800
    public static let carbonControl: UInt32 = 0x1000

    /// ⇧⌘V
    public static let defaultPanel = Shortcut(keyCode: 9, modifiers: carbonShift | carbonCmd)
    /// ⇧⌘C
    public static let defaultStack = Shortcut(keyCode: 8, modifiers: carbonShift | carbonCmd)

    /// A user-facing reason this shortcut can't be used, or nil.
    public var validationError: String? { shortcutValidationError(keyCode: keyCode, modifiers: modifiers) }

    public var isValid: Bool { isValidShortcut(keyCode: keyCode, modifiers: modifiers) }

    /// For example "⇧⌘V".
    public var displayString: String { shortcutDisplayString(keyCode: keyCode, modifiers: modifiers) }
}

private let knownModifierMask = Shortcut.carbonCmd | Shortcut.carbonShift | Shortcut.carbonOption | Shortcut.carbonControl

/// Plain-⌘ combos that would break copy/paste, quitting, window management or app switching system-wide.
private let reservedCommandKeys: [UInt32: String] = [
    8: "⌘C", 9: "⌘V", 7: "⌘X", 0: "⌘A", 6: "⌘Z", 12: "⌘Q", 13: "⌘W", 4: "⌘H", 46: "⌘M", 49: "⌘Space", 48: "⌘Tab",
]

/// A global shortcut needs at least one of ⌘, ⌥ or ⌃ (Shift alone would swallow capital letters), only known
/// modifier bits, a real (non-modifier) key, and must not be a reserved system combo such as ⌘C or ⌘Q.
public func isValidShortcut(keyCode: UInt32, modifiers: UInt32) -> Bool {
    shortcutValidationError(keyCode: keyCode, modifiers: modifiers) == nil
}

/// A user-facing reason the combo can't be used, or nil when it's acceptable.
public func shortcutValidationError(keyCode: UInt32, modifiers: UInt32) -> String? {
    let needsModifier = "Use at least one of ⌘, ⌥ or ⌃ with a key."
    guard modifiers & ~knownModifierMask == 0 else { return needsModifier }
    guard modifiers & (Shortcut.carbonCmd | Shortcut.carbonOption | Shortcut.carbonControl) != 0 else { return needsModifier }
    guard keyCode <= 0x7E, !modifierKeyCodes.contains(keyCode) else { return "Pick a key other than a modifier." }
    if modifiers == Shortcut.carbonCmd, let name = reservedCommandKeys[keyCode] {
        return "\(name) is reserved by macOS and apps. Try adding ⇧, ⌥ or ⌃."
    }
    return nil
}

private let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

public func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= Shortcut.carbonCmd }
    if flags.contains(.shift) { m |= Shortcut.carbonShift }
    if flags.contains(.option) { m |= Shortcut.carbonOption }
    if flags.contains(.control) { m |= Shortcut.carbonControl }
    return m
}

private let keyNames: [UInt32: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
    13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
    24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
    35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
    47: ".", 50: "`", 36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 115: "↖", 119: "↘",
    116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
    109: "F10", 103: "F11", 111: "F12",
]

public func shortcutDisplayString(keyCode: UInt32, modifiers: UInt32) -> String {
    var s = ""
    if modifiers & Shortcut.carbonControl != 0 { s += "⌃" }
    if modifiers & Shortcut.carbonOption != 0 { s += "⌥" }
    if modifiers & Shortcut.carbonShift != 0 { s += "⇧" }
    if modifiers & Shortcut.carbonCmd != 0 { s += "⌘" }
    return s + (keyNames[keyCode] ?? "Key \(keyCode)")
}

/// App-wide light/dark choice. `system` follows macOS until the user picks one.
public enum AppearancePreference: String, CaseIterable, Sendable {
    case system, light, dark
}

/// Persisted user preferences (shortcuts, capture exclusions and appearance).
public struct Preferences: Equatable, Sendable {
    public var panelShortcut: Shortcut
    public var stackShortcut: Shortcut
    public var excludedBundleIDs: Set<String>
    public var appearance: AppearancePreference

    public init(panelShortcut: Shortcut = .defaultPanel, stackShortcut: Shortcut = .defaultStack,
                excludedBundleIDs: Set<String> = CaptureRules.defaultExcluded,
                appearance: AppearancePreference = .system) {
        self.panelShortcut = panelShortcut; self.stackShortcut = stackShortcut
        self.excludedBundleIDs = excludedBundleIDs; self.appearance = appearance
    }

    public static let appearanceKey = "appearancePreference"

    public static func encode(appearance: AppearancePreference) -> String { appearance.rawValue }

    /// Missing or unknown values mean "follow the system".
    public static func decodeAppearance(_ raw: String?) -> AppearancePreference {
        raw.flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    public static func loadAppearance(from defaults: UserDefaults = .standard) -> AppearancePreference {
        decodeAppearance(defaults.string(forKey: appearanceKey))
    }

    public static func save(appearance: AppearancePreference, to defaults: UserDefaults = .standard) {
        defaults.set(encode(appearance: appearance), forKey: appearanceKey)
    }

    static let panelKey = "panelShortcut"
    static let stackKey = "stackShortcut"
    static let excludedKey = "excludedBundleIDs"
    static let knownDefaultsKey = "knownDefaultExclusions"

    /// Defaults that existed before `knownDefaultExclusions` was persisted, for lists saved by older versions.
    static let legacyKnownDefaults: Set<String> = CaptureRules.defaultExcluded.subtracting(["com.apple.Passwords"])

    public static func encode(_ shortcut: Shortcut) -> Data? { try? JSONEncoder().encode(shortcut) }

    /// Returns nil for corrupt data or a shortcut that fails validation.
    public static func decodeShortcut(_ data: Data?) -> Shortcut? {
        guard let data, let s = try? JSONDecoder().decode(Shortcut.self, from: data), s.isValid else { return nil }
        return s
    }

    public static func encode(excluded: Set<String>) -> Data? { try? JSONEncoder().encode(excluded.sorted()) }

    public static func decodeExcluded(_ data: Data?) -> Set<String>? {
        guard let data, let list = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Missing or corrupt values fall back to defaults. An explicitly saved empty exclusion list is preserved.
    public static func load(from defaults: UserDefaults = .standard) -> Preferences {
        var p = Preferences()
        p.appearance = loadAppearance(from: defaults)
        if let s = decodeShortcut(defaults.data(forKey: panelKey)) { p.panelShortcut = s }
        if let s = decodeShortcut(defaults.data(forKey: stackKey)) { p.stackShortcut = s }
        if let e = decodeExcluded(defaults.data(forKey: excludedKey)) {
            // Defaults added since this list was saved are merged in once; ones the user removed stay removed.
            let known = decodeExcluded(defaults.data(forKey: knownDefaultsKey)) ?? legacyKnownDefaults
            let added = CaptureRules.defaultExcluded.subtracting(known)
            p.excludedBundleIDs = e.union(added)
            if !added.isEmpty { p.save(to: defaults) }
        }
        if p.panelShortcut == p.stackShortcut { p.stackShortcut = .defaultStack; p.panelShortcut = .defaultPanel }
        return p
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(Self.encode(panelShortcut), forKey: Self.panelKey)
        defaults.set(Self.encode(stackShortcut), forKey: Self.stackKey)
        defaults.set(Self.encode(excluded: excludedBundleIDs), forKey: Self.excludedKey)
        defaults.set(Self.encode(excluded: CaptureRules.defaultExcluded), forKey: Self.knownDefaultsKey)
        Self.save(appearance: appearance, to: defaults)
    }
}
