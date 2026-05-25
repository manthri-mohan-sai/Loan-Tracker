import SwiftUI

// MARK: - The "global key" equivalent

/// PreferenceKey carrying a rect in global (window) coordinates.
struct LogoAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Publishes this view's frame in global window coordinates.
/// Global coords don't shift based on safe area, NavigationStack, etc.,
/// so they're safe to compare across any view hierarchy.
struct PublishLogoAnchor: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: LogoAnchorKey.self,
                    value: geo.frame(in: .global)
                )
            }
        )
    }
}

extension View {
    /// Marks this view as the destination for the splash's rupee animation.
    func logoAnchor() -> some View {
        modifier(PublishLogoAnchor())
    }
}
