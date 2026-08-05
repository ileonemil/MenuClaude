import Cocoa

// `MenuClaude --diagnose` stampa a terminale ciò che l'app vede (credenziali,
// risposta dell'API, quote lette) ed esce: utile quando la barra mostra "!".
if CommandLine.arguments.contains("--diagnose") {
    Diagnostics.run()
} else if CommandLine.arguments.contains("--test-notification") {
    Diagnostics.testNotification()
} else if let index = CommandLine.arguments.firstIndex(of: "--preview"),
          index + 1 < CommandLine.arguments.count {
    Preview.run(directory: CommandLine.arguments[index + 1])
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // solo barra dei menu, niente Dock
    app.run()
}
