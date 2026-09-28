import AVFoundation
import AVKit
import SwiftUI

struct MediaDrawerView: View {
    let items: [MediaRecord]
    let initialItemID: String
    let mediaURL: (MediaRecord) -> URL

    @Environment(\.dismiss) private var dismiss
    @State private var focusedItemID: String?
    @State private var selectedDetent: PresentationDetent = .large

    init(
        items: [MediaRecord],
        initialItemID: String,
        mediaURL: @escaping (MediaRecord) -> URL
    ) {
        self.items = items
        self.initialItemID = initialItemID
        self.mediaURL = mediaURL
        _focusedItemID = State(initialValue: initialItemID)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        let size = cardSize(for: item, in: proxy.size)

                        MediaCard(
                            item: item,
                            url: mediaURL(item),
                            isActive: focusedItemID == item.id
                        )
                        .frame(width: size.width, height: size.height)
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, proxy.size.width * 0.09, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $focusedItemID, anchor: .center)
            .accessibilityIdentifier("media-drawer-carousel")
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("media-drawer-close")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
        .presentationCornerRadius(28)
    }

    private func cardSize(for item: MediaRecord, in availableSize: CGSize) -> CGSize {
        let aspectRatio = min(max(item.dimensions?.aspectRatio ?? 1, 0.2), 5)
        let maximumWidth = availableSize.width * 0.82
        let maximumHeight = max(availableSize.height - 40, 120)
        let width = min(maximumWidth, maximumHeight * aspectRatio)
        return CGSize(width: width, height: width / aspectRatio)
    }
}

private struct MediaCard: View {
    let item: MediaRecord
    let url: URL
    let isActive: Bool

    var body: some View {
        Group {
            if item.mediaType == .video {
                AutoplayVideoPlayer(url: url, isActive: isActive)
            } else {
                ThumbnailImage(url: url, maxPixelSize: 2_048, contentMode: .fit)
                    .accessibilityLabel("Full-size media")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .accessibilityIdentifier("media-card-\(item.id)")
    }
}

struct AutoplayVideoPlayer: View {
    let isActive: Bool
    let videoGravity: AVLayerVideoGravity
    @State private var player: AVPlayer

    init(
        url: URL,
        isActive: Bool,
        videoGravity: AVLayerVideoGravity = .resizeAspect
    ) {
        self.isActive = isActive
        self.videoGravity = videoGravity
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NativeVideoPlayer(player: player, videoGravity: videoGravity)
            .onAppear { updatePlayback() }
            .onChange(of: isActive) { _, _ in updatePlayback() }
            .onDisappear { player.pause() }
            .accessibilityLabel("Playing video")
    }

    private func updatePlayback() {
        if isActive {
            if let duration = player.currentItem?.duration.seconds,
               duration.isFinite,
               player.currentTime().seconds >= duration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
        } else {
            player.pause()
        }
    }
}

private struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let viewController = AVPlayerViewController()
        viewController.player = player
        viewController.showsPlaybackControls = false
        viewController.videoGravity = videoGravity
        viewController.allowsPictureInPicturePlayback = false
        viewController.entersFullScreenWhenPlaybackBegins = false
        viewController.view.backgroundColor = .black
        return viewController
    }

    func updateUIViewController(_ viewController: AVPlayerViewController, context: Context) {
        viewController.player = player
        viewController.videoGravity = videoGravity
    }

    static func dismantleUIViewController(
        _ viewController: AVPlayerViewController,
        coordinator: Void
    ) {
        viewController.player?.pause()
        viewController.player = nil
    }
}
