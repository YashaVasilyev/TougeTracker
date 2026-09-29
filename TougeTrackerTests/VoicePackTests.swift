import XCTest
@testable import TougeTracker

/// Covers turning a written co-driver call into recorded clips.
///
/// The names used here are the real ones in the bundled pack, so these tests
/// would fail if the mapping drifted away from what actually ships rather than
/// passing against a convenient fiction.
final class VoicePackTests: XCTestCase {

    private func pack() -> VoicePack {
        VoicePack(available: [
            "Left1", "Left2", "Left3", "Left4", "Left5", "Left6",
            "Right1", "Right2", "Right3", "Right4", "Right5", "Right6",
            "LeftHP", "RightHP", "LeftSquare", "RightSquare",
            "Into-Left1", "Into-Left2", "Into-Left3", "Into-Left4", "Into-Left5",
            "Into-Right1", "Into-Right2", "Into-Right3", "Into-Right4", "Into-Right5",
            "And-Left2", "And-Left6", "And-Right2", "And-Right6",
            "Long", "VeryLong",
            "Dist40", "Dist100", "Dist200", "Dist400",
        ])
    }

    func testCornerBecomesItsClip() {
        XCTAssertEqual(pack().clips(for: "three left"), ["Left3"])
        XCTAssertEqual(pack().clips(for: "hairpin right"), ["RightHP"])
    }

    func testLengthAppendsTheModifierAfterTheCorner() {
        XCTAssertEqual(pack().clips(for: "three left long"), ["Left3", "Long"])
        XCTAssertEqual(pack().clips(for: "six right very long"), ["Right6", "VeryLong"])
    }

    func testConnectorIsASingleRecordedClip() {
        // The whole point of the pack: "into three right" is one take.
        XCTAssertEqual(pack().clips(for: "into three right"), ["Into-Right3"])
        XCTAssertEqual(pack().clips(for: "followed by six right"), ["And-Right6"])
    }

    func testChainedCallPlaysInOrder() {
        XCTAssertEqual(pack().clips(for: "five left, into three right, 100"),
                       ["Left5", "Into-Right3", "Dist100"])
    }

    /// The pack records `into` up to five and `followed by` from two up, so the
    /// gaps have to be said as two clips rather than going quiet.
    func testMissingConnectorClipsFallBackToSomethingThatExists() {
        // "into six" is not recorded but "and six" is, and that is a true thing
        // to say — better than reading the connector and the severity as two
        // unrelated clips.
        XCTAssertEqual(pack().clips(for: "into six right"), ["And-Right6"])
        // "followed by one" is not recorded at all, so the link is made with an
        // "into one" clip and the severity spoken plainly.
        XCTAssertEqual(pack().clips(for: "followed by one left"),
                       ["Into-Left1", "Left1"])
    }

    /// A distance the pack never recorded must still be spoken. The regression
    /// this guards: the co-driver gave the corner and never said how far.
    func testUnrecordedDistanceUsesTheNearestRecorded() {
        XCTAssertEqual(pack().clips(for: "220"), ["Dist200"])
        XCTAssertEqual(pack().clips(for: "320"), ["Dist400"])
        XCTAssertEqual(pack().clips(for: "100"), ["Dist100"], "an exact clip is used as-is")
    }

    func testUnknownWordsProduceNothingSoTheCallerCanFallBack() {
        // Nothing recognised means the speaker should read the call out with the
        // system voice instead of staying silent.
        XCTAssertEqual(pack().clips(for: "caution, ice"), [])
    }

    /// With no pack there is nothing to play, and the speaker must fall back to
    /// reading the call out rather than naming clips that are not there.
    func testEmptyPackResolvesToNothingSoTheCallerFallsBack() {
        XCTAssertEqual(VoicePack(available: []).clips(for: "three left"), [])
        XCTAssertEqual(VoicePack(available: []).clips(for: "into three right"), [])
    }
}
