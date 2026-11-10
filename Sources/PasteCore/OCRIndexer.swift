import Foundation
import Vision

private let maxOCRLength = 100_000

public func recognizeText(imagePath: String) async -> String {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .utility).async {
            guard FileManager.default.fileExists(atPath: imagePath) else { cont.resume(returning: ""); return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(url: URL(fileURLWithPath: imagePath), options: [:])
            do {
                try handler.perform([request])
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                cont.resume(returning: String(text.prefix(maxOCRLength)))
            } catch {
                cont.resume(returning: "")
            }
        }
    }
}

private let inFlightLock = NSLock()
nonisolated(unsafe) private var inFlight = Set<String>()

private func claimOCR(_ id: String) -> Bool { inFlightLock.withLock { inFlight.insert(id).inserted } }
private func releaseOCR(_ id: String) { inFlightLock.withLock { _ = inFlight.remove(id) } }

public struct OCRIndexer: Sendable {
    let store: ClipStore
    public init(store: ClipStore) { self.store = store }

    public func index(clip: Clip) async {
        guard clip.kind == .image, let path = clip.blobPath else { return }
        // Skip clips already OCRed ("" counts as done) and clips another task is OCRing right now.
        let key = "\(ObjectIdentifier(store).hashValue)-\(clip.id)"   // ids repeat across stores
        guard claimOCR(key) else { return }
        defer { releaseOCR(key) }
        // Checked after claiming the slot so two racing callers can't both pass it.
        guard (try? store.hasOCRText(clipID: clip.id)) == false else { return }
        let text = await recognizeText(imagePath: path)
        try? store.setOCRText(clipID: clip.id, text: text)
    }
}
