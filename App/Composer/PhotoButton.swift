import PhotosUI
import SwiftUI
import UIKit

/// The camera button of the composer and the New task sheet: Photos, Camera
/// and Last screenshot. The picked photo is encoded off the main thread and
/// handed to `onAttach`; `notice` says why a pick failed.
@MainActor
struct PhotoButton: View {
    let isDisabled: Bool
    @Binding var isPreparing: Bool
    @Binding var notice: String?
    let onAttach: (PendingImage) -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var showsPhotos = false
    @State private var showsCamera = false

    var body: some View {
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
        .disabled(isDisabled || isPreparing)
        .accessibilityLabel("Add a photo")
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
            onAttach(pending)
        } else {
            notice = "Could not read the photo."
        }
    }
}
