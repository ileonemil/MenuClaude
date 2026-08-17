import Cocoa

/// La finestra delle impostazioni.
///
/// Prima tutto stava nel menu: era arrivato a ventisei voci, con tre sottomenu
/// annidati, e per cambiare una soglia bisognava ricordarsi dove fosse. Le
/// impostazioni sono cose che si guardano tutte insieme, non una alla volta
/// mentre il menu si chiude a ogni clic.
final class SettingsWindowController: NSWindowController {
    /// Chiamato dopo ogni modifica, così la barra dei menu si ridisegna subito.
    var onChange: (() -> Void)?
    /// Il pulsante di prova delle notifiche resta una funzione dell'app.
    var onTestNotification: (() -> Void)?

    private var alertChecks: [AlertKind: NSButton] = [:]
    private let thresholdPopUp = NSPopUpButton()
    private let notificationWarning = NSTextField(labelWithString: "")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L.t("Impostazioni di MenuClaude", "MenuClaude Settings")
        window.center()
        self.init(window: window)

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let general = NSTabViewItem(identifier: "general")
        general.label = L.t("Generale", "General")
        general.view = pad(generalPane())
        tabs.addTabViewItem(general)

        let alerts = NSTabViewItem(identifier: "alerts")
        alerts.label = L.t("Avvisi", "Alerts")
        alerts.view = pad(alertsPane())
        tabs.addTabViewItem(alerts)

