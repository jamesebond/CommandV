import Testing
import Foundation
@testable import PasteCore

private func makeStore() throws -> ClipStore {
    let path = NSTemporaryDirectory() + "paste-\(UUID().uuidString).sqlite"
    return try ClipStore(path: path)
}

private func clip(_ text: String, hash: String? = nil) -> Clip {
    Clip(id: 0, kind: .text, text: text, blobPath: nil, thumbPath: nil,
         sourceBundleID: "com.test", sourceName: "Test", createdAt: Date(),
         pinboardID: nil, ocrText: nil, contentHash: hash ?? text)
}

@Suite struct ClipStoreTests {
    @Test func insertThenRecentReturnsNewestFirst() throws {
        let s = try makeStore()
        _ = try s.insert(clip("A"))
        _ = try s.insert(clip("B"))
        #expect(try s.recent(limit: 10, offset: 0).map(\.text) == ["B", "A"])
    }

    @Test func duplicateHashMovesExistingToFront() throws {
        let s = try makeStore()
        _ = try s.insert(clip("A"))
        _ = try s.insert(clip("B"))
        _ = try s.insert(clip("A"))
        let rows = try s.recent(limit: 10, offset: 0)
        #expect(rows.count == 2)
        #expect(rows.first?.text == "A")
    }

    @Test func deleteRemovesRow() throws {
        let s = try makeStore()
        let a = try s.insert(clip("A"))
        try s.delete(id: a.id)
        #expect(try s.recent(limit: 10, offset: 0).isEmpty)
    }

    @Test func pinboardAssignmentPersists() throws {
        let s = try makeStore()
        let a = try s.insert(clip("A"))
        let p = try s.addPinboard(name: "Work", colorHex: "#FF0000")
        try s.setPinboard(clipID: a.id, pinboardID: p.id)
        #expect(try s.recent(limit: 10, offset: 0).first?.pinboardID == p.id)
        #expect(try s.pinboards().map(\.name) == ["Work"])
        try s.deletePinboard(id: p.id)
        #expect(try s.recent(limit: 10, offset: 0).first?.pinboardID == nil)
    }

    @Test func ocrTextIsStored() throws {
        let s = try makeStore()
        let a = try s.insert(clip("A"))
        try s.setOCRText(clipID: a.id, text: "hello")
        #expect(try s.recent(limit: 1, offset: 0).first?.ocrText == "hello")
    }

    @Test func openFailureThrowsWithoutCrashing() throws {
        // A directory path makes sqlite3_open_v2 fail after a handle is allocated.
        let dir = NSTemporaryDirectory() + "paste-dir-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { _ = try ClipStore(path: dir) }
        #expect(throws: (any Error).self) { _ = try ClipStore(path: "/nonexistent-dir-xyz/h.sqlite") }
    }

    @Test func renamePinboardUpdatesName() throws {
        let s = try makeStore()
        let p = try s.addPinboard(name: "Work", colorHex: "#FF0000")
        try s.renamePinboard(id: p.id, name: "Home")
        let boards = try s.pinboards()
        #expect(boards.map(\.name) == ["Home"])
        #expect(boards.first?.colorHex == "#FF0000")
    }

    @Test func sourceAppsAreDistinctAndRecentFirst() throws {
        let s = try makeStore()
        func c(_ t: String, _ b: String?, _ n: String?, _ age: TimeInterval) -> Clip {
            Clip(kind: .text, text: t, sourceBundleID: b, sourceName: n,
                 createdAt: Date(timeIntervalSinceNow: -age), contentHash: t)
        }
        _ = try s.insert(c("1", "com.a", "Alpha", 30))
        _ = try s.insert(c("2", "com.b", "Beta", 20))
        _ = try s.insert(c("3", "com.a", "Alpha", 10))
        _ = try s.insert(c("4", nil, nil, 5))
        let apps = try s.sourceApps()
        #expect(apps.map(\.bundleID) == ["com.a", "com.b"])
        #expect(apps.map(\.name) == ["Alpha", "Beta"])
    }

    @Test func freshStoreHasSchemaVersion1() throws {
        let s = try makeStore()
        #expect(try s.userVersion() == ClipStore.currentSchemaVersion)
        #expect(try s.userVersion() == 1)
    }

    @Test func reopeningKeepsDataAndVersion() throws {
        let path = NSTemporaryDirectory() + "paste-\(UUID().uuidString).sqlite"
        do { let s = try ClipStore(path: path); _ = try s.insert(clip("A")) }
        let s2 = try ClipStore(path: path)
        #expect(try s2.recent(limit: 10, offset: 0).map(\.text) == ["A"])
        #expect(try s2.userVersion() == 1)
    }

    @Test func existingClipIDs() throws {
        let s = try makeStore()
        let a = try s.insert(clip("A")), b = try s.insert(clip("B"))
        try s.delete(id: a.id)
        #expect(try s.existingClipIDs(among: [a.id, b.id, 999]) == [b.id])
        #expect(try s.existingClipIDs(among: []).isEmpty)
    }
}
