import SwiftUI

/// The app's dark palette, in one place.
///
/// The app is dark-only (see `UIUserInterfaceStyle` in `project.yml`), so these
/// are not adaptive colours — they are the only colours the app draws with, and
/// putting them here is what stops each view picking its own near-black and
/// having the panels disagree with one another.
///
/// The neutrals are blue-biased rather than grey: the accent is blue, and a
/// grey next to a saturated blue reads as dirty, while a blue surface under it
/// reads as one system. They stay dark enough to be read at night.
///
/// The chart series have their own entries because the speed trace and the
/// acceleration trace are read together, side by side, and have to stay
/// distinguishable from each other and from the chrome in both of them.
enum Theme {

    // MARK: - Surfaces

    /// The window background. Panels sit on top of it.
    static let background = Color(red: 0.043, green: 0.055, blue: 0.086)
    /// A card: the stat panel, the chart panel.
    static let surface = Color(red: 0.075, green: 0.094, blue: 0.141)
    /// A second level up, for a tile inside a card.
    static let surfaceRaised = Color(red: 0.118, green: 0.145, blue: 0.208)
    /// Hairlines between panels, and the edge of a card.
    static let border = Color(red: 0.42, green: 0.55, blue: 0.80).opacity(0.22)

    // MARK: - Text

    /// Headline numbers, and the primary label under them.
    static let textPrimary = Color(red: 0.93, green: 0.96, blue: 1.0)
    /// Units, captions, anything secondary.
    static let textSecondary = Color(red: 0.62, green: 0.71, blue: 0.85)
    /// Chart axis labels.
    static let textTertiary = Color(red: 0.45, green: 0.54, blue: 0.68)

    // MARK: - Data

    /// The accent, and the speed trace and driven line on the map. Blue: it is
    /// the one hue that stays legible against the dark map tiles underneath it,
    /// and it leaves red and green free for braking/accelerating and the start
    /// and finish markers — none of which can be given up to branding.
    static let accent = Color(red: 0.30, green: 0.56, blue: 0.98)
    /// Positive acceleration.
    static let accelerating = Color(red: 0.29, green: 0.80, blue: 0.55)
    /// Braking — the negative half of the same series.
    static let braking = Color(red: 0.95, green: 0.33, blue: 0.33)
    /// Where the run started.
    static let start = Color(red: 0.35, green: 0.82, blue: 0.62)
    /// Where it finished.
    static let finish = Color(red: 0.98, green: 0.35, blue: 0.35)

    /// A card's background plus its edge, so every panel is drawn the same way.
    static func card(_ radius: CGFloat = 14) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(surface)
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(border, lineWidth: 1)
            )
    }
}
