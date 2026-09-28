import SwiftUI

struct PacenoteCardView: View {
    let current: String?
    let next: [String]
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let current {
                Text(current)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else if !next.isEmpty {
                Text(next.first ?? "")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Text("No pacenotes — free drive")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }

            if let current {
                ProgressView(value: progress)
                    .progressViewStyle(.linear).tint(.white.opacity(0.6))
            }

            ForEach(Array(next.prefix(2).enumerated()), id: \.offset) { _, text in
                Text(text)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}
