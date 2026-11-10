import AppKit
import SwiftUI
import PasteCore

enum Theme {
    static let cardWidth: CGFloat = 200
    static let cardHeight: CGFloat = 230
    static let headerHeight: CGFloat = 48
    static let cornerRadius: CGFloat = 12

    /// Card body: near-white in light mode, a raised dark gray in dark mode.
    static let cardSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.17, green: 0.17, blue: 0.19, alpha: 1)
            : NSColor(red: 0.99, green: 0.99, blue: 0.99, alpha: 1)
    })

    /// Header tint per clip kind.
    static func headerColor(_ kind: ClipKind) -> Color {
        switch kind {
        case .text: Color(red: 0.22, green: 0.48, blue: 0.93)      // blue
        case .image: Color(red: 0.90, green: 0.29, blue: 0.30)     // red
        case .link: Color(red: 0.20, green: 0.69, blue: 0.40)      // green
        case .file: Color(red: 0.42, green: 0.45, blue: 0.50)      // graphite
        case .richText: Color(red: 0.95, green: 0.67, blue: 0.13)  // amber
        case .color: Color(red: 0.61, green: 0.34, blue: 0.85)     // purple
        }
    }

    /// Parses "#RRGGBB" / "RRGGBB"; nil when not a hex color.
    static func color(hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
