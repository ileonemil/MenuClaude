import Cocoa

// Disegna lo sfondo della finestra del DMG: due "piazzole" per le icone, una
// freccia che indica dove trascinare, e le due cose da sapere al primo avvio.
// L'output è a 1x e 2x; make-dmg.sh li unisce in un TIFF multi-risoluzione.

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let outputDirectory = CommandLine.arguments[1]
let width: CGFloat = 620
let height: CGFloat = 420

// Le icone vanno posizionate qui dentro, e make-dmg.sh usa le stesse coordinate.
let appSlot = NSPoint(x: 165, y: 250)
let folderSlot = NSPoint(x: 455, y: 250)

let claudeOrange = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.30, alpha: 1)
let ink = NSColor(calibratedWhite: 0.16, alpha: 1)
let faded = NSColor(calibratedWhite: 0.45, alpha: 1)

func draw(scale: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Fondo: crema tenue con un alone caldo in alto, per non essere una lastra piatta.
    NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.96, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    // Sfumatura verticale su tutta la tela: un rettangolo più piccolo lascerebbe
    // uno scalino visibile dove finisce.
    if let glow = NSGradient(
        colors: [claudeOrange.withAlphaComponent(0), claudeOrange.withAlphaComponent(0.15)]
    ) {
        glow.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)
    }

    // Titolo.
    let title = NSMutableParagraphStyle()
    title.alignment = .center
    NSAttributedString(
        string: "MenuClaude",
        attributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold),
            .foregroundColor: ink,
            .paragraphStyle: title,
        ]
    ).draw(in: NSRect(x: 0, y: height - 72, width: width, height: 40))

    NSAttributedString(
        string: "Il tuo utilizzo di Claude nella barra dei menu  ·  Claude usage in your menu bar",
        attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: faded,
            .paragraphStyle: title,
        ]
    ).draw(in: NSRect(x: 0, y: height - 96, width: width, height: 20))

    // Le due piazzole dove atterrano le icone.
    for slot in [appSlot, folderSlot] {
        let box = NSRect(x: slot.x - 62, y: slot.y - 58, width: 124, height: 124)
        let path = NSBezierPath(roundedRect: box, xRadius: 22, yRadius: 22)
        NSColor.white.withAlphaComponent(0.75).setFill()
        path.fill()
        claudeOrange.withAlphaComponent(0.30).setStroke()
        path.lineWidth = 1.5
        path.setLineDash([6, 5], count: 2, phase: 0)
        path.stroke()
    }

    // Freccia dalla piazzola dell'app a quella di Applicazioni.
    let arrowStart = NSPoint(x: appSlot.x + 78, y: slotCenterY())
    let arrowEnd = NSPoint(x: folderSlot.x - 78, y: slotCenterY())
    let shaft = NSBezierPath()
    shaft.move(to: arrowStart)
    shaft.line(to: NSPoint(x: arrowEnd.x - 12, y: arrowEnd.y))
    shaft.lineWidth = 3
    shaft.lineCapStyle = .round
    claudeOrange.setStroke()
    shaft.stroke()

    let head = NSBezierPath()
    head.move(to: arrowEnd)
    head.line(to: NSPoint(x: arrowEnd.x - 16, y: arrowEnd.y + 9))
    head.line(to: NSPoint(x: arrowEnd.x - 16, y: arrowEnd.y - 9))
    head.close()
    claudeOrange.setFill()
    head.fill()

    let centred = NSMutableParagraphStyle()
    centred.alignment = .center
    NSAttributedString(
        string: "trascina qui\ndrag here",
        attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: claudeOrange,
            .paragraphStyle: centred,
        ]
    ).draw(in: NSRect(x: arrowStart.x, y: slotCenterY() + 10, width: arrowEnd.x - arrowStart.x, height: 30))

    // I due passi, sotto le icone: il secondo è quello che salva dalle domande.
    // Da macOS 15 il clic destro → Apri non aggira più il blocco per le app
    // non firmate: l'unica strada senza Terminale è Impostazioni di Sistema.
    let steps: [(String, String)] = [
        ("1", "Trascina MenuClaude su Applicazioni\nDrag MenuClaude onto Applications"),
        ("2", "Se macOS la blocca: Impostazioni di Sistema › Privacy e Sicurezza › «Apri comunque»\nIf macOS blocks it: System Settings › Privacy & Security › \"Open Anyway\""),
    ]
    var y: CGFloat = 118
    for (number, text) in steps {
        let bullet = NSRect(x: 96, y: y - 2, width: 22, height: 22)
        claudeOrange.setFill()
        NSBezierPath(ovalIn: bullet).fill()

        let numberStyle = NSMutableParagraphStyle()
        numberStyle.alignment = .center
        NSAttributedString(
            string: number,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: numberStyle,
            ]
        ).draw(in: NSRect(x: bullet.minX, y: bullet.minY + 3, width: bullet.width, height: 16))

        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: ink,
            ]
        ).draw(in: NSRect(x: 130, y: y - 15, width: 470, height: 36))
        y -= 52
    }

    NSAttributedString(
        string: "Senza blocchi: un solo comando da Terminale, nel README  ·  No blocks: one Terminal command, in the README",
        attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: faded,
            .paragraphStyle: title,
        ]
    ).draw(in: NSRect(x: 0, y: 22, width: width, height: 16))

    return rep.representation(using: .png, properties: [:])
}

func slotCenterY() -> CGFloat { appSlot.y - 58 + 62 }

for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    guard let data = draw(scale: scale) else { continue }
    try? data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name)"))
}

// make-dmg.sh legge queste coordinate per posizionare le icone sullo sfondo.
print("\(Int(width)) \(Int(height)) \(Int(appSlot.x)) \(Int(height - appSlot.y)) \(Int(folderSlot.x)) \(Int(height - folderSlot.y))")
