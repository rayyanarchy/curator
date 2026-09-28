import Foundation
import Testing
@testable import Curator

struct AppModelTests {
    @Test @MainActor
    func multipleProfilesAreRestoredAndManagedIndependently() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CuratorAppModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = AppPaths(
            applicationSupport: root.appending(path: "ApplicationSupport", directoryHint: .isDirectory),
            caches: root.appending(path: "Caches", directoryHint: .isDirectory)
        )
        let defaultsSuite = "CuratorAppModelTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer {
            try? FileManager.default.removeItem(at: root)
            userDefaults.removePersistentDomain(forName: defaultsSuite)
        }

        let olderProfile = makeProfile(
            name: "Personal",
            updatedAt: .distantPast,
            archiveFilename: "personal-archive.zip"
        )
        let newerProfile = makeProfile(
            name: "Photography",
            updatedAt: .now,
            archiveChecksums: ["updated-export"]
        )
        let inactivePhoto = makeRecord(
            id: "inactive-photo",
            profileID: olderProfile.id,
            kind: .profilePhoto,
            capturedAt: Date(timeIntervalSince1970: 50)
        )
        let olderPhoto = makeRecord(
            id: "older-photo",
            profileID: newerProfile.id,
            kind: .profilePhoto,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let newerPhoto = makeRecord(
            id: "newer-photo",
            profileID: newerProfile.id,
            kind: .profilePhoto,
            capturedAt: Date(timeIntervalSince1970: 200)
        )
        try writeManifest(for: olderProfile, items: [inactivePhoto], paths: paths)
        try writeManifest(for: newerProfile, items: [olderPhoto, newerPhoto], paths: paths)
        try writeImportReport(
            sourceFilename: "photography-archive.zip",
            profileID: newerProfile.id,
            paths: paths
        )

        let store = VaultStore(paths: paths)
        #expect(try await store.hasImportedArchive(
            checksum: "updated-export",
            profileID: newerProfile.id
        ))
        let hasDifferentExport = try await store.hasImportedArchive(
            checksum: "different-export",
            profileID: newerProfile.id
        )
        #expect(!hasDifferentExport)

        let model = AppModel(paths: paths, userDefaults: userDefaults)
        await model.loadProfiles()

        #expect(model.profiles.map(\.id) == [newerProfile.id, olderProfile.id])
        #expect(model.selectedProfileID == newerProfile.id)
        #expect(model.profile(withID: newerProfile.id)?.latestArchiveFilename == "photography-archive.zip")

        #expect(model.latestProfilePhoto(for: newerProfile.id)?.id == newerPhoto.id)
        #expect(model.latestProfilePhoto(for: olderProfile.id)?.id == inactivePhoto.id)

        model.selectProfile(olderProfile.id)
        let reopened = AppModel(paths: paths, userDefaults: userDefaults)
        await reopened.loadProfiles()
        #expect(reopened.selectedProfileID == olderProfile.id)

        let renamed = await model.renameProfile(profileID: olderProfile.id, to: "  Family  ")
        #expect(renamed)
        #expect(model.profile(withID: olderProfile.id)?.name == "Family")
        #expect(FileManager.default.fileExists(atPath: paths.vault(for: newerProfile.id).path))

        let photographyPreferences = MediaPreferences(visibleContentKinds: [.reel, .story])
        let updatedPreferences = await model.updateMediaPreferences(
            profileID: newerProfile.id,
            preferences: photographyPreferences
        )
        #expect(updatedPreferences)
        #expect(model.mediaPreferences(for: newerProfile.id) == photographyPreferences)
        #expect(model.mediaPreferences(for: olderProfile.id) == .all)

        let deleted = await model.deleteProfile(profileID: olderProfile.id)
        #expect(deleted)
        #expect(model.profiles.map(\.id) == [newerProfile.id])
        #expect(model.selectedProfileID == newerProfile.id)
        #expect(!FileManager.default.fileExists(atPath: paths.vault(for: olderProfile.id).path))
        #expect(FileManager.default.fileExists(atPath: paths.vault(for: newerProfile.id).path))

        let nextLaunch = AppModel(paths: paths, userDefaults: userDefaults)
        await nextLaunch.loadProfiles()
        #expect(nextLaunch.profiles.map(\.id) == [newerProfile.id])
        #expect(nextLaunch.selectedProfileID == newerProfile.id)
        #expect(nextLaunch.profiles.first?.effectiveMediaPreferences == photographyPreferences)
    }

    private func makeProfile(
        name: String,
        updatedAt: Date,
        archiveChecksums: [String] = [],
        archiveFilename: String? = nil
    ) -> VaultProfile {
        VaultProfile(
            id: UUID(),
            name: name,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            itemCount: 0,
            totalBytes: 0,
            earliestItemAt: nil,
            latestItemAt: nil,
            coverItemIDs: [],
            schemaVersion: VaultProfile.schemaVersion,
            sourceIdentity: name.lowercased(),
            sourceArchiveChecksums: archiveChecksums,
            latestArchiveFilename: archiveFilename
        )
    }

    private func writeManifest(
        for profile: VaultProfile,
        items: [MediaRecord] = [],
        paths: AppPaths
    ) throws {
        try FileManager.default.createDirectory(
            at: paths.vault(for: profile.id),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(VaultManifest(profile: profile, items: items))
            .write(to: paths.manifest(for: profile.id), options: .atomic)
    }

    private func makeRecord(
        id: String,
        profileID: UUID,
        kind: ContentKind,
        capturedAt: Date?
    ) -> MediaRecord {
        MediaRecord(
            id: id,
            profileID: profileID,
            contentKind: kind,
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

    private func writeImportReport(
        sourceFilename: String,
        profileID: UUID,
        paths: AppPaths
    ) throws {
        let imports = paths.vault(for: profileID).appending(path: "imports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let report = ImportReport(
            id: UUID(),
            sourceFilename: sourceFilename,
            sourceChecksum: "report-checksum",
            startedAt: .now,
            completedAt: .now,
            metadataRecords: 0,
            importedItems: 0,
            skippedExistingItems: 0,
            missingReferences: 0,
            recoveredItems: 0,
            unknownMediaItems: 0,
            embeddedItems: 0,
            sidecarOnlyItems: 0
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(
            to: imports.appending(path: "\(report.id.uuidString).json"),
            options: .atomic
        )
    }
}
