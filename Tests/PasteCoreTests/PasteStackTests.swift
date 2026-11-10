import Testing
import Foundation
import AppKit
@testable import PasteCore

private func clip(_ n: Int) -> Clip { Clip(kind: .text, text: "\(n)", contentHash: "h\(n)") }

@Suite struct PasteStackTests {
    @Test func removeClipIDs() {
        var s = PasteStack()
        for i in 1...4 { var c = clip(i); c.id = Int64(i); s.push(c) }
        #expect(s.remove(clipIDs: [2, 3, 99]) == 2)
        #expect(s.clipIDs == [1, 4])
        #expect(s.popNext()?.text == "1")
        #expect(s.remove(clipIDs: []) == 0)
    }

    @Test func fifoOrder() {
        var s = PasteStack()
        s.push(clip(1)); s.push(clip(2)); s.push(clip(3))
        #expect(s.isActive)
        #expect(s.popNext()?.text == "1")
        #expect(s.popNext()?.text == "2")
        #expect(s.popNext()?.text == "3")
        #expect(!s.isActive)
    }

    @Test func popOnEmptyReturnsNil() {
        var s = PasteStack()
        #expect(s.popNext() == nil)
    }

    @Test func clearDeactivates() {
        var s = PasteStack()
        s.push(clip(1))
        s.clear()
        #expect(!s.isActive)
        #expect(s.popNext() == nil)
    }

    @Test func recognizeMissingFileReturnsEmpty() async {
        #expect(await recognizeText(imagePath: "/nonexistent/x.png") == "")
    }

    private func renderInvoicePNG() throws -> String {
        let size = NSSize(width: 400, height: 120)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        ("invoice 42" as NSString).draw(at: NSPoint(x: 20, y: 30), withAttributes: [
            .font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        let png = rep.representation(using: .png, properties: [:])!
        let path = NSTemporaryDirectory() + "ocr-\(UUID().uuidString).png"
        try png.write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func recognizesRenderedText() async throws {
        let text = await recognizeText(imagePath: try renderInvoicePNG())
        #expect(text.lowercased().contains("invoice"))
    }

    @Test func indexIsNoOpForNonImageClip() async throws {
        let store = try ClipStore(path: NSTemporaryDirectory() + "paste-\(UUID().uuidString).sqlite")
        let c = try store.insert(Clip(kind: .text, text: "x", contentHash: "t"))
        await OCRIndexer(store: store).index(clip: c)
        #expect(try store.recent(limit: 1, offset: 0).first?.ocrText == nil)
    }

    @Test func indexStoresOCRTextForImageClipAndMakesItSearchable() async throws {
        let store = try ClipStore(path: NSTemporaryDirectory() + "paste-\(UUID().uuidString).sqlite")
        let path = try renderInvoicePNG()
        let c = try store.insert(Clip(kind: .image, blobPath: path, contentHash: "img"))
        await OCRIndexer(store: store).index(clip: c)
        let stored = try #require(try store.recent(limit: 1, offset: 0).first)
        #expect(stored.ocrText?.lowercased().contains("invoice") == true)
        #expect(try store.search(ClipFilter(query: "invoice"), limit: 10).map(\.id) == [c.id])
    }

    @Test func peekDoesNotRemoveAndEmptyOCRCountsAsDone() async throws {
        var st = PasteStack()
        st.push(clip(1))
        #expect(st.peekNext()?.text == "1")
        #expect(st.count == 1)

        // A blank image yields "" which is stored; it must not be OCRed again.
        let store = try ClipStore(path: NSTemporaryDirectory() + "paste-\(UUID().uuidString).sqlite")
        let size = NSSize(width: 50, height: 50)
        let img = NSImage(size: size)
        img.lockFocus(); NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill(); img.unlockFocus()
        let path = NSTemporaryDirectory() + "blank-\(UUID().uuidString).png"
        try NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: path))
        let c = try store.insert(Clip(kind: .image, blobPath: path, contentHash: "blank"))
        #expect(try !store.hasOCRText(clipID: c.id))
        await OCRIndexer(store: store).index(clip: c)
        #expect(try store.hasOCRText(clipID: c.id))
        #expect(try store.recent(limit: 1, offset: 0).first?.ocrText == "")
        try store.setOCRText(clipID: c.id, text: "sentinel")
        await OCRIndexer(store: store).index(clip: c)   // stale snapshot (ocrText nil) must still be skipped
        #expect(try store.recent(limit: 1, offset: 0).first?.ocrText == "sentinel")
        // Duplicate copy returns the existing row, already marked as OCRed.
        let dup = try store.insert(Clip(kind: .image, blobPath: path, contentHash: "blank"))
        #expect(dup.ocrText == "sentinel")
    }
}
