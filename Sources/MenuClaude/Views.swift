import Cocoa

/// Barra di avanzamento arrotondata, disegnata a mano per avere pieno controllo
/// su spessore e colore (NSProgressIndicator non permette né l'uno né l'altro).
final class BarView: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var severity: Severity = .normal { didSet { needsDisplay = true } }
    var thickness: CGFloat = 6 { didSet { invalidateIntrinsicContentSize() } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: thickness) }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0, y: (bounds.height - thickness) / 2, width: bounds.width, height: thickness)
        let radius = thickness / 2

        Theme.track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return }
        // Sotto il diametro il segmento non sarebbe visibile: teniamo un minimo.
        let width = max(thickness, rect.width * CGFloat(clamped))
        let fill = NSRect(x: rect.minX, y: rect.minY, width: width, height: thickness)
        Theme.color(for: severity).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

/// Riga di una quota: etichetta, percentuale, barra, countdown al reset.
final class LimitRowView: NSView {
    private let titleLabel = LimitRowView.label(size: 11, weight: .medium, color: .secondaryLabelColor)
    private let percentLabel = LimitRowView.label(size: 13, weight: .semibold, color: .labelColor, mono: true)
    private let bar = BarView()
    private let resetLabel = LimitRowView.label(size: 10, weight: .regular, color: .tertiaryLabelColor)
    private let stampLabel = LimitRowView.label(size: 10, weight: .regular, color: .tertiaryLabelColor)

    private var resetsAt: Date?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        percentLabel.alignment = .right
        stampLabel.alignment = .right
        // I valori a destra non devono mai accorciarsi: se lo spazio manca,
        // a troncarsi sono l'etichetta e il countdown a sinistra. Senza
        // troncamento la cella non spende larghezza per i puntini di sospensione,
        // che al limite le mangiavano due caratteri buoni.
        for field in [percentLabel, stampLabel] {
            field.lineBreakMode = .byClipping
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
            field.setContentHuggingPriority(.required, for: .horizontal)
        }

        let top = NSStackView(views: [titleLabel, NSView(), percentLabel])
        top.orientation = .horizontal
        top.spacing = 6
        top.alignment = .firstBaseline

        let bottom = NSStackView(views: [resetLabel, NSView(), stampLabel])
        bottom.orientation = .horizontal
        bottom.spacing = 6
        bottom.alignment = .firstBaseline

        let stack = NSStackView(views: [top, bar, bottom])
        stack.orientation = .vertical
        stack.spacing = 5
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    func apply(_ limit: UsageLimit) {
        titleLabel.stringValue = limit.label.uppercased()
        percentLabel.stringValue = Format.percent(limit.percent)
        percentLabel.textColor = limit.severity == .normal ? .labelColor : Theme.color(for: limit.severity)
        bar.progress = limit.percent / 100
        bar.severity = limit.severity
        resetsAt = limit.resetsAt
        stampLabel.stringValue = Format.resetStamp(limit.resetsAt) ?? ""
        tick()
    }

    func setTitle(_ text: String) { titleLabel.stringValue = text }
    func setResetText(_ text: String) { resetLabel.stringValue = text }
    func setStampText(_ text: String) { stampLabel.stringValue = text }

    /// Aggiorna solo il countdown, una volta al secondo.
    func tick() {
        if let remaining = Format.countdown(to: resetsAt) {
            resetLabel.stringValue = L.t("reset tra \(remaining)", "resets in \(remaining)")
        } else {
            resetLabel.stringValue = ""
        }
    }

    static func label(size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = mono ? NSFont.monoDigits(size, weight) : NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
}

/// Pallino di stato, accanto all'indicazione dei server.
final class DotView: NSView {
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: (bounds.height - 7) / 2, width: 7, height: 7)).fill()
    }
}

/// Separatore sottile a tutta larghezza.
final class SeparatorView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

enum RingIcon {
    /// Tre anelli concentrici in stile Apple Fitness: sessione all'esterno,
    /// avanzamento della finestra di 5 ore al centro, settimana all'interno.
    /// Tutti si riempiono nella stessa direzione — più pieno, meno margine.
    static func concentric(
        session: Double,
        window: Double,
        weekly: Double,
        sessionSeverity: Severity,
        weeklySeverity: Severity,
        colored: Bool
    ) -> NSImage {
        // A questa scala il tratto sottile è l'unico modo per tenere i tre
        // anelli distinguibili: più spessi si fondono in una macchia.
        let side: CGFloat = 18
        let lineWidth: CGFloat = 1.4
        let rings: [(progress: Double, radius: CGFloat, color: NSColor)] = [
            (session, 7.6, colored ? Theme.color(for: sessionSeverity) : .black),
            (window, 5.2, colored ? Theme.accent : .black),
            (weekly, 2.8, colored ? Theme.color(for: weeklySeverity) : .black),
        ]

        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let center = NSPoint(x: side / 2, y: side / 2)
            for ring in rings {
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: ring.radius, startAngle: 0, endAngle: 360)
                track.lineWidth = lineWidth
                ring.color.withAlphaComponent(colored ? 0.22 : 0.28).setStroke()
                track.stroke()

                let clamped = min(max(ring.progress, 0), 1)
                guard clamped > 0.005 else { continue }
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: center,
                    radius: ring.radius,
                    startAngle: 90,
                    endAngle: 90 - 360 * CGFloat(clamped),
                    clockwise: true
                )
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                ring.color.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = !colored
        return image
    }

    /// Anello di avanzamento per la barra dei menu: traccia tenue + arco colorato.
    static func image(progress: Double, severity: Severity, colored: Bool) -> NSImage {
        let side: CGFloat = 15
        let lineWidth: CGFloat = 2.4
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: side / 2, y: side / 2)
            let radius = (side - lineWidth) / 2 - 0.5

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            (colored ? NSColor.tertiaryLabelColor : NSColor.black.withAlphaComponent(0.30)).setStroke()
            track.stroke()

            let clamped = min(max(progress, 0), 1)
            if clamped > 0 {
                let arc = NSBezierPath()
                // Parte da mezzogiorno e gira in senso orario, come un quadrante.
                arc.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 90,
                    endAngle: 90 - 360 * CGFloat(clamped),
                    clockwise: true
                )
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                (colored ? Theme.color(for: severity) : NSColor.black).setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = !colored
        return image
    }
}
