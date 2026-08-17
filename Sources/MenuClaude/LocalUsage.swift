import Foundation

/// Quanto è costato un insieme di messaggi, e in che token.
struct UsageTotals {
    var messages = 0
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    /// Valore a listino API dei token, in dollari. Zero per i modelli di cui
    /// non conosciamo il prezzo — che restano contati nei token.
    var cost = 0.0

    var totalTokens: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        UsageTotals(
            messages: a.messages + b.messages,
            input: a.input + b.input,
            output: a.output + b.output,
            cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
            cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
            cacheRead: a.cacheRead + b.cacheRead,
            cost: a.cost + b.cost
        )
    }
}

struct LocalUsageReport {
    var byModel: [String: UsageTotals] = [:]
    /// Chiave `yyyy-MM-dd`.
    var byDay: [String: UsageTotals] = [:]
    var byProject: [String: UsageTotals] = [:]
    var total = UsageTotals()
    /// Modelli visti nei log ma assenti dal listino: i loro token sono contati,
    /// il loro costo no.
    var unpricedModels: Set<String> = []
    var firstDay: String?
    var lastDay: String?
    var scannedAt = Date()

    var isEmpty: Bool { total.messages == 0 }

    func days(last count: Int, endingAt end: Date = Date()) -> [(day: String, totals: UsageTotals)] {
        let formatter = LocalUsageIndex.dayFormatter
        return (0..<count).reversed().map { offset in
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: end) ?? end
            let key = formatter.string(from: date)
            return (key, byDay[key] ?? UsageTotals())
        }
    }
}

/// Legge i log di Claude Code (`~/.claude/projects/**/*.jsonl`) e ne ricava
/// token, costi e attività per modello, giorno e progetto.
///
/// Due avvertenze che valgono per tutto ciò che ne esce:
/// coprono **solo Claude Code su questo Mac** — non claude.ai, non l'app
/// desktop, non un altro computer; e il costo è il valore a listino API dei
/// token, non quello che hai pagato.
///
/// La scansione è incrementale: di ogni file si ricorda quanti byte erano già
/// stati letti, e ai giri successivi si legge solo la coda. Rileggere tutto a
/// ogni apertura, con log che crescono di continuo, bloccherebbe l'interfaccia.
final class LocalUsageIndex {
    static let shared = LocalUsageIndex()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private let root: URL
    private let stateURL: URL
    private let queue = DispatchQueue(label: "menuclaude.localusage")

    private var offsets: [String: Int] = [:]
    private var report = LocalUsageReport()
    private var loaded = false

    init(root: URL? = nil, stateURL: URL? = nil) {
        self.root = root ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)

        if let stateURL = stateURL {
            self.stateURL = stateURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let folder = base.appendingPathComponent("MenuClaude", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.stateURL = folder.appendingPathComponent("local-usage.json")
        }
    }

    /// L'ultimo risultato noto, senza toccare il disco.
    var cached: LocalUsageReport {
        queue.sync {
            if !loaded { loadState() }
            return report
        }
    }

    /// Aggiorna leggendo solo ciò che è stato scritto dall'ultima volta.
    @discardableResult
    func refresh() -> LocalUsageReport {
        queue.sync {
            if !loaded { loadState() }
            let files = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
            for relative in files where relative.hasSuffix(".jsonl") {
                ingest(root.appendingPathComponent(relative))
            }
            report.scannedAt = Date()
            saveState()
            return report
        }
    }

    // MARK: - Lettura incrementale

    private func ingest(_ url: URL) {
        let key = url.path
        let previous = offsets[key] ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? FileManager.default.attributesOfItem(atPath: key)[.size] as? Int) ?? 0
        let start = size < previous ? 0 : previous  // file troncato o riscritto
        guard size > start else { return }

