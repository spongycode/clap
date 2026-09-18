import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ImageIO

/// Generates QR code PNGs for clipboard content — scannable and shareable
/// to phones without any network dependency.
public enum QRCodeBuilder {

    /// QR byte capacity at level "M"; beyond this the payload won't fit.
    public static let maxPayloadBytes = 2_000

    /// True when `text` can be encoded (non-empty, within capacity).
    public static func canEncode(_ text: String) -> Bool {
        let payload = Data(text.utf8)
        return !payload.isEmpty && payload.count <= maxPayloadBytes
    }

    /// Renders `text` as a QR code PNG. Returns nil for empty or oversized
    /// payloads (or the unlikely case generation fails).
    public static func pngData(for text: String, pixelScale: Int = 8) -> Data? {
        let payload = Data(text.utf8)
        guard !payload.isEmpty, payload.count <= maxPayloadBytes else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: CGFloat(pixelScale), y: CGFloat(pixelScale)))

        guard let cgImage = Self.context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return pngData(from: cgImage)
    }

    private static let context = CIContext()

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
