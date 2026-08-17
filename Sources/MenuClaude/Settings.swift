import Foundation

enum DisplayMode: Int, CaseIterable {
    case sessionOnly = 0
    case sessionAndWeekly = 1
    case sessionAndTimer = 2
    case everything = 3
    case iconOnly = 4
    case rings = 5

    var label: String {
        switch self {
        case .sessionOnly:
            return L.t("Solo sessione — 23%", "Session only — 23%")
        case .sessionAndWeekly:
            return L.t("Sessione e settimana — 23% · 54%", "Session and week — 23% · 54%")
        case .sessionAndTimer:
            return L.t("Sessione e timer — 23% · 2h 41m", "Session and timer — 23% · 2h 41m")
        case .everything:
            return L.t("Tutto — 23% · 2h 41m · 54%", "Everything — 23% · 2h 41m · 54%")
        case .iconOnly:
            return L.t("Solo anello", "Ring only")
        case .rings:
            return L.t("Anelli concentrici — sessione, timer, settimana",
                       "Concentric rings — session, timer, week")
        }
    }

    /// Le modalità che disegnano l'icona da sé, ignorando le opzioni sull'anello.
    var usesOwnIcon: Bool { self == .rings }
}

final class Settings {
    static let shared = Settings()
    private let defaults: UserDefaults

    private enum Key {
        static let displayMode = "displayMode"
        static let refreshInterval = "refreshInterval"
        static let showRing = "showRing"
        static let colorInMenuBar = "colorInMenuBar"
        static let alertThreshold = "alertThreshold"
        static let language = "language"
        static let checkForUpdates = "checkForUpdates"
        static let autoRenewToken = "autoRenewToken"
        static func alert(_ kind: AlertKind) -> String { "alertEnabled.\(kind.rawValue)" }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var registered: [String: Any] = [
            Key.displayMode: DisplayMode.sessionAndWeekly.rawValue,
            Key.refreshInterval: 300.0,
            Key.showRing: true,
            Key.colorInMenuBar: true,
            Key.alertThreshold: 80.0,
            Key.language: Language.system.rawValue,
            Key.checkForUpdates: true,
            Key.autoRenewToken: true,
        ]
        for kind in AlertKind.allCases {
            registered[Key.alert(kind)] = kind.enabledByDefault
        }
        defaults.register(defaults: registered)
    }

    var displayMode: DisplayMode {
        get { DisplayMode(rawValue: defaults.integer(forKey: Key.displayMode)) ?? .sessionAndWeekly }
        set { defaults.set(newValue.rawValue, forKey: Key.displayMode) }
    }

    /// Secondi tra due chiamate all'API. L'endpoint ha un rate limit stretto,
    /// quindi sotto il minuto non si scende: le percentuali cambiano lentamente
    /// e il countdown al reset è calcolato in locale.
    var refreshInterval: TimeInterval {
        get { max(Settings.minimumInterval, defaults.double(forKey: Key.refreshInterval)) }
        set { defaults.set(max(Settings.minimumInterval, newValue), forKey: Key.refreshInterval) }
    }

    var showRing: Bool {
        get { defaults.bool(forKey: Key.showRing) }
        set { defaults.set(newValue, forKey: Key.showRing) }
    }

    /// Se falso, l'anello resta monocromatico (template) e si adatta alla barra.
    var colorInMenuBar: Bool {
        get { defaults.bool(forKey: Key.colorInMenuBar) }
        set { defaults.set(newValue, forKey: Key.colorInMenuBar) }
    }

    var language: Language {
        get { Language(rawValue: defaults.integer(forKey: Key.language)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.language) }
    }

    /// Rinnova da sé l'access token quando scade, senza aspettare il pulsante.
    var autoRenewToken: Bool {
        get { defaults.bool(forKey: Key.autoRenewToken) }
        set { defaults.set(newValue, forKey: Key.autoRenewToken) }
    }

    /// Controllo automatico delle nuove versioni su GitHub.
    var checkForUpdates: Bool {
        get { defaults.bool(forKey: Key.checkForUpdates) }
        set { defaults.set(newValue, forKey: Key.checkForUpdates) }
    }

    // MARK: - Avvisi

    var alertThreshold: Double {
        get { defaults.double(forKey: Key.alertThreshold) }
        set { defaults.set(newValue, forKey: Key.alertThreshold) }
    }

    func isAlertEnabled(_ kind: AlertKind) -> Bool {
        defaults.bool(forKey: Key.alert(kind))
    }

    func setAlert(_ kind: AlertKind, enabled: Bool) {
        defaults.set(enabled, forKey: Key.alert(kind))
    }

    var anyAlertEnabled: Bool {
        AlertKind.allCases.contains(where: isAlertEnabled)
    }

    static let thresholdChoices: [Double] = [50, 70, 80, 90]

    static let minimumInterval: TimeInterval = 60
    static let refreshChoices: [TimeInterval] = [60, 120, 300, 600, 1800]

    static func refreshLabel(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes == 1 { return L.t("minuto", "minute") }
        return L.t("\(minutes) minuti", "\(minutes) minutes")
    }
}
