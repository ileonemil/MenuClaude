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
