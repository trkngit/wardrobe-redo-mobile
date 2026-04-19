import CoreML
import Foundation
import Testing
import UIKit
@testable import WardrobeReDo

/// Unit tests for `AttributeClassifierService`, `MockAttributeClassifier`,
/// and the shared `AttributePrediction` payload.
///
/// Three seams are exercised:
///   1. **Mock behaviour.** `MockAttributeClassifier` is the production
///      fallback when no mlpackage is bundled — the pre-fill VM will
///      hit it in tests + previews. Needs to faithfully model
///      `.returnPrediction` and `.throwError`.
///   2. **Decode math.** `AttributeClassifierService.decode(prediction:)`
///      is pure — we build `MLDictionaryFeatureProvider`s by hand and
///      verify the argmax / confidence / threshold logic without
///      loading a live model.
///   3. **Graceful missing-model.** When the bundled model is absent,
///      `predict` throws `.modelLoadFailed` — callers wrap in `try?`
///      and fall through to rules-engine-only pre-fill.
///
/// All tests should stay fast (<50ms each) — no Core ML load, no
/// MLDiagnosticsStore writes.
@MainActor
struct AttributeClassifierServiceTests {

    // MARK: - AttributePrediction.empty

    @Test func emptyPredictionIsAllNilAndZero() {
        let prediction = AttributePrediction.empty
        #expect(prediction.texture == nil)
        #expect(prediction.textureConfidence == 0.0)
        #expect(prediction.fit == nil)
        #expect(prediction.fitConfidence == 0.0)
    }

    // MARK: - MockAttributeClassifier

    @Test func mockReturnsEmptyByDefault() async throws {
        let mock = MockAttributeClassifier()
        let prediction = try await mock.predict(crop: UIImage())
        #expect(prediction == .empty)
        #expect(mock.callCount == 1)
    }

    @Test func mockReturnsConfiguredPrediction() async throws {
        let expected = AttributePrediction(
            texture: .silk, textureConfidence: 0.91,
            fit: .oversized, fitConfidence: 0.77
        )
        let mock = MockAttributeClassifier(prediction: expected)

        let prediction = try await mock.predict(crop: UIImage())
        #expect(prediction == expected)
    }

