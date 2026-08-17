import Foundation

enum RefreshError: Error {
    case noCredentials
    case noRefreshToken
    case network(String)
    case http(Int)
    case malformed
    /// Il token nuovo c'è ed è valido, ma non è stato possibile riscriverlo nel
    /// portachiavi. È il caso peggiore e va detto chiaramente: se il server ha
    /// ruotato il refresh token, quello che Claude Code ha in memoria non vale
    /// più e servirà rifare il login.
    case tokenRenewedButNotSaved

    var message: String {
        switch self {
        case .noCredentials:
            return L.t("Credenziali non trovate nel portachiavi",
                       "Credentials not found in the Keychain")
        case .noRefreshToken:
            return L.t("Nessun refresh token salvato: serve `claude auth login`",
                       "No refresh token stored: run `claude auth login`")
        case .network(let detail):
            return detail
        case .http(let code):
            return L.t("Rinnovo rifiutato dal server (HTTP \(code))",
                       "Renewal refused by the server (HTTP \(code))")
        case .malformed:
            return L.t("Risposta di rinnovo non riconosciuta", "Unrecognised renewal response")
        case .tokenRenewedButNotSaved:
            return L.t("Token rinnovato ma non salvato nel portachiavi",
                       "Token renewed but not saved to the Keychain")
        }
    }
}

/// Quando ha senso rinnovare da soli, senza aspettare il pulsante.
enum AutoRenewPolicy {
    /// Dopo un tentativo si aspetta: se il rinnovo non risolve, riprovare a
    /// ogni giro trasformerebbe un problema in una raffica di richieste.
    static let cooldown: TimeInterval = 300

    static func shouldRenew(
        after error: UsageError,
        enabled: Bool,
        alreadyRenewing: Bool,
        lastAttempt: Date,
        now: Date = Date()
    ) -> Bool {
        switch error {
        case .tokenExpired, .unauthorized:
            break
        default:
            return false
        }
        guard enabled, !alreadyRenewing else { return false }
        return now.timeIntervalSince(lastAttempt) > cooldown
    }
}

/// Rinnova l'access token usando il refresh token che Claude Code tiene nel
/// portachiavi, con lo stesso endpoint e lo stesso client id della CLI.
///
/// Serve perché **solo la CLI `claude` rinnova quella voce**: chi lavora
/// nell'app desktop o dal web se la vedrebbe scadere ogni poche ore senza che
/// nessuno la aggiorni.
///
/// Il server *ruota* il refresh token, cioè ne restituisce uno nuovo e invalida
/// il vecchio: se succede e non riusciamo a riscriverlo, il login di Claude Code
/// si rompe. Perciò la riscrittura viene ritentata e, se fallisce comunque,
/// l'errore è esplicito invece che silenzioso — anche quando il rinnovo è
/// partito da solo.
final class TokenRefresher {
    private let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    func refresh(completion: @escaping (Result<ClaudeCredentials, RefreshError>) -> Void) {
        guard
            let document = CredentialsStore.rawDocument(),
            let credentials = CredentialsStore.parseDocument(document)
        else {
            DispatchQueue.main.async { completion(.failure(.noCredentials)) }
            return
        }
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.noRefreshToken)) }
            return
        }

        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        // Chiediamo esattamente gli ambiti che il token aveva: allargarli
        // sarebbe scorretto, restringerli romperebbe Claude Code.
        if !credentials.scopes.isEmpty {
            body["scope"] = credentials.scopes.joined(separator: " ")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MenuClaude/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { data, response, error in
            let outcome = self.handle(
                data: data, response: response, error: error,
                document: document, previousRefreshToken: refreshToken
            )
            DispatchQueue.main.async { completion(outcome) }
        }.resume()
    }

    private func handle(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        document: Data,
        previousRefreshToken: String
    ) -> Result<ClaudeCredentials, RefreshError> {
        if let error = error {
            return .failure(.network((error as NSError).localizedDescription))
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            return .failure(.http(http.statusCode))
        }
        guard
            let data = data,
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let accessToken = payload["access_token"] as? String, !accessToken.isEmpty
        else {
            return .failure(.malformed)
        }

        // Se il server non manda un refresh token nuovo, il vecchio resta valido.
        let newRefreshToken = (payload["refresh_token"] as? String) ?? previousRefreshToken
        let expiresIn = (payload["expires_in"] as? Double) ?? 8 * 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)

        guard let merged = merge(
            into: document,
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresAt: expiresAt,
            scope: payload["scope"] as? String
        ) else {
            return .failure(.malformed)
        }

        guard let credentials = CredentialsStore.parseDocument(merged) else {
            return .failure(.malformed)
        }
        // In memoria il token nuovo vale comunque: se il salvataggio fallisce,
        // almeno MenuClaude continua a funzionare in questa sessione.
        CredentialsStore.adoptInMemory(credentials)

        var saved = CredentialsStore.writeDocument(merged)
        if !saved {
            // Un secondo tentativo dopo una pausa: qui in gioco c'è il login
            // di Claude Code, non vale la pena arrendersi al primo rifiuto.
            Thread.sleep(forTimeInterval: 0.5)
            saved = CredentialsStore.writeDocument(merged)
        }
        return saved ? .success(credentials) : .failure(.tokenRenewedButNotSaved)
    }

    /// Sostituisce solo i campi del token dentro `claudeAiOauth`, lasciando
    /// intatto tutto il resto del documento.
    private func merge(
        into document: Data,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        scope: String?
    ) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: document)) as? [String: Any] else {
            return nil
        }
        var oauth = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000
        if let scope = scope, !scope.isEmpty {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root)
    }
}
