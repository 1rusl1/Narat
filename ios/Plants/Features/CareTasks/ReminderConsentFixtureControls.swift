#if DEBUG
import SwiftUI

private struct ReminderConsentFixtureKey: EnvironmentKey {
    static var defaultValue: ReminderConsentFixture? { nil }
}

extension EnvironmentValues {
    var reminderConsentFixture: ReminderConsentFixture? {
        get { self[ReminderConsentFixtureKey.self] }
        set { self[ReminderConsentFixtureKey.self] = newValue }
    }
}

/// Captures the original host scope, even while readiness holds Core binding.
struct ReminderConsentFixtureControls: View {
    let fixture: ReminderConsentFixture
    let lifecycle: CareReminderLifecycle
    let connection: CatalogueConnection
    let expected: CatalogueSDKSnapshot
    let isLocaleCurrent: () -> Bool
    @State private var evidence = ""

    private var current: Bool {
        connection.authClassification == .permanent(expected) && isLocaleCurrent()
            && fixture.runtime.core === lifecycle
            && fixture.matches(context: fixture.context, connection: connection)
            && expected.session.userId == fixture.notifications.ledger.owner
    }

    var body: some View {
        if current {
            VStack {
                if fixture.configuration.mode == .routing {
                    Button("Deliver fake notification tap") { perform { try fixture.deliverRouting(kind: "tap") } }
                        .accessibilityIdentifier("care.fixture.notificationTap")
                        .accessibilityValue(fixture.routingPlantName)
                    Button("Deliver fake foreground notification") {
                        perform { try fixture.deliverRouting(kind: "foreground") }
                    }
                    .accessibilityIdentifier("care.fixture.notificationForeground")
                }
                if fixture.configuration.mode == .readiness {
                    Button("Release readiness") { perform { fixture.runtime.readiness.release() } }
                        .accessibilityIdentifier("care.fixture.ready")
                }
                Button("Snapshot fixture evidence") { perform { try fixture.snapshotEvidence() } }
                    .accessibilityIdentifier("care.fixture.snapshot")
                Button("Authorize fake OS") { perform { try fixture.notifications.setAuthorization(.authorized) } }
                    .accessibilityIdentifier("care.fixture.authorized")
                Button("Clear fake failure") { perform { try fixture.notifications.setFailures(add: false, inventory: false) } }
                    .accessibilityIdentifier("care.fixture.clearFailure")
                Button("Fail fake inventory") { perform { try fixture.notifications.setFailures(add: false, inventory: true) } }
                    .accessibilityIdentifier("care.fixture.failInventory")
                if fixture.configuration.mode == .noSchedule {
                    Button("Restore fixture schedule") { perform { try fixture.restoreSchedule() } }
                        .accessibilityIdentifier("care.fixture.restore")
                }
                Text(evidence).accessibilityIdentifier("care.fixture.changed")
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        guard current else { return }
        do {
            try action()
            evidence = "Changed: " + String((fixture.notifications.ledger.markers?.count ?? 0)
                + (fixture.notifications.ledger.routingProbes?.count ?? 0))
        } catch { evidence = "Fixture change failed" }
    }
}
#endif
