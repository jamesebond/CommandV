import Foundation

/// Builds the item provider for dragging a card out of the panel. Creating it only stats files; blob bytes are
/// read inside the lazy load handlers, when a receiver asks (off the main thread).
public enum ClipDragProvider {
    public static func make(for clip: Clip) -> NSItemProvider {
        let plan = ClipContentResolver.dragPlan(clip)
        let p = NSItemProvider()
        for f in plan.dataFiles {
            let path = f.path
            p.registerDataRepresentation(forTypeIdentifier: f.typeIdentifier, visibility: .all) { done in
                do { done(try Data(contentsOf: URL(fileURLWithPath: path)), nil) } catch { done(nil, error) }
                return nil
            }
        }
        // Copy semantics (openInPlace false): the receiver gets its own copy, so a same-volume Finder drop
        // can't move the stored blob out of the blobs folder.
        for f in plan.copyFiles {
            let url = URL(fileURLWithPath: f.path)
            p.registerFileRepresentation(forTypeIdentifier: f.typeIdentifier, fileOptions: [], visibility: .all) { done in
                done(url, false, nil); return nil
            }
        }
        // File clips offer the user's own file. An NSItemProvider carries one URL, so multi-file clips offer the first.
        if let url = plan.fileURLs.first { p.registerObject(url as NSURL, visibility: .all) }
        if let s = plan.string { p.registerObject(s as NSString, visibility: .all) }
        let idData = ClipDragID.encode(clip.id)
        p.registerDataRepresentation(forTypeIdentifier: ClipDragID.typeIdentifier, visibility: .all) { done in
            done(idData, nil); return nil
        }
        return p
    }
}
