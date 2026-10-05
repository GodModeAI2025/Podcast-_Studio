import StudioServices
import SwiftUI

// Silent CloudKit pushes (CKDatabaseSubscription) wake the owner's app on every device and
// trigger a zone fetch → "X von N Tracks da".

#if os(iOS)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    var studio: StudioController?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let studio else { return .noData }
        return await studio.handleRemoteNotification(userInfo) ? .newData : .noData
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Remote notifications unavailable: \(error.localizedDescription)")
    }
}

#elseif os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var studio: StudioController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let studio else { return }
        // Parsed synchronously; only the zone refresh runs asynchronously.
        _ = studio.handleRemotePush(userInfo)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Remote notifications unavailable: \(error.localizedDescription)")
    }
}
#endif
