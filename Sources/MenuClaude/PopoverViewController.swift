import Cocoa

protocol PopoverDelegate: AnyObject {
    func popoverDidRequestRefresh()
    func popoverDidRequestMenu(from view: NSView)
    func popoverDidRequestTokenRenewal()
    func popoverDidRequestAlarmToggle()
}

/// Il pannello che compare cliccando sull'icona nella barra dei menu.
final class PopoverViewController: NSViewController {
    weak var delegate: PopoverDelegate?

    private let width: CGFloat = 288
    private let content = NSStackView()
    private let titleLabel = LimitRowView.label(size: 13, weight: .semibold, color: .labelColor)
    private let planLabel = LimitRowView.label(size: 10, weight: .semibold, color: .secondaryLabelColor)
    private let statusLabel = LimitRowView.label(size: 10, weight: .regular, color: .tertiaryLabelColor)
    private let serverLabel = LimitRowView.label(size: 10, weight: .regular, color: .tertiaryLabelColor)
    private let serverDot = DotView()
    private let errorLabel = LimitRowView.label(size: 11, weight: .regular, color: .systemRed)
    private let refreshButton = NSButton()
    private let menuButton = NSButton()
    private let renewButton = NSButton()
    private let alarmButton = NSButton()
    /// Creata qui e non in `loadView`: `render` può arrivare prima che la
    /// vista sia stata caricata, e un optional implicito qui significava un
    /// crash all'avvio.
    private let errorRow = NSStackView()

    private var rows: [String: LimitRowView] = [:]
    private var rowOrder: [String] = []
    private var extraRow: LimitRowView?
    private var limitsContainer = NSStackView()

    private var snapshot: UsageSnapshot?
    private var lastError: UsageError?
    private var retryAt: Date?
    /// Frasi di proiezione, per tipo di quota. Calcolate fuori: qui si mostrano.
    var forecasts: [String: String] = [:]
    /// Mentre il rinnovo è in corso il messaggio non va sovrascritto dal tick.
    var renewalInProgress = false

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        root.translatesAutoresizingMaskIntoConstraints = false

        planLabel.alignment = .right
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 3
        errorLabel.isHidden = true

        renewButton.title = L.t("Rinnova", "Renew")
        renewButton.bezelStyle = .rounded
        renewButton.controlSize = .small
        renewButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        renewButton.target = self
        renewButton.action = #selector(renewClicked)
        renewButton.setContentHuggingPriority(.required, for: .horizontal)
        renewButton.isHidden = true

        errorRow.setViews([errorLabel, renewButton], in: .leading)
        errorRow.orientation = .horizontal
        errorRow.spacing = 8
        errorRow.alignment = .centerY

