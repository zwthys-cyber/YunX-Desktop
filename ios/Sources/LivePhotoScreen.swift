// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import Photos
import PhotosUI

struct LivePhotoRoute: Identifiable {
    let id = UUID()
    let photo: URL
    let movie: URL
}
struct ExportFilesRoute: Identifiable { let id = UUID(); let files: [URL] }

@MainActor
struct LivePhotoScreen: View {
    let photoURL: URL
    let movieURL: URL
    @State private var livePhoto: PHLivePhoto?
    @State private var message: String?
    @State private var saving = false
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack {
                if let livePhoto { NativeLivePhotoView(photo: livePhoto); Text("长按预览动态效果").font(.footnote).foregroundStyle(.secondary) }
                else if message == nil { ProgressView("正在读取动态照片…") }
                if let message { Text(message).font(.footnote).padding() }
                Button(saved ? "已保存到照片" : "保存到照片") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(livePhoto == nil || saving || saved)
                if saving { ProgressView() }
            }.navigationTitle("动态照片").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .task(id: photoURL) {
                    do { livePhoto = try await LivePhotoAssembly.preview(photo: photoURL, movie: movieURL) }
                    catch is CancellationError { }
                    catch { message = "系统无法读取此动态照片，请检查配对文件是否完整。" }
                }
        }
    }
    private func save() async {
        guard !saving, !saved else { return }; saving = true; defer { saving = false }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else { message = "未获得添加照片权限，可在系统设置中允许云析添加照片，或导出配对文件。"; return }
        do {
            let photo = photoURL, movie = movieURL
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: photo, options: nil)
                request.addResource(with: .pairedVideo, fileURL: movie, options: nil)
            }
            saved = true; message = "已保存为系统动态照片。"
        } catch { message = "系统照片保存失败，应用内配对文件已保留，请稍后重试。" }
    }
}

@MainActor
private struct NativeLivePhotoView: UIViewRepresentable {
    let photo: PHLivePhoto
    func makeUIView(context: Context) -> PHLivePhotoView { let view = PHLivePhotoView(); view.contentMode = .scaleAspectFit; return view }
    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== photo { view.livePhoto = photo; view.startPlayback(with: .hint) }
    }
    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: ()) { view.stopPlayback(); view.livePhoto = nil }
}

@MainActor
struct ExportFilesView: UIViewControllerRepresentable {
    let files: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: files, applicationActivities: nil) }
    func updateUIViewController(_ view: UIActivityViewController, context: Context) { }
}
