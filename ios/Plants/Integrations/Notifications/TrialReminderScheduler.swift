import Foundation
import Observation
import UserNotifications

struct VerifiedTrial: Equatable, Sendable {
    let ownerId: UUID
    let end: Date
    let accessUntil: Date

    init?(ownerId: UUID, entitlement: SyncWireEntitlementDTO?, now: Date) {
        guard let entitlement, entitlement.productId == "app.narat.plants.pro.yearly",
              entitlement.offerKind == "trial", let end = entitlement.trialEndAt.flatMap(SQLTimestamp.date(from:)),
              let accessUntil = entitlement.verifiedAccessUntil, accessUntil > now else { return nil }
        self.ownerId = ownerId
        self.end = end
        self.accessUntil = accessUntil
    }

    var reminderDate: Date { end.addingTimeInterval(-24 * 60 * 60) }
}

struct TrialReminderRequest: Equatable, Sendable {
    static let prefix = "narat.trial-reminder."
    let ownerId: UUID
    let date: Date
    let locale: SupportedLocale

    var id: String { Self.prefix + ownerId.uuidString.lowercased() }
}

@MainActor
protocol TrialReminderNotifications {
    /// Nil means the system has not asked for permission.
    func authorization() async -> Bool?
    func requestAuthorization() async throws
    func reconcile(_ request: TrialReminderRequest?) async throws
}

@MainActor
private struct SystemTrialReminderNotifications: TrialReminderNotifications {
    private var center: UNUserNotificationCenter { .current() }

    func authorization() async -> Bool? {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: nil
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func reconcile(_ request: TrialReminderRequest?) async throws {
        let center = center
        let pending = await center.pendingNotificationRequests()
        let obsolete = pending.map(\.identifier).filter {
            $0.hasPrefix(TrialReminderRequest.prefix) && $0 != request?.id
        }
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter {
            $0.hasPrefix(TrialReminderRequest.prefix) && $0 != request?.id
        })
        guard let request else { return }

        let content = UNMutableNotificationContent()
        content.title = request.locale == .pl ? "Okres próbny dobiega końca" : "Your trial ends soon"
        content.body = request.locale == .pl
            ? "Sprawdź datę zakończenia okresu próbnego w Narat."
            : "Check your trial end date in Narat."
        content.sound = .default
        let calendar = SQLCalendarDay.calendar
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: request.date)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        if let existing = pending.first(where: { $0.identifier == request.id }),
           (existing.trigger as? UNCalendarNotificationTrigger)?.dateComponents == components,
           existing.content.title == content.title, existing.content.body == content.body { return }
        center.removePendingNotificationRequests(withIdentifiers: [request.id])
        try await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger))
    }
}

@MainActor
@Observable
final class TrialReminderScheduler {
    private(set) var trial: VerifiedTrial?
    private(set) var optedIn = false
    private(set) var notificationsDenied = false
    private(set) var schedulingFailed = false

    @ObservationIgnored private let notifications: any TrialReminderNotifications
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var locale: SupportedLocale = .en
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0

    convenience init() {
        self.init(notifications: SystemTrialReminderNotifications())
    }

    init(notifications: any TrialReminderNotifications, defaults: UserDefaults = .standard,
         clock: @escaping () -> Date = { Date() }) {
        self.notifications = notifications
        self.defaults = defaults
        self.clock = clock
    }

    @discardableResult
    func update(ownerId: UUID?, entitlement: SyncWireEntitlementDTO?, locale: SupportedLocale) -> Task<Void, Never> {
        self.locale = locale
        trial = ownerId.flatMap { VerifiedTrial(ownerId: $0, entitlement: entitlement, now: clock()) }
        optedIn = trial.map { defaults.bool(forKey: preferenceKey($0.ownerId)) } ?? false
        notificationsDenied = false
        schedulingFailed = false
        expiryTask?.cancel()
        expiryTask = nil
        if let trial {
            let delay = max(0, trial.accessUntil.timeIntervalSince(clock()))
            expiryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, self.trial == trial else { return }
                self.update(ownerId: nil, entitlement: nil, locale: self.locale)
            }
        }
        return reconcile()
    }

    func setOptIn(_ enabled: Bool, ownerId: UUID) async {
        guard let trial, trial.ownerId == ownerId, trial.accessUntil > clock() else { return }
        defaults.set(enabled, forKey: preferenceKey(ownerId))
        optedIn = enabled
        var authorizationFailed = false
        if enabled, canSchedule(trial), await notifications.authorization() == nil,
           self.trial?.ownerId == ownerId, optedIn {
            do { try await notifications.requestAuthorization() }
            catch { authorizationFailed = true }
        }
        await reconcile().value
        if authorizationFailed, self.trial?.ownerId == ownerId, optedIn { schedulingFailed = true }
    }

    private func preferenceKey(_ ownerId: UUID) -> String {
        "narat.trial-reminder.opt-in." + ownerId.uuidString.lowercased()
    }

    private func canSchedule(_ trial: VerifiedTrial) -> Bool {
        trial.reminderDate > clock() && trial.reminderDate < trial.accessUntil
    }

    private func reconcile() -> Task<Void, Never> {
        revision += 1
        let expected = revision
        let previous = work
        // Serialize OS writes so a logout or opt-out always wins over an in-flight add.
        let next = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, revision == expected else { return }
            var request: TrialReminderRequest?
            notificationsDenied = false
            schedulingFailed = false
            if let trial, optedIn, canSchedule(trial) {
                let allowed = await notifications.authorization()
                guard revision == expected else { return }
                notificationsDenied = allowed == false
                if allowed == true, canSchedule(trial) {
                    request = TrialReminderRequest(ownerId: trial.ownerId, date: trial.reminderDate, locale: locale)
                }
            }
            do {
                try await notifications.reconcile(request)
            } catch {
                if revision == expected { schedulingFailed = true }
            }
        }
        work = next
        return next
    }
}