        configure(button: refreshButton, symbol: "arrow.clockwise", tooltip: L.t("Aggiorna adesso", "Refresh now"), action: #selector(refreshClicked))
        configure(button: menuButton, symbol: "ellipsis.circle", tooltip: L.t("Opzioni", "Options"), action: #selector(menuClicked))
        configure(button: alarmButton, symbol: "bell", tooltip: "", action: #selector(alarmClicked))

        let header = NSStackView(views: [titleLabel, planLabel, NSView(), alarmButton, refreshButton, menuButton])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        titleLabel.stringValue = L.t("Utilizzo Claude", "Claude Usage")

        limitsContainer.orientation = .vertical
        limitsContainer.spacing = 14
        limitsContainer.alignment = .leading

        serverLabel.alignment = .right
        serverLabel.lineBreakMode = .byClipping
        serverLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        serverLabel.setContentHuggingPriority(.required, for: .horizontal)
        serverDot.isHidden = true
        serverLabel.isHidden = true

        let footer = NSStackView(views: [statusLabel, NSView(), serverDot, serverLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 5

        content.orientation = .vertical
        content.spacing = 12
        content.alignment = .leading
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setViews([header, errorRow, limitsContainer, SeparatorView(), footer], in: .top)

        root.addSubview(content)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: width),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            errorRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            limitsContainer.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])

        view = root
    }

    private func configure(button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.target = self
        button.toolTip = tooltip
        button.action = action
        button.contentTintColor = .secondaryLabelColor
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - Aggiornamento contenuti

    func render(snapshot: UsageSnapshot?, error: UsageError?, retryAt: Date?, serverStatus: ServerStatus?) {
        titleLabel.stringValue = L.t("Utilizzo Claude", "Claude Usage")
        refreshButton.toolTip = L.t("Aggiorna adesso", "Refresh now")
        menuButton.toolTip = L.t("Opzioni", "Options")
        self.snapshot = snapshot
        self.lastError = error
        self.retryAt = retryAt

        errorLabel.isHidden = error == nil
        errorRow.isHidden = error == nil
        switch error {
        case .tokenExpired?, .unauthorized?:
            renewButton.isHidden = false
        default:
            renewButton.isHidden = true
        }

        if let status = serverStatus {
            serverDot.isHidden = false
            serverLabel.isHidden = false
            serverLabel.stringValue = status.summary
            serverDot.color = Theme.color(for: status.severity)
            serverLabel.textColor = status.isHealthy ? .tertiaryLabelColor : Theme.color(for: status.severity)
        }

        if let snapshot = snapshot {
            planLabel.stringValue = (snapshot.plan ?? "").uppercased()
            syncRows(with: snapshot)
        }

        tick()
    }

    /// Ricostruisce le righe solo quando l'insieme di quote cambia davvero,
    /// così l'apertura del pannello non fa saltare il layout.
    private func syncRows(with snapshot: UsageSnapshot) {
        var wanted: [(String, UsageLimit)] = []
        if let session = snapshot.session { wanted.append(("session", session)) }
        if let weekly = snapshot.weekly { wanted.append((weekly.kind, weekly)) }
        for extra in snapshot.secondaryWeekly { wanted.append((extra.kind, extra)) }

        let keys = wanted.map { $0.0 } + (snapshot.extra != nil ? ["__extra"] : [])
        if keys != rowOrder {
            rowOrder = keys
            rows.removeAll()
            extraRow = nil
            limitsContainer.setViews([], in: .top)
            for key in keys {
                if key == "__extra" {
                    let separator = SeparatorView()
                    limitsContainer.addView(separator, in: .top)
                    separator.widthAnchor.constraint(equalTo: limitsContainer.widthAnchor).isActive = true
                }
                let row = LimitRowView()
                rows[key] = row
                limitsContainer.addView(row, in: .top)
                row.widthAnchor.constraint(equalTo: limitsContainer.widthAnchor).isActive = true
            }
        }

        for (key, limit) in wanted {
            rows[key]?.apply(limit)
            rows[key]?.setForecast(forecasts[limit.kind])
        }

        if let extra = snapshot.extra, let row = rows["__extra"] {
            row.apply(
                UsageLimit(
                    kind: "__extra",
                    group: "extra",
                    percent: extra.percent,
                    resetsAt: nil,
                    severity: extra.severity,
                    isActive: false
                )
            )
            row.overrideText(
                title: L.t("CREDITI EXTRA", "EXTRA CREDITS"),
                detail: L.t("\(extra.usedText) di \(extra.limitText)", "\(extra.usedText) of \(extra.limitText)")
            )
        }
    }

    /// Chiamata ogni secondo mentre il pannello è aperto.
    func tick() {
        for (key, row) in rows where key != "__extra" { row.tick() }

        if renewalInProgress { return }
        if let error = lastError {
            errorLabel.textColor = .systemRed
            var text = error.message
            if let retryAt = retryAt, retryAt > Date(),
               let countdown = Format.countdown(to: retryAt) {
                text += L.t(" — riprovo tra \(countdown)", " — retrying in \(countdown)")
            }
            errorLabel.stringValue = text
        }

        if let snapshot = snapshot {
            statusLabel.stringValue = L.t("Aggiornato \(Format.agoText(snapshot.fetchedAt))", "Updated \(Format.agoText(snapshot.fetchedAt))")
        } else if lastError != nil {
            statusLabel.stringValue = L.t("Nessun dato", "No data")
        } else {
            statusLabel.stringValue = L.t("Caricamento…", "Loading…")
        }
    }

    // MARK: - Azioni

    @objc private func refreshClicked() {
        delegate?.popoverDidRequestRefresh()
    }

    @objc private func menuClicked() {
        delegate?.popoverDidRequestMenu(from: menuButton)
    }

    @objc private func renewClicked() {
        delegate?.popoverDidRequestTokenRenewal()
    }

    @objc private func alarmClicked() {
        delegate?.popoverDidRequestAlarmToggle()
    }

    /// La campanella è piena quando la sveglia è armata, e il tooltip dice a
    /// che ora suonerà: senza, non ci sarebbe modo di saperlo.
    func showAlarm(at date: Date?, resetsAt: Date?) {
        let armed = date != nil
        alarmButton.image = NSImage(
            systemSymbolName: armed ? "bell.fill" : "bell",
            accessibilityDescription: nil
        )
        alarmButton.contentTintColor = armed ? Theme.accent : .secondaryLabelColor
        if let date = date {
            alarmButton.toolTip = L.t("Ti avviso al reset, \(Format.resetStamp(date) ?? "") — clic per annullare",
                                      "You'll be alerted at the reset, \(Format.resetStamp(date) ?? "") — click to cancel")
        } else if let resetsAt = resetsAt, let remaining = Format.countdown(to: resetsAt) {
            alarmButton.toolTip = L.t("Avvisami quando la sessione si azzera (fra \(remaining))",
                                      "Alert me when the session resets (in \(remaining))")
        } else {
            alarmButton.toolTip = L.t("Avvisami quando la sessione si azzera",
                                      "Alert me when the session resets")
        }
        alarmButton.isEnabled = resetsAt != nil || armed
    }

    /// Mostra l'esito del rinnovo al posto del messaggio d'errore.
    func showRenewalState(_ text: String, busy: Bool, failed: Bool) {
        errorRow.isHidden = false
        errorLabel.isHidden = false
        errorLabel.stringValue = text
        errorLabel.textColor = failed ? .systemRed : .secondaryLabelColor
        renewButton.isEnabled = !busy
        renewButton.title = busy ? L.t("Rinnovo…", "Renewing…") : L.t("Rinnova", "Renew")
    }
}

extension LimitRowView {
    /// Per la riga dei crediti extra, dove al posto del countdown va l'importo.
    func overrideText(title: String, detail: String) {
        setTitle(title)
        setResetText(detail)
        setStampText("")
    }
}
