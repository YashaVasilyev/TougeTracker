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
                // Dark only, deliberately: the app is read in a car, often at
                // night, and a white screen at 60mph is a hazard. This is the
                // belt to `UIUserInterfaceStyle: Dark` in Info.plist — that one
                // covers the UIKit-backed chrome and any modal that escapes this
                // view, this one makes the intent visible in the source and
                // covers a preview or a sheet hosted elsewhere.
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}
