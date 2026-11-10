import Foundation

/// One serialized flavor of a clip, keyed by a public uniform type identifier (e.g. "public.png").
public struct ClipRepresentation: Equatable, Sendable {
    public let typeIdentifier: String
    public let data: Data
    public init(typeIdentifier: String, data: Data) {
        self.typeIdentifier = typeIdentifier; self.data = data
    }
}

/// What a clip puts on a pasteboard or drag: optional plain string, data flavors, and file URLs.
public struct ClipContent: Equatable, Sendable {
    public var string: String?
    public var representations: [ClipRepresentation]
    public var fileURLs: [URL]

    public init(string: String? = nil, representations: [ClipRepresentation] = [], fileURLs: [URL] = []) {
        self.string = string; self.representations = representations; self.fileURLs = fileURLs
    }
}

public enum ClipContentResolver {
    public static let html = "public.html"
    public static let rtf = "public.rtf"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let jpeg = "public.jpeg"

    /// The content to paste, or nil when the saved blob or files are missing. `plainText` yields text only.
    public static func resolve(_ clip: Clip, plainText: Bool) -> ClipContent? {
        let text = clip.text ?? ""
        if plainText {
            if clip.kind == .file {
                return ClipContent(string: text.split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent }.joined(separator: "\n"))
            }
            return ClipContent(string: text)
        }
        switch clip.kind {
        case .text, .link, .color:
            return ClipContent(string: text)
        case .richText:
            guard let path = clip.blobPath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return ClipContent(string: text, representations: [ClipRepresentation(typeIdentifier: path.hasSuffix(".html") ? html : rtf, data: data)])
        case .image:
            guard let path = clip.blobPath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            let type = path.hasSuffix(".png") ? png : (path.hasSuffix(".tiff") ? tiff : jpeg)
            return ClipContent(representations: [ClipRepresentation(typeIdentifier: type, data: data)])
        case .file:
            let paths = text.split(separator: "\n").map(String.init)
            guard !paths.isEmpty, paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else { return nil }
            return ClipContent(fileURLs: paths.map { URL(fileURLWithPath: $0) })
        }
    }

    /// A flavor whose bytes are read lazily from `path` when a drop target asks for it.
    public struct LazyFile: Equatable, Sendable {
        public let typeIdentifier: String
        public let path: String
    }

    /// What a card drag offers, decided with `stat` calls only (no blob is read until a receiver asks).
    public struct DragPlan: Equatable, Sendable {
        public var string: String?
        /// Data flavors (rich text HTML/RTF, image data) loaded lazily from the stored blob.
        public var dataFiles: [LazyFile]
        /// Image blob offered as a copy-on-drop file representation, so a Finder drop can never move the stored blob.
        public var copyFiles: [LazyFile]
        /// The user's own files (file clips only), offered as plain file URLs.
        public var fileURLs: [URL]
    }

    public static func dragPlan(_ clip: Clip) -> DragPlan {
        let fm = FileManager.default
        let text = clip.text ?? ""
        func blob() -> String? { clip.blobPath.flatMap { fm.fileExists(atPath: $0) ? $0 : nil } }
        switch clip.kind {
        case .text, .link, .color:
            return DragPlan(string: text, dataFiles: [], copyFiles: [], fileURLs: [])
        case .richText:
            guard let path = blob() else { return DragPlan(string: text, dataFiles: [], copyFiles: [], fileURLs: []) }
            return DragPlan(string: text, dataFiles: [LazyFile(typeIdentifier: path.hasSuffix(".html") ? html : rtf, path: path)], copyFiles: [], fileURLs: [])
        case .image:
            guard let path = blob() else { return DragPlan(string: nil, dataFiles: [], copyFiles: [], fileURLs: []) }
            let f = LazyFile(typeIdentifier: path.hasSuffix(".png") ? png : (path.hasSuffix(".tiff") ? tiff : jpeg), path: path)
            return DragPlan(string: nil, dataFiles: [f], copyFiles: [f], fileURLs: [])
        case .file:
            let paths = text.split(separator: "\n").map(String.init)
            guard !paths.isEmpty, paths.allSatisfy({ fm.fileExists(atPath: $0) }) else {
                return DragPlan(string: text, dataFiles: [], copyFiles: [], fileURLs: [])
            }
            return DragPlan(string: nil, dataFiles: [], copyFiles: [], fileURLs: paths.map { URL(fileURLWithPath: $0) })
        }
    }
}

/// The private, in-process drag type that carries a clip's row id between the cards and the pinboard tabs.
public enum ClipDragID {
    public static let typeIdentifier = "com.commandv.clip-id"

    public static func encode(_ id: Int64) -> Data { Data(String(id).utf8) }

    public static func decode(_ data: Data?) -> Int64? {
        guard let data, let s = String(data: data, encoding: .utf8), let id = Int64(s), id > 0 else { return nil }
        return id
    }
}

/// What to do with the panel once a card "drag" ends. The drag closure can run at mouse-down, so a plain click
/// must be told apart from a real drag.
public enum DragOutcome: Equatable, Sendable {
    case clickOnly, keepOpen, hide

    /// Movement (points) beyond which a press counts as a drag even if the drag pasteboard didn't change.
    public static let dragThreshold: Double = 6

    public static func decide(pasteboardChanged: Bool, movedDistance: Double, mouseOverPanel: Bool,
                              panelIsKey: Bool, pinnedOnTab: Bool) -> DragOutcome {
        guard pasteboardChanged || movedDistance > dragThreshold else { return .clickOnly }
        if pinnedOnTab { return .keepOpen }
        return (!panelIsKey || !mouseOverPanel) ? .hide : .keepOpen
    }
}
