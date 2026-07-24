import SwiftUI

@main
struct NotedApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }

#if os(macOS)
        Settings {
            NavigationStack {
                SettingsView()
                    .environmentObject(model)
            }
            .frame(minWidth: 560, minHeight: 560)
        }
#endif
    }
}
