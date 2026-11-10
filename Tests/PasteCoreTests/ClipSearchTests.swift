import Testing
import Foundation
@testable import PasteCore

private func makeStore() throws -> ClipStore {
    try ClipStore(path: NSTemporaryDirectory() + "paste-\(UUID().uuidString).sqlite")
}

private func mk(_ text: String?, kind: ClipKind = .text, bundle: String = "com.test",
                name: String = "Test", ocr: String? = nil, hash: String? = nil) -> Clip {
    Clip(kind: kind, text: text, sourceBundleID: bundle, sourceName: name, ocrText: ocr,
         contentHash: hash ?? (text ?? UUID().uuidString))
}

@Suite struct ClipSearchTests {
    @Test func prefixMatchFindsText() throws {
        let s = try makeStore()
        _ = try s.insert(mk("hello world"))
        _ = try s.insert(mk("other"))
        #expect(try s.search(ClipFilter(query: "hel"), limit: 10).map(\.text) == ["hello world"])
    }

    @Test func matchesOCRText() throws {
        let s = try makeStore()
        _ = try s.insert(mk(nil, kind: .image, ocr: "invoice 42", hash: "img"))
        #expect(try s.search(ClipFilter(query: "invoice"), limit: 10).count == 1)
    }

    @Test func kindFilterNarrows() throws {
        let s = try makeStore()
        _ = try s.insert(mk("alpha"))
        _ = try s.insert(mk("alpha link", kind: .link))
        let r = try s.search(ClipFilter(query: "alpha", kinds: [.link]), limit: 10)
        #expect(r.map(\.kind) == [.link])
    }

    @Test func sourceAppFilterNarrows() throws {
        let s = try makeStore()
        _ = try s.insert(mk("alpha", bundle: "com.a"))
        _ = try s.insert(mk("alpha two", bundle: "com.b"))
        let r = try s.search(ClipFilter(query: "alpha", sourceBundleID: "com.b"), limit: 10)
        #expect(r.map(\.text) == ["alpha two"])
    }

    @Test func specialCharactersDoNotThrow() throws {
        let s = try makeStore()
        _ = try s.insert(mk("a-b foo"))
        for q in ["\"", "*", "a-b", "foo:"] {
            _ = try s.search(ClipFilter(query: q), limit: 10)
        }
    }

    @Test func emptyQueryReturnsRecent() throws {
        let s = try makeStore()
        _ = try s.insert(mk("A"))
        _ = try s.insert(mk("B"))
        #expect(try s.search(ClipFilter(), limit: 10).map(\.text) == ["B", "A"])
    }

    @Test func pinboardAndSinceFilters() throws {
        let s = try makeStore()
        let pb = try s.addPinboard(name: "P", colorHex: "#fff")
        let old = try s.insert(Clip(kind: .text, text: "old", createdAt: Date(timeIntervalSince1970: 1000), contentHash: "old"))
        let new = try s.insert(mk("new"))
        try s.setPinboard(clipID: new.id, pinboardID: pb.id)
        #expect(try s.search(ClipFilter(pinboardID: pb.id), limit: 10).map(\.id) == [new.id])
        #expect(try s.search(ClipFilter(since: Date(timeIntervalSince1970: 2000)), limit: 10).map(\.id) == [new.id])
        _ = old
    }

    @Test func ftsTriggersStayInSync() throws {
        let s = try makeStore()
        let c = try s.insert(mk(nil, kind: .image, hash: "x"))
        #expect(try s.search(ClipFilter(query: "zebra"), limit: 10).isEmpty)
        try s.setOCRText(clipID: c.id, text: "zebra crossing")
        #expect(try s.search(ClipFilter(query: "zebra"), limit: 10).count == 1)
        try s.setOCRText(clipID: c.id, text: "giraffe")
        #expect(try s.search(ClipFilter(query: "zebra"), limit: 10).isEmpty)
        #expect(try s.search(ClipFilter(query: "giraffe"), limit: 10).count == 1)
        try s.delete(id: c.id)
        #expect(try s.search(ClipFilter(query: "giraffe"), limit: 10).isEmpty)
    }
}
