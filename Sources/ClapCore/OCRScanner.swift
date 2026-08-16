import Foundation
import Vision

/// Extracts text from images using Apple's built-in Vision framework (`VNRecognizeTextRequest`).
public enum OCRScanner {
    /// Extracts text lines from an image file URL.
    /// Returns multi-line text string or `nil` if no text is recognized.
    public static func recognizeText(from imageURL: URL) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(url: imageURL, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results, !observations.isEmpty else {
                return nil
            }
            let lines = observations
                .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return nil }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    /// Extracts text lines from raw image data (e.g. PNG / TIFF / JPEG).
    public static func recognizeText(from data: Data) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(data: data, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results, !observations.isEmpty else {
                return nil
            }
            let lines = observations
                .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return nil }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
