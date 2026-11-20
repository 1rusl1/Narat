import Foundation
import Combine

/// One worker per adapter lifecycle. Static reconcile remains a caller-serialized bounded pass.
@MainActor
final class CareReminderScheduler: ObservableObject {
    struct Input {
        let lease: SyncSessionLease
        let store: LocalStore
        let authority: SyncSessionAuthority
        let isCurrent: () -> Bool
        let state: CareOverviewViewState?
        let optedIn: Bool
        let allowNewRequests: Bool
        let locale: String
        let timeZone: TimeZone
        let clock: () -> Date

        func validate() throws {
            try Task.checkCancellation()
            guard isCurrent(), clock().timeIntervalSince1970.isFinite else { throw Failure.scope }
            try authority.withPermanentBoundValid(lease) {}
        }
    }

    struct Result: Equatable {
        let confirmedPendingCount: Int
        let omittedCount: Int
        let unconfirmedBlockers: Int
        let failed: Bool
        let deferred: Bool
    }

    @Published private(set) var result: Result?
    @Published private(set) var authorization: CareReminderPlan.Authorization?
    @Published private(set) var requestingPermission = false

    private let notifications: any CareReminderNotifications
    private var latest: Input?
    private var held = false
    private var revision: UInt64 = 0
    // Sticky across logout -> B -> A and opt-out -> opt-in coalescing.
    private var cleanupRequired = false
    private var permissionIntent = false
    private var worker: Task<Void, Never>?

    init(notifications: any CareReminderNotifications) {
        self.notifications = notifications
        // Unresolved startup deliberately does not inspect or clean the OS inventory.
    }

    func update(_ input: Input) {
        if let previous = latest,
           previous.lease.ownerId != input.lease.ownerId || previous.authority !== input.authority {
            cleanupRequired = true
        }
        if !input.optedIn { cleanupRequired = true }
        latest = input
        held = false
        submit()
    }

    /// Presentation suspension retains known state and already-authorized future requests.
    /// Local mutations can still supply update(input with allowNewRequests: false).
    func hold() {
        held = true
        submit()
    }

    /// Actual logout only; no old owner ledger is opened, even if its lease is dead.
    func cancelAll() {
        cleanupRequired = true
        latest = nil
        held = true
        submit()
    }

    /// Explicit UI action only. An ineligible action never becomes a future prompt intent.
    func requestPermission() {
        guard !held, let input = latest, (try? input.validate()) != nil,
              input.optedIn, input.allowNewRequests,
              !Self.plan(input).candidates.isEmpty else { return }
        submit(permission: true)
    }

    func retry() { submit() }

    func waitUntilIdle() async { await worker?.value }

    private static func plan(_ input: Input) -> CareReminderPlan {
        CareReminderPlan(expectedOwnerId: input.lease.ownerId, state: input.state,
            optedIn: input.optedIn, authorization: .authorized, now: input.clock(),
            timeZone: input.timeZone, locale: input.locale)
    }

    private func submit(permission: Bool = false) {
        revision &+= 1
        permissionIntent = permission
        result = nil
        authorization = nil
        requestingPermission = false
        if worker == nil {
            // Never cancel this task: an OS add must finish before the next cleanup/add.
            worker = Task { await self.drain() }
        }
    }

    private func check(_ expected: UInt64) throws {
        guard revision == expected else { throw Failure.scope }
        try latest?.validate()
    }

    private func checked<T: Sendable>(
        _ expected: UInt64, _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        try check(expected)
        do {
            let value = try await operation()
            try check(expected)
            return value
        } catch {
            try check(expected)
            throw error
        }
    }

