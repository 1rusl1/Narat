import Foundation

/// Pure proposals only. Durable occurrence receipts must be filtered before an OS adapter adds requests.
struct CareReminderPlan: Sendable, Equatable {
    enum Authorization: Sendable, Equatable {
        case notDetermined, authorized, denied
    }

    enum Occurrence: Codable, Sendable, Equatable {
        case routine(ruleId: UUID)
        case firstAid(controlId: UUID)
    }

    struct Candidate: Sendable, Equatable, Identifiable {
        let id: String
        let ownerId: UUID
        let plantId: UUID
        let occurrence: Occurrence
        let sourceDueYMD: String
        let absoluteFireDate: Date
        let locale: String
    }

    /// All eligible occurrences, before opt-in, authorization and the care-only capacity limit.
    let candidates: [Candidate]
    let requests: [Candidate]
    var eligibleCandidateCount: Int { candidates.count }
    /// Capacity omissions only; opting out or denying permission does not change this count.
    var omittedCount: Int { max(0, candidates.count - Self.capacity) }
    static let capacity = 32

    init(
        expectedOwnerId: UUID, state: CareOverviewViewState?, optedIn: Bool,
        authorization: Authorization, now: Date, timeZone: TimeZone, locale: String
    ) {
        guard let state, state.ownerId == expectedOwnerId,
              ["en", "pl"].contains(locale), state.snapshotLocale == locale,
              state.availability == .available, state.knownInvalidation == nil,
              state.failure == nil || state.failure == .transport,
              let generation = state.canonicalGeneration, state.snapshotGeneration == generation,
              !state.profileHourPending, let hour = state.reminderHourLocal,
              (0...23).contains(hour) else {
            candidates = []; requests = []
            return
        }
        switch state.access {
        case .free:
            guard state.verifiedAccessUntil == nil else {
                candidates = []; requests = []
                return
            }
        case .verified:
            guard let deadline = state.verifiedAccessUntil, deadline > now else {
                candidates = []; requests = []
                return
            }
        case .unknown, .expired:
            candidates = []; requests = []
            return
        }

        var proposals: [Candidate] = []
        func append(plantId: UUID, occurrence: Occurrence, due: String) {
            guard let fire = Self.resolve(sourceYMD: due, hour: hour, timeZone: timeZone),
                  fire > now, state.verifiedAccessUntil.map({ fire < $0 }) ?? true else { return }
            let id = Self.identity(ownerId: expectedOwnerId, plantId: plantId,
                                   occurrence: occurrence, sourceDueYMD: due)
            proposals.append(Candidate(
                id: id, ownerId: expectedOwnerId, plantId: plantId, occurrence: occurrence,
                sourceDueYMD: due, absoluteFireDate: fire, locale: locale
            ))
        }
        for plant in state.plants where plant.automatedActionsAllowed && plant.cardLinkAvailable {
            if let routine = plant.routine, plant.routineSource?.isVerifiedLink == true {
                append(plantId: plant.card.id, occurrence: .routine(ruleId: routine.ruleId),
                       due: routine.dueLocalDate)
            }
            for control in plant.controls where control.source.isVerifiedLink {
                append(plantId: plant.card.id, occurrence: .firstAid(controlId: control.id),
                       due: control.dueOn)
            }
        }
        let unique = Self.orderedUnique(proposals)
        candidates = unique
        requests = optedIn && authorization == .authorized ? Array(unique.prefix(Self.capacity)) : []
    }

    /// Shared exact identity format; a moved first-aid control remains the same opportunity.
    static func identity(ownerId: UUID, plantId: UUID, occurrence: Occurrence, sourceDueYMD: String) -> String {
        let prefix = "care/\(ownerId.uuidString.lowercased())/\(plantId.uuidString.lowercased())"
        switch occurrence {
        case .routine(let ruleId):
            return "\(prefix)/routine/\(ruleId.uuidString.lowercased())/\(sourceDueYMD)"
        case .firstAid(let controlId):
            return "\(prefix)/first-aid/\(controlId.uuidString.lowercased())"
        }
    }

    /// Duplicate identities, including moved controls, choose the earliest proposal deterministically.
    static func orderedUnique(_ proposals: [Candidate]) -> [Candidate] {
        let ordered = proposals.sorted {
            if $0.absoluteFireDate != $1.absoluteFireDate { return $0.absoluteFireDate < $1.absoluteFireDate }
            return $0.id < $1.id
        }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.id).inserted }
    }

    /// Gregorian source labels are never UTC-midnight instants shifted into another local day.
    /// Gaps advance to the next valid time on the same day; overlaps select the first instant.
    static func resolve(sourceYMD: String, hour: Int, timeZone: TimeZone) -> Date? {
        guard (0...23).contains(hour), sourceYMD.utf8.count == 10,
              sourceYMD.utf8.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 ? byte == 45 : (48...57).contains(byte)
              }),
              let label = SQLCalendarDay.date(from: sourceYMD) else { return nil }
        let parts = SQLCalendarDay.calendar.dateComponents([.year, .month, .day], from: label)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        // Noon supplies a search anchor, not a date conversion. Round-trip rejects skipped days.
        var noonParts = parts
        noonParts.hour = 12
        guard let noon = calendar.date(from: noonParts),
              sameDay(noon, parts: parts, calendar: calendar) else { return nil }
        let start = calendar.startOfDay(for: noon)
        var target = DateComponents()
        target.hour = hour
        target.minute = 0
        target.second = 0
        guard let fire = calendar.nextDate(
            after: start.addingTimeInterval(-1), matching: target,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward
        ), sameDay(fire, parts: parts, calendar: calendar) else { return nil }
        return fire
    }

    private static func sameDay(_ date: Date, parts: DateComponents, calendar: Calendar) -> Bool {
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == parts.year && actual.month == parts.month && actual.day == parts.day
    }
}
