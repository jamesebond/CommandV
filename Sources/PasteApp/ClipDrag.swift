import AppKit
import UniformTypeIdentifiers
import PasteCore

enum ClipDrag {
    /// Private flavor read only by the pinboard tabs. Declared in Info.plist by scripts/bundle.sh. It is offered
    /// to every app (`.all`): a custom type is never inserted as text, and in-process-only delivery was unproven.
    static let clipIDType = UTType(exportedAs: ClipDragID.typeIdentifier, conformingTo: .data)

    static func provider(for clip: Clip) -> NSItemProvider { ClipDragProvider.make(for: clip) }
}
