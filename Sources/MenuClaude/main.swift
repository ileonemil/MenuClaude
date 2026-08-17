import Cocoa

// `MenuClaude --diagnose` stampa a terminale ciò che l'app vede (credenziali,
// risposta dell'API, quote lette) ed esce: utile quando la barra mostra "!".
if CommandLine.arguments.contains("--diagnose") {
    Diagnostics.run()
} else if CommandLine.arguments.contains("--json") {
    Automation.printJSON()
} else if CommandLine.arguments.contains("--update") {
    Diagnostics.update()
} else if CommandLine.arguments.contains("--renew-token") {
    Diagnostics.renewToken()
} else if CommandLine.arguments.contains("--test-notification") {
    Diagnostics.testNotification()
} else if let index = CommandLine.arguments.firstIndex(of: "--analytics-shot"),
          index + 1 < CommandLine.arguments.count {
    // Disegna la finestra delle statistiche su un PNG, chiara e scura, senza
    // aprirla: è l'unico modo di guardare i grafici mentre li si scrive.
    AnalyticsWindowController.writeSnapshots(to: CommandLine.arguments[index + 1])
} else if CommandLine.arguments.contains("--analytics") {
    // Apre la sola finestra delle statistiche, senza barra dei menu: serve a
    // guardare i grafici mentre li si disegna, senza chiudere l'app installata.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let controller = AnalyticsWindowController()
    controller.show()
    app.run()
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
