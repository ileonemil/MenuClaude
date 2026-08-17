import Foundation

/// Listino pubblico dell'API, in dollari per milione di token.
///
/// Serve a stimare quanto varrebbero, pagati a consumo, i token passati da
/// Claude Code. Non è quello che paghi: con un abbonamento paghi la quota, non
/// i token. È un'unità di misura del lavoro svolto, non una fattura.
///
/// Va aggiornato a mano quando Anthropic cambia i listini o esce un modello
/// nuovo: un modello sconosciuto viene contato nei token ma non nel costo,
/// e il pannello lo segnala invece di inventare una cifra.
struct ModelPrice {
    var inputPerMillion: Double
    var outputPerMillion: Double

    /// Scrivere in cache costa più dell'input normale, rileggerla molto meno.
    static let cacheWrite5mMultiplier = 1.25
    static let cacheWrite1hMultiplier = 2.0
    static let cacheReadMultiplier = 0.1
}

enum Pricing {
    /// Aggiornato al 24/06/2026.
    private static let table: [String: ModelPrice] = [
        "claude-fable-5": ModelPrice(inputPerMillion: 10, outputPerMillion: 50),
        "claude-mythos-5": ModelPrice(inputPerMillion: 10, outputPerMillion: 50),
        "claude-opus-5": ModelPrice(inputPerMillion: 5, outputPerMillion: 25),
        "claude-opus-4-8": ModelPrice(inputPerMillion: 5, outputPerMillion: 25),
        "claude-opus-4-7": ModelPrice(inputPerMillion: 5, outputPerMillion: 25),
        "claude-opus-4-6": ModelPrice(inputPerMillion: 5, outputPerMillion: 25),
        "claude-sonnet-5": ModelPrice(inputPerMillion: 3, outputPerMillion: 15),
        "claude-sonnet-4-6": ModelPrice(inputPerMillion: 3, outputPerMillion: 15),
        "claude-haiku-4-5": ModelPrice(inputPerMillion: 1, outputPerMillion: 5),
    ]

    static func price(for model: String) -> ModelPrice? {
        if let exact = table[model] { return exact }
        // I log possono portare suffissi di data: proviamo il prefisso più lungo.
        let match = table.keys
            .filter { model.hasPrefix($0) }
            .max(by: { $0.count < $1.count })
        return match.flatMap { table[$0] }
    }

    static func isKnown(_ model: String) -> Bool { price(for: model) != nil }

    /// Nome leggibile: `claude-opus-5` → `Opus 5`.
    static func shortName(_ model: String) -> String {
        var name = model
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        let parts = name.split(separator: "-")
        guard let family = parts.first else { return model }
        let version = parts.dropFirst()
            .prefix(while: { $0.allSatisfy { $0.isNumber } })
            .joined(separator: ".")
        let capitalized = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? capitalized : "\(capitalized) \(version)"
    }
}
