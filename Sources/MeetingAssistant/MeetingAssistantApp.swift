import SwiftUI

@main
struct MeetingAssistantApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 780, minHeight: 620)
        }
        .defaultSize(width: 1_280, height: 820)

        Settings {
            SettingsView()
                .environmentObject(appModel)
                .frame(width: 560)
        }
    }
}
