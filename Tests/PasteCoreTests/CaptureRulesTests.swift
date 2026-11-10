import XCTest
import AppKit
@testable import PasteCore

final class FakePasteboard: PasteboardReading, @unchecked Sendable {
    var changeCount = 0
    var store: [String: Data] = [:]
    var types: [String] { Array(store.keys) }
    func data(forType type: String) -> Data? { store[type] }
    var files: [URL] = []
    func fileURLs() -> [URL] { files }
    func setString(_ s: String) { store["public.utf8-plain-text"] = Data(s.utf8); changeCount += 1 }
}

final class CaptureRulesTests: XCTestCase {
    let rules = CaptureRules(excludedBundleIDs: CaptureRules.defaultExcluded)

    func testConcealedTypeRejected() {
        XCTAssertFalse(rules.shouldCapture(sourceBundleID: "com.apple.TextEdit",
                                           types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
    }
    func testExcludedBundleRejected() {
        XCTAssertFalse(rules.shouldCapture(sourceBundleID: "com.1password.1password", types: ["public.utf8-plain-text"]))
    }
    func testNormalTextAccepted() {
        XCTAssertTrue(rules.shouldCapture(sourceBundleID: "com.apple.TextEdit", types: ["public.utf8-plain-text"]))
    }

    private func makeMonitor(_ pb: FakePasteboard, _ store: ClipStore, _ got: Box) -> (ClipboardMonitor, DispatchQueue) {
        let cb = DispatchQueue(label: "test.cb")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = ClipboardMonitor(store: store, rules: rules, reader: pb, blobsDirectory: dir,
                                 sourceProvider: { nil }, callbackQueue: cb,
                                 onNewClip: { c in got.clips.append(c) })
        return (m, cb)
    }
    final class Box: @unchecked Sendable { var clips: [Clip] = [] }

    func testSelfWriteIgnored() throws {
        let store = try ClipStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db").path)
        let pb = FakePasteboard(); let got = Box()
        let (m, cb) = makeMonitor(pb, store, got)
        pb.setString("mine")
        m.markSelfWrite()
        m.poll(); m.drain(); cb.sync {}
        XCTAssertTrue(got.clips.isEmpty)
        pb.setString("theirs")
        m.poll(); m.drain(); cb.sync {}
        XCTAssertEqual(got.clips.count, 1)
        XCTAssertEqual(got.clips.first?.text, "theirs")
        XCTAssertEqual(got.clips.first?.kind, .text)
    }

    func testGenuineCopyAfterSelfWriteCaptured() throws {
        let store = try ClipStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db").path)
        let pb = FakePasteboard(); let got = Box()
        let (m, cb) = makeMonitor(pb, store, got)
        m.markSelfWrite()   // no write happened; must not swallow the next copy
        pb.setString("genuine")
        m.poll(); m.drain(); cb.sync {}
        XCTAssertEqual(got.clips.first?.text, "genuine")
    }

    func testMultiFileCopy() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pb = FakePasteboard()
        pb.files = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
        pb.changeCount = 1
        let c = clipFromPasteboard(pb, source: nil, blobsDirectory: dir)
        XCTAssertEqual(c?.kind, .file)
        XCTAssertEqual(c?.text, "/tmp/a.txt\n/tmp/b.txt")
        pb.files = [URL(fileURLWithPath: "/tmp/a.txt")]
        XCTAssertNotEqual(clipFromPasteboard(pb, source: nil, blobsDirectory: dir)?.contentHash, c?.contentHash)
    }

    func testOversizedRichTextFallsBackToPlain() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pb = FakePasteboard()
        pb.store["public.html"] = Data(("<b>" + String(repeating: "x", count: 6_000_000) + "</b>").utf8)
        pb.store["public.utf8-plain-text"] = Data("hello".utf8)
        let c = clipFromPasteboard(pb, source: nil, blobsDirectory: dir)
        XCTAssertEqual(c?.kind, .text)
        XCTAssertNil(c?.blobPath)
        pb.store["public.html"] = Data("<p>Hi <b>there</b></p>".utf8)
        pb.store["public.utf8-plain-text"] = nil
        let r = clipFromPasteboard(pb, source: nil, blobsDirectory: dir)
        XCTAssertEqual(r?.kind, .richText)
        XCTAssertEqual(r?.text, "Hi there")
    }

    func testConcealedAppearingMidFlightDropped() throws {
        let store = try ClipStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db").path)
        let pb = FakePasteboard(); let got = Box()
        let (m, cb) = makeMonitor(pb, store, got)
        pb.setString("secret")
        // Simulate the pasteboard changing between the main-thread check and the data read.
        pb.store["org.nspasteboard.ConcealedType"] = Data(); pb.changeCount += 1
        // poll now sees the concealed type up front; also covered by the re-check on the work queue.
        m.poll(); m.drain(); cb.sync {}
        XCTAssertTrue(got.clips.isEmpty)
    }

    func testPathologicalMarkupStripsQuickly() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for chunk in ["<script>", "<", "<<<<style>", "{\\\\b "] {
            let pb = FakePasteboard()
            let big = String(repeating: chunk, count: 3_000_000 / chunk.utf8.count)
            pb.store[chunk.hasPrefix("{") ? "public.rtf" : "public.html"] = Data(big.utf8)
            let start = Date()
            _ = clipFromPasteboard(pb, source: nil, blobsDirectory: dir)
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "chunk \(chunk)")
        }
    }

    func testKindsAndTextCap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pb = FakePasteboard()
        pb.setString("https://example.com/x")
        XCTAssertEqual(clipFromPasteboard(pb, source: nil, blobsDirectory: dir)?.kind, .link)
        pb.setString(String(repeating: "a", count: 2_000_000))
        let c = clipFromPasteboard(pb, source: nil, blobsDirectory: dir)
        XCTAssertEqual(c?.text?.utf8.count, 1_048_576)
        XCTAssertEqual(c?.contentHash.count, 64)
    }

    func testImageBlobAndThumb() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let img = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { r in
            NSColor.red.setFill(); r.fill(); return true }
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let pb = FakePasteboard(); pb.store["public.png"] = png; pb.changeCount = 1
        let c = clipFromPasteboard(pb, source: nil, blobsDirectory: dir)
        XCTAssertEqual(c?.kind, .image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: c?.blobPath ?? ""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: c?.thumbPath ?? ""))
    }
}
