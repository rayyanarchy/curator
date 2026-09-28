import Darwin
import Foundation

@main
struct ImportSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: CuratorImportSmoke <instagram-export.zip>\n".utf8))
            exit(64)
        }

        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let suppliedContainer = ProcessInfo.processInfo.environment["CURATOR_SMOKE_CONTAINER"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        let root = suppliedContainer ?? FileManager.default.temporaryDirectory
            .appending(path: "CuratorSmoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths: AppPaths
        if suppliedContainer != nil {
            paths = AppPaths(
                applicationSupport: root
                    .appending(path: "Library/Application Support/Curator", directoryHint: .isDirectory),
                caches: root.appending(path: "Library/Caches/Curator", directoryHint: .isDirectory)
            )
        } else {
            paths = AppPaths(
                applicationSupport: root.appending(path: "ApplicationSupport", directoryHint: .isDirectory),
                caches: root.appending(path: "Caches", directoryHint: .isDirectory)
            )
        }
        let store = VaultStore(paths: paths)
        let importer = InstagramArchiveImporter(
            paths: paths,
            store: store,
            shouldGenerateThumbnails: false
        )
        defer {
            if suppliedContainer == nil {
                try? FileManager.default.removeItem(at: root)
            }
        }

        if ProcessInfo.processInfo.environment["CURATOR_SMOKE_SUGGEST_ONLY"] == "1" {
            let suggestion = try await importer.suggestedProfile(for: sourceURL)
            print("RESULT suggested_name=\(suggestion.name)")
            print("RESULT suggested_identity=\(suggestion.identityKey ?? "none")")
            return
        }

        let logger = ProgressLogger()
        let profile = try await importer.importArchive(from: sourceURL, targetProfileID: nil) { snapshot in
            Task { await logger.record(snapshot) }
        }
        let items = try await store.loadItems(profileID: profile.id)
        let recovered = items.filter(\.recovered).count
        let unknown = items.filter { $0.mediaType == .unknown }.count
        let embedded = items.filter { $0.embeddingStatus == .embedded }.count
        let sidecarOnly = items.filter { $0.embeddingStatus == .sidecarOnly }.count

        if suppliedContainer != nil {
            print("RESULT profile=\(profile.name)")
            print("RESULT items=\(items.count)")
            print("RESULT recovered=\(recovered)")
            print("RESULT unknown=\(unknown)")
            print("RESULT embedded=\(embedded)")
            print("RESULT sidecar_only=\(sidecarOnly)")
            print("RESULT bytes=\(profile.totalBytes)")
            return
        }

        let sourceChecksum = try await importer.sourceChecksum(for: sourceURL)
        var matchingProfile: VaultProfile?
        for candidate in try await store.loadProfiles() {
            if try await store.hasImportedArchive(checksum: sourceChecksum, profileID: candidate.id) {
                matchingProfile = candidate
                break
            }
        }
        guard let matchingProfile, matchingProfile.id == profile.id else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let mergedProfile = try await importer.importArchive(
            from: sourceURL,
            targetProfileID: matchingProfile.id,
            defensiveMerge: true
        ) { snapshot in
            Task { await logger.record(snapshot) }
        }
        let mergedItems = try await store.loadItems(profileID: mergedProfile.id)

        print("RESULT profile=\(profile.name)")
        print("RESULT matched_existing_profile=\(matchingProfile.id == profile.id)")
        print("RESULT same_profile_on_reimport=\(mergedProfile.id == profile.id)")
        print("RESULT items=\(items.count)")
        print("RESULT items_after_reimport=\(mergedItems.count)")
        print("RESULT recovered=\(recovered)")
        print("RESULT unknown=\(unknown)")
        print("RESULT embedded=\(embedded)")
        print("RESULT sidecar_only=\(sidecarOnly)")
        print("RESULT bytes=\(profile.totalBytes)")
    }
}

private actor ProgressLogger {
    private var lastPhase: ImportSnapshot.Phase?

    func record(_ snapshot: ImportSnapshot) {
        guard snapshot.phase != lastPhase || snapshot.completed == snapshot.total || snapshot.completed.isMultiple(of: 100) else {
            return
        }
        print("[\(snapshot.phase.rawValue)] \(snapshot.completed)/\(snapshot.total) \(snapshot.detail ?? "")")
        lastPhase = snapshot.phase
    }
}
