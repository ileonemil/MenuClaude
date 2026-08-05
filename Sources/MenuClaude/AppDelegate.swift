import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, PopoverDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let panel = PopoverViewController()
    private let client = UsageClient()

    private var fetchTimer: Timer?
    private var uiTimer: Timer?

    private var snapshot: UsageSnapshot?
    private var lastError: UsageError?
    private var isFetching = false
    private var lastPopoverClose = Date.distantPast

    /// L'endpoint risponde 429 se lo si interroga troppo spesso.
    private var backoff = Backoff.restored()
    private var lastAttempt = Date.distantPast
    /// Un solo tentativo manuale per ogni attesa: premere "Aggiorna" a ripetizione
    /// durante un 429 non fa che allungarla.
    private var forcedAttemptSpentFor = Date.distantPast

    /// Quante volte di fila il dato è tornato identico. Se non cambia niente —
    /// di notte, o mentre il Mac è inattivo — interrogare ogni cinque minuti è
    /// solo un modo per esaurire la quota di richieste.
    private var idleRounds = 0
    private static let maximumInterval: TimeInterval = 1800

    private let statusClient = StatusClient()
    private let alerts = AlertCenter()
    private var serverStatus: ServerStatus?
    private var statusTimer: Timer?
    /// Lo stato dei server sta su un'altra pagina, senza rate limit stretti.
    private static let statusInterval: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Due copie in esecuzione raddoppierebbero le chiamate all'API, che ha
        // un rate limit stretto: la seconda si fa da parte.
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.menuclaude.MenuClaude")
            .filter { $0.processIdentifier != mine }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        panel.delegate = self
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        LaunchAtLogin.removeLegacyAgents()
        // Gli avvisi sulle soglie sono attivi di default: senza permesso non
        // arriverebbero mai, quindi lo chiediamo subito.
        if Settings.shared.anyAlertEnabled {
            Notifier.shared.requestAuthorization()
        } else {
            Notifier.shared.refreshAuthorization()
        }

        renderStatusItem()
        refresh(force: false)
        scheduleFetchTimer()
        scheduleStatusTimer()

        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        fetchTimer?.invalidate()
        uiTimer?.invalidate()
        statusTimer?.invalidate()
    }

    // MARK: - Aggiornamento dati

    /// Un solo appuntamento alla volta, ricalcolato dopo ogni tentativo: così
    /// l'attesa dopo un 429 e il rallentamento quando il dato è fermo non si
    /// sommano a un timer periodico che continua a scattare per conto suo.
    private func scheduleFetchTimer() {
        fetchTimer?.invalidate()

        let base = Settings.shared.refreshInterval
        let idleFactor = pow(2.0, Double(min(idleRounds, 3)))
        var delay = min(base * idleFactor, AppDelegate.maximumInterval)
        if backoff.isWaiting() {
            delay = max(delay, backoff.retryAt.timeIntervalSinceNow)
        }

        let timer = Timer(fire: Date().addingTimeInterval(delay), interval: 0, repeats: false) {
            [weak self] _ in
            self?.refresh(force: false)
        }
        timer.tolerance = min(delay * 0.2, 60)
        RunLoop.main.add(timer, forMode: .common)
        fetchTimer = timer
    }

    private func scheduleStatusTimer() {
        statusTimer?.invalidate()
        let timer = Timer(
            timeInterval: AppDelegate.statusInterval,
            target: self,
            selector: #selector(refreshServerStatus),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        refreshServerStatus()
    }

    @objc private func refreshServerStatus() {
        statusClient.fetch { [weak self] status in
            guard let self = self, let status = status else { return }
            self.alerts.evaluate(status: status)
            self.serverStatus = status
            self.panel.render(
                snapshot: self.snapshot,
                error: self.lastError,
                retryAt: self.backoff.retryAt,
                serverStatus: status
            )
        }
    }

    /// `force` = richiesta esplicita dell'utente: riprova subito anche dopo un
    /// rifiuto del portachiavi.
    private func refresh(force: Bool) {
        guard !isFetching else { return }
        let now = Date()

        if backoff.isWaiting(now: now) {
            // Durante un'attesa concediamo un solo tentativo manuale, poi si
            // aspetta: il pannello dice già quando riproveremo da soli.
            guard force, forcedAttemptSpentFor != backoff.retryAt else { return }
            forcedAttemptSpentFor = backoff.retryAt
        }
        if now.timeIntervalSince(lastAttempt) < 5 { return }
        lastAttempt = now

        isFetching = true
        client.fetch(force: force) { [weak self] result in
            guard let self = self else { return }
            self.isFetching = false
            switch result {
            case .success(let fresh):
                // Se nulla è cambiato, la prossima interrogazione può aspettare.
                if let previous = self.snapshot, previous.isEquivalent(to: fresh) {
                    self.idleRounds += 1
                } else {
                    self.idleRounds = 0
                }
                self.snapshot = fresh
                self.lastError = nil
                self.backoff.reset()

            case .failure(let error):
                self.lastError = error
                // Teniamo l'ultimo dato buono: meglio un valore stantio che un vuoto.
                if case .rateLimited(let retryAfter) = error {
                    self.backoff.record(suggested: retryAfter, escalate: !force)
                }
            }
            self.backoff.save()
            self.alerts.evaluate(snapshot: self.snapshot)
            self.alerts.evaluate(error: self.lastError)
            self.renderStatusItem()
            self.panel.render(
                snapshot: self.snapshot,
                error: self.lastError,
                retryAt: self.backoff.retryAt,
                serverStatus: self.serverStatus
            )
            self.scheduleFetchTimer()
        }
    }

    @objc private func systemDidWake() {
        // Il Mac ha dormito: il timer non è scattato e il dato è vecchio. Ma
        // dopo un sonno lungo anche l'ultima attesa può essere scaduta, quindi
        // si passa dalla normale programmazione invece di sparare una richiesta.
        idleRounds = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            if self.backoff.isWaiting() {
                self.scheduleFetchTimer()
            } else {
                self.refresh(force: false)
            }
        }
    }

    @objc private func appearanceChanged() {
        renderStatusItem()
    }

    private func tick() {
        renderStatusItem()
        if popover.isShown { panel.tick() }
    }

    // MARK: - Barra dei menu

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        let settings = Settings.shared
        let session = snapshot?.session
        let weekly = snapshot?.weekly

        let severity = session?.severity ?? .normal
        if settings.displayMode == .rings {
            button.image = RingIcon.concentric(
                session: (session?.percent ?? 0) / 100,
                window: session?.windowProgress() ?? 0,
                weekly: (weekly?.percent ?? 0) / 100,
                sessionSeverity: severity,
                weeklySeverity: weekly?.severity ?? .normal,
                colored: settings.colorInMenuBar
            )
        } else {
            button.image = settings.showRing
                ? RingIcon.image(
                    progress: (session?.percent ?? 0) / 100,
                    severity: severity,
                    colored: settings.colorInMenuBar
                )
                : nil
        }

        guard snapshot != nil else {
            button.attributedTitle = styled(lastError == nil ? "…" : "!", dimmed: true)
            button.toolTip = lastError?.message ?? L.t("Caricamento…", "Loading…")
            return
        }

        var parts: [String] = []
        switch settings.displayMode {
        case .iconOnly, .rings:
            parts = []
        case .sessionOnly:
            if let s = session { parts = [Format.percent(s.percent)] }
        case .sessionAndWeekly:
            if let s = session { parts.append(Format.percent(s.percent)) }
            if let w = weekly { parts.append(Format.percent(w.percent)) }
        case .sessionAndTimer:
            if let s = session { parts.append(Format.percent(s.percent)) }
            if let t = Format.countdown(to: session?.resetsAt) { parts.append(t) }
        case .everything:
            if let s = session { parts.append(Format.percent(s.percent)) }
            if let t = Format.countdown(to: session?.resetsAt) { parts.append(t) }
            if let w = weekly { parts.append(Format.percent(w.percent)) }
        }

        button.attributedTitle = parts.isEmpty
            ? NSAttributedString(string: "")
            : styled(parts.joined(separator: " · "), dimmed: false)
        button.toolTip = tooltipText()
    }

    private func styled(_ text: String, dimmed: Bool) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monoDigits(11.5, .medium),
                .foregroundColor: dimmed ? NSColor.tertiaryLabelColor : NSColor.labelColor,
                .baselineOffset: 0.5,
            ]
        )
    }

    private func tooltipText() -> String {
        guard let snapshot = snapshot else { return "" }
        var lines: [String] = []
        if Settings.shared.displayMode == .rings {
            lines.append(L.t("Anelli: esterno sessione · centrale timer · interno settimana",
                             "Rings: outer session · middle timer · inner week"))
        }
        for limit in [snapshot.session, snapshot.weekly].compactMap({ $0 }) + snapshot.secondaryWeekly {
            var line = "\(limit.label): \(Format.percent(limit.percent))"
            if let remaining = Format.countdown(to: limit.resetsAt) {
                line += L.t(" · reset tra \(remaining)", " · resets in \(remaining)")
            }
            lines.append(line)
        }
        if let extra = snapshot.extra {
            lines.append(L.t("Crediti extra: \(extra.usedText) di \(extra.limitText)",
                             "Extra credits: \(extra.usedText) of \(extra.limitText)"))
        }
        if let error = lastError { lines.append("⚠︎ \(error.message)") }
        lines.append(L.t("Aggiornato \(Format.agoText(snapshot.fetchedAt))",
                         "Updated \(Format.agoText(snapshot.fetchedAt))"))
        return lines.joined(separator: "\n")
    }

    // MARK: - Interazione

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)

        if isRightClick {
            showMenu(from: statusItem.button)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Un popover `.transient` si chiude da sé al clic fuori — compreso il
        // clic sull'icona: senza questa guardia si richiuderebbe e riaprirebbe.
        if Date().timeIntervalSince(lastPopoverClose) < 0.25 { return }
        guard let button = statusItem.button else { return }
        panel.render(
            snapshot: snapshot,
            error: lastError,
            retryAt: backoff.retryAt,
            serverStatus: serverStatus
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        // Se il dato è vecchio, l'apertura vale come richiesta di aggiornamento.
        // Aprire il pannello vale come aggiornamento solo se il dato è più
        // vecchio dell'intervallo scelto: aprirlo e richiuderlo dieci volte non
        // deve tradursi in dieci chiamate.
        if let fetched = snapshot?.fetchedAt,
           Date().timeIntervalSince(fetched) > Settings.shared.refreshInterval {
            refresh(force: false)
        } else if snapshot == nil {
            refresh(force: false)
        }
    }

    private func showMenu(from view: NSView?) {
        let menu = buildMenu()
        if let button = statusItem.button, view === button {
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
        } else if let view = view {
            let point = NSPoint(x: 0, y: view.bounds.height + 4)
            menu.popUp(positioning: nil, at: point, in: view)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = Settings.shared

        if let snapshot = snapshot {
            for limit in [snapshot.session, snapshot.weekly].compactMap({ $0 }) {
                var text = "\(limit.label): \(Format.percent(limit.percent))"
                if let remaining = Format.countdown(to: limit.resetsAt) {
                    text += L.t(" · reset tra \(remaining)", " · resets in \(remaining)")
                }
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(item(L.t("Aggiorna adesso", "Refresh now"), #selector(menuRefresh), key: "r"))

        let display = NSMenu()
        for mode in DisplayMode.allCases {
            let entry = item(mode.label, #selector(menuSetDisplay), key: "")
            entry.tag = mode.rawValue
            entry.state = settings.displayMode == mode ? .on : .off
            display.addItem(entry)
        }
        let displayItem = NSMenuItem(title: L.t("Cosa mostrare", "What to show"), action: nil, keyEquivalent: "")
        displayItem.submenu = display
        menu.addItem(displayItem)

        let intervals = NSMenu()
        for value in Settings.refreshChoices {
            let entry = item(L.t("Ogni \(Settings.refreshLabel(value))", "Every \(Settings.refreshLabel(value))"),
                             #selector(menuSetInterval), key: "")
            entry.tag = Int(value)
            entry.state = abs(settings.refreshInterval - value) < 0.5 ? .on : .off
            intervals.addItem(entry)
        }
        let intervalItem = NSMenuItem(title: L.t("Frequenza aggiornamento", "Update frequency"), action: nil, keyEquivalent: "")
        intervalItem.submenu = intervals
        menu.addItem(intervalItem)

        menu.addItem(alertsMenuItem())

        let ring = item(L.t("Mostra anello", "Show ring"), #selector(menuToggleRing), key: "")
        ring.state = settings.showRing ? .on : .off
        // Gli anelli concentrici sono l'icona: l'opzione non si applica.
        ring.isEnabled = !settings.displayMode.usesOwnIcon
        menu.addItem(ring)

        let color = item(L.t("Icona a colori", "Coloured icon"), #selector(menuToggleColor), key: "")
        color.state = settings.colorInMenuBar ? .on : .off
        color.isEnabled = settings.showRing || settings.displayMode.usesOwnIcon
        menu.addItem(color)

        let languages = NSMenu()
        for language in Language.allCases {
            let entry = item(language.label, #selector(menuSetLanguage), key: "")
            entry.tag = language.rawValue
            entry.state = settings.language == language ? .on : .off
            languages.addItem(entry)
        }
        let languageItem = NSMenuItem(title: L.t("Lingua", "Language"), action: nil, keyEquivalent: "")
        languageItem.submenu = languages
        menu.addItem(languageItem)

        let login = item(L.t("Avvia al login", "Launch at login"), #selector(menuToggleLogin), key: "")
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item(L.t("Apri utilizzo su claude.ai", "Open usage on claude.ai"), #selector(menuOpenWeb), key: ""))
        menu.addItem(.separator())
        menu.addItem(item(L.t("Esci da MenuClaude", "Quit MenuClaude"), #selector(menuQuit), key: "q"))
        return menu
    }

    private func alertsMenuItem() -> NSMenuItem {
        let settings = Settings.shared
        let alerts = NSMenu()

        for kind in AlertKind.allCases {
            let entry = item(kind.label, #selector(menuToggleAlert), key: "")
            entry.representedObject = kind.rawValue
            entry.state = settings.isAlertEnabled(kind) ? .on : .off
            alerts.addItem(entry)
        }

        alerts.addItem(.separator())
        let thresholds = NSMenu()
        for value in Settings.thresholdChoices {
            let entry = item("\(Int(value))%", #selector(menuSetThreshold), key: "")
            entry.tag = Int(value)
            entry.state = abs(settings.alertThreshold - value) < 0.5 ? .on : .off
            thresholds.addItem(entry)
        }
        let thresholdItem = NSMenuItem(title: L.t("Soglia", "Threshold"), action: nil, keyEquivalent: "")
        thresholdItem.submenu = thresholds
        alerts.addItem(thresholdItem)

        alerts.addItem(.separator())
        alerts.addItem(item(L.t("Invia una notifica di prova", "Send a test notification"), #selector(menuTestNotification), key: ""))

        // Se i permessi mancano, dirlo qui evita avvisi che non arrivano mai.
        if settings.anyAlertEnabled && Notifier.shared.authorization == .denied {
            let warning = NSMenuItem(
                title: L.t("⚠︎ Notifiche non autorizzate — Impostazioni di Sistema",
                           "⚠︎ Notifications not allowed — System Settings"),
                action: #selector(menuOpenNotificationSettings),
                keyEquivalent: ""
            )
            warning.target = self
            alerts.addItem(warning)
        }

        let item = NSMenuItem(title: L.t("Avvisi", "Alerts"), action: nil, keyEquivalent: "")
        item.submenu = alerts
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    // MARK: - Voci di menu

    @objc private func menuRefresh() { refresh(force: true) }

    @objc private func menuSetDisplay(_ sender: NSMenuItem) {
        if let mode = DisplayMode(rawValue: sender.tag) {
            Settings.shared.displayMode = mode
            renderStatusItem()
        }
    }

    @objc private func menuSetInterval(_ sender: NSMenuItem) {
        Settings.shared.refreshInterval = TimeInterval(sender.tag)
        scheduleFetchTimer()
    }

    @objc private func menuToggleRing() {
        Settings.shared.showRing.toggle()
        renderStatusItem()
    }

    @objc private func menuToggleColor() {
        Settings.shared.colorInMenuBar.toggle()
        renderStatusItem()
    }

    @objc private func menuToggleLogin() {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
    }

    @objc private func menuToggleAlert(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = AlertKind(rawValue: raw) else { return }
        let enabled = !Settings.shared.isAlertEnabled(kind)
        Settings.shared.setAlert(kind, enabled: enabled)

        if enabled {
            // Il permesso si chiede quando serve davvero, non all'avvio.
            Notifier.shared.requestAuthorization()
            if kind == .serverStatus { refreshServerStatus() }
        }
    }

    @objc private func menuSetThreshold(_ sender: NSMenuItem) {
        Settings.shared.alertThreshold = Double(sender.tag)
    }

    @objc private func menuSetLanguage(_ sender: NSMenuItem) {
        guard let language = Language(rawValue: sender.tag) else { return }
        Settings.shared.language = language
        // Tutte le stringhe si risolvono al momento del disegno: basta ridisegnare.
        renderStatusItem()
        panel.render(
            snapshot: snapshot,
            error: lastError,
            retryAt: backoff.retryAt,
            serverStatus: serverStatus
        )
    }

    @objc private func menuTestNotification() {
        Notifier.shared.requestAuthorization { granted in
            guard granted else {
                self.showNotificationProblem()
                return
            }
            Notifier.shared.send(
                title: L.t("MenuClaude funziona", "MenuClaude works"),
                body: L.t("Gli avvisi arriveranno così.", "This is how alerts will look."),
                identifier: "test"
            )
        }
    }

    private func showNotificationProblem() {
        let alert = NSAlert()
        alert.messageText = L.t("Notifiche non autorizzate", "Notifications not allowed")
        alert.informativeText = L.t(
            "macOS non permette a MenuClaude di inviare notifiche.\nAbilitale in Impostazioni di Sistema › Notifiche › MenuClaude.",
            "macOS is not letting MenuClaude send notifications.\nEnable them in System Settings › Notifications › MenuClaude."
        )
        if let detail = Notifier.shared.lastError { alert.informativeText += "\n\n(\(detail))" }
        alert.addButton(withTitle: L.t("Apri Impostazioni", "Open Settings"))
        alert.addButton(withTitle: L.t("Chiudi", "Close"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openNotificationSettings() }
    }

    @objc private func menuOpenNotificationSettings() {
        openNotificationSettings()
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuOpenWeb() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
    }

    // MARK: - PopoverDelegate

    func popoverDidRequestRefresh() { refresh(force: true) }

    func popoverDidRequestMenu(from view: NSView) { showMenu(from: view) }
}