    @Test func mockThrowsConfiguredError() async {
        let mock = MockAttributeClassifier(
            behavior: .throwError(.inferenceFailed(reason: "forced"))
        )

        await #expect(throws: AttributeClassifierError.inferenceFailed(reason: "forced")) {
            _ = try await mock.predict(crop: UIImage())
        }
    }

    @Test func mockSetBehaviorSwitchesMidTest() async throws {
        let mock = MockAttributeClassifier()
        let first = try await mock.predict(crop: UIImage())
        #expect(first == .empty)

        mock.setBehavior(.throwError(.modelLoadFailed(
            reason: "rotated out", modelPath: nil
        )))

        await #expect(throws: AttributeClassifierError.self) {
            _ = try await mock.predict(crop: UIImage())
        }
        #expect(mock.callCount == 2)
    }

    // MARK: - Decode: happy path

    @Test func decodeReturnsExpectedTextureAndFit() throws {
        // Texture: index 2 = .denim at 0.70; fit: index 5 = .cropped at 0.90
        let textureLogits = makeSoftmaxLogits(size: 15, peakIndex: 2, peakValue: 0.70)
        let fitLogits = makeSoftmaxLogits(size: 6, peakIndex: 5, peakValue: 0.90)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "texture_probs": MLFeatureValue(multiArray: textureLogits),
            "fit_probs": MLFeatureValue(multiArray: fitLogits)
        ])

        let prediction = AttributeClassifierService.decode(prediction: provider)

        #expect(prediction.texture == .denim)
        #expect(abs(prediction.textureConfidence - 0.70) < 0.01)
        #expect(prediction.fit == .cropped)
        #expect(abs(prediction.fitConfidence - 0.90) < 0.01)
    }

    // MARK: - Decode: confidence below enum-emit threshold

    @Test func decodeDropsTextureBelowEnumThreshold() throws {
        // 0.30 is below AttributeClassifierService.minEnumConfidence (0.35).
        let textureLogits = makeSoftmaxLogits(size: 15, peakIndex: 4, peakValue: 0.30)
        // Give fit a healthy prediction to prove the two heads decouple.
        let fitLogits = makeSoftmaxLogits(size: 6, peakIndex: 2, peakValue: 0.80)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "texture_probs": MLFeatureValue(multiArray: textureLogits),
            "fit_probs": MLFeatureValue(multiArray: fitLogits)
        ])

        let prediction = AttributeClassifierService.decode(prediction: provider)

        #expect(prediction.texture == nil,
                "Confidence below minEnumConfidence should suppress the enum case")
        #expect(prediction.textureConfidence > 0,
                "Confidence itself is still reported so higher layers can log it")
        #expect(prediction.fit == .regular,
                "fit head must not be affected by the texture head's low confidence")
    }

    // MARK: - Decode: confidence respected for UI pre-fill threshold

    @Test func decodeConfidenceRespectsPrefillThreshold() throws {
        // 0.75 is above enum threshold (0.35) but below pre-fill (0.80).
        // Service returns the case + confidence; the VM layer is what
        // refuses to pre-fill, not this service.
        let textureLogits = makeSoftmaxLogits(size: 15, peakIndex: 0, peakValue: 0.75)
        let fitLogits = makeSoftmaxLogits(size: 6, peakIndex: 0, peakValue: 0.75)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "texture_probs": MLFeatureValue(multiArray: textureLogits),
            "fit_probs": MLFeatureValue(multiArray: fitLogits)
        ])

        let prediction = AttributeClassifierService.decode(prediction: provider)

        #expect(prediction.texture == .cotton)
        #expect(prediction.fit == .oversized)
        #expect(AttributePrefill.shouldPrefill(prediction.textureConfidence) == false,
                "0.75 confidence must NOT clear the pre-fill bar (0.80)")
    }

    // MARK: - Decode: handles softmax vs raw logits

    @Test func decodeRunsSoftmaxOnRawLogits() throws {
        // Build raw logits [5, 2, 0, 0, 0, 0] for fit — stable softmax
        // should yield ~0.95 on index 0.
        let rawLogits = try MLMultiArray(shape: [1, 6], dataType: .float32)
        let values: [Float] = [5.0, 2.0, 0.0, 0.0, 0.0, 0.0]
        for (i, v) in values.enumerated() {
            rawLogits[[0, NSNumber(value: i)]] = NSNumber(value: v)
        }
        // Texture: pre-softmaxed, peak on index 7 = .knit.
        let textureProbs = makeSoftmaxLogits(size: 15, peakIndex: 7, peakValue: 0.88)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "texture_probs": MLFeatureValue(multiArray: textureProbs),
            "fit_logits": MLFeatureValue(multiArray: rawLogits)
        ])

        let prediction = AttributeClassifierService.decode(prediction: provider)

        #expect(prediction.texture == .knit)
        #expect(prediction.fit == .oversized)
        #expect(prediction.fitConfidence > 0.90,
                "Softmax over [5,2,0,0,0,0] should put >0.9 probability on index 0")
    }

    // MARK: - Decode: absent output keys

    @Test func decodeHandlesMissingOutputsGracefully() throws {
        let empty = try MLDictionaryFeatureProvider(dictionary: [:])
        let prediction = AttributeClassifierService.decode(prediction: empty)
        #expect(prediction == .empty)
    }

    // MARK: - Service: graceful missing-model fallback

    @Test func predictThrowsModelLoadFailedWhenNoModel() async {
        // Inject a loader that always returns nil — mirrors production
        // when the mlpackage hasn't shipped yet.
        let service = AttributeClassifierService(modelLoader: { nil })

        await #expect(throws: AttributeClassifierError.self) {
            _ = try await service.predict(crop: UIImage())
        }
    }

    @Test func prewarmIsIdempotentWhenModelMissing() async {
        let service = AttributeClassifierService(modelLoader: { nil })
        // Three calls must not crash and must not retry the loader
        // in a tight loop — the service's `modelLoadAttempted` flag
        // prevents hot-loop reloads on every call.
        await service.prewarm()
        await service.prewarm()
        await service.prewarm()
    }

    // MARK: - Label drift guards

    @Test func textureLabelsMatchEnumOrderAndCount() {
        // If a future TextureType case lands without an accompanying
        // training-side update, this test flags the drift at build time.
        #expect(AttributeClassifierService.textureLabels.count == TextureType.allCases.count,
                "textureLabels must cover every TextureType case — retrain the classifier if you added one")
        // Every enum value must appear at least once.
        let covered = Set(AttributeClassifierService.textureLabels)
        let expected = Set(TextureType.allCases)
        #expect(covered == expected,
                "textureLabels must be a permutation of TextureType.allCases")
    }

    @Test func fitLabelsMatchEnumOrderAndCount() {
        #expect(AttributeClassifierService.fitLabels.count == FitAttribute.allCases.count)
        let covered = Set(AttributeClassifierService.fitLabels)
        let expected = Set(FitAttribute.allCases)
        #expect(covered == expected)
    }

    // MARK: - Helpers

    /// Build a `[1, size]` Float32 MLMultiArray with a single peak at
    /// `peakIndex` carrying `peakValue`; the rest is distributed
    /// uniformly so the vector sums to 1.0 (so `argmaxSoftmax`'s
    /// "looks like probabilities" branch fires). Used by the decode
    /// tests so we can hand-pick an index + confidence in one line.
    private func makeSoftmaxLogits(size: Int, peakIndex: Int, peakValue: Float) -> MLMultiArray {
        let array = try! MLMultiArray(shape: [1, NSNumber(value: size)], dataType: .float32)
        let residual = (1.0 - peakValue) / Float(size - 1)
        for i in 0 ..< size {
            let v = (i == peakIndex) ? peakValue : residual
            array[[0, NSNumber(value: i)]] = NSNumber(value: v)
        }
        return array
    }
}
