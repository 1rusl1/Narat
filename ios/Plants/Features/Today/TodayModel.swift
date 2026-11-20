import Foundation
import Observation

/// Presentation only. The caller validates its original permanent lease before every call.
@MainActor @Observable
final class TodayModel {
    struct Scope: Equatable, Sendable {
        let ownerId: UUID
        let generation: UInt64
        let locale: SupportedLocale
        fileprivate let activationId: UUID
    }

    private(set) var scope: Scope?
    private(set) var state: CareOverviewViewState?
    private(set) var refreshing = false
    private(set) var readingLocal = false
    private(set) var needsLocalRead = true
    private(set) var error: CareOverviewViewState.Failure?
    var needsRevalidation: Bool {
        needsLocalRead || error == .revalidationRequired || state?.failure == .revalidationRequired
    }
    var hasError: Bool { error != nil || state?.failure != nil }

    private var localRevision: UInt64 = 0
    private var requestId: UUID?

    /// A fresh identity even for A -> B -> A, or reactivation of the same lease.
    @discardableResult
    func activate(ownerId: UUID, generation: UInt64, locale: SupportedLocale) -> Scope {
        suspend()
        let next = Scope(ownerId: ownerId, generation: generation, locale: locale, activationId: UUID())
        scope = next
        return next
    }

    func suspend() {
        scope = nil
        requestId = nil
        localRevision &+= 1
        state = nil
        refreshing = false
        readingLocal = false
        needsLocalRead = true
        error = nil
    }

    /// Call after a durable local signal, and once when activating to read the cache.
    /// Hiding the old projection immediately also suppresses its automation and dates.
    func rereadLocal(
        scope: Scope,
        read: @MainActor () async throws -> CareOverviewViewState
    ) async {
        await load(scope: scope, local: true, operation: read)
    }

    /// One bounded caller operation; no transport, retry, coalescer or background task here.
    func refresh(
        scope: Scope,
        read: @MainActor () async throws -> CareOverviewViewState
    ) async {
        await load(scope: scope, local: false, operation: read)
    }

    private func load(
        scope: Scope, local: Bool,
        operation: @MainActor () async throws -> CareOverviewViewState
    ) async {
        guard self.scope == scope, !Task.isCancelled else { return }
        // A refresh cannot bypass an unresolved local overlay.
        guard local || !needsLocalRead else { return }
        if local {
            localRevision &+= 1
            needsLocalRead = true
            state = nil
        }
        let revision = localRevision
        let request = UUID()
        requestId = request
        readingLocal = local
        refreshing = !local
        error = nil
        defer {
            if isCurrent(scope, request: request, revision: revision) {
                readingLocal = false
                refreshing = false
            }
        }
        do {
            let result = try await operation()
            guard isCurrent(scope, request: request, revision: revision) else { return }
            try Task.checkCancellation()
            guard result.ownerId == scope.ownerId,
                  result.snapshotLocale == nil || result.snapshotLocale == scope.locale.rawValue else {
                state = nil
                // A coherent owner-local read resolves the overlay fence even if its
                // cached locale needs a bounded refresh. Never display that old locale.
                needsLocalRead = result.ownerId != scope.ownerId
                error = .revalidationRequired
                return
            }
            state = result
            needsLocalRead = false
        } catch is CancellationError {
            // Keep a cancelled local read fenced until an explicit coherent reread.
        } catch {
            guard isCurrent(scope, request: request, revision: revision), !Task.isCancelled else { return }
            self.error = .transport
        }
    }

    private func isCurrent(_ scope: Scope, request: UUID, revision: UInt64) -> Bool {
        self.scope == scope && requestId == request && localRevision == revision
    }
}
