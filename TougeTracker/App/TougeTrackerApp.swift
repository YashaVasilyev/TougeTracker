import SwiftUI
import SwiftData

@main
struct TougeTrackerApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: SavedRoute.self, Drive.self, RouteTile.self,
                configurations: ModelConfiguration()
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(AppSettings.shared)
                .environment(DriveEngine.shared)
                .environment(TabRouter())
                .environment(RouteStore(container: container))
        }
        .modelContainer(container)
    }
}
