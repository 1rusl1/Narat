import Foundation

/// One pending Inbox intent, pinned before suspension. Root supplies only a coherent local
/// cache reader. Snapshot is the original SDK snapshot (CatalogueSDKSnapshot in Root).
@MainActor
final class CareReminderTapCoordinator<Snapshot: Equatable> {
    @MainActor
    struct Source {
        let connection: ObjectIdentifier
        let ownerId: UUID
        let snapshot: Snapshot
        let locale: String
        // Must include current Root connection identity, SDK epoch and locale; never scene activity.
        let isCurrent: @MainActor () -> Bool
        // Capture the original authority/lease before suspension and validate that SAME lease
        // before and after cachedCareOverview. Missing authority returns nil, never refreshes.
        let readCache: @MainActor () async throws -> CareOverviewViewState?

        fileprivate func matches(_ other: Source) -> Bool {
            connection == other.connection && ownerId == other.ownerId
                && snapshot == other.snapshot && locale == other.locale
        }
    }

    enum Scope {
        case unresolved
        case signedOut
        case anonymous
        case permanent(Source)
    }

    @MainActor
    struct Resolution {
        let intent: CareReminderNotificationInbox.Intent
        let decision: CareReminderRouting.Decision
        let source: Source?
        fileprivate let revision: UUID
        fileprivate let state: CareOverviewViewState?
    }

    @MainActor
    struct Target {
        let intent: CareReminderNotificationInbox.Intent
        let plantId: UUID
        let source: Source
    }

    private let inbox: CareReminderNotificationInbox
    private let clock: @MainActor () -> Date
    private let timeZone: @MainActor () -> TimeZone
    private var intent: CareReminderNotificationInbox.Intent?
    private var original: Source?
    private var dropped = false
    private var revision = UUID()

    init(inbox: CareReminderNotificationInbox,
         clock: @escaping @MainActor () -> Date,
         timeZone: @escaping @MainActor () -> TimeZone) {
        self.inbox = inbox
        self.clock = clock
        self.timeZone = timeZone
    }

    /// nil means a displaced intent/read: it grants no authority over the pending tap.
    func resolve(_ requested: CareReminderNotificationInbox.Intent, scope: Scope) async -> Resolution? {
        guard inbox.pendingTap == requested else { return nil }
        if intent != requested {
            intent = requested
            original = nil
            dropped = false
        }
        revision = UUID()
        let readRevision = revision
        @MainActor
        func result(_ decision: CareReminderRouting.Decision,
                    state: CareOverviewViewState? = nil) -> Resolution {
            Resolution(intent: requested, decision: decision, source: original,
                       revision: readRevision, state: state)
        }
        guard !dropped else { return result(.drop) }
        // Evaluate the pinned closure even during unresolved auth or UI HOLD.
        if let original, !original.isCurrent() {
            dropped = true
            return result(.drop)
        }
        switch scope {
        case .unresolved:
            return result(.hold)
        case .signedOut, .anonymous:
            dropped = true
            return result(.drop)
        case .permanent(let supplied):
            if let original {
                guard original.matches(supplied) else {
                    dropped = true
                    return result(.drop)
                }
            } else {
                guard supplied.ownerId == requested.route.candidate.ownerId,
                      supplied.isCurrent() else {
                    dropped = true
                    return result(.drop)
                }
                original = supplied
            }
        }
        guard let pinned = original else { return result(.hold) }
        // Cancellation preserves the immutable binding and invalidates any previous read.
        guard !Task.isCancelled else { return result(.hold) }
        let state: CareOverviewViewState?
        do {
            state = try await pinned.readCache()
        } catch {
            guard intent == requested, inbox.pendingTap == requested,
                  revision == readRevision else { return nil }
            if !pinned.isCurrent() {
                dropped = true
                return result(.drop)
            }
            return result(.hold)
        }
        guard intent == requested, inbox.pendingTap == requested,
              revision == readRevision else { return nil }
        guard pinned.isCurrent() else {
            dropped = true
            return result(.drop)
        }
        guard !Task.isCancelled else { return result(.hold) }
        let decision = CareReminderRouting.decide(requested.route,
            expectedOwnerId: pinned.ownerId, locale: pinned.locale,
            state: state, now: clock(), timeZone: timeZone())
        if decision == .drop { dropped = true }
        return result(decision, state: state)
    }

    /// Presentation availability is a final UI gate, never a source-currentness predicate.
    /// Returns the original SDK target only after exact one-shot consumption. No UI effects.
    func consumeOpen(_ result: Resolution, scope: Scope, presentationAvailable: Bool) -> Target? {
        guard inbox.pendingTap == result.intent, intent == result.intent,
              revision == result.revision, !dropped, let pinned = original else { return nil }
        guard pinned.isCurrent() else {
            dropped = true
            return nil
        }
        switch scope {
        case .unresolved:
            return nil
        case .signedOut, .anonymous:
            dropped = true
            return nil
        case .permanent(let supplied):
            guard pinned.matches(supplied) else {
                dropped = true
                return nil
            }
        }
        let fresh = CareReminderRouting.decide(result.intent.route,
            expectedOwnerId: pinned.ownerId, locale: pinned.locale,
            state: result.state, now: clock(), timeZone: timeZone())
        if fresh == .drop { dropped = true }
        guard !Task.isCancelled, presentationAvailable,
              case .open(let plantId) = result.decision, fresh == result.decision else { return nil }
        inbox.consume(intentID: result.intent.id)
        dropped = true
        revision = UUID()
        return Target(intent: result.intent, plantId: plantId, source: pinned)
    }
}
