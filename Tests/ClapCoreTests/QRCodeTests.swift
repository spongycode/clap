import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import ClapCore

@Suite("QR code generation")
struct QRCodeTests {

    private func pngSize(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    @Test func generatesSquarePngForText() throws {
        let png = try #require(QRCodeBuilder.pngData(for: "https://clap.example/hello"))
        let size = try #require(pngSize(png))
        #expect(size.0 == size.1)
        #expect(size.0 >= 100)   // 21-module QR at 8x scale minimum
    }

    @Test func rejectsEmptyAndOversized() {
        #expect(QRCodeBuilder.pngData(for: "") == nil)
        #expect(QRCodeBuilder.pngData(for: String(repeating: "x", count: 3_000)) == nil)
    }

    @Test func largerScaleProducesLargerImage() throws {
        let small = try #require(QRCodeBuilder.pngData(for: "hi", pixelScale: 4))
        let large = try #require(QRCodeBuilder.pngData(for: "hi", pixelScale: 12))
        let smallWidth = try #require(pngSize(small)).0
        let largeWidth = try #require(pngSize(large)).0
        #expect(largeWidth > smallWidth)
    }
}
