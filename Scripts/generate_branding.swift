import AppKit
import CoreGraphics

func processAppIcon() {
    let sourcePath = CommandLine.arguments.count > 1
        ? (CommandLine.arguments[1] as NSString).expandingTildeInPath
        : "Resources/AppIcon.png"
    let sourceURL = URL(fileURLWithPath: sourcePath)
    guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print("Failed to load app image at \(sourcePath)")
        return
    }

    let width = cgImage.width
    let height = cgImage.height
    let bytesPerRow = width * 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    var pixelData = [UInt8](repeating: 0, count: width * height * 4)
    guard let ctx = CGContext(
        data: &pixelData,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        print("Failed context")
        return
    }

    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    // Remove cream background in-place using direct raw byte buffer
    for i in stride(from: 0, to: pixelData.count, by: 4) {
        let r = Double(pixelData[i]) / 255.0
        let g = Double(pixelData[i + 1]) / 255.0
        let b = Double(pixelData[i + 2]) / 255.0

        let dr = r - 0.93
        let dg = g - 0.93
        let db = b - 0.90
        let dist = sqrt(dr*dr + dg*dg + db*db)

        if dist < 0.05 {
            pixelData[i + 3] = 0 // transparent
        } else if dist < 0.09 {
            let alpha = (dist - 0.05) / 0.04
            pixelData[i] = UInt8(r * alpha * 255.0)
            pixelData[i + 1] = UInt8(g * alpha * 255.0)
            pixelData[i + 2] = UInt8(b * alpha * 255.0)
            pixelData[i + 3] = UInt8(alpha * 255.0)
        }
    }

    guard let processedCGImage = ctx.makeImage() else { return }

    let resourcesDir = URL(fileURLWithPath: "Resources")
    try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

    // Save master AppIcon.png
    let masterURL = resourcesDir.appendingPathComponent("AppIcon.png")
    if let dest = CGImageDestinationCreateWithURL(masterURL as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, processedCGImage, nil)
        CGImageDestinationFinalize(dest)
        print("Saved Resources/AppIcon.png")
    }

    // Build iconset
    let iconsetDir = URL(fileURLWithPath: "Resources/AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconsetDir)
    try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

    let sizes: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    for (name, px) in sizes {
        guard let scaleCtx = CGContext(
            data: nil,
            width: px,
            height: px,
            bitsPerComponent: 8,
            bytesPerRow: px * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { continue }

        scaleCtx.interpolationQuality = .high
        scaleCtx.draw(processedCGImage, in: CGRect(x: 0, y: 0, width: px, height: px))
        if let scaledImg = scaleCtx.makeImage() {
            let outURL = iconsetDir.appendingPathComponent(name)
            if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, scaledImg, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }

    // Convert iconset to icns
    let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
    try? p.run()
    p.waitUntilExit()
    print("Generated Resources/AppIcon.icns")
}

func generateMenuBarIcons() {
    let resourcesDir = URL(fileURLWithPath: "Resources")
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let size = 18 * scale
        guard let cg = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { continue }

        cg.clear(CGRect(x: 0, y: 0, width: size, height: size))

        let s = CGFloat(scale)
        cg.setFillColor(NSColor.black.cgColor)
        cg.setStrokeColor(NSColor.black.cgColor)

        // Clipboard body
        let boardX: CGFloat = 2.5 * s
        let boardY: CGFloat = 1.5 * s
        let boardW: CGFloat = 13.0 * s
        let boardH: CGFloat = 14.0 * s
        let corner: CGFloat = 2.2 * s

        let boardPath = CGPath(roundedRect: CGRect(x: boardX, y: boardY, width: boardW, height: boardH),
                               cornerWidth: corner, cornerHeight: corner, transform: nil)
        cg.addPath(boardPath)
        cg.fillPath()

        // Top Clip tab
        let clipW: CGFloat = 6.0 * s
        let clipH: CGFloat = 2.5 * s
        let clipX: CGFloat = (CGFloat(size) - clipW) / 2.0
        let clipY: CGFloat = boardY + boardH - (1.0 * s)
        let clipPath = CGPath(roundedRect: CGRect(x: clipX, y: clipY, width: clipW, height: clipH),
                              cornerWidth: 1.2 * s, cornerHeight: 1.2 * s, transform: nil)
        cg.addPath(clipPath)
        cg.fillPath()

        // Inner gap cutout
        cg.setBlendMode(.clear)
        let innerGapW: CGFloat = 4.4 * s
        let innerGapH: CGFloat = 1.2 * s
        let innerGapX: CGFloat = (CGFloat(size) - innerGapW) / 2.0
        let innerGapY: CGFloat = boardY + boardH - (2.4 * s)
        let innerGapPath = CGPath(roundedRect: CGRect(x: innerGapX, y: innerGapY, width: innerGapW, height: innerGapH),
                                  cornerWidth: 0.6 * s, cornerHeight: 0.6 * s, transform: nil)
        cg.addPath(innerGapPath)
        cg.fillPath()

        // Terminal prompt cutout `_ >`
        cg.setLineWidth(1.4 * s)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        // Chevron `>`
        let chvLeft = boardX + boardW - (4.0 * s)
        let chvMidX = boardX + boardW - (2.6 * s)
        let chvTopY = boardY + (5.8 * s)
        let chvMidY = boardY + (4.0 * s)
        let chvBotY = boardY + (2.2 * s)

        let chvPath = CGMutablePath()
        chvPath.move(to: CGPoint(x: chvLeft, y: chvTopY))
        chvPath.addLine(to: CGPoint(x: chvMidX, y: chvMidY))
        chvPath.addLine(to: CGPoint(x: chvLeft, y: chvBotY))
        cg.addPath(chvPath)
        cg.strokePath()

        // Underscore `_`
        let underLeft = boardX + boardW - (7.4 * s)
        let underRight = boardX + boardW - (4.8 * s)
        let underY = boardY + (2.2 * s)
        let underPath = CGMutablePath()
        underPath.move(to: CGPoint(x: underLeft, y: underY))
        underPath.addLine(to: CGPoint(x: underRight, y: underY))
        cg.addPath(underPath)
        cg.strokePath()

        if let img = cg.makeImage() {
            let outURL = resourcesDir.appendingPathComponent("MenuBarIcon\(suffix).png")
            if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
                print("Generated Resources/MenuBarIcon\(suffix).png (\(size)x\(size))")
            }
        }
    }
}

processAppIcon()
generateMenuBarIcons()
