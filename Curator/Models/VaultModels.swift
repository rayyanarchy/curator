import Foundation

enum ContentKind: String, Codable, CaseIterable, Sendable {
    case post
    case archivedPost
    case story
    case reel
    case profilePhoto
    case other
    case recovered

    var displayName: String {
        switch self {
        case .post: "Post"
        case .archivedPost: "Archived post"
        case .story: "Story"
        case .reel: "Reel"
        case .profilePhoto: "Profile photo"
        case .other: "Other"
        case .recovered: "Recovered"
        }
    }

    var preferenceName: String {
        switch self {
        case .post: "Posts"
        case .archivedPost: "Archived posts"
        case .story: "Stories"
        case .reel: "Reels"
        case .profilePhoto: "Profile photos"
        case .other: "Other media"
        case .recovered: "Recovered media"
        }
    }

    var systemImage: String {
        switch self {
        case .post: "square.grid.2x2"
        case .archivedPost: "archivebox"
        case .story: "circle.dashed"
        case .reel: "play.rectangle"
        case .profilePhoto: "person.crop.circle"
        case .other: "photo.on.rectangle.angled"
        case .recovered: "wand.and.stars"
        }
    }
}

struct MediaPreferences: Codable, Hashable, Sendable {
    var visibleContentKinds: Set<ContentKind>

    static let all = MediaPreferences(visibleContentKinds: Set(ContentKind.allCases))

    func includes(_ item: MediaRecord) -> Bool {
        visibleContentKinds.contains(item.contentKind)
    }
}

enum FeedSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst

    var id: Self { self }

    var displayName: String {
        switch self {
        case .newestFirst: "Newest first"
        case .oldestFirst: "Oldest first"
        }
    }

    func sorted(_ items: [MediaRecord]) -> [MediaRecord] {
        items.sorted { left, right in
            switch (left.capturedAt, right.capturedAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                switch self {
                case .newestFirst: leftDate > rightDate
                case .oldestFirst: leftDate < rightDate
                }
            case (_?, nil):
                true
            case (nil, _?):
                false
            default:
                left.id < right.id
            }
        }
    }
}

enum MediaType: String, Codable, Sendable {
    case image
    case video
    case unknown
}

enum EmbeddingStatus: String, Codable, Sendable {
    case pending
    case embedded
    case sidecarOnly
}

struct PixelSize: Codable, Hashable, Sendable {
    let width: Int
    let height: Int

    var aspectRatio: Double {
        guard height > 0 else { return 1 }
        return Double(width) / Double(height)
    }
}

struct MediaRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let profileID: UUID
    let contentKind: ContentKind
    let capturedAt: Date?
    let originalTimestamp: String?
    let timezoneIdentifier: String
    let caption: String?
    let mediaType: MediaType
    let dimensions: PixelSize?
    let duration: TimeInterval?
    let mediaPath: String
    let originalExportPath: String
    let checksum: String
    let importID: UUID
    let recovered: Bool
    let duplicateGroupID: String?
    let embeddingStatus: EmbeddingStatus
    let warnings: [String]

    var monthKey: String {
        guard let capturedAt else { return "Unknown date" }
        return capturedAt.formatted(.dateTime.month(.wide).year())
    }
}

struct VaultProfile: Codable, Identifiable, Hashable, Sendable {
    static let schemaVersion = 4

    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var itemCount: Int
    var totalBytes: Int64
    var earliestItemAt: Date?
    var latestItemAt: Date?
    var coverItemIDs: [String]
    var schemaVersion: Int
    var sourceIdentity: String? = nil
    var sourceArchiveChecksums: [String]? = nil
    var mediaPreferences: MediaPreferences? = nil
    var latestArchiveFilename: String? = nil

    var importedArchiveChecksums: [String] {
        sourceArchiveChecksums ?? []
    }

    var effectiveMediaPreferences: MediaPreferences {
        mediaPreferences ?? .all
    }
}

struct ArchiveProfileSuggestion: Equatable, Sendable {
    let name: String
    let identityKey: String?
}

struct VaultManifest: Codable, Sendable {
    var profile: VaultProfile
    var items: [MediaRecord]
}

struct ImportReport: Codable, Sendable {
    let id: UUID
    let sourceFilename: String
    let sourceChecksum: String
    let startedAt: Date
    let completedAt: Date
    let metadataRecords: Int
    let importedItems: Int
    let skippedExistingItems: Int
    let missingReferences: Int
    let recoveredItems: Int
    let unknownMediaItems: Int
    let embeddedItems: Int
    let sidecarOnlyItems: Int
}

struct ImportSnapshot: Equatable, Sendable {
    enum Phase: String, Sendable {
        case preparing = "Preparing"
        case inspecting = "Reading Instagram data"
        case extracting = "Organizing media"
        case indexing = "Building your timeline"
        case verifying = "Verifying"
    }

    let phase: Phase
    let completed: Int
    let total: Int
    let detail: String?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

enum ImportState: Equatable {
    case idle
    case preparing
    case running(ImportSnapshot)
    case completed(VaultProfile)
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .preparing, .running: true
        default: false
        }
    }
}
