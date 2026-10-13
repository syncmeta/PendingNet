import Foundation

public enum PendingNetLanguage: String, CaseIterable, Sendable {
    case system, simplified = "zh-Hans", traditional = "zh-Hant", english = "en"
}

public enum PendingNetLanguagePreferences {
    public static let key = "pendingnet.language"
    public static func save(_ language: PendingNetLanguage, defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: key)
        if language == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([language.rawValue], forKey: "AppleLanguages") }
    }
    public static var locale: Locale {
        let raw = UserDefaults.standard.string(forKey: key) ?? "system"
        return raw == "system" ? .autoupdatingCurrent : Locale(identifier: raw)
    }
    public static var bundle: Bundle {
        guard let raw = UserDefaults.standard.string(forKey: key), raw != "system",
              let path = Bundle.main.path(forResource: raw, ofType: "lproj"), let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
    public static func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, value: key, comment: "PendingNet")
    }
}
