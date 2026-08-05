import Foundation

/// Avvio automatico tramite LaunchAgent: funziona anche per un'app non
/// distribuita dall'App Store e non richiede un helper separato.
enum LaunchAtLogin {
    private static var label: String {
        Bundle.main.bundleIdentifier ?? "com.menuclaude.MenuClaude"
    }

    /// Identificatori usati da versioni precedenti: i loro LaunchAgent vanno
    /// rimossi, altrimenti resterebbero ad avviare un binario fantasma.
    private static let legacyLabels: [String] = []

    private static var agentsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents")
    }

    private static var plistURL: URL {
        agentsDirectory.appendingPathComponent("\(label).plist")
    }

    static func removeLegacyAgents() {
        for legacy in legacyLabels where legacy != label {
            try? FileManager.default.removeItem(
                at: agentsDirectory.appendingPathComponent("\(legacy).plist")
            )
        }
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func set(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    private static func enable() {
        let executable = Bundle.main.executablePath ?? ""
        guard !executable.isEmpty else { return }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]

        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: plistURL, options: .atomic)
        } catch {
            NSLog("MenuClaude: impossibile scrivere il LaunchAgent — \(error)")
        }
    }

    private static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
