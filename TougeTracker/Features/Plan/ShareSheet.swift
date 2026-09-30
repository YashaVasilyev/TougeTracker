import SwiftUI
import UIKit

/// The system share sheet, which `UIActivityViewController` does not wrap for
/// SwiftUI. Passing the text directly shares it to notes, messages, mail and
/// anything else that takes text, which is what a call sheet is for.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
