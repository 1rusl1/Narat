import UIKit
import UserNotifications

/// Owns the transport before Root exists; construction has no System effects.
@MainActor
final class CareReminderAppDelegate: NSObject, UIApplicationDelegate {
    typealias Installer = @MainActor (CareReminderNotificationBridge) -> Void

    let inbox = CareReminderNotificationInbox()
    private(set) var bridge: CareReminderNotificationBridge?
    private let arguments: [String]
    private let installer: Installer

    override convenience init() {
        self.init(arguments: ProcessInfo.processInfo.arguments) { bridge in
            // Acquisition is lazy and can only happen after the shared launch guard.
            UNUserNotificationCenter.current().delegate = bridge
        }
    }

    init(arguments: [String], installer: @escaping Installer) {
        self.arguments = arguments
        self.installer = installer
        super.init()
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard CareReminderSystemLaunchPolicy.allowsSystem(arguments: arguments),
              bridge == nil else { return true }
        let inbox = inbox
        let bridge = CareReminderNotificationBridge(arguments: arguments) { event in
            await inbox.receive(event)
        }
        self.bridge = bridge
        installer(bridge)
        return true
    }
}