    private func cleanup(_ expected: UInt64) async throws {
        if let input = latest {
            // Reuse the accepted pass to journal conservative blockers and cancellation proof
            // before cleanup. Never open the previous owner's ledger.
            let cancellation = Input(lease: input.lease, store: input.store, authority: input.authority,
                isCurrent: { self.revision == expected && input.isCurrent() }, state: input.state,
                optedIn: false, allowNewRequests: false, locale: input.locale,
                timeZone: input.timeZone, clock: input.clock)
            let value = await Pass(cancellation, notifications).run(privacyCleanup: true)
            try check(expected)
            guard !value.failed else { throw Failure.inventory }
            cleanupRequired = false
            return
        }
        let inventory = try await checked(expected) { try await notifications.inventory() }
        let pending = CareReminderNotificationFactory.ownIdentifiers(inventory.pending.map { $0.rawIdentifier })
        let delivered = CareReminderNotificationFactory.ownIdentifiers(inventory.delivered.map { $0.rawIdentifier })
        if !pending.isEmpty {
            try await checked(expected) { try await notifications.removePending(pending) }
        }
        if !delivered.isEmpty {
            try await checked(expected) { try await notifications.removeDelivered(delivered) }
        }
        let readback = try await checked(expected) { try await notifications.inventory() }
        guard readback.otherPendingCount >= 0,
              !(readback.pending + readback.delivered).contains(where: {
                  $0.rawIdentifier.hasPrefix(CareReminderNotificationFactory.prefix)
              }) else { throw Failure.inventory }
        cleanupRequired = false
    }

    private func drain() async {
        var handled: UInt64?
        while handled != revision {
            let expected = revision
            handled = expected
            let input = latest
            let shouldPrompt = permissionIntent
            permissionIntent = false
            do {
                try check(expected)
                if cleanupRequired { try await cleanup(expected) }
                guard let input else { continue }
                let auth = try await checked(expected) { try await notifications.authorization() }
                authorization = auth
                if shouldPrompt && !held && input.optedIn && input.allowNewRequests
                    && !Self.plan(input).candidates.isEmpty && auth == .notDetermined {
                    requestingPermission = true
                    try await checked(expected) { try await notifications.requestAuthorization() }
                    requestingPermission = false
                    authorization = try await checked(expected) { try await notifications.authorization() }
                }
                try check(expected)
                let bound = Input(lease: input.lease, store: input.store, authority: input.authority,
                    isCurrent: { self.revision == expected && input.isCurrent() }, state: input.state,
                    optedIn: input.optedIn, allowNewRequests: input.allowNewRequests && !held,
                    locale: input.locale, timeZone: input.timeZone, clock: input.clock)
                let value = await Self.reconcile(bound, notifications: notifications)
                try check(expected)
                result = value
            } catch {
                if revision == expected {
                    requestingPermission = false
                    if (try? check(expected)) != nil {
                        result = Result(confirmedPendingCount: 0, omittedCount: 0,
                            unconfirmedBlockers: 1, failed: true, deferred: false)
                    } else {
                        result = nil
                        authorization = nil
                    }
                }
            }
        }
        worker = nil
    }

    private enum Failure: Error { case scope, inventory }

    static func reconcile(_ input: Input, notifications: any CareReminderNotifications) async -> Result {
        await Pass(input, notifications).run()
    }

    @MainActor
    private final class Pass {
        let input: Input
        let notifications: any CareReminderNotifications
        var token: CareReminderReceiptSnapshot?
        var inventory = CareReminderNotificationInventory(pending: [], delivered: [], otherPendingCount: 0)
        var omitted = 0
        var currentIDs: Set<String>?
        var untrustedInventory = false

        init(_ input: Input, _ notifications: any CareReminderNotifications) {
            self.input = input
            self.notifications = notifications
        }

        // Validate the ORIGINAL binding and caller epoch on both success and error paths.
        func checked<T: Sendable>(_ operation: @MainActor () async throws -> T) async throws -> T {
            try input.validate()
            do {
                let value = try await operation()
                try input.validate()
                return value
            } catch {
                try input.validate()
                throw error
            }
        }

        func save(_ receipts: CareReminderReceipts) async throws {
            guard let original = token else { throw Failure.scope }
            token = try await checked {
                try await input.store.commitCareReminderReceipts(receipts, replacing: original,
                                                                 authority: input.authority)
            }
        }

        func route(_ item: CareReminderNotificationInventory.Item) -> CareReminderNotificationRoute? {
            guard let r = item.route else { return nil }
            let c = r.candidate
            guard item.rawIdentifier == CareReminderNotificationFactory.prefix + c.id,
                  c.id == CareReminderPlan.identity(ownerId: c.ownerId, plantId: c.plantId,
                      occurrence: c.occurrence, sourceDueYMD: c.sourceDueYMD),
                  SQLCalendarDay.date(from: c.sourceDueYMD) != nil,
                  c.absoluteFireDate.timeIntervalSince1970.isFinite,
                  ["en", "pl"].contains(c.locale) else { return nil }
            return r
        }

