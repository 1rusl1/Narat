#if DEBUG
import Foundation

enum ReminderConsentFixtureMode: String, Codable, CaseIterable {
    case eligible, oneReadLag = "one-readlag", twoReadLag = "two-readlag"
    case denied, noSchedule = "noSchedule", failure, readiness, hour
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
    struct Event: Codable {
        enum Kind: String, Codable { case add, removePending, removeDelivered, deliver }
        let kind: Kind
        let wires: [Wire]
        let identifiers: [String]
    }
    struct Marker: Codable {
        enum Kind: String, Codable { case authorization, failures, retry, snapshot }
        let kind: Kind
        let authReads: Int
        let inventoryReads: Int
        var overviewReads: Int? = nil
        var addsCount: Int? = nil
        var promptCount: Int? = nil
        var pendingCount: Int? = nil
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
        // Optional keys keep old version-1 cold ledgers decodable.
        var initialPending: [Wire]?
        var initialDelivered: [Wire]?
        var events: [Event]?
        var markers: [Marker]?
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
        try validateEvidence()
        if ledger.events == nil {
            ledger.initialPending = ledger.pending
            ledger.initialDelivered = ledger.delivered
            ledger.events = []
        }
        if ledger.markers == nil { ledger.markers = [] }
        try save(ledger)
    }

    private func validateEvidence() throws {
        guard let events = ledger.events else {
            guard ledger.initialPending == nil, ledger.initialDelivered == nil,
                  ledger.markers == nil else { throw Fault.corrupt }
            return
        }
        guard let initialPending = ledger.initialPending,
              let initialDelivered = ledger.initialDelivered else { throw Fault.corrupt }
        var pending = initialPending, delivered = initialDelivered
        func valid(_ wires: [Wire]) -> Bool {
            wires.allSatisfy { $0.route?.candidate.ownerId == ledger.owner
                    && ($0.deliveredAt == nil || $0.deliveredAt! <= ledger.now) }
                && Set(wires.map(\.identifier)).count == wires.count
        }
        guard valid(pending), valid(delivered),
              Set(pending.map(\.identifier)).isDisjoint(with: delivered.map(\.identifier)),
              pending.allSatisfy({ $0.deliveredAt == nil }),
              delivered.allSatisfy({ $0.deliveredAt == $0.route?.candidate.absoluteFireDate })
        else { throw Fault.corrupt }
        var attempts = Set(initialPending.compactMap { $0.route?.attemptId }
            + initialDelivered.compactMap { $0.route?.attemptId })
        for event in events {
            guard valid(event.wires), event.identifiers.allSatisfy({
                $0.hasPrefix(CareReminderNotificationFactory.prefix)
            }) else { throw Fault.corrupt }
            switch event.kind {
            case .add:
                guard event.wires.count == 1, event.identifiers.isEmpty,
                      let wire = event.wires.first, wire.deliveredAt == nil,
                      !pending.contains(where: { $0.identifier == wire.identifier }),
                      let attempt = wire.route?.attemptId, attempts.insert(attempt).inserted
                else { throw Fault.corrupt }
                pending += event.wires
            case .removePending, .removeDelivered:
                guard event.wires.isEmpty else { throw Fault.corrupt }
                if event.kind == .removePending {
                    pending.removeAll { event.identifiers.contains($0.identifier) }
                } else { delivered.removeAll { event.identifiers.contains($0.identifier) } }
            case .deliver:
                guard event.identifiers.isEmpty, event.wires.allSatisfy({ wire in
                    pending.contains(where: { $0.identifier == wire.identifier && $0.metadata == wire.metadata })
                        && wire.deliveredAt == wire.route?.candidate.absoluteFireDate
                        && wire.deliveredAt! <= ledger.now
                }) else { throw Fault.corrupt }
                pending.removeAll { item in event.wires.contains { $0.identifier == item.identifier } }
                delivered += event.wires
            }
        }
        guard pending == ledger.pending, delivered == ledger.delivered else { throw Fault.corrupt }
        var auth = 0, inventory = 0
        for marker in ledger.markers ?? [] {
            guard marker.authReads >= auth, marker.authReads <= ledger.authReads,
                  marker.inventoryReads >= inventory, marker.inventoryReads <= ledger.inventoryReads
            else { throw Fault.corrupt }
            let metadata = [marker.overviewReads, marker.addsCount, marker.promptCount, marker.pendingCount]
            guard metadata.compactMap({ $0 }).allSatisfy({ (0...Int(Int32.max)).contains($0) }),
                  marker.addsCount.map({ $0 <= ledger.adds.count }) ?? true,
                  marker.promptCount.map({ $0 <= ledger.promptCount }) ?? true,
                  marker.kind != .snapshot || metadata.allSatisfy({ $0 != nil })
            else { throw Fault.corrupt }
            auth = marker.authReads; inventory = marker.inventoryReads
        }
    }

    private func mark(_ kind: Marker.Kind, in next: inout Ledger) {
        let marker = Marker(kind: kind, authReads: next.authReads, inventoryReads: next.inventoryReads)
        next.markers?.append(marker)
    }

    /// Reads stored evidence only, even before Core has a consent binding.
    func snapshot(overviewReads: Int) throws {
        guard (0...Int(Int32.max)).contains(overviewReads) else { throw Fault.corrupt }
        var next = ledger
        next.markers?.append(Marker(kind: .snapshot, authReads: next.authReads,
            inventoryReads: next.inventoryReads, overviewReads: overviewReads,
            addsCount: next.adds.count, promptCount: next.promptCount, pendingCount: next.pending.count))
        try save(next)
    }

    func markRetry() throws {
        var next = ledger
        mark(.retry, in: &next)
        try save(next)
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
        mark(.authorization, in: &next)
        try save(next)
    }

    func setFailures(add: Bool, inventory: Bool) throws {
        var next = ledger; next.addFailure = add; next.inventoryFailure = inventory
        mark(.failures, in: &next)
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
        guard !ledger.pending.contains(where: { $0.identifier == wire.identifier }),
              !ledger.adds.contains(where: { $0.route?.attemptId == proposal.attemptId })
        else { throw Fault.corrupt }
        var next = ledger; next.adds.append(wire)
        next.events?.append(.init(kind: .add, wires: [wire], identifiers: []))
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
        next.events?.append(.init(kind: delivered ? .removeDelivered : .removePending,
                                  wires: [], identifiers: own))
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
            next.events?.append(.init(kind: .deliver, wires: [wire], identifiers: []))
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

    func snapshotEvidence() throws {
        guard let reads = context.server.snapshot.overviewRequests else {
            throw ReminderConsentNotifications.Fault.corrupt
        }
        try notifications.snapshot(overviewReads: reads)
    }

    func restoreSchedule() throws {
        guard configuration.mode == .noSchedule else { throw ReminderConsentNotifications.Fault.scope }
        try context.resumeToday() // Existing persisted todayWithdrawn=false survives cold restart.
    }
}
#endif
