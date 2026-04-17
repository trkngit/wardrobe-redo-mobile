import AVFoundation
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

    func makeUIViewController(context: Context) -> CameraCaptureViewController {
        let vc = CameraCaptureViewController()
        vc.monitor = monitor
        vc.onPhotoCaptured = onPhotoCaptured
        vc.onAuthorizationChanged = onAuthorizationChanged
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

    weak var monitor: BackgroundQualityMonitor?
    var onPhotoCaptured: ((UIImage) -> Void)?
    var onAuthorizationChanged: ((CameraAuthorizationState) -> Void)?

    // MARK: - Internals

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.wardroberedo.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "com.wardroberedo.camera.video", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var qualityBridge: BackgroundQualityCaptureBridge?
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
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
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
            configureSession()
        case .notDetermined:
            onAuthorizationChanged?(.notDetermined)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.onAuthorizationChanged?(granted ? .authorized : .denied)
                    if granted { self?.configureSession() }
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
    /// Must be invoked on the main thread.
    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        settings.isHighResolutionPhotoEnabled = true
        let delegate = PhotoCaptureDelegate { [weak self] image in
            DispatchQueue.main.async {
                guard let self, let image else { return }
                self.onPhotoCaptured?(image)
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
    private let completion: (UIImage?) -> Void

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
        super.init()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if error != nil {
            completion(nil)
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else {
            completion(nil)
            return
        }
        completion(image)
    }
}
