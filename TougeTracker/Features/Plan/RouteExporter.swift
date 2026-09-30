import Foundation

/// Turns a route into something you can take with you.
///
/// The pacenotes already exist as text, and a call sheet is the thing a driver
/// actually wants on a phone with no signal, in a glovebox, or printed for a
/// passenger to read back. It is also the one output of the whole pipeline that
/// can be checked by eye without driving.
public enum RouteExporter {

    /// A call sheet: every corner, in order, with its distance along.
    ///
    /// Distances are what make it usable rather than decorative — a corner
    /// called without knowing where it is is trivia.
    public static func callSheet(road: TougeRoad, notes: [Pacenote],
                                 settings: AppSettings) -> String {
        var lines: [String] = []
        lines.append(road.displayName)
        lines.append("\(settings.units.distanceString(road.lengthMeters)) · \(notes.count) turns")
        lines.append(String(repeating: "-", count: 40))
        for (index, note) in notes.enumerated() {
            let where_ = settings.units.distanceString(note.startDist)
            let what = note.isStraight
                ? "\(settings.units.distanceString(note.length)) straight"
                : PacenoteGenerator.describe(grade: note.grade, dir: note.direction,
                                             format: settings.pacenoteFormat,
                                             isLong: note.isLong, isVeryLong: note.isVeryLong,
                                             isHairpin: note.grade == "HP")
                    + CornerTrend.spelling(note.trend)
            lines.append(String(format: "%2d.  %8@   %@", index + 1, where_ as NSString, what))
        }
        return lines.joined(separator: "\n")
    }

    /// GPX, for anything that reads tracks.
    public static func gpx(road: TougeRoad) -> String {
        let points = road.geoPoints
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="TougeTracker" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>\(xmlEscaped(road.displayName))</name><trkseg>

        """
        for point in points {
            out += String(format: "    <trkpt lat=\"%f\" lon=\"%f\"></trkpt>\n",
                          point.lat, point.lon)
        }
        out += """
          </trkseg></trk>
        </gpx>

        """
        return out
    }

    /// A file name that says what the route is, without anything a file system
    /// would object to.
    public static func fileName(for road: TougeRoad, pathExtension: String) -> String {
        let base = road.displayName
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = base.isEmpty ? "route" : base
        return "\(stem).\(pathExtension)"
    }

    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
