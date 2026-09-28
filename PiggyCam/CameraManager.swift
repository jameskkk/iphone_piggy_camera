import AVFoundation
import Combine
import CoreImage
import ImageIO
import Photos
import UIKit
import Vision

enum CameraFlashMode: CaseIterable {
    case off
    case auto
    case on

    var title: String {
        switch self {
        case .off: "關閉"
        case .auto: "自動"
        case .on: "開啟"
        }
    }

    var symbolName: String {
        switch self {
        case .off: "bolt.slash.fill"
        case .auto: "bolt.badge.automatic.fill"
        case .on: "bolt.fill"
        }
    }

    var avMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: .off
        case .auto: .auto
        case .on: .on
        }
    }

    var next: CameraFlashMode {
        switch self {
        case .off: .auto
        case .auto: .on
        case .on: .off
        }
    }
}

final class CameraManager: NSObject, ObservableObject {
    let faceExclusionStore = FaceExclusionStore()

    @Published private(set) var previewFrame: CGImage?
    @Published private(set) var lastThumbnail: UIImage?
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var isUsingFrontCamera = true
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var permissionProblem: String?
    @Published private(set) var message: String?
    @Published private(set) var countdown: Int?
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var availableZoomFactors: [CGFloat] = [1, 2]
    @Published private(set) var focusPoint: CGPoint?
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var minimumExposureBias: Float = -2
    @Published private(set) var maximumExposureBias: Float = 2
    @Published private(set) var flashMode: CameraFlashMode = .off
    @Published private(set) var isFlashAvailable = false
    @Published private(set) var pigEffectEnabled = true
    @Published private(set) var shutterFlashVisible = false

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.john.PiggyCam.session")
    private let outputQueue = DispatchQueue(label: "com.john.PiggyCam.output")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let faceRequest = VNDetectFaceRectanglesRequest()

    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var photoOutput: AVCapturePhotoOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var currentPosition: AVCaptureDevice.Position = .front
    private var configured = false
    private var lastRenderedFrame: CGImage?
    private var zoomBaseFactor: CGFloat = 1
    private var isObservingPhotoLibrary = false
    private var faceMatchFrame = 0
    private var faceMatchStates: [FaceMatchState] = []

    private var wantsRecording = false
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var recordingStartTime: CMTime?
    private var lastDurationUpdate: TimeInterval = 0

    private struct FaceMatchState {
        var boundingBox: CGRect
        var isExcluded: Bool
        var evaluatedFrame: Int
        var lastMatchedFrame: Int?
        var consecutiveMatches: Int
        var consecutiveMisses: Int
    }

    private lazy var pigMask: CIImage? = {
        guard let image = UIImage(named: "PigMask") else { return nil }
        return CIImage(image: image)
    }()

