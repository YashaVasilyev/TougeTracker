import SwiftUI
import Charts
import SwiftData
import MapKit
import CoreLocation

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
            // An empty list is what a failed read looks like, so say so rather
            // than letting a corrupt store read as "you have never driven".
            .overlay {
                if store.drives().isEmpty, let error = store.lastError {
                    ContentUnavailableView {
                        Label("Could not load drives", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                }
            }
        }
    }
}

/// The screen a drive ends on, and the same screen History opens a past drive
/// on: where you went, how it went, and the shape of it over time.
///
/// Laid out as a 2×2 of map, stats, and the two traces. This replaced a single
/// scrolling column of five small charts, which had the map nowhere on it at
/// all — the one thing you want first when you stop and ask "where was that?".
struct DriveDetailView: View {
    @Environment(AppSettings.self) private var settings: AppSettings
    let drive: Drive

    /// Leaves this screen, when there is somewhere to leave *to*.
    ///
    /// The summary is shown from two places and only one of them is a dead
    /// end: right after a drive finishes (the Drive tab replaces the setup
    /// view with this, so there is nothing behind it but the tab bar) and from
    /// History, where it is pushed onto a stack and the back button already
    /// does the job. Nil — the History case — means no button is drawn.
    var onDone: (() -> Void)?

    /// The driven line, and the series to plot. Both are computed once in `init`
    /// rather than in `body`: `drive.samples` unpacks the whole telemetry blob
    /// out of SwiftData on every access, so a computed property would re-decode
    /// tens of thousands of samples on every redraw — including the ones caused
    /// by scrubbing the chart.
    private let path: [CLLocationCoordinate2D]
    private let series: [DriveMetrics.Point]

    @State private var mapPosition: MapCameraPosition
    /// Where the user is scrubbing, in seconds since the start of the drive.
    @State private var scrubTime: Double?
    /// Whether the G-diagram is shown. It is the one thing here that cannot be
    /// read at a glance, so it stays out of the way until it is asked for.
    @State private var showingGDiagram = false

