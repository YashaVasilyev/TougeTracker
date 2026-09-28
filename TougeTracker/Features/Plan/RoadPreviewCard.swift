import SwiftUI

/// Bottom preview card shown when a road is tapped on the map — the Tougefinder
/// pattern: at-a-glance stats and primary actions without leaving the map.
/// "Details" opens the full `RouteDetailView` sheet.
struct RoadPreviewCard: View {
    let road: TougeRoad
    let settings: AppSettings
    let isSaved: Bool
    let onSave: () -> Void
    let onStart: () -> Void
    let onDetails: () -> Void
    let onDismiss: () -> Void

    /// Generated once in `init` rather than computed in `body`: the generator
    /// walks every coordinate of the road, so a computed property would re-run
    /// the whole pass on each body evaluation. Same approach as
    /// `RouteDetailView`.
    private let pacenotes: [Pacenote]

    init(road: TougeRoad, settings: AppSettings, isSaved: Bool,
         onSave: @escaping () -> Void, onStart: @escaping () -> Void,
         onDetails: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.road = road
        self.settings = settings
        self.isSaved = isSaved
        self.onSave = onSave
        self.onStart = onStart
        self.onDetails = onDetails
        self.onDismiss = onDismiss
        self.pacenotes = PacenoteGenerator.generate(road.geoPoints).turns
    }

    /// The first few notes, rendered with the connector that joins each to the
    /// one before it. Without it the chips read as disconnected grades.
    private var previewLines: [String] {
        let head = Array(pacenotes.prefix(4))
        return PacenoteGenerator.renderedList(head, format: settings.pacenoteFormat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            stats
            if !previewLines.isEmpty {
                notesPreview
            }
            actions
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(road.displayName)
                    .font(.headline)
                    .lineLimit(2)
                if let type = road.type, !type.isEmpty {
                    Text(type.capitalized)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            scoreBadge
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }

    private var scoreBadge: some View {
        let score = road.totalScore ?? 0
        return VStack(spacing: 0) {
            Text("\(score)")
                .font(.title3).fontWeight(.bold)
                .monospacedDigit()
            Text("score")
                .font(.system(size: 9)).opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(ScoreStyle.color(for: score), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: - Stats

    private var stats: some View {
        HStack(spacing: 0) {
            stat("Length", settings.units.distanceString(road.lengthMeters))
            Divider().frame(height: 26)
            stat("Curvature", "\(road.curvatureScore ?? 0)")
            Divider().frame(height: 26)
            stat("Flow", "\(road.flowScore ?? 0)")
            Divider().frame(height: 26)
            stat("Turns", "\(pacenotes.count)")
        }
        .padding(.vertical, 2)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline).fontWeight(.semibold)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Notes preview

    private var notesPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pacenotes.count > 4
                 ? "First 4 of \(pacenotes.count) turns"
                 : "Pacenotes")
                .font(.caption2).foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onStart) {
                Label("Start", systemImage: "car.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            Button(action: onSave) {
                Label(isSaved ? "Saved" : "Save",
                      systemImage: isSaved ? "checkmark" : "bookmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isSaved)

            Button(action: onDetails) {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Full details")
        }
        .font(.footnote)
        .controlSize(.regular)
    }
}

/// Shared score→colour mapping so the map lines and the card badge agree.
enum ScoreStyle {
    static func color(for score: Int) -> Color {
        if score >= 80 { return Color(red: 0.929, green: 0.239, blue: 0.196) }
        if score >= 50 { return Color(red: 1.0, green: 0.757, blue: 0.031) }
        return Color(red: 0.275, green: 0.651, blue: 0.196)
    }
}