    deinit {
        if isObservingPhotoLibrary {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            requestOptionalPermissionsAndConfigure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                granted ? self.requestOptionalPermissionsAndConfigure() : self.showPermissionProblem()
            }
        default:
            showPermissionProblem()
        }
    }

    func stop() {
        if isRecording { stopRecording() }
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func switchCamera() {
        guard !isRecording, countdown == nil else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let next: AVCaptureDevice.Position = self.currentPosition == .front ? .back : .front
            guard
                let device = self.cameraDevice(position: next),
                let newInput = try? AVCaptureDeviceInput(device: device),
                let oldInput = self.videoInput
            else {
                self.showMessage("無法切換鏡頭")
                return
            }

            self.session.beginConfiguration()
            self.session.removeInput(oldInput)
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
                self.currentPosition = next
                self.configureRotationCoordinator(for: device)
                self.updateConnections()
                self.configureCapabilities(for: device)
            } else {
                self.session.addInput(oldInput)
            }
            self.session.commitConfiguration()
            self.outputQueue.async {
                self.faceMatchStates.removeAll()
            }
        }
    }

    func cycleFlashMode() {
        guard isFlashAvailable else {
            showMessage("前置鏡頭不支援硬體閃光燈")
            return
        }
        flashMode = flashMode.next
    }

    func togglePigEffect() {
        pigEffectEnabled.toggle()
        showMessage(pigEffectEnabled ? "小豬效果已開啟" : "小豬效果已關閉")
    }

    func takePhoto(after delay: Int = 0) {
        guard isReady, !isRecording, countdown == nil else { return }
        if delay > 0 {
            runCountdown(delay)
        } else {
            capturePhotoNow()
        }
    }

    func setZoom(_ displayFactor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let minimumDisplay = device.minAvailableVideoZoomFactor / self.zoomBaseFactor
            let maximumDisplay = min(device.maxAvailableVideoZoomFactor / self.zoomBaseFactor, 8)
            let clampedDisplay = min(max(displayFactor, minimumDisplay), maximumDisplay)
            let deviceFactor = clampedDisplay * self.zoomBaseFactor
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: deviceFactor, withRate: 12)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clampedDisplay }
            } catch {
                self.showMessage("無法調整縮放")
            }
        }
    }

    func focus(at normalizedPoint: CGPoint) {
        let point = CGPoint(
            x: min(max(normalizedPoint.x, 0), 1),
            y: min(max(normalizedPoint.y, 0), 1)
        )
        DispatchQueue.main.async {
            self.focusPoint = point
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if self.focusPoint == point { self.focusPoint = nil }
            }
        }

        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let devicePoint = CGPoint(
                x: point.y,
                y: self.currentPosition == .front ? point.x : 1 - point.x
            )
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                self.showMessage("無法設定對焦")
            }
        }
    }

    func setExposureBias(_ value: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let clamped = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.exposureBias = clamped }
            } catch {
                self.showMessage("無法調整曝光")
            }
        }
    }

    func startRecording() {
        guard isReady, !isRecording, countdown == nil else { return }
        outputQueue.async { [weak self] in
            self?.resetWriter()
            self?.wantsRecording = true
        }
        if flashMode == .on { setTorch(enabled: true) }
        DispatchQueue.main.async {
            self.recordingDuration = 0
            self.isRecording = true
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        setTorch(enabled: false)
        DispatchQueue.main.async { self.isRecording = false }
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRecording = false
            guard let writer = self.assetWriter, let url = self.recordingURL else {
                self.resetWriter()
                return
            }

            self.videoWriterInput?.markAsFinished()
            self.audioWriterInput?.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self else { return }
                if writer.status == .completed {
                    if let frame = self.lastRenderedFrame {
                        DispatchQueue.main.async { self.lastThumbnail = UIImage(cgImage: frame) }
                    }
                    self.saveVideo(at: url)
                } else {
                    try? FileManager.default.removeItem(at: url)
                    self.showMessage("影片儲存失敗")
                }
                self.outputQueue.async { self.resetWriter() }
            }
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func refreshPhotoLibraryThumbnail() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = 1
        guard let latestAsset = PHAsset.fetchAssets(with: fetchOptions).firstObject else { return }

        let imageOptions = PHImageRequestOptions()
        imageOptions.deliveryMode = .opportunistic
        imageOptions.resizeMode = .fast
        imageOptions.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(
            for: latestAsset,
            targetSize: CGSize(width: 240, height: 240),
            contentMode: .aspectFill,
            options: imageOptions
        ) { [weak self] image, _ in
            guard let image else { return }
            DispatchQueue.main.async { self?.lastThumbnail = image }
        }
    }

    func useBrowserThumbnail(_ image: UIImage) {
        lastThumbnail = image
    }

    private func runCountdown(_ remaining: Int) {
        DispatchQueue.main.async {
            self.countdown = remaining
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if remaining > 1 {
                    self.runCountdown(remaining - 1)
                } else {
                    self.countdown = nil
                    self.capturePhotoNow()
                }
            }
        }
    }

    private func capturePhotoNow() {
        sessionQueue.async { [weak self] in
            guard let self, let output = self.photoOutput else { return }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            if self.isFlashAvailable {
                settings.flashMode = self.flashMode.avMode
            }
            DispatchQueue.main.async {
                self.shutterFlashVisible = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.shutterFlashVisible = false
                }
            }
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func requestOptionalPermissionsAndConfigure() {
        requestPhotoLibraryAccess()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.configureAndStartSession()
            }
        } else {
            configureAndStartSession()
        }
    }

    private func requestPhotoLibraryAccess() {
        let handleStatus: (PHAuthorizationStatus) -> Void = { [weak self] status in
            guard let self, status == .authorized || status == .limited else { return }
            DispatchQueue.main.async {
                if !self.isObservingPhotoLibrary {
                    PHPhotoLibrary.shared().register(self)
                    self.isObservingPhotoLibrary = true
                }
                self.refreshPhotoLibraryThumbnail()
            }
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: handleStatus)
        } else {
            handleStatus(status)
        }
    }

    private func configureAndStartSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                guard self.configureSession() else {
                    self.showMessage("相機初始化失敗")
                    return
                }
                self.configured = true
            }
            guard !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async {
                self.isReady = true
                self.permissionProblem = nil
            }
        }
    }

    private func configureSession() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        guard
            let camera = cameraDevice(position: currentPosition),
            let cameraInput = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(cameraInput)
        else { return false }
        session.addInput(cameraInput)
        videoInput = cameraInput
        configureRotationCoordinator(for: camera)

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let microphone = AVCaptureDevice.default(for: .audio),
           let microphoneInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(microphoneInput) {
            session.addInput(microphoneInput)
        }

        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(video) else { return false }
        session.addOutput(video)
        videoOutput = video

        let photo = AVCapturePhotoOutput()
        guard session.canAddOutput(photo) else { return false }
        session.addOutput(photo)
        photo.maxPhotoQualityPrioritization = .quality
        photoOutput = photo

        let audio = AVCaptureAudioDataOutput()
        audio.setSampleBufferDelegate(self, queue: outputQueue)
        if session.canAddOutput(audio) {
            session.addOutput(audio)
            audioOutput = audio
        }

        updateConnections()
        configureCapabilities(for: camera)
        return true
    }

    private func updateConnections() {
        let captureAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90

        applyConnectionSettings(
            to: videoOutput?.connection(with: .video),
            rotationAngle: captureAngle
        )
        applyConnectionSettings(
            to: photoOutput?.connection(with: .video),
            rotationAngle: captureAngle
        )
    }

    private func configureRotationCoordinator(for device: AVCaptureDevice) {
        rotationObservation = nil
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            self?.sessionQueue.async { [weak self] in
                self?.updateConnections()
            }
        }
    }

    private func applyConnectionSettings(
        to connection: AVCaptureConnection?,
        rotationAngle: CGFloat
    ) {
        guard let connection else { return }
        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = currentPosition == .front
        }
    }

    private func configureCapabilities(for device: AVCaptureDevice) {
        let supportsUltraWide = device.deviceType == .builtInTripleCamera
            || device.deviceType == .builtInDualWideCamera
        if supportsUltraWide,
           let firstSwitch = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            zoomBaseFactor = CGFloat(truncating: firstSwitch)
        } else {
            zoomBaseFactor = 1
        }

        let candidates: [CGFloat] = supportsUltraWide ? [0.5, 1, 2] : [1, 2]
        let supported = candidates.filter {
            let hardwareFactor = $0 * zoomBaseFactor
            return hardwareFactor >= device.minAvailableVideoZoomFactor
                && hardwareFactor <= device.maxAvailableVideoZoomFactor
        }
        let defaultDisplayFactor: CGFloat = supported.contains(1) ? 1 : (supported.first ?? 1)
        let defaultHardwareFactor = min(
            max(defaultDisplayFactor * zoomBaseFactor, device.minAvailableVideoZoomFactor),
            device.maxAvailableVideoZoomFactor
        )
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = defaultHardwareFactor
            device.unlockForConfiguration()
        } catch { }

        DispatchQueue.main.async {
            self.availableZoomFactors = supported.isEmpty ? [1] : supported
            self.zoomFactor = defaultDisplayFactor
            self.isUsingFrontCamera = self.currentPosition == .front
            self.isFlashAvailable = self.currentPosition == .back && device.hasFlash
            self.flashMode = self.isFlashAvailable ? self.flashMode : .off
            self.minimumExposureBias = max(device.minExposureTargetBias, -2)
            self.maximumExposureBias = min(device.maxExposureTargetBias, 2)
            self.exposureBias = 0
        }
    }

    private func cameraDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if position == .back {
            deviceTypes = [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera
            ]
        } else {
            deviceTypes = [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        }
        for type in deviceTypes {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) {
                return device
            }
        }
        return nil
    }

    private func setTorch(enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let device = self?.videoInput?.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if enabled {
                    try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    private func renderPigFrame(from image: CIImage, forceFaceMatching: Bool = false) -> CIImage {
        guard pigEffectEnabled, let mask = pigMask else {
            faceMatchStates.removeAll()
            return image
        }

        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)
        try? handler.perform([faceRequest])
        guard let faces = faceRequest.results, !faces.isEmpty else {
            faceMatchStates.removeAll()
            return image
        }

        faceMatchFrame &+= 1
        var updatedStates: [FaceMatchState] = []
        var renderedImage = image
        for face in faces {
            let box = face.boundingBox
            let faceRect = CGRect(
                x: image.extent.minX + box.minX * image.extent.width,
                y: image.extent.minY + box.minY * image.extent.height,
                width: box.width * image.extent.width,
                height: box.height * image.extent.height
            )
            let previous = faceMatchStates.min(by: {
                faceDistance($0.boundingBox, box) < faceDistance($1.boundingBox, box)
            }).flatMap { faceDistance($0.boundingBox, box) < 0.2 ? $0 : nil }
            let shouldReevaluate = forceFaceMatching
                || previous == nil
                || faceMatchFrame - (previous?.evaluatedFrame ?? 0) >= 6
            let isExcluded: Bool
            let evaluatedFrame: Int
            let lastMatchedFrame: Int?
            let consecutiveMatches: Int
            let consecutiveMisses: Int
            if shouldReevaluate {
                let matched = faceExclusionStore.shouldExclude(faceIn: image, faceRect: faceRect)
                evaluatedFrame = faceMatchFrame
                if matched {
                    consecutiveMatches = (previous?.consecutiveMatches ?? 0) + 1
                    isExcluded = forceFaceMatching
                        || previous?.isExcluded == true
                        || consecutiveMatches >= 2
                    lastMatchedFrame = faceMatchFrame
                    consecutiveMisses = 0
                } else if !forceFaceMatching,
                          previous?.isExcluded == true,
                          let previousMatchedFrame = previous?.lastMatchedFrame,
                          faceMatchFrame - previousMatchedFrame <= 36,
                          (previous?.consecutiveMisses ?? 0) < 3 {
                    isExcluded = true
                    lastMatchedFrame = previousMatchedFrame
                    consecutiveMatches = previous?.consecutiveMatches ?? 0
                    consecutiveMisses = (previous?.consecutiveMisses ?? 0) + 1
                } else {
                    isExcluded = false
                    lastMatchedFrame = nil
                    consecutiveMatches = 0
                    consecutiveMisses = 0
                }
            } else {
                isExcluded = previous?.isExcluded ?? false
                evaluatedFrame = previous?.evaluatedFrame ?? faceMatchFrame
                lastMatchedFrame = previous?.lastMatchedFrame
                consecutiveMatches = previous?.consecutiveMatches ?? 0
                consecutiveMisses = previous?.consecutiveMisses ?? 0
            }
            updatedStates.append(FaceMatchState(
                boundingBox: box,
                isExcluded: isExcluded,
                evaluatedFrame: evaluatedFrame,
                lastMatchedFrame: lastMatchedFrame,
                consecutiveMatches: consecutiveMatches,
                consecutiveMisses: consecutiveMisses
            ))
            if isExcluded { continue }

            let target = CGRect(
                x: faceRect.midX - faceRect.width * 0.78,
                y: faceRect.midY - faceRect.height * 0.83,
                width: faceRect.width * 1.56,
                height: faceRect.height * 1.66
            )
            let sx = target.width / mask.extent.width
            let sy = target.height / mask.extent.height
            let transform = CGAffineTransform(
                a: sx,
                b: 0,
                c: 0,
                d: sy,
                tx: target.minX - mask.extent.minX * sx,
                ty: target.minY - mask.extent.minY * sy
            )
            renderedImage = mask.transformed(by: transform).composited(over: renderedImage)
        }
        faceMatchStates = updatedStates
        return renderedImage
    }

    private func faceDistance(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let dx = first.midX - second.midX
        let dy = first.midY - second.midY
        return sqrt(dx * dx + dy * dy)
    }

    private func updatePreview(with image: CIImage) {
        guard let rendered = ciContext.createCGImage(image, from: image.extent) else { return }
        lastRenderedFrame = rendered
        DispatchQueue.main.async { self.previewFrame = rendered }
    }

    private func appendVideo(_ image: CIImage, presentationTime: CMTime) {
        if assetWriter == nil {
            prepareWriter(width: Int(image.extent.width), height: Int(image.extent.height))
        }
        guard
            let writer = assetWriter,
            let input = videoWriterInput,
            let adaptor = pixelBufferAdaptor,
            let pool = adaptor.pixelBufferPool
        else { return }

        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: presentationTime)
            recordingStartTime = presentationTime
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }

        var outputBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
              let buffer = outputBuffer else { return }
        ciContext.render(
            image,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: image.extent.width, height: image.extent.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        adaptor.append(buffer, withPresentationTime: presentationTime)

        if let start = recordingStartTime {
            let duration = max(CMTimeGetSeconds(presentationTime - start), 0)
            if duration - lastDurationUpdate >= 0.2 {
                lastDurationUpdate = duration
                DispatchQueue.main.async { self.recordingDuration = duration }
            }
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard wantsRecording,
              assetWriter?.status == .writing,
              recordingStartTime != nil,
              let input = audioWriterInput,
              input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    private func prepareWriter(width: Int, height: Int) {
        let evenWidth = width - width % 2
        let evenHeight = height - height % 2
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiggyCam-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: evenWidth,
            AVVideoHeightKey: evenHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { return }
        writer.add(videoInput)

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: evenWidth,
            kCVPixelBufferHeightKey as String: evenHeight
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: attributes
        )

        if let recommended = audioOutput?.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any] {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: recommended)
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                audioWriterInput = audioInput
            }
        }

        assetWriter = writer
        videoWriterInput = videoInput
        recordingURL = url
    }

    private func resetWriter() {
        assetWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        pixelBufferAdaptor = nil
        recordingURL = nil
        recordingStartTime = nil
        lastDurationUpdate = 0
    }

    private func savePhoto(_ image: UIImage) {
        DispatchQueue.main.async { self.lastThumbnail = image }
        ensurePhotoAccess { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                self.showMessage("請允許加入照片圖庫")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                self.showMessage(success ? "照片已儲存" : "照片儲存失敗")
                if success { self.refreshPhotoLibraryThumbnail() }
            }
        }
    }

    private func saveVideo(at url: URL) {
        ensurePhotoAccess { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                try? FileManager.default.removeItem(at: url)
                self.showMessage("請允許加入照片圖庫")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, _ in
                try? FileManager.default.removeItem(at: url)
                self.showMessage(success ? "影片已儲存" : "影片儲存失敗")
                if success { self.refreshPhotoLibraryThumbnail() }
            }
        }
    }

    private func ensurePhotoAccess(_ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized || status == .limited {
            completion(true)
        } else if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                completion(newStatus == .authorized || newStatus == .limited)
            }
        } else {
            completion(false)
        }
    }

    private func showPermissionProblem() {
        DispatchQueue.main.async {
            self.isReady = false
            self.permissionProblem = "請在「設定」中允許 PiggyCam 使用相機，才能即時辨識人臉。"
        }
    }

    private func showMessage(_ text: String) {
        DispatchQueue.main.async {
            self.message = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                if self.message == text { self.message = nil }
            }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === audioOutput {
            appendAudio(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let processed = renderPigFrame(from: CIImage(cvPixelBuffer: pixelBuffer))
        updatePreview(with: processed)
        if wantsRecording {
            appendVideo(processed, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
    }
}

extension CameraManager: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        refreshPhotoLibraryThumbnail()
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            showMessage("照片拍攝失敗")
            return
        }
        outputQueue.async { [weak self] in
            guard let self else { return }
            let processed = self.renderPigFrame(from: source, forceFaceMatching: true)
            guard let cgImage = self.ciContext.createCGImage(processed, from: processed.extent) else {
                self.showMessage("照片處理失敗")
                return
            }
            self.savePhoto(UIImage(cgImage: cgImage))
        }
    }
}
