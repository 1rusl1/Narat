import Foundation
import Observation

public enum SupportedLocale: String, CaseIterable, Codable, Sendable {
    case pl = "pl"
    case en = "en"

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    public static func resolveInitial(preferredLanguages: [String] = Locale.preferredLanguages) -> SupportedLocale {
        for identifier in preferredLanguages {
            let normalized = identifier.lowercased()
            if normalized.hasPrefix("pl") {
                return .pl
            }
            if normalized.hasPrefix("en") {
                return .en
            }
        }
        return .en
    }
}

@MainActor
@Observable
public final class LanguageStore {
    private static let storageKey = "narat.preferred_locale"
    private let userDefaults: UserDefaults

    public var currentLocale: SupportedLocale {
        didSet {
            userDefaults.set(currentLocale.rawValue, forKey: Self.storageKey)
        }
    }

    public init(userDefaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.userDefaults = userDefaults
        if let saved = userDefaults.string(forKey: Self.storageKey),
           let parsed = SupportedLocale(rawValue: saved) {
            self.currentLocale = parsed
        } else {
            let resolved = SupportedLocale.resolveInitial(preferredLanguages: preferredLanguages)
            self.currentLocale = resolved
            userDefaults.set(resolved.rawValue, forKey: Self.storageKey)
        }
    }
}
