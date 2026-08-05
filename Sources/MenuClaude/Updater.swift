import Cocoa

struct AvailableUpdate {
    var version: String
    var notes: String
    var downloadURL: URL
    var size: Int
}

enum UpdateError: Error {
    case network(String)
    case malformed
    case noAsset
    case notWritable(String)
    case mountFailed
    case contentMismatch
    case copyFailed

    var message: String {
        switch self {
        case .network(let detail):
            return detail
        case .malformed:
            return L.t("Risposta di GitHub non riconosciuta", "Unrecognised response from GitHub")
        case .noAsset:
            return L.t("La release non contiene un DMG", "The release has no DMG attached")
        case .notWritable(let path):
            return L.t("Non ho i permessi per aggiornare \(path). Sposta MenuClaude in Applicazioni.",
                       "No permission to update \(path). Move MenuClaude to Applications.")
        case .mountFailed:
            return L.t("Non è stato possibile aprire il DMG scaricato",
                       "Could not open the downloaded DMG")
        case .contentMismatch:
            return L.t("Il contenuto scaricato non corrisponde alla versione attesa",
                       "The download does not match the expected version")
        case .copyFailed:
            return L.t("Copia della nuova versione non riuscita", "Copying the new version failed")
        }
    }
}

/// Aggiornamento in-app dalle release di GitHub.
///
/// Non serve un account sviluppatore Apple: quello serve a *firmare* l'app, non
/// a sostituirla. `/Applications` è scrivibile dagli utenti amministratori, e
/// un'app non può riscrivere sé stessa mentre è in esecuzione — quindi il
/// lavoro finale lo fa uno script che aspetta la chiusura, scambia il bundle e
/// riapre l'app.
final class Updater {
    static let repository = "ileonemil/MenuClaude"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
    }

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // MARK: - Controllo

    /// `nil` come risultato positivo significa "sei già aggiornato".
    func check(completion: @escaping (Result<AvailableUpdate?, UpdateError>) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MenuClaude", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            let outcome: Result<AvailableUpdate?, UpdateError>

            if let error = error {
                outcome = .failure(.network((error as NSError).localizedDescription))
            } else if let update = data.flatMap(self.parse) {
                outcome = .success(
                    Updater.isNewer(update.version, than: self.currentVersion) ? update : nil
                )
            } else {
                outcome = .failure(.malformed)
            }
            DispatchQueue.main.async { completion(outcome) }
        }.resume()
    }

    private func parse(_ data: Data) -> AvailableUpdate? {
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let tag = root["tag_name"] as? String,
            let assets = root["assets"] as? [[String: Any]]
        else { return nil }

        let dmg = assets.first {
            ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true
        }
        guard
            let asset = dmg,
            let urlString = asset["browser_download_url"] as? String,
            let url = URL(string: urlString)
        else { return nil }

        return AvailableUpdate(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            notes: (root["body"] as? String) ?? "",
            downloadURL: url,
            size: (asset["size"] as? Int) ?? 0
        )
    }

    /// Confronto numerico per componenti: "1.10" è più recente di "1.9".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let left = i < a.count ? a[i] : 0
            let right = i < b.count ? b[i] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - Installazione

    func install(_ update: AvailableUpdate, completion: @escaping (UpdateError?) -> Void) {
        let destination = Bundle.main.bundleURL
        // Meglio accorgersene adesso che dopo aver scaricato e smontato tutto.
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            completion(.notWritable(destination.deletingLastPathComponent().path))
            return
        }

        session.downloadTask(with: update.downloadURL) { [weak self] location, response, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { completion(.network((error as NSError).localizedDescription)) }
                return
            }
            guard
                let location = location,
                (response as? HTTPURLResponse)?.statusCode == 200
            else {
                DispatchQueue.main.async { completion(.malformed) }
                return
            }

            let result = self.unpackAndSwap(dmg: location, update: update, destination: destination)
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func unpackAndSwap(dmg: URL, update: AvailableUpdate, destination: URL) -> UpdateError? {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MenuClaudeUpdate-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)

        let image = work.appendingPathComponent("MenuClaude.dmg")
        try? fm.moveItem(at: dmg, to: image)

        let mount = work.appendingPathComponent("mnt")
        try? fm.createDirectory(at: mount, withIntermediateDirectories: true)

        guard run("/usr/bin/hdiutil",
                  ["attach", image.path, "-mountpoint", mount.path, "-nobrowse", "-readonly", "-quiet"]) else {
            return .mountFailed
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }

        let newApp = mount.appendingPathComponent("MenuClaude.app")
        guard fm.fileExists(atPath: newApp.path), version(of: newApp) == update.version else {
            return .contentMismatch
        }

        // Copiamo fuori dal DMG prima di smontarlo.
        let staged = work.appendingPathComponent("MenuClaude.app")
        guard run("/usr/bin/ditto", [newApp.path, staged.path]) else { return .copyFailed }

        // Senza questo macOS rifiuterebbe di aprire l'app appena scaricata,
        // come fa al primo avvio. Il file arriva via HTTPS dalla stessa release
        // da cui l'utente ha installato, ed è stato appena verificato.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        // Un'app non può sostituire sé stessa mentre gira: lo fa uno script che
        // aspetta la chiusura del processo, scambia il bundle e riapre.
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(destination.path)"
        /usr/bin/ditto "\(staged.path)" "\(destination.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(destination.path)" 2>/dev/null
        /usr/bin/open "\(destination.path)"
        sleep 3
        rm -rf "\(work.path)"
        """
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else {
            return .copyFailed
        }
        _ = run("/bin/chmod", ["+x", script.path])

        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = [script.path]
        do { try swap.run() } catch { return .copyFailed }

        // Lo script è avviato: da qui in poi chi ha chiesto l'aggiornamento
        // deve chiudere il processo, altrimenti lo scambio non parte mai.
        return nil
    }

    private func version(of bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
