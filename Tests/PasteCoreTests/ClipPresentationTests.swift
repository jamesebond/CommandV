import XCTest
@testable import PasteCore

final class ClipPresentationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testRelativeTime() {
        func s(_ secs: Double) -> String { ClipPresentation.relativeTimeString(from: now.addingTimeInterval(-secs), now: now) }
        XCTAssertEqual(s(3), "Just now")
        XCTAssertEqual(s(30), "30 seconds ago")
        XCTAssertEqual(s(60), "1 minute ago")
        XCTAssertEqual(s(300), "5 minutes ago")
        XCTAssertEqual(s(3600), "1 hour ago")
        XCTAssertEqual(s(7200), "2 hours ago")
        XCTAssertEqual(s(86400), "Yesterday")
        XCTAssertEqual(s(86400 * 3), "3 days ago")
        XCTAssertEqual(s(86400 * 14), "2 weeks ago")
        XCTAssertEqual(s(86400 * 60), "2 months ago")
        XCTAssertEqual(s(86400 * 800), "2 years ago")
        XCTAssertEqual(s(-50), "Just now")
    }

    func testFooters() {
        XCTAssertEqual(ClipPresentation.footerText(kind: .text, text: "hello"), "5 characters")
        XCTAssertEqual(ClipPresentation.footerText(kind: .text, text: "a"), "1 character")
        XCTAssertEqual(ClipPresentation.footerText(kind: .image, text: nil, pixelSize: (800, 600)), "800 × 600")
        XCTAssertEqual(ClipPresentation.footerText(kind: .link, text: "https://www.example.com/a?b=1"), "example.com")
        XCTAssertEqual(ClipPresentation.footerText(kind: .file, text: "/a/b.txt\n/c/d.png"), "2 files")
        XCTAssertEqual(ClipPresentation.footerText(kind: .file, text: "/a/b.txt"), "1 file")
    }

    func testTypeNames() {
        XCTAssertEqual(ClipPresentation.typeName(.richText), "Rich text")
        XCTAssertEqual(ClipPresentation.typeName(.color), "Color")
    }

    func testEscapeAction() {
        XCTAssertEqual(EscapeAction.forQuery(""), .closePanel)
        XCTAssertEqual(EscapeAction.forQuery("abc"), .clearSearch)
    }
}
