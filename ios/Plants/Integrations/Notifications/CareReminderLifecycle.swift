import Foundation
import Combine

/// Cache-only coordinator. Root supplies accepted permanent auth; construction is inert.
@MainActor
final class CareReminderLifecycle: ObservableObject {
    struct Context {
        let lease: SyncSessionLease
        let store: LocalStore
        let authority: SyncSessionAuthority
        let engine: SyncEngine
        let locale: String
        let isCurrent: () -> Bool
        var readCache: (() async throws -> CareOverviewViewState)? = nil
    }

    /// Immutable authority captured when the consent controls are presented.
    struct ConsentBinding: Equatable {
        fileprivate let scopeId: UUID
        let ownerId: UUID
        let locale: String
    }

    private final class Scope {
        let id = UUID()
        let context: Context
        init(_ context: Context) { self.context = context }
    }

    @Published private(set) var state: CareOverviewViewState?
    @Published private(set) var readFailed = false
    @Published private(set) var optedIn = false
    @Published private(set) var revision: UInt64 = 0
    let worker: CareReminderScheduler
    var result: CareReminderScheduler.Result? { worker.result }
    var authorization: CareReminderPlan.Authorization? { worker.authorization }
    var requestingPermission: Bool { worker.requestingPermission }

    private let defaults: UserDefaults
    private let clock: () -> Date
    private let timeZone: () -> TimeZone
    private var forwarding: AnyCancellable?
    private var scope: Scope?
    private var active = false
    private var authHeld = true
    private var dirty = false
    private var readTask: Task<Void, Never>?
    private var localTask: Task<Void, Never>?
    private var canonicalTask: Task<Void, Never>?

    init(notifications: any CareReminderNotifications, defaults: UserDefaults,
         clock: @escaping () -> Date, timeZone: @escaping () -> TimeZone) {
        self.defaults = defaults
        self.clock = clock
        self.timeZone = timeZone
        worker = CareReminderScheduler(notifications: notifications)
        forwarding = worker.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        readTask?.cancel()
        localTask?.cancel()
        canonicalTask?.cancel()
    }

    static func preferenceKey(ownerId: UUID) -> String {
        "narat.care-reminders.opt-in.v1." + ownerId.uuidString.lowercased()
    }

