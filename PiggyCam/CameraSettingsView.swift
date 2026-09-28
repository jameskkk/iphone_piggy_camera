import PhotosUI
import SwiftUI

struct CameraSettingsView: View {
    @ObservedObject var store: FaceExclusionStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var confirmRemoveAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("啟用排除人臉", isOn: $store.isEnabled)

                    PhotosPicker(
                        selection: $selectedItems,
                        maxSelectionCount: 10,
                        matching: .images,
                        preferredItemEncoding: .automatic
                    ) {
                        Label("加入參考照片", systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(store.isProcessing)

                    if store.isProcessing {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在建立人臉特徵…")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let message = store.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("排除人臉")
                } footer: {
                    Text("每張照片會使用畫面中最大的一張臉。建議選擇光線充足、正面且沒有遮擋的照片；同一人物可加入不同角度以提升效果。")
                }

                Section("已加入的人臉") {
                    if store.faces.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("尚未加入任何排除人臉")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    } else {
                        ForEach(Array(store.faces.enumerated()), id: \.element.id) { index, face in
                            HStack(spacing: 14) {
                                Image(uiImage: face.thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 54, height: 54)
                                    .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("排除人物 \(index + 1)")
                                        .font(.body.weight(.medium))
                                    Text("只在此裝置上比對")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button(role: .destructive) {
                                    store.removeFace(id: face.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("移除排除人物 \(index + 1)")
                            }
                        }

                        Button("清除所有排除人臉", role: .destructive) {
                            confirmRemoveAll = true
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("比對容許度")
                            Spacer()
                            Text(store.matchTolerance.formatted(.number.precision(.fractionLength(2))))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $store.matchTolerance, in: 0.38...0.68, step: 0.01)
                            .tint(.pink)
                    }
                } header: {
                    Text("辨識調整")
                } footer: {
                    Text("數值較低會減少誤排除，但可能漏掉角度差異較大的本人；數值較高則較寬鬆。建議先使用預設值。")
                }

                Section("隱私") {
                    Label("所有人臉偵測與比對都在 iPhone 上完成", systemImage: "iphone.gen3")
                    Label("參考照片保存在 PiggyCam 的 App 沙盒", systemImage: "lock.shield")
                    Label("不會上傳照片或人臉特徵", systemImage: "icloud.slash")
                }
            }
            .navigationTitle("PiggyCam 設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: selectedItems) { _, items in
                importSelectedItems(items)
            }
            .confirmationDialog(
                "確定清除所有排除人臉？",
                isPresented: $confirmRemoveAll,
                titleVisibility: .visible
            ) {
                Button("全部清除", role: .destructive) { store.removeAllFaces() }
                Button("取消", role: .cancel) { }
            }
        }
    }

    private func importSelectedItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var dataItems: [Data] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    dataItems.append(data)
                }
            }
            _ = await store.addPhotos(dataItems)
            await MainActor.run { selectedItems = [] }
        }
    }
}