        func sameOccurrence(_ r: CareReminderNotificationRoute, _ e: CareReminderReceipts.Entry) -> Bool {
            r.candidate.id == e.id && r.candidate.ownerId == e.ownerId
                && r.candidate.plantId == e.plantId && r.candidate.occurrence == e.occurrence
        }

        func exact(_ item: CareReminderNotificationInventory.Item, _ e: CareReminderReceipts.Entry) -> Bool {
            guard let r = route(item) else { return false }
            return sameOccurrence(r, e) && r.attemptId == e.attemptId
                && r.candidate.absoluteFireDate == e.currentFireDate
                && r.candidate.sourceDueYMD == e.sourceDueYMD
        }

        func pending(_ id: String) -> [CareReminderNotificationInventory.Item] {
            inventory.pending.filter { $0.rawIdentifier == CareReminderNotificationFactory.prefix + id }
        }

        func delivered(_ id: String) -> [CareReminderNotificationInventory.Item] {
            inventory.delivered.filter { $0.rawIdentifier == CareReminderNotificationFactory.prefix + id }
        }

        func deliveryProof(_ e: CareReminderReceipts.Entry) -> Bool {
            delivered(e.id).contains { item in
                route(item).map { sameOccurrence($0, e) } ?? false
            }
        }

        func normalize(_ plan: CareReminderPlan, observeExisting: Bool = true) async throws {
            guard var ledger = token?.receipts else { throw Failure.scope }
            // Unknown verified identities become terminal BEFORE cleanup; never import add authority.
            for item in inventory.pending + inventory.delivered
                where item.rawIdentifier.hasPrefix(CareReminderNotificationFactory.prefix) {
                if let r = route(item) {
                    if r.candidate.ownerId == input.lease.ownerId && ledger.entries[r.candidate.id] == nil {
                        try ledger.recordUnknown(r, delivered: inventory.delivered.contains(item))
                    }
                } else {
                    let id = String(item.rawIdentifier.dropFirst(CareReminderNotificationFactory.prefix.count))
                    if ledger.entries[id] == nil {
                        untrustedInventory = true
                        if let candidate = plan.currentOccurrences.first(where: { $0.id == id }) {
                            // Metadata grants no add authority. Persist a conservative identity blocker
                            // BEFORE deleting the untrusted raw request (including skipped local days).
                            try ledger.recordUnknown(.init(candidate: candidate, attemptId: UUID()), delivered: false)
                        } else if CareReminderReceipts.canonicalOwner(of: id) == input.lease.ownerId {
                            // Eligibility may temporarily hide a canonical occurrence. Retain its
                            // identity without inventing due/fire metadata or future add authority.
                            try ledger.blockIdentifier(id)
                        }
                    }
                }
            }
            // Without a projection, preserve existing phases; only persist unknown blockers.
            if !observeExisting {
                try await save(ledger)
                return
            }
            for id in ledger.entries.keys.sorted() {
                guard let e = ledger.entries[id] else { continue }
                let items = pending(id)
                let matches = items.count == 1 && exact(items[0], e)
                let proof = deliveryProof(e)
                let cancelledConflict = e.phase == .cancelledBeforeFire
                    && (!items.isEmpty || !delivered(id).isEmpty)
                let activeConflict = [.prepared, .armed].contains(e.phase)
                    && (!matches || (!delivered(id).isEmpty && !proof))
                try ledger.observe(id: id, now: input.clock(), delivered: proof,
                    unknown: cancelledConflict || activeConflict)
                if matches && !proof {
                    _ = try ledger.acknowledge(id: id, attemptId: e.attemptId, now: input.clock())
                }
            }
            try await save(ledger)
        }

        func readInventory() async throws {
            inventory = try await checked { try await notifications.inventory() }
            guard inventory.otherPendingCount >= 0 else { throw Failure.inventory }
        }

