import Testing
import Foundation
@testable import PasteCore

@Suite struct ClipContentTests {
    private func tempFile(_ name: String, _ bytes: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipcontent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url.path
    }

    private func clip(_ kind: ClipKind, text: String? = nil, blob: String? = nil) -> Clip {
        Clip(id: 7, kind: kind, text: text, blobPath: blob, contentHash: "h")
    }

    private func plan(_ c: Clip) -> ClipContentResolver.DragPlan { ClipContentResolver.dragPlan(c) }

    @Test func textLinkColorOfferTheString() {
        for kind in [ClipKind.text, .link, .color] {
            let p = plan(clip(kind, text: "hello"))
            #expect(p.string == "hello" && p.dataFiles.isEmpty && p.copyFiles.isEmpty && p.fileURLs.isEmpty)
        }
    }

    @Test func richTextOffersLazyHTMLPlusString() throws {
        let path = try tempFile("a.html", "<b>hi</b>")
        let p = plan(clip(.richText, text: "hi", blob: path))
        #expect(p.string == "hi")
        #expect(p.dataFiles == [.init(typeIdentifier: "public.html", path: path)])
        #expect(p.fileURLs.isEmpty && p.copyFiles.isEmpty)
        let rtf = try tempFile("a.rtf", "{\\rtf1 hi}")
        #expect(plan(clip(.richText, text: "hi", blob: rtf)).dataFiles.first?.typeIdentifier == "public.rtf")
        #expect(plan(clip(.richText, text: "hi", blob: "/nonexistent/x.html")).dataFiles.isEmpty)
        #expect(plan(clip(.richText, text: "hi", blob: "/nonexistent/x.html")).string == "hi")
    }

    @Test func imageOffersDataAndCopyFileButNeverAPlainURL() throws {
        for (name, uti) in [("a.png", "public.png"), ("a.tiff", "public.tiff"), ("a.jpg", "public.jpeg")] {
            let path = try tempFile(name, "bytes")
            let p = plan(clip(.image, blob: path))
            #expect(p.dataFiles == [.init(typeIdentifier: uti, path: path)])
            #expect(p.copyFiles == p.dataFiles)
            #expect(p.fileURLs.isEmpty && p.string == nil)
        }
        let gone = plan(clip(.image, blob: "/nonexistent/x.png"))
        #expect(gone.dataFiles.isEmpty && gone.copyFiles.isEmpty && gone.string == nil)
    }

    @Test func fileOffersURLsOrFallsBackToPaths() throws {
        let a = try tempFile("a.txt", "a"), b = try tempFile("b.txt", "b")
        let p = plan(clip(.file, text: a + "\n" + b))
        #expect(p.fileURLs == [URL(fileURLWithPath: a), URL(fileURLWithPath: b)])
        #expect(p.string == nil)
        let gone = plan(clip(.file, text: "/nonexistent/z.txt"))
        #expect(gone.fileURLs.isEmpty && gone.string == "/nonexistent/z.txt")
    }

    @Test func plainTextPasteUsesFileNames() {
        let c = ClipContentResolver.resolve(clip(.file, text: "/x/a.txt\n/y/b.txt"), plainText: true)
        #expect(c == ClipContent(string: "a.txt\nb.txt"))
    }

    @Test func dragIDRoundTrip() {
        #expect(ClipDragID.decode(ClipDragID.encode(42)) == 42)
        #expect(ClipDragID.decode(Data("abc".utf8)) == nil)
        #expect(ClipDragID.decode(Data("-3".utf8)) == nil)
        #expect(ClipDragID.decode(nil) == nil)
    }

    // MARK: provider introspection

    private func load(_ p: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { c in p.loadDataRepresentation(forTypeIdentifier: type) { d, _ in c.resume(returning: d) } }
    }

    @Test func providerForTextOffersTextAndPrivateID() async {
        let p = ClipDragProvider.make(for: clip(.text, text: "hello"))
        #expect(Set(p.registeredTypeIdentifiers) == ["public.utf8-plain-text", ClipDragID.typeIdentifier])
        #expect(await load(p, ClipDragID.typeIdentifier).flatMap { ClipDragID.decode($0) } == 7)
    }

    @Test func providerForImageUsesACopyNotTheBlobURL() async throws {
        let path = try tempFile("img.png", "pngbytes")
        let p = ClipDragProvider.make(for: clip(.image, blob: path))
        #expect(p.registeredTypeIdentifiers.contains("public.png"))
        #expect(!p.registeredTypeIdentifiers.contains("public.file-url"))
        #expect(p.registeredTypeIdentifiers.contains(ClipDragID.typeIdentifier))
        #expect(await load(p, "public.png") == Data("pngbytes".utf8))
        let received: URL? = await withCheckedContinuation { c in
            p.loadFileRepresentation(forTypeIdentifier: "public.png") { url, _ in
                guard let url else { c.resume(returning: nil); return }
                c.resume(returning: url)
            }
        }
        // The receiver's URL must be its own copy, not the stored blob.
        let url = try #require(received)
        #expect(url.standardizedFileURL.path != URL(fileURLWithPath: path).standardizedFileURL.path)
        // A real file representation keeps the blob's file name; a data-flavor temp file would not.
        #expect(url.lastPathComponent == "img.png")
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func providerForFileClipOffersFileURLOnly() throws {
        let a = try tempFile("own.txt", "x")
        let p = ClipDragProvider.make(for: clip(.file, text: a))
        #expect(p.registeredTypeIdentifiers.contains("public.file-url"))
        #expect(!p.registeredTypeIdentifiers.contains("public.utf8-plain-text"))
    }
}

@Suite struct DragOutcomeTests {
    @Test func clickOnlyNeverHides() {
        #expect(DragOutcome.decide(pasteboardChanged: false, movedDistance: 2, mouseOverPanel: true, panelIsKey: true, pinnedOnTab: false) == .clickOnly)
        #expect(DragOutcome.decide(pasteboardChanged: false, movedDistance: 6, mouseOverPanel: false, panelIsKey: false, pinnedOnTab: false) == .clickOnly)
    }
    @Test func realDragOutsideHides() {
        #expect(DragOutcome.decide(pasteboardChanged: true, movedDistance: 0, mouseOverPanel: false, panelIsKey: true, pinnedOnTab: false) == .hide)
        #expect(DragOutcome.decide(pasteboardChanged: false, movedDistance: 300, mouseOverPanel: true, panelIsKey: false, pinnedOnTab: false) == .hide)
    }
    @Test func realDragOverPanelKeepsOpen() {
        #expect(DragOutcome.decide(pasteboardChanged: true, movedDistance: 50, mouseOverPanel: true, panelIsKey: true, pinnedOnTab: false) == .keepOpen)
    }
    @Test func pinnedOnTabKeepsOpen() {
        #expect(DragOutcome.decide(pasteboardChanged: true, movedDistance: 50, mouseOverPanel: false, panelIsKey: false, pinnedOnTab: true) == .keepOpen)
    }
}
