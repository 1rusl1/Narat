import Foundation

/// Reading eligibility only; independently current SDK owner/locale and async fences are upstream.
enum CareReminderRouting {
    enum Decision: Sendable, Equatable {
        case hold
        case drop
        case open(plantId: UUID)
    }

    static func decide(
        _ route: CareReminderNotificationRoute, expectedOwnerId: UUID,
        locale: String, state: CareOverviewViewState?, now: Date, timeZone: TimeZone
    ) -> Decision {
        let payload = route.candidate
        guard payload.ownerId == expectedOwnerId else { return .drop }
        guard let state, state.ownerId == expectedOwnerId else { return .hold }
        // Care-data authorization is independent of OS notification permission.
        if state.failure == .authorizationDenied || state.access == .expired { return .drop }
        guard now.timeIntervalSince1970.isFinite else { return .hold }
        if let deadline = state.verifiedAccessUntil, deadline <= now { return .drop }
        guard ["en", "pl"].contains(locale), state.snapshotLocale == locale,
              state.availability == .available, state.knownInvalidation == nil,
              state.failure == nil || state.failure == .transport,
              state.access != .unknown,
              let generation = state.canonicalGeneration, state.snapshotGeneration == generation,
              !state.profileHourPending, let hour = state.reminderHourLocal,
              (0...23).contains(hour) else { return .hold }

        let current = CareReminderPlan(
            expectedOwnerId: expectedOwnerId, state: state, optedIn: false,
            authorization: .denied, now: now, timeZone: timeZone, locale: locale
        ).currentOccurrences
        // First-aid identity excludes its date. Delivery fire/attempt/language are not authority.
        guard current.contains(where: {
            $0.id == payload.id && $0.ownerId == payload.ownerId
                && $0.plantId == payload.plantId && $0.occurrence == payload.occurrence
                && $0.sourceDueYMD == payload.sourceDueYMD
        }) else { return .drop }
        return .open(plantId: payload.plantId)
    }
}
