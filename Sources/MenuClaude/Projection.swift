import Foundation

/// Dove si andrà a finire se si continua così.
struct Projection {
    /// Punti percentuali consumati all'ora, nella finestra corrente.
    var ratePerHour: Double
    /// Quando si arriverebbe al 100%, se ci si arriva prima del reset.
    var exhaustionAt: Date?
    /// Quanto si arriverebbe ad avere consumato al momento del reset.
    var percentAtReset: Double
    /// Su quanti campioni è basata: sotto una certa soglia non dice granché.
    var sampleCount: Int

    var isReliable: Bool { sampleCount >= 3 && ratePerHour > 0.01 }
}

enum Projections {
    /// Serve almeno mezz'ora di osservazioni: sotto, il rumore di un singolo
    /// scatto della percentuale produrrebbe stime assurde.
    static let minimumSpan: TimeInterval = 30 * 60

    /// Stima il ritmo di consumo dai campioni della finestra corrente.
    ///
    /// Si guarda solo dentro la finestra in corso: i campioni precedenti
    /// appartengono a una quota già azzerata e, mescolati, farebbero sembrare
    /// che il consumo sia sceso.
    static func project(
        samples: [UsageSample],
        resetsAt: Date?,
        windowLength: TimeInterval,
        value: (UsageSample) -> Double,
        now: Date = Date()
    ) -> Projection? {
        guard let resetsAt = resetsAt else { return nil }
        let windowStart = resetsAt.addingTimeInterval(-windowLength)
        let inWindow = samples.filter { $0.at >= windowStart && $0.at <= now }
        guard let first = inWindow.first, let last = inWindow.last else { return nil }

        let span = last.at.timeIntervalSince(first.at)
        guard span >= minimumSpan else { return nil }

        let consumed = value(last) - value(first)
        let ratePerHour = consumed / (span / 3600)
        let remaining = max(0, 100 - value(last))
        let hoursToReset = max(0, resetsAt.timeIntervalSince(now)) / 3600

        var exhaustionAt: Date?
        if ratePerHour > 0.01 {
            let hoursLeft = remaining / ratePerHour
            if hoursLeft <= hoursToReset {
                exhaustionAt = now.addingTimeInterval(hoursLeft * 3600)
            }
        }

        return Projection(
            ratePerHour: ratePerHour,
            exhaustionAt: exhaustionAt,
            percentAtReset: min(100, value(last) + ratePerHour * hoursToReset),
            sampleCount: inWindow.count
        )
    }

    /// La frase da mostrare sotto la quota. `nil` quando non c'è abbastanza
    /// materiale per dire qualcosa di sensato — meglio tacere che inventare.
    static func summary(for projection: Projection?, resetsAt: Date?, now: Date = Date()) -> String? {
        guard let projection = projection, projection.isReliable else { return nil }

        if let exhaustion = projection.exhaustionAt {
            let when = Format.countdown(to: exhaustion, now: now) ?? ""
            return L.t("a questo ritmo finisce fra \(when)", "at this rate it runs out in \(when)")
        }
        // Non si esaurisce prima del reset: interessa quanto ci si arriva vicino.
        let arrival = Int(projection.percentAtReset.rounded())
        if arrival >= 95 {
            return L.t("a questo ritmo arrivi al reset appena in tempo",
                       "at this rate you'll just make it to the reset")
        }
        return L.t("a questo ritmo arrivi al reset al \(arrival)%",
                   "at this rate you'll reach the reset at \(arrival)%")
    }
}
