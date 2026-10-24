import AVFoundation
import Combine
import os
import Photos
import UIKit
import VideoToolbox

struct StatusNote: Equatable, Identifiable {
    let id = UUID()
    let text: String
}

enum CameraPhase: Equatable {
    case starting
    case ready
    case unauthorized
    case failed(String)
}

enum CameraSetupError: LocalizedError {
    case noCamera
    case formatUnavailable
    case failedToStart
    case cannotAddAudio

    var errorDescription: String? {
        switch self {
        case .noCamera:
            return "This phone's camera couldn't be opened."
        case .formatUnavailable:
            return "Couldn't find a matching video format on both cameras."
        case .failedToStart:
            return "The camera didn't start."
        case .cannotAddAudio:
            return "The microphone didn't start."
        }
    }
}

/// One capture pipeline that keeps writing the same movie while the lens changes.
/// Audio uses its own session so a camera flip doesn't stall the microphone.
final class CameraEngine: NSObject, ObservableObject {
    let videoSession = AVCaptureSession()
    private let audioSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "flipcam.session", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "flipcam.samples", qos: .userInitiated)
    private let stateLock = NSLock()
    private let logger = Logger(subsystem: "personal.flipcam.recorder", category: "camera")

    @Published private(set) var phase: CameraPhase = .starting
    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published private(set) var zoomProfile = ZoomProfile.identity
    @Published private(set) var zoomDisplay: CGFloat = 1
    @Published private(set) var isAdjustingZoom = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var isSwitchingCamera = false
    @Published private(set) var torchAvailable = false
    @Published private(set) var torchOn = false
    @Published private(set) var systemControlsVisible = false
    @Published private(set) var latestURL: URL?
    @Published private(set) var thumbnail: UIImage?
    @Published var statusNote: StatusNote?
    @Published private(set) var recordingStartedAt: Date?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var videoDevice: AVCaptureDevice?
    private var usesSeparateAudio = false
    private var didConfigure = false
    private var sessionReady = false
    private var didSetControlsDelegate = false
    private var lockedWidth = 1920
    private var lockedHeight = 1080

    private var activeProfile = ZoomProfile.identity
    private var backDisplayZoom: CGFloat = 1
    private var frontDisplayZoom: CGFloat = 1
    private var pinchOriginDeviceZoom: CGFloat = 1
    private var pinching = false

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var deviceObservations: [NSKeyValueObservation] = []
    private var rotationObservations: [NSKeyValueObservation] = []
    private var lastPreviewAngle: CGFloat = 90
    private var captureAngle: CGFloat = 90

    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var didStartSession = false
    private var lastVideoPTS: CMTime?
    private var lastAudioPTS: CMTime?
    private var isReconfiguring = false

    var zoomLabel: String { ZoomFormatting.readout(zoomDisplay) }
    var canRecord: Bool { phase == .ready && !isFinishing }

    func start() {
        sessionQueue.async {
            guard !self.didConfigure else { return }
            self.didConfigure = true
            self.registerNotifications()
            AVCaptureDevice.requestAccess(for: .video) { videoGranted in
                AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                    guard videoGranted, audioGranted else {
                        self.onMain { self.phase = .unauthorized }
                        return
                    }
                    self.sessionQueue.async { self.configureAndStart() }
                }
            }
        }
    }

    func flip() {
        sessionQueue.async {
            guard self.sessionReady, !self.isReconfiguring else { return }
            let next: AVCaptureDevice.Position = self.videoDevice?.position == .front ? .back : .front
            self.reconfigure(to: next)
        }
    }

    func toggleRecording() {
        sessionQueue.async {
            if self.isRecording {
                self.finishRecording(note: nil, save: true)
            } else if self.sessionReady && !self.isFinishing {
                self.startRecording()
            }
        }
    }

    func selectZoom(_ display: CGFloat) {
        sessionQueue.async {
            self.pinching = false
            self.apply(displayZoom: display, ramp: true)
            self.publishAdjusting(self.videoDevice?.isRampingVideoZoom == true)
        }
    }

    func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            sessionQueue.async {
                self.pinching = true
                self.pinchOriginDeviceZoom = self.videoDevice?.videoZoomFactor ?? self.activeProfile.deviceZoom(forDisplayZoom: 1)
                self.cancelRamp()
                self.publishAdjusting(true)
            }
        case .changed:
            let scale = gesture.scale
            sessionQueue.async {
                guard self.pinching else { return }
                let minimum = self.videoDevice?.minAvailableVideoZoomFactor ?? 1
                let maximum = self.deviceZoomCeiling()
                let target = min(max(self.pinchOriginDeviceZoom * scale, minimum), maximum)
                self.apply(deviceZoom: target, ramp: false)
            }
        default:
            sessionQueue.async {
                self.pinching = false
                self.publishAdjusting(false)
            }
        }
    }

    func resetZoom() {
        selectZoom(zoomProfile.defaultDisplay)
    }

    func multiplyZoom(by factor: CGFloat) {
        let next = zoomDisplay * factor
        selectZoom(next)
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                self.logger.error("focus failed: \(error.localizedDescription)")
            }
        }
    }

    func toggleTorch() {
        sessionQueue.async {
            guard let device = self.videoDevice, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = device.torchMode == .on ? .off : .on
                let on = device.torchMode == .on
                device.unlockForConfiguration()
                self.onMain { self.torchOn = on }
            } catch {
                self.logger.error("torch failed: \(error.localizedDescription)")
            }
        }
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        let layerChanged = previewLayer !== layer
        previewLayer = layer
        layer.videoGravity = .resizeAspectFill
        if layerChanged {
            onMain { self.applyPreviewConnection() }
        }
        sessionQueue.async {
            guard self.rotationCoordinator == nil || layerChanged else { return }
            self.installRotationCoordinatorIfPossible()
        }
    }

    // MARK: - Setup

    private func configureAndStart() {
        do {
            try configureAudioCategory()
            usesSeparateAudio = startSeparateAudio()
            try configureVideoSession(includeAudio: !usesSeparateAudio)
            videoSession.startRunning()
            guard videoSession.isRunning else { throw CameraSetupError.failedToStart }
            sessionReady = true
            installRotationCoordinatorIfPossible()
            onMain { self.phase = .ready }
        } catch {
            logger.error("setup failed: \(error.localizedDescription)")
            onMain { self.phase = .failed(error.localizedDescription) }
        }
    }

    private func configureAudioCategory() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        try audio.setActive(true)
    }

    private func startSeparateAudio() -> Bool {
        audioSession.beginConfiguration()
        audioSession.automaticallyConfiguresApplicationAudioSession = false
        do {
            guard let mic = AVCaptureDevice.default(for: .audio) else { throw CameraSetupError.cannotAddAudio }
            let input = try AVCaptureDeviceInput(device: mic)
            guard audioSession.canAddInput(input) else { throw CameraSetupError.cannotAddAudio }
            audioSession.addInput(input)
            audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
            guard audioSession.canAddOutput(audioOutput) else { throw CameraSetupError.cannotAddAudio }
            audioSession.addOutput(audioOutput)
            audioSession.commitConfiguration()
        } catch {
            audioSession.commitConfiguration()
            tearDownAudioSession()
            logger.error("separate audio session failed: \(error.localizedDescription)")
            return false
        }

        audioSession.startRunning()
        guard audioSession.isRunning else {
            tearDownAudioSession()
            return false
        }
        return true
    }

    private func tearDownAudioSession() {
        audioSession.beginConfiguration()
        if audioSession.outputs.contains(where: { $0 === audioOutput }) {
            audioSession.removeOutput(audioOutput)
        }
        for input in audioSession.inputs {
            audioSession.removeInput(input)
        }
        audioSession.commitConfiguration()
    }

    private func configureVideoSession(includeAudio: Bool) throws {
        guard let size = sharedRecordingSize() else { throw CameraSetupError.formatUnavailable }
        lockedWidth = Int(size.width)
        lockedHeight = Int(size.height)

        if videoSession.supportsControls && !didSetControlsDelegate {
            videoSession.setControlsDelegate(self, queue: .main)
            didSetControlsDelegate = true
        }

        videoSession.beginConfiguration()
        do {
            videoSession.automaticallyConfiguresApplicationAudioSession = false
            videoSession.sessionPreset = .inputPriority

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ]
            videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
            guard videoSession.canAddOutput(videoOutput) else { throw CameraSetupError.failedToStart }
            videoSession.addOutput(videoOutput)

            if includeAudio {
                let microphone = try audioDeviceInput()
                audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
                guard videoSession.canAddInput(microphone) else { throw CameraSetupError.cannotAddAudio }
                videoSession.addInput(microphone)
                guard videoSession.canAddOutput(audioOutput) else { throw CameraSetupError.cannotAddAudio }
                videoSession.addOutput(audioOutput)
            }

            try installCamera(.back)
            videoSession.commitConfiguration()
        } catch {
            videoSession.commitConfiguration()
            throw error
        }
    }

    private func audioDeviceInput() throws -> AVCaptureDeviceInput {
        guard let mic = AVCaptureDevice.default(for: .audio) else { throw CameraSetupError.cannotAddAudio }
        return try AVCaptureDeviceInput(device: mic)
    }

    private func sharedRecordingSize() -> CMVideoDimensions? {
        guard let back = backDevice(), let front = frontDevice() else { return nil }
        let sizes = [
            CMVideoDimensions(width: 1920, height: 1080),
            CMVideoDimensions(width: 1280, height: 720)
        ]
        return sizes.first { size in
            format(for: back, size: size) != nil && format(for: front, size: size) != nil
        }
    }

    private func reconfigure(to position: AVCaptureDevice.Position) {
        stateLock.lock()
        isReconfiguring = true
        stateLock.unlock()
        onMain { self.isSwitchingCamera = true }
        defer {
            self.stateLock.lock()
            self.isReconfiguring = false
            self.stateLock.unlock()
            self.onMain { self.isSwitchingCamera = false }
        }

        rememberCurrentZoom()
        extinguishTorch()

        videoSession.beginConfiguration()
        do {
            try installCamera(position)
            videoSession.commitConfiguration()
            installRotationCoordinatorIfPossible()
        } catch {
            videoSession.commitConfiguration()
            logger.error("flip failed: \(error.localizedDescription)")
            onMain { self.statusNote = StatusNote(text: error.localizedDescription) }
        }
    }

    private func installCamera(_ position: AVCaptureDevice.Position) throws {
        guard let device = position == .back ? backDevice() : frontDevice() else {
            throw CameraSetupError.noCamera
        }
        let previous = videoInput
        if let previous {
            videoSession.removeInput(previous)
            videoInput = nil
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
            guard videoSession.canAddInput(input) else { throw CameraSetupError.noCamera }
            videoSession.addInput(input)
        } catch {
            if let previous, videoSession.canAddInput(previous) {
                videoSession.addInput(previous)
                videoInput = previous
            }
            throw error
        }

        videoInput = input
        videoDevice = device
        try lockFormat(on: device)
        installZoomSlider(for: device)
        applyVideoConnectionSettings()

        let desired = position == .front ? frontDisplayZoom : backDisplayZoom
        let target = activeProfile.deviceZoom(forDisplayZoom: desired)
        try device.lockForConfiguration()
        let ceiling = min(device.activeFormat.videoMaxZoomFactor, device.maxAvailableVideoZoomFactor)
        device.videoZoomFactor = min(max(target, device.minAvailableVideoZoomFactor), ceiling)
        device.unlockForConfiguration()
        observeZoom(on: device)

        let profile = activeProfile
        let zoom = device.videoZoomFactor
        onMain {
            self.position = device.position
            self.torchAvailable = device.hasTorch
            self.torchOn = device.torchMode == .on
            self.zoomProfile = profile
            self.zoomDisplay = profile.displayZoom(forDeviceZoom: zoom)
            self.applyPreviewConnection()
        }
    }

    private func lockFormat(on device: AVCaptureDevice) throws {
        let size = CMVideoDimensions(width: Int32(lockedWidth), height: Int32(lockedHeight))
        guard let format = format(for: device, size: size) else { throw CameraSetupError.formatUnavailable }
        try device.lockForConfiguration()
        device.activeFormat = format
        let frame = CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = frame
        device.activeVideoMaxFrameDuration = frame
        device.unlockForConfiguration()
        let ceiling = min(format.videoMaxZoomFactor, device.maxAvailableVideoZoomFactor)
        activeProfile = ZoomProfile.make(
            multiplier: displayMultiplier(for: device),
            deviceMinimum: device.minAvailableVideoZoomFactor,
            deviceMaximum: ceiling
        )
    }

    /// Prefer Apple's display multiplier. On a triple camera, fall back to the
    /// ultrawide switch-over so 1× stays the main lens if the multiplier is 1.
    private func displayMultiplier(for device: AVCaptureDevice) -> CGFloat {
        let reported = device.displayVideoZoomFactorMultiplier
        if reported > 0, abs(reported - 1) > 0.001 {
            return reported
        }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        if hasUltraWide, let switchOver = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            let factor = CGFloat(truncating: switchOver)
            if factor > 1 { return 1 / factor }
        }
        return reported > 0 ? reported : 1
    }

    private func format(for device: AVCaptureDevice, size: CMVideoDimensions) -> AVCaptureDevice.Format? {
        device.formats
            .filter { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width == size.width, dims.height == size.height else { return false }
                return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            }
            .max { lhs, rhs in
                score(lhs) < score(rhs)
            }
    }

    private func score(_ format: AVCaptureDevice.Format) -> Int {
        Int(format.videoMaxZoomFactor) + (format.isVideoStabilizationModeSupported(.standard) ? 10_000 : 0)
    }

    private func applyVideoConnectionSettings() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .standard
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func installZoomSlider(for device: AVCaptureDevice) {
        guard videoSession.supportsControls else { return }
        for control in videoSession.controls {
            videoSession.removeControl(control)
        }
        let slider = AVCaptureSystemZoomSlider(device: device)
        if videoSession.canAddControl(slider) {
            videoSession.addControl(slider)
        }
    }

    private func backDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func frontDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    // MARK: - Zoom

    private func observeZoom(on device: AVCaptureDevice) {
        deviceObservations.forEach { $0.invalidate() }
        deviceObservations.removeAll()
        deviceObservations.append(device.observe(\.videoZoomFactor, options: [.new]) { [weak self] device, _ in
            let zoom = device.videoZoomFactor
            self?.sessionQueue.async {
                guard let self else { return }
                let display = self.activeProfile.displayZoom(forDeviceZoom: zoom)
                self.onMain { self.zoomDisplay = display }
            }
        })
        deviceObservations.append(device.observe(\.isRampingVideoZoom, options: [.new]) { [weak self] device, _ in
            let ramping = device.isRampingVideoZoom
            self?.sessionQueue.async {
                self?.publishAdjusting(ramping)
            }
        })
    }

    private func apply(displayZoom: CGFloat, ramp: Bool) {
        apply(deviceZoom: activeProfile.deviceZoom(forDisplayZoom: displayZoom), ramp: ramp)
    }

    private func apply(deviceZoom: CGFloat, ramp: Bool) {
        guard let device = videoDevice else { return }
        let minimum = device.minAvailableVideoZoomFactor
        let maximum = deviceZoomCeiling()
        let target = min(max(deviceZoom, minimum), maximum)
        do {
            try device.lockForConfiguration()
            if ramp {
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.ramp(toVideoZoomFactor: target, withRate: 5)
            } else {
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.videoZoomFactor = target
            }
            device.unlockForConfiguration()
        } catch {
            logger.error("zoom failed: \(error.localizedDescription)")
        }
    }

    private func deviceZoomCeiling() -> CGFloat {
        guard let device = videoDevice else { return activeProfile.deviceZoom(forDisplayZoom: activeProfile.maximumDisplay) }
        let hardware = min(device.activeFormat.videoMaxZoomFactor, device.maxAvailableVideoZoomFactor)
        return min(hardware, activeProfile.deviceZoom(forDisplayZoom: activeProfile.maximumDisplay))
    }

    private func cancelRamp() {
        guard let device = videoDevice, device.isRampingVideoZoom else { return }
        try? device.lockForConfiguration()
        device.cancelVideoZoomRamp()
        device.unlockForConfiguration()
    }

    private func rememberCurrentZoom() {
        guard let device = videoDevice else { return }
        let display = activeProfile.displayZoom(forDeviceZoom: device.videoZoomFactor)
        if device.position == .front {
            frontDisplayZoom = display
        } else {
            backDisplayZoom = display
        }
    }

    private func publishAdjusting(_ adjusting: Bool) {
        let visible = pinching || adjusting
        onMain { self.isAdjustingZoom = visible }
    }

    private func extinguishTorch() {
        guard let device = videoDevice, device.hasTorch, device.torchMode == .on else { return }
        try? device.lockForConfiguration()
        device.torchMode = .off
        device.unlockForConfiguration()
        onMain { self.torchOn = false }
    }

    // MARK: - Recording

    private func startRecording() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FlipCam-\(UUID().uuidString).mov")
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

            let fallbackVideoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: lockedWidth,
                AVVideoHeightKey: lockedHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 10_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
                ]
            ]
            let videoSettings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov) as? [String: Any] ?? fallbackVideoSettings
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            stateLock.lock()
            let angle = captureAngle
            stateLock.unlock()
            videoInput.transform = CGAffineTransform(rotationAngle: angle * .pi / 180)
            guard writer.canAdd(videoInput) else { throw CameraSetupError.failedToStart }
            writer.add(videoInput)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)

            var audioInput: AVAssetWriterInput?
            if let settings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any] {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }

            stateLock.lock()
            assetWriter = writer
            videoWriterInput = videoInput
            audioWriterInput = audioInput
            pixelAdaptor = adaptor
            outputURL = url
            didStartSession = false
            lastVideoPTS = nil
            lastAudioPTS = nil
            isRecording = true
            stateLock.unlock()

            let started = Date()
            onMain {
                self.isRecording = true
                self.recordingStartedAt = started
                UIApplication.shared.isIdleTimerDisabled = true
            }
        } catch {
            logger.error("record start failed: \(error.localizedDescription)")
            onMain { self.statusNote = StatusNote(text: error.localizedDescription) }
        }
    }

    private func finishRecording(note: String?, save: Bool) {
        stateLock.lock()
        let writer = assetWriter
        let videoInput = videoWriterInput
        let audioInput = audioWriterInput
        let url = outputURL
        let started = didStartSession
        guard isRecording || writer != nil else {
            stateLock.unlock()
            return
        }
        isRecording = false
        assetWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        pixelAdaptor = nil
        outputURL = nil
        didStartSession = false
        stateLock.unlock()

        onMain {
            self.isRecording = false
            self.recordingStartedAt = nil
            self.isFinishing = writer != nil
            UIApplication.shared.isIdleTimerDisabled = false
        }

        guard let writer, let url else { return }

        if !started || writer.status == .unknown || writer.status == .failed {
            if writer.status != .failed {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: url)
            onMain {
                self.isFinishing = false
                self.statusNote = StatusNote(text: note ?? "Hold the record button a little longer.")
            }
            return
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            let completed = writer.status == .completed
            if completed && save {
                self.onMain {
                    self.latestURL = url
                    self.isFinishing = false
                }
                self.makeThumbnail(for: url)
                Task { await self.saveToPhotos(url) }
            } else {
                self.onMain {
                    self.isFinishing = false
                    self.statusNote = StatusNote(text: note ?? writer.error?.localizedDescription ?? "Recording failed.")
                }
            }
        }
    }

    private func makeThumbnail(for url: URL) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.generateCGImageAsynchronously(for: time) { [weak self] image, _, _ in
            guard let self, let image else { return }
            let thumbnail = UIImage(cgImage: image)
            self.onMain { self.thumbnail = thumbnail }
        }
    }

    private func saveToPhotos(_ url: URL) async {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let status = current == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .addOnly) : current
        guard status == .authorized else {
            onMain { self.statusNote = StatusNote(text: "Clip is ready. Allow Photos if you want it in your library.") }
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }
            onMain { self.statusNote = StatusNote(text: "Saved to Photos") }
        } catch {
            logger.error("photo save failed: \(error.localizedDescription)")
            onMain { self.statusNote = StatusNote(text: "Couldn't save to Photos. You can still share the clip.") }
        }
    }

    // MARK: - Preview rotation

    private func installRotationCoordinatorIfPossible() {
        guard let device = videoDevice, let previewLayer else { return }
        rotationObservations.forEach { $0.invalidate() }
        rotationObservations.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            self?.onMain {
                self?.lastPreviewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
                self?.applyPreviewConnection()
            }
        })
        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            guard let self else { return }
            self.stateLock.lock()
            self.captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            self.stateLock.unlock()
        })
    }

    private func applyPreviewConnection() {
        guard let connection = previewLayer?.connection else { return }
        let angle = lastPreviewAngle
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
        }
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionRuntimeError), name: .AVCaptureSessionRuntimeError, object: videoSession)
        center.addObserver(self, selector: #selector(sessionWasInterrupted), name: .AVCaptureSessionWasInterrupted, object: videoSession)
        center.addObserver(self, selector: #selector(sessionInterruptionEnded), name: .AVCaptureSessionInterruptionEnded, object: videoSession)
        center.addObserver(self, selector: #selector(sessionDidStart), name: .AVCaptureSessionDidStartRunning, object: videoSession)
        center.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        sessionQueue.async {
            guard !self.videoSession.isRunning else { return }
            self.videoSession.startRunning()
        }
    }

    @objc private func sessionWasInterrupted() {
        sessionQueue.async {
            guard self.isRecording else { return }
            self.finishRecording(note: "Recording stopped because the camera was interrupted.", save: true)
        }
    }

    @objc private func sessionInterruptionEnded() {
        sessionQueue.async {
            if !self.videoSession.isRunning { self.videoSession.startRunning() }
            if self.usesSeparateAudio, !self.audioSession.isRunning { self.audioSession.startRunning() }
        }
    }

    @objc private func sessionDidStart() {
        onMain { self.applyPreviewConnection() }
    }

    @objc private func didEnterBackground() {
        sessionQueue.async {
            guard self.isRecording else { return }
            self.finishRecording(note: nil, save: true)
        }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        autoreleasepool {
            append(sampleBuffer, isVideo: output === videoOutput)
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        stateLock.lock()
        guard isRecording, let writer = assetWriter else {
            stateLock.unlock()
            return
        }
        if isVideo && isReconfiguring {
            stateLock.unlock()
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, !pts.isIndefinite else {
            stateLock.unlock()
            return
        }

        if !didStartSession {
            guard writer.startWriting() else {
                stateLock.unlock()
                finishRecording(note: writer.error?.localizedDescription ?? "Couldn't start the recording.", save: false)
                return
            }
            writer.startSession(atSourceTime: pts)
            didStartSession = true
        }

        guard writer.status == .writing else {
            stateLock.unlock()
            return
        }

        if isVideo {
            guard
                let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                let input = videoWriterInput,
                input.isReadyForMoreMediaData,
                let adaptor = pixelAdaptor
            else {
                stateLock.unlock()
                return
            }
            if let lastVideoPTS, CMTimeCompare(pts, lastVideoPTS) <= 0 {
                stateLock.unlock()
                return
            }
            let wrote = adaptor.append(buffer, withPresentationTime: pts)
            if wrote { lastVideoPTS = pts }
            stateLock.unlock()
        } else {
            guard let input = audioWriterInput, input.isReadyForMoreMediaData else {
                stateLock.unlock()
                return
            }
            if let lastAudioPTS, CMTimeCompare(pts, lastAudioPTS) <= 0 {
                stateLock.unlock()
                return
            }
            let wrote = input.append(sampleBuffer)
            if wrote { lastAudioPTS = pts }
            stateLock.unlock()
        }
    }
}

extension CameraEngine: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        systemControlsVisible = true
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        systemControlsVisible = false
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        systemControlsVisible = false
    }
}
