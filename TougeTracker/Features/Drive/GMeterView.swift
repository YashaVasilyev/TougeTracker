import SwiftUI

/// A "gee-bubble" meter: the bubble sits inside a fixed track and moves
/// horizontally for lateral g (+right / −left) and vertically for longitudinal
/// g (+forward / −backward). A positive reading keeps the bubble toward the
/// corresponding edge; braking pushes it down, accelerating pulls it up.
struct GMeterView: View {
    let forwardG: Double   // + forward (accelerate), − brake
    let lateralG: Double   // + right,  − left

    private let maxG: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            Z3View(forward: forwardG, lateral: lateralG, maxG: maxG)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
        )
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The three-zone g-meter: neutral center, forward/accel up, lateral left/right,
/// brake down. Draws reference bands and a moving dot.
private struct Z3View: View {
    let forward: Double
    let lateral: Double
    let maxG: Double

    var body: some View {
        Color.clear.overlay(alignment: .center) {
            // background grid bands
            Rectangle().fill(Color.white.opacity(0.08))
                .frame(width: 50, height: 50)
            // bubble position: x = lateral, y = -forward (so accel is up)
            let x = max(-1, min(1, lateral / maxG)) * 45
            let y = max(-1, min(1, forward / maxG)) * 45
            Circle()
                .fill(Color.yellow)
                .frame(width: 16, height: 16)
                .offset(x: x, y: -y)
                .shadow(radius: 2)
        }
    }
}