        try? handle.seek(toOffset: UInt64(start))
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // L'ultima riga può essere a metà scrittura: la si lascia al giro dopo.
        var consumed = data.count
        if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            consumed = lastNewline + 1
        } else {
            return
        }

        let usable = data.prefix(consumed)
        for line in usable.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            absorb(Data(line))
        }
        offsets[key] = start + consumed
    }

    private func absorb(_ line: Data) {
        guard
            let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let message = root["message"] as? [String: Any],
            let model = message["model"] as? String,
            let usage = message["usage"] as? [String: Any]
        else { return }
        // `<synthetic>` è il segnaposto che Claude Code usa per i messaggi che
        // non sono passati da un modello: non è un modello mancante dal listino.
        guard !model.hasPrefix("<") else { return }

        let creation = usage["cache_creation"] as? [String: Any]
        var totals = UsageTotals(
            messages: 1,
            input: int(usage["input_tokens"]),
            output: int(usage["output_tokens"]),
            cacheWrite5m: int(creation?["ephemeral_5m_input_tokens"]),
            cacheWrite1h: int(creation?["ephemeral_1h_input_tokens"]),
            cacheRead: int(usage["cache_read_input_tokens"])
        )
        // Se il dettaglio 5m/1h manca, il totale di scrittura finisce nel 5m.
        if totals.cacheWrite5m == 0, totals.cacheWrite1h == 0 {
            totals.cacheWrite5m = int(usage["cache_creation_input_tokens"])
        }

        if let price = Pricing.price(for: model) {
            let inputRate = price.inputPerMillion / 1_000_000
            totals.cost =
                Double(totals.input) * inputRate
                + Double(totals.output) * price.outputPerMillion / 1_000_000
                + Double(totals.cacheWrite5m) * inputRate * ModelPrice.cacheWrite5mMultiplier
                + Double(totals.cacheWrite1h) * inputRate * ModelPrice.cacheWrite1hMultiplier
                + Double(totals.cacheRead) * inputRate * ModelPrice.cacheReadMultiplier
        } else {
            report.unpricedModels.insert(model)
        }

        report.byModel[model] = (report.byModel[model] ?? UsageTotals()) + totals
        report.total = report.total + totals

        if let stamp = root["timestamp"] as? String, let date = ISO.date(from: stamp) {
            let day = LocalUsageIndex.dayFormatter.string(from: date)
            report.byDay[day] = (report.byDay[day] ?? UsageTotals()) + totals
            if report.firstDay == nil || day < report.firstDay! { report.firstDay = day }
            if report.lastDay == nil || day > report.lastDay! { report.lastDay = day }
        }

        if let cwd = root["cwd"] as? String {
            let project = URL(fileURLWithPath: cwd).lastPathComponent
            report.byProject[project] = (report.byProject[project] ?? UsageTotals()) + totals
        }
    }

    private func int(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return 0
    }

    // MARK: - Persistenza

    private func loadState() {
        loaded = true
        guard
            let data = try? Data(contentsOf: stateURL),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        offsets = (root["offsets"] as? [String: Int]) ?? [:]
        report.byModel = decodeBucket(root["byModel"])
        report.byDay = decodeBucket(root["byDay"])
        report.byProject = decodeBucket(root["byProject"])
        report.total = decodeTotals(root["total"]) ?? UsageTotals()
        report.unpricedModels = Set((root["unpriced"] as? [String]) ?? [])
        report.firstDay = root["firstDay"] as? String
        report.lastDay = root["lastDay"] as? String
    }

    private func saveState() {
        let object: [String: Any] = [
            "offsets": offsets,
            "byModel": encodeBucket(report.byModel),
            "byDay": encodeBucket(report.byDay),
            "byProject": encodeBucket(report.byProject),
            "total": encodeTotals(report.total),
            "unpriced": Array(report.unpricedModels),
            "firstDay": report.firstDay as Any,
            "lastDay": report.lastDay as Any,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func encodeTotals(_ t: UsageTotals) -> [String: Any] {
        ["m": t.messages, "i": t.input, "o": t.output,
         "w5": t.cacheWrite5m, "w1": t.cacheWrite1h, "r": t.cacheRead, "c": t.cost]
    }

    private func decodeTotals(_ any: Any?) -> UsageTotals? {
        guard let d = any as? [String: Any] else { return nil }
        return UsageTotals(
            messages: int(d["m"]), input: int(d["i"]), output: int(d["o"]),
            cacheWrite5m: int(d["w5"]), cacheWrite1h: int(d["w1"]),
            cacheRead: int(d["r"]), cost: (d["c"] as? Double) ?? 0
        )
    }

    private func encodeBucket(_ bucket: [String: UsageTotals]) -> [String: Any] {
        bucket.mapValues(encodeTotals)
    }

    private func decodeBucket(_ any: Any?) -> [String: UsageTotals] {
        guard let d = any as? [String: Any] else { return [:] }
        var out: [String: UsageTotals] = [:]
        for (key, value) in d {
            if let totals = decodeTotals(value) { out[key] = totals }
        }
        return out
    }
}

enum UsageFormat {
    /// "1,2 M", "834 k", "512"
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1f M", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0f k", Double(count) / 1_000) }
        return "\(count)"
    }

    static func dollars(_ amount: Double) -> String {
        if amount >= 100 { return String(format: "$%.0f", amount) }
        if amount >= 1 { return String(format: "$%.2f", amount) }
        return String(format: "$%.3f", amount)
    }
}
