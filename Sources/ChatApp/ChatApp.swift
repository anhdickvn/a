import SwiftUI

@main
struct ChatApp: App {
    @StateObject private var accountStore = MCAccountStore()
    @StateObject private var themeStore = MCThemeStore()
    @StateObject private var historyStore = MCChatHistoryStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                MCServerListView()
                    .tabItem { Label("ChatCraft", systemImage: "message.fill") }

                MCLogsView()
                    .tabItem { Label("Logs", systemImage: "archivebox.fill") }

                MCSettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }
            // Inject every shared store at the TabView root. This is intentionally
            // above all tabs/navigation/sheets so descendants can never render
            // without their required EnvironmentObject.
            .environmentObject(accountStore)
            .environmentObject(historyStore)
            .environmentObject(themeStore)
            .preferredColorScheme(themeStore.mode.colorScheme)
            .tint(.blue)
        }
    }
}
