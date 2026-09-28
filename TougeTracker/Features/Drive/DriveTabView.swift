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
                    // of its own, so it gets an explicit way back — otherwise a
                    // finished drive is a dead end with only the tab bar to
                    // escape via.
                    DriveDetailView(drive: drive)
                        .safeAreaInset(edge: .bottom) {
                            Button {
                                engine.dismissLastDrive()
                            } label: {
                                Text("Done")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.horizontal)
                            .padding(.bottom, 6)
                            .background(.bar)
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
    }
}
