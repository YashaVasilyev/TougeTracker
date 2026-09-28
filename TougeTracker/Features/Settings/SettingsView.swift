import SwiftUI
import CoreLocation

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Speed / distance", selection: $settings.units) {
                        ForEach(LengthUnit.allCases) { u in
                            Text(u.rawValue).tag(u)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Pacenotes") {
                    Picker("Format", selection: $settings.pacenoteFormat) {
                        ForEach(PacenoteFormat.allCases) { f in
                            Text(f.rawValue.capitalized).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Co-driver") {
                    Toggle("Voice", isOn: .init(
                        get: { settings.voiceEnabled },
                        set: { settings.voiceEnabled = $0 }
                    ))
                    Slider(value: $settings.speechRate, in: 0.5...2.0, step: 0.05)
                    Text(String(format: "Rate: %.2f", settings.speechRate))
                    Slider(value: $settings.callDistanceScale, in: 0.5...2.0, step: 0.1)
                    Text(String(format: "Call distance scale: %.1f", settings.callDistanceScale))
                }
            }
            .navigationTitle("Settings")
        }
    }
}
