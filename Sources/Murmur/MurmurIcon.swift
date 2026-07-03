import AppKit

/// Menu-bar icons drawn in code as template images: crisp at any scale,
/// automatically adapt to light/dark menu bars and the "reduce transparency"
/// setting. The motif is a four-bar whisper waveform.
@MainActor
enum MurmurIcon {

    /// Waveform bars — idle state.
    static let idle: NSImage = makeTemplate(name: "wisprrr-idle") { rect in
        drawBars(in: rect)
    }

    /// Waveform bars punched out of a filled circle — recording state,
    /// clearly distinct from idle at a glance.
    static let recording: NSImage = makeTemplate(name: "wisprrr-recording") { rect in
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        NSColor.black.setFill()
        circle.fill()
        NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
        drawBars(in: rect.insetBy(dx: 3.4, dy: 0))
        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
    }

    /// Four vertical rounded bars with whisper-wave heights.
    private static func drawBars(in rect: NSRect) {
        let heights: [CGFloat] = [0.36, 0.72, 0.55, 0.30]   // fraction of rect height
        let barWidth: CGFloat = rect.width * 0.13
        let gap = (rect.width - barWidth * CGFloat(heights.count)) / CGFloat(heights.count + 1)
        NSColor.black.setFill()
        for (i, fraction) in heights.enumerated() {
            let height = rect.height * fraction
            let x = rect.minX + gap + CGFloat(i) * (barWidth + gap)
            let y = rect.midY - height / 2
            let bar = NSRect(x: x, y: y, width: barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    private static func makeTemplate(
        name: String,
        draw: @escaping (NSRect) -> Void
    ) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = true
        image.setName(name)
        return image
    }
}
