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

    private let refresher = TokenRefresher()
    private var isRenewing = false
    /// Il rinnovo automatico non deve poter diventare un ciclo: se dopo un
    /// tentativo il token è ancora rifiutato, si aspetta prima di riprovare.
    private var lastAutoRenew = Date.distantPast

    private var alarmDate: Date?

    private let updater = Updater()
    private var pendingUpdate: AvailableUpdate?
    private var updateTimer: Timer?
    private static let updateInterval: TimeInterval = 24 * 3600

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
        scheduleUpdateTimer()
        syncAlarmState()

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
        updateTimer?.invalidate()
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

    // MARK: - Aggiornamenti dell'app

    private func scheduleUpdateTimer() {
        updateTimer?.invalidate()
        guard Settings.shared.checkForUpdates else { return }
        let timer = Timer(
            timeInterval: AppDelegate.updateInterval,
            target: self,
            selector: #selector(checkForUpdatesQuietly),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
        // Un controllo all'avvio, senza fretta e senza finestre.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkForUpdatesQuietly()
        }
    }

    /// Controllo di sfondo: se c'è una novità compare in cima al menu, e — se
    /// l'avviso è attivo — arriva una notifica. Nessuna finestra a sorpresa.
    @objc private func checkForUpdatesQuietly() {
        guard Settings.shared.checkForUpdates else { return }
        updater.check { [weak self] result in
            guard let self = self, case .success(let update) = result, let update = update else { return }
            let alreadyKnown = self.pendingUpdate?.version == update.version
            self.pendingUpdate = update
            guard !alreadyKnown, Settings.shared.isAlertEnabled(.updateAvailable) else { return }
            Notifier.shared.send(
                title: L.t("MenuClaude \(update.version) è disponibile",
                           "MenuClaude \(update.version) is available"),
                body: L.t("Apri il menu per aggiornare", "Open the menu to update"),
                identifier: AlertKind.updateAvailable.rawValue
            )
        }
    }

    @objc private func menuCheckForUpdates() {
        updater.check { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.showUpdateAlert(
                    title: L.t("Controllo non riuscito", "Check failed"),
                    text: error.message
                )
            case .success(nil):
                self.showUpdateAlert(
                    title: L.t("Sei già aggiornato", "You're up to date"),
                    text: L.t("MenuClaude \(self.updater.currentVersion) è l'ultima versione.",
                              "MenuClaude \(self.updater.currentVersion) is the latest version.")
                )
            case .success(let update?):
                self.pendingUpdate = update
                self.offerUpdate(update)
            }
        }
    }

    @objc private func menuInstallUpdate() {
        guard let update = pendingUpdate else {
            menuCheckForUpdates()
            return
        }
        offerUpdate(update)
    }

    private func offerUpdate(_ update: AvailableUpdate) {
        let alert = NSAlert()
        alert.messageText = L.t("MenuClaude \(update.version) è disponibile",
                                "MenuClaude \(update.version) is available")
        let size = ByteCountFormatter.string(fromByteCount: Int64(update.size), countStyle: .file)
        alert.informativeText = L.t(
            "Hai la versione \(updater.currentVersion). L'aggiornamento pesa \(size); "
                + "MenuClaude si chiuderà e si riaprirà da sola.",
            "You have version \(updater.currentVersion). The update is \(size); "
                + "MenuClaude will quit and reopen by itself."
        )
        alert.addButton(withTitle: L.t("Aggiorna", "Update"))
        alert.addButton(withTitle: L.t("Più tardi", "Later"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let progress = NSAlert()
        progress.messageText = L.t("Aggiornamento in corso…", "Updating…")
        progress.informativeText = L.t("MenuClaude si riaprirà da sola quando ha finito.",
                                       "MenuClaude will reopen by itself when it's done.")
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        progress.accessoryView = spinner

        updater.install(update) { [weak self] error in
            NSApp.stopModal()
            guard let error = error else {
                // Lo script di scambio aspetta che questo processo sparisca.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                return
            }
            self?.showUpdateAlert(
                title: L.t("Aggiornamento non riuscito", "Update failed"),
                text: error.message
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        progress.runModal()
    }

    private func showUpdateAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
                self.autoRenewIfNeeded(after: error)
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
            self.panel.showAlarm(at: self.alarmDate, resetsAt: self.snapshot?.session?.resetsAt)
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
        menu.addItem(item(L.t("Rinnova il token", "Renew the token"), #selector(menuRenewToken), key: ""))

        if let resetsAt = snapshot?.session?.resetsAt, resetsAt > Date() {
            let title: String
            if let alarmDate = alarmDate {
                title = L.t("Annulla la sveglia (\(Format.resetStamp(alarmDate) ?? ""))",
                            "Cancel the alarm (\(Format.resetStamp(alarmDate) ?? ""))")
            } else {
                let remaining = Format.countdown(to: resetsAt) ?? ""
                title = L.t("Avvisami al reset della sessione (fra \(remaining))",
                            "Alert me when the session resets (in \(remaining))")
            }
            let entry = item(title, #selector(menuToggleAlarm), key: "")
            entry.state = alarmDate != nil ? .on : .off
            menu.addItem(entry)
        }

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

        let autoRenew = item(L.t("Rinnova il token automaticamente", "Renew the token automatically"),
                             #selector(menuToggleAutoRenew), key: "")
        autoRenew.state = settings.autoRenewToken ? .on : .off
        menu.addItem(autoRenew)

        let login = item(L.t("Avvia al login", "Launch at login"), #selector(menuToggleLogin), key: "")
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        if let update = pendingUpdate {
            let entry = item(L.t("Aggiorna a MenuClaude \(update.version)",
                                 "Update to MenuClaude \(update.version)"),
                             #selector(menuInstallUpdate), key: "")
            // In grassetto: è l'unica voce che vale la pena notare adesso.
            entry.attributedTitle = NSAttributedString(
                string: entry.title,
                attributes: [.font: NSFont.menuFont(ofSize: 0).bold()]
            )
            menu.addItem(entry)
        } else {
            menu.addItem(item(L.t("Cerca aggiornamenti…", "Check for updates…"),
                              #selector(menuCheckForUpdates), key: ""))
        }

        menu.addItem(item(L.t("Apri utilizzo su claude.ai", "Open usage on claude.ai"), #selector(menuOpenWeb), key: ""))
        menu.addItem(.separator())
        let version = item(L.t("Versione \(updater.currentVersion)", "Version \(updater.currentVersion)"),
                           #selector(menuCheckForUpdates), key: "")
        version.isEnabled = false
        menu.addItem(version)
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

    @objc private func menuRenewToken() {
        togglePopoverForRenewal()
        renewToken()
    }

    /// Il rinnovo mostra il suo esito nel pannello: se è chiuso, si apre.
    /// Arma o disarma la sveglia per il reset della sessione.
    private func toggleSessionAlarm() {
        if alarmDate != nil {
            SessionAlarm.cancel()
            alarmDate = nil
            panel.showAlarm(at: nil, resetsAt: snapshot?.session?.resetsAt)
            return
        }
        guard let resetsAt = snapshot?.session?.resetsAt, resetsAt > Date() else { return }

        // Serve il permesso alle notifiche: senza, la sveglia non suonerebbe mai.
        Notifier.shared.requestAuthorization { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.showNotificationProblem()
                return
            }
            SessionAlarm.schedule(at: resetsAt) { fireDate in
                self.alarmDate = fireDate
                self.panel.showAlarm(at: fireDate, resetsAt: resetsAt)
                if fireDate == nil {
                    self.showUpdateAlert(
                        title: L.t("Sveglia non impostata", "Alarm not set"),
                        text: L.t("macOS non ha accettato la notifica programmata.",
                                  "macOS did not accept the scheduled notification.")
                    )
                }
            }
        }
    }

    /// La sveglia sopravvive alla chiusura dell'app, quindi allo stato del
    /// pulsante si risale da quella davvero in coda nel sistema.
    private func syncAlarmState() {
        SessionAlarm.pending { [weak self] date in
            guard let self = self else { return }
            self.alarmDate = date
            self.panel.showAlarm(at: date, resetsAt: self.snapshot?.session?.resetsAt)
        }
    }

    private func togglePopoverForRenewal() {
        guard !popover.isShown, let button = statusItem.button else { return }
        panel.render(snapshot: snapshot, error: lastError,
                     retryAt: backoff.retryAt, serverStatus: serverStatus)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

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

    @objc private func menuToggleAlarm() {
        toggleSessionAlarm()
    }

    @objc private func menuToggleAutoRenew() {
        Settings.shared.autoRenewToken.toggle()
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

    func popoverDidRequestTokenRenewal() { renewToken() }

    func popoverDidRequestAlarmToggle() { toggleSessionAlarm() }

    /// Il caso tipico: il Mac torna dallo standby, il token è scaduto da ore e
    /// nessuno lo ha rinnovato. Invece di lasciare l'app ferma finché non si
    /// preme il pulsante, ci prova da sola — una volta, e non più spesso di
    /// ogni cinque minuti.
    private func autoRenewIfNeeded(after error: UsageError) {
        guard AutoRenewPolicy.shouldRenew(
            after: error,
            enabled: Settings.shared.autoRenewToken,
            alreadyRenewing: isRenewing,
            lastAttempt: lastAutoRenew
        ) else { return }
        lastAutoRenew = Date()
        renewToken(automatic: true)
    }

    /// Rinnovo manuale del token. Manuale di proposito: tocca le credenziali di
    /// Claude Code, quindi deve essere un gesto deliberato e riconoscibile.
    private func renewToken(automatic: Bool = false) {
        guard !isRenewing else { return }
        isRenewing = true
        panel.renewalInProgress = true
        panel.showRenewalState(
            automatic
                ? L.t("Token scaduto — lo rinnovo…", "Token expired — renewing…")
                : L.t("Rinnovo del token in corso…", "Renewing the token…"),
            busy: true, failed: false
        )

        refresher.refresh { [weak self] result in
            guard let self = self else { return }
            self.isRenewing = false
            self.panel.renewalInProgress = false

            switch result {
            case .success:
                self.lastError = nil
                self.backoff.reset()
                self.backoff.save()
                self.panel.showRenewalState(L.t("Token rinnovato", "Token renewed"),
                                            busy: false, failed: false)
                self.refresh(force: true)

            case .failure(let error):
                self.panel.showRenewalState(error.message, busy: false, failed: true)
                // Questo va detto comunque, anche se il rinnovo era automatico:
                // in gioco c'è il login di Claude Code.
                if case .tokenRenewedButNotSaved = error { self.warnAboutUnsavedToken() }
            }
        }
    }

    /// Il caso che non va nascosto: il token nuovo funziona qui, ma nel
    /// portachiavi è rimasto il vecchio. Se il server lo ha ruotato, Claude Code
    /// ha in mano un refresh token ormai invalido.
    private func warnAboutUnsavedToken() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L.t("Token rinnovato ma non salvato",
                                "Token renewed but not saved")
        alert.informativeText = L.t(
            """
            MenuClaude ha ottenuto un token valido e continuerà a funzionare, ma \
            macOS non gli ha permesso di riscriverlo nel portachiavi.

            Se il server ha sostituito il refresh token, quello che Claude Code \
            ha salvato non vale più: al prossimo problema di autenticazione \
            esegui `claude auth login` nel Terminale.
            """,
            """
            MenuClaude obtained a valid token and will keep working, but macOS \
            would not let it write the token back to the Keychain.

            If the server replaced the refresh token, the one Claude Code has \
            stored is no longer valid: next time authentication fails, run \
            `claude auth login` in a Terminal.
            """
        )
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func popoverDidRequestMenu(from view: NSView) { showMenu(from: view) }
}
