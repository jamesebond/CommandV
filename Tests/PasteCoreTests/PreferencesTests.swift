import Testing
import Foundation
@testable import PasteCore

@Suite struct PreferencesTests {
    @Test func validation() {
        #expect(isValidShortcut(keyCode: 9, modifiers: Shortcut.carbonCmd | Shortcut.carbonShift))
        #expect(isValidShortcut(keyCode: 9, modifiers: Shortcut.carbonControl))
        #expect(!isValidShortcut(keyCode: 9, modifiers: 0))
        #expect(!isValidShortcut(keyCode: 9, modifiers: Shortcut.carbonShift))
        #expect(!isValidShortcut(keyCode: 55, modifiers: Shortcut.carbonCmd))   // modifier key itself
        #expect(!isValidShortcut(keyCode: 9, modifiers: Shortcut.carbonCmd | 0x4))
    }

    @Test func displayStrings() {
        #expect(Shortcut.defaultPanel.displayString == "⇧⌘V")
        #expect(Shortcut.defaultStack.displayString == "⇧⌘C")
        #expect(shortcutDisplayString(keyCode: 49, modifiers: Shortcut.carbonControl | Shortcut.carbonOption) == "⌃⌥Space")
    }

    @Test func roundTripAndDefaults() {
        let d = UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!
        #expect(Preferences.load(from: d) == Preferences())
        var p = Preferences()
        p.panelShortcut = Shortcut(keyCode: 38, modifiers: Shortcut.carbonCmd | Shortcut.carbonOption)
        p.excludedBundleIDs = ["com.example.secret"]
        p.save(to: d)
        #expect(Preferences.load(from: d) == p)
        p.excludedBundleIDs = []
        p.save(to: d)
        #expect(Preferences.load(from: d).excludedBundleIDs.isEmpty)
    }

    @Test func corruptOrInvalidFallsBack() {
        let d = UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!
        d.set(Data("garbage".utf8), forKey: "panelShortcut")
        d.set(Preferences.encode(Shortcut(keyCode: 9, modifiers: 0)), forKey: "stackShortcut")
        let p = Preferences.load(from: d)
        #expect(p.panelShortcut == .defaultPanel)
        #expect(p.stackShortcut == .defaultStack)
    }

    @Test func reservedCommandCombosRejected() {
        let cmd = Shortcut.carbonCmd
        for key: UInt32 in [8, 9, 7, 0, 6, 12, 13, 4, 46, 49, 48] {
            #expect(!isValidShortcut(keyCode: key, modifiers: cmd))
            #expect(shortcutValidationError(keyCode: key, modifiers: cmd)?.contains("reserved") == true)
        }
        // Adding another modifier makes them fine (the default is ⇧⌘V).
        #expect(isValidShortcut(keyCode: 9, modifiers: cmd | Shortcut.carbonShift))
        #expect(isValidShortcut(keyCode: 49, modifiers: cmd | Shortcut.carbonOption))
        #expect(isValidShortcut(keyCode: 9, modifiers: cmd | Shortcut.carbonOption))
        #expect(Shortcut(keyCode: 9, modifiers: cmd).validationError != nil)
        #expect(Shortcut.defaultPanel.validationError == nil)
    }

    @Test func newDefaultAddedToOldSavedList() {
        let d = UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!
        // A list saved by an older version: no Passwords, no knownDefaults key.
        let old = CaptureRules.defaultExcluded.subtracting(["com.apple.Passwords"]).union(["com.example.mine"])
        d.set(Preferences.encode(excluded: old), forKey: "excludedBundleIDs")
        let p = Preferences.load(from: d)
        #expect(p.excludedBundleIDs.contains("com.apple.Passwords"))
        #expect(p.excludedBundleIDs.contains("com.example.mine"))
        #expect(Preferences.load(from: d).excludedBundleIDs == p.excludedBundleIDs)
    }

    @Test func removedDefaultStaysRemoved() {
        let d = UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!
        var p = Preferences()
        p.excludedBundleIDs.remove("com.bitwarden.desktop")
        p.save(to: d)   // knownDefaults now includes bitwarden, the list doesn't
        #expect(!Preferences.load(from: d).excludedBundleIDs.contains("com.bitwarden.desktop"))
        // Legacy list that lacks a default the user removed (but also lacks the new Passwords one).
        let d2 = UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!
        let legacy = Preferences.legacyKnownDefaults.subtracting(["com.bitwarden.desktop"])
        d2.set(Preferences.encode(excluded: legacy), forKey: "excludedBundleIDs")
        let l = Preferences.load(from: d2).excludedBundleIDs
        #expect(l.contains("com.apple.Passwords"))
        #expect(!l.contains("com.bitwarden.desktop"))
    }

    @Test func passwordsIsDefaultExcluded() {
        #expect(CaptureRules.defaultExcluded.contains("com.apple.Passwords"))
    }
}

@Suite struct AppearancePreferenceTests {
    @Test func defaultsToSystem() {
        let d = UserDefaults(suiteName: "appearance-\(UUID().uuidString)")!
        #expect(Preferences().appearance == .system)
        #expect(Preferences.load(from: d).appearance == .system)
        #expect(Preferences.loadAppearance(from: d) == .system)
    }

    @Test func encodeDecodeAndPersist() {
        for a in AppearancePreference.allCases {
            #expect(Preferences.decodeAppearance(Preferences.encode(appearance: a)) == a)
        }
        #expect(Preferences.decodeAppearance("sepia") == .system)
        #expect(Preferences.decodeAppearance(nil) == .system)
        let d = UserDefaults(suiteName: "appearance-\(UUID().uuidString)")!
        Preferences.save(appearance: .dark, to: d)
        #expect(Preferences.load(from: d).appearance == .dark)
        var p = Preferences.load(from: d)
        p.appearance = .light
        p.save(to: d)
        #expect(Preferences.loadAppearance(from: d) == .light)
        #expect(d.string(forKey: "appearancePreference") == "light")
    }
}
