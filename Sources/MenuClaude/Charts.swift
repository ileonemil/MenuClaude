import Cocoa

/// Base per i grafici: tiene l'elenco dei rettangoli disegnati e il testo da
/// mostrare al passaggio del mouse. Un grafico senza tooltip costringe a
/// etichettare ogni segno o a non dire i valori esatti: nessuna delle due.
class ChartView: NSView, NSViewToolTipOwner {
    /// Riempito da `draw`: rettangolo del segno e testo del tooltip.
    var marks: [(rect: NSRect, text: String)] = []

    override var isFlipped: Bool { false }

    func registerTooltips() {
        removeAllToolTips()
        for mark in marks {
            // Il bersaglio è più largo del segno: barre sottili sono
            // impossibili da centrare col mouse.
            let target = mark.rect.insetBy(dx: -2, dy: 0)
            addToolTip(target, owner: self, userData: nil)
        }
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        marks.first { $0.rect.insetBy(dx: -2, dy: 0).contains(point) }?.text ?? ""
    }

    /// Testo recessivo per assi e griglia: non deve competere coi dati.
    func drawAxisLabel(_ text: String, at point: NSPoint, alignment: NSTextAlignment = .center) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: style,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var origin = point
        switch alignment {
        case .right: origin.x -= size.width
        case .center: origin.x -= size.width / 2
        default: break
        }
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

/// Un numero grande con la sua etichetta. Quando il dato è uno solo, un grafico
/// è solo decorazione: si scrive il numero.
final class StatTile: NSView {
    private let valueLabel = NSTextField(labelWithString: "—")
    private let captionLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")

    init(caption: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        valueLabel.font = NSFont.monoDigits(21, .semibold)
        valueLabel.textColor = .labelColor
        captionLabel.stringValue = caption.uppercased()
        captionLabel.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        captionLabel.textColor = .secondaryLabelColor
        noteLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        noteLabel.textColor = .tertiaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [captionLabel, valueLabel, noteLabel])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    func set(value: String, note: String = "") {
        valueLabel.stringValue = value
        noteLabel.stringValue = note
    }

    override func updateLayer() {
        layer?.backgroundColor = Theme.tileBackground.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.tileBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// Barre verticali per una serie sola nel tempo (i token al giorno).
/// Una serie sola non ha legenda: a dire di cosa si tratta è il titolo.
final class DailyBarChart: ChartView {
    struct Column {
        var label: String
        var value: Double
        var tooltip: String
        /// Giorno futuro o precedente al primo dato: si disegna vuoto.
        var isPlaceholder = false
    }

    var columns: [Column] = [] { didSet { needsDisplay = true } }
    /// Formatta il valore dell'asse verticale.
    var axisFormatter: (Double) -> String = { String(Int($0)) }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 150) }

    override func draw(_ dirtyRect: NSRect) {
        marks.removeAll()
        guard !columns.isEmpty else { return }

        let leftGutter: CGFloat = 38
        let bottomGutter: CGFloat = 16
        let plot = NSRect(
            x: leftGutter,
            y: bottomGutter,
            width: bounds.width - leftGutter - 4,
            height: bounds.height - bottomGutter - 8
        )
        let peak = columns.map(\.value).max() ?? 0
        guard peak > 0 else {
            drawAxisLabel(L.t("nessun dato", "no data"),
                          at: NSPoint(x: bounds.midX, y: bounds.midY))
            return
        }

        // Griglia: tre linee tenui, sotto ai dati e mai in primo piano.
        let steps = [0.0, 0.5, 1.0]
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        for step in steps {
            let y = plot.minY + plot.height * CGFloat(step)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y.rounded() + 0.5))
            line.line(to: NSPoint(x: plot.maxX, y: y.rounded() + 0.5))
            line.lineWidth = 1
            line.stroke()
            drawAxisLabel(axisFormatter(peak * step),
                          at: NSPoint(x: leftGutter - 6, y: y - 4), alignment: .right)
        }

        // 2px di superficie fra una barra e l'altra: senza lo stacco le barre
        // adiacenti si leggono come un blocco unico.
        let gap: CGFloat = 2
        let slot = plot.width / CGFloat(columns.count)
        let width = max(3, slot - gap)
        let fill = Theme.categorical(0)

        for (index, column) in columns.enumerated() {
            let x = plot.minX + slot * CGFloat(index) + (slot - width) / 2
            let height = plot.height * CGFloat(column.value / peak)
            let hit = NSRect(x: x, y: plot.minY, width: width, height: plot.height)
            marks.append((hit, column.tooltip))

            guard !column.isPlaceholder, column.value > 0 else { continue }
            // Le estremità sono arrotondate solo in cima: la base resta
            // ancorata all'asse, che è ciò da cui si legge la lunghezza.
            let bar = NSRect(x: x, y: plot.minY, width: width, height: max(2, height))
            roundedTop(bar, radius: min(4, width / 2)).fill(with: fill)
        }

