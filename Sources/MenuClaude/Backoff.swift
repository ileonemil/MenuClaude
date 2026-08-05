import Foundation

/// Attesa crescente dopo un rifiuto del server: 2, 4, 8, 16 minuti… fino a
/// mezz'ora. Insistere durante un 429 non fa che tenere aperta la finestra del
/// blocco, quindi ogni rifiuto raddoppia l'attesa e un successo azzera tutto.
struct Backoff {
    /// Prima attesa, e passo del raddoppio.
    static let base: TimeInterval = 120
    /// Tetto alla *nostra* stima. Non si applica a quanto chiede il server.
    static let maximum: TimeInterval = 1800
    /// Tetto di sicurezza a un `Retry-After` assurdo.
    static let serverMaximum: TimeInterval = 7200

    private(set) var failures = 0
    private(set) var retryAt = Date.distantPast

    func isWaiting(now: Date = Date()) -> Bool { now < retryAt }

    /// - Parameters:
    ///   - suggested: l'header `Retry-After`. Quando il server dice un tempo
    ///     preciso lo si rispetta per intero: troncarlo significa ripresentarsi
    ///     in anticipo e prendere un altro rifiuto.
    ///   - escalate: falso per i tentativi chiesti dall'utente, che non devono
    ///     far salire il contatore — altrimenti chi preme "Aggiorna" perché vede
    ///     un errore si allunga l'attesa da solo.
    @discardableResult
    mutating func record(
        suggested: TimeInterval?,
        escalate: Bool = true,
        now: Date = Date()
    ) -> TimeInterval {
        if escalate { failures += 1 }

        let ourGuess = min(Backoff.base * pow(2, Double(max(failures, 1) - 1)), Backoff.maximum)
        let serverAsk = suggested.map { min(max($0, 0), Backoff.serverMaximum) } ?? 0
        let delay = max(ourGuess, serverAsk)

        // Un tentativo manuale non deve mai accorciare un'attesa già in corso.
        let candidate = now.addingTimeInterval(delay)
        retryAt = max(retryAt, candidate)
        return retryAt.timeIntervalSince(now)
    }

    mutating func reset() {
        failures = 0
        retryAt = .distantPast
    }

    /// L'attesa sopravvive alla chiusura dell'app: riaprirla durante un blocco
    /// non deve valere come "riprova subito".
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(retryAt.timeIntervalSince1970, forKey: "backoff.retryAt")
        defaults.set(failures, forKey: "backoff.failures")
    }

    static func restored(from defaults: UserDefaults = .standard) -> Backoff {
        var backoff = Backoff()
        let stamp = defaults.double(forKey: "backoff.retryAt")
        guard stamp > 0 else { return backoff }
        let saved = Date(timeIntervalSince1970: stamp)
        // Se l'attesa è già passata, ripartiamo puliti.
        guard saved > Date() else { return backoff }
        backoff.retryAt = saved
        backoff.failures = defaults.integer(forKey: "backoff.failures")
        return backoff
    }
}
