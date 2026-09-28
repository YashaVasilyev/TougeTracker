import SwiftUI

/// A lightweight toast that auto-dismisses after ~2 s.
struct ToastModifier: ViewModifier {
    @Binding var item: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let text = item {
                    Text(text)
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(radius: 2)
                        .transition(.move(edge: .top))
                        .padding(.top, 8)
                }
            }
            .animation(.easeOut(duration: 0.2), value: item)
            .onChange(of: item) { _ in
                if item != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { item = nil }
                }
            }
    }
}

extension View {
    func toast(_ item: Binding<String?>) -> some View {
        modifier(ToastModifier(item: item))
    }
}
