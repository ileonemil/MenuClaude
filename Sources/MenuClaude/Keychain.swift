import Foundation
import Security

/// Le credenziali OAuth che Claude Code salva nel Keychain di login.
struct ClaudeCredentials {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var subscriptionType: String?
    var rateLimitTier: String?

    var isExpired: Bool { !isValid(margin: 0) }

    /// Consideriamo il token già scaduto poco prima della scadenza vera, così
    /// non spendiamo una chiamata (e un eventuale prompt) per un 401 annunciato.
    func isValid(margin: TimeInterval) -> Bool {
        guard let expiresAt = expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow > margin
    }
}

enum CredentialsResult {
    case ok(ClaudeCredentials)
    case missing
    case denied
}

/// Ogni lettura del Keychain può far comparire il pannello di autorizzazione di
/// macOS. Le credenziali restano quindi in memoria per tutta la loro validità e
/// il Keychain viene interrogato solo quando il token è scaduto o rifiutato:
/// nel caso normale una volta per avvio, non a ogni aggiornamento.
enum CredentialsStore {
    static let service = "Claude Code-credentials"

    private static let lock = NSLock()
    private static var cached: ClaudeCredentials?
    private static var backoffUntil = Date.distantPast

    /// Quante volte abbiamo davvero interrogato il portachiavi: è la misura di
    /// quanti pannelli di autorizzazione l'utente può vedersi comparire.
    private(set) static var keychainReads = 0

    /// Quanto aspettare prima di riproporre il prompt dopo un rifiuto.
    private static let denialBackoff: TimeInterval = 300

    /// - Parameter force: ignora la pausa dopo un rifiuto (aggiornamento manuale).
    static func load(force: Bool = false) -> CredentialsResult {
        lock.lock()
        defer { lock.unlock() }

        if !force, let credentials = cached, credentials.isValid(margin: 60) {
            return .ok(credentials)
        }
        if !force, Date() < backoffUntil {
            // L'utente ha appena rifiutato: meglio un dato stantio che insistere.
            if let credentials = cached { return .ok(credentials) }
            return .denied
        }

        switch readKeychain() {
        case .ok(let credentials):
            cached = credentials
            backoffUntil = .distantPast
            return .ok(credentials)

        case .denied:
            backoffUntil = Date().addingTimeInterval(denialBackoff)
            if let credentials = cached, credentials.isValid(margin: 0) { return .ok(credentials) }
            return .denied

        case .missing:
            break
        }

        // Alcune installazioni tengono le credenziali in chiaro nel file.
        if let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/.credentials.json"),
           let credentials = parse(data) {
            cached = credentials
            return .ok(credentials)
        }

        if let credentials = cached { return .ok(credentials) }
        return .missing
    }

    /// Da chiamare quando l'API risponde 401: il token in memoria non vale più.
    static func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    private static func readKeychain() -> CredentialsResult {
        keychainReads += 1
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let credentials = parse(data) else { return .missing }
            return .ok(credentials)
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .denied
        default:
            return .missing
        }
    }

    private static func parse(_ data: Data) -> ClaudeCredentials? {
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else { return nil }

        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double, ms > 0 {
            expires = Date(timeIntervalSince1970: ms / 1000.0)
        }
        return ClaudeCredentials(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expires,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }
}
