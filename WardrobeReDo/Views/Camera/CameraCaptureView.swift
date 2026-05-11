// AVFoundation's capture primitives (AVCaptureSession, AVCapturePhotoOutput,
// AVCaptureVideoDataOutput) aren't yet annotated `Sendable`, so Xcode 16's
// Swift 6 checker rejects sending references to them into the Sendable
// closures we hand to `sessionQueue.async`. Apple's docs are clear these
// types are safe when all mutations route through a single queue — which
// this controller does — so `@preconcurrency` is the intended escape hatch
// until the SDK completes its audit.
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Permission states we surface to the SwiftUI layer. Combined with
/// `.notAvailable` for simulator / missing hardware, this gives the
/// caller enough information to fall back to the PhotosPicker flow.
enum CameraAuthorizationState: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case notAvailable  // simulator, or device has no back camera
}

/// Lifecycle of the live AVCaptureSession, surfaced to the overlay
/// alongside `CameraAuthorizationState`. This split matters because
/// "permission decision pending" and "session not yet running" are
/// different states that produce different HUD content — the overlay
/// must be able to tell them apart so a user tapping shutter during
/// the permission flight doesn't see a dead button without
/// explanation.
///
/// Transition to `.running` is driven externally by the SwiftUI
/// caller: the controller emits `.configuring` once permission is
/// granted, and the caller flips to `.running` when the
/// `BackgroundQualityMonitor` publishes its first non-`.unknown`
/// frame. This keeps AVFoundation lifecycle in the VC and "first
/// frame seen" in SwiftUI where it can drive view re-renders.
enum CameraSessionState: Sendable, Equatable {
    case configuring     // permission granted, session setup in flight on sessionQueue
    case running         // session.isRunning && first sample buffer received
    case stopped         // viewWillDisappear path
    case failed(String)  // input/output guard failed; payload for telemetry
}

/// Exposes imperative camera actions (shutter) to the SwiftUI layer
/// while keeping the UIViewController as the source of truth for
/// AVCapture lifecycle. The representable wires the weak ref; the
/// SwiftUI overlay calls `capture()` to fire the shutter.
@MainActor
final class CameraController {
    fileprivate weak var viewController: CameraCaptureViewController?

    func capture() {
        viewController?.capturePhoto()
    }
}

/// SwiftUI wrapper around a custom `UIViewController` that drives an
/// `AVCaptureSession`. The overlay (traffic-light HUD, shutter button,
/// cancel) is drawn in SwiftUI on top of this view by the caller so we
/// can keep this file focused on AVCapture lifecycle.
///
/// The caller provides a `BackgroundQualityMonitor` instance; this view
/// feeds each video frame into it via a capture bridge. On shutter tap,
/// the captured photo is orientation-normalized and passed back through
/// `onPhotoCaptured`.
struct CameraCaptureView: UIViewControllerRepresentable {
    let monitor: BackgroundQualityMonitor
    let controller: CameraController
    var onPhotoCaptured: (UIImage) -> Void
    var onAuthorizationChanged: (CameraAuthorizationState) -> Void
    var onSessionStateChanged: ((CameraSessionState) -> Void)? = nil
    var onCaptureFailed: ((String) -> Void)? = nil

    func makeUIViewController(context: Context) -> CameraCaptureViewController {
        let vc = CameraCaptureViewController()
        vc.monitor = monitor
        vc.onPhotoCaptured = onPhotoCaptured
        vc.onAuthorizationChanged = onAuthorizationChanged
        vc.onSessionStateChanged = onSessionStateChanged
        vc.onCaptureFailed = onCaptureFailed
        controller.viewController = vc
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraCaptureViewController, context: Context) {
        // No dynamic state — session lifecycle is owned by the controller.
    }
}

/// Imperative UIKit controller that owns the `AVCaptureSession`.
/// Kept separate from the SwiftUI `UIViewControllerRepresentable` so the
/// session survives SwiftUI re-renders and so we can handle delegate
/// callbacks cleanly.
final class CameraCaptureViewController: UIViewController {

    // MARK: - Inputs (set before viewDidLoad)

    // `monitor` is touched inside `sessionQueue.async` when we configure
    // the video output. Same reasoning as the other AVFoundation members
    // below — serialized by sessionQueue, so the Swift-6 actor isolation
    // check is safe to bypass.
    nonisolated(unsafe) weak var monitor: BackgroundQualityMonitor?
    var onPhotoCaptured: ((UIImage) -> Void)?
    var onAuthorizationChanged: ((CameraAuthorizationState) -> Void)?
    var onSessionStateChanged: ((CameraSessionState) -> Void)?
    var onCaptureFailed: ((String) -> Void)?

    // MARK: - Internals
    //
    // AVFoundation's capture primitives are the textbook use case for
    // `nonisolated(unsafe)` under Swift 6: they're thread-safe by design
    // *when* all mutations go through a single dedicated queue — which
    // `sessionQueue` enforces here. Without the marker, the compiler sees
    // a `@MainActor` view controller touching these properties from a
    // non-main dispatch block and rejects it.
    //
    // `qualityBridge` gets the same treatment because it's assigned
    // inside the same `sessionQueue.async { ... }` block, so its reads
    // and writes are already serialized on that queue.

