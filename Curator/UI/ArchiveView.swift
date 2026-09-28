import ImageIO
import SwiftUI

struct ArchiveView: View {
    let items: [MediaRecord]
    let mediaURL: (MediaRecord) -> URL
    let thumbnailURL: (String) -> URL
    @State private var selectedItem: MediaRecord?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("No media", systemImage: "photo.on.rectangle.angled")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(items) { item in
                            Button {
                                selectedItem = item
                            } label: {
                                GridTile(
                                    url: displayURL(for: item),
                                    categorySystemImage: MediaFilterCategory
                                        .category(for: item.contentKind)
                                        .systemImage
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accessibilityLabel(for: item))
                            .accessibilityHint("Opens media drawer")
                            .accessibilityIdentifier("media-grid-item-\(item.id)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .background(Color(.systemBackground))
            }
        }
        .sheet(item: $selectedItem) { item in
            MediaDrawerView(
                items: items,
                initialItemID: item.id,
                mediaURL: mediaURL
            )
        }
    }

    private func displayURL(for item: MediaRecord) -> URL {
        item.mediaType == .image ? mediaURL(item) : thumbnailURL(item.id)
    }

    private func accessibilityLabel(for item: MediaRecord) -> String {
        switch item.mediaType {
        case .image: "Photo"
        case .video: "Video"
        case .unknown: "Media"
        }
    }
}

private struct GridTile: View {
    let url: URL
    let categorySystemImage: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ThumbnailImage(url: url)

            Image(systemName: categorySystemImage)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .padding(8)
                .accessibilityHidden(true)
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
    }
}

struct ArchiveFeedView: View {
    let items: [MediaRecord]
    let mediaURL: (MediaRecord) -> URL

    @State private var focusedItemID: String?

    init(
        items: [MediaRecord],
        mediaURL: @escaping (MediaRecord) -> URL
    ) {
        self.items = items
        self.mediaURL = mediaURL
        _focusedItemID = State(initialValue: items.first?.id)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    ForEach(items) { item in
                        FeedMedia(
                            item: item,
                            url: mediaURL(item),
                            isActive: focusedItemID == item.id
                        )
                        .frame(
                            width: proxy.size.width,
                            height: max(proxy.size.height, 1)
                        )
                        .clipped()
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $focusedItemID, anchor: .center)
            .onChange(of: items.map(\.id)) { _, itemIDs in
                if let focusedItemID, itemIDs.contains(focusedItemID) {
                    return
                }
                focusedItemID = itemIDs.first
            }
        }
        .background(Color(.systemBackground))
    }
}

private struct FeedMedia: View {
    let item: MediaRecord
    let url: URL
    let isActive: Bool

    var body: some View {
        Group {
            if item.mediaType == .video {
                AutoplayVideoPlayer(
                    url: url,
                    isActive: isActive,
                    videoGravity: .resizeAspectFill
                )
            } else {
                ThumbnailImage(
                    url: url,
                    maxPixelSize: 2_048,
                    contentMode: .fill
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.mediaType == .video ? "Video" : "Photo")
    }
}

struct ThumbnailImage: View {
    let url: URL
    let maxPixelSize: Int
    let contentMode: ContentMode
    @State private var image: UIImage?

    init(url: URL, maxPixelSize: Int = 900, contentMode: ContentMode = .fill) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task(id: url) {
            image = await LocalThumbnailLoader.shared.image(
                at: url,
                maxPixelSize: maxPixelSize
            )
        }
    }
}

actor LocalThumbnailLoader {
    static let shared = LocalThumbnailLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]

    func image(at url: URL, maxPixelSize: Int) async -> UIImage? {
        let key = "\(url.path)#\(maxPixelSize)"
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if let task = inFlightTasks[key] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return UIImage(contentsOfFile: url.path) }
            return UIImage(cgImage: cgImage)
        }
        inFlightTasks[key] = task
        let image = await task.value
        inFlightTasks[key] = nil
        if let image {
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }
}
