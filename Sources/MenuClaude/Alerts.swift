import Cocoa
import UserNotifications

enum AlertKind: String, CaseIterable {
    case sessionThreshold
    case weeklyThreshold
    case extraThreshold
    case limitReached
    case sessionReset
    case serverStatus
    case fetchFailure
    case updateAvailable

    var label: String {
        switch self {
        case .sessionThreshold: return L.t("Sessione oltre la soglia", "Session over threshold")
        case .weeklyThreshold: return L.t("Settimana oltre la soglia", "Week over threshold")
        case .extraThreshold: return L.t("Crediti extra oltre la soglia", "Extra credits over threshold")
        case .limitReached: return L.t("Limite raggiunto (100%)", "Limit reached (100%)")
        case .sessionReset: return L.t("Sessione azzerata", "Session reset")
        case .serverStatus: return L.t("Stato dei server Claude", "Claude server status")
        case .fetchFailure: return L.t("Errori di aggiornamento prolungati", "Prolonged update failures")
        case .updateAvailable: return L.t("Nuova versione di MenuClaude", "New MenuClaude version")
        }
    }

    /// Acceso di default: le soglie e i limiti. Il resto è opt-in.
    var enabledByDefault: Bool {
        switch self {
        case .sessionThreshold, .weeklyThreshold, .limitReached, .updateAvailable: return true
        default: return false
        }
    }
}

/// Consegna le notifiche di sistema. Un'app senza notarizzazione può comunque
/// usare UNUserNotificationCenter, ma solo se il bundle è firmato: se la
/// registrazione fallisce lo diciamo invece di fallire in silenzio.
final class Notifier {
    static let shared = Notifier()

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var lastError: String?

    private var center: UNUserNotificationCenter? {
        // Fuori da un bundle valido la chiamata va in crash: meglio verificare.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        guard let center = center else {
            lastError = L.t("L'app non è avviata come bundle", "The app is not running from a bundle")
            completion?(false)
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error = error { self?.lastError = error.localizedDescription }
                self?.authorization = granted ? .authorized : .denied
                completion?(granted)
            }
        }
    }

    func refreshAuthorization() {
        center?.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async { self?.authorization = settings.authorizationStatus }
        }
    }

    func send(title: String, body: String, identifier: String) {
        guard let center = center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(identifier)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        center.add(request) { [weak self] error in
            guard let error = error else { return }
            DispatchQueue.main.async { self?.lastError = error.localizedDescription }
        }
    }
}

/// Decide *quando* notificare. La regola è sempre la stessa: si avvisa al
/// passaggio della soglia, non a ogni aggiornamento sopra la soglia, e la
/// memoria si azzera quando la finestra di quota si azzera.
final class AlertCenter {
    typealias Delivery = (_ title: String, _ body: String, _ identifier: String) -> Void

    private let settings: Settings
    private let defaults: UserDefaults
    private let deliver: Delivery

    private var lastStatusIndicator: String?
    private var failingSince: Date?

    init(
        settings: Settings = .shared,
        defaults: UserDefaults = .standard,
        deliver: @escaping Delivery = { Notifier.shared.send(title: $0, body: $1, identifier: $2) }
    ) {
        self.settings = settings
        self.defaults = defaults
        self.deliver = deliver
    }

    func evaluate(snapshot: UsageSnapshot?) {
        guard let snapshot = snapshot else { return }
        let threshold = settings.alertThreshold

        if let session = snapshot.session {
            check(limit: session, kind: .sessionThreshold, threshold: threshold,
                  title: L.t("Sessione: ", "Session: ") + Format.percent(session.percent))
            checkReset(session)
        }
        if let weekly = snapshot.weekly {
            check(limit: weekly, kind: .weeklyThreshold, threshold: threshold,
                  title: L.t("Settimana: ", "Week: ") + Format.percent(weekly.percent))
        }
        if let extra = snapshot.extra {
            let asLimit = UsageLimit(kind: "extra", group: "extra", percent: extra.percent,
                                     resetsAt: nil, severity: extra.severity, isActive: true)
            check(limit: asLimit, kind: .extraThreshold, threshold: threshold,
                  title: L.t("Crediti extra: ", "Extra credits: ") + Format.percent(extra.percent),
                  detail: L.t("\(extra.usedText) di \(extra.limitText)", "\(extra.usedText) of \(extra.limitText)"))
        }
    }

    // MARK: - Soglie

    /// Due letture della stessa finestra riportano l'istante di reset con
    /// qualche decimo di secondo di scarto: il server non è preciso al
    /// millisecondo. Confrontarlo alla virgola faceva sembrare nuova ogni
    /// finestra, azzerando la memoria e rimandando lo stesso avviso a ogni giro.
    private static let sameWindowTolerance: TimeInterval = 300

    /// Distanza minima fra due avvisi dello stesso tipo. È una rete di
    /// sicurezza: qualunque cosa sfugga alla logica delle finestre, non si
    /// trasforma in una raffica di notifiche.
    private static let minimumRepeat: TimeInterval = 1800