        // Etichette dell'asse orizzontale: solo alcune, mai una per barra.
        let stride = max(1, columns.count / 6)
        for (index, column) in columns.enumerated() where index % stride == 0 {
            let x = plot.minX + slot * (CGFloat(index) + 0.5)
            drawAxisLabel(column.label, at: NSPoint(x: x, y: 2))
        }

        registerTooltips()
    }

    private func roundedTop(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let r = min(radius, rect.height / 2)
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - r))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r, startAngle: 180, endAngle: 90, clockwise: true
        )
        path.line(to: NSPoint(x: rect.maxX - r, y: rect.maxY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r, startAngle: 90, endAngle: 0, clockwise: true
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.close()
        return path
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

/// Andamento continuo di una percentuale nel tempo (sessione o settimana).
/// Linea sottile con un velo sotto: l'area dice "quanto", la linea "quando".
final class TrendChart: ChartView {
    struct Point {
        var at: Date
        var value: Double
        var tooltip: String
    }

    var points: [Point] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var colorIndex = 0

    // Senza storico non c'è niente da disegnare: la sezione si stringe attorno
    // alla frase invece di lasciare un buco alto quanto un grafico.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: points.count >= 2 ? 120 : 40)
    }

    override func draw(_ dirtyRect: NSRect) {
        marks.removeAll()
        guard points.count >= 2,
              let first = points.first?.at,
              let last = points.last?.at,
              last > first
        else {
            drawAxisLabel(L.t("storico non ancora sufficiente", "not enough history yet"),
                          at: NSPoint(x: bounds.midX, y: bounds.midY))
            return
        }

        let leftGutter: CGFloat = 30
        let bottomGutter: CGFloat = 14
        let plot = NSRect(
            x: leftGutter,
            y: bottomGutter,
            width: bounds.width - leftGutter - 4,
            height: bounds.height - bottomGutter - 8
        )
        let span = last.timeIntervalSince(first)

        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        for step in [0.0, 0.5, 1.0] {
            let y = plot.minY + plot.height * CGFloat(step)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y.rounded() + 0.5))
            line.line(to: NSPoint(x: plot.maxX, y: y.rounded() + 0.5))
            line.lineWidth = 1
            line.stroke()
            drawAxisLabel("\(Int(step * 100))%",
                          at: NSPoint(x: leftGutter - 6, y: y - 4), alignment: .right)
        }

        func position(_ point: Point) -> NSPoint {
            let x = plot.minX + plot.width * CGFloat(point.at.timeIntervalSince(first) / span)
            let y = plot.minY + plot.height * CGFloat(min(max(point.value, 0), 100) / 100)
            return NSPoint(x: x, y: y)
        }

        let color = Theme.categorical(colorIndex)
        let line = NSBezierPath()
        let area = NSBezierPath()
        area.move(to: NSPoint(x: position(points[0]).x, y: plot.minY))
        for (index, point) in points.enumerated() {
            let p = position(point)
            if index == 0 { line.move(to: p) } else { line.line(to: p) }
            area.line(to: p)
            marks.append((NSRect(x: p.x - 4, y: plot.minY, width: 8, height: plot.height), point.tooltip))
        }
        area.line(to: NSPoint(x: position(points[points.count - 1]).x, y: plot.minY))
        area.close()

        color.withAlphaComponent(0.15).setFill()
        area.fill()
        color.setStroke()
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.stroke()

        let formatter = DateFormatter()
        formatter.locale = L.locale
        formatter.setLocalizedDateFormatFromTemplate(span > 3 * 86400 ? "dMMM" : "EEEHH")
        drawAxisLabel(formatter.string(from: first), at: NSPoint(x: plot.minX + 12, y: 1))
        drawAxisLabel(formatter.string(from: last), at: NSPoint(x: plot.maxX - 12, y: 1))

        registerTooltips()
    }
}

/// Calendario ad anno, una cella per giorno, intensità = quanto lavoro.
/// La rampa è a tinta unica: chiara→scura è l'unica scala che si legge come
/// "poco→tanto" senza dover consultare la legenda.
final class HeatmapView: ChartView {
    struct Day {
        var date: Date
        var value: Double
        var tooltip: String
    }

    var days: [Day] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    private let gap: CGFloat = 3
    private let topGutter: CGFloat = 14
    private let leftGutter: CGFloat = 26
    /// Il lato del quadratino non è fisso: un anno intero deve entrare nella
    /// larghezza disponibile, altrimenti gli ultimi mesi — gli unici che
    /// interessano davvero — finiscono fuori dal bordo.
    private var cell: CGFloat = 11

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: topGutter + 7 * (11 + gap) + 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        marks.removeAll()
        guard let firstDay = days.first?.date else { return }