    init(drive: Drive, onDone: (() -> Void)? = nil) {
        self.drive = drive
        self.onDone = onDone
        let samples = drive.samples
        self.series = DriveMetrics.series(from: samples)
        // The polyline is decimated harder than the charts: a line this dense
        // is indistinguishable from a smooth one, and MapKit is paid per point.
        let step = max(1, samples.count / 2000)
        self.path = stride(from: 0, to: samples.count, by: step)
            .map { CLLocationCoordinate2D(latitude: samples[$0].lat,
                                          longitude: samples[$0].lon) }
        _mapPosition = State(initialValue: .region(MapFit.region(for: path)))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top half: the run on the left, the numbers on the right.
            HStack(spacing: 0) {
                runMap
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Theme.border)
                statsPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Divider().overlay(Theme.border)

            // Bottom half: the two traces.
            tracesPanel
                .frame(minHeight: 200, maxHeight: .infinity)
        }
        .background(Theme.background)
        .navigationTitle(drive.routeName ?? "Drive")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink("Export", items: [DriveExporter.csv(drive), DriveExporter.gpx(drive)])
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingGDiagram.toggle()
                } label: {
                    Label("G diagram", systemImage: "circle.grid.cross")
                }
            }
        }
        .sheet(isPresented: $showingGDiagram) {
            gDiagramSheet
                .presentationBackground(Theme.background)
        }
    }

    // MARK: - Map

    /// The line actually driven, with where it started and stopped.
    ///
    /// Not the planned route: after a run the question is where the car went,
    /// and on a drive that left the planned line those are two different shapes.
    private var runMap: some View {
        Map(position: $mapPosition) {
            if path.count > 1 {
                // Two strokes: a wide translucent one under a solid line, so the
                // route reads on a dark map without glowing.
                MapPolyline(coordinates: path)
                    .stroke(Theme.accent.opacity(0.25), lineWidth: 8)
                MapPolyline(coordinates: path)
                    .stroke(Theme.accent, lineWidth: 3)
            }
            if let first = path.first {
                Marker("Start", systemImage: "flag.checkered", coordinate: first)
                    .tint(Theme.start)
            }
            if let last = path.last, path.count > 1 {
                Marker("Finish", systemImage: "flag", coordinate: last)
                    .tint(Theme.finish)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls { MapCompass() }
        .overlay(alignment: .topLeading) {
            if drive.sampleCount == 0 {
                Text("No telemetry")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
        }
    }

    // MARK: - Stats

    /// The four headline numbers, and the peak-G row underneath them.
    ///
    /// Top and average speed lead because they are what a driver checks against
    /// their own memory of the run; distance and time give them scale.
    ///
    /// No scroll view: the panel shares the top half of the screen with the map,
    /// so every row is given an equal share of whatever height that half has
    /// rather than sitting at its natural size in a column of empty space. On a
    /// short screen the tiles compress instead of the last one being cut off.
    private var statsPanel: some View {
        VStack(spacing: 8) {
            // The two speeds get a tile each rather than a quarter of the
            // panel: they are the numbers a driver actually came back for, and
            // they are the only ones that fill a whole tile.
            HStack(spacing: 8) {
                SpeedTile("TOP SPEED",
                          value: settings.units.speedString(drive.maxSpeed),
                          unit: settings.units.symbol)
                SpeedTile("AVERAGE SPEED",
                          value: settings.units.speedString(avgSpeed),
                          unit: settings.units.symbol)
            }
            HStack(spacing: 8) {
                StatTile("DISTANCE",
                         value: settings.units.distanceString(drive.distanceMeters),
                         unit: settings.units.distanceSymbol)
                StatTile("TIME",
                         value: formattedTime(drive.durationSeconds),
                         unit: "")
            }
            // The G figures are a third of the width each, so they get shorter
            // labels and a smaller value — a third of half a phone is about
            // 60pt, which is not enough for "PEAK LATERAL" beside a 20pt number.
            HStack(spacing: 8) {
                StatTile("LATERAL", value: gString(drive.maxLateralG),
                         unit: "g", compact: true)
                StatTile("BRAKE", value: gString(drive.maxBrakeG),
                         unit: "g", compact: true)
                StatTile("ACCEL", value: gString(drive.maxForwardG),
                         unit: "g", compact: true)
            }
        }
        .frame(maxHeight: .infinity)
        .padding(12)
        .background(Theme.surface)
    }

    /// Signed so a brake figure reads as a push against the limit rather than a
    /// positive number that happens to be labelled BRAKE.
    private func gString(_ g: Double) -> String {
        String(format: "%+.2f", g)
    }

    /// Distance over elapsed time, not the mean of the sampled speeds — see
    /// `DriveMetrics.averageSpeed`.
    private var avgSpeed: Double {
        DriveMetrics.averageSpeed(distanceMeters: drive.distanceMeters,
                                  durationSeconds: drive.durationSeconds)
    }

    // MARK: - Traces

    /// Speed over time, and the derivative of speed over time.
    ///
    /// Two charts rather than one with two scales: speed in mph and m/s² on a
    /// shared axis would be a chart you have to decode, and the whole point of
    /// plotting acceleration under speed is seeing the braking line up against
    /// the corner it went into. They share the x-axis, so one drag scrubs both.
    private var tracesPanel: some View {
        VStack(spacing: 6) {
            speedChart
            accelChart
            readout
            if let onDone { doneButton(onDone) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }

    /// The way out of a finished drive.
    ///
    /// Full-width and in the accent colour because it is the only other thing on
    /// this screen you can press, and the drive it closes is over — nothing here
    /// is going to start recording.
    private func doneButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Done")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.background)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 2)
    }

    private var speedChart: some View {
        Chart {
            ForEach(series, id: \.t) { p in
                AreaMark(x: .value("Time", p.t), y: .value("Speed", displaySpeed(p.speed)))
                    .foregroundStyle(.linearGradient(
                        colors: [Theme.accent.opacity(0.45), Theme.accent.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.t), y: .value("Speed", displaySpeed(p.speed)))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.catmullRom(alpha: 0.2))
            }
            scrubMarks(y: scrubbed.map { displaySpeed($0.speed) })
        }
        .chartYAxis { axisMarks }
        .chartXAxis { timeAxis }
        .chartOverlay { proxy in scrubGesture(proxy) }
        .chartLegend(.hidden)
        .frame(maxHeight: .infinity)
    }

    /// d(speed)/dt, as bars coloured by sign. Braking below the axis is the
    /// reason to look at this chart, and one colour for both halves would hide
    /// which is which.
    private var accelChart: some View {
        Chart {
            ForEach(series, id: \.t) { p in
                BarMark(x: .value("Time", p.t), y: .value("Accel", displayAccel(p.accel)))
                    .foregroundStyle(p.accel >= 0 ? Theme.accelerating : Theme.braking)
            }
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Theme.textTertiary.opacity(0.5))
            scrubMarks(y: scrubbed.map { displayAccel($0.accel) })
        }
        .chartYAxis { axisMarks }
        .chartXAxis { timeAxis }
        .chartOverlay { proxy in scrubGesture(proxy) }
        .chartLegend(.hidden)
        .frame(maxHeight: .infinity)
    }

    /// Dark-theme axis: SwiftUI's defaults are tuned for white, and on this
    /// background the grid lines and labels wash out.
    @AxisContentBuilder
    private var axisMarks: some AxisContent {
        AxisMarks(position: .leading) { _ in
            AxisGridLine().foregroundStyle(Theme.textTertiary.opacity(0.25))
            AxisValueLabel().foregroundStyle(Theme.textTertiary)
        }
    }

    @AxisContentBuilder
    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(Theme.textTertiary.opacity(0.12))
            AxisValueLabel {
                if let seconds = value.as(Double.self) {
                    Text(formattedTime(seconds)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    /// What both charts draw while scrubbing: a vertical line, plus a dot at the
    /// value in the chart's own units. Nothing is drawn when nothing is selected.
    @ChartContentBuilder
    private func scrubMarks(y: Double?) -> some ChartContent {
        if let y, let scrubTime {
            RuleMark(x: .value("Scrub", scrubTime))
                .foregroundStyle(Theme.textPrimary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            PointMark(x: .value("Scrub", scrubTime), y: .value("Scrubbed", y))
                .foregroundStyle(Theme.textPrimary)
                .symbolSize(40)
        }
    }

    /// The series point nearest the scrub, so the readout can show the same
    /// values the charts are marking.
    private var scrubbed: DriveMetrics.Point? {
        guard let scrubTime else { return nil }
        return series.min { abs($0.t - scrubTime) < abs($1.t - scrubTime) }
    }

    /// The values under the finger, or a hint at what to do when idle.
    private var readout: some View {
        HStack(spacing: 12) {
            if let p = scrubbed {
                readoutItem("SPEED", String(format: "%.0f", displaySpeed(p.speed)),
                            settings.units.symbol, Theme.accent)
                readoutItem("ACCEL", String(format: "%+.1f", displayAccel(p.accel)), "g",
                            p.accel >= 0 ? Theme.accelerating : Theme.braking)
                readoutItem("AT", formattedTime(p.t), "", Theme.textSecondary)
            } else {
                Text("Drag across the charts to read a moment")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
    }

    private func readoutItem(_ label: String, _ value: String,
                             _ unit: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
            if !unit.isEmpty {
                Text(unit).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            Text(label).font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
        }
    }

    /// Turns a drag in chart coordinates into a time, published so both charts
    /// mark the same instant. The `plotFrame` inset matters: without it the
    /// touch is measured from the chart's edge and every value is skewed by the
    /// width of the y-axis labels.
    @ViewBuilder
    private func scrubGesture(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let x = value.location.x - geo[plotFrame].origin.x
                        guard let t: Double = proxy.value(atX: x) else { return }
                        scrubTime = min(max(t, 0), max(series.last?.t ?? 0, 0))
                    }
                    .onEnded { _ in scrubTime = nil })
        }
    }

    /// m/s → display units, through the same conversion the rest of the app uses.
    private func displaySpeed(_ mps: Double) -> Double { settings.units.speedValue(mps) }

    /// m/s² → g, the unit every other force figure in the app is already in.
    private func displayAccel(_ mps2: Double) -> Double { mps2 / 9.80665 }

    // MARK: - G diagram

    /// Longitudinal against lateral acceleration, off the accelerometer rather
    /// than off the speed derivative. A diagnostic, and it costs a full screen
    /// to read, so it is not one of the three panels.
    private var gDiagramSheet: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Chart(drive.samples, id: \.t) { s in
                    PointMark(x: .value("Lateral", Double(s.lateralG)),
                              y: .value("Longitudinal", Double(s.forwardG)))
                        .foregroundStyle(Theme.accent.opacity(0.7))
                        .symbolSize(8)
                }
                .chartXScale(domain: -1.5...1.5)
                .chartYScale(domain: -1.5...1.5)
                .chartXAxis { axisMarks }
                .chartYAxis { axisMarks }
                .chartLegend(.hidden)
                .overlay(alignment: .center) {
                    Circle().stroke(Theme.textTertiary.opacity(0.3), lineWidth: 1)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .background(Theme.background)
            .navigationTitle("G diagram")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func formattedTime(_ t: TimeInterval) -> String {
        let t = max(0, t)
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

/// One number on the stats panel: the value large, the unit beside it, and the
/// label underneath. The unit is its own text rather than part of the value so
/// the digits stay monospaced and the unit can be recoloured or dropped without
/// touching the number.
struct StatTile: View {
    let label: String
    let value: String
    var unit: String = ""
    var tint: Color = Theme.textPrimary
    /// The smaller size used in the third-width G row, where a third of half a
    /// phone cannot fit a 20pt number and a two-word label.
    var compact = false

    /// The label stays unlabeled at the call site — `StatTile("TOP SPEED", value:
    /// …)` reads better than repeating the word `label` eight times — so the
    /// memberwise initializer is not usable here and this replaces it.
    init(_ label: String, value: String, unit: String = "",
         tint: Color = Theme.textPrimary, compact: Bool = false) {
        self.label = label
        self.value = value
        self.unit = unit
        self.tint = tint
        self.compact = compact
    }

    private var valueSize: CGFloat { compact ? 15 : 22 }
    private var labelSize: CGFloat { compact ? 8.5 : 9.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            // The panel's rows are stretched to share the quarter of the screen
            // the map has left, so the number and its label are centred in the
            // tile as a pair. Pinning them to the top would leave every tile with
            // a different amount of dead space under it and read as broken.
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: compact ? 9 : 10, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Text(label)
                .font(.system(size: labelSize, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                // "AVERAGE SPEED" is the longest label and the tile is a quarter
                // of a phone wide, so it has to shrink or truncate. Shrinking
                // reads better than an ellipsis on a stat you came to read.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 7 : 10)
        .padding(.vertical, compact ? 6 : 8)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A speed, as the headline number of the stats panel: the digits scaled to
/// fill the width of the tile, the unit centred beneath them, and a tinted wash
/// behind the whole thing so the tile reads as a filled object rather than a
/// number floating in an empty box.
///
/// The value is measured and then drawn at a size that fills the width, so a
/// 3-digit top speed and a 1-digit average both come out the same visual
/// weight — a fixed size would leave the slow tile looking empty and the fast
/// one cramped. The measurement pass runs at a fixed reference size, so the
/// scale factor is stable and the digits do not oscillate between redraws.
struct SpeedTile: View {
    let label: String
    let value: String
    let unit: String

    /// The size the value is measured at, and the range the drawn size is
    /// allowed to land in. The cap keeps a two-digit number in a tall tile from
    /// growing absurdly large; the floor keeps a narrow tile legible.
    private static let referenceSize: CGFloat = 100
    private static let minSize: CGFloat = 18
    private static let maxSize: CGFloat = 44

    /// How much of the tile's width the digits are allowed to take. Not 1.0:
    /// the drawn width and the measured width disagree by a fraction of a point
    /// once hinting and rounding are applied, and a number sized to exactly
    /// 100% is therefore a number that truncates.
    private static let fill: CGFloat = 0.9

    @State private var valueWidth: CGFloat = 0

    /// The label stays unlabeled at the call site — `SpeedTile("TOP SPEED",
    /// value: …)` reads better than repeating the word `label` — so the
    /// memberwise initializer is not usable here and this replaces it.
    init(_ label: String, value: String, unit: String = "") {
        self.label = label
        self.value = value
        self.unit = unit
    }

    /// The drawn font size, from the measured width of the value at the
    /// reference size. Zero until the first measurement lands, in which case
    /// the cap is used and the tile simply redraws a moment later.
    private func fontSize(for availableWidth: CGFloat) -> CGFloat {
        guard valueWidth > 0, availableWidth > 0 else { return Self.maxSize }
        let scaled = Self.referenceSize * (availableWidth * Self.fill) / valueWidth
        return min(Self.maxSize, max(Self.minSize, scaled))
    }

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 10
            let available = max(0, geo.size.width - inset * 2)
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                // The number is measured off-screen rather than with a
                // `GeometryReader` around the drawn text, which would feed its
                // own size back into the scale factor and oscillate.
                Text(value)
                    .font(.system(size: fontSize(for: available),
                                  weight: .bold,
                                  design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    // The size is computed to fit, so this should never engage.
                    // It is here so that a value too wide for even the floor size
                    // shrinks instead of truncating to an ellipsis — a speed
                    // reading as "…" is worse than a small one.
                    .minimumScaleFactor(0.5)
                    .background(alignment: .leading) { valueProbe }
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, inset)
            .padding(.vertical, 8)
            // A vertical wash so the tile is a filled block of colour rather
            // than an outlined empty one; strongest at the top where the
            // label sits, fading out under the number.
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.20),
                                                   Theme.accent.opacity(0.05)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.accent.opacity(0.30), lineWidth: 1)
            }
        }
        .onPreferenceChange(ValueWidthKey.self) { valueWidth = $0 }
    }

    /// An invisible copy of the value at the reference size, reporting its
    /// width. Hidden text still lays out, so this costs a measure and no draw.
    private var valueProbe: some View {
        Text(value)
            .font(.system(size: Self.referenceSize, weight: .bold, design: .rounded))
            .monospacedDigit()
            .fixedSize()
            .opacity(0)
            .background {
                GeometryReader { probe in
                    Color.clear.preference(key: ValueWidthKey.self, value: probe.size.width)
                }
            }
    }
}

/// The measured width of a `SpeedTile`'s value at its reference size.
private struct ValueWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
