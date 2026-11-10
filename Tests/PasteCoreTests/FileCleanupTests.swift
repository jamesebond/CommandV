import Testing
import Foundation
import AppKit
@testable import PasteCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("blobs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func imageClip(_ name: String, in dir: URL) throws -> Clip {
    let blob = dir.appendingPathComponent("\(name).png"), thumb = dir.appendingPathComponent("\(name)-thumb.png")
    try Data("x".utf8).write(to: blob); try Data("y".utf8).write(to: thumb)
    return Clip(kind: .image, blobPath: blob.path, thumbPath: thumb.path, contentHash: name)
}

@Suite struct FileCleanupTests {
    @Test func deleteWithFilesRemovesBlobAndThumb() throws {
        let dir = try tempDir()
        let s = try ClipStore(path: dir.appendingPathComponent("db.sqlite").path)
        let c = try s.insert(try imageClip("a", in: dir))
        try s.deleteWithFiles(id: c.id, blobsDirectory: dir)
        #expect(try s.recent(limit: 10, offset: 0).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: c.blobPath!))
        #expect(!FileManager.default.fileExists(atPath: c.thumbPath!))
    }

    @Test func doesNotDeleteOutsideBlobsDirectory() throws {
        let dir = try tempDir(), other = try tempDir()
        let s = try ClipStore(path: dir.appendingPathComponent("db.sqlite").path)
        let victim = other.appendingPathComponent("precious.txt")
        try Data("keep".utf8).write(to: victim)
        let traversal = dir.path + "/../" + other.lastPathComponent + "/precious.txt"
        let c = try s.insert(Clip(kind: .image, blobPath: victim.path, thumbPath: traversal, contentHash: "t"))
        try s.deleteWithFiles(id: c.id, blobsDirectory: dir)
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func deleteAllRemovesFilesKeepsPinboardsAndPinnedClips() throws {
        let dir = try tempDir()
        let s = try ClipStore(path: dir.appendingPathComponent("db.sqlite").path)
        let pb = try s.addPinboard(name: "Keep", colorHex: "#FF0000")
        let a = try s.insert(try imageClip("a", in: dir)), b = try s.insert(try imageClip("b", in: dir))
        let pinned = try s.insert(try imageClip("p", in: dir))
        try s.setPinboard(clipID: pinned.id, pinboardID: pb.id)
        _ = try s.insert(Clip(kind: .text, text: "hi", contentHash: "t"))
        #expect(try s.clipCount() == 4)
        #expect(try s.unpinnedClipCount() == 3)
        #expect(try s.deleteAll(blobsDirectory: dir) == 3)
        #expect(try s.clipCount() == 1)
        for c in [a, b] {
            #expect(!FileManager.default.fileExists(atPath: c.blobPath!))
            #expect(!FileManager.default.fileExists(atPath: c.thumbPath!))
        }
        #expect(FileManager.default.fileExists(atPath: pinned.blobPath!))
        #expect(FileManager.default.fileExists(atPath: pinned.thumbPath!))
        #expect(try s.recent(limit: 10, offset: 0).map(\.id) == [pinned.id])
        #expect(try s.pinboards().count == 1)
    }
}

private struct PNGBoard: PasteboardReading {
    let png: Data
    var changeCount: Int { 1 }
    var types: [String] { ["public.png"] }
    func data(forType type: String) -> Data? { type == "public.png" ? png : nil }
    func fileURLs() -> [URL] { [] }
}

@Suite struct BlobsDirectoryTests {
    @Test func defaultBlobsDirectoryIsAppSupportCommandVBlobs() {
        let expected = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CommandV/blobs", isDirectory: true)
        #expect(defaultBlobsDirectory() == expected)
    }

    /// Files written by the capture path are removed by the delete path when both use the same directory
    /// (both default to `defaultBlobsDirectory()`).
    @Test func filesWrittenByCaptureAreDeletedByStore() throws {
        let dir = try tempDir()
        let img = NSImage(size: NSSize(width: 8, height: 8))
        img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); img.unlockFocus()
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let built = try #require(clipFromPasteboard(PNGBoard(png: png), source: nil, blobsDirectory: dir))
        let s = try ClipStore(path: dir.appendingPathComponent("db.sqlite").path)
        let c = try s.insert(built)
        #expect(FileManager.default.fileExists(atPath: c.blobPath!))
        #expect(FileManager.default.fileExists(atPath: c.thumbPath!))
        try s.deleteWithFiles(id: c.id, blobsDirectory: dir)
        #expect(!FileManager.default.fileExists(atPath: c.blobPath!))
        #expect(!FileManager.default.fileExists(atPath: c.thumbPath!))
    }
}
