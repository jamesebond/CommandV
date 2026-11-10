import AppKit
import SwiftUI
import ImageIO
import PasteCore

@MainActor
private enum ImageCache {
    static let images = NSCache<NSString, NSImage>()
    static var sizes: [String: CGSize] = [:]
    static let icons = NSCache<NSString, NSImage>()
    static var missingApps = Set<String>()

    static func appIcon(bundleID: String) -> NSImage? {
        if let i = icons.object(forKey: "app:" + bundleID as NSString) { return i }
        if missingApps.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missingApps.insert(bundleID); return nil
        }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        icons.setObject(i, forKey: "app:" + bundleID as NSString)
        return i
    }

    static func fileIcon(path: String) -> NSImage {
        if let i = icons.object(forKey: "file:" + path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        icons.setObject(i, forKey: "file:" + path as NSString)
        return i
    }

    static func image(_ path: String) -> NSImage? {
        if let i = images.object(forKey: path as NSString) { return i }
        guard let i = NSImage(contentsOfFile: path) else { return nil }
        images.setObject(i, forKey: path as NSString)
        return i
    }

    static func pixelSize(_ path: String) -> CGSize? {
        if let s = sizes[path] { return s }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let s = CGSize(width: w, height: h)
        sizes[path] = s
        return s
    }
}

struct ClipCardView: View {
    let clip: Clip
    let selected: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            body_
            footer
        }
        .frame(width: Theme.cardWidth, height: Theme.cardHeight)
        .background(Theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
        )
        // A hairline keeps the dark surface distinct from the dark panel; the shadow does that in light mode.
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(selected ? 0 : 0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ClipPresentation.typeName(clip.kind))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text(ClipPresentation.relativeTimeString(from: clip.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 4)
            if let icon = sourceIcon {
                Image(nsImage: icon).resizable().frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.headerHeight)
        .background(Theme.headerColor(clip.kind))
    }

    private var sourceIcon: NSImage? {
        guard let id = clip.sourceBundleID else { return nil }
        return ImageCache.appIcon(bundleID: id)
    }

    private var body_: some View {
        Group {
            switch clip.kind {
            case .text, .richText: textBody(clip.text ?? "")
            case .color: colorBody
            case .image: imageBody
            case .link: linkBody
            case .file: fileBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func textBody(_ s: String) -> some View {
        Text(s.prefix(600))
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .lineLimit(8)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
    }

    private var colorBody: some View {
        VStack(spacing: 8) {
            if let c = Theme.color(hex: clip.text ?? "") {
                RoundedRectangle(cornerRadius: 8).fill(c).frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
            }
            Text(clip.text ?? "").font(.system(size: 13, design: .monospaced)).foregroundStyle(.primary)
        }
        .padding(12)
    }

    @ViewBuilder private var imageBody: some View {
        if let p = clip.thumbPath ?? clip.blobPath, let img = ImageCache.image(p) {
            Color.clear.overlay(
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            ).clipped()
        } else {
            Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(.tertiary)
        }
    }

    private var linkBody: some View {
        let text = clip.text ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            Text(ClipPresentation.domain(of: text))
                .font(.system(size: 15, weight: .bold))
                .lineLimit(2)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    private var fileBody: some View {
        let paths = ClipPresentation.filePaths(clip.text)
        return VStack(spacing: 8) {
            if let first = paths.first {
                Image(nsImage: ImageCache.fileIcon(path: first)).resizable().frame(width: 64, height: 64)
                Text((first as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if paths.count > 1 {
                    Text("and \(paths.count - 1) more").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private var footer: some View {
        var size: (Int, Int)?
        if clip.kind == .image, let p = clip.blobPath ?? clip.thumbPath, let s = ImageCache.pixelSize(p) {
            size = (Int(s.width), Int(s.height))
        }
        return Text(ClipPresentation.footerText(kind: clip.kind, text: clip.text, pixelSize: size))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
    }
}
