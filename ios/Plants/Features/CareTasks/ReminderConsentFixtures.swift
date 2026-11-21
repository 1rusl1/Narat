#if DEBUG
import Foundation

enum ReminderConsentFixtureMode: String, Codable, CaseIterable {
    case eligible, oneReadLag = "one-readlag", twoReadLag = "two-readlag"
    case denied, noSchedule = "noSchedule", failure, readiness
}

enum ReminderConsentLaunch: Equatable {
    struct Configuration: Equatable {
        let namespace: UUID
        let mode: ReminderConsentFixtureMode
        fileprivate init(namespace: UUID, mode: ReminderConsentFixtureMode) {
            self.namespace = namespace; self.mode = mode
        }
    }
    case ordinary, invalid, fixture(Configuration)

    static func parse(_ arguments: [String]) -> Self {
        let flags = arguments.filter { $0.hasPrefix("--care-reminder") }
        guard !flags.isEmpty else { return .ordinary }
        guard flags.count == 2,
              Set(flags) == ["--care-reminder-fixture", "--care-reminder-namespace"],
              !arguments.contains(where: {
                  $0.hasPrefix("--catalogue-") || $0.hasPrefix("--today-")
                      || $0.hasPrefix("--narat-staging")
              }) else { return .invalid }
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1)
            else { return nil }
            return arguments[i + 1]
        }
        guard let raw = value("--care-reminder-namespace"), let namespace = UUID(uuidString: raw),
              namespace.uuidString.lowercased() == raw.lowercased(),
              let name = value("--care-reminder-fixture"),
              let mode = ReminderConsentFixtureMode(rawValue: name) else { return .invalid }
        return .fixture(.init(namespace: namespace, mode: mode))
    }
}

/// Dedicated file-backed OS substitute. No UN center, SDK, Core callbacks or ordinary defaults.
@MainActor
final class ReminderConsentNotifications: CareReminderNotifications {
    enum Fault: Error { case corrupt, scope, injected }
    struct Wire: Codable, Equatable {
        let identifier: String
        let metadata: [String: String]
        var deliveredAt: Date?
        var route: CareReminderNotificationRoute? {
            CareReminderNotificationFactory.parse(identifier: identifier, userInfo: metadata)
        }
    }
    struct Ledger: Codable {
        let version: Int
        let namespace: UUID
        let mode: ReminderConsentFixtureMode
        let owner: UUID
        let seed: Date
        var now: Date
        var status: String
        var lag = 0
        var promptCount = 0
        var authReads = 0
        var inventoryReads = 0
        var adds: [Wire] = []
        var removedPending: [String] = []
        var removedDelivered: [String] = []
        var pending: [Wire] = []
        var delivered: [Wire] = []
        var otherPending = ["narat.trial.fixture"]
        var addFailure = false
        var inventoryFailure = false
    }
    private let file: URL
    private(set) var ledger: Ledger
    var now: Date { ledger.now }

    init(file: URL, namespace: UUID, mode: ReminderConsentFixtureMode,
         owner: UUID, seed: Date) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: file))
        } else {
            ledger = Ledger(version: 1, namespace: namespace, mode: mode, owner: owner,
                seed: seed, now: seed, status: mode == .denied ? "denied" : "notDetermined",
                addFailure: mode == .failure)
        }
        guard ledger.version == 1, ledger.namespace == namespace, ledger.mode == mode,
              ledger.owner == owner, ledger.seed == seed, seed.timeIntervalSince1970.isFinite,
              ledger.now >= seed, ledger.now.timeIntervalSince1970.isFinite,
              ["notDetermined", "authorized", "denied"].contains(ledger.status),
              (0...1).contains(ledger.lag),
              [ledger.promptCount, ledger.authReads, ledger.inventoryReads].allSatisfy({ $0 >= 0 }),
              ledger.otherPending == ["narat.trial.fixture"],
              Set(ledger.pending.map(\.identifier)).count == ledger.pending.count,
              Set(ledger.delivered.map(\.identifier)).count == ledger.delivered.count,
              Set(ledger.pending.map(\.identifier)).isDisjoint(with: ledger.delivered.map(\.identifier)),
              ledger.pending.allSatisfy({ $0.deliveredAt == nil }),
              ledger.delivered.allSatisfy({ $0.deliveredAt == $0.route?.candidate.absoluteFireDate }),
              (ledger.adds + ledger.pending + ledger.delivered).allSatisfy({
                  $0.route?.candidate.ownerId == owner
                      && ($0.deliveredAt == nil || $0.deliveredAt! <= ledger.now)
              }),
              (ledger.removedPending + ledger.removedDelivered).allSatisfy({
                  $0.hasPrefix(CareReminderNotificationFactory.prefix)
              }) else { throw Fault.corrupt }
        try save(ledger)
    }

    private func save(_ next: Ledger) throws {
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        ledger = next
    }

    func authorization() async throws -> CareReminderPlan.Authorization {
        var next = ledger; next.authReads += 1
        let status = next.lag > 0 ? "notDetermined" : next.status
        next.lag = max(0, next.lag - 1)
        try save(next)
        switch status {
        case "authorized": return .authorized
        case "denied": return .denied
        default: return .notDetermined
        }
    }

    func requestAuthorization() async throws {
        var next = ledger; next.promptCount += 1
        if next.mode != .denied && next.mode != .twoReadLag {
            next.status = "authorized"
            next.lag = next.mode == .oneReadLag ? 1 : 0
        }
        try save(next)
    }

    /// An explicit fake OS change only; retry on the accepted Core performs the next read.
    func setAuthorization(_ status: CareReminderPlan.Authorization) throws {
        var next = ledger
        switch status {
        case .authorized: next.status = "authorized"
        case .denied: next.status = "denied"
        case .notDetermined: next.status = "notDetermined"
        }
        next.lag = 0
        try save(next)
    }

    func setFailures(add: Bool, inventory: Bool) throws {
        var next = ledger; next.addFailure = add; next.inventoryFailure = inventory
        try save(next)
    }

    func inventory() async throws -> CareReminderNotificationInventory {
        var next = ledger; next.inventoryReads += 1
        try save(next)
        guard !ledger.inventoryFailure else { throw Fault.injected }
        func item(_ wire: Wire) -> CareReminderNotificationInventory.Item {
            .init(rawIdentifier: wire.identifier, route: wire.route, deliveredAt: wire.deliveredAt)
        }
        return .init(pending: ledger.pending.map(item), delivered: ledger.delivered.map(item),
                     otherPendingCount: ledger.otherPending.count)
    }

    func add(_ proposal: CareReminderNotificationProposal, now: Date) async throws {
        guard proposal.candidate.ownerId == ledger.owner, now == ledger.now else { throw Fault.scope }
        let request = try CareReminderNotificationFactory.request(proposal, now: now)
        guard let metadata = request.content.userInfo as? [String: String] else { throw Fault.corrupt }
        let wire = Wire(identifier: request.identifier, metadata: metadata)
        var next = ledger; next.adds.append(wire)
        next.pending.removeAll { $0.identifier == wire.identifier }
        next.pending.append(wire)
        try save(next)
        // Deliberately uncertain OS outcome: exact inventory survives a failed add.
        if ledger.addFailure { throw Fault.injected }
    }

    func removePending(_ identifiers: [String]) async throws { try remove(identifiers, delivered: false) }
    func removeDelivered(_ identifiers: [String]) async throws { try remove(identifiers, delivered: true) }
    private func remove(_ identifiers: [String], delivered: Bool) throws {
        let own = CareReminderNotificationFactory.ownIdentifiers(identifiers)
        var next = ledger
        if delivered {
            next.removedDelivered += own
            next.delivered.removeAll { own.contains($0.identifier) }
        } else {
            next.removedPending += own
            next.pending.removeAll { own.contains($0.identifier) }
        }
        try save(next)
    }

    func advance(to date: Date) throws {
        guard date >= now, date.timeIntervalSince1970.isFinite else { throw Fault.scope }
        var next = ledger; next.now = date
        for var wire in next.pending where wire.route!.candidate.absoluteFireDate <= date {
            wire.deliveredAt = wire.route!.candidate.absoluteFireDate
            next.delivered.removeAll { $0.identifier == wire.identifier }
            next.delivered.append(wire)
        }
        next.pending.removeAll { $0.route!.candidate.absoluteFireDate <= date }
        try save(next)
    }
}