        func remove(_ raw: String, entry: CareReminderReceipts.Entry?) async throws {
            let hadPending = inventory.pending.contains { $0.rawIdentifier == raw }
            if hadPending {
                do {
                    try await checked { try await notifications.removePending([raw]) }
                    try await readInventory()
                } catch {
                    // An unknown removal outcome is not a cancellation proof.
                    try input.validate()
                    if let entry, var ledger = token?.receipts,
                       [.prepared, .armed].contains(entry.phase) {
                        try ledger.observe(id: entry.id, now: input.clock(), unknown: true)
                        try await save(ledger)
                    }
                    throw error
                }
                if let entry, var ledger = token?.receipts,
                   [.prepared, .armed].contains(entry.phase) {
                    if deliveryProof(entry) {
                        try ledger.observe(id: entry.id, now: input.clock(), delivered: true)
                    } else {
                        let absent = !inventory.pending.contains { $0.rawIdentifier == raw }
                            && !inventory.delivered.contains { $0.rawIdentifier == raw }
                        _ = try ledger.cancel(id: entry.id, attemptId: entry.attemptId,
                            proof: absent ? .removedAndReadBackAbsent(confirmedAt: input.clock()) : .readbackFailed,
                            now: input.clock())
                    }
                    try await save(ledger)
                }
                guard !inventory.pending.contains(where: { $0.rawIdentifier == raw }) else {
                    throw Failure.inventory
                }
            }
            if inventory.delivered.contains(where: { $0.rawIdentifier == raw }) {
                try await checked { try await notifications.removeDelivered([raw]) }
                try await readInventory()
                guard !inventory.delivered.contains(where: { $0.rawIdentifier == raw }) else {
                    throw Failure.inventory
                }
            }
        }

        func result(failed: Bool, deferred: Bool = false) -> Result {
            let entries = token?.receipts.entries.values.map { $0 } ?? []
            let confirmed = entries.filter { e in
                let items = pending(e.id)
                return e.phase == .armed && e.currentFireDate > input.clock()
                    && items.count == 1 && exact(items[0], e)
            }.count
            let blockers = Set(entries.filter { e in
                (currentIDs?.contains(e.id) ?? true) && (e.phase == .uncertain || e.phase == .prepared
                    || (e.phase == .armed && !pending(e.id).contains { exact($0, e) }))
            }.map { $0.id }).union((token?.receipts.blockedIdentifiers ?? []).filter {
                currentIDs?.contains($0) == true
            }).count
            return Result(confirmedPendingCount: confirmed, omittedCount: omitted,
                unconfirmedBlockers: max(blockers, failed ? 1 : 0), failed: failed, deferred: deferred)
        }

        // OS routes alone never prove existing receipts. On metadata failure, retain unknown
        // own canonical requests until a terminal entry or identity blocker actually commits.
        func privacyFallback() async throws {
            try await readInventory()
            let raws = Set((inventory.pending + inventory.delivered).map { $0.rawIdentifier })
            for raw in raws.sorted() where raw.hasPrefix(CareReminderNotificationFactory.prefix) {
                let id = String(raw.dropFirst(CareReminderNotificationFactory.prefix.count))
                if CareReminderReceipts.canonicalOwner(of: id) == input.lease.ownerId,
                   token?.receipts.entries[id] == nil,
                   token?.receipts.blockedIdentifiers.contains(id) != true { continue }
                // Raw OS absence grants no cancellation proof or scheduling authority.
                try await remove(raw, entry: nil)
            }
        }

