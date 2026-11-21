import Foundation
import Combine
import UserNotifications

/// Classification only, available before System acquisition in Debug and Release.
/// This does not replace the separate, strict fixture configuration parser.
enum CareReminderSystemLaunchPolicy {
    static func allowsSystem(arguments: [String]) -> Bool {
        let reserved = ["--catalogue", "--today", "--narat-staging",
                        "--care-reminder", "--result-save-presentation"]
        return !arguments.contains { argument in
            reserved.contains { argument.hasPrefix($0) }
        }
    }
}

enum CareReminderNativeEvent: Sendable, Equatable {
    case tap(CareReminderNotificationRoute)
    case foreground(CareReminderNotificationRoute)
}

/// Untrusted transport only. SDK authority and one-shot routing belong to D3.
@MainActor
final class CareReminderNotificationInbox: ObservableObject {
    struct Intent: Sendable, Equatable {
        let id: UUID
        let route: CareReminderNotificationRoute
    }
    private struct Key: Hashable {
        let occurrence: String
        let attempt: UUID
        init(_ route: CareReminderNotificationRoute) {
            occurrence = route.candidate.id
            attempt = route.attemptId
        }
    }
    static let recentLimit = 64
    @Published private(set) var pendingTap: Intent?
    @Published private(set) var latestForeground: CareReminderNotificationRoute?
    private var recent: [Key] = []
    var recentCount: Int { recent.count }

    func receive(_ event: CareReminderNativeEvent) {
        switch event {
        case .foreground(let route):
            latestForeground = route
        case .tap(let route):
            let key = Key(route)
            guard !recent.contains(key) else { return }
            // Remember consumed and displaced taps within a fixed recent window.
            recent.append(key)
            if recent.count > Self.recentLimit { recent.removeFirst() }
            pendingTap = Intent(id: UUID(), route: route)
        }
    }

    func consume(intentID: UUID) {
        guard pendingTap?.id == intentID else { return }
        pendingTap = nil
    }
}

/// Inert optional-protocol witness; no registration, System acquisition or Root access.
final class CareReminderNotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    typealias Sink = @Sendable (CareReminderNativeEvent) async -> Void
    private let systemAllowed: Bool
    private let sink: Sink

    init(arguments: [String], sink: @escaping Sink) {
        systemAllowed = CareReminderSystemLaunchPolicy.allowsSystem(arguments: arguments)
        self.sink = sink
        super.init()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let request = response.notification.request
        receive(identifier: request.identifier, actionIdentifier: response.actionIdentifier,
                userInfo: request.content.userInfo, completionHandler: completionHandler)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let request = notification.request
        present(identifier: request.identifier, userInfo: request.content.userInfo,
                completionHandler: completionHandler)
    }

    // Entry helpers permit tests without fabricating framework notification objects.
    // Completion belongs exclusively to this synchronous callback stack.
    func receive(identifier: String, actionIdentifier: String, userInfo: [AnyHashable: Any],
                 completionHandler: @escaping @Sendable () -> Void) {
        defer { completionHandler() }
        guard systemAllowed, actionIdentifier == UNNotificationDefaultActionIdentifier,
              let route = CareReminderNotificationFactory.parse(
                identifier: identifier, userInfo: userInfo) else { return }
        forward(.tap(route))
    }

    func present(identifier: String, userInfo: [AnyHashable: Any],
                 completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        defer { completionHandler([]) }
        guard systemAllowed, let route = CareReminderNotificationFactory.parse(
            identifier: identifier, userInfo: userInfo) else { return }
        forward(.foreground(route))
    }

    private func forward(_ event: CareReminderNativeEvent) {
        let sink = sink
        // Only the parsed Sendable event and immutable Sendable sink cross this boundary.
        Task { await sink(event) }
    }
}
