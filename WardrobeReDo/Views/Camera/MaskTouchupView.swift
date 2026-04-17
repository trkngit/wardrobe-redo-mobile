import PencilKit
import SwiftUI
import UIKit

/// Post-extraction editor that lets the user refine a Vision (Phase 1)
/// or SAM2 (Phase 3) mask. Shows the masked image over a checkerboard
/// so transparent regions are obvious, plus a PencilKit canvas where
/// the user brushes in missing areas (Add mode) or brushes out extras
/// (Erase mode). "Smart re-crop" asks the caller to re-run extraction;
/// "Done" composites the strokes into the final image and returns.
struct MaskTouchupView: View {
    let sourceImage: UIImage
    let initialMaskedImage: UIImage
    var onDone: (UIImage) -> Void
    var onSmartRecrop: () -> Void
    var onCancel: () -> Void

    enum BrushMode: String, CaseIterable, Identifiable {
        case add, erase
        var id: String { rawValue }
        var displayName: String { self == .add ? "Add" : "Erase" }
        var systemImage: String { self == .add ? "plus.circle.fill" : "minus.circle.fill" }
        var strokeColor: UIColor { self == .add ? .systemGreen : .systemRed }
    }

    @State private var brushMode: BrushMode = .add
    @State private var additiveDrawing = PKDrawing()
    @State private var subtractiveDrawing = PKDrawing()

    var body: some View {
        NavigationStack {
            ZStack {
                Color(Theme.Colors.background).ignoresSafeArea()

                VStack(spacing: Theme.Spacing.md) {
                    GeometryReader { geo in
                        ZStack {
                            CheckerboardBackground()
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))

                            let canvasRect = aspectFitRect(
                                imageSize: initialMaskedImage.size,
                                in: geo.size
                            )

                            Image(uiImage: initialMaskedImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: canvasRect.width, height: canvasRect.height)
                                .position(x: canvasRect.midX, y: canvasRect.midY)

                            PKCanvasRepresentable(
                                drawing: currentDrawingBinding,
                                toolColor: brushMode.strokeColor,
                                toolWidth: brushStrokeWidth(for: canvasRect.size)
                            )
                            .frame(width: canvasRect.width, height: canvasRect.height)
                            .position(x: canvasRect.midX, y: canvasRect.midY)
                            .opacity(0.55)
                        }
                    }
                    .frame(maxHeight: .infinity)

                    brushPicker
                    actionRow
                }
                .padding(Theme.Spacing.md)
            }
            .navigationTitle("Fix mask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", action: onCancel)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Done", action: commit)
                }
            }
        }
    }

    // MARK: - Bindings

    private var currentDrawingBinding: Binding<PKDrawing> {
        switch brushMode {
        case .add: return $additiveDrawing
        case .erase: return $subtractiveDrawing
        }
    }

    // MARK: - Subviews

    private var brushPicker: some View {
        Picker("Brush", selection: $brushMode) {
            ForEach(BrushMode.allCases) { mode in
                Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                switch brushMode {
                case .add: additiveDrawing = PKDrawing()
                case .erase: subtractiveDrawing = PKDrawing()
                }
            } label: {
                Label("Clear \(brushMode.displayName.lowercased())", systemImage: "arrow.uturn.backward")
                    .font(Theme.Fonts.bodySmall.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.sm)
            }
            .buttonStyle(.bordered)
            .tint(Color(Theme.Colors.textSecondary))

            Button(action: onSmartRecrop) {
                Label("Smart re-crop", systemImage: "wand.and.stars")
                    .font(Theme.Fonts.bodySmall.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.sm)
            }
            .buttonStyle(.bordered)
            .tint(Color(Theme.Colors.primary))
        }
    }

    // MARK: - Commit

    private func commit() {
        let result = MaskBrushComposer.compose(
            source: sourceImage,
            initialMasked: initialMaskedImage,
            additive: additiveDrawing,
            subtractive: subtractiveDrawing
        )
        onDone(result)
    }

    // MARK: - Layout helpers

    /// Returns the centered rect that aspect-fits `imageSize` into `container`.
    /// Keeps the PKCanvasView aligned with the image on the checker background.
    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let widthRatio = container.width / imageSize.width
        let heightRatio = container.height / imageSize.height
        let ratio = min(widthRatio, heightRatio)
        let fittedSize = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        let origin = CGPoint(
            x: (container.width - fittedSize.width) / 2,
            y: (container.height - fittedSize.height) / 2
        )
        return CGRect(origin: origin, size: fittedSize)
    }

    /// Larger brush when the canvas is small so the user isn't trying
    /// to paint with a 2-pixel pen on a thumbnail. Clamped sensibly.
    private func brushStrokeWidth(for canvasSize: CGSize) -> CGFloat {
        let shortest = min(canvasSize.width, canvasSize.height)
        return min(40, max(12, shortest * 0.05))
    }
}

