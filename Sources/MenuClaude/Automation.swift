import Foundation

/// Le vie d'accesso da fuori: `menuclaude://…` per i Comandi rapidi e
/// `--json` per gli script.
///
/// Serve soprattutto a una cosa che l'app non può fare da sé: creare un vero
/// timer nell'app Orologio. Orologio non ha dizionario AppleScript e il suo
/// schema `clock-timer:` non accetta una durata, quindi MenuClaude si limita a
/// dire quanti minuti mancano; a farne un timer è un Comando rapido.
enum Automation {
    enum Command: String {
        case open
        case refresh
        case renew
        case analytics
        case settings
        case alarm
    }

    static func command(from url: URL) -> Command? {
        guard url.scheme == "menuclaude" else { return nil }
        // Sia `menuclaude://refresh` sia `menuclaude:refresh` devono funzionare:
        // chi scrive un Comando rapido a mano sbaglia quasi sempre gli slash.
        let name = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Command(rawValue: name.lowercased())
    }

    /// Stampa lo stato corrente in JSON ed esce. I minuti al reset sono un
    /// numero già pronto: è il valore che un Comando rapido passa al timer.
    static func printJSON() -> Never {
        guard case .ok(let credentials) = CredentialsStore.load(force: true) else {
            emit(["error": "credentials_unavailable"])
        }

        let client = UsageClient()
        var outcome: Result<UsageSnapshot, UsageError>?
        client.fetch(force: true) { outcome = $0 }

        // `fetch` risponde sulla coda principale: aspettarla con un semaforo la
        // bloccherebbe e la risposta non arriverebbe mai. Si fa girare il
        // run loop finché il risultato non c'è.
        let deadline = Date().addingTimeInterval(30)
        while outcome == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        switch outcome {
        case .success(let snapshot):
            var object: [String: Any] = [
                "plan": credentials.subscriptionType as Any,
                "fetched_at": stamp(Date()),
            ]
            if let session = snapshot.session {
                object["session_percent"] = round(session.percent)
                object["session_resets_at"] = session.resetsAt.map(stamp) as Any
                object["session_resets_in_minutes"] = minutes(until: session.resetsAt) as Any
            }
            if let weekly = snapshot.weekly {
                object["weekly_percent"] = round(weekly.percent)
                object["weekly_resets_at"] = weekly.resetsAt.map(stamp) as Any
                object["weekly_resets_in_minutes"] = minutes(until: weekly.resetsAt) as Any
            }
            if let extra = snapshot.extra {
                object["extra_percent"] = round(extra.percent)
            }
            emit(object)
        case .failure(let error):
            emit(["error": error.code])
        case nil:
            emit(["error": "timeout"])
        }
    }

    private static func minutes(until date: Date?) -> Int? {
        guard let date = date else { return nil }
        return max(0, Int(date.timeIntervalSinceNow / 60))
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func emit(_ object: [String: Any]) -> Never {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(object["error"] == nil ? 0 : 1)
    }
}
