import Foundation

public enum ClipKind: String, Sendable, Codable {
    case text, richText, link, image, file, color
}

public struct Clip: Identifiable, Sendable {
    public var id: Int64
    public var kind: ClipKind
    public var text: String?
    public var blobPath: String?
    public var thumbPath: String?
    public var sourceBundleID: String?
    public var sourceName: String?
    public var createdAt: Date
    public var pinboardID: Int64?
    public var ocrText: String?
    public var contentHash: String

    public init(id: Int64 = 0, kind: ClipKind, text: String? = nil, blobPath: String? = nil,
                thumbPath: String? = nil, sourceBundleID: String? = nil, sourceName: String? = nil,
                createdAt: Date = Date(), pinboardID: Int64? = nil, ocrText: String? = nil,
                contentHash: String) {
        self.id = id; self.kind = kind; self.text = text; self.blobPath = blobPath
        self.thumbPath = thumbPath; self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName; self.createdAt = createdAt; self.pinboardID = pinboardID
        self.ocrText = ocrText; self.contentHash = contentHash
    }
}

public struct Pinboard: Identifiable, Sendable {
    public var id: Int64
    public var name: String
    public var colorHex: String

    public init(id: Int64, name: String, colorHex: String) {
        self.id = id; self.name = name; self.colorHex = colorHex
    }
}