    func accept(_ context: Context) {
        guard context.isCurrent(),
              (try? context.authority.withPermanentBoundValid(context.lease) {}) != nil else {
            suspendAuth()
            return
        }
        let previous = scope?.context
        let knownDirty = dirty && previous?.lease.ownerId == context.lease.ownerId
            && previous?.authority === context.authority
        stopObservations()
        if let previous, previous.lease.ownerId != context.lease.ownerId
            || previous.authority !== context.authority { worker.cancelAll() }
        let next = Scope(context)
        scope = next
        authHeld = false
        state = nil
        readFailed = false
        dirty = knownDirty
        optedIn = defaults.bool(forKey: Self.preferenceKey(ownerId: context.lease.ownerId))
        revision &+= 1
        // Must run before the first cache read: foreign cleanup and unknown-own journaling.
        submit(next)
        readTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.scope === next { self.readTask = nil } }
            guard self.valid(next) else { return }
            let local = await context.store.localOutboxUpdates(ownerId: context.lease.ownerId)
            guard self.valid(next) else { return }
            self.localTask = self.observe(local, scope: next)
            let canonical = await context.engine.canonicalSyncUpdates()
            guard self.valid(next) else { return }
            self.canonicalTask = self.observe(canonical, scope: next)
            await self.worker.waitUntilIdle()
            guard self.valid(next) else { return }
            await self.read(next)
        }
    }

    /// Unresolved SDK startup/refresh is not logout. Keep requests and local subscriptions.
    func suspendAuth() {
        authHeld = true
        readTask?.cancel()
        readTask = nil
        revision &+= 1
        worker.hold()
    }

    func logout() {
        stopObservations()
        scope = nil
        authHeld = true
        state = nil
        readFailed = false
        optedIn = false
        dirty = false
        revision &+= 1
        worker.cancelAll()
    }

    func setSceneActive(_ value: Bool) {
        active = value
        guard let scope, valid(scope) else { return }
        if value { signal(scope, durable: false) }
        else if readTask == nil && !readFailed { submit(scope) }
        else { worker.hold() }
    }

    /// Future Root calls this for derived cache publication, timezone and clock boundaries.
    /// No timer, Store polling, canonical publication or network operation is started here.
    func cachePublicationOrTimeChanged() {
        guard let scope else { return }
        signal(scope, durable: true)
    }

    func setOptedIn(_ value: Bool, requestPermission: Bool = false) {
        guard let scope, valid(scope) else { return }
        defaults.set(value, forKey: Self.preferenceKey(ownerId: scope.context.lease.ownerId))
        optedIn = value
        if !value { submit(scope, preference: false) }
        else if readTask == nil && !readFailed { submit(scope) }
        if requestPermission { requestEligiblePermission() }
    }

    func requestEligiblePermission() {
        guard let scope, valid(scope), active, optedIn,
              readTask == nil, !readFailed else { return }
        worker.requestPermission()
    }

    func retry() {
        guard let scope else { return }
        signal(scope, durable: false)
    }

    // Read-only presentation scope; every action rechecks the original SDK lease synchronously.
    func isCurrent(ownerId: UUID) -> Bool {
        guard let scope, scope.context.lease.ownerId == ownerId else { return false }
        return valid(scope)
    }

    func consentBinding(expectedOwnerId: UUID, locale: String) -> ConsentBinding? {
        guard let scope, scope.context.lease.ownerId == expectedOwnerId,
              scope.context.locale == locale, valid(scope) else { return nil }
        return ConsentBinding(scopeId: scope.id, ownerId: expectedOwnerId, locale: locale)
    }

    func isCurrent(binding: ConsentBinding) -> Bool {
        guard let scope, scope.id == binding.scopeId,
              scope.context.lease.ownerId == binding.ownerId,
              scope.context.locale == binding.locale else { return false }
        return valid(scope)
    }

    func eligibleCandidateCount(expectedOwnerId: UUID) -> Int {
        guard isCurrent(ownerId: expectedOwnerId), let scope, readTask == nil,
              !readFailed else { return 0 }
        return CareReminderPlan(expectedOwnerId: expectedOwnerId, state: state,
            optedIn: true, authorization: .authorized, now: clock(),
            timeZone: timeZone(), locale: scope.context.locale).candidates.count
    }

    func offersConsent(expectedOwnerId: UUID) -> Bool {
        active && eligibleCandidateCount(expectedOwnerId: expectedOwnerId) > 0
    }

    func consentStatus(binding: ConsentBinding) -> ReminderConsentStatus {
        ReminderConsentStatus(
            current: isCurrent(binding: binding)
                && (state == nil || state?.ownerId == binding.ownerId),
            reading: readTask != nil, active: active, optedIn: optedIn,
            readFailed: readFailed, state: state,
            eligibleCount: eligibleCandidateCount(expectedOwnerId: binding.ownerId),
            authorization: authorization, requestingPermission: requestingPermission,
            result: result, now: clock())
    }

    enum ConsentAction {
        case setOptedIn(Bool), allow, checkStatus
    }

    func performConsentAction(_ action: ConsentAction, binding: ConsentBinding) {
        guard isCurrent(binding: binding) else { return }
        switch action {
        case .setOptedIn(let value):
            // Preference only: neither now nor on later eligibility does this create prompt intent.
            setOptedIn(value)
        case .allow:
            guard active, optedIn,
                  eligibleCandidateCount(expectedOwnerId: binding.ownerId) > 0 else { return }
            requestEligiblePermission()
        case .checkStatus:
            retry()
        }
    }

    func waitUntilIdle() async {
        repeat {
            await readTask?.value
            await worker.waitUntilIdle()
        } while readTask != nil
    }

    private func valid(_ expected: Scope) -> Bool {
        guard scope === expected, !authHeld, expected.context.isCurrent() else { return false }
        return (try? expected.context.authority.withPermanentBoundValid(expected.context.lease) {}) != nil
    }

    private func stopObservations() {
        readTask?.cancel()
        localTask?.cancel()
        canonicalTask?.cancel()
        readTask = nil
        localTask = nil
        canonicalTask = nil
    }

    private func observe(_ updates: AsyncStream<Void>, scope: Scope) -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in updates {
                guard !Task.isCancelled, let self, self.scope === scope else { return }
                self.signal(scope, durable: true)
            }
        }
    }

    private func signal(_ scope: Scope, durable: Bool) {
        guard self.scope === scope else { return }
        dirty = dirty || durable
        // Revoke stale add authority synchronously, before any cache-reader suspension.
        worker.hold()
        revision &+= 1
        guard valid(scope), readTask == nil else { return }
        readTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.scope === scope { self.readTask = nil } }
            await self.read(scope)
        }
    }

    private func read(_ scope: Scope) async {
        let context = scope.context
        while valid(scope) && !Task.isCancelled {
            let expected = revision
            do {
                let next: CareOverviewViewState
                if let reader = context.readCache {
                    next = try await reader()
                } else {
                    let local = try await context.store.readCareOverviewPresentation(
                        context: context.lease, authority: context.authority)
                    guard valid(scope), !Task.isCancelled else { return }
                    next = CareOverviewViewState(local: local, now: clock(), origin: .cache)
                }
                guard valid(scope), !Task.isCancelled else { return }
                guard expected == revision else { continue }
                guard next.ownerId == context.lease.ownerId else { throw ScopeError.foreignCache }
                let unknown = next.availability == .unavailable && next.snapshotLocale == nil
                    && next.knownInvalidation == nil && next.pending.isEmpty
                    && !next.profileHourPending && next.access != .expired
                    && (next.verifiedAccessUntil.map { $0 > clock() } ?? true)
                    && (next.failure == nil || next.failure == .transport)
                state = unknown ? nil : next
                readFailed = false
                dirty = false
                submit(scope)
            } catch {
                guard valid(scope), !Task.isCancelled else { return }
                guard expected == revision else { continue }
                readFailed = true
                // Known durable change + failed read must never revive old add authority.
                // Use the accepted cleanup path; consent remains untouched.
                if dirty { submit(scope, preference: false) }
                else { worker.hold() }
            }
            return
        }
    }
    private enum ScopeError: Error { case foreignCache }

    private func submit(_ scope: Scope, preference: Bool? = nil) {
        guard valid(scope) else { return }
        let context = scope.context
        worker.update(.init(lease: context.lease, store: context.store, authority: context.authority,
            isCurrent: { [weak self] in self?.valid(scope) == true }, state: state,
            optedIn: preference ?? optedIn, allowNewRequests: active && !readFailed,
            locale: context.locale, timeZone: timeZone(), clock: clock))
    }
}