/// Unused by Root in B1. Only this validated, explicit method may create a fixture SDK.
@MainActor
final class ReminderConsentFixture {
    let configuration: ReminderConsentLaunch.Configuration
    let context: CatalogueUIFixtureContext
    let notifications: ReminderConsentNotifications
    let runtime: CareReminderRuntime

    private init(_ configuration: ReminderConsentLaunch.Configuration,
                 context: CatalogueUIFixtureContext, notifications: ReminderConsentNotifications,
                 defaults: UserDefaults) {
        self.configuration = configuration; self.context = context; self.notifications = notifications
        runtime = .init(core: .init(notifications: notifications, defaults: defaults,
            clock: { notifications.now }, timeZone: { TimeZone(secondsFromGMT: 0)! }),
            readiness: .init(held: true))
    }

    static func makeContext(_ configuration: ReminderConsentLaunch.Configuration) async throws -> ReminderConsentFixture {
        var notifications: ReminderConsentNotifications?
        let name = configuration.namespace.uuidString.lowercased()
        let context = try await CatalogueUIFixtures.make(namespace: name, scenario: .todayFuture,
            reminderConfiguration: configuration, reminderPreparation: { server, directory in
                guard let seed = server.snapshot.todayClockSeed.flatMap(SQLTimestamp.date(from:)),
                      server.snapshot.todayAnchorDay != nil,
                      [server.snapshot.reminderCommandRequests, server.snapshot.reminderAuthRequests,
                       server.snapshot.reminderReadRequests].allSatisfy({ ($0 ?? -1) >= 0 })
                else { throw ReminderConsentNotifications.Fault.corrupt }
                notifications = try .init(file: directory.appendingPathComponent("reminder-os.json"),
                    namespace: configuration.namespace, mode: configuration.mode,
                    owner: server.snapshot.permanent, seed: seed)
            })
        guard let notifications, let defaults = UserDefaults(suiteName: "NaratCareReminderFixture." + name) else {
            context.shutdown()
            throw ReminderConsentNotifications.Fault.corrupt
        }
        return .init(configuration, context: context, notifications: notifications, defaults: defaults)
    }

    func matches(context: CatalogueUIFixtureContext, connection: CatalogueConnection) -> Bool {
        self.context === context && context.connection === connection
            && context.namespace == configuration.namespace.uuidString.lowercased()
            && context.server.snapshot.scenario == .todayFuture
            && context.server.snapshot.reminderMode == configuration.mode.rawValue
            && notifications.ledger.owner == context.server.snapshot.permanent
    }

    func cleanup() throws {
        try context.cleanup()
        UserDefaults(suiteName: "NaratCareReminderFixture." + context.namespace)?
            .removePersistentDomain(forName: "NaratCareReminderFixture." + context.namespace)
    }

    func restoreSchedule() throws {
        guard configuration.mode == .noSchedule else { throw ReminderConsentNotifications.Fault.scope }
        try context.resumeToday() // Existing persisted todayWithdrawn=false survives cold restart.
    }
}
#endif
