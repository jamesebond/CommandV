import Foundation
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

public protocol PasteboardReading: Sendable {
    var changeCount: Int { get }
    var types: [String] { get }
    func data(forType type: String) -> Data?
    func fileURLs() -> [URL]
}

public extension PasteboardReading {
    func fileURLs() -> [URL] {
        guard let d = data(forType: "public.file-url"), let s = String(data: d, encoding: .utf8),
              let url = URL(string: s), url.isFileURL else { return [] }
        return [url]
    }
}

public struct SystemPasteboard: PasteboardReading, @unchecked Sendable {
    let pb: NSPasteboard
    public init(_ pb: NSPasteboard = .general) { self.pb = pb }
    public var changeCount: Int { pb.changeCount }
    public var types: [String] { (pb.types ?? []).map(\.rawValue) }
    public func data(forType type: String) -> Data? { pb.data(forType: NSPasteboard.PasteboardType(type)) }
    public func fileURLs() -> [URL] {
        let objs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return objs ?? []
    }
}

public let maxTextBytes = 1_048_576
public let maxRichBlobBytes = 5_242_880

private let maxStripInputBytes = 262_144

/// Single-pass linear tag stripper (input capped); skips script/style bodies.
private func strippedHTML(_ d: Data) -> String {
    let bytes = [UInt8](d.prefix(maxStripInputBytes))
    var out = [UInt8](); out.reserveCapacity(bytes.count)
    var i = 0
    let n = bytes.count
    func lower(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
    func matches(_ at: Int, _ word: String) -> Bool {
        let w = Array(word.utf8)
        guard at + w.count <= n else { return false }
        for k in 0..<w.count where lower(bytes[at + k]) != w[k] { return false }
        return true
    }
    var skipping: String? = nil   // inside script/style body, waiting for its closing tag
    while i < n {
        let c = bytes[i]
        if c == 60 { // <
            if let tag = skipping {
                if matches(i + 1, "/" + tag) { skipping = nil } else { i += 1; continue }
            } else if matches(i + 1, "script") { skipping = "script" }
            else if matches(i + 1, "style") { skipping = "style" }
            // consume to '>' (or to end if none)
            var j = i + 1
            while j < n && bytes[j] != 62 { j += 1 }
            i = j + 1
            continue
        }
        if skipping == nil { out.append(c) }
        i += 1
    }
    var s = String(decoding: out, as: UTF8.self)
    for (e, r) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
        s = s.replacingOccurrences(of: e, with: r)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func strippedRTF(_ d: Data) -> String {
    var s = String(decoding: d.prefix(maxStripInputBytes), as: UTF8.self)
    s = s.replacingOccurrences(of: "\\\\[a-zA-Z]+-?\\d* ?|[{}]|\\\\'[0-9a-fA-F]{2}", with: "", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

public func defaultBlobsDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PasteClone/blobs", isDirectory: true)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func capped(_ s: String) -> String {
    guard s.utf8.count > maxTextBytes else { return s }
    var bytes = Array(s.utf8.prefix(maxTextBytes))
    // Trim to a valid UTF-8 boundary only if needed.
    while !bytes.isEmpty, String(validatingCString: bytes.map { CChar(bitPattern: $0) } + [0]) == nil { bytes.removeLast() }
    return String(decoding: bytes, as: UTF8.self)
}

/// Builds a clip from the pasteboard contents. Does blocking work (decode, hash, disk); call off the main thread.
public func clipFromPasteboard(_ pb: PasteboardReading, source: NSRunningApplication?,
                               blobsDirectory: URL = defaultBlobsDirectory()) -> Clip? {
    let bundleID = source?.bundleIdentifier
    let name = source?.localizedName
    func make(_ kind: ClipKind, text: String? = nil, blob: String? = nil, thumb: String? = nil, hash: String) -> Clip {
        Clip(kind: kind, text: text, blobPath: blob, thumbPath: thumb,
             sourceBundleID: bundleID, sourceName: name, contentHash: hash)
    }
    let fm = FileManager.default

    // 1. File URLs
    let files = pb.fileURLs()
    if !files.isEmpty {
        let paths = files.map(\.path).joined(separator: "\n")
        return make(.file, text: paths, hash: sha256(Data(("file:" + paths).utf8)))
    }

    // 2. Image
    for t in ["public.png", "public.tiff", "public.jpeg"] {
        guard let data = pb.data(forType: t), let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0 else { continue }
        let hash = sha256(data)
        try? fm.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
        let ext = t == "public.png" ? "png" : t == "public.jpeg" ? "jpg" : "tiff"
        let blob = blobsDirectory.appendingPathComponent("\(hash).\(ext)")
        let thumb = blobsDirectory.appendingPathComponent("\(hash)-thumb.png")
        if !fm.fileExists(atPath: blob.path) { try? data.write(to: blob, options: .atomic) }
        if !fm.fileExists(atPath: thumb.path) {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 320]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
               let dest = CGImageDestinationCreateWithURL(thumb as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        return make(.image, blob: blob.path,
                    thumb: fm.fileExists(atPath: thumb.path) ? thumb.path : nil, hash: hash)
    }

    let plain = pb.data(forType: "public.utf8-plain-text").flatMap { String(data: $0, encoding: .utf8) }

    // 3. Link
    var linkString: String? = nil
    if let d = pb.data(forType: "public.url"), let s = String(data: d, encoding: .utf8) { linkString = s }
    else if let p = plain?.trimmingCharacters(in: .whitespacesAndNewlines),
            !p.contains(where: \.isWhitespace), let u = URL(string: p),
            let scheme = u.scheme?.lowercased(), (scheme == "http" || scheme == "https"), u.host != nil { linkString = p }
    if let l = linkString {
        return make(.link, text: l, hash: sha256(Data(("link:" + l).utf8)))
    }

    // 4. Rich text
    for t in ["public.rtf", "public.html"] {
        if let d = pb.data(forType: t) {
            var text = plain
            if text == nil {
                // NSAttributedString import is main-thread-only; use cheap stripping instead.
                text = t == "public.rtf" ? strippedRTF(d) : strippedHTML(d)
            }
            let body = capped(text ?? "")
            if d.count > maxRichBlobBytes {
                // Too big to keep as rich text; fall back to the plain-text preview.
                if body.isEmpty { return nil }
                return make(.text, text: body, hash: sha256(Data(("text:" + body).utf8)))
            }
            try? fm.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
            let hash = sha256(d + Data("rich".utf8))
            let blob = blobsDirectory.appendingPathComponent("\(hash).\(t == "public.rtf" ? "rtf" : "html")")
            if !fm.fileExists(atPath: blob.path) { try? d.write(to: blob, options: .atomic) }
            return make(.richText, text: body, blob: blob.path, hash: hash)
        }
    }

    // 5. Plain text
    if let p = plain, !p.isEmpty {
        let t = capped(p)
        return make(.text, text: t, hash: sha256(Data(("text:" + t).utf8)))
    }
    return nil
}

public final class ClipboardMonitor: @unchecked Sendable {
    private let store: ClipStore
    private var rules: CaptureRules   // guarded by `lock`
    private let reader: PasteboardReading
    private let blobsDirectory: URL
    private let sourceProvider: @Sendable () -> NSRunningApplication?
    private let callbackQueue: DispatchQueue
    private let onNewClip: @Sendable (Clip) -> Void
    private let work = DispatchQueue(label: "pasteclone.monitor", qos: .utility)
    private let lock = NSLock()
    private var lastChangeCount: Int
    private var timer: Timer?

    public init(store: ClipStore, rules: CaptureRules,
                reader: PasteboardReading = SystemPasteboard(),
                blobsDirectory: URL = defaultBlobsDirectory(),
                sourceProvider: @escaping @Sendable () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
                callbackQueue: DispatchQueue = .main,
                onNewClip: @escaping @Sendable (Clip) -> Void) {
        self.store = store; self.rules = rules; self.reader = reader
        self.blobsDirectory = blobsDirectory; self.sourceProvider = sourceProvider
        self.callbackQueue = callbackQueue; self.onNewClip = onNewClip
        self.lastChangeCount = reader.changeCount
    }

    public func start() {
        stop()
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() { timer?.invalidate(); timer = nil }

    /// Replaces the capture rules; takes effect for the next poll.
    public func updateRules(_ newRules: CaptureRules) { lock.lock(); rules = newRules; lock.unlock() }

    private func currentRules() -> CaptureRules { lock.lock(); defer { lock.unlock() }; return rules }

    /// Call after the app writes to the pasteboard itself; changes up to now are treated as already seen.
    public func markSelfWrite() { lock.lock(); lastChangeCount = reader.changeCount; lock.unlock() }

    /// Cheap check on the caller's thread; heavy work runs on a background queue.
    public func poll() {
        let count = reader.changeCount
        lock.lock()
        guard count != lastChangeCount else { lock.unlock(); return }
        lastChangeCount = count
        lock.unlock()
        let types = reader.types
        let source = sourceProvider()
        guard currentRules().shouldCapture(sourceBundleID: source?.bundleIdentifier, types: types) else { return }
        work.async { [self] in
            guard let built = clipFromPasteboard(reader, source: source, blobsDirectory: blobsDirectory) else { return }
            // Re-validate: pasteboard may have changed (e.g. a password manager) since we checked.
            guard reader.changeCount == count,
                  currentRules().shouldCapture(sourceBundleID: source?.bundleIdentifier, types: reader.types) else { return }
            guard let clip = try? store.insert(built) else { return }
            let cb = onNewClip
            callbackQueue.async { cb(clip) }
        }
    }

    /// Waits for in-flight background work (for tests).
    public func drain() { work.sync {} }
}
