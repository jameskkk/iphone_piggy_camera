import Combine
import CoreImage
import UIKit
import Vision

struct ExcludedFace: Identifiable {
    let id: UUID
    let thumbnail: UIImage
    let fileURL: URL
}

final class FaceExclusionStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var faces: [ExcludedFace] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var effectiveTolerance: Double

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            stateLock.lock()
            matchingEnabled = isEnabled
            stateLock.unlock()
        }
    }

    @Published var usesAutomaticTolerance: Bool {
        didSet {
            UserDefaults.standard.set(usesAutomaticTolerance, forKey: Self.automaticToleranceKey)
            stateLock.lock()
            matchingUsesAutomaticTolerance = usesAutomaticTolerance
            matchingTolerance = usesAutomaticTolerance ? automaticTolerance : Float(matchTolerance)
            let effective = matchingTolerance
            stateLock.unlock()
            effectiveTolerance = Double(effective)
        }
    }

    @Published var matchTolerance: Double {
        didSet {
            UserDefaults.standard.set(matchTolerance, forKey: Self.toleranceKey)
            stateLock.lock()
            if !matchingUsesAutomaticTolerance {
                matchingTolerance = Float(matchTolerance)
            }
            let effective = matchingTolerance
            stateLock.unlock()
            effectiveTolerance = Double(effective)
        }
    }

    private struct FaceDescriptor {
        let variants: [VNFeaturePrintObservation]
    }

    private static let enabledKey = "faceExclusionsEnabled"
    private static let automaticToleranceKey = "faceExclusionsAutomaticTolerance"
    private static let toleranceKey = "faceExclusionTolerance"
    private static let toleranceVersionKey = "faceExclusionToleranceVersion"
    private static let currentToleranceVersion = 3
    private static let defaultTolerance = 0.72
    private static let minimumAutomaticTolerance: Float = 0.72
    private static let maximumAutomaticTolerance: Float = 0.82

    private let processingQueue = DispatchQueue(label: "com.john.PiggyCam.face-exclusions")
    private let stateLock = NSLock()
    private var descriptors: [UUID: FaceDescriptor] = [:]
    private var matchingEnabled: Bool
    private var matchingUsesAutomaticTolerance: Bool
    private var matchingTolerance: Float
    private var automaticTolerance: Float = 0.72

    private var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ExcludedFaces", isDirectory: true)
    }

    init() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let storedVersion = defaults.integer(forKey: Self.toleranceVersionKey)
        let tolerance: Double
        if storedVersion < Self.currentToleranceVersion {
            tolerance = Self.defaultTolerance
            defaults.set(tolerance, forKey: Self.toleranceKey)
            defaults.set(Self.currentToleranceVersion, forKey: Self.toleranceVersionKey)
        } else {
            tolerance = defaults.object(forKey: Self.toleranceKey) as? Double ?? Self.defaultTolerance
        }
        let automatic = defaults.object(forKey: Self.automaticToleranceKey) as? Bool ?? true

        isEnabled = enabled
        usesAutomaticTolerance = automatic
        matchTolerance = tolerance
        effectiveTolerance = automatic ? Self.defaultTolerance : tolerance
        matchingEnabled = enabled
        matchingUsesAutomaticTolerance = automatic
        matchingTolerance = Float(automatic ? Self.defaultTolerance : tolerance)
        loadStoredFaces()
    }

    func addPhotos(_ dataItems: [Data]) async -> Int {
        guard !dataItems.isEmpty else { return 0 }
        await MainActor.run {
            isProcessing = true
            statusMessage = "正在分析參考照片…"
        }

        return await withCheckedContinuation { continuation in
            processingQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: 0)
                    return
                }
                let directory = self.prepareStorageDirectory()

                var additions: [(ExcludedFace, FaceDescriptor)] = []
                var rejectedCount = 0
                for data in dataItems {
                    guard let preparedData = self.preparedJPEGData(from: data),
                          let descriptor = self.makeReferenceDescriptor(from: preparedData),
                          let image = UIImage(data: preparedData) else {
                        rejectedCount += 1
                        continue
                    }
                    let id = UUID()
                    let fileURL = directory.appendingPathComponent("\(id.uuidString).jpg")
                    do {
                        try preparedData.write(to: fileURL, options: .atomic)
                        let thumbnail = image.preparingThumbnail(of: CGSize(width: 180, height: 180)) ?? image
                        additions.append((ExcludedFace(id: id, thumbnail: thumbnail, fileURL: fileURL), descriptor))
                    } catch {
                        rejectedCount += 1
                    }
                }

                self.stateLock.lock()
                additions.forEach { self.descriptors[$0.0.id] = $0.1 }
                let effective = self.recalculateToleranceLocked()
                self.stateLock.unlock()

                DispatchQueue.main.async {
                    self.faces.append(contentsOf: additions.map { $0.0 })
                    self.effectiveTolerance = Double(effective)
                    self.isProcessing = false
                    if additions.isEmpty {
                        self.statusMessage = "找不到清楚且完整的人臉，請改用正面照片。"
                    } else if rejectedCount > 0 {
                        self.statusMessage = "已加入 \(additions.count) 張；另有 \(rejectedCount) 張未偵測到人臉。"
                    } else {
                        self.statusMessage = "已加入 \(additions.count) 張，並完成辨識校準。"
                    }
                    continuation.resume(returning: additions.count)
                }
            }
        }
    }

    func removeFace(id: UUID) {
        guard let face = faces.first(where: { $0.id == id }) else { return }
        faces.removeAll { $0.id == id }
        stateLock.lock()
        descriptors.removeValue(forKey: id)
        let effective = recalculateToleranceLocked()
        stateLock.unlock()
        effectiveTolerance = Double(effective)
        processingQueue.async {
            try? FileManager.default.removeItem(at: face.fileURL)
        }
        statusMessage = "已移除排除人臉。"
    }

    func removeAllFaces() {
        faces.removeAll()
        stateLock.lock()
        descriptors.removeAll()
        let effective = recalculateToleranceLocked()
        stateLock.unlock()
        effectiveTolerance = Double(effective)
        let directory = storageDirectory
        processingQueue.async {
            try? FileManager.default.removeItem(at: directory)
        }
        statusMessage = "已清除所有排除人臉。"
    }

    func shouldExclude(faceIn image: CIImage, faceRect: CGRect) -> Bool {
        stateLock.lock()
        let enabled = matchingEnabled
        let references = Array(descriptors.values)
        let tolerance = matchingTolerance
        stateLock.unlock()

        guard enabled, !references.isEmpty,
              let candidate = makeFaceDescriptor(
                from: standardizedFaceImage(from: image, faceRect: faceRect),
                includeMirroredVariant: false
              )?.variants.first else { return false }

        var nearestDistance = Float.greatestFiniteMagnitude
        for reference in references {
            for variant in reference.variants {
                var distance: Float = 0
                if (try? candidate.computeDistance(&distance, to: variant)) != nil {
                    nearestDistance = min(nearestDistance, distance)
                }
            }
        }
        return nearestDistance <= tolerance
    }

    private func loadStoredFaces() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            let directory = self.prepareStorageDirectory()
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            var loaded: [(ExcludedFace, FaceDescriptor)] = []
            for url in urls where url.pathExtension.lowercased() == "jpg" {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let originalData = try? Data(contentsOf: url) else { continue }
                let migratedData = self.migratedJPEGDataIfNeeded(from: originalData)
                let data = migratedData ?? originalData
                guard let image = UIImage(data: data),
                      let descriptor = self.makeReferenceDescriptor(from: data) else { continue }
                if migratedData != nil {
                    try? data.write(to: url, options: .atomic)
                }
                let thumbnail = image.preparingThumbnail(of: CGSize(width: 180, height: 180)) ?? image
                loaded.append((ExcludedFace(id: id, thumbnail: thumbnail, fileURL: url), descriptor))
            }

            self.stateLock.lock()
            loaded.forEach { self.descriptors[$0.0.id] = $0.1 }
            let effective = self.recalculateToleranceLocked()
            self.stateLock.unlock()
            DispatchQueue.main.async {
                self.faces = loaded.map { $0.0 }
                self.effectiveTolerance = Double(effective)
            }
        }
    }

    private func preparedJPEGData(from data: Data) -> Data? {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
        let maximumDimension: CGFloat = 1_600
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let targetLargestSide = min(max(pixelWidth, pixelHeight), maximumDimension)
        let displayedAspect = max(image.size.width, 1) / max(image.size.height, 1)
        let size: CGSize
        if displayedAspect >= 1 {
            size = CGSize(width: targetLargestSide, height: targetLargestSide / displayedAspect)
        } else {
            size = CGSize(width: targetLargestSide * displayedAspect, height: targetLargestSide)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let normalized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return normalized.jpegData(compressionQuality: 0.9)
    }

    private func migratedJPEGDataIfNeeded(from data: Data) -> Data? {
        guard let image = UIImage(data: data), let cgImage = image.cgImage,
              max(cgImage.width, cgImage.height) > 1_600 else { return nil }
        return preparedJPEGData(from: data)
    }

    private func prepareStorageDirectory() -> URL {
        var directory = storageDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? directory.setResourceValues(resourceValues)
        return directory
    }

    private func makeReferenceDescriptor(from data: Data) -> FaceDescriptor? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)
        guard (try? handler.perform([faceRequest])) != nil,
              let face = faceRequest.results?.max(by: {
                  $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
              }) else { return nil }

        let box = face.boundingBox
        let faceRect = CGRect(
            x: image.extent.minX + box.minX * image.extent.width,
            y: image.extent.minY + box.minY * image.extent.height,
            width: box.width * image.extent.width,
            height: box.height * image.extent.height
        )
        return makeFaceDescriptor(
            from: standardizedFaceImage(from: image, faceRect: faceRect),
            includeMirroredVariant: true
        )
    }

    private func standardizedFaceImage(from image: CIImage, faceRect: CGRect) -> CIImage {
        let maximumSide = min(image.extent.width, image.extent.height)
        let side = min(max(faceRect.width, faceRect.height) * 1.16, maximumSide)
        var origin = CGPoint(x: faceRect.midX - side / 2, y: faceRect.midY - side / 2)
        origin.x = min(max(origin.x, image.extent.minX), image.extent.maxX - side)
        origin.y = min(max(origin.y, image.extent.minY), image.extent.maxY - side)
        let cropRect = CGRect(origin: origin, size: CGSize(width: side, height: side))
        let cropped = image.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        let targetSize: CGFloat = 256
        let resized = cropped.transformed(by: CGAffineTransform(
            scaleX: targetSize / max(cropped.extent.width, 1),
            y: targetSize / max(cropped.extent.height, 1)
        ))
        return resized
            .cropped(to: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.08
            ])
    }

    private func makeFaceDescriptor(
        from image: CIImage,
        includeMirroredVariant: Bool
    ) -> FaceDescriptor? {
        guard let original = makeFeaturePrint(from: image) else { return nil }
        guard includeMirroredVariant else { return FaceDescriptor(variants: [original]) }
        let mirroredImage = image.transformed(by: CGAffineTransform(
            a: -1,
            b: 0,
            c: 0,
            d: 1,
            tx: image.extent.maxX + image.extent.minX,
            ty: 0
        ))
        guard let mirrored = makeFeaturePrint(from: mirroredImage) else {
            return FaceDescriptor(variants: [original])
        }
        return FaceDescriptor(variants: [original, mirrored])
    }

    private func makeFeaturePrint(from image: CIImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }

    private func recalculateToleranceLocked() -> Float {
        let values = Array(descriptors.values)
        var nearestDistances: [Float] = []
        for firstIndex in values.indices {
            var nearest = Float.greatestFiniteMagnitude
            for secondIndex in values.indices where firstIndex != secondIndex {
                nearest = min(nearest, descriptorDistance(values[firstIndex], values[secondIndex]))
            }
            if nearest.isFinite, nearest <= 0.76 {
                nearestDistances.append(nearest)
            }
        }

        if let largestRelatedDistance = nearestDistances.max() {
            automaticTolerance = min(
                max(largestRelatedDistance + 0.08, Self.minimumAutomaticTolerance),
                Self.maximumAutomaticTolerance
            )
        } else {
            automaticTolerance = Self.minimumAutomaticTolerance
        }
        matchingTolerance = matchingUsesAutomaticTolerance
            ? automaticTolerance
            : Float(matchTolerance)
        return matchingTolerance
    }

    private func descriptorDistance(_ first: FaceDescriptor, _ second: FaceDescriptor) -> Float {
        var nearest = Float.greatestFiniteMagnitude
        for firstVariant in first.variants {
            for secondVariant in second.variants {
                var distance: Float = 0
                if (try? firstVariant.computeDistance(&distance, to: secondVariant)) != nil {
                    nearest = min(nearest, distance)
                }
            }
        }
        return nearest
    }

}
