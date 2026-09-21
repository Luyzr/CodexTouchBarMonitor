import AppKit

/// Fixed colors and equilateral geometry; never rendered as a monochrome font glyph.
@MainActor enum WaitingIcon {
    static let image = makeImage(opacity: 1)
    static let dimmedImage = makeImage(opacity: 0.45)
    private static func makeImage(opacity: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let height = CGFloat(18) * sqrt(3) / 2
            let bottom = (20 - height) / 2
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: 10, y: bottom + height))
            triangle.line(to: NSPoint(x: 1, y: bottom))
            triangle.line(to: NSPoint(x: 19, y: bottom))
            triangle.close()
            NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: opacity).setFill()
            triangle.fill()
            NSColor.black.withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect: NSRect(x: 9, y: 7, width: 2, height: 6), xRadius: 0.5, yRadius: 0.5).fill()
            NSBezierPath(ovalIn: NSRect(x: 9, y: 4, width: 2, height: 2)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Waiting for your reply"
        return image
    }
}
