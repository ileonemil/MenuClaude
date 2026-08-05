import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let outDir = CommandLine.arguments[1]
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func draw(_ px: Int) -> Data? {
    let s = CGFloat(px)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        // Sfondo: quadrato arrotondato in arancio Claude, leggermente sfumato.
        let inset = s * 0.055
        let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
        let gradient = NSGradient(
            colors: [
                NSColor(calibratedRed: 0.91, green: 0.55, blue: 0.36, alpha: 1),
                NSColor(calibratedRed: 0.78, green: 0.36, blue: 0.22, alpha: 1),
            ]
        )
        gradient?.draw(in: path, angle: -90)

        // Anello di avanzamento a circa tre quarti.
        let center = NSPoint(x: s / 2, y: s / 2)
        let radius = s * 0.27
        let line = s * 0.095

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = line
        NSColor.white.withAlphaComponent(0.28).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 270, clockwise: true)
        arc.lineWidth = line
        arc.lineCapStyle = .round
        NSColor.white.setStroke()
        arc.stroke()
        return true
    }
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: px, height: px)
    return rep.representation(using: .png, properties: [:])
}

for px in sizes {
    guard let data = draw(px) else { continue }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(px).png"))
}
print("ok")