    nonisolated(unsafe) private let session = AVCaptureSession()
    // `DispatchQueue` is already `Sendable`, so no `nonisolated(unsafe)`
    // marker is needed (Xcode 16 emits a warning when it's there).
    private let sessionQueue = DispatchQueue(label: "com.wardroberedo.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "com.wardroberedo.camera.video", qos: .userInitiated)
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let videoOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private var qualityBridge: BackgroundQualityCaptureBridge?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDelegate: PhotoCaptureDelegate?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPreview()
        checkAuthorization()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop the cancellation race: zero out callbacks BEFORE
        // dispatching the stop. A late-arriving `requestAccess`
        // completion or photo capture must not fire after the cover
        // has dismissed.
        onAuthorizationChanged = nil
        onSessionStateChanged?(.stopped)
        onSessionStateChanged = nil
        onCaptureFailed = nil
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        monitor?.cancel()
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    deinit {
        // Belt-and-suspenders cleanup if the VC is released without
        // viewWillDisappear firing (e.g. SwiftUI re-renders the
        // cameraCover under us). Drop the sample-buffer delegate so
        // any in-flight `processSampleBuffer` Task sees a nil
        // reference and bails. Don't touch session configuration from
        // deinit — it expects sessionQueue isolation that we can't
        // guarantee on the deallocation thread.
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        captureDelegate = nil
        qualityBridge = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - Authorization

    private func checkAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            onAuthorizationChanged?(.authorized)
            onSessionStateChanged?(.configuring)
            configureSession()
        case .notDetermined:
            onAuthorizationChanged?(.notDetermined)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.onAuthorizationChanged?(granted ? .authorized : .denied)
                    if granted {
                        self.onSessionStateChanged?(.configuring)
                        self.configureSession()
                    }
                }
            }
        case .denied, .restricted:
            onAuthorizationChanged?(.denied)
        @unknown default:
            onAuthorizationChanged?(.denied)
        }
    }

    // MARK: - Session wiring

    private func setupPreview() {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            // Input: back wide-angle camera when available, otherwise
            // the default video device for the current environment.
            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { [weak self] in
                    self?.onAuthorizationChanged?(.notAvailable)
                    self?.onSessionStateChanged?(.failed("No usable camera device"))
                }
                return
            }
            self.session.addInput(input)

            // Photo output — high-resolution still capture.
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.isHighResolutionCaptureEnabled = true
            }

            // Video data output — feeds BackgroundQualityMonitor.
            // NV12 (biplanar YUV full range) lets the monitor read the
            // Y plane directly without a color-space conversion.
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true

            if let monitor = self.monitor {
                let bridge = BackgroundQualityCaptureBridge(monitor: monitor)
                self.qualityBridge = bridge
                self.videoOutput.setSampleBufferDelegate(bridge, queue: self.videoOutputQueue)
            }
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }

            self.session.commitConfiguration()
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    // MARK: - Capture

    /// Called by the SwiftUI layer when the shutter button is tapped.
    /// Must be invoked on the main thread. Generates a medium-impact
    /// haptic synchronously on entry so the user gets immediate
    /// confirmation that the tap registered, even before AVFoundation
    /// returns the photo. Errors are propagated through
    /// `onCaptureFailed` so the cover can surface a banner — silently
    /// swallowing them (as the pre-build-6 code did) is the single
    /// most common cause of "the shutter didn't work" reports.
    func capturePhoto() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let settings = AVCapturePhotoSettings()
        settings.isHighResolutionPhotoEnabled = true
        let delegate = PhotoCaptureDelegate { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let image):
                    self.onPhotoCaptured?(image)
                case .failure(let error):
                    self.onCaptureFailed?(error.localizedDescription)
                }
            }
        }
        captureDelegate = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

/// Retains a completion closure so we can keep the delegate alive for
/// the duration of the capture callback. AVFoundation stores the
/// delegate as `weak`, which means losing the local reference would
/// silently drop the callback.
private final class PhotoCaptureDelegate: NSObject,
    AVCapturePhotoCaptureDelegate,
    @unchecked Sendable
{
    private let completion: (Result<UIImage, Error>) -> Void

    init(completion: @escaping (Result<UIImage, Error>) -> Void) {
        self.completion = completion
        super.init()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else {
            completion(.failure(PhotoCaptureError.invalidPhotoData))
            return
        }
        completion(.success(image))
    }
}

/// Failure modes for `PhotoCaptureDelegate` distinct from AVFoundation
/// errors — when the capture itself succeeds but we can't decode a
/// usable `UIImage` from the bytes.
private enum PhotoCaptureError: LocalizedError {
    case invalidPhotoData

    var errorDescription: String? {
        switch self {
        case .invalidPhotoData:
            return "Couldn't decode the captured photo."
        }
    }
}
