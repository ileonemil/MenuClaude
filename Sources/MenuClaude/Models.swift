import Foundation

enum Severity: String {
    case normal
    case warning
    case critical

    static func from(percent: Double, declared: String?) -> Severity {
        if let declared = declared, let s = Severity(rawValue: declared), s != .normal { return s }
        if percent >= 90 { return .critical }
        if percent >= 70 { return .warning }
        return .normal
    }
}

/// Una singola quota restituita dall'endpoint (sessione 5h, settimana, Opus, …).
struct UsageLimit {
    var kind: String
    var group: String
    var percent: Double
    var resetsAt: Date?
    var severity: Severity
    var isActive: Bool

    /// La finestra di sessione dura cinque ore.
    static let sessionWindow: TimeInterval = 5 * 3600

    /// Quanto è avanzata la finestra corrente: 0 appena azzerata, 1 quando sta
    /// per azzerarsi. Serve all'anello del timer, che si riempie col passare
    /// del tempo come gli altri si riempiono col consumo.
    func windowProgress(length: TimeInterval = UsageLimit.sessionWindow, now: Date = Date()) -> Double {
        guard let resetsAt = resetsAt, length > 0 else { return 0 }
        let remaining = resetsAt.timeIntervalSince(now)
        return min(max(1 - remaining / length, 0), 1)
    }

    var label: String {
        switch kind {
        case "session": return L.t("Sessione (5h)", "Session (5h)")
        case "weekly_all": return L.t("Settimana", "Weekly")
        case "weekly_opus": return L.t("Settimana · Opus", "Weekly · Opus")
        case "weekly_sonnet": return L.t("Settimana · Sonnet", "Weekly · Sonnet")
        case "weekly_cowork": return L.t("Settimana · Cowork", "Weekly · Cowork")
        case "weekly_oauth_apps": return L.t("Settimana · app OAuth", "Weekly · OAuth apps")
        default:
            let pretty = kind.replacingOccurrences(of: "_", with: " ")
            return pretty.prefix(1).uppercased() + pretty.dropFirst()
        }
    }
}

/// Crediti extra a consumo (oltre il piano), se abilitati.
struct ExtraUsage {
    var percent: Double
    var usedMinor: Int
    var limitMinor: Int
    var currency: String
    var exponent: Int
    var severity: Severity

    private func format(_ minor: Int) -> String {
        let value = Double(minor) / pow(10.0, Double(exponent))
        let f = NumberFormatter()
        f.locale = L.locale
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = exponent
        f.minimumFractionDigits = exponent == 0 ? 0 : 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    var usedText: String { format(usedMinor) }
    var limitText: String { format(limitMinor) }
}

struct UsageSnapshot {
    var limits: [UsageLimit] = []
    var extra: ExtraUsage?
    var plan: String?
    var fetchedAt: Date = Date()

    var session: UsageLimit? {
        limits.first(where: { $0.kind == "session" }) ?? limits.first(where: { $0.group == "session" })
    }

    var weekly: UsageLimit? {
        limits.first(where: { $0.kind == "weekly_all" }) ?? limits.first(where: { $0.group == "weekly" })
    }

    /// Stesse percentuali e stesse finestre: la fotografia non è cambiata.
    /// Serve a capire quando conviene rallentare le interrogazioni.
    ///
    /// Gli istanti di reset vanno confrontati con tolleranza: il server li
    /// riporta con qualche decimo di secondo di scarto fra una risposta e
    /// l'altra, e preteso il confronto esatto nessuna risposta risultava mai
    /// uguale alla precedente — così il rallentamento non entrava mai in gioco.
    func isEquivalent(to other: UsageSnapshot) -> Bool {
        guard limits.count == other.limits.count else { return false }
        for (mine, theirs) in zip(limits, other.limits) {
            if mine.kind != theirs.kind { return false }
            if abs(mine.percent - theirs.percent) > 0.01 { return false }
            switch (mine.resetsAt, theirs.resetsAt) {
            case (nil, nil):
                break
            case let (a?, b?) where abs(a.timeIntervalSince(b)) <= 300:
                break
            default:
                return false
            }
        }
        return abs((extra?.percent ?? 0) - (other.extra?.percent ?? 0)) <= 0.01
    }

