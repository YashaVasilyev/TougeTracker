import SwiftUI
import Observation

/// Which root tab is showing. Drives the `TabView` selection so a drive started
/// from the Plan tab can pull the user into the HUD instead of leaving them
/// looking at the map.
enum AppTab: Hashable {
    case plan, drive, history, settings
}

@MainActor
@Observable
final class TabRouter {
    var selected: AppTab = .plan

    /// Call when a drive begins so the HUD takes over the screen.
    func enterDriveMode() {
        selected = .drive
    }
}

struct RootTabView: View {
    @Environment(TabRouter.self) private var router: TabRouter

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.selected) {
            RouteBrowserView()
                .tabItem { Label("Plan", systemImage: "map") }
                .tag(AppTab.plan)

            DriveTabView()
                .tabItem { Label("Drive", systemImage: "gauge.with.needle") }
                .tag(AppTab.drive)

            HistoryListView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.history)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
