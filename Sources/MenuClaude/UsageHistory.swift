import Foundation

/// Una fotografia dell'utilizzo, salvata su disco.
struct UsageSample {
    var at: Date
    var session: Double
    var weekly: Double
    var extra: Double?
    var sessionResetsAt: Date?
    var weeklyResetsAt: Date?
}

/// Registra le letture dell'API su file, perché l'API non ha memoria: espone
/// solo l'istante presente. Senza questo archivio nessuna domanda che riguardi
/// il tempo — quanto sto consumando, quando finirò, com'era la settimana
/// scorsa — sarebbe rispondibile, e ogni ora non registrata è persa per sempre.
///
/// Formato: una riga JSON per campione. Compatto, leggibile a occhio, e si
/// aggiunge in coda senza rileggere niente.
final class UsageHistory {
    static let shared = UsageHistory()

    /// Un campione ogni tanto basta: le percentuali sono numeri interi e non
    /// cambiano più in fretta di così.
    private static let minimumGap: TimeInterval = 4 * 60
    /// Anche quando non cambia niente, un battito ogni tanto: serve a
    /// distinguere "fermo" da "app spenta" quando si guarda il grafico.
    private static let heartbeat: TimeInterval = 30 * 60
    /// Oltre un anno lo storico non serve, e il file non deve crescere all'infinito.
    private static let retention: TimeInterval = 400 * 86400

    private let queue = DispatchQueue(label: "menuclaude.history")
    private let url: URL
    private var cache: [UsageSample]?

    init(url: URL? = nil) {
        if let url = url {
            self.url = url
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let folder = base.appendingPathComponent("MenuClaude", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.url = folder.appendingPathComponent("usage-history.jsonl")
        }
    }

    var fileURL: URL { url }

    // MARK: - Scrittura

    func record(_ snapshot: UsageSnapshot, now: Date = Date()) {
        guard let session = snapshot.session, let weekly = snapshot.weekly else { return }
        let sample = UsageSample(
            at: now,
            session: session.percent,
            weekly: weekly.percent,
            extra: snapshot.extra?.percent,
            sessionResetsAt: session.resetsAt,
            weeklyResetsAt: weekly.resetsAt
        )

        queue.sync {
            let previous = loadLocked().last
            if let previous = previous {
                let gap = now.timeIntervalSince(previous.at)
                let unchanged = abs(previous.session - sample.session) < 0.01
                    && abs(previous.weekly - sample.weekly) < 0.01
                if gap < UsageHistory.minimumGap { return }
                if unchanged && gap < UsageHistory.heartbeat { return }
            }
            append(sample)
            cache?.append(sample)
        }
    }

    private func append(_ sample: UsageSample) {
        guard let line = encode(sample) else { return }
        let data = (line + "\n").data(using: .utf8)!
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Lettura

    func samples(since: Date? = nil) -> [UsageSample] {
        queue.sync {
            let all = loadLocked()
            guard let since = since else { return all }
            return all.filter { $0.at >= since }
        }
    }

    private func loadLocked() -> [UsageSample] {
        if let cache = cache { return cache }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            cache = []
            return []
        }
        var samples = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { decode(String($0)) }
        samples.sort { $0.at < $1.at }

        let cutoff = Date().addingTimeInterval(-UsageHistory.retention)
        if let first = samples.first, first.at < cutoff {
            samples = samples.filter { $0.at >= cutoff }
            rewrite(samples)
        }
        cache = samples
        return samples
    }

    private func rewrite(_ samples: [UsageSample]) {
        let text = samples.compactMap(encode).joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - Formato

    /// Chiavi corte: il file cresce di una riga ogni pochi minuti per anni.
    private func encode(_ sample: UsageSample) -> String? {
        var object: [String: Any] = [
            "t": Int(sample.at.timeIntervalSince1970),
            "s": sample.session,
            "w": sample.weekly,
        ]
        if let extra = sample.extra { object["e"] = extra }
        if let reset = sample.sessionResetsAt { object["sr"] = Int(reset.timeIntervalSince1970) }
        if let reset = sample.weeklyResetsAt { object["wr"] = Int(reset.timeIntervalSince1970) }
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else { return nil }
        return line
    }

    private func decode(_ line: String) -> UsageSample? {
        guard
            let data = line.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let t = object["t"] as? Double,
            let s = object["s"] as? Double,
            let w = object["w"] as? Double
        else { return nil }
        return UsageSample(
            at: Date(timeIntervalSince1970: t),
            session: s,
            weekly: w,
            extra: object["e"] as? Double,
            sessionResetsAt: (object["sr"] as? Double).map { Date(timeIntervalSince1970: $0) },
            weeklyResetsAt: (object["wr"] as? Double).map { Date(timeIntervalSince1970: $0) }
        )
    }
}