// MARK: - PKCanvas Representable

/// Thin `UIViewRepresentable` around `PKCanvasView`. Stores strokes in
/// the bound `PKDrawing`; consumer (MaskTouchupView) swaps the binding
/// when the user toggles brush mode so each mode gets its own drawing.
struct PKCanvasRepresentable: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var toolColor: UIColor
    var toolWidth: CGFloat

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawing = drawing
        canvas.tool = PKInkingTool(.pen, color: toolColor, width: toolWidth)
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if uiView.drawing != drawing {
            uiView.drawing = drawing
        }
        uiView.tool = PKInkingTool(.pen, color: toolColor, width: toolWidth)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let drawing: Binding<PKDrawing>

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }
    }
}

// MARK: - Checkerboard background

/// Subtle alternating-tone background that makes transparent pixels in
/// the masked image obvious. Gray/white 8-pt checkers.
struct CheckerboardBackground: View {
    var tile: CGFloat = 8
    var dark: Color = Color.gray.opacity(0.3)
    var light: Color = Color.white.opacity(0.15)

    var body: some View {
        Canvas { ctx, size in
            let cols = Int(ceil(size.width / tile))
            let rows = Int(ceil(size.height / tile))
            for row in 0..<rows {
                for col in 0..<cols {
                    let isDark = (row + col).isMultiple(of: 2)
                    let rect = CGRect(
                        x: CGFloat(col) * tile,
                        y: CGFloat(row) * tile,
                        width: tile,
                        height: tile
                    )
                    ctx.fill(Path(rect), with: .color(isDark ? dark : light))
                }
            }
        }
    }
}

// MARK: - Mask composition

/// Takes the brush strokes drawn by the user in MaskTouchupView and
/// composites them against the current masked image to produce an
/// updated masked image. The result preserves the alpha channel — the
/// downstream color extractor keeps sampling only the foreground.
///
/// Algorithm:
///   1. Paint the current masked image as the base (holes = transparent).
///   2. For additive strokes: clip to the stroke footprint, then draw
///      the source image in those clipped regions. `destinationOver` is
///      not used because we want strokes to fully reveal source pixels
///      even where the destination already has partial alpha.
///   3. For subtractive strokes: use `destinationOut` blend mode, which
///      treats stroke alpha as an eraser — wherever strokes have alpha,
///      the destination alpha is multiplied by (1 - strokeAlpha).
enum MaskBrushComposer {
    static func compose(
        source: UIImage,
        initialMasked: UIImage,
        additive: PKDrawing,
        subtractive: PKDrawing
    ) -> UIImage {
        let size = initialMasked.size
        let rect = CGRect(origin: .zero, size: size)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = initialMasked.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            let cg = ctx.cgContext

            // 1. Base: draw the current masked image
            initialMasked.draw(in: rect)

            // 2. Reveal source where additive strokes exist
            if !additive.strokes.isEmpty,
               let maskCG = clipMask(from: additive, size: size, scale: initialMasked.scale) {
                cg.saveGState()
                // CGContext.clip(to:mask:) treats dark pixels in the mask
                // as "draw through" — see `clipMask` for how we produce
                // a DeviceGray white-on-black mask from the PKDrawing.
                cg.clip(to: rect, mask: maskCG)
                source.draw(in: rect)
                cg.restoreGState()
            }

            // 3. Erase where subtractive strokes exist
            if !subtractive.strokes.isEmpty {
                let strokeImage = subtractive.image(from: rect, scale: initialMasked.scale)
                strokeImage.draw(in: rect, blendMode: .destinationOut, alpha: 1)
            }
        }
    }

    /// Convert a PKDrawing into a single-channel grayscale image suitable
    /// for `CGContext.clip(to:mask:)`. Transparent regions become white
    /// (don't-draw-through); stroke regions become dark (draw-through).
    private static func clipMask(
        from drawing: PKDrawing,
        size: CGSize,
        scale: CGFloat
    ) -> CGImage? {
        let rect = CGRect(origin: .zero, size: size)
        let strokeImage = drawing.image(from: rect, scale: scale)
        guard let strokeCG = strokeImage.cgImage else { return nil }

        let width = strokeCG.width
        let height = strokeCG.height
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(strokeCG, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

#Preview {
    if let placeholder = UIImage(systemName: "tshirt")?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal) {
        MaskTouchupView(
            sourceImage: placeholder,
            initialMaskedImage: placeholder,
            onDone: { _ in },
            onSmartRecrop: {},
            onCancel: {}
        )
    }
}
