import SwiftUI
import UIKit

/// Presentation only: the accepted worker remains the sole scheduling authority.
struct ReminderConsentStatus: Equatable {
    enum Phase: Equatable {
        case unavailable, off, stopping, loading, unknown, readFailed, expired, paused
        case permissionPending, pending, confirmed, denied, noEligible, unconfirmed, failed
    }
    let phase: Phase
    var confirmedPendingCount = 0
    var readbackWarning = false
    var partial = false
    var canAllow = false

    init(current: Bool, reading: Bool, active: Bool, optedIn: Bool,
         readFailed: Bool, state: CareOverviewViewState?, eligibleCount: Int,
         authorization: CareReminderPlan.Authorization?, requestingPermission: Bool,
         result: CareReminderScheduler.Result?, now: Date) {
        guard current else { phase = .unavailable; return }
        guard optedIn else {
            if !reading, !readFailed, let result, !result.failed, !result.deferred,
               result.unconfirmedBlockers == 0, result.confirmedPendingCount == 0 {
                phase = .off
            } else {
                phase = .stopping
                readbackWarning = true
            }
            return
        }
        guard !reading else { phase = .loading; return }
        guard !readFailed else { phase = .readFailed; return }
        guard let state else { phase = .unknown; return }
        guard state.access != .expired,
              state.verifiedAccessUntil.map({ $0 > now }) ?? true else {
            phase = .expired; return
        }
        guard state.access != .unknown else { phase = .unknown; return }
        guard active else { phase = .paused; return }
        guard !state.profileHourPending else { phase = .pending; return }
        guard state.availability == .available, state.knownInvalidation == nil,
              state.failure == nil || state.failure == .transport else {
            phase = .paused; return
        }
        if requestingPermission { phase = .permissionPending; return }
        canAllow = eligibleCount > 0 && authorization == .notDetermined
        // A successful OS inventory read is the only source of a positive count.
        if let result, result.confirmedPendingCount > 0 {
            phase = .confirmed
            confirmedPendingCount = result.confirmedPendingCount
            readbackWarning = authorization != .authorized
            partial = result.failed || result.deferred || result.omittedCount > 0
                || result.unconfirmedBlockers > 0
        } else if result?.failed == true {
            phase = .failed
        } else if authorization == .denied {
            phase = .denied
        } else if result?.deferred == true {
            phase = .paused
        } else if eligibleCount == 0 {
            phase = .noEligible
        } else if result == nil {
            phase = .pending
        } else {
            phase = .unconfirmed
            partial = result!.omittedCount > 0 || result!.unconfirmedBlockers > 0
        }
    }
}

/// Observes readiness without starting work or rebinding an existing action.
struct ReminderConsentHost: View {
    @ObservedObject var lifecycle: CareReminderLifecycle
    let connection: CatalogueConnection
    let expected: CatalogueSDKSnapshot
    let polish: Bool
    let isLocaleCurrent: () -> Bool
#if DEBUG
    @Environment(\.reminderConsentFixture) private var fixture
#endif

    var body: some View {
        Group {
            if connection.authClassification == .permanent(expected), isLocaleCurrent() {
#if DEBUG
                if let fixture {
                    ReminderConsentFixtureControls(fixture: fixture, lifecycle: lifecycle,
                        connection: connection, expected: expected, isLocaleCurrent: isLocaleCurrent)
                }
#endif
                if let binding = lifecycle.consentBinding(
                    expectedOwnerId: expected.session.userId, locale: polish ? "pl" : "en") {
                    ReminderConsentView(lifecycle: lifecycle, binding: binding, polish: polish)
                } else {
                    Text(polish ? "Odczytywanie stanu…" : "Reading reminder state…")
                        .accessibilityIdentifier("care.reminders.loading")
                }
            }
        }
    }
}

struct ReminderConsentView: View {
    @ObservedObject var lifecycle: CareReminderLifecycle
    let binding: CareReminderLifecycle.ConsentBinding
    let polish: Bool
    var compact = false
    @Environment(\.openURL) private var openURL
#if DEBUG
    @Environment(\.reminderConsentFixture) private var fixture
#endif

    private var status: ReminderConsentStatus {
        lifecycle.consentStatus(binding: binding)
    }

