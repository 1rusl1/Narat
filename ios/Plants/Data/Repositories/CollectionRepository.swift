import Foundation

public struct CollectionCapacity: Sendable, Equatable {
    public let ownerId: UUID
    public let plantCount: Int
    public let hasVerifiedPaidAccess: Bool

    public var collectionLimit: Int? { hasVerifiedPaidAccess ? nil : 3 }
    public var canCreate: Bool { hasVerifiedPaidAccess || plantCount < 3 }
}

public enum CollectionCapacityResult: Sendable, Equatable {
    case signInRequired
    case confirmed(CollectionCapacity)
}

struct CollectionCapacitySnapshot: Sendable {
    let plantCount: Int
    let entitlement: SyncWireEntitlementDTO?
}

/// Advisory only: the server's create guard remains authoritative.
public struct CollectionRepository: Sendable {
    private let store: LocalStore
    private let apiClient: PlantsAPIClient
    private let syncEngine: SyncEngine
    private let clock: @Sendable () -> Date

    public init(
        store: LocalStore, apiClient: PlantsAPIClient, syncEngine: SyncEngine,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.apiClient = apiClient
        self.syncEngine = syncEngine
        self.clock = clock
    }

    /// Errors mean unavailable; neither old cache nor pending commands imply capacity.
    public func preflightCapacity(
        session: NativeAuthSession, isAnonymous: Bool
    ) async throws -> CollectionCapacityResult {
        try Task.checkCancellation()
        guard !isAnonymous else { return .signInRequired }
        // Do not pass an explicit-session fallback: only an actually bound client qualifies.
        let context = try await apiClient.captureSyncContext(ownerId: session.userId)
        guard context.session == session else { throw SyncWireValidationError.invalidSession }
        _ = try await syncEngine.performFullRefresh(context: context)
        let snapshot = try await store.collectionCapacitySnapshot(
            context: context, authority: apiClient.syncAuthority
        )
        return try apiClient.syncAuthority.withValid(context) {
            let now = clock()
            func future(_ raw: String?) -> Bool {
                guard let raw, let expiry = SQLTimestamp.date(from: raw) else { return false }
                return expiry > now
            }
            let paid = snapshot.entitlement.map {
                ["active", "grace"].contains($0.state) && future($0.validUntil)
                    && ($0.offerKind == "paid" || ($0.offerKind == "trial" && future($0.trialEndAt)))
            } ?? false
            return .confirmed(CollectionCapacity(
                ownerId: context.ownerId, plantCount: snapshot.plantCount, hasVerifiedPaidAccess: paid
            ))
        }
    }
}