        let calendar = Calendar.current
        let weeksNeeded = ceil(Double(days.count) / 7) + 1
        let available = bounds.width - leftGutter - 4
        cell = min(11, max(4, available / CGFloat(weeksNeeded) - gap))
        // La griglia parte dal lunedì della prima settimana, così ogni riga è
        // sempre lo stesso giorno della settimana.
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: firstDay)
        components.weekday = calendar.firstWeekday
        let gridStart = calendar.date(from: components) ?? firstDay
        let peak = days.map(\.value).max() ?? 0

        let symbols = DateFormatter()
        symbols.locale = L.locale
        let weekdays = symbols.veryShortStandaloneWeekdaySymbols ?? []
        let monthNames = symbols.shortStandaloneMonthSymbols ?? []

        var drawnMonths: Set<Int> = []
        var lookup: [String: Day] = [:]
        for day in days { lookup[LocalUsageIndex.dayFormatter.string(from: day.date)] = day }

        let totalDays = calendar.dateComponents([.day], from: gridStart, to: days.last!.date).day ?? 0
        let weeks = totalDays / 7 + 1

        for week in 0..<weeks {
            for weekday in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: week * 7 + weekday, to: gridStart)
                else { continue }
                let x = leftGutter + CGFloat(week) * (cell + gap)
                // Le righe scendono dall'alto: la prima riga in cima alla vista.
                let y = bounds.height - topGutter - CGFloat(weekday + 1) * (cell + gap)
                guard x + cell <= bounds.width else { break }

                let key = LocalUsageIndex.dayFormatter.string(from: date)
                let rect = NSRect(x: x, y: y, width: cell, height: cell)
                let path = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)

                if let day = lookup[key], day.value > 0, peak > 0 {
                    // Radice quadrata: senza, una giornata eccezionale schiaccia
                    // tutte le altre sul passo più chiaro.
                    Theme.sequential((day.value / peak).squareRoot()).setFill()
                    marks.append((rect, day.tooltip))
                } else if date > Date() {
                    continue
                } else {
                    Theme.emptyCell.setFill()
                    marks.append((rect, L.t("\(key): nessuna attività", "\(key): no activity")))
                }
                path.fill()

                // Etichetta del mese, una volta sola, sopra la prima settimana.
                let month = calendar.component(.month, from: date)
                if weekday == 0, !drawnMonths.contains(month), calendar.component(.day, from: date) <= 7 {
                    drawnMonths.insert(month)
                    if month - 1 < monthNames.count {
                        drawAxisLabel(monthNames[month - 1],
                                      at: NSPoint(x: x, y: bounds.height - topGutter + 1),
                                      alignment: .left)
                    }
                }
            }
        }

        // Etichette dei giorni: una sì e due no, altrimenti si accavallano.
        for weekday in stride(from: 0, to: 7, by: 2) {
            let index = (calendar.firstWeekday - 1 + weekday) % 7
            guard index < weekdays.count else { continue }
            let y = bounds.height - topGutter - CGFloat(weekday + 1) * (cell + gap) + 1
            drawAxisLabel(weekdays[index], at: NSPoint(x: leftGutter - 6, y: y), alignment: .right)
        }

        drawLegend()
        registerTooltips()
    }

    private func drawLegend() {
        let side: CGFloat = 9
        var x = bounds.width - 5 * (side + 3) - 40
        let y: CGFloat = 2
        drawAxisLabel(L.t("meno", "less"), at: NSPoint(x: x - 4, y: y), alignment: .right)
        for step in 0..<5 {
            let rect = NSRect(x: x, y: y, width: side, height: side)
            if step == 0 { Theme.emptyCell.setFill() } else { Theme.sequential(Double(step) / 4).setFill() }
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            x += side + 3
        }
        drawAxisLabel(L.t("più", "more"), at: NSPoint(x: x + 2, y: y), alignment: .left)
    }
}

/// Riga di una classifica: pastiglia colorata, nome, barra, valore.
/// Il valore è sempre scritto: il colore non è mai l'unico modo di leggerlo.
final class RankRowView: NSView {
    private let swatch = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = RankBar()

    init(color: NSColor?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.isHidden = color == nil
        bar.color = color ?? Theme.categorical(0)
        if let color = color { swatch.layer?.backgroundColor = color.cgColor }

        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = NSFont.monoDigits(12, .semibold)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byClipping
        detailLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byClipping

        let values = NSStackView(views: [valueLabel, detailLabel])
        values.orientation = .vertical
        values.spacing = 0
        values.alignment = .trailing
        values.setContentHuggingPriority(.required, for: .horizontal)
        values.setContentCompressionResistancePriority(.required, for: .horizontal)

        let top = NSStackView(views: [swatch, nameLabel, NSView(), values])
        top.orientation = .horizontal
        top.spacing = 6
        top.alignment = .centerY

        let stack = NSStackView(views: [top, bar])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 10),
            swatch.heightAnchor.constraint(equalToConstant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    func set(name: String, value: String, detail: String, share: Double) {
        nameLabel.stringValue = name
        valueLabel.stringValue = value
        detailLabel.stringValue = detail
        bar.share = share
        toolTip = "\(name) — \(value) · \(detail)"
    }
}

private final class RankBar: NSView {
    var share: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 5) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0, y: 0, width: bounds.width, height: 5)
        Theme.track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()
        let clamped = min(max(share, 0), 1)
        guard clamped > 0 else { return }
        color.setFill()
        let fill = NSRect(x: 0, y: 0, width: max(5, rect.width * CGFloat(clamped)), height: 5)
        NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
    }
}
