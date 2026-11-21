import Foundation
import Combine

/// Owns exactly one accepted coordinator; construction never accepts auth or reads the OS.
@MainActor
final class CareReminderRuntime: ObservableObject {
    let core: CareReminderLifecycle
    let readiness: CareReminderReadiness
    private var forwarding: AnyCancellable?

    init(core: CareReminderLifecycle, readiness: CareReminderReadiness = .init()) {
        self.core = core
        self.readiness = readiness
        forwarding = core.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    static func production() -> CareReminderRuntime {
        .init(core: CareReminderLifecycle(
            notifications: SystemCareReminderNotifications(), defaults: .standard,
            clock: { Date() }, timeZone: { TimeZone.current }))
    }
}

/// Future callers must revalidate their SDK lease after this suspension, before Core.accept.
@MainActor
final class CareReminderReadiness {
    private var released = true
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init() {}

    func wait() async throws {
        try Task.checkCancellation()
        guard !released else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
    }

    deinit {
        for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
    }

#if DEBUG
    init(held: Bool) { released = !held }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values { waiter.resume() }
    }

    var waitingCount: Int { waiters.count }
#endif
}
