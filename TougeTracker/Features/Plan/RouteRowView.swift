import SwiftUI

struct RouteRowView: View {
    let route: SavedRoute
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading) {
            Text(route.name.isEmpty ? "Unnamed Road" : route.name)
                .font(.headline)
            Text(String(format: "%.1f mi · Score %d/100 · %d turns",
                    route.lengthMeters / 1609.344,
                    max(route.curvatureScore, route.totalScore),
                    route.pacenotes.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
