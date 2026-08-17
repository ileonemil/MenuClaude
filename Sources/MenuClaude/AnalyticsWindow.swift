import Cocoa

/// La finestra delle statistiche: quanto lavoro è passato da Claude Code su
/// questo Mac, come si distribuisce nel tempo, fra i modelli e fra i progetti.
///
/// Due avvertenze sono stampate in cima alla finestra e non sono un dettaglio:
/// i dati vengono dai log locali di Claude Code — non da claude.ai, non
/// dall'app desktop, non da un altro computer — e il valore in dollari è quanto
/// costerebbero quei token pagati a consumo sull'API, non quanto hai pagato.
final class AnalyticsWindowController: NSWindowController {
    private let content = NSStackView()
    private let tiles = (
        tokens: StatTile(caption: L.t("Token totali", "Total tokens")),
        cost: StatTile(caption: L.t("Valore a listino", "List value")),
        messages: StatTile(caption: L.t("Risposte", "Responses")),
        span: StatTile(caption: L.t("Periodo", "Period"))
    )
    private let dailyChart = DailyBarChart()
    private let trendChart = TrendChart()
    private let heatmap = HeatmapView()
    private let modelsStack = NSStackView()
    private let projectsStack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let unpricedLabel = NSTextField(labelWithString: "")
    private var isLoading = false
    /// Viste che devono occupare tutta la larghezza della colonna.
    private var fullWidth: [NSView] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L.t("Statistiche MenuClaude", "MenuClaude Analytics")
        window.minSize = NSSize(width: 560, height: 420)
        window.center()
        self.init(window: window)
        buildContent()
        reload()
    }

    // MARK: - Costruzione

    private func buildContent() {
        content.orientation = .vertical
        content.spacing = 20
        content.alignment = .leading
        content.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 22, right: 22)
        content.translatesAutoresizingMaskIntoConstraints = false

        content.addArrangedSubview(header())
        content.addArrangedSubview(tileRow())
        content.addArrangedSubview(
            section(
                L.t("Token al giorno", "Tokens per day"),
                L.t("ultimi 30 giorni", "last 30 days"),
                dailyChart
            )
        )
        content.addArrangedSubview(
            section(
                L.t("Quota settimanale nel tempo", "Weekly quota over time"),
                L.t("dallo storico registrato da MenuClaude", "from the history MenuClaude records"),
                trendChart
            )
        )
        content.addArrangedSubview(
            section(L.t("Per modello", "By model"), nil, modelsStack, stacked: true)
        )
        content.addArrangedSubview(
            section(L.t("Per progetto", "By project"), nil, projectsStack, stacked: true)
        )
        content.addArrangedSubview(
            section(
                L.t("Attività", "Activity"),
                L.t("un quadratino per giorno, ultimi 12 mesi", "one square per day, last 12 months"),
                heatmap
            )
        )
        content.addArrangedSubview(footer())

        for stack in [modelsStack, projectsStack] {
            stack.orientation = .vertical
            stack.spacing = 12
            stack.alignment = .leading
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = content

        for view in fullWidth {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -44).isActive = true
        }

        let root = NSView()
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        window?.contentView = root
    }

    private func header() -> NSView {
        let title = NSTextField(labelWithString: L.t("Il tuo lavoro con Claude Code", "Your work with Claude Code"))
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)

        let scope = NSTextField(wrappingLabelWithString: L.t(
            "Solo Claude Code su questo Mac: claude.ai, l'app desktop e gli altri computer non lasciano log qui. "
                + "Il valore in dollari è quanto costerebbero questi token pagati a consumo sull'API — non quanto hai speso.",
            "Claude Code on this Mac only: claude.ai, the desktop app and other computers leave no logs here. "
                + "The dollar figure is what these tokens would cost on the pay-as-you-go API — not what you spent."
        ))
        scope.font = NSFont.systemFont(ofSize: 11)
        scope.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, scope])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        scope.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func tileRow() -> NSView {
        let row = NSStackView(views: [tiles.tokens, tiles.cost, tiles.messages, tiles.span])
        row.orientation = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        return row
    }

    private func section(_ title: String, _ subtitle: String?, _ body: NSView, stacked: Bool = false) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        var heading: [NSView] = [label]
        if let subtitle = subtitle {
            let caption = NSTextField(labelWithString: subtitle)
            caption.font = NSFont.systemFont(ofSize: 11)
            caption.textColor = .tertiaryLabelColor
            heading.append(caption)
        }
        let headingRow = NSStackView(views: heading)
        headingRow.orientation = .horizontal
        headingRow.spacing = 8
        headingRow.alignment = .firstBaseline

        let stack = NSStackView(views: [headingRow, body])
        stack.orientation = .vertical
        stack.spacing = stacked ? 10 : 8
        stack.alignment = .leading
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        // La larghezza si aggancia al contenitore solo dopo l'inserimento:
        // finché la vista non è nella gerarchia il vincolo non ha un antenato.
        fullWidth.append(stack)
        return stack
    }

    private func footer() -> NSView {
        footerLabel.font = NSFont.systemFont(ofSize: 10)
        footerLabel.textColor = .tertiaryLabelColor
        unpricedLabel.font = NSFont.systemFont(ofSize: 10)
        unpricedLabel.textColor = Theme.color(for: .warning)
        unpricedLabel.isHidden = true

        let button = NSButton(
            title: L.t("Rileggi i log", "Rescan logs"),
            target: self,
            action: #selector(rescan)
        )
        button.bezelStyle = .rounded
        button.controlSize = .small

        let row = NSStackView(views: [footerLabel, unpricedLabel, NSView(), button])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        fullWidth.append(row)
        return row
    }

    // MARK: - Dati

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        rescan()
    }

    @objc private func rescan() {
        guard !isLoading else { return }
        isLoading = true
        footerLabel.stringValue = L.t("Lettura dei log…", "Reading logs…")
        DispatchQueue.global(qos: .userInitiated).async {
            let report = LocalUsageIndex.shared.refresh()
            DispatchQueue.main.async {
                self.isLoading = false
                self.apply(report)
            }
        }
    }

    private func reload() {
        apply(LocalUsageIndex.shared.cached)
    }

    /// Accessi che servono solo al disegno fuori schermo.
    var contentStack: NSStackView { content }
    func reloadForSnapshot() { reload() }

    private func apply(_ report: LocalUsageReport) {
        applyTiles(report)
        applyDaily(report)
        applyTrend()
        applyModels(report)
        applyProjects(report)
        applyHeatmap(report)

        let stamp = DateFormatter.localizedString(from: report.scannedAt, dateStyle: .none, timeStyle: .short)
        footerLabel.stringValue = L.t("Aggiornato alle \(stamp)", "Updated at \(stamp)")

        let unpriced = report.unpricedModels.sorted()
        unpricedLabel.isHidden = unpriced.isEmpty
        if !unpriced.isEmpty {
            unpricedLabel.stringValue = L.t(
                "Modelli senza listino, contati nei token ma non nel costo: \(unpriced.joined(separator: ", "))",
                "Models with no price, counted in tokens but not in cost: \(unpriced.joined(separator: ", "))"
            )
        }
    }

    private func applyTiles(_ report: LocalUsageReport) {
        let total = report.total
        tiles.tokens.set(
            value: UsageFormat.tokens(total.totalTokens),
            note: L.t(
                "\(UsageFormat.tokens(total.cacheRead)) riletti da cache",
                "\(UsageFormat.tokens(total.cacheRead)) read from cache"
            )
        )
        tiles.cost.set(
            value: UsageFormat.dollars(total.cost),
            note: L.t("se pagati sull'API", "if paid on the API")
        )
        tiles.messages.set(value: "\(total.messages)")

        if let first = report.firstDay, let last = report.lastDay {
            let days = dayCount(from: first, to: last)
            tiles.span.set(
                value: L.t("\(days) giorni", "\(days) days"),
                note: "\(shortDay(first)) → \(shortDay(last))"
            )
        } else {
            tiles.span.set(value: "—", note: L.t("nessun log trovato", "no logs found"))
        }
    }

    private func applyDaily(_ report: LocalUsageReport) {
        let formatter = DateFormatter()
        formatter.locale = L.locale
        formatter.setLocalizedDateFormatFromTemplate("dMMM")

        dailyChart.axisFormatter = { UsageFormat.tokens(Int($0)) }
        dailyChart.columns = report.days(last: 30).map { entry in
            let date = LocalUsageIndex.dayFormatter.date(from: entry.day) ?? Date()
            let tokens = entry.totals.totalTokens
            let text = tokens == 0
                ? L.t("\(formatter.string(from: date)): niente", "\(formatter.string(from: date)): nothing")
                : "\(formatter.string(from: date)): \(UsageFormat.tokens(tokens)) · "
                    + "\(UsageFormat.dollars(entry.totals.cost)) · "
                    + L.t("\(entry.totals.messages) risposte", "\(entry.totals.messages) responses")
            return DailyBarChart.Column(
                label: shortDay(entry.day),
                value: Double(tokens),
                tooltip: text
            )
        }
    }

    private func applyTrend() {
        let since = Date().addingTimeInterval(-21 * 86400)
        let formatter = DateFormatter()
        formatter.locale = L.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        trendChart.points = UsageHistory.shared.samples(since: since).map { sample in
            TrendChart.Point(
                at: sample.at,
                value: sample.weekly,
                tooltip: "\(formatter.string(from: sample.at)) — "
                    + L.t("settimana al \(Int(sample.weekly.rounded()))%",
                          "week at \(Int(sample.weekly.rounded()))%")
            )
        }
    }

    private func applyModels(_ report: LocalUsageReport) {
        modelsStack.setViews([], in: .top)
        let ranked = report.byModel.sorted { $0.value.totalTokens > $1.value.totalTokens }
        guard let peak = ranked.first?.value.totalTokens, peak > 0 else {
            modelsStack.addArrangedSubview(emptyNote())
            return
        }

        // Oltre gli slot della tavolozza non si inventano colori: si accorpa.
        let visible = ranked.prefix(Theme.categoricalCount - 1)
        let rest = ranked.dropFirst(visible.count)

        for (index, entry) in visible.enumerated() {
            let row = RankRowView(color: Theme.categorical(index))
            row.set(
                name: Pricing.shortName(entry.key),
                value: UsageFormat.tokens(entry.value.totalTokens),
                detail: "\(UsageFormat.dollars(entry.value.cost)) · "
                    + L.t("\(entry.value.messages) risposte", "\(entry.value.messages) responses"),
                share: Double(entry.value.totalTokens) / Double(peak)
            )
            modelsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
        }

        if !rest.isEmpty {
            let totals = rest.map(\.value).reduce(UsageTotals(), +)
            let row = RankRowView(color: Theme.categorical(Theme.categoricalCount - 1))
            row.set(
                name: L.t("altri \(rest.count) modelli", "\(rest.count) other models"),
                value: UsageFormat.tokens(totals.totalTokens),
                detail: UsageFormat.dollars(totals.cost),
                share: Double(totals.totalTokens) / Double(peak)
            )
            modelsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
        }
    }

    private func applyProjects(_ report: LocalUsageReport) {
        projectsStack.setViews([], in: .top)
        let ranked = report.byProject.sorted { $0.value.cost > $1.value.cost }.prefix(8)
        guard let peak = ranked.first?.value.cost, peak > 0 else {
            projectsStack.addArrangedSubview(emptyNote())
            return
        }
        for entry in ranked {
            // Una misura sola: un colore solo. Colorare ogni barra in modo
            // diverso suggerirebbe categorie che qui non esistono.
            let row = RankRowView(color: nil)
            row.set(
                name: entry.key,
                value: UsageFormat.dollars(entry.value.cost),
                detail: UsageFormat.tokens(entry.value.totalTokens),
                share: entry.value.cost / peak
            )
            projectsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: projectsStack.widthAnchor).isActive = true
        }
    }

    private func applyHeatmap(_ report: LocalUsageReport) {
        let formatter = DateFormatter()
        formatter.locale = L.locale
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")

        heatmap.days = report.days(last: 365).compactMap { entry in
            guard let date = LocalUsageIndex.dayFormatter.date(from: entry.day) else { return nil }
            let tokens = entry.totals.totalTokens
            return HeatmapView.Day(
                date: date,
                value: Double(tokens),
                tooltip: "\(formatter.string(from: date)): \(UsageFormat.tokens(tokens)) · "
                    + UsageFormat.dollars(entry.totals.cost)
            )
        }
    }

    private func emptyNote() -> NSTextField {
        let label = NSTextField(labelWithString: L.t(
            "Nessun log di Claude Code trovato in ~/.claude/projects.",
            "No Claude Code logs found in ~/.claude/projects."
        ))
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func shortDay(_ key: String) -> String {
        guard let date = LocalUsageIndex.dayFormatter.date(from: key) else { return key }
        let formatter = DateFormatter()
        formatter.locale = L.locale
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter.string(from: date)
    }

    private func dayCount(from: String, to: String) -> Int {
        guard
            let start = LocalUsageIndex.dayFormatter.date(from: from),
            let end = LocalUsageIndex.dayFormatter.date(from: to)
        else { return 0 }
        return (Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0) + 1
    }
}

