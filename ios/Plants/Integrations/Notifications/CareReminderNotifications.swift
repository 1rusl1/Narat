import Foundation
import UserNotifications

struct CareReminderNotificationProposal: Sendable, Equatable {
    let candidate: CareReminderPlan.Candidate
    /// Supplied by the caller after durable PREPARED; freshness is a ledger responsibility.
    let attemptId: UUID
}

struct CareReminderNotificationRoute: Sendable, Equatable {
    let candidate: CareReminderPlan.Candidate
    let attemptId: UUID
    // Routing data only: never authenticates an SDK owner or authorizes scheduling.
}

struct CareReminderNotificationInventory: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        let rawIdentifier: String
        let route: CareReminderNotificationRoute?
        let deliveredAt: Date?
    }
    let pending: [Item]
    let delivered: [Item]
    let otherPendingCount: Int
}

@MainActor
protocol CareReminderNotifications {
    func authorization() async throws -> CareReminderPlan.Authorization
    func requestAuthorization() async throws
    func inventory() async throws -> CareReminderNotificationInventory
    func add(_ proposal: CareReminderNotificationProposal, now: Date) async throws
    func removePending(_ identifiers: [String]) async throws
    func removeDelivered(_ identifiers: [String]) async throws
}

/// No permission, persistence, eligibility or OS delivery side effects.
enum CareReminderNotificationFactory {
    static let prefix = "narat.care-reminder.v1."
    private static let metadataPrefix = "narat.care."
    enum Invalid: Error { case proposal }

    static func ownIdentifiers(_ identifiers: [String]) -> [String] {
        identifiers.filter { $0.hasPrefix(prefix) }
    }

