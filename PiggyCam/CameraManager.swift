import AVFoundation
import Combine
import CoreImage
import Photos
import UIKit
import Vision

final class CameraManager: NSObject, ObservableObject {
    @Published private(set) var previewFrame: CGImage?
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var permissionProblem: String?
    @Published private(set) var message: String?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.john.PiggyCam.session")
    private let outputQueue = DispatchQueue(label: "com.john.PiggyCam.output")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let faceRequest = VNDetectFaceRectanglesRequest()

    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var currentPosition: AVCaptureDevice.Position = .front
    private var configured = false
    private var lastRenderedFrame: CGImage?

    private var wantsRecording = false
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var recordingStartTime: CMTime?

    private lazy var pigMask: CIImage? = {
        guard let image = UIImage(named: "PigMask") else { return nil }
        return CIImage(image: image)
    }()

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
        guard !isRecording else { return }
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
                self.updateVideoConnection()
            } else {
                self.session.addInput(oldInput)
            }
            self.session.commitConfiguration()
        }
    }

    func takePhoto() {
        guard let image = lastRenderedFrame else {
            showMessage("相機尚未準備完成")
            return
        }
        savePhoto(UIImage(cgImage: image))
    }

    func startRecording() {
        guard isReady, !isRecording else { return }
        outputQueue.async { [weak self] in
            self?.resetWriter()
            self?.wantsRecording = true
        }
        DispatchQueue.main.async { self.isRecording = true }
    }

    func stopRecording() {
        guard isRecording else { return }
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

    private func requestOptionalPermissionsAndConfigure() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.configureAndStartSession()
            }
        } else {
            configureAndStartSession()
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
        session.sessionPreset = .high

        guard
            let camera = cameraDevice(position: currentPosition),
            let cameraInput = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(cameraInput)
        else { return false }
        session.addInput(cameraInput)
        videoInput = cameraInput

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

        let audio = AVCaptureAudioDataOutput()
        audio.setSampleBufferDelegate(self, queue: outputQueue)
        if session.canAddOutput(audio) {
            session.addOutput(audio)
            audioOutput = audio
        }

        updateVideoConnection()
        return true
    }

    private func updateVideoConnection() {
        guard let connection = videoOutput?.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = currentPosition == .front
        }
    }

    private func cameraDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        ).devices.first
    }

    private func renderPigFrame(from pixelBuffer: CVPixelBuffer) -> CIImage {
        let base = CIImage(cvPixelBuffer: pixelBuffer)
        guard let mask = pigMask else { return base }

        let handler = VNImageRequestHandler(ciImage: base, orientation: .up)
        try? handler.perform([faceRequest])
        guard let faces = faceRequest.results, !faces.isEmpty else { return base }

        return faces.reduce(base) { image, face in
            let box = face.boundingBox
            let faceRect = CGRect(
                x: base.extent.minX + box.minX * base.extent.width,
                y: base.extent.minY + box.minY * base.extent.height,
                width: box.width * base.extent.width,
                height: box.height * base.extent.height
            )
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
            return mask.transformed(by: transform).composited(over: image)
        }
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
    }

    private func savePhoto(_ image: UIImage) {
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
        let processed = renderPigFrame(from: pixelBuffer)
        updatePreview(with: processed)
        if wantsRecording {
            appendVideo(processed, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
    }
}
