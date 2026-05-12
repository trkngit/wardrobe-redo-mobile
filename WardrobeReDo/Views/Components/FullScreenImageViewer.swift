import SwiftUI
import Kingfisher

/// Build 18 — fullscreen image viewer for wardrobe item photos.
///
/// Triggered from `ItemDetailView` when the user taps the
/// large hero image. User-reported gap: before this, the photo
/// was a static letterbox with no way to see the full uncropped
/// shot (especially relevant for multi-garment captures where
/// the per-item bounding box dims most of the image).
///
/// Interactions:
///   - Pinch to zoom (1x – 4x). State carries between gestures
///     so a second pinch picks up where the last one ended.
///   - Drag to pan when zoomed.
///   - Drag-down at 1x to dismiss (with rubber-band + opacity
///     fade so the gesture feels coupled to the close animation).
///   - Tap the X button to dismiss.
///   - Double-tap to toggle between 1x and 2.5x at the tap point.
///
/// Lifetime: presented via `.fullScreenCover(isPresented:)` so the
/// system handles the slide-up / slide-down animation. Pinch /
/// drag state is local; nothing persists across presentations.
struct FullScreenImageViewer: View {
    let url: URL?
    @Binding var isPresented: Bool

    // Zoom state — `currentScale` is what's rendered; `gestureScale`
    // is the multiplier from the active pinch. We multiply them so
    // each gesture starts from the prior committed scale.
    @State private var currentScale: CGFloat = 1.0
    @State private var gestureScale: CGFloat = 1.0

    // Pan state — same dual-state pattern as scale.
    @State private var currentOffset: CGSize = .zero
    @State private var gestureOffset: CGSize = .zero

    // Drag-to-dismiss state. Tracked separately from `currentOffset`
    // so panning a zoomed-in image doesn't accidentally trigger the
    // dismiss animation.
    @State private var dismissOffset: CGFloat = 0

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 4.0
    private let dismissThreshold: CGFloat = 120

    var body: some View {
        ZStack {
            // Background dims along with the dismiss drag — couples
            // the gesture to the close animation so it feels like
            // the user is "pulling the photo down" rather than
            // triggering an unrelated dismiss event.
            Color.black
                .ignoresSafeArea()
                .opacity(backgroundOpacity)

            KFImage(url)
                .placeholder {
                    ProgressView()
                        .tint(.white)
                }
                .resizable()
                .scaledToFit()
                .scaleEffect(currentScale * gestureScale)
                .offset(combinedOffset)
                .gesture(magnifyGesture)
                .simultaneousGesture(panGesture)
                .gesture(dismissGesture)
                .onTapGesture(count: 2, perform: handleDoubleTap)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        HapticManager.light()
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.trailing, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.sm)
                    .accessibilityLabel("Close image viewer")
                }
                Spacer()
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
    }

    // MARK: - Derived state

    /// Background dims as the user drags down, from 1.0 at rest to
    /// 0.4 at the dismiss threshold. Stays opaque while zoomed.
    private var backgroundOpacity: Double {
        guard currentScale == 1.0 else { return 1.0 }
        let progress = min(abs(dismissOffset) / dismissThreshold, 1.0)
        return 1.0 - (progress * 0.6)
    }

    private var combinedOffset: CGSize {
        CGSize(
            width: currentOffset.width + gestureOffset.width,
            height: currentOffset.height + gestureOffset.height + dismissOffset
        )
    }

    // MARK: - Gestures

    /// Pinch-to-zoom. The clamp on commit keeps us inside
    /// [minScale, maxScale]; the per-gesture multiplier means a
    /// pinch that would overshoot doesn't snap visually mid-gesture.
    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                gestureScale = value
            }
            .onEnded { _ in
                let combined = (currentScale * gestureScale).clamped(to: minScale...maxScale)
                currentScale = combined
                gestureScale = 1.0
                // Reset pan if zoomed back out — otherwise the image
                // could end up offset off-screen at 1x.
                if currentScale == 1.0 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        currentOffset = .zero
                    }
                }
            }
    }

    /// Pan only when zoomed past 1x. Below that the dismiss gesture
    /// owns vertical drag so the two don't conflict.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard currentScale > 1.0 else { return }
                gestureOffset = value.translation
            }
            .onEnded { _ in
                guard currentScale > 1.0 else { return }
                currentOffset.width += gestureOffset.width
                currentOffset.height += gestureOffset.height
                gestureOffset = .zero
            }
    }

    /// Drag-down-at-1x dismisses. Above the threshold we close;
    /// below it we spring back. Only active at 1x so panning a
    /// zoomed image isn't hijacked.
    private var dismissGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard currentScale == 1.0 else { return }
                // Only downward drag dismisses; upward returns 0.
                dismissOffset = max(0, value.translation.height)
            }
            .onEnded { _ in
                guard currentScale == 1.0 else { return }
                if dismissOffset > dismissThreshold {
                    HapticManager.light()
                    isPresented = false
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    /// Double-tap toggle: 1x → 2.5x → 1x. We don't center on the
    /// tap point (that requires the rendered image rect, which is
    /// expensive to compute here) — instead 2.5x lands centered
    /// and the user pans from there.
    private func handleDoubleTap() {
        HapticManager.light()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            if currentScale > 1.0 {
                currentScale = 1.0
                currentOffset = .zero
            } else {
                currentScale = 2.5
            }
        }
    }
}

// MARK: - Comparable clamp helper

private extension Comparable {
    /// Tiny helper since SwiftUI numerics use this pattern often
    /// enough to be worth a one-liner. Not extracted to a shared
    /// utility because exactly one file needs it today.
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
