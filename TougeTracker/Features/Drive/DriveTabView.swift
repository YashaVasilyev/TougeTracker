import SwiftUI

struct DriveTabView: View {
    @Environment(DriveEngine.self) private var engine: DriveEngine

    var body: some View {
        Group {
            switch engine.state {
            case .recording, .paused:
                DriveHUDView()
            case .finished:
                if let drive = engine.lastDrive {
                    // `DriveDetailView` is a scroll view with no navigation bar
                    // of its own, so it takes a way out — otherwise a finished
                    // drive is a dead end with only the tab bar to escape via.
                    // It only does so when asked: from History the same view is
                    // pushed onto a stack, where a Done button would be a second
                    // way to press Back.
                    DriveDetailView(drive: drive) {
                        engine.dismissLastDrive()
                    }
                } else {
                    DriveSetupView()
                }
            default:
                DriveSetupView()
            }
        }
        // No .ignoresSafeArea(edges: .top) here: the drive HUD's top bar holds
        // the status readout and controls, and must clear the notch.
        .background(Theme.background)
    }
}
