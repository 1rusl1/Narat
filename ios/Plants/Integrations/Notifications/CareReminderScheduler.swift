import Foundation

/// One bounded pass only. The caller MUST serialize passes across all instances for an owner.
/// No Root integration, latest-intent worker, logout/hold policy or concurrent-call safety yet.
@MainActor
enum CareReminderScheduler {
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

        func normalize() async throws {
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
                    guard ledger.entries[id] != nil else { throw Failure.inventory }
                }
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
            let blockers = entries.filter { e in
                e.phase == .uncertain || e.phase == .prepared
                    || (e.phase == .armed && !pending(e.id).contains { exact($0, e) })
            }.count
            return Result(confirmedPendingCount: confirmed, omittedCount: omitted,
                unconfirmedBlockers: max(blockers, failed ? 1 : 0), failed: failed, deferred: deferred)
        }

        func run() async -> Result {
            do {
                token = try await checked {
                    try await input.store.beginCareReminderReceipts(context: input.lease, authority: input.authority)
                }
                let authorization = try await checked { try await notifications.authorization() }
                try await readInventory()
                // Presentation unknown is NOT logout or permission to cancel.
                guard let state = input.state else { return result(failed: false, deferred: true) }
                guard state.ownerId == input.lease.ownerId else { throw Failure.scope }
                try await normalize()
                let plan = CareReminderPlan(expectedOwnerId: input.lease.ownerId, state: state,
                    optedIn: input.optedIn, authorization: authorization, now: input.clock(),
                    timeZone: input.timeZone, locale: input.locale)
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
                if enabled && input.allowNewRequests {
                    let fresh = plan.candidates.filter { c in
                        guard let e = token?.receipts.entries[c.id] else { return true }
                        return e.phase == .cancelledBeforeFire
                    }
                    // Filter ALL candidates against receipts before applying either capacity.
                    let carePending = inventory.pending.filter {
                        $0.rawIdentifier.hasPrefix(CareReminderNotificationFactory.prefix)
                    }.count
                    let slots = max(0, min(CareReminderPlan.capacity - carePending,
                        64 - inventory.otherPendingCount - carePending))
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
                return result(failed: true)
            }
        }
    }
}