        func run(privacyCleanup: Bool = false) async -> Result {
            do {
                try await readInventory()
                // A cold known owner may inherit another owner's OS remnants. Only strict raw
                // identities establish foreign ownership; never consult a foreign ledger/payload.
                let foreignRaw = Set((inventory.pending + inventory.delivered).compactMap { item -> String? in
                    let raw = item.rawIdentifier
                    guard raw.hasPrefix(CareReminderNotificationFactory.prefix),
                          let owner = CareReminderReceipts.canonicalOwner(of:
                            String(raw.dropFirst(CareReminderNotificationFactory.prefix.count))),
                          owner != input.lease.ownerId else { return nil }
                    return raw
                })
                for raw in foreignRaw.sorted() { try await remove(raw, entry: nil) }
                token = try await checked {
                    try await input.store.beginCareReminderReceipts(context: input.lease, authority: input.authority)
                }
                if privacyCleanup {
                    if let state = input.state, state.ownerId != input.lease.ownerId { throw Failure.scope }
                    try await normalize(CareReminderScheduler.plan(input), observeExisting: input.state != nil)
                    let raws = Set((inventory.pending + inventory.delivered).map { $0.rawIdentifier })
                    for raw in raws.sorted() where raw.hasPrefix(CareReminderNotificationFactory.prefix) {
                        let id = String(raw.dropFirst(CareReminderNotificationFactory.prefix.count))
                        try await remove(raw, entry: input.state == nil ? nil : token?.receipts.entries[id])
                    }
                    return result(failed: untrustedInventory)
                }
                let authorization = try await checked { try await notifications.authorization() }
                try await readInventory()
                // Presentation unknown is NOT logout or permission to cancel same-owner requests.
                guard let state = input.state else { return result(failed: false, deferred: true) }
                guard state.ownerId == input.lease.ownerId else { throw Failure.scope }
                let plan = CareReminderPlan(expectedOwnerId: input.lease.ownerId, state: state,
                    optedIn: input.optedIn, authorization: authorization, now: input.clock(),
                    timeZone: input.timeZone, locale: input.locale)
                currentIDs = plan.currentOccurrenceIDs
                try await normalize(plan)
                let enabled = input.optedIn && authorization == .authorized
                let desired = Dictionary(grouping: plan.candidates, by: { $0.id })
                // All removals remain within the care prefix, including foreign-owner remnants.
                let rawIDs = Set((inventory.pending + inventory.delivered).map { $0.rawIdentifier })
                for raw in rawIDs.sorted() where raw.hasPrefix(CareReminderNotificationFactory.prefix) {
                    let id = String(raw.dropFirst(CareReminderNotificationFactory.prefix.count))
                    let entry = token?.receipts.entries[id]
                    let keep = entry.map { e in
                        enabled && [.prepared, .armed].contains(e.phase)
                            && desired[id]?.contains { c in
                                c.absoluteFireDate == e.currentFireDate && c.sourceDueYMD == e.sourceDueYMD
                            } == true
                    } ?? false
                    if !keep { try await remove(raw, entry: entry) }
                }
                // Malformed inventory is cleaned, but this pass never converts it to add authority.
                if untrustedInventory { throw Failure.inventory }
                if enabled && input.allowNewRequests {
                    let fresh = plan.candidates.filter { c in
                        guard token?.receipts.blockedIdentifiers.contains(c.id) != true else { return false }
                        guard let e = token?.receipts.entries[c.id] else { return true }
                        return e.phase == .cancelledBeforeFire
                    }
                    // Filter ALL candidates against receipts before applying either capacity.
                    let carePending = inventory.pending.filter {
                        $0.rawIdentifier.hasPrefix(CareReminderNotificationFactory.prefix)
                    }.count
                    let slots = max(0, min(CareReminderPlan.capacity - carePending,
                        // Conservative TOTAL budget, reserving space for trial/other requests.
                        32 - min(32, inventory.otherPendingCount) - carePending))
                    omitted = max(0, fresh.count - slots)
                    for candidate in fresh.prefix(slots) {
                        try input.validate()
                        let now = input.clock()
                        guard candidate.absoluteFireDate > now,
                              state.verifiedAccessUntil.map({ now < $0 && candidate.absoluteFireDate < $0 }) ?? true
                        else { continue }
                        guard var ledger = token?.receipts else { throw Failure.scope }
                        guard try ledger.prepare(candidate, now: now) == .newlyPrepared,
                              let entry = ledger.entries[candidate.id] else { throw Failure.inventory }
                        try await save(ledger)
                        try input.validate()
                        let addNow = input.clock()
                        guard candidate.absoluteFireDate > addNow,
                              state.verifiedAccessUntil.map({ addNow < $0 && candidate.absoluteFireDate < $0 }) ?? true
                        else { throw Failure.scope }
                        // An error here intentionally leaves durable PREPARED for inventory recovery.
                        try await checked {
                            try await notifications.add(.init(candidate: candidate, attemptId: entry.attemptId), now: addNow)
                        }
                        guard var ack = token?.receipts else { throw Failure.scope }
                        _ = try ack.acknowledge(id: candidate.id, attemptId: entry.attemptId, now: input.clock())
                        try await save(ack)
                    }
                }
                // Confirm pending from adapter evidence, never infer delivery from add/save.
                try await readInventory()
                return result(failed: false)
            } catch {
                if privacyCleanup {
                    // Keep failure visible and the worker latch set after best-effort cleanup.
                    // checked() enforces the original lease/revision on every fallback await.
                    do { try await privacyFallback() } catch {}
                }
                return result(failed: true)
            }
        }
    }
}