    private func windowChanged(key: String, resetsAt: Date?) -> Bool {
        let current = resetsAt?.timeIntervalSince1970 ?? 0
        guard let stored = defaults.object(forKey: key) as? Double else {
            // Prima osservazione: è l'inizio, non un cambio di finestra.
            defaults.set(current, forKey: key)
            return false
        }
        guard abs(stored - current) > AlertCenter.sameWindowTolerance else { return false }
        defaults.set(current, forKey: key)
        return true
    }

    private func deliverOnce(_ title: String, _ body: String, _ kind: AlertKind) {
        let key = "alert.\(kind.rawValue).lastSent"
        let last = defaults.double(forKey: key)
        if last > 0, Date().timeIntervalSince1970 - last < AlertCenter.minimumRepeat { return }
        defaults.set(Date().timeIntervalSince1970, forKey: key)
        deliver(title, body, kind.rawValue)
    }

    private func check(
        limit: UsageLimit,
        kind: AlertKind,
        threshold: Double,
        title: String,
        detail: String? = nil
    ) {
        let windowKey = "alert.\(kind.rawValue).window"
        let firedKey = "alert.\(kind.rawValue).fired"
        let reachedKey = "alert.\(limit.kind).reached"

        // Una nuova finestra cancella la memoria della vecchia — compresa la
        // pausa fra due avvisi uguali, che altrimenti soffocherebbe il primo
        // avviso legittimo della finestra appena aperta.
        if windowChanged(key: windowKey, resetsAt: limit.resetsAt) {
            defaults.set(false, forKey: firedKey)
            defaults.set(false, forKey: reachedKey)
            defaults.removeObject(forKey: "alert.\(kind.rawValue).lastSent")
            defaults.removeObject(forKey: "alert.\(AlertKind.limitReached.rawValue).lastSent")
        }

        if settings.isAlertEnabled(kind), limit.percent >= threshold, !defaults.bool(forKey: firedKey) {
            defaults.set(true, forKey: firedKey)
            var body = detail ?? ""
            if let remaining = Format.countdown(to: limit.resetsAt) {
                let resets = L.t("si azzera tra \(remaining)", "resets in \(remaining)")
                body = body.isEmpty ? resets.prefix(1).uppercased() + resets.dropFirst() : body + " · " + resets
            }
            deliverOnce(title, body, kind)
        }

        if settings.isAlertEnabled(.limitReached), limit.percent >= 100, !defaults.bool(forKey: reachedKey) {
            defaults.set(true, forKey: reachedKey)
            var body = L.t("Limite esaurito", "Limit exhausted")
            if let remaining = Format.countdown(to: limit.resetsAt) {
                body += L.t(" · si azzera tra \(remaining)", " · resets in \(remaining)")
            }
            deliverOnce("\(limit.label): 100%", body, .limitReached)
        }
    }

    private func checkReset(_ session: UsageLimit) {
        guard session.resetsAt != nil else { return }
        // Stessa tolleranza: senza, ogni oscillazione del timestamp sarebbe
        // sembrata l'apertura di una nuova sessione.
        let changed = windowChanged(key: "alert.sessionReset.window", resetsAt: session.resetsAt)
        guard changed, settings.isAlertEnabled(.sessionReset) else { return }
        deliver(
            L.t("Sessione azzerata", "Session reset"),
            L.t("Cinque ore di quota di nuovo disponibili", "Five hours of quota available again"),
            AlertKind.sessionReset.rawValue
        )
    }

    // MARK: - Stato dei server

    func evaluate(status: ServerStatus) {
        defer { lastStatusIndicator = status.indicator }
        guard settings.isAlertEnabled(.serverStatus) else { return }
        // Il primo controllo dopo l'avvio non è un cambiamento.
        guard let previous = lastStatusIndicator, previous != status.indicator else { return }

        deliver(
            status.isHealthy
                ? L.t("Server Claude di nuovo operativi", "Claude servers back to normal")
                : L.t("Problemi ai server Claude", "Claude server trouble"),
            status.detail,
            AlertKind.serverStatus.rawValue
        )
    }

    // MARK: - Errori prolungati

    func evaluate(error: UsageError?) {
        guard settings.isAlertEnabled(.fetchFailure) else {
            failingSince = nil
            return
        }
        guard error != nil else {
            failingSince = nil
            defaults.set(false, forKey: "alert.fetchFailure.fired")
            return
        }

        let since = failingSince ?? Date()
        failingSince = since
        // Un errore isolato non merita una notifica: solo se dura.
        guard Date().timeIntervalSince(since) > 15 * 60,
              !defaults.bool(forKey: "alert.fetchFailure.fired") else { return }

        defaults.set(true, forKey: "alert.fetchFailure.fired")
        deliver(
            L.t("MenuClaude non riesce ad aggiornarsi", "MenuClaude cannot update"),
            error?.message ?? "",
            AlertKind.fetchFailure.rawValue
        )
    }
}
