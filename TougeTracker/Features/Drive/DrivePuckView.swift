import SwiftUI

/// The position arrow, drawn the way a navigation app draws it: a solid
/// chevron in the accent colour, ringed in white so it stays readable over
/// both the pale road casings and the dark forest of a satellite-free standard
/// map, with a heading beam showing roughly where the car is pointed.
///
/// A plain dot — which is what this replaced — answers *where* and nothing else.
/// At the moment a car comes over a crest the dot is the only thing telling you
/// which way the road goes, and an arrow with a beam in front of it is the
/// difference between reading the corner and guessing at it.
struct DrivePuckView: View {
    /// Screen rotation in degrees clockwise from up. Driven by
    /// `NavCamera.puckRotation(bearing:cameraHeading:)`, which is 0 in
    /// heading-up so the arrow points up the screen, as it does in Maps.
    var rotationDegrees: Double

    /// Heading beam, shown when the car is actually pointing somewhere. Off at a
    /// standstill, where a beam sweeping about with a phone in a cup holder is
    /// noise rather than information.
    var showsBeam: Bool

    init(rotationDegrees: Double, showsBeam: Bool = true) {
        self.rotationDegrees = rotationDegrees
        self.showsBeam = showsBeam
    }

    var body: some View {
        ZStack {
            if showsBeam {
                beam
            }
            // The white underlay is a second, slightly larger arrow rather than a
            // stroke: a stroke on a dart puts half its width inside the shape and
            // eats the tip, which is the one part of it the eye actually uses.
            PuckArrowShape()
                .fill(Color.white)
                .frame(width: 22, height: 25)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            PuckArrowShape()
                .fill(Theme.accent)
                .frame(width: 17, height: 20)
        }
        .frame(width: 34, height: 34)
        // The arrow is anchored on the point it is pointing at, not on its
        // middle: a puck that sits *behind* the coordinate it marks reads as
        // being a car-length behind where the car is.
        .offset(y: -8)
        .rotationEffect(.degrees(rotationDegrees))
    }

    /// The cone in front of the arrow. Wider and longer than the arrow so it
    /// reads as "this way" rather than as part of the marker, and faint enough
    /// that the arrow stays the thing the eye lands on.
    private var beam: some View {
        PuckBeamShape()
            .fill(
                LinearGradient(colors: [Theme.accent.opacity(0.30), Theme.accent.opacity(0)],
                           startPoint: .bottom,
                           endPoint: .top)
            )
            .frame(width: 30, height: 34)
            .offset(y: -18)
    }
}

/// The Maps dart: a solid triangle with a shallow notch cut into its tail.
///
/// The notch is the whole subtlety. Cut it deep and the shape stops reading as
/// an arrow at all — it becomes a bat wing, or a checkmark, and at 40 px on a
/// phone the driver is left guessing which way it faces. Cut it shallow and the
/// barbs read as direction while the mass of the shape still reads as solid.
private struct PuckArrowShape: Shape {
    /// How far up the tail the notch reaches, as a fraction of the height. Just
    /// past halfway: enough to see, not enough to hollow it out.
    private var notchDepth: Double { 0.82 }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        // Wider than it is tall. A tall narrow triangle reads as a paper plane,
        // which is a different idea entirely — this is a direction indicator.
        let tip = CGPoint(x: w / 2, y: 0)
        let rightBarb = CGPoint(x: w, y: h)
        let notch = CGPoint(x: w / 2, y: h * notchDepth)
        let leftBarb = CGPoint(x: 0, y: h)

        var p = Path()
        p.move(to: leftBarb)
        p.addLine(to: tip)
        p.addLine(to: rightBarb)
        p.addLine(to: notch)
        p.closeSubpath()
        return p
    }
}

/// The heading cone: a wedge opening forward from the arrow's base.
private struct PuckBeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w / 2, y: 0))
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }
}
