import Foundation

/// Interroga l'endpoint OAuth di usage usando il token di Claude Code.
/// Le credenziali vengono rilette a ogni fetch: quando Claude Code rinnova il
/// token, l'app lo prende al giro successivo senza bisogno di riavviarsi.
final class UsageClient {
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// - Parameter force: aggiornamento richiesto dall'utente. Riprova subito
    ///   anche se il portachiavi era stato rifiutato poco prima.
    func fetch(force: Bool = false, completion: @escaping (Result<UsageSnapshot, UsageError>) -> Void) {
        let creds: ClaudeCredentials
        switch CredentialsStore.load(force: force) {
        case .ok(let loaded):
            creds = loaded
        case .denied:
            DispatchQueue.main.async { completion(.failure(.keychainDenied)) }
            return
        case .missing:
            DispatchQueue.main.async { completion(.failure(.noCredentials)) }
            return
        }

        send(using: creds, allowRetry: true, completion: completion)
    }

    private func send(
        using creds: ClaudeCredentials,
        allowRetry: Bool,
        completion: @escaping (Result<UsageSnapshot, UsageError>) -> Void
    ) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MenuClaude/1.0", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let outcome: Result<UsageSnapshot, UsageError>

            if let error = error {
                outcome = .failure(.network((error as NSError).localizedDescription))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if http.statusCode == 401 || http.statusCode == 403 {
                    // Il token in memoria non vale più: una sola rilettura del
                    // Keychain (Claude Code potrebbe averlo già rinnovato).
                    CredentialsStore.invalidate()
                    if allowRetry, case .ok(let fresh) = CredentialsStore.load(force: true),
                       fresh.accessToken != creds.accessToken {
                        self?.send(using: fresh, allowRetry: false, completion: completion)
                        return
                    }
                    outcome = .failure(creds.isExpired ? .tokenExpired : .unauthorized)
                } else if http.statusCode == 429 {
                    // `retry-after: 0` capita spesso e non vuol dire "riprova
                    // subito": in quel caso decide il backoff del chiamante.
                    let header = http.allHeaderFields["Retry-After"] as? String
                    let seconds = header.flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil }
                    outcome = .failure(.rateLimited(retryAfter: seconds))
                } else {
                    outcome = .failure(.http(http.statusCode))
                }
            } else if let data = data, var snapshot = UsageClient.decode(data) {
                snapshot.plan = creds.subscriptionType
                outcome = .success(snapshot)
            } else {
                outcome = .failure(.malformed)
            }

            DispatchQueue.main.async { completion(outcome) }
        }
        task.resume()
    }

    // MARK: - Parsing

    /// Il payload cambia nel tempo (nuove quote appaiono e spariscono), quindi
    /// leggiamo l'array `limits` in modo generico e teniamo i campi storici
    /// `five_hour` / `seven_day` come rete di sicurezza.
    static func decode(_ data: Data) -> UsageSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        var snapshot = UsageSnapshot()

        if let raw = root["limits"] as? [[String: Any]] {
            for entry in raw {
                guard let kind = entry["kind"] as? String else { continue }
                guard let percent = numeric(entry["percent"]) else { continue }
                let group = (entry["group"] as? String) ?? kind
                snapshot.limits.append(
                    UsageLimit(
                        kind: kind,
                        group: group,
                        percent: percent,
                        resetsAt: ISO.date(from: entry["resets_at"] as? String),
                        severity: Severity.from(percent: percent, declared: entry["severity"] as? String),
                        isActive: (entry["is_active"] as? Bool) ?? false
                    )
                )
            }
        }

        if snapshot.limits.isEmpty {
            let legacy: [(String, String, String)] = [
                ("five_hour", "session", "session"),
                ("seven_day", "weekly_all", "weekly"),
                ("seven_day_opus", "weekly_opus", "weekly"),
                ("seven_day_sonnet", "weekly_sonnet", "weekly"),
            ]
            for (key, kind, group) in legacy {
                guard
                    let block = root[key] as? [String: Any],
                    let percent = numeric(block["utilization"])
                else { continue }
                snapshot.limits.append(
                    UsageLimit(
                        kind: kind,
                        group: group,
                        percent: percent,
                        resetsAt: ISO.date(from: block["resets_at"] as? String),
                        severity: Severity.from(percent: percent, declared: nil),
                        isActive: false
                    )
                )
            }
        }

        snapshot.extra = decodeExtra(root)
        return snapshot.limits.isEmpty && snapshot.extra == nil ? nil : snapshot
    }

    private static func decodeExtra(_ root: [String: Any]) -> ExtraUsage? {
        guard
            let spend = root["spend"] as? [String: Any],
            (spend["enabled"] as? Bool) == true,
            let used = spend["used"] as? [String: Any],
            let limit = spend["limit"] as? [String: Any],
            let usedMinor = numeric(used["amount_minor"]),
            let limitMinor = numeric(limit["amount_minor"]), limitMinor > 0
        else { return nil }

        let percent = numeric(spend["percent"]) ?? (usedMinor / limitMinor * 100)
        return ExtraUsage(
            percent: percent,
            usedMinor: Int(usedMinor),
            limitMinor: Int(limitMinor),
            currency: (used["currency"] as? String) ?? "USD",
            exponent: Int(numeric(used["exponent"]) ?? 2),
            severity: Severity.from(percent: percent, declared: spend["severity"] as? String)
        )
    }

    private static func numeric(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
