import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var mode: CaptureMode = .photo
    @State private var timerSeconds = 0
    @State private var gridEnabled = false
    @State private var exposureExpanded = false
    @State private var lastMagnification: CGFloat = 1
    @State private var showPhotoBrowser = false
    @State private var selectedLibraryItem: PhotosPickerItem?

    var body: some View {
        GeometryReader { proxy in
            let topHeight = min(max(proxy.size.height * 0.13, 72), 118)
            let previewHeight = min(proxy.size.width * 4 / 3, proxy.size.height - topHeight - 188)

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    topControls
                        .frame(height: topHeight, alignment: .bottom)

                    cameraPreview
                        .frame(width: proxy.size.width, height: previewHeight)

                    bottomControls
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if !camera.isReady {
                    permissionOverlay
                }
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: camera.message)
        .animation(.easeInOut(duration: 0.15), value: camera.shutterFlashVisible)
        .task { camera.start() }
        .onDisappear { camera.stop() }
        .photosPicker(
            isPresented: $showPhotoBrowser,
            selection: $selectedLibraryItem,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .automatic
        )
        .onChange(of: selectedLibraryItem) { _, item in
            updateThumbnail(from: item)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            camera.refreshPhotoLibraryThumbnail()
        }
    }

    private var topControls: some View {
        VStack(spacing: 10) {
            if camera.isRecording {
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(formattedDuration)
                        .monospacedDigit()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(.black.opacity(0.48), in: Capsule())
            }

            HStack(spacing: 24) {
                Button(action: camera.cycleFlashMode) {
                    Image(systemName: camera.flashMode.symbolName)
                        .foregroundStyle(camera.flashMode == .off ? .white : .yellow)
                }
                .accessibilityLabel("閃光燈：\(camera.flashMode.title)")

                Menu {
                    timerButton(title: "關閉", seconds: 0)
                    timerButton(title: "3 秒", seconds: 3)
                    timerButton(title: "10 秒", seconds: 10)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "timer")
                        if timerSeconds > 0 {
                            Text("\(timerSeconds)")
                                .font(.caption2.bold())
                        }
                    }
                    .foregroundStyle(timerSeconds > 0 ? .yellow : .white)
                }
                .accessibilityLabel("自拍計時器")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { exposureExpanded.toggle() }
                } label: {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(exposureExpanded ? .yellow : .white)
                }
                .accessibilityLabel("曝光補償")

                Button {
                    gridEnabled.toggle()
                } label: {
                    Image(systemName: "square.grid.3x3")
                        .foregroundStyle(gridEnabled ? .yellow : .white)
                }
                .accessibilityLabel(gridEnabled ? "關閉格線" : "開啟格線")

                Button(action: camera.togglePigEffect) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(camera.pigEffectEnabled ? .pink : .white)
                }
                .accessibilityLabel(camera.pigEffectEnabled ? "關閉小豬效果" : "開啟小豬效果")
            }
            .font(.system(size: 20, weight: .semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.white.opacity(0.1), in: Capsule())
            .disabled(camera.isRecording)
            .opacity(camera.isRecording ? 0.55 : 1)

            if exposureExpanded && !camera.isRecording {
                HStack(spacing: 10) {
                    Image(systemName: "sun.min.fill")
                    Slider(
                        value: Binding(
                            get: { camera.exposureBias },
                            set: { camera.setExposureBias($0) }
                        ),
                        in: camera.minimumExposureBias...camera.maximumExposureBias
                    )
                    .tint(.yellow)
                    Image(systemName: "sun.max.fill")
                    Text(camera.exposureBias.formatted(.number.precision(.fractionLength(1))))
                        .monospacedDigit()
                        .frame(width: 34)
                }
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(.horizontal, 26)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, 12)
    }

    private var cameraPreview: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if let frame = camera.previewFrame {
                    Image(decorative: frame, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.aperture")
                            .font(.system(size: 52, weight: .light))
                            .foregroundStyle(.pink)
                        Text("正在準備小豬相機…")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }

                if gridEnabled { cameraGrid }

                if let point = camera.focusPoint {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(.yellow, lineWidth: 1.5)
                        .frame(width: 72, height: 72)
                        .position(
                            x: point.x * proxy.size.width,
                            y: point.y * proxy.size.height
                        )
                        .transition(.opacity)
                }

                if let countdown = camera.countdown {
                    Text("\(countdown)")
                        .font(.system(size: 92, weight: .light, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                        .transition(.scale.combined(with: .opacity))
                }

                VStack {
                    Spacer()
                    zoomControls
                        .padding(.bottom, 18)
                }

                if let message = camera.message {
                    VStack {
                        Text(message)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(.black.opacity(0.68), in: Capsule())
                            .padding(.top, 16)
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Color.white
                    .opacity(camera.shutterFlashVisible ? 0.82 : 0)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    camera.focus(at: CGPoint(
                        x: value.location.x / proxy.size.width,
                        y: value.location.y / proxy.size.height
                    ))
                }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        let incremental = value / lastMagnification
                        lastMagnification = value
                        camera.setZoom(camera.zoomFactor * incremental)
                    }
                    .onEnded { _ in lastMagnification = 1 }
            )
        }
        .clipped()
    }

    private var cameraGrid: some View {
        GeometryReader { proxy in
            Path { path in
                for index in 1...2 {
                    let x = proxy.size.width * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    let y = proxy.size.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.45), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
    }

    private var zoomControls: some View {
        HStack(spacing: 14) {
            ForEach(camera.availableZoomFactors, id: \.self) { factor in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    camera.setZoom(factor)
                } label: {
                    Text(zoomLabel(factor))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelectedZoom(factor) ? .yellow : .white)
                        .frame(width: isSelectedZoom(factor) ? 48 : 34, height: isSelectedZoom(factor) ? 48 : 34)
                        .background(.black.opacity(isSelectedZoom(factor) ? 0.58 : 0.38), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(camera.isRecording)
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
            HStack {
                Button {
                    showPhotoBrowser = true
                } label: {
                    Group {
                        if let thumbnail = camera.lastThumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo.fill")
                                .font(.system(size: 19))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .frame(width: 54, height: 54)
                    .background(.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(camera.isRecording)
                .accessibilityLabel("瀏覽照片與影片")

                Spacer()

                shutterButton

                Spacer()

                Button(action: switchCamera) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!camera.isReady || camera.isRecording || camera.countdown != nil)
                .opacity(camera.isRecording ? 0.4 : 1)
                .accessibilityLabel("翻轉前後鏡頭")
            }
            .padding(.horizontal, 32)

            HStack(spacing: 0) {
                modeButton(.video)
                modeButton(.photo)
            }
            .padding(4)
            .background(.white.opacity(0.09), in: Capsule())
        }
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var shutterButton: some View {
        Button(action: capture) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.75), lineWidth: 4)
                    .frame(width: 82, height: 82)

                if mode == .video {
                    RoundedRectangle(cornerRadius: camera.isRecording ? 7 : 34)
                        .fill(.red)
                        .frame(
                            width: camera.isRecording ? 32 : 66,
                            height: camera.isRecording ? 32 : 66
                        )
                } else {
                    Circle().fill(.white).frame(width: 68, height: 68)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!camera.isReady || camera.countdown != nil)
        .scaleEffect(camera.countdown == nil ? 1 : 0.92)
        .accessibilityLabel(mode == .photo ? "拍照" : (camera.isRecording ? "停止錄影" : "開始錄影"))
    }

    private func modeButton(_ item: CaptureMode) -> some View {
        Button {
            guard !camera.isRecording else { return }
            withAnimation(.easeInOut(duration: 0.18)) { mode = item }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Text(item.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(mode == item ? .yellow : .white)
                .frame(width: 80, height: 38)
                .background(mode == item ? .white.opacity(0.1) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
    }

    @ViewBuilder
    private var permissionOverlay: some View {
        if let problem = camera.permissionProblem {
            VStack(spacing: 14) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.pink)
                Text("需要相機權限").font(.title3.bold())
                Text(problem)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("前往設定") { camera.openSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
            }
            .padding(28)
            .frame(maxWidth: 330)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding()
        }
    }

    private var formattedDuration: String {
        let seconds = Int(camera.recordingDuration)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func timerButton(title: String, seconds: Int) -> some View {
        Button {
            timerSeconds = seconds
        } label: {
            if timerSeconds == seconds {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func zoomLabel(_ factor: CGFloat) -> String {
        factor == floor(factor) ? "\(Int(factor))×" : String(format: "%.1f×", Double(factor))
    }

    private func isSelectedZoom(_ factor: CGFloat) -> Bool {
        abs(camera.zoomFactor - factor) < 0.08
    }

    private func capture() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch mode {
        case .photo:
            camera.takePhoto(after: timerSeconds)
        case .video:
            camera.isRecording ? camera.stopRecording() : camera.startRecording()
        }
    }

    private func switchCamera() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        camera.switchCamera()
    }

    private func updateThumbnail(from item: PhotosPickerItem?) {
        guard let item else {
            camera.refreshPhotoLibraryThumbnail()
            return
        }
        guard item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) else {
            camera.refreshPhotoLibraryThumbnail()
            return
        }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            await MainActor.run { camera.useBrowserThumbnail(image) }
        }
    }
}

private enum CaptureMode: String, CaseIterable, Identifiable {
    case photo
    case video

    var id: String { rawValue }
    var title: String { self == .photo ? "拍照" : "錄影" }
}

#Preview {
    ContentView()
}
