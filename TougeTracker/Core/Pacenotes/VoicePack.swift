import Foundation

/// The recorded co-driver clips that ship in the app bundle, and the rule for
/// turning a written pacenote call into them.
///
/// A call like "into three right" is a rally co-driver's stock phrase, and a
/// rally pack has it recorded as a single take. Speaking the recorded clip
/// instead of reading the words aloud is the difference between a co-driver and
/// a phone reading a list.
///
/// The pack is a rally vocabulary, so it is wider than the app's but not
/// identical to it: it records `into` for severities one to five only, and
/// `followed by` from two up. Anything missing falls back to the nearest
/// equivalent rather than going silent — a slightly wrong clip still tells the
/// driver to turn, and silence tells them nothing.
public struct VoicePack {

    /// Clip names held by the pack, without the `.wav` extension.
    private let available: Set<String>
    private let distances: [Int]

    /// The pack as bundled, or nil when it is not present.
    ///
    /// Nil is a supported state, not an error: the app falls back to the system
    /// voice, and the simulator runs with no pack at all.
    public static func bundled(in bundle: Bundle = .main) -> VoicePack? {
        guard let names = Self.clipNames(in: bundle), !names.isEmpty else { return nil }
        return VoicePack(available: names)
    }

    /// Every clip in the bundle, at the top level where the pack lands.
    ///
    /// The app bundles AAC (`.m4a`), which is a fraction of the size of the
    /// recorded masters. WAV is still accepted so a build made straight from
    /// the masters works too.
    static func clipNames(in bundle: Bundle) -> Set<String>? {
        var names: Set<String> = []
        for ext in ["m4a", "wav"] {
            for url in bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
                names.insert(URL(fileURLWithPath: url.path)
                    .deletingPathExtension().lastPathComponent)
            }
        }
        return names.isEmpty ? nil : names
    }

    /// The bundle URL for a clip, whichever format it shipped as.
    static func url(forClip name: String, in bundle: Bundle = .main) -> URL? {
        for ext in ["m4a", "wav"] {
            if let url = bundle.url(forResource: name, withExtension: ext) { return url }
        }
        return nil
    }

    init(available: Set<String>) {
        self.available = available
        self.distances = available
            .filter { $0.hasPrefix("Dist") && $0.dropFirst(4).allSatisfy(\.isNumber) }
            .compactMap { Int($0.dropFirst(4)) }
            .sorted()
    }

    // MARK: - Vocabulary

    private static let grades = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "hairpin": "HP", "square": "Square", "flat": "Flat",
    ]
    private static let directions = ["left": "Left", "right": "Right"]

    /// The recorded warnings, by the word they are written with.
    ///
    /// Spelled out rather than derived from `RoadFeature` so the pack stays a
    /// list of clips it actually holds: a feature the pack has no take for falls
    /// out here and is read by the system voice instead.
    private static let warnings = ["stop sign", "traffic lights", "give way",
                                   "t junction", "crossroads", "merge", "roundabout"]

    // MARK: - Lookup

    /// The clips for one whole call, in the order they are spoken. Empty when
    /// nothing in the call can be spoken, which asks the caller to fall back.
    public func clips(for phrase: String) -> [String] {
        phrase.split(separator: ", ", omittingEmptySubsequences: true).flatMap { item in
            let text = item.trimmingCharacters(in: .whitespaces)
            if text.allSatisfy(\.isNumber), let metres = Int(text) {
                return [nearestDistance(to: metres)].compactMap { $0 }
            }
            // A junction or a stop sign is one clip, and the pacenote parse below
            // would reject it for having no severity and no direction in it.
            if let warning = warning(for: text) { return warning }
            guard let parsed = parse(text) else { return [] }
            return clips(connector: parsed.connector, grade: parsed.grade,
                         direction: parsed.direction, modifier: parsed.modifier,
                         trend: parsed.trend)
        }
    }

    private func clips(connector: String?, grade: String,
                       direction: String, modifier: String?, trend: String?) -> [String] {
        var tail = modifier.flatMap { available.contains($0) ? [$0] : nil } ?? []
        // Said after the corner, and after the length: "three left long tightens".
        if let trend, available.contains(trend) { tail.append(trend) }
        var spoken: [String]

        switch connector {
        case "into":
            // A single "into" take exists only up to five. Beyond that, any
            // linking clip does: "and six right" is better than saying "into"
            // and the severity as two unrelated clips.
            spoken = first("Into-\(direction)\(grade)", "And-\(direction)\(grade)")
                ?? (first("Into-\(direction)1") ?? []) + (first("\(direction)\(grade)") ?? [])
        case "and":
            // No "followed by one" in the pack. Saying it as "into one, one
            // left" keeps the link, which the driver needs to know the corners
            // are one movement; dropping the link would call two corners that
            // sound unrelated.
            spoken = first("And-\(direction)\(grade)")
                ?? (first("Into-\(direction)1") ?? []) + (first("\(direction)\(grade)") ?? [])
        default:
            spoken = first("\(direction)\(grade)") ?? (first("\(direction)1") ?? [])
        }

        // Nothing in the pack covers this, so say nothing and let the caller
        // read the call out with the system voice rather than going quiet.
        return spoken.isEmpty ? [] : spoken + tail
    }

    /// The clip for a road warning, or nil when the pack has not got one.
    private func warning(for text: String) -> [String]? {
        let lowered = text.lowercased()
        guard VoicePack.warnings.contains(lowered) else { return nil }
        let clip = RoadFeature.spokenWords[lowered] ?? "Caution"
        return available.contains(clip) ? [clip] : nil
    }

    /// The nearest recorded distance to `metres`, or nil if the pack has no
    /// distances at all.
    ///
    /// The pack records fifteen distances but the app calls one every ten
    /// metres, so most calls need one that was not recorded. Without this the
    /// co-driver says "square right" and never says how far.
    private func nearestDistance(to metres: Int) -> String? {
        guard !distances.isEmpty else { return nil }
        let exact = "Dist\(metres)"
        if available.contains(exact) { return exact }
        let nearest = distances.min {
            let da = abs($0 - metres), db = abs($1 - metres)
            return da == db ? $0 < $1 : da < db
        }
        return nearest.map { "Dist\($0)" }
    }

    /// Splits one phrase item into its parts, or nil if it is not a corner.
    private func parse(_ item: String) -> (connector: String?, grade: String,
                                           direction: String, modifier: String?,
                                           trend: String?)? {
        var rest = item
        var connector: String?
        for (prefix, name) in [("into ", "into"), ("followed by ", "and")] where rest.hasPrefix(prefix) {
            connector = name
            rest.removeFirst(prefix.count)
            break
        }
        // Trailing words are stripped in the order they appear, not in a fixed
        // order. "three left long tightens" does not end with " long", so a
        // fixed order finds neither suffix and the whole call fails to parse.
        var modifier: String?
        var trend: String?
        while true {
            if let (suffix, name) = [(" very long", "VeryLong"), (" long", "Long")]
                .first(where: { rest.hasSuffix($0.0) }), modifier == nil {
                modifier = name
                rest.removeLast(suffix.count)
            } else if let (suffix, name) = [(" tightens", "Tightens"), (" opens", "Opens")]
                .first(where: { rest.hasSuffix($0.0) }), trend == nil {
                // The pack has these as separate takes, so the call is stitched
                // from two clips rather than spoken as one phrase.
                trend = name
                rest.removeLast(suffix.count)
            } else {
                break
            }
        }
        let parts = rest.split(separator: " ")
        guard parts.count >= 2,
              let direction = VoicePack.directions[String(parts.last!)]
        else { return nil }
        guard let grade = VoicePack.grades[String(parts[0])] else { return nil }
        return (connector, grade, direction, modifier, trend)
    }

    private func first(_ names: String...) -> [String]? {
        for name in names where available.contains(name) { return [name] }
        return nil
    }
}
