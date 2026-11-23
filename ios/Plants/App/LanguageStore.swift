import Foundation
import Observation
import SwiftUI

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

// MARK: - Quiet Garden presentation
// Shared by existing target members; no network, state, routing or persistence lives here.

enum QuietGarden {
    static let background = Color("QGBackground")
    static let surface = Color("QGSurface")
    static let primaryText = Color("QGPrimaryText")
    static let secondaryText = Color("QGSecondaryText")
    static let accent = Color("QGAccent")
    static let onAccent = Color("QGOnAccent")
    static let separator = Color("QGSeparator")
    static let controlBorder = Color("QGControlBorder")
    static let warning = Color("QGWarning")
    static let danger = Color("QGDanger")
}

enum QuietGardenTone {
    case neutral, warning, error, success
    var color: Color {
        switch self {
        case .neutral: QuietGarden.secondaryText
        case .warning: QuietGarden.warning
        case .error: QuietGarden.danger
        case .success: QuietGarden.accent
        }
    }
}

struct QuietGardenPrimaryButtonStyle: ButtonStyle {
    var inverted = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .foregroundStyle(enabled ? (inverted ? QuietGarden.accent : QuietGarden.onAccent) : QuietGarden.secondaryText)
            .background(enabled ? (configuration.role == .destructive ? QuietGarden.danger : (inverted ? QuietGarden.onAccent : QuietGarden.accent)) : QuietGarden.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(enabled ? .clear : QuietGarden.separator, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct QuietGardenSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .multilineTextAlignment(.leading)
            .frame(minHeight: 44)
            .padding(.horizontal, 16).padding(.vertical, 4)
            .foregroundStyle(enabled ? (configuration.role == .destructive ? QuietGarden.danger : QuietGarden.accent) : QuietGarden.secondaryText)
            .background(QuietGarden.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(enabled ? QuietGarden.controlBorder : QuietGarden.separator, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct QuietGardenCard: ViewModifier {
    let padding: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QuietGarden.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct QuietGardenNotice: ViewModifier {
    let tone: QuietGardenTone
    func body(content: Content) -> some View {
        content
            .font(.subheadline)
            .foregroundStyle(tone.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(tone.color)
                    .frame(width: 3).padding(.vertical, 12)
                    .accessibilityHidden(true)
            }
    }
}

struct QuietGardenActionLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).resizable().scaledToFit()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
    }
}

extension View {
    func qgScreen() -> some View {
        self.foregroundStyle(QuietGarden.primaryText)
            .tint(QuietGarden.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(QuietGarden.background.ignoresSafeArea())
    }
    func qgCard(padding: CGFloat = 20) -> some View { modifier(QuietGardenCard(padding: padding)) }
    func qgNotice(_ tone: QuietGardenTone = .neutral) -> some View { modifier(QuietGardenNotice(tone: tone)) }
    func qgSectionTitle() -> some View {
        self.font(.title2.weight(.semibold)).foregroundStyle(QuietGarden.primaryText)
            .padding(.top, 8).accessibilityAddTraits(.isHeader)
    }
    func qgForm() -> some View {
        self.scrollContentBackground(.hidden).qgScreen()
    }
}
