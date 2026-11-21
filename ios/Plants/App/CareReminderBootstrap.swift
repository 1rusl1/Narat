import SwiftUI

/// Publishes a runtime together with its source, before Root can run any callbacks.
@MainActor
final class CareReminderBootstrap: ObservableObject {
    enum Startup {
        case loading, failed
        case ordinary(CareReminderRuntime)
#if DEBUG
        case fixture(ReminderConsentFixture)
#endif
    }

    @Published private(set) var startup: Startup
#if DEBUG
    private let configuration: ReminderConsentLaunch.Configuration?
    private let fixtureFactory: @MainActor (ReminderConsentLaunch.Configuration) async throws -> ReminderConsentFixture
    private var attempted = false

    convenience init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.init(arguments: arguments, productionFactory: { .production() },
                  fixtureFactory: { try await ReminderConsentFixture.makeContext($0) })
    }

    /// Injection is confined to DEBUG tests; production never constructs a placeholder.
    init(arguments: [String],
         productionFactory: @MainActor () -> CareReminderRuntime,
         fixtureFactory: @escaping @MainActor (ReminderConsentLaunch.Configuration) async throws -> ReminderConsentFixture) {
        self.fixtureFactory = fixtureFactory
        switch ReminderConsentLaunch.parse(arguments) {
        case .ordinary:
            configuration = nil
            startup = .ordinary(productionFactory())
        case .invalid:
            configuration = nil
            startup = .failed
        case .fixture(let configuration):
            self.configuration = configuration
            startup = .loading
        }
    }
#else
    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        startup = .ordinary(.production())
    }
#endif

    func prepare() async {
#if DEBUG
        guard !attempted, let configuration else { return }
        attempted = true
        do {
            try Task.checkCancellation()
            let fixture = try await fixtureFactory(configuration)
            guard !Task.isCancelled, fixture.configuration == configuration,
                  let connection = fixture.context.connection,
                  fixture.matches(context: fixture.context, connection: connection) else {
                fixture.context.shutdown()
                startup = .failed
                return
            }
            if configuration.mode != .readiness { fixture.runtime.readiness.release() }
            startup = .fixture(fixture)
        } catch {
            startup = .failed
        }
#endif
    }
}