    var body: some View {
        Group {
            if compact {
                DisclosureGroup(polish ? "Przypomnienia o pielęgnacji" : "Care reminders") {
                    controls
                }
            } else {
                controls
            }
        }
        .accessibilityIdentifier("care.reminders")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(polish ? "Przypomnienia o pielęgnacji" : "Care reminders", isOn: Binding(
                get: { lifecycle.isCurrent(binding: binding) && lifecycle.optedIn },
                set: { lifecycle.performConsentAction(.setOptedIn($0), binding: binding) }
            ))
            .disabled(!lifecycle.isCurrent(binding: binding))
            .accessibilityIdentifier("care.reminders.optIn")
            Text(message(status.phase))
                .accessibilityIdentifier("care.reminders.status")
            if status.phase == .confirmed {
                Text((polish ? "Potwierdzone oczekujące: " : "Confirmed pending: ")
                     + String(status.confirmedPendingCount))
                    .accessibilityIdentifier("care.reminders.confirmed")
            }
            if status.readbackWarning {
                Text(status.phase == .stopping
                     ? (polish ? "Powiadomienia iOS mogą nadal oczekiwać. Ponów sprawdzenie."
                        : "iOS notifications may still be pending. Retry the check.")
                     : (polish ? "Ostatnie sprawdzenie nie potwierdziło uprawnień iOS. Sprawdź status ponownie."
                        : "The latest status check did not confirm iOS permission. Check status again."))
                    .accessibilityIdentifier("care.reminders.readback")
            }
            if status.partial {
                Text(polish ? "Część przypomnień pozostaje niepotwierdzona."
                     : "Some reminders remain unconfirmed.")
                    .accessibilityIdentifier("care.reminders.partial")
            }
            if status.canAllow {
                Button(polish ? "Zezwól na powiadomienia" : "Allow notifications") {
                    lifecycle.performConsentAction(.allow, binding: binding)
                }
                .accessibilityIdentifier("care.reminders.allow")
            }
            Button(polish ? "Sprawdź status / ponów" : "Check status / retry") {
#if DEBUG
                if let fixture, lifecycle.isCurrent(binding: binding),
                   fixture.runtime.core === lifecycle,
                   let connection = fixture.context.connection,
                   fixture.matches(context: fixture.context, connection: connection),
                   fixture.notifications.ledger.owner == binding.ownerId {
                    try? fixture.notifications.markRetry()
                }
#endif
                lifecycle.performConsentAction(.checkStatus, binding: binding)
            }
            .disabled(!lifecycle.isCurrent(binding: binding) || lifecycle.requestingPermission)
            .accessibilityIdentifier("care.reminders.retry")
            if status.phase == .denied || (status.phase == .confirmed && status.readbackWarning && lifecycle.authorization == .denied) {
                Button(polish ? "Ustawienia iOS" : "iOS Settings") {
                    guard lifecycle.isCurrent(binding: binding),
                          let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .accessibilityIdentifier("care.reminders.settings")
            }
            Text(polish ? "Godzinę zmienisz w ustawieniach konta. Ręczny dziennik pielęgnacji pozostaje dostępny."
                 : "Change the hour in account settings. Manual care journaling remains available.")
                .font(.footnote)
        }
    }

    private func message(_ phase: ReminderConsentStatus.Phase) -> String {
        switch phase {
        case .unavailable:
            polish ? "Potwierdź bieżące konto." : "Confirm the current account."
        case .off:
            polish ? "Przypomnienia są wyłączone dla tego konta." : "Reminders are off for this account."
        case .stopping:
            polish ? "Zgoda wyłączona. Nie potwierdzono usunięcia powiadomień iOS. Ponów sprawdzenie."
                : "Preference is off. iOS notification cleanup is not confirmed. Retry the check."
        case .loading:
            polish ? "Odczytywanie stanu…" : "Reading reminder state…"
        case .unknown:
            polish ? "Brak potwierdzonych danych zadań." : "Task data is not confirmed."
        case .readFailed:
            polish ? "Nie udało się odczytać zadań. Ponów sprawdzenie." : "Couldn’t read tasks. Retry the check."
        case .expired:
            polish ? "Dostęp wygasł. Automatyczne przypomnienia są wstrzymane." : "Access expired. Automatic reminders are paused."
        case .paused:
            polish ? "Automatyczne przypomnienia są wstrzymane." : "Automatic reminders are paused."
        case .permissionPending:
            polish ? "Oczekiwanie na uprawnienia iOS…" : "Waiting for iOS permission…"
        case .pending:
            polish ? "Oczekiwanie na potwierdzenie przypomnień…" : "Waiting for reminder confirmation…"
        case .confirmed:
            polish ? "Potwierdzono oczekujące powiadomienia iOS." : "Pending iOS notifications confirmed."
        case .denied:
            polish ? "Powiadomienia są zablokowane w iOS." : "Notifications are denied in iOS."
        case .noEligible:
            polish ? "Brak przyszłych zadań do przypomnienia. Zgoda nie wywoła automatycznego pytania iOS."
                : "No eligible future tasks. This preference will not automatically prompt for iOS permission."
        case .unconfirmed:
            polish ? "Nie potwierdzono żadnych oczekujących przypomnień." : "No pending reminders confirmed."
        case .failed:
            polish ? "Nie udało się potwierdzić przypomnień. Ponów sprawdzenie." : "Couldn’t confirm reminders. Retry the check."
        }
    }
}
