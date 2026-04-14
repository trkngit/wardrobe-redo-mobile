import SwiftUI

// MARK: - Staggered Fade-In

/// Applies a fade-in + slide-up entrance animation with optional stagger delay.
struct StaggeredFadeIn: ViewModifier {
    let index: Int
    let baseDelay: Double
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 12)
            .animation(
                .easeOut(duration: 0.35).delay(Double(index) * baseDelay),
                value: isVisible
            )
            .onAppear { isVisible = true }
    }
}

extension View {
    /// Staggered entrance animation — each item fades in slightly after the previous.
    func staggeredFadeIn(index: Int, baseDelay: Double = 0.05) -> some View {
        modifier(StaggeredFadeIn(index: index, baseDelay: baseDelay))
    }
}

// MARK: - Scale Pop-In

/// Scales from 0 → 1 with a spring bounce. Good for badges, swatches, dots.
struct ScalePopIn: ViewModifier {
    let delay: Double
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isVisible ? 1 : 0)
            .opacity(isVisible ? 1 : 0)
            .animation(
                .spring(response: 0.4, dampingFraction: 0.6).delay(delay),
                value: isVisible
            )
            .onAppear { isVisible = true }
    }
}

extension View {
    /// Spring scale-in animation with configurable delay.
    func scalePopIn(delay: Double = 0) -> some View {
        modifier(ScalePopIn(delay: delay))
    }
}

// MARK: - Shimmer Loading

/// Placeholder shimmer effect for loading states.
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    gradient: Gradient(colors: [
                        .clear,
                        Color.white.opacity(0.3),
                        .clear,
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase)
                .mask(content)
            )
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5)
                        .repeatForever(autoreverses: false)
                ) {
                    phase = UIScreen.main.bounds.width
                }
            }
    }
}

extension View {
    /// Adds a shimmer loading animation overlay.
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Cross-Fade Transition

extension AnyTransition {
    /// Smooth cross-fade with slight scale for screen transitions.
    static var crossFade: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.98))
    }
}
