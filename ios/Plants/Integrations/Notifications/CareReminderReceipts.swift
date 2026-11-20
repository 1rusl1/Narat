import Foundation

/// Pure metadata only: no persistence, pending-list inspection or claim of OS delivery.
struct CareReminderReceipts: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable { case prepared, armed, cancelledBeforeFire, spent, uncertain }
    enum Preparation: Equatable { case newlyPrepared, existing, blocked }
    enum Invalid: Error { case metadata, owner, candidate }
    /// Inputs supplied by a future adapter, never inferred from an empty pending list.
    enum RemovalProof: Sendable {
        case missing, readbackFailed
        case removedAndReadBackAbsent(confirmedAt: Date)
    }
    struct Cancellation: Codable, Sendable, Equatable {
        let attemptId: UUID
        let fireDate: Date
        let confirmedAt: Date
    }
    struct Entry: Codable, Sendable, Equatable {
        let id: String
        let ownerId: UUID
        let plantId: UUID
        let occurrence: CareReminderPlan.Occurrence
        fileprivate(set) var sourceDueYMD: String
        let originalFireDate: Date
        fileprivate(set) var currentFireDate: Date
        fileprivate(set) var attemptId: UUID
        fileprivate(set) var phase: Phase
        fileprivate(set) var cancellation: Cancellation?
    }
    let version: Int
    let ownerId: UUID
    private(set) var entries: [String: Entry]
    private(set) var blockedIdentifiers: Set<String>

    init(ownerId: UUID) {
        version = 1
        self.ownerId = ownerId
        entries = [:]
        blockedIdentifiers = []
    }

    private enum CodingKeys: String, CodingKey { case version, ownerId, entries, blockedIdentifiers }
    // An array of keyed records allows duplicate identities to be rejected during decoding.
    private struct Record: Codable { let key: String; let entry: Entry }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        ownerId = try values.decode(UUID.self, forKey: .ownerId)
        let blocked = try values.contains(.blockedIdentifiers)
            ? values.decode([String].self, forKey: .blockedIdentifiers) : []
        blockedIdentifiers = Set(blocked)
        guard blockedIdentifiers.count == blocked.count else { throw Invalid.metadata }
        entries = [:]
        for record in try values.decode([Record].self, forKey: .entries) {
            guard record.key == record.entry.id, entries[record.key] == nil else { throw Invalid.metadata }
            entries[record.key] = record.entry
        }
        try validate(expectedOwner: ownerId)
    }

    func encode(to encoder: Encoder) throws {
        try validate(expectedOwner: ownerId)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(ownerId, forKey: .ownerId)
        try values.encode(blockedIdentifiers.sorted(), forKey: .blockedIdentifiers)
        try values.encode(entries.keys.sorted().compactMap { key in
            entries[key].map { Record(key: key, entry: $0) }
        }, forKey: .entries)
    }

    func validate(expectedOwner: UUID) throws {
        guard version == 1 else { throw Invalid.metadata }
        guard ownerId == expectedOwner else { throw Invalid.owner }
        guard blockedIdentifiers.allSatisfy({ Self.canonicalOwner(of: $0) == ownerId })
        else { throw Invalid.metadata }
        for (key, entry) in entries {
            guard key == entry.id, entry.ownerId == ownerId,
                  entry.id == CareReminderPlan.identity(ownerId: ownerId, plantId: entry.plantId,
                      occurrence: entry.occurrence, sourceDueYMD: entry.sourceDueYMD),
                  SQLCalendarDay.date(from: entry.sourceDueYMD) != nil,
                  Self.finite(entry.originalFireDate), Self.finite(entry.currentFireDate),
                  entry.originalFireDate == entry.currentFireDate || entry.cancellation != nil
            else { throw Invalid.metadata }
            if let proof = entry.cancellation {
                guard Self.finite(proof.fireDate), Self.finite(proof.confirmedAt),
                      proof.confirmedAt < proof.fireDate,
                      ![.prepared, .armed].contains(entry.phase) || proof.attemptId != entry.attemptId
                else { throw Invalid.metadata }
            }
            if entry.phase == .cancelledBeforeFire {
                guard let proof = entry.cancellation, proof.attemptId == entry.attemptId,
                      proof.fireDate == entry.currentFireDate else { throw Invalid.metadata }
            }
        }
    }

    /// Replacements are checked against the committed ledger, never a caller's expected copy.
    func validateReplacement(of previous: Self) throws {
        try previous.validate(expectedOwner: ownerId)
        try validate(expectedOwner: previous.ownerId)
        guard blockedIdentifiers.isSuperset(of: previous.blockedIdentifiers) else { throw Invalid.metadata }
        for (id, new) in entries where previous.entries[id] == nil {
            guard [.prepared, .spent, .uncertain].contains(new.phase),
                  new.phase != .prepared || (new.cancellation == nil
                      && new.originalFireDate == new.currentFireDate)
            else { throw Invalid.metadata }
        }
        for (id, old) in previous.entries {
            guard let new = entries[id], new.ownerId == old.ownerId,
                  new.plantId == old.plantId, new.occurrence == old.occurrence,
                  new.originalFireDate == old.originalFireDate else { throw Invalid.metadata }
            let changedAttempt = new.attemptId != old.attemptId
                || new.currentFireDate != old.currentFireDate || new.sourceDueYMD != old.sourceDueYMD
            if changedAttempt {
                guard old.phase == .cancelledBeforeFire, new.phase == .prepared,
                      new.attemptId != old.attemptId, let proof = old.cancellation,
                      proof.attemptId == old.attemptId, proof.fireDate == old.currentFireDate,
                      new.cancellation == proof else { throw Invalid.metadata }
                continue
            }
            let allowed: [Phase]
            switch old.phase {
            case .prepared: allowed = [.prepared, .armed, .cancelledBeforeFire, .spent, .uncertain]
            case .armed: allowed = [.armed, .cancelledBeforeFire, .spent, .uncertain]
            case .cancelledBeforeFire: allowed = [.cancelledBeforeFire, .spent, .uncertain]
            case .spent: allowed = [.spent]
            case .uncertain: allowed = [.uncertain, .spent]
            }
            guard allowed.contains(new.phase) else { throw Invalid.metadata }
            if [.prepared, .armed].contains(old.phase), new.phase == .cancelledBeforeFire {
                guard let proof = new.cancellation, proof.attemptId == old.attemptId,
                      proof.fireDate == old.currentFireDate else { throw Invalid.metadata }
            } else {
                guard new.cancellation == old.cancellation else { throw Invalid.metadata }
            }
        }
    }

    mutating func prepare(_ candidate: CareReminderPlan.Candidate, now: Date) throws -> Preparation {
        guard candidate.ownerId == ownerId else { throw Invalid.owner }
        guard Self.finite(now), Self.finite(candidate.absoluteFireDate),
              SQLCalendarDay.date(from: candidate.sourceDueYMD) != nil,
              candidate.id == CareReminderPlan.identity(ownerId: ownerId, plantId: candidate.plantId,
                  occurrence: candidate.occurrence, sourceDueYMD: candidate.sourceDueYMD)
        else { throw Invalid.candidate }
        if blockedIdentifiers.contains(candidate.id) { return .blocked }
        if let old = entries[candidate.id] {
            try observe(id: old.id, now: now)
            guard let current = entries[old.id] else { throw Invalid.metadata }
            switch current.phase {
            case .spent, .uncertain: return .blocked
            case .prepared, .armed:
                return current.currentFireDate == candidate.absoluteFireDate
                    && current.sourceDueYMD == candidate.sourceDueYMD ? .existing : .blocked
            case .cancelledBeforeFire: break
            }
        }
        guard candidate.absoluteFireDate > now else { throw Invalid.candidate }
        let old = entries[candidate.id]
        entries[candidate.id] = Entry(id: candidate.id, ownerId: ownerId, plantId: candidate.plantId,
            occurrence: candidate.occurrence, sourceDueYMD: candidate.sourceDueYMD,
            originalFireDate: old?.originalFireDate ?? candidate.absoluteFireDate,
            currentFireDate: candidate.absoluteFireDate, attemptId: UUID(), phase: .prepared,
            cancellation: old?.cancellation)
        return .newlyPrepared
    }

    /// ACK is bound to this prepare attempt, including after cancellation and same-date reprepare.
    @discardableResult
    mutating func acknowledge(id: String, attemptId: UUID, now: Date) throws -> Bool {
        try observe(id: id, now: now)
        guard var entry = entries[id], entry.phase == .prepared,
              entry.attemptId == attemptId else { return false }
        entry.phase = .armed
        entries[id] = entry
        return true
    }

    /// Time passing consumes even a prepared opportunity; absence/dismissal never resets it.
    mutating func observe(id: String, now: Date, delivered: Bool = false, unknown: Bool = false) throws {
        guard Self.finite(now), var entry = entries[id] else { throw Invalid.metadata }
        if delivered || ([.prepared, .armed].contains(entry.phase) && now >= entry.currentFireDate) {
            entry.phase = .spent
        } else if unknown && entry.phase != .spent {
            entry.phase = .uncertain
        }
        entries[id] = entry
    }

    @discardableResult
    mutating func cancel(
        id: String, attemptId: UUID, proof: RemovalProof, now: Date
    ) throws -> Bool {
        try observe(id: id, now: now)
        guard var entry = entries[id], [.prepared, .armed].contains(entry.phase),
              entry.attemptId == attemptId else { return false }
        switch proof {
        case .removedAndReadBackAbsent(let confirmedAt):
            guard Self.finite(confirmedAt), confirmedAt <= now else { throw Invalid.metadata }
            guard confirmedAt < entry.currentFireDate else { return false }
            entry.cancellation = Cancellation(attemptId: attemptId, fireDate: entry.currentFireDate,
                                                confirmedAt: confirmedAt)
            entry.phase = .cancelledBeforeFire
            entries[id] = entry
            return true
        case .missing, .readbackFailed:
            entry.phase = .uncertain
            entries[id] = entry
            return false
        }
    }

    /// Conservative OS-history import only. This can NEVER create PREPARED or authorize an add.
    /// In particular, a verified past occurrence may block a later first-aid date proposal.
    mutating func recordUnknown(_ route: CareReminderNotificationRoute, delivered: Bool) throws {
        let c = route.candidate
        guard c.ownerId == ownerId else { throw Invalid.owner }
        guard c.id == CareReminderPlan.identity(ownerId: ownerId, plantId: c.plantId,
                  occurrence: c.occurrence, sourceDueYMD: c.sourceDueYMD),
              SQLCalendarDay.date(from: c.sourceDueYMD) != nil, Self.finite(c.absoluteFireDate)
        else { throw Invalid.candidate }
        guard entries[c.id] == nil else { return }
        entries[c.id] = Entry(id: c.id, ownerId: ownerId, plantId: c.plantId,
            occurrence: c.occurrence, sourceDueYMD: c.sourceDueYMD,
            originalFireDate: c.absoluteFireDate, currentFireDate: c.absoluteFireDate,
            attemptId: route.attemptId, phase: delivered ? .spent : .uncertain, cancellation: nil)
    }

    /// Canonical raw identity only; this never manufactures scheduling metadata.
    static func canonicalOwner(of id: String) -> UUID? {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5 || parts.count == 6, parts[0] == "care",
              let owner = UUID(uuidString: parts[1]), owner.uuidString.lowercased() == parts[1],
              let plant = UUID(uuidString: parts[2]), plant.uuidString.lowercased() == parts[2],
              let occurrence = UUID(uuidString: parts[4]), occurrence.uuidString.lowercased() == parts[4]
        else { return nil }
        if parts[3] == "first-aid", parts.count == 5 { return owner }
        if parts[3] == "routine", parts.count == 6, SQLCalendarDay.date(from: parts[5]) != nil {
            return owner
        }
        return nil
    }

    mutating func blockIdentifier(_ id: String) throws {
        guard Self.canonicalOwner(of: id) == ownerId else { throw Invalid.metadata }
        blockedIdentifiers.insert(id)
    }

    private static func finite(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }
}
