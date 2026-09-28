import SwiftUI
import Charts
import SwiftData

struct HistoryListView: View {
    @Environment(RouteStore.self) private var store: RouteStore

    var body: some View {
        NavigationStack {
            List(store.drives()) { drive in
                NavigationLink(value: drive) {
                    VStack(alignment: .leading) {
                        Text(drive.summaryText).font(.headline)
                        Text(String(format: "%.2f max lateral G · %.0f m/s", drive.maxLateralG, drive.maxSpeed))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: Drive.self) { drive in
                DriveDetailView(drive: drive)
            }
        }
    }
}

struct DriveDetailView: View {
    @Environment(AppSettings.self) private var settings: AppSettings
    let drive: Drive

    private var samples: [TelemetrySample] {
        // Downsample for rendering if large.
        let all = drive.samples
        guard all.count > 5000 else { return all }
        let step = all.count / 5000
        return stride(from: 0, to: all.count, by: step).map { all[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statsGrid
                speedChart
                longitudinalChart
                lateralChart
                ggDiagram
            }
            .padding()
        }
        .navigationTitle(drive.routeName ?? "Drive")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink("Export", items: [DriveExporter.csv(drive), DriveExporter.gpx(drive)])
            }
        }
    }

    @ViewBuilder private var statsGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, spacing: 10) {
            StatTile("DISTANCE", settings.units.distanceString(drive.distanceMeters))
            StatTile("DURATION", formattedTime(drive.durationSeconds))
            StatTile("MAX SPEED", settings.units.speedString(drive.maxSpeed))
            StatTile("MAX LAT G", String(format: "%.2f", drive.maxLateralG))
        }
        .font(.caption)
    }

    @ViewBuilder private var speedChart: some View {
        Chart(samples, id: \.t) { s in
            LineMark(x: .value("t", s.t), y: .value("speed", Double(s.speed) * (settings.units == .mph ? 2.237 : 3.6)))
                .interpolationMethod(.catmullRom(alpha: 0.2))
                .foregroundStyle(Color.orange)
        }
        .frame(height: 120)
        .overlay(alignment: .topTrailing) {
            Text("Speed").font(.caption).padding(4)
        }
    }

    @ViewBuilder private var longitudinalChart: some View {
        Chart {
            ForEach(samples, id: \.t) { s in
                BarMark(x: .value("t", s.t), y: .value("g", Double(s.forwardG)))
                    .foregroundStyle(Double(s.forwardG) >= 0 ? Color.green : Color.red)
        }
        }
        .chartYScale(domain: -1...1)
        .frame(height: 90)
    }

    @ViewBuilder private var lateralChart: some View {
        Chart(samples, id: \.t) { s in
            AreaMark(x: .value("t", s.t), y: .value("lat", Double(s.lateralG)))
                .foregroundStyle(Color.blue.opacity(0.5))
        }
        .chartYScale(domain: -1.2...1.2)
        .frame(height: 90)
    }

    @ViewBuilder private var ggDiagram: some View {
        Chart(samples, id: \.t) { s in
            PointMark(x: .value("long", Double(s.forwardG)),
                      y: .value("lat", Double(s.lateralG)))
                .foregroundStyle(Color.purple)
        }
        .chartXScale(domain: -1.2...1.2)
        .chartYScale(domain: -1.2...1.2)
        .frame(height: 180)
        .overlay(alignment: .center) {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        }
    }

    private func formattedTime(_ t: TimeInterval) -> String {
        let t = max(0, t)
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct StatTile: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        VStack(alignment: .center) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Writes shareable CSV/GPX for a drive.
///
/// Both formats are exported in SI units (m/s, metres) so the data stays
/// canonical and re-importable; the app's display preference only affects
/// on-screen rendering. The two unit columns in the CSV make that explicit.
private struct DriveExporter {
    static func csv(_ drive: Drive) -> URL {
        let samples = drive.samples
        let header = "t,lat,lon,speed_mps,speed_mph,speed_kmh,course,altitude,fwdG,latG,yawRate"
        var rows: [String] = []
        rows.reserveCapacity(samples.count)
        for s in samples {
            let mps = Double(s.speed)
            let row = "\(s.t),\(s.lat),\(s.lon),\(mps),\(mps * 2.236936),\(mps * 3.6),"
                + "\(s.course),\(s.altitude),\(s.forwardG),\(s.lateralG),\(s.yawRate)"
            rows.append(row)
        }
        let text = ([header] + rows).joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drive_\(Int(Date().timeIntervalSince1970)).csv")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func gpx(_ drive: Drive) -> URL {
        let samples = drive.samples
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var trkpts = ""
        trkpts.reserveCapacity(samples.count * 200)
        for s in samples {
            // GPX <time> is a full xsd:dateTime, not a seconds-since-start
            // offset. Offsetting from the drive's start keeps the track
            // positioned on the real-world timeline.
            let stamp = iso.string(from: drive.startedAt.addingTimeInterval(s.t))
            trkpts += "    <trkpt lat=\"\(s.lat)\" lon=\"\(s.lon)\"><time>\(stamp)</time>"
                + "<ele>\(s.altitude)</ele><extensions><speed>\(s.speed)</speed>"
                + "<course>\(s.course)</course><gforce fwd=\"\(s.forwardG)\""
                + " lat=\"\(s.lateralG)\"/></extensions></trkpt>\n"
        }

        // Route names come from the tile data and may contain & or <.
        let name = xmlEscaped(drive.routeName ?? "TougeTracker drive")
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1" creator="TougeTracker">
          <trk><name>\(name)</name><trkseg>
        \(trkpts)          </trkseg></trk>
        </gpx>
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drive_\(Int(Date().timeIntervalSince1970)).gpx")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Escapes the five XML predefined entities. Order matters: `&` first.
    private static func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
