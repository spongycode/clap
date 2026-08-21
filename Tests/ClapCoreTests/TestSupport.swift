import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
@testable import ClapCore

/// Settable clock for deterministic timestamp control via ClipboardStore's
/// injected `now:`. Thread-safe: read on the store's executor, written from
/// test tasks.
final class TestClock: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<Date>(initialState: Date())

    var value: Date {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func advance(_ seconds: TimeInterval) {
        value = value.addingTimeInterval(seconds)
    }
}

/// Creates a store in a unique temp data dir, runs `body`, cleans up.
/// Pass a clock to drive timestamps deterministically.
func withStore<T>(clock: TestClock = TestClock(),
                  _ body: (ClipboardStore, URL) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clap-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try ClipboardStore(dataDir: dir, now: { clock.value })
    return try await body(store, dir)
}

/// Programmatically generates a solid-color PNG via CoreGraphics + ImageIO.
func makePNG(width: Int = 8, height: Int = 8, red: CGFloat = 1.0) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create CGContext") }
    context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { fatalError("could not make CGImage") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("could not create image destination") }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Reads the pixel dimensions of an image file.
func imagePixelSize(at url: URL) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (w, h)
}
