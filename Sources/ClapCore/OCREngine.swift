import Foundation
import Vision
import os

/// Injectable OCR seam so capture paths can be tested without Vision.
public protocol OCREngine: Sendable {
    func recognizeText(from imageData: Data) async -> String?
}

/// Apple Vision text recognition (accurate mode, no language correction).
/// The blocking Vision call runs on a utility queue so awaiting it never
/// blocks the store actor.
public struct VisionOCREngine: OCREngine {
    private static let logger = Logger(subsystem: ClapIdentity.bundleID, category: "ocr")

    public init() {}

    public func recognizeText(from imageData: Data) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.performOCR(imageData))
            }
        }
    }

    private static func performOCR(_ imageData: Data) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(data: imageData, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results else { return nil }
            let lines = observations
                .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return nil }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
