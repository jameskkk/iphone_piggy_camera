import Combine
import CoreImage
import Photos
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

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            stateLock.lock()
            matchingEnabled = isEnabled
            stateLock.unlock()
        }
    }

    @Published var matchTolerance: Double {
        didSet {
            UserDefaults.standard.set(matchTolerance, forKey: Self.toleranceKey)
            stateLock.lock()
            matchingTolerance = Float(matchTolerance)
            stateLock.unlock()
        }
    }

    private static let enabledKey = "faceExclusionsEnabled"
    private static let toleranceKey = "faceExclusionTolerance"
    private static let defaultTolerance = 0.52

    private let processingQueue = DispatchQueue(label: "com.john.PiggyCam.face-exclusions")
    private let stateLock = NSLock()
    private var descriptors: [UUID: VNFeaturePrintObservation] = [:]
    private var matchingEnabled: Bool
    private var matchingTolerance: Float

    private var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ExcludedFaces", isDirectory: true)
    }

    init() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let tolerance = defaults.object(forKey: Self.toleranceKey) as? Double ?? Self.defaultTolerance
        isEnabled = enabled
        matchTolerance = tolerance
        matchingEnabled = enabled
        matchingTolerance = Float(tolerance)
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

                var additions: [(ExcludedFace, VNFeaturePrintObservation)] = []
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
                self.stateLock.unlock()

                DispatchQueue.main.async {
                    self.faces.append(contentsOf: additions.map { $0.0 })
                    self.isProcessing = false
                    if additions.isEmpty {
                        self.statusMessage = "找不到清楚且完整的人臉，請改用正面照片。"
                    } else if rejectedCount > 0 {
                        self.statusMessage = "已加入 \(additions.count) 張；另有 \(rejectedCount) 張未偵測到人臉。"
                    } else {
                        self.statusMessage = "已加入 \(additions.count) 張排除人臉。"
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
        stateLock.unlock()
        processingQueue.async {
            try? FileManager.default.removeItem(at: face.fileURL)
        }
        statusMessage = "已移除排除人臉。"
    }

    func removeAllFaces() {
        faces.removeAll()
        stateLock.lock()
        descriptors.removeAll()
        stateLock.unlock()
        let directory = storageDirectory
        processingQueue.async {
            try? FileManager.default.removeItem(at: directory)
        }
        statusMessage = "已清除所有排除人臉。"
    }

    func shouldExclude(faceImage: CIImage) -> Bool {
        stateLock.lock()
        let enabled = matchingEnabled
        let references = Array(descriptors.values)
        let tolerance = matchingTolerance
        stateLock.unlock()

        guard enabled, !references.isEmpty,
              let candidate = makeFeaturePrint(from: faceImage) else { return false }
        for reference in references {
            var distance: Float = 0
            if (try? candidate.computeDistance(&distance, to: reference)) != nil,
               distance <= tolerance {
                return true
            }
        }
        return false
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

            var loaded: [(ExcludedFace, VNFeaturePrintObservation)] = []
            for url in urls where url.pathExtension.lowercased() == "jpg" {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let data = try? Data(contentsOf: url),
                      let image = UIImage(data: data),
                      let descriptor = self.makeReferenceDescriptor(from: data) else { continue }
                let thumbnail = image.preparingThumbnail(of: CGSize(width: 180, height: 180)) ?? image
                loaded.append((ExcludedFace(id: id, thumbnail: thumbnail, fileURL: url), descriptor))
            }

            self.stateLock.lock()
            loaded.forEach { self.descriptors[$0.0.id] = $0.1 }
            self.stateLock.unlock()
            DispatchQueue.main.async {
                self.faces = loaded.map { $0.0 }
            }
        }
    }

    private func preparedJPEGData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maximumDimension: CGFloat = 1_600
        let largestSide = max(image.size.width, image.size.height)
        let scale = min(maximumDimension / max(largestSide, 1), 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let normalized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return normalized.jpegData(compressionQuality: 0.9)
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

    private func makeReferenceDescriptor(from data: Data) -> VNFeaturePrintObservation? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)
        guard (try? handler.perform([faceRequest])) != nil,
              let face = faceRequest.results?.max(by: {
                  $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
              }) else { return nil }

        let box = face.boundingBox
        let rect = CGRect(
            x: image.extent.minX + box.minX * image.extent.width,
            y: image.extent.minY + box.minY * image.extent.height,
            width: box.width * image.extent.width,
            height: box.height * image.extent.height
        )
        let expanded = rect.insetBy(dx: -rect.width * 0.12, dy: -rect.height * 0.12)
            .intersection(image.extent)
        return makeFeaturePrint(from: image.cropped(to: expanded))
    }

    private func makeFeaturePrint(from image: CIImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }
}