    private static func components(for date: Date) -> DateComponents? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        guard let year = parts.year, (1...9999).contains(year),
              calendar.date(from: parts) == date else { return nil }
        return parts
    }

    static func request(_ proposal: CareReminderNotificationProposal, now: Date) throws -> UNNotificationRequest {
        let c = proposal.candidate
        guard now.timeIntervalSince1970.isFinite, c.absoluteFireDate > now,
              let parts = components(for: c.absoluteFireDate) else { throw Invalid.proposal }
        let kind: String
        let subject: UUID
        switch c.occurrence {
        case .routine(let rule): kind = "routine"; subject = rule
        case .firstAid(let control): kind = "first-aid"; subject = control
        }
        let fields = [
            "version": "1", "owner": c.ownerId.uuidString.lowercased(),
            "plant": c.plantId.uuidString.lowercased(), "occurrence": c.id,
            "kind": kind, (kind == "routine" ? "rule" : "control"): subject.uuidString.lowercased(),
            "sourceYMD": c.sourceDueYMD, "attemptId": proposal.attemptId.uuidString.lowercased(),
            "absoluteFire": String(c.absoluteFireDate.timeIntervalSince1970), "locale": c.locale
        ]
        let content = UNMutableNotificationContent()
        content.userInfo = Dictionary(uniqueKeysWithValues: fields.map { (metadataPrefix + $0.key, $0.value) })
        let identifier = prefix + c.id
        guard parse(identifier: identifier, userInfo: content.userInfo) != nil else { throw Invalid.proposal }
        content.title = c.locale == "pl" ? "Pielęgnacja roślin" : "Plant care"
        content.body = c.locale == "pl"
            ? "Sprawdź zadania pielęgnacji w Narat." : "Check your care tasks in Narat."
        content.sound = .default
        return UNNotificationRequest(identifier: identifier, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }

    /// Also accepts post-fire payloads. Current shared occurrence validation belongs to the caller.
    static func parse(identifier: String, userInfo: [AnyHashable: Any]) -> CareReminderNotificationRoute? {
        guard identifier.hasPrefix(prefix), let fields = userInfo as? [String: String],
              fields[metadataPrefix + "version"] == "1" else { return nil }
        func field(_ key: String) -> String? { fields[metadataPrefix + key] }
        func uuid(_ key: String) -> UUID? {
            guard let raw = field(key), let id = UUID(uuidString: raw),
                  id.uuidString.lowercased() == raw else { return nil }
            return id
        }
        guard let kind = field("kind"), ["routine", "first-aid"].contains(kind) else { return nil }
        let subjectKey = kind == "routine" ? "rule" : "control"
        let keys = ["version", "owner", "plant", "occurrence", "kind", subjectKey,
                    "sourceYMD", "attemptId", "absoluteFire", "locale"]
        guard Set(fields.keys) == Set(keys.map { metadataPrefix + $0 }),
              let owner = uuid("owner"), let plant = uuid("plant"),
              let subject = uuid(subjectKey), let attempt = uuid("attemptId"),
              let due = field("sourceYMD"), SQLCalendarDay.date(from: due) != nil,
              let locale = field("locale"), ["en", "pl"].contains(locale),
              let rawFire = field("absoluteFire"), let seconds = Double(rawFire),
              seconds.isFinite, String(seconds) == rawFire else { return nil }
        let fire = Date(timeIntervalSince1970: seconds)
        guard components(for: fire) != nil else { return nil }
        let occurrence: CareReminderPlan.Occurrence = kind == "routine"
            ? .routine(ruleId: subject) : .firstAid(controlId: subject)
        let domainID = CareReminderPlan.identity(ownerId: owner, plantId: plant,
            occurrence: occurrence, sourceDueYMD: due)
        guard field("occurrence") == domainID, identifier == prefix + domainID else { return nil }
        return CareReminderNotificationRoute(candidate: .init(id: domainID, ownerId: owner,
            plantId: plant, occurrence: occurrence, sourceDueYMD: due,
            absoluteFireDate: fire, locale: locale), attemptId: attempt)
    }

    /// Framework objects are consumed locally; only Sendable values leave the adapter.
    static func inventory(pending: [UNNotificationRequest],
                          delivered: [(request: UNNotificationRequest, deliveredAt: Date)])
        -> CareReminderNotificationInventory {
        let ownPending = pending.filter { $0.identifier.hasPrefix(prefix) }
        let pendingItems = ownPending.map { request in
            let route = parse(identifier: request.identifier, userInfo: request.content.userInfo)
            if let parsed = route {
                guard let trigger = request.trigger as? UNCalendarNotificationTrigger,
                      !trigger.repeats,
                      trigger.dateComponents == components(for: parsed.candidate.absoluteFireDate) else {
                    return CareReminderNotificationInventory.Item(rawIdentifier: request.identifier,
                        route: nil, deliveredAt: nil)
                }
            }
            return CareReminderNotificationInventory.Item(rawIdentifier: request.identifier,
                route: route, deliveredAt: nil)
        }
        let deliveredItems = delivered.filter { $0.request.identifier.hasPrefix(prefix) }.map { pair in
            CareReminderNotificationInventory.Item(rawIdentifier: pair.request.identifier,
                route: parse(identifier: pair.request.identifier, userInfo: pair.request.content.userInfo),
                deliveredAt: pair.deliveredAt)
        }
        return CareReminderNotificationInventory(pending: pendingItems, delivered: deliveredItems,
            otherPendingCount: pending.count - ownPending.count)
    }
}

@MainActor
struct SystemCareReminderNotifications: CareReminderNotifications {
    private var center: UNUserNotificationCenter { .current() }

    func authorization() async throws -> CareReminderPlan.Authorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional, .ephemeral: .authorized
        default: .denied
        }
    }

    func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func inventory() async throws -> CareReminderNotificationInventory {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        return CareReminderNotificationFactory.inventory(pending: pending,
            delivered: delivered.map { (request: $0.request, deliveredAt: $0.date) })
    }

    func add(_ proposal: CareReminderNotificationProposal, now: Date) async throws {
        let request = try CareReminderNotificationFactory.request(proposal, now: now)
        try await center.add(request)
    }

    func removePending(_ identifiers: [String]) async throws {
        center.removePendingNotificationRequests(
            withIdentifiers: CareReminderNotificationFactory.ownIdentifiers(identifiers))
    }

    func removeDelivered(_ identifiers: [String]) async throws {
        center.removeDeliveredNotifications(
            withIdentifiers: CareReminderNotificationFactory.ownIdentifiers(identifiers))
    }
}
