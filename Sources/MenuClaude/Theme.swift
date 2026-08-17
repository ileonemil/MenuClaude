import Cocoa

enum Theme {
    static func color(for severity: Severity) -> NSColor {
        switch severity {
        case .normal:
            return NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(calibratedRed: 0.42, green: 0.80, blue: 0.55, alpha: 1)
                    : NSColor(calibratedRed: 0.18, green: 0.63, blue: 0.36, alpha: 1)
            }
        case .warning:
            return NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(calibratedRed: 0.98, green: 0.76, blue: 0.33, alpha: 1)
                    : NSColor(calibratedRed: 0.85, green: 0.56, blue: 0.05, alpha: 1)
            }
        case .critical:
            return NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.40, alpha: 1)
                    : NSColor(calibratedRed: 0.80, green: 0.19, blue: 0.16, alpha: 1)
            }
        }
    }

    static let track = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.10)
    }

    static let accent = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.30, alpha: 1) // arancio Claude
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSFont {
    static func monoDigits(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

extension NSFont {
    func bold() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}

// MARK: - Colori per i grafici

extension Theme {
    /// Tavolozza categoriale per identità (i modelli). L'ordine è fisso e non
    /// va mai riciclato: oltre l'ultimo slot si accorpa in "altri".
    /// Le due colonne sono state validate separatamente per la superficie
    /// chiara e per quella scura — non sono una l'inversione dell'altra.
    private static let categoricalLight = ["2a78d6", "eb6834", "1baf7a", "eda100", "e87ba4"]
    private static let categoricalDark = ["3987e5", "d95926", "199e70", "c98500", "d55181"]

    static func categorical(_ index: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let palette = appearance.isDark ? categoricalDark : categoricalLight
            return NSColor(hex: palette[index % palette.count])
        }
    }

    static var categoricalCount: Int { categoricalLight.count }

    /// Rampa sequenziale a tinta unica per la magnitudine (la heatmap).
    /// Chiara→scura sul fondo chiaro, scura→chiara su quello scuro: in
    /// entrambi i casi il valore basso si confonde con lo sfondo e l'alto salta
    /// all'occhio. Una scala arcobaleno qui sarebbe illeggibile.
    private static let blueRamp = [
        "cde2fb", "b7d3f6", "9ec5f4", "86b6ef", "6da7ec",
        "5598e7", "3987e5", "2a78d6", "256abf", "1c5cab",
        "184f95", "104281", "0d366b",
    ]

    static func sequential(_ value: Double) -> NSColor {
        let clamped = min(max(value, 0), 1)
        return NSColor(name: nil) { appearance in
            let steps = blueRamp
            if appearance.isDark {
                // Dal passo più scuro (che si appoggia allo sfondo) al più chiaro.
                let index = Int(round((1 - clamped) * Double(steps.count - 3))) + 2
                return NSColor(hex: steps[min(index, steps.count - 1)])
            }
            let index = Int(round(clamped * Double(steps.count - 4)))
            return NSColor(hex: steps[min(index, steps.count - 1)])
        }
    }

    /// Cella senza attività: neutra, non un passo della rampa.
    static let emptyCell = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(calibratedWhite: 1, alpha: 0.06)
                          : NSColor(calibratedWhite: 0, alpha: 0.05)
    }

    /// Fondo delle tessere: appena staccato dalla superficie, non un riquadro.
    static let tileBackground = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(calibratedWhite: 1, alpha: 0.05)
                          : NSColor(calibratedWhite: 0, alpha: 0.035)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
