import PhotosUI
import SwiftUI
import UIKit

/// The bar at the bottom of Task detail: a camera button (Photos, Camera,
/// Last screenshot), the text field and Send. A pending photo shows as a
/// removable thumbnail; the send bubble shows upload progress and Retry.
@MainActor
struct ComposerBar: View {
    @Bindable var composer: CommentComposer
    @State private var photoItem: PhotosPickerItem?
    @State private var showsPhotos = false
    @State private var showsCamera = false
    @State private var isPreparing = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if composer.phase != .idle {
                SendBubble(composer: composer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let image = composer.image {
                PendingThumbnail(image: image, canRemove: !composer.isBusy) {
                    composer.removeImage()
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                photoMenu
                TextField("Comment", text: $composer.text, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.background, in: .rect(cornerRadius: 18))
                    .disabled(composer.isBusy)
                Button {
                    notice = nil
                    Task { await composer.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(!composer.canSend || isPreparing)
                .accessibilityLabel("Send")
            }
        }
        .animation(.snappy, value: composer.phase)
        .animation(.snappy, value: composer.image == nil)
        .photosPicker(isPresented: $showsPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await attachPicked(item) }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { image in
                Task { await attach(image: image, filename: "photo.jpg") }
            }
            .ignoresSafeArea()
        }
    }

    private var photoMenu: some View {
        Menu {
            Button {
                showsPhotos = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            if CameraPicker.isAvailable {
                Button {
                    showsCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                }
            }
            Button {
                Task { await attachLastScreenshot() }
            } label: {
                Label("Last screenshot", systemImage: "camera.viewfinder")
            }
        } label: {
            Group {
                if isPreparing {
                    ProgressView()
                } else {
                    Image(systemName: "camera.fill")
                        .font(.title3)
                }
            }
            .frame(width: 36, height: 36)
        }
        .disabled(composer.isBusy || isPreparing)
        .accessibilityLabel("Add a photo")
    }

    // MARK: Photos

    private func attachPicked(_ item: PhotosPickerItem) async {
        notice = nil
        isPreparing = true
        defer { isPreparing = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            notice = "Could not load the photo."
            return
        }
        await attach(data: data, filename: "photo.jpg")
    }

    private func attachLastScreenshot() async {
        notice = nil
        isPreparing = true
        defer { isPreparing = false }
        do {
            let data = try await LastScreenshot.data()
            await attach(data: data, filename: "screenshot.jpg")
        } catch LastScreenshot.Failure.noAccess {
            notice = "Allow access to Photos in Settings to attach your last screenshot."
        } catch {
            notice = "No screenshot found."
        }
    }

    private func attach(data: Data, filename: String) async {
        let pending = await Task.detached(priority: .userInitiated) {
            PhotoEncoder.pendingImage(from: data, filename: filename)
        }.value
        finish(pending)
    }

    private func attach(image: UIImage, filename: String) async {
        notice = nil
        isPreparing = true
        defer { isPreparing = false }
        let pending = await Task.detached(priority: .userInitiated) {
            PhotoEncoder.pendingImage(from: image, filename: filename)
        }.value
        finish(pending)
    }

    private func finish(_ pending: PendingImage?) {
        if let pending {
            composer.attach(pending)
        } else {
            notice = "Could not read the photo."
        }
    }
}

/// Progress while the photo uploads and the comment sends; the error and
/// Retry when the send failed.
private struct SendBubble: View {
    let composer: CommentComposer

    var body: some View {
        HStack(spacing: 10) {
            switch composer.phase {
            case .uploading(let progress):
                ProgressView(value: progress)
                    .frame(maxWidth: 120)
                Text("Uploading photo…")
            case .sending:
                ProgressView()
                Text("Sending…")
            case .failed(let message):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Retry") {
                    Task { await composer.retry() }
                }
                .buttonStyle(.bordered)
            case .idle:
                EmptyView()
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 14))
    }
}

/// The photo waiting to be sent, with a remove button.
private struct PendingThumbnail: View {
    let image: PendingImage
    let canRemove: Bool
    let onRemove: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel("Photo to send")

            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.title3)
                }
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove photo")
            }
        }
        .task(id: image.data) {
            thumbnail = await UIImage(data: image.data)?.byPreparingThumbnail(ofSize: CGSize(width: 192, height: 192))
        }
    }
}
