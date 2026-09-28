import Foundation
import Testing
@testable import Curator

struct VaultModelsTests {
    @Test func mediaRecordMonthKeyUsesCapturedDate() {
        let date = ISO8601DateFormatter().date(from: "2024-06-15T12:00:00Z")!
        let record = MediaRecord(
            id: "test",
            profileID: UUID(),
            contentKind: .story,
            capturedAt: date,
            originalTimestamp: "Jun 15, 2024 5:30 pm",
            timezoneIdentifier: "Asia/Kolkata",
            caption: "A memory",
            mediaType: .image,
            dimensions: PixelSize(width: 1080, height: 1920),
            duration: nil,
            mediaPath: "media/test.jpg",
            originalExportPath: "media/stories/test.jpg",
            checksum: "abc",
            importID: UUID(),
            recovered: false,
            duplicateGroupID: nil,
            embeddingStatus: .sidecarOnly,
            warnings: []
        )

        #expect(record.monthKey.contains("2024"))
        #expect(record.dimensions?.aspectRatio == 0.5625)
    }

    @Test func legacyProfileManifestDecodesWithoutSourceTrackingFields() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Legacy",
          "createdAt": "2024-06-15T12:00:00Z",
          "updatedAt": "2024-06-15T12:00:00Z",
          "itemCount": 0,
          "totalBytes": 0,
          "coverItemIDs": [],
          "schemaVersion": 1
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let profile = try decoder.decode(VaultProfile.self, from: Data(json.utf8))

        #expect(profile.id == id)
        #expect(profile.sourceIdentity == nil)
        #expect(profile.importedArchiveChecksums.isEmpty)
        #expect(profile.effectiveMediaPreferences == .all)
        #expect(profile.latestArchiveFilename == nil)
    }

    @Test func mediaPreferencesIncludeOnlySelectedCategories() {
        let profileID = UUID()
        let preferences = MediaPreferences(visibleContentKinds: [.story])
        let story = makeRecord(id: "story", profileID: profileID, contentKind: .story)
        let reel = makeRecord(id: "reel", profileID: profileID, contentKind: .reel)

        #expect(preferences.includes(story))
        #expect(!preferences.includes(reel))
    }

    @Test func feedSortOrderSortsDatesAndKeepsUndatedMediaLast() {
        let profileID = UUID()
        let older = makeRecord(
            id: "older",
            profileID: profileID,
            contentKind: .post,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = makeRecord(
            id: "newer",
            profileID: profileID,
            contentKind: .post,
            capturedAt: Date(timeIntervalSince1970: 200)
        )
        let undated = makeRecord(
            id: "undated",
            profileID: profileID,
            contentKind: .post,
            capturedAt: nil
        )

        #expect(FeedSortOrder.newestFirst.sorted([older, undated, newer]).map(\.id) == ["newer", "older", "undated"])
        #expect(FeedSortOrder.oldestFirst.sorted([newer, undated, older]).map(\.id) == ["older", "newer", "undated"])
    }

    @Test func mediaFilterCategoriesCoverEveryImportedKindExactlyOnce() {
        let groupedKinds = MediaFilterCategory.allCases.flatMap(\.contentKinds)

        #expect(Set(groupedKinds) == Set(ContentKind.allCases))
        #expect(groupedKinds.count == Set(groupedKinds).count)
    }

    @Test func everyContentKindUsesItsViewOptionsCategorySymbol() {
        for contentKind in ContentKind.allCases {
            let category = MediaFilterCategory.category(for: contentKind)

            #expect(category.contentKinds.contains(contentKind))
            #expect(!category.systemImage.isEmpty)
        }
    }

    private func makeRecord(
        id: String,
        profileID: UUID,
        contentKind: ContentKind,
        capturedAt: Date? = nil
    ) -> MediaRecord {
        MediaRecord(
            id: id,
            profileID: profileID,
            contentKind: contentKind,
            capturedAt: capturedAt,
            originalTimestamp: nil,
            timezoneIdentifier: "UTC",
            caption: nil,
            mediaType: .image,
            dimensions: nil,
            duration: nil,
            mediaPath: "media/\(id).jpg",
            originalExportPath: "media/\(id).jpg",
            checksum: id,
            importID: UUID(),
            recovered: false,
            duplicateGroupID: nil,
            embeddingStatus: .sidecarOnly,
            warnings: []
        )
    }
}
