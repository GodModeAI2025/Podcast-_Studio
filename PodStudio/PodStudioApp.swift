import StudioServices
import SwiftUI

@main
struct PodStudioApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @State private var studio = StudioController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(studio)
                .preferredColorScheme(.dark)
                .tint(Arcade.accent)
                .task {
                    appDelegate.studio = studio
                    await studio.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Catch up on deliveries that arrived while the app was not running
                    // (silent pushes do not relaunch a force-quit app).
                    if phase == .active { Task { await studio.refreshDelivery() } }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(studio)
                .preferredColorScheme(.dark)
                .tint(Arcade.accent)
                .frame(width: 480, height: 520)
        }
        #endif
    }
}
