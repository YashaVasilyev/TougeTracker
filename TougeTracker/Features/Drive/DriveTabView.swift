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
                    DriveDetailView(drive: drive)
                } else {
                    DriveSetupView()
                }
            default:
                DriveSetupView()
            }
        }
        // No .ignoresSafeArea(edges: .top) here: the drive HUD's top bar holds
        // the status readout and controls, and must clear the notch.
    }
}
