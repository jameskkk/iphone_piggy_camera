import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var mode: CaptureMode = .photo

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            cameraPreview

            if !camera.isReady {
                permissionOverlay
            }

            VStack(spacing: 0) {
                header
                Spacer()
                if let message = camera.message {
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                controls
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: camera.message)
        .task { camera.start() }
        .onDisappear { camera.stop() }
    }

    @ViewBuilder
    private var cameraPreview: some View {
        if let frame = camera.previewFrame {
            GeometryReader { proxy in
                Image(decorative: frame, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
        } else {
            VStack(spacing: 14) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.pink)
                Text("正在準備小豬相機…")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private var header: some View {
        HStack {
            Label("PiggyCam", systemImage: "sparkles")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.42), in: Capsule())

            Spacer()

            if camera.isRecording {
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text("錄影中")
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.black.opacity(0.55), in: Capsule())
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 20) {
            Picker("拍攝模式", selection: $mode) {
                ForEach(CaptureMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .disabled(camera.isRecording)

            HStack {
                Color.clear.frame(width: 58, height: 58)
                Spacer()

                Button(action: capture) {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 5)
                            .frame(width: 78, height: 78)
                        if mode == .video {
                            RoundedRectangle(cornerRadius: camera.isRecording ? 7 : 30)
                                .fill(.red)
                                .frame(
                                    width: camera.isRecording ? 32 : 62,
                                    height: camera.isRecording ? 32 : 62
                                )
                        } else {
                            Circle().fill(.white).frame(width: 62, height: 62)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!camera.isReady)
                .accessibilityLabel(mode == .photo ? "拍照" : (camera.isRecording ? "停止錄影" : "開始錄影"))

                Spacer()

                Button(action: camera.switchCamera) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(.black.opacity(0.48), in: Circle())
                }
                .disabled(!camera.isReady || camera.isRecording)
                .opacity(camera.isRecording ? 0.45 : 1)
                .accessibilityLabel("翻轉前後鏡頭")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(.black.opacity(0.36), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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

    private func capture() {
        switch mode {
        case .photo: camera.takePhoto()
        case .video: camera.isRecording ? camera.stopRecording() : camera.startRecording()
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
