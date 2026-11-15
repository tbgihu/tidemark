import AppKit

/// Draws the app icon (seen in notifications, Login Items and Finder): three level bars, like the menu bar's, on one
/// flat deep-sea blue. build.sh turns the .iconset into AppIcon.icns.
///
/// It follows Apple's macOS icon grid as far as a drawn .icns can: a 1024-point canvas, an 824-point squircle
/// (continuous corners, not circular arcs) centred on it, the artwork inside the grid's central area, and the drop
/// shadow drawn in. Like a Liquid Glass icon it has two layers, a flat background and a glyph that catches light on
/// its upper edge, with no detail that turns to noise at 16 points. Light, dark and tinted variants need an
/// Icon Composer asset compiled by Xcode, which a Command Line Tools build can't make, so macOS shows this one in
/// every appearance.
@MainActor
enum Icon {
    static func write(to iconset: URL) {
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try? png(pixels).write(to: iconset.appending(path: name))
            }
        }
    }

    private static func png(_ pixels: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 1024, height: 1024)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(pixel: 1024 / CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    static let blue = NSColor(srgbRed: 0.05, green: 0.30, blue: 0.52, alpha: 1)

    /// In a 1024-point canvas, `pixel` points to a pixel. Small sizes (64 pixels and less) drop the faint tracks and
    /// the rim, which would only blur.
    private static func draw(pixel: CGFloat) {
        let small = pixel >= 16
        let body = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = squircle(body)

        // Background layer: the shadow under the shape, then one flat colour.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        blue.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        // Glyph layer: three level bars, like the menu bar's, each a ruler-straight capsule filled from the left.
        // The bars span x 224–800, 96 points high with 64 between them, centred on the canvas. Their edges are
        // rounded to whole pixels at each size, so no edge is a blurred half pixel.
        func snap(_ value: CGFloat) -> CGFloat { (value / pixel).rounded() * pixel }
        let fills: [CGFloat] = [0.86, 0.62, 0.36]
        for (index, fraction) in fills.enumerated() {
            let top = 720 - CGFloat(index) * 160
            let track = NSRect(x: snap(224), y: snap(top - 96), width: snap(800) - snap(224), height: snap(top) - snap(top - 96))
            let radius = track.height / 2
            if !small {
                NSColor.white.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            }
            var level = track
            level.size.width = max(track.width * fraction, track.height)
            let bar = NSBezierPath(roundedRect: level, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            bar.addClip()
            // Lit from above: white at the top edge, a touch of the sea at the bottom.
            NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(srgbRed: 0.86, green: 0.93, blue: 0.98, alpha: 1)])!
                .draw(in: level, angle: -90)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()

        // The glass rim: a fine light edge, brightest at the top and fading out towards the bottom.
        guard !small else { return }
        NSGraphicsContext.saveGraphicsState()
        let edge = NSBezierPath()
        edge.append(shape)
        edge.append(squircle(body.insetBy(dx: 3, dy: 3)).reversed)
        edge.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
            .draw(in: body, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Apple's icon shape: a rounded square whose corners blend into the sides with continuous curvature, unlike
    /// circular arcs. Each corner is a superellipse arc 1.528 radii long, shaped to pass where a circular corner of
    /// `radius` would at 45°: the macOS template's 824-point shape with its 185.4-point corners.
    static func squircle(_ rect: NSRect, radius: CGFloat = 185.4) -> NSBezierPath {
        let reach = min(radius * 1.528665, rect.width / 2, rect.height / 2)
        // Where a circular corner is at 45°: radius × (1 − 1/√2) in from both sides.
        let exponent = log(0.5) / log(1 - radius * (1 - 1 / 2.squareRoot()) / reach)
        // Counterclockwise from the top right, each corner a quarter turn on from the last.
        let corners = [NSPoint(x: rect.maxX - reach, y: rect.maxY - reach), NSPoint(x: rect.minX + reach, y: rect.maxY - reach),
                       NSPoint(x: rect.minX + reach, y: rect.minY + reach), NSPoint(x: rect.maxX - reach, y: rect.minY + reach)]
        let path = NSBezierPath()
        for (index, centre) in corners.enumerated() {
            let start = CGFloat(index) * .pi / 2
            for step in 0...90 {
                let t = start + CGFloat(step) / 90 * .pi / 2
                let c = cos(t), s = sin(t)
                let point = NSPoint(x: centre.x + reach * copysign(pow(abs(c), 2 / exponent), c),
                                    y: centre.y + reach * copysign(pow(abs(s), 2 / exponent), s))
                path.isEmpty ? path.move(to: point) : path.line(to: point)
            }
        }
        path.close()
        return path
    }
}
