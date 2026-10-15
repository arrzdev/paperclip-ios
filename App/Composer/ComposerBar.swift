import SwiftUI
import UIKit

/// The bar at the bottom of Task detail: a camera button (`PhotoButton`),
/// the text field and Send. A pending photo shows as a removable
/// thumbnail; the send bubble shows upload progress and Retry.
@MainActor
struct ComposerBar: View {
    @Bindable var composer: CommentComposer
    @State private var isPreparing = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if composer.phase != .idle {
                SendBubble(phase: composer.phase) {
                    Task { await composer.retry() }
                }
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
                PhotoButton(isDisabled: composer.isBusy, isPreparing: $isPreparing, notice: $notice) {
                    composer.attach($0)
                }
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
    }
}

/// Progress while the photo uploads and the comment sends; the error and
/// Retry when the send failed.
struct SendBubble: View {
    let phase: SendPhase
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
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
                Spacer(minLength: 8)
                Button("Retry", action: onRetry)
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
struct PendingThumbnail: View {
    let image: PendingImage
    let canRemove: Bool
    let onRemove: () -> Void
    @State private var thumbnail: UIImage?
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 64

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
            .frame(width: size, height: size)
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
