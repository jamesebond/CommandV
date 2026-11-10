import Foundation

/// Pure presentation helpers for clip cards (kept in PasteCore so they are unit-testable).
public enum ClipPresentation {
    /// "just now", "5 minutes ago", "2 hours ago", "yesterday", "3 days ago", ...
    public static func relativeTimeString(from date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 10 { return "Just now" }
        if s < 60 { return "\(s) seconds ago" }
        let m = s / 60
        if m < 60 { return m == 1 ? "1 minute ago" : "\(m) minutes ago" }
        let h = m / 60
        if h < 24 { return h == 1 ? "1 hour ago" : "\(h) hours ago" }
        let d = h / 24
        if d == 1 { return "Yesterday" }
        if d < 7 { return "\(d) days ago" }
        let w = d / 7
        if d < 30 { return w == 1 ? "1 week ago" : "\(w) weeks ago" }
        let mo = d / 30
        if d < 365 { return mo == 1 ? "1 month ago" : "\(mo) months ago" }
        let y = d / 365
        return y == 1 ? "1 year ago" : "\(y) years ago"
    }

    public static func typeName(_ kind: ClipKind) -> String {
        switch kind {
        case .text: "Text"
        case .richText: "Rich text"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        }
    }

    /// Domain of a URL string, without a leading "www.".
    public static func domain(of urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host else { return trimmed }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// File paths from a file clip's text (one path per line).
    public static func filePaths(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    /// Footer line for a card. `pixelSize` is only used for images.
    public static func footerText(kind: ClipKind, text: String?, pixelSize: (width: Int, height: Int)? = nil) -> String {
        switch kind {
        case .text, .richText, .color:
            let n = (text ?? "").count
            return n == 1 ? "1 character" : "\(n) characters"
        case .image:
            if let p = pixelSize { return "\(p.width) × \(p.height)" }
            return "Image"
        case .link:
            return domain(of: text ?? "")
        case .file:
            let n = filePaths(text).count
            return n == 1 ? "1 file" : "\(n) files"
        }
    }
}

/// What Esc does given the current search query.
public enum EscapeAction: Equatable, Sendable {
    case clearSearch, closePanel
    public static func forQuery(_ query: String) -> EscapeAction { query.isEmpty ? .closePanel : .clearSearch }
}
