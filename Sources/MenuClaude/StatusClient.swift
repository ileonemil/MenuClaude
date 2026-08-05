import Foundation

/// Lo stato dei servizi Claude, dalla pagina Statuspage pubblica.
struct ServerStatus {
    var indicator: String        // none, minor, major, critical
    var description: String
    var affected: [String]       // componenti non operativi
    var incidents: [String]
    var checkedAt = Date()

    var isHealthy: Bool { indicator == "none" && affected.isEmpty }

    var severity: Severity {
        switch indicator {
        case "none": return .normal
        case "critical", "major": return .critical
        default: return affected.isEmpty ? .normal : .warning
        }
    }

    var detail: String {
        var parts: [String] = [description]
        if !affected.isEmpty { parts.append(affected.joined(separator: ", ")) }
        if let incident = incidents.first { parts.append(incident) }
        return parts.joined(separator: " · ")
    }

    /// Testo breve per il pannello.
    var summary: String {
        if isHealthy { return L.t("Server operativi", "Servers operational") }
        if !affected.isEmpty { return affected.joined(separator: ", ") }
        return description
    }
}

/// Nessun token, nessun dato personale: è la stessa pagina che chiunque può
/// aprire su status.claude.com.
final class StatusClient {
    private let endpoint = URL(string: "https://status.claude.com/api/v2/summary.json")!
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    func fetch(completion: @escaping (ServerStatus?) -> Void) {
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("MenuClaude/1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, _, _ in
            let status = data.flatMap(StatusClient.decode)
            DispatchQueue.main.async { completion(status) }
        }.resume()
    }

    static func decode(_ data: Data) -> ServerStatus? {
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let status = root["status"] as? [String: Any]
        else { return nil }

        let components = (root["components"] as? [[String: Any]]) ?? []
        let affected = components
            .filter { ($0["status"] as? String) != "operational" }
            .compactMap { $0["name"] as? String }

        let incidents = ((root["incidents"] as? [[String: Any]]) ?? [])
            .compactMap { $0["name"] as? String }

        return ServerStatus(
            indicator: (status["indicator"] as? String) ?? "unknown",
            description: (status["description"] as? String) ?? "",
            affected: affected,
            incidents: incidents
        )
    }
}
