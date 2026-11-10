import Testing
import Foundation
@testable import PasteCore

@Suite struct LegacyDataMigrationTests {
    private func tempSupport() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func seedLegacy(_ support: URL, extraPath: String? = nil) throws -> (old: URL, blob: String, thumb: String) {
        let old = support.appendingPathComponent("PasteClone", isDirectory: true)
        let blobs = old.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("a.png"), thumb = blobs.appendingPathComponent("a_thumb.png")
        try Data("b".utf8).write(to: blob); try Data("t".utf8).write(to: thumb)
        let store = try ClipStore(path: old.appendingPathComponent("history.sqlite").path)
        _ = try store.insert(Clip(kind: .image, blobPath: blob.path, thumbPath: thumb.path, contentHash: "h1"))
        if let extraPath { _ = try store.insert(Clip(kind: .image, blobPath: extraPath, thumbPath: extraPath, contentHash: "h2")) }
        return (old, blob.path, thumb.path)
    }

    @Test func movesDirectoryAndRewritesPaths() throws {
        let support = try tempSupport(); defer { try? FileManager.default.removeItem(at: support) }
        let seeded = try seedLegacy(support)
        #expect(LegacyDataMigration.migrateIfNeeded(appSupport: support))
        let new = support.appendingPathComponent("CommandV", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: seeded.old.path))
        let store = try ClipStore(path: new.appendingPathComponent("history.sqlite").path)
        let clip = try #require(try store.recent(limit: 10, offset: 0).first)
        #expect(clip.blobPath == new.path + "/blobs/a.png")
        #expect(clip.thumbPath == new.path + "/blobs/a_thumb.png")
        #expect(FileManager.default.fileExists(atPath: try #require(clip.blobPath)))
        #expect(FileManager.default.fileExists(atPath: try #require(clip.thumbPath)))
    }

    @Test func noOpWhenNewDirectoryExists() throws {
        let support = try tempSupport(); defer { try? FileManager.default.removeItem(at: support) }
        let seeded = try seedLegacy(support)
        let new = support.appendingPathComponent("CommandV", isDirectory: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        #expect(!LegacyDataMigration.migrateIfNeeded(appSupport: support))
        #expect(FileManager.default.fileExists(atPath: seeded.old.appendingPathComponent("blobs/a.png").path))
        let store = try ClipStore(path: seeded.old.appendingPathComponent("history.sqlite").path)
        #expect(try store.recent(limit: 1, offset: 0).first?.blobPath == seeded.blob)
    }

    @Test func noOpWhenOldDirectoryMissing() throws {
        let support = try tempSupport(); defer { try? FileManager.default.removeItem(at: support) }
        #expect(!LegacyDataMigration.migrateIfNeeded(appSupport: support))
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("CommandV").path))
    }

    @Test func leavesUnrelatedPathsUntouched() throws {
        let support = try tempSupport(); defer { try? FileManager.default.removeItem(at: support) }
        let other = "/somewhere/else/PasteClone/blobs/x.png"
        _ = try seedLegacy(support, extraPath: other)
        #expect(LegacyDataMigration.migrateIfNeeded(appSupport: support))
        let new = support.appendingPathComponent("CommandV", isDirectory: true)
        let store = try ClipStore(path: new.appendingPathComponent("history.sqlite").path)
        let clips = try store.recent(limit: 10, offset: 0)
        #expect(clips.count == 2)
        #expect(clips.contains { $0.blobPath == other && $0.thumbPath == other })
        #expect(clips.contains { $0.blobPath == new.path + "/blobs/a.png" })
    }
}