        let root = NSView()
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        window.contentView = root
    }

    func show() {
        syncNotificationWarning()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Generale

    private func generalPane() -> NSView {
        let settings = Settings.shared

        let display = NSPopUpButton()
        for mode in DisplayMode.allCases { display.addItem(withTitle: mode.label) }
        display.selectItem(at: DisplayMode.allCases.firstIndex(of: settings.displayMode) ?? 0)
        display.target = self
        display.action = #selector(changeDisplay(_:))

        let interval = NSPopUpButton()
        for value in Settings.refreshChoices {
            interval.addItem(withTitle: L.t("Ogni \(Settings.refreshLabel(value))",
                                            "Every \(Settings.refreshLabel(value))"))
        }
        interval.selectItem(at: Settings.refreshChoices.firstIndex { abs($0 - settings.refreshInterval) < 0.5 } ?? 2)
        interval.target = self
        interval.action = #selector(changeInterval(_:))

        let language = NSPopUpButton()
        for value in Language.allCases { language.addItem(withTitle: value.label) }
        language.selectItem(at: Language.allCases.firstIndex(of: settings.language) ?? 0)
        language.target = self
        language.action = #selector(changeLanguage(_:))

        let ring = check(L.t("Mostra l'anello di avanzamento", "Show the progress ring"),
                         settings.showRing, #selector(toggleRing(_:)))
        let color = check(L.t("Icona a colori", "Coloured icon"),
                          settings.colorInMenuBar, #selector(toggleColor(_:)))
        let autoRenew = check(L.t("Rinnova il token automaticamente", "Renew the token automatically"),
                              settings.autoRenewToken, #selector(toggleAutoRenew(_:)))
        let updates = check(L.t("Cerca aggiornamenti automaticamente", "Check for updates automatically"),
                            settings.checkForUpdates, #selector(toggleUpdates(_:)))
        let login = check(L.t("Avvia MenuClaude al login", "Launch MenuClaude at login"),
                          LaunchAtLogin.isEnabled, #selector(toggleLogin(_:)))

        let renewNote = note(L.t(
            "Quando il Mac torna dallo standby l'access token è quasi sempre scaduto: senza questo, il conteggio resta fermo finché non lo rinnovi a mano.",
            "After the Mac wakes from standby the access token is nearly always expired: without this, the count stays frozen until you renew it by hand."
        ))

        return form([
            (L.t("Nella barra dei menu", "In the menu bar"), display),
            (L.t("Aggiornamento", "Refresh"), interval),
            (L.t("Lingua", "Language"), language),
            (nil, ring),
            (nil, color),
            (nil, autoRenew),
            (nil, renewNote),
            (nil, updates),
            (nil, login),
        ])
    }

    // MARK: - Avvisi

    private func alertsPane() -> NSView {
        let settings = Settings.shared

        for value in Settings.thresholdChoices { thresholdPopUp.addItem(withTitle: "\(Int(value))%") }
        thresholdPopUp.selectItem(at: Settings.thresholdChoices.firstIndex { abs($0 - settings.alertThreshold) < 0.5 } ?? 2)
        thresholdPopUp.target = self
        thresholdPopUp.action = #selector(changeThreshold(_:))

        var rows: [(String?, NSView)] = [(L.t("Soglia", "Threshold"), thresholdPopUp)]
        for kind in AlertKind.allCases {
            let box = check(kind.label, settings.isAlertEnabled(kind), #selector(toggleAlert(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            alertChecks[kind] = box
            rows.append((nil, box))
        }

        let test = NSButton(title: L.t("Invia una notifica di prova", "Send a test notification"),
                            target: self, action: #selector(sendTest))
        test.bezelStyle = .rounded
        rows.append((nil, test))

        notificationWarning.font = NSFont.systemFont(ofSize: 11)
        notificationWarning.textColor = Theme.color(for: .warning)
        notificationWarning.isHidden = true
        let warningButton = NSButton(
            title: L.t("Apri Impostazioni di Sistema", "Open System Settings"),
            target: self,
            action: #selector(openNotificationSettings)
        )
        warningButton.bezelStyle = .inline
        warningButton.controlSize = .small
        let warningRow = NSStackView(views: [notificationWarning, warningButton])
        warningRow.orientation = .vertical
        warningRow.alignment = .leading
        warningRow.spacing = 4
        rows.append((nil, warningRow))

        return form(rows)
    }

    private func syncNotificationWarning() {
        let denied = Notifier.shared.authorization == .denied
        notificationWarning.isHidden = !denied
        notificationWarning.superview?.isHidden = !denied
        if denied {
            notificationWarning.stringValue = L.t(
                "macOS non autorizza le notifiche di MenuClaude: gli avvisi non arriveranno.",
                "macOS is not allowing MenuClaude notifications: alerts will not arrive."
            )
        }
    }

    // MARK: - Impalcatura

    private func pad(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -18),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
        ])
        return container
    }

    /// Etichette a destra, controlli a sinistra: la disposizione di sistema.
    private func form(_ rows: [(String?, NSView)]) -> NSView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        for (title, control) in rows {
            let label: NSView
            if let title = title {
                let field = NSTextField(labelWithString: title)
                field.font = NSFont.systemFont(ofSize: 12)
                field.textColor = .secondaryLabelColor
                label = field
            } else {
                label = NSGridCell.emptyContentView
            }
            grid.addRow(with: [label, control])
        }
        return grid
    }

    private func check(_ title: String, _ value: Bool, _ action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: action)
        box.state = value ? .on : .off
        return box
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont.systemFont(ofSize: 10)
        field.textColor = .tertiaryLabelColor
        field.preferredMaxLayoutWidth = 300
        return field
    }

    // MARK: - Azioni

    private func changed() { onChange?() }

    @objc private func changeDisplay(_ sender: NSPopUpButton) {
        Settings.shared.displayMode = DisplayMode.allCases[sender.indexOfSelectedItem]
        changed()
    }

    @objc private func changeInterval(_ sender: NSPopUpButton) {
        Settings.shared.refreshInterval = Settings.refreshChoices[sender.indexOfSelectedItem]
        changed()
    }

    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        Settings.shared.language = Language.allCases[sender.indexOfSelectedItem]
        changed()
        // Le etichette di questa finestra sono già state costruite: si rifà.
        window?.close()
    }

    @objc private func changeThreshold(_ sender: NSPopUpButton) {
        Settings.shared.alertThreshold = Settings.thresholdChoices[sender.indexOfSelectedItem]
        changed()
    }

    @objc private func toggleRing(_ sender: NSButton) {
        Settings.shared.showRing = sender.state == .on
        changed()
    }

    @objc private func toggleColor(_ sender: NSButton) {
        Settings.shared.colorInMenuBar = sender.state == .on
        changed()
    }

    @objc private func toggleAutoRenew(_ sender: NSButton) {
        Settings.shared.autoRenewToken = sender.state == .on
        changed()
    }

    @objc private func toggleUpdates(_ sender: NSButton) {
        Settings.shared.checkForUpdates = sender.state == .on
        changed()
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        LaunchAtLogin.set(sender.state == .on)
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func toggleAlert(_ sender: NSButton) {
        guard
            let raw = sender.identifier?.rawValue,
            let kind = AlertKind(rawValue: raw)
        else { return }
        Settings.shared.setAlert(kind, enabled: sender.state == .on)
        if sender.state == .on { Notifier.shared.requestAuthorization() }
        syncNotificationWarning()
        changed()
    }

    @objc private func sendTest() {
        onTestNotification?()
        // Il permesso può essere stato negato proprio ora.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.syncNotificationWarning() }
    }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