    /// Le quote settimanali secondarie (Opus, Sonnet, …), oltre a `weekly`.
    var secondaryWeekly: [UsageLimit] {
        guard let main = weekly else { return [] }
        return limits.filter { $0.group == "weekly" && $0.kind != main.kind }
    }
}

enum UsageError: Error {
    case noCredentials
    case keychainDenied
    case tokenExpired
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(String)
    case malformed

    var message: String {
        switch self {
        case .noCredentials:
            return L.t("Credenziali Claude non trovate nel Keychain",
                       "Claude credentials not found in the Keychain")
        case .keychainDenied:
            return L.t("Accesso al portachiavi negato — aggiorna e scegli «Sempre»",
                       "Keychain access denied — refresh and choose “Always Allow”")
        case .tokenExpired, .unauthorized:
            // Non serve dire come fare: accanto c'è il pulsante che lo fa.
            return L.t("Token scaduto", "Token expired")
        case .rateLimited:
            return L.t("Troppe richieste all'API", "Too many API requests")
        case .http(let code):
            return L.t("Errore dal server (HTTP \(code))", "Server error (HTTP \(code))")
        case .network(let detail):
            return detail
        case .malformed:
            return L.t("Risposta non riconosciuta", "Unrecognised response")
        }
    }
}

enum ISO {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Il server manda microsecondi (6 cifre): se i formatter standard falliscono,
    /// tagliamo la parte frazionaria e riproviamo.
    static func date(from string: String?) -> Date? {
        guard let string = string else { return nil }
        if let d = withFraction.date(from: string) { return d }
        if let d = plain.date(from: string) { return d }
        if let dot = string.firstIndex(of: ".") {
            var end = string.index(after: dot)
            while end < string.endIndex, string[end].isNumber { end = string.index(after: end) }
            var trimmed = string
            trimmed.removeSubrange(dot..<end)
            return plain.date(from: trimmed)
        }
        return nil
    }
}

enum Format {
    /// "2h 41m", "3g 6h", "48s" — compatto, per il countdown al reset.
    static func countdown(to date: Date?, now: Date = Date()) -> String? {
        guard let date = date else { return nil }
        let seconds = Int(date.timeIntervalSince(now).rounded())
        if seconds <= 0 { return L.t("ora", "now") }
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        let day = L.t("g", "d")
        if d > 0 { return h > 0 ? "\(d)\(day) \(h)h" : "\(d)\(day)" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// "oggi 15:20", "gio 22:00", "7 set 20:00"
    static func resetStamp(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let cal = Calendar.current
        let time = DateFormatter()
        time.locale = L.locale
        time.dateFormat = L.isEnglish ? "h:mm a" : "HH:mm"
        let clock = time.string(from: date)

        if cal.isDateInToday(date) { return L.t("oggi \(clock)", "today \(clock)") }
        if cal.isDateInTomorrow(date) { return L.t("domani \(clock)", "tomorrow \(clock)") }
        let days = cal.dateComponents([.day], from: Date(), to: date).day ?? 0
        let df = DateFormatter()
        df.locale = L.locale
        if days < 7 {
            df.dateFormat = L.isEnglish ? "EEE h:mm a" : "EEE HH:mm"
        } else {
            df.dateFormat = L.isEnglish ? "d MMM h:mm a" : "d MMM HH:mm"
        }
        return df.string(from: date)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value.rounded())
    }

    static func agoText(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 5 { return L.t("adesso", "just now") }
        if s < 60 { return L.t("\(s)s fa", "\(s)s ago") }
        if s < 3600 { return L.t("\(s / 60)m fa", "\(s / 60)m ago") }
        return L.t("\(s / 3600)h fa", "\(s / 3600)h ago")
    }
}
