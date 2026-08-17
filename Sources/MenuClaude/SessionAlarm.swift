import Foundation
import UserNotifications

/// Una sveglia per il momento in cui la sessione si azzera.
///
/// Non è un timer dell'app Orologio: Clock non è pilotabile dall'esterno —
/// non ha dizionario AppleScript e il suo schema `clock-timer:` apre la scheda
/// Timer senza accettare una durata. È invece una notifica programmata da
/// MenuClaude per quell'istante preciso, che il sistema consegna anche se l'app
/// nel frattempo è stata chiusa e anche se il Mac ha dormito.
enum SessionAlarm {
    static let identifier = "sessionResetAlarm"

    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Programma la sveglia. `completion` riceve l'istante in cui suonerà, o
    /// `nil` se non è stato possibile.
    static func schedule(at date: Date, completion: @escaping (Date?) -> Void) {
        guard let center = center else {
            completion(nil)
            return
        }
        let seconds = date.timeIntervalSinceNow
        guard seconds > 1 else {
            completion(nil)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = L.t("Sessione azzerata", "Session reset")
        content.body = L.t("Le cinque ore sono passate: la quota è di nuovo piena.",
                           "The five hours are up: your quota is full again.")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        )
        // Lo stesso identificatore sostituisce una sveglia già programmata,
        // così non se ne accumulano due per la stessa sessione.
        center.add(request) { error in
            DispatchQueue.main.async { completion(error == nil ? date : nil) }
        }
    }

    static func cancel() {
        center?.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// L'istante in cui suonerà, se è armata.
    static func pending(completion: @escaping (Date?) -> Void) {
        guard let center = center else {
            completion(nil)
            return
        }
        center.getPendingNotificationRequests { requests in
            let fireDate = requests
                .first { $0.identifier == identifier }
                .flatMap { $0.trigger as? UNTimeIntervalNotificationTrigger }
                .flatMap { $0.nextTriggerDate() }
            DispatchQueue.main.async { completion(fireDate) }
        }
    }
}
