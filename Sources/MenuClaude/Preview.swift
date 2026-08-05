import Cocoa

/// `MenuClaude --preview <cartella>` disegna il pannello e la voce di barra su
/// PNG, in chiaro e in scuro, senza dover aprire l'app. Serve per rivedere il
/// layout dopo una modifica.
enum Preview {
    static func run(directory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let snapshot = fixture()
        for (name, appearance) in [("chiaro", NSAppearance(named: .aqua)!), ("scuro", NSAppearance(named: .darkAqua)!)] {
            NSAppearance.current = appearance
            write(panel(snapshot, appearance: appearance), to: "\(directory)/pannello-\(name).png")
            write(menuBar(snapshot, appearance: appearance), to: "\(directory)/barra-\(name).png")
        }

        // Lo stato di errore: dato vecchio ma ancora mostrato, con l'attesa
        // prima del prossimo tentativo.
        NSAppearance.current = NSAppearance(named: .aqua)!
        var stale = snapshot
        stale.fetchedAt = Date().addingTimeInterval(-8 * 60)
        write(
            panel(stale, appearance: NSAppearance(named: .aqua)!,
                  error: .rateLimited(retryAfter: nil),
                  retryAt: Date().addingTimeInterval(4 * 60)),
            to: "\(directory)/pannello-429.png"
        )

        // Token scaduto: è lo stato in cui compare il pulsante Rinnova.
        write(
            panel(stale, appearance: NSAppearance(named: .aqua)!, error: .tokenExpired),
            to: "\(directory)/pannello-token.png"
        )
        print("Anteprime scritte in \(directory)")
        exit(0)
    }

    private static func fixture() -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.plan = "max"
        snapshot.limits = [
            UsageLimit(kind: "session", group: "session", percent: 78,
                       resetsAt: Date().addingTimeInterval(2 * 3600 + 41 * 60),
                       severity: .warning, isActive: true),
            UsageLimit(kind: "weekly_all", group: "weekly", percent: 54,
                       resetsAt: Date().addingTimeInterval(2 * 86400 + 5 * 3600),
                       severity: .normal, isActive: true),
            UsageLimit(kind: "weekly_opus", group: "weekly", percent: 93,
                       resetsAt: Date().addingTimeInterval(2 * 86400 + 5 * 3600),
                       severity: .critical, isActive: false),
        ]
        snapshot.extra = ExtraUsage(percent: 29, usedMinor: 437, limitMinor: 1500,
                                    currency: "EUR", exponent: 2, severity: .normal)
        return snapshot
    }

    private static func panel(
        _ snapshot: UsageSnapshot,
        appearance: NSAppearance,
        error: UsageError? = nil,
        retryAt: Date? = nil,
        serverStatus: ServerStatus? = ServerStatus(
            indicator: "none",
            description: "All Systems Operational",
            affected: [],
            incidents: []
        )
    ) -> NSImage {
        let controller = PopoverViewController()
        let view = controller.view
        view.appearance = appearance
        controller.render(snapshot: snapshot, error: error, retryAt: retryAt, serverStatus: serverStatus)

        let fitting = view.fittingSize
        view.frame = NSRect(origin: .zero, size: fitting)
        view.layoutSubtreeIfNeeded()

        let background = NSView(frame: view.frame)
        background.appearance = appearance
        background.wantsLayer = true
        background.layer?.backgroundColor = appearance.isDark
            ? NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
            : NSColor(calibratedWhite: 0.98, alpha: 1).cgColor
        background.addSubview(view)

        return image(of: background)
    }

    private static func menuBar(_ snapshot: UsageSnapshot, appearance: NSAppearance) -> NSImage {
        let width: CGFloat = 300
        let height: CGFloat = 24
        let session = snapshot.session!
        let weekly = snapshot.weekly!
        let ring = RingIcon.image(progress: session.percent / 100, severity: session.severity, colored: true)
        let rings = RingIcon.concentric(
            session: session.percent / 100,
            window: session.windowProgress(),
            weekly: weekly.percent / 100,
            sessionSeverity: session.severity,
            weeklySeverity: weekly.severity,
            colored: true
        )
        let text = "\(Format.percent(session.percent)) · \(Format.countdown(to: session.resetsAt) ?? "") · \(Format.percent(weekly.percent))"

        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSAppearance.current = appearance
            (appearance.isDark ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()

            ring.draw(in: NSRect(x: 8, y: (height - 15) / 2, width: 15, height: 15))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monoDigits(11.5, .medium),
                .foregroundColor: appearance.isDark ? NSColor.white : NSColor.black,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let size = string.size()
            string.draw(at: NSPoint(x: 28, y: (height - size.height) / 2))

            // A destra, la stessa informazione in modalità anelli concentrici.
            rings.draw(in: NSRect(x: width - 30, y: (height - 18) / 2, width: 18, height: 18))
            return true
        }
    }

    private static func image(of view: NSView) -> NSImage {
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func write(_ image: NSImage, to path: String) {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
