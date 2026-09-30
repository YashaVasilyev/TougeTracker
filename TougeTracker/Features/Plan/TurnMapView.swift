import SwiftUI
import MapKit

/// Every turn on a road, shown on the map and listed underneath.
///
/// The map in `RouteDetailView` marks each apex, but with an identical red pin,
/// so it answers *where* the corners are and not what they are. This is the
/// other half: a marker labelled with its grade, coloured by severity, and a
/// list you can tap to fly the map to a corner.
struct TurnMapView: View {
    @Environment(\.dismiss) private var dismiss

    let road: TougeRoad
    let settings: AppSettings
    let pacenotes: [Pacenote]

    @State private var position: MapCameraPosition = .automatic
    @State private var selected: Int?

    init(road: TougeRoad, settings: AppSettings) {
        self.road = road
        self.settings = settings
        self.pacenotes = PacenoteGenerator.generate(road.geoPoints).turns
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map
                Divider()
                list
            }
            .navigationTitle("Turns")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $position) {
            if road.geoPoints.count > 1 {
                MapPolyline(coordinates: road.geoPoints.map(\.clLocation))
                    .stroke(.blue.opacity(0.45), lineWidth: 4)
            }
            // Turns only. A straight is a distance, not a place, and marking
            // every run would bury the corners under a wall of labels.
            ForEach(Array(pacenotes.enumerated()), id: \.offset) { index, note in
                if !note.isStraight {
                    Annotation(TurnMapView.turnLabel(for: note), coordinate: note.apex.clLocation) {
                        turnMarker(for: note, index: index)
                    }
                }
            }
        }
        .mapStyle(.standard)
        .frame(height: 280)
        .mapControls { MapCompass() }
    }

    /// What is written on the marker: the severity, or the shape when the
    /// corner is a hairpin or a square, which are not numbers.
    /// The whole call in words, for a screen reader: "three left tightens".
    static func spokenCall(for note: Pacenote) -> String {
        var words = [SeverityStyle.spoken(note.grade)]
        if let direction = note.direction { words.append(direction == .left ? "left" : "right") }
        if note.trend.isNoted { words.append(CornerTrend.spelling(note.trend).trimmingCharacters(in: .whitespaces)) }
        return words.joined(separator: " ")
    }

    /// What is written on a marker: the severity, or the shape when the corner
    /// is a hairpin or a square, which are not numbers.
    static func turnLabel(for note: Pacenote) -> String {
        switch note.grade {
        case "HP": return "HP"
        case "Square": return "Sq"
        default: return note.grade
        }
    }

    private func turnMarker(for note: Pacenote, index: Int) -> some View {
        GradeMarker(text: TurnMapView.turnLabel(for: note), grade: note.grade,
                    isSelected: selected == index,
                    spokenLabel: TurnMapView.spokenCall(for: note),
                    metresIn: note.startDist)
    }

    // MARK: - List

    private var list: some View {
        List {
            if pacenotes.isEmpty {
                ContentUnavailableView("No turns", systemImage: "wind",
                                       description: Text("This road has no corners worth calling."))
            } else {
                Section("\(pacenotes.count) notes") {
                    ForEach(Array(pacenotes.enumerated()), id: \.offset) { index, note in
                        Button { focus(on: index) } label: {
                            row(for: note)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selected == index
                                            ? Color.accentColor.opacity(0.12) : nil)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(for note: Pacenote) -> some View {
        HStack(spacing: 10) {
            Text(TurnMapView.turnLabel(for: note))
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(SeverityStyle.color(for: note.grade), in: Circle())
            Text(note.isStraight
                 ? "\(settings.units.distanceString(note.length)) straight"
                 : PacenoteGenerator.describe(grade: note.grade, dir: note.direction,
                                             format: settings.pacenoteFormat,
                                             isLong: note.isLong, isVeryLong: note.isVeryLong,
                                             isHairpin: note.grade == "HP",
                                             straightLengthMeters: nil))
                .font(.system(.body, design: .monospaced))
            Spacer(minLength: 8)
            Text(settings.units.distanceString(note.startDist))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    /// Centres the map on a corner and selects it.
    private func focus(on index: Int) {
        guard pacenotes.indices.contains(index) else { return }
        selected = index
        let apex = pacenotes[index].apex.clLocation
        // A span tight enough to see the corner and what leads into it, rather
        // than the whole road, which is the view the user just left.
        position = .region(MKCoordinateRegion(
            center: apex,
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)))
    }
}

/// Severity -> colour, so a grade reads the same wherever it is shown.
///
/// The ramp runs green for an open corner through to red for the tightest, so
/// the map can be read at a glance without decoding the number. Hairpins and
/// squares sit at the tight end because that is how sharply they turn.
/// The coloured circle a turn is drawn as. Shared so a grade looks the same on
/// the turn map and on the detail sheet's map.
struct GradeMarker: View {
    let text: String
    let grade: String
    var isSelected: Bool = false
    /// What VoiceOver says, where a screen reader would otherwise announce a
    /// digit and a colour and neither of which means anything.
    var spokenLabel: String?
    /// How far into the road this corner is, so "three left" is not just a
    /// severity but somewhere on the drive.
    var metresIn: Double?

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: isSelected ? 30 : 24, height: isSelected ? 30 : 24)
            .background(SeverityStyle.color(for: grade), in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: isSelected ? 3 : 1.5))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel ?? SeverityStyle.spoken(grade))
            .accessibilityValue(metresIn.map { "\(Int($0)) metres in" } ?? "")
    }
}

enum SeverityStyle {
    /// How a grade is spoken, for anything a person has to hear rather than read.
    ///
    /// A marker is a colour and a digit, and neither survives VoiceOver: the
    /// colour is invisible and "1" is announced as "one" at best. This spells
    /// out the words a co-driver would use.
    static func spoken(_ grade: String) -> String {
        switch grade {
        case "HP": return "hairpin"
        case "Square": return "square"
        case "Flat": return "flat"
        case "1": return "one"
        case "2": return "two"
        case "3": return "three"
        case "4": return "four"
        case "5": return "five"
        case "6": return "six"
        default: return grade
        }
    }

    static func color(for grade: String) -> Color {
        switch grade {
        case "HP": return Color(red: 0.62, green: 0.11, blue: 0.20)
        case "Square": return Color(red: 0.80, green: 0.16, blue: 0.16)
        case "1": return Color(red: 0.87, green: 0.18, blue: 0.18)
        case "2": return Color(red: 0.93, green: 0.31, blue: 0.13)
        case "3": return Color(red: 0.95, green: 0.47, blue: 0.09)
        case "4": return Color(red: 0.93, green: 0.62, blue: 0.10)
        case "5": return Color(red: 0.83, green: 0.71, blue: 0.12)
        default: return Color(red: 0.35, green: 0.62, blue: 0.24)
        }
    }
}
