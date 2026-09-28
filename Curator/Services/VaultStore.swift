import Foundation

actor VaultStore {
    private let paths: AppPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(paths: AppPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func prepareDirectories() throws {
        for directory in [paths.applicationSupport, paths.vaults, paths.staging, paths.caches, paths.thumbnails] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func loadProfiles() throws -> [VaultProfile] {
        try prepareDirectories()
        let directories = try fileManager.contentsOfDirectory(
            at: paths.vaults,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return directories.compactMap { directory in
            let manifestURL = directory.appending(path: "vault.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(VaultManifest.self, from: data) else {
                return nil
            }
            var profile = manifest.profile
            if profile.latestArchiveFilename == nil {
                profile.latestArchiveFilename = latestImportedArchiveFilename(in: directory)
            }
            return profile
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadArchive() throws -> VaultProfile? {
        try loadProfiles().first
    }

    func loadManifest(profileID: UUID) throws -> VaultManifest? {
        let url = paths.manifest(for: profileID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(VaultManifest.self, from: Data(contentsOf: url))
    }

    func loadItems(profileID: UUID) throws -> [MediaRecord] {
        try loadManifest(profileID: profileID)?.items.sorted {
            ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast)
        } ?? []
    }

    func loadLatestProfilePhoto(profileID: UUID) throws -> MediaRecord? {
        try loadManifest(profileID: profileID)?.items
            .filter { $0.contentKind == .profilePhoto && $0.mediaType == .image }
            .max(by: Self.profilePhotoIsOlder)
    }

    func renameProfile(profileID: UUID, to name: String) throws -> VaultProfile {
        guard var manifest = try loadManifest(profileID: profileID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        manifest.profile.name = name
        manifest.profile.updatedAt = Date()
        try write(manifest, to: paths.vault(for: profileID))
        return manifest.profile
    }

    func updateMediaPreferences(
        profileID: UUID,
        preferences: MediaPreferences
    ) throws -> VaultProfile {
        guard var manifest = try loadManifest(profileID: profileID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        manifest.profile.mediaPreferences = preferences
        manifest.profile.schemaVersion = VaultProfile.schemaVersion
        manifest.profile.updatedAt = Date()
        try write(manifest, to: paths.vault(for: profileID))
        return manifest.profile
    }

    func deleteProfile(profileID: UUID) throws {
        let destination = paths.vault(for: profileID)
        guard fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.removeItem(at: destination)
    }

    func hasImportedArchive(checksum: String, profileID: UUID) throws -> Bool {
        guard let manifest = try loadManifest(profileID: profileID) else { return false }
        if manifest.profile.importedArchiveChecksums.contains(checksum) { return true }

        let imports = paths.vault(for: profileID).appending(path: "imports", directoryHint: .isDirectory)
        guard let files = try? fileManager.contentsOfDirectory(
            at: imports,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        return files.contains { url in
            guard let data = try? Data(contentsOf: url),
                  let report = try? decoder.decode(ImportReport.self, from: data) else {
                return false
            }
            return report.sourceChecksum == checksum
        }
    }

    func commit(manifest: VaultManifest, transactionDirectory: URL) throws {
        try prepareDirectories()
        let destination = paths.vault(for: manifest.profile.id)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let stagedMedia = transactionDirectory.appending(path: "media", directoryHint: .isDirectory)
        let stagedMetadata = transactionDirectory.appending(path: "metadata", directoryHint: .isDirectory)
        let stagedImports = transactionDirectory.appending(path: "imports", directoryHint: .isDirectory)
        try mergeDirectory(stagedMedia, into: destination.appending(path: "media", directoryHint: .isDirectory))
        try mergeDirectory(stagedMetadata, into: destination.appending(path: "metadata", directoryHint: .isDirectory))
        try mergeDirectory(stagedImports, into: destination.appending(path: "imports", directoryHint: .isDirectory))

        try write(manifest, to: destination)
    }

    private func write(_ manifest: VaultManifest, to destination: URL) throws {
        let data = try encoder.encode(manifest)
        let temporaryManifest = destination.appending(path: "vault.json.next")
        try data.write(to: temporaryManifest, options: [.atomic])

        let manifestURL = destination.appending(path: "vault.json")
        if fileManager.fileExists(atPath: manifestURL.path) {
            _ = try fileManager.replaceItemAt(manifestURL, withItemAt: temporaryManifest)
        } else {
            try fileManager.moveItem(at: temporaryManifest, to: manifestURL)
        }
    }

    private func latestImportedArchiveFilename(in vault: URL) -> String? {
        let imports = vault.appending(path: "imports", directoryHint: .isDirectory)
        guard let files = try? fileManager.contentsOfDirectory(
            at: imports,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return files.compactMap { url -> ImportReport? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(ImportReport.self, from: data)
        }
        .max { $0.completedAt < $1.completedAt }?
        .sourceFilename
    }

    private static func profilePhotoIsOlder(_ left: MediaRecord, _ right: MediaRecord) -> Bool {
        switch (left.capturedAt, right.capturedAt) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate < rightDate
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        default:
            return left.id < right.id
        }
    }

    private func mergeDirectory(_ source: URL, into destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let sourceURL = enumerator?.nextObject() as? URL {
            let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
            let relative = try relativePath(of: sourceURL, under: source)
            let destinationURL = destination.appending(path: relative)

            if values.isDirectory == true {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            } else if !fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            }
        }
    }

    private func relativePath(of child: URL, under parent: URL) throws -> String {
        let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
        guard childPath.hasPrefix(parentPath + "/") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return String(childPath.dropFirst(parentPath.count + 1))
    }
}