extension AnalyticsWindowController {
    /// Salva `<prefisso>-light.png` e `<prefisso>-dark.png` con l'intero
    /// contenuto della finestra, srotolato: i grafici vanno guardati, e uno
    /// screenshot della sola parte visibile non basta.
    static func writeSnapshots(to prefix: String) {
        _ = NSApplication.shared
        let controller = AnalyticsWindowController()
        LocalUsageIndex.shared.refresh()
        controller.reloadForSnapshot()

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let window = controller.window, let root = window.contentView else { continue }
            window.appearance = NSAppearance(named: appearance)

            let stack = controller.contentStack
            stack.layoutSubtreeIfNeeded()
            let height = max(stack.fittingSize.height, 600)
            window.setContentSize(NSSize(width: 720, height: height))
            root.layoutSubtreeIfNeeded()
            // Il disegno legge l'aspetto corrente del thread, non quello della
            // finestra: senza questo escono due immagini identiche.
            NSAppearance.current = window.appearance

            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { continue }
            // `cacheDisplay` disegna le viste ma non il fondo della finestra: senza
            // dipingerlo prima, i riempimenti traslucidi finiscono sul trasparente
            // e nel PNG sembrano opachi.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: root.bounds).fill()
            NSGraphicsContext.restoreGraphicsState()
            root.cacheDisplay(in: root.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(prefix)-\(suffix).png"))
            }
        }
    }
}

/// Senza questa il contenuto di un NSScrollView parte dal basso.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
