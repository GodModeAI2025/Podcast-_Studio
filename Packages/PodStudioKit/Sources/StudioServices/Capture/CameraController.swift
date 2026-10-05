#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import Foundation
import Observation

/// Local camera self-view (M1). Video is never recorded — sessions produce audio only.
/// Remote participants are shown by FaceTime's own
/// SharePlay UI (AD6).
@MainActor
@Observable
public final class CameraController {
    public private(set) var isRunning = false
    public private(set) var cameras: [AVCaptureDevice] = []
    public private(set) var selectedCameraID: String?
    public private(set) var lastError: String?

    /// Shared with the preview layer; configured and started on `sessionQueue`.
    public let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "podstudio.camera")

    public init() {}

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public func refreshCameras() {
        #if os(iOS)
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .external]
        #else
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        #endif
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        if selectedCameraID == nil {
            #if os(iOS)
            selectedCameraID = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)?.uniqueID
            #else
            selectedCameraID = AVCaptureDevice.default(for: .video)?.uniqueID
            #endif
        }
    }

    public func start() async {
        guard !isRunning else { return }
        guard await Self.requestPermission() else {
            lastError = "Kein Kamerazugriff."
            return
        }
        refreshCameras()
        guard let id = selectedCameraID, let device = AVCaptureDevice(uniqueID: id) else {
            lastError = "Keine Kamera gefunden."
            return
        }
        let session = self.session
        let error: String? = await withCheckedContinuation { cont in
            sessionQueue.async {
                session.beginConfiguration()
                session.sessionPreset = .medium  // self-view only, never recorded
                session.inputs.forEach { session.removeInput($0) }
                var failure: String?
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    if session.canAddInput(input) { session.addInput(input) } else { failure = "Kamera nicht verfügbar." }
                } catch {
                    failure = error.localizedDescription
                }
                #if os(iOS)
                // Keep the preview alive while FaceTime/SharePlay or PiP is in the foreground.
                if session.isMultitaskingCameraAccessSupported {
                    session.isMultitaskingCameraAccessEnabled = true
                }
                #endif
                session.commitConfiguration()
                if failure == nil { session.startRunning() }
                cont.resume(returning: failure)
            }
        }
        lastError = error
        isRunning = error == nil
    }

    public func stop() {
        let session = self.session
        sessionQueue.async { session.stopRunning() }
        isRunning = false
    }

    public func select(_ id: String) async {
        selectedCameraID = id
        if isRunning {
            stop()
            await start()
        }
    }
}
#endif
