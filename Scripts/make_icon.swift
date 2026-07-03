// Renders the Murmur app icon and builds Resources/AppIcon.icns.
// Run: swift Scripts/make_icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS-style rounded square, deep indigo-to-violet — quiet, night-time, murmur.
let cornerRadius = size * 0.2237
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let squircle = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
NSGradient(colors: [
    NSColor(calibratedRed: 0.11, green: 0.08, blue: 0.28, alpha: 1),   // deep indigo
    NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.85, alpha: 1),   // violet
])!.draw(in: squircle, angle: 90)

// Faint concentric "sound ripple" arcs behind the bars.
NSColor.white.withAlphaComponent(0.08).setStroke()
for radius: CGFloat in [330, 420, 510] {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2), radius: radius,
                  startAngle: 200, endAngle: 340)
    arc.lineWidth = 14
    arc.stroke()
}

// The four-bar whisper waveform (same proportions as the menu-bar icon).
let heights: [CGFloat] = [0.36, 0.72, 0.55, 0.30]
let field = rect.insetBy(dx: size * 0.24, dy: size * 0.24)
let barWidth = field.width * 0.13
let gap = (field.width - barWidth * CGFloat(heights.count)) / CGFloat(heights.count + 1)
NSColor.white.setFill()
for (i, fraction) in heights.enumerated() {
    let h = field.height * fraction
    let x = field.minX + gap + CGFloat(i) * (barWidth + gap)
    let bar = NSRect(x: x, y: field.midY - h / 2, width: barWidth, height: h)
    NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
let master = URL(fileURLWithPath: "Resources/icon_1024.png")
try! FileManager.default.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try! png.write(to: master)
print("wrote \(master.path)")
