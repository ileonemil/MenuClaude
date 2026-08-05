import Foundation

enum Language: Int, CaseIterable {
    case system = 0
    case italian = 1
    case english = 2

    var label: String {
        switch self {
        case .system: return L.t("Come il sistema", "Same as system")
        case .italian: return "Italiano"
        case .english: return "English"
        }
    }
}

/// Due lingue soltanto, quindi niente file `.strings`: le traduzioni stanno
/// accanto al testo che traducono, dove è più difficile dimenticarne una.
enum L {
    static var selected: Language {
        Settings.shared.language
    }

    /// Con "come il sistema" si guarda la lingua preferita del Mac: tutto ciò
    /// che non è italiano ricade sull'inglese.
    static var isEnglish: Bool {
        switch selected {
        case .italian: return false
        case .english: return true
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return !preferred.lowercased().hasPrefix("it")
        }
    }

    static func t(_ italian: String, _ english: String) -> String {
        isEnglish ? english : italian
    }

    static var locale: Locale {
        Locale(identifier: isEnglish ? "en_US" : "it_IT")
    }
}
