import Foundation

enum Diagnostics {
    /// `--test-notification`: chiede il permesso, manda un avviso di prova e
    /// riferisce cosa ha risposto macOS.
    static func testNotification() -> Never {
        print(L.t("MenuClaude — prova notifiche\n", "MenuClaude — notification test\n"))
        var done = false
        var status: Int32 = 1

        Notifier.shared.requestAuthorization { granted in
            if granted {
                print(L.t("✓ Permesso concesso", "✓ Permission granted"))
                Notifier.shared.send(
                    title: L.t("MenuClaude funziona", "MenuClaude works"),
                    body: L.t("Gli avvisi arriveranno così.", "This is how alerts will look."),
                    identifier: "test"
                )
                print(L.t("→ Notifica inviata: dovrebbe comparire in alto a destra.",
                          "→ Notification sent: it should appear in the top right."))
                status = 0
            } else {
                print(L.t("✗ Permesso negato", "✗ Permission denied"))
                print("  System Settings › Notifications › MenuClaude")
                if let detail = Notifier.shared.lastError { print(L.t("  Dettaglio: \(detail)", "  Detail: \(detail)")) }
            }
            done = true
        }

        let deadline = Date().addingTimeInterval(10)
        while !done, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if !done { print(L.t("✗ Nessuna risposta da macOS entro 10 secondi", "✗ No response from macOS within 10 seconds")) }
        // Diamo tempo alla notifica di essere consegnata prima di uscire.
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        exit(status)
    }

    static func run() -> Never {
        print(L.t("MenuClaude — diagnostica\n", "MenuClaude — diagnostics\n"))

        let creds: ClaudeCredentials
        switch CredentialsStore.load(force: true) {
        case .ok(let loaded):
            creds = loaded
        case .denied:
            print(L.t("✗ Accesso al portachiavi negato.", "✗ Keychain access denied."))
            print(L.t("  Riprova e scegli “Sempre” nel pannello di macOS.",
                      "  Try again and choose “Always Allow” in the macOS panel."))
            exit(1)
        case .missing:
            print(L.t("✗ Credenziali: non trovate.", "✗ Credentials: not found."))
            print(L.t("  Cercate nel Keychain (voce “\(CredentialsStore.service)”)",
                      "  Looked in the Keychain (item “\(CredentialsStore.service)”)"))
            print(L.t("  e in ~/.claude/.credentials.json.", "  and in ~/.claude/.credentials.json."))
            print(L.t("  Fai login con `claude` almeno una volta, poi riprova.",
                      "  Sign in with `claude` at least once, then try again."))
            exit(1)
        }

        print(L.t("✓ Credenziali trovate", "✓ Credentials found"))
        print(L.t("  piano: ", "  plan: ") + (creds.subscriptionType ?? L.t("sconosciuto", "unknown")))
        if let expires = creds.expiresAt {
            let state = creds.isExpired ? L.t("SCADUTO", "EXPIRED") : L.t("valido", "valid")
            print(L.t("  token: \(state) (scadenza \(Format.resetStamp(expires) ?? "?"))",
                      "  token: \(state) (expires \(Format.resetStamp(expires) ?? "?"))"))
        }

        print(L.t("\n… chiamata a api.anthropic.com/api/oauth/usage",
                  "\n… calling api.anthropic.com/api/oauth/usage"))
        let semaphore = DispatchSemaphore(value: 0)
        var status = 1

        UsageClient().fetch { result in
            switch result {
            case .failure(let error):
                print("✗ \(error.message)")
            case .success(let snapshot):
                print(L.t("✓ Risposta ricevuta\n", "✓ Response received\n"))
                for limit in snapshot.limits {
                    let countdown = Format.countdown(to: limit.resetsAt) ?? "—"
                    let stamp = Format.resetStamp(limit.resetsAt) ?? "—"
                    print("  \(limit.label.padding(toLength: 24, withPad: " ", startingAt: 0))"
                        + "\(Format.percent(limit.percent).padding(toLength: 6, withPad: " ", startingAt: 0))"
                        + L.t("reset tra \(countdown) (\(stamp))", "resets in \(countdown) (\(stamp))"))
                }
                if let extra = snapshot.extra {
                    print("  \(L.t("Crediti extra", "Extra credits").padding(toLength: 24, withPad: " ", startingAt: 0))"
                        + "\(Format.percent(extra.percent).padding(toLength: 6, withPad: " ", startingAt: 0))"
                        + L.t("\(extra.usedText) di \(extra.limitText)", "\(extra.usedText) of \(extra.limitText)"))
                }
                status = 0
            }
            print(L.t("\nPortachiavi letto \(CredentialsStore.keychainReads) volta/e.",
                      "\nKeychain read \(CredentialsStore.keychainReads) time(s)."))
            print(L.t(
                "Il token resta in memoria finché è valido, quindi il pannello di\nautorizzazione può comparire una volta per avvio, non a ogni\naggiornamento. Scegliendo “Sempre” non compare più.",
                "The token stays in memory while it is valid, so the authorisation\npanel may appear once per launch, not on every update. Choosing\n“Always Allow” makes it stop appearing."
            ))
            semaphore.signal()
        }

        // fetch() consegna il risultato sulla coda main, che qui non gira da sola.
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(Int32(status))
    }
}
