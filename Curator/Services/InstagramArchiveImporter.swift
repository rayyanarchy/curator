import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import QuickLookThumbnailing
import SwiftSoup
import UniformTypeIdentifiers
import ZIPFoundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

actor InstagramArchiveImporter {
    private struct Draft {
        let sourcePath: String
        let kind: ContentKind
        let caption: String?
        let timestamp: String?
        let capturedAt: Date?
        let occurrence: Int
        let recovered: Bool
    }

    private let paths: AppPaths
    private let store: VaultStore
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let shouldGenerateThumbnails: Bool
    private let metadataWriter = MediaMetadataWriter()

    init(
        paths: AppPaths,
        store: VaultStore,
        fileManager: FileManager = .default,
        shouldGenerateThumbnails: Bool = true
    ) {
        self.paths = paths
        self.store = store
        self.fileManager = fileManager
        self.shouldGenerateThumbnails = shouldGenerateThumbnails
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }

    func importArchive(
        from sourceURL: URL,
        targetProfileID: UUID?,
        profileName: String? = nil,
        sourceIdentity: String? = nil,
        defensiveMerge: Bool = false,
        progress: @escaping @Sendable (ImportSnapshot) -> Void
    ) async throws -> VaultProfile {
        try await store.prepareDirectories()
        let importID = UUID()
        let startedAt = Date()
        let jobRoot = paths.staging.appending(path: importID.uuidString.lowercased(), directoryHint: .isDirectory)
        let extractedRoot = jobRoot.appending(path: "extracted", directoryHint: .isDirectory)
        let transactionRoot = jobRoot.appending(path: "transaction", directoryHint: .isDirectory)
        let stagedZIP = jobRoot.appending(path: "source.zip")

        try fileManager.createDirectory(at: extractedRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: jobRoot) }

        progress(.init(phase: .preparing, completed: 0, total: 1, detail: "Copying export"))
        try coordinatedCopy(from: sourceURL, to: stagedZIP)
        progress(.init(phase: .preparing, completed: 1, total: 1, detail: nil))

        let sourceChecksum = try sha256(of: stagedZIP)
        let archive = try Archive(url: stagedZIP, accessMode: .read)
        let entries = try validatedEntries(in: archive, destinationRoot: extractedRoot)
        let relevant = entries.filter { isOwnedContentPath($0.path) }
        try validateWorkingCapacity(for: relevant, at: jobRoot)
        progress(.init(phase: .inspecting, completed: 0, total: relevant.count, detail: nil))

        for (index, entry) in relevant.enumerated() {
            try Task.checkCancellation()
            let destination = try safeDestination(for: entry.path, under: extractedRoot)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destination)
            progress(.init(
                phase: .inspecting,
                completed: index + 1,
                total: relevant.count,
                detail: destination.lastPathComponent
            ))
        }

        var drafts = try parseHTMLContent(at: extractedRoot)
        drafts.append(contentsOf: try parseJSONContent(at: extractedRoot))
        let referencedPaths = Set(drafts.map(\.sourcePath))
        drafts.append(contentsOf: try recoveredDrafts(at: extractedRoot, excluding: referencedPaths))

        let existingManifest: VaultManifest?
        if let targetProfileID {
            existingManifest = try await store.loadManifest(profileID: targetProfileID)
        } else {
            existingManifest = nil
        }

        let profileID = existingManifest?.profile.id ?? UUID()
        let existingItems = existingManifest?.items ?? []
        var knownMergeKeys = Set(existingItems.map(mergeKey(for:)))
        var knownChecksums = Set(existingItems.map(\.checksum))
        var newItems: [MediaRecord] = []
        var seenChecksums = Dictionary(
            existingItems.map { ($0.checksum, $0.duplicateGroupID ?? $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        var missingReferences = 0
        var skippedExistingItems = 0
        var unknownMediaItems = 0

        progress(.init(phase: .extracting, completed: 0, total: drafts.count, detail: nil))
        for (index, draft) in drafts.enumerated() {
            try Task.checkCancellation()
            let source = try safeDestination(for: draft.sourcePath, under: extractedRoot)
            guard fileManager.fileExists(atPath: source.path) else {
                missingReferences += 1
                continue
            }

            let checksum = try sha256(of: source)
            let capturedAt = draft.capturedAt ?? parseDate(draft.timestamp)
            let candidateMergeKey = mergeKey(checksum: checksum, capturedAt: capturedAt, kind: draft.kind)
            if defensiveMerge, !knownChecksums.insert(checksum).inserted {
                skippedExistingItems += 1
                continue
            }
            guard knownMergeKeys.insert(candidateMergeKey).inserted else {
                skippedExistingItems += 1
                continue
            }

            let mediaType = sniffMediaType(at: source)
            if mediaType == .unknown { unknownMediaItems += 1 }
            let ext = preferredExtension(for: source, mediaType: mediaType)
            let itemID = stableID(for: draft, checksum: checksum)
            let datePrefix = capturedAt.map { Self.fileDateFormatter.string(from: $0) } ?? "undated"
            let filename = "\(datePrefix)_\(draft.kind.rawValue)_\(itemID.prefix(12)).\(ext)"
            let components = dateComponents(for: capturedAt)
            let relativeMediaPath = "media/\(components.year)/\(components.month)/\(filename)"
            let mediaDestination = transactionRoot.appending(path: relativeMediaPath)
            try fileManager.createDirectory(at: mediaDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: mediaDestination)

            let embedding = metadataWriter.embed(
                capturedAt: capturedAt,
                caption: draft.caption?.nilIfBlank,
                originalExportPath: draft.sourcePath,
                contentKind: draft.kind,
                in: mediaDestination,
                mediaType: mediaType
            )

            let duplicateGroup = seenChecksums[checksum]
            if seenChecksums[checksum] == nil { seenChecksums[checksum] = itemID }
            let details = await mediaDetails(at: mediaDestination, type: mediaType)

            let record = MediaRecord(
                id: itemID,
                profileID: profileID,
                contentKind: draft.kind,
                capturedAt: capturedAt,
                originalTimestamp: draft.timestamp,
                timezoneIdentifier: TimeZone.current.identifier,
                caption: draft.caption?.nilIfBlank,
                mediaType: mediaType,
                dimensions: details.dimensions,
                duration: details.duration,
                mediaPath: relativeMediaPath,
                originalExportPath: draft.sourcePath,
                checksum: checksum,
                importID: importID,
                recovered: draft.recovered,
                duplicateGroupID: duplicateGroup,
                embeddingStatus: embedding.status,
                warnings: recordWarnings(
                    recovered: draft.recovered,
                    mediaType: mediaType,
                    embeddingWarning: embedding.warning
                )
            )

            let metadataPath = "metadata/\(components.year)/\(components.month)/\(filename).json"
            let metadataURL = transactionRoot.appending(path: metadataPath)
            try fileManager.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(record).write(to: metadataURL, options: [.atomic])
            newItems.append(record)
            if shouldGenerateThumbnails {
                try? await generateThumbnail(for: record, mediaURL: mediaDestination)
            }

            progress(.init(
                phase: .extracting,
                completed: index + 1,
                total: drafts.count,
                detail: filename
            ))
        }

        progress(.init(phase: .indexing, completed: 0, total: 1, detail: nil))
        let allItems = (existingItems + newItems).sorted {
            ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast)
        }
        let now = Date()
        let profile = VaultProfile(
            id: profileID,
            name: existingManifest?.profile.name ?? profileName?.nilIfBlank ?? filenameSuggestedProfileName(from: sourceURL),
            createdAt: existingManifest?.profile.createdAt ?? now,
            updatedAt: now,
            itemCount: allItems.count,
            totalBytes: allItems.reduce(0) { total, item in
                let url = paths.vault(for: profileID).appending(path: item.mediaPath)
                let staged = transactionRoot.appending(path: item.mediaPath)
                let candidate = fileManager.fileExists(atPath: staged.path) ? staged : url
                let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                return total + size
            },
            earliestItemAt: allItems.compactMap(\.capturedAt).min(),
            latestItemAt: allItems.compactMap(\.capturedAt).max(),
            coverItemIDs: Array(allItems.prefix(4).map(\.id)),
            schemaVersion: VaultProfile.schemaVersion,
            sourceIdentity: existingManifest?.profile.sourceIdentity ?? sourceIdentity,
            sourceArchiveChecksums: Array(Set(
                existingManifest?.profile.importedArchiveChecksums ?? []
            ).union([sourceChecksum])).sorted(),
            mediaPreferences: existingManifest?.profile.mediaPreferences,
            latestArchiveFilename: sourceURL.lastPathComponent
        )

        let report = ImportReport(
            id: importID,
            sourceFilename: sourceURL.lastPathComponent,
            sourceChecksum: sourceChecksum,
            startedAt: startedAt,
            completedAt: Date(),
            metadataRecords: drafts.filter { !$0.recovered }.count,
            importedItems: newItems.count,
            skippedExistingItems: skippedExistingItems,
            missingReferences: missingReferences,
            recoveredItems: drafts.filter(\.recovered).count,
            unknownMediaItems: unknownMediaItems,
            embeddedItems: newItems.filter { $0.embeddingStatus == .embedded }.count,
            sidecarOnlyItems: newItems.filter { $0.embeddingStatus == .sidecarOnly }.count
        )
        let reportURL = transactionRoot.appending(path: "imports/\(importID.uuidString.lowercased()).json")
        try fileManager.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: reportURL, options: [.atomic])

        try await store.commit(manifest: VaultManifest(profile: profile, items: allItems), transactionDirectory: transactionRoot)
        progress(.init(phase: .indexing, completed: 1, total: 1, detail: nil))
        progress(.init(phase: .verifying, completed: 1, total: 1, detail: "\(newItems.count) new memories"))
        return profile
    }

    func sourceChecksum(for sourceURL: URL) throws -> String {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        return try sha256(of: sourceURL)
    }

    func suggestedProfile(for sourceURL: URL) throws -> ArchiveProfileSuggestion {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard let archive = try? Archive(url: sourceURL, accessMode: .read, pathEncoding: nil) else {
            return ArchiveProfileSuggestion(
                name: filenameSuggestedProfileName(from: sourceURL),
                identityKey: nil
            )
        }

        let candidates = archive.filter { entry in
            guard entry.type == .file, entry.uncompressedSize <= 5_000_000 else { return false }
            let path = entry.path.lowercased()
            return path.contains("personal_information") &&
                (path.hasSuffix("personal_information.html") ||
                    path.hasSuffix("personal_information.json") ||
                    path.hasSuffix("instagram_profile_information.html") ||
                    path.hasSuffix("instagram_profile_information.json") ||
                    path.hasSuffix("profile_information.html") ||
                    path.hasSuffix("profile_information.json"))
        }

        for entry in candidates {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }

            if entry.path.lowercased().hasSuffix(".html"),
               let html = String(data: data, encoding: .utf8),
               let fields = try profileFields(inHTML: html),
               let suggestion = profileSuggestion(from: fields) {
                return suggestion
            }

            if entry.path.lowercased().hasSuffix(".json"),
               let value = try? JSONSerialization.jsonObject(with: data) {
                let fields = profileFields(inJSON: value)
                if let suggestion = profileSuggestion(from: fields) {
                    return suggestion
                }
            }
        }

        return ArchiveProfileSuggestion(
            name: filenameSuggestedProfileName(from: sourceURL),
            identityKey: nil
        )
    }

    func suggestedProfileName(for sourceURL: URL) throws -> String {
        try suggestedProfile(for: sourceURL).name
    }

    private func validatedEntries(in archive: Archive, destinationRoot: URL) throws -> [Entry] {
        var entries: [Entry] = []

        for entry in archive {
            guard entry.type == .file else { continue }
            _ = try safeDestination(for: entry.path, under: destinationRoot)
            entries.append(entry)
        }

        return entries
    }

    private func validateWorkingCapacity(for entries: [Entry], at location: URL) throws {
        let expandedBytes = entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        let workingCopies = expandedBytes.multipliedReportingOverflow(by: 2)
        guard !workingCopies.overflow else { throw ImportError.insufficientStorage }

        let safetyMargin = max(UInt64(268_435_456), expandedBytes / 10)
        let required = workingCopies.partialValue.addingReportingOverflow(safetyMargin)
        guard !required.overflow else { throw ImportError.insufficientStorage }

        let available = try location.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard required.partialValue < UInt64(max(available, 0)) else {
            throw ImportError.insufficientStorage
        }
    }

    private func safeDestination(for path: String, under root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !components.contains("..") else {
            throw ImportError.unsafeArchivePath(path)
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let destination = components.reduce(resolvedRoot) { partial, component in
            partial.appending(path: String(component))
        }.standardizedFileURL
        guard destination.path.hasPrefix(resolvedRoot.path + "/") else {
            throw ImportError.unsafeArchivePath(path)
        }
        return destination
    }

    private func isOwnedContentPath(_ path: String) -> Bool {
        path.hasPrefix("media/") ||
            path.hasPrefix("your_instagram_activity/content/") ||
            path.hasPrefix("your_instagram_activity/media/") ||
            path.hasPrefix("personal_information/personal_information/")
    }

    private func parseHTMLContent(at root: URL) throws -> [Draft] {
        var drafts: [Draft] = []
        var occurrences: [String: Int] = [:]
        let activityRoot = root.appending(path: "your_instagram_activity", directoryHint: .isDirectory)
        guard let enumerator = fileManager.enumerator(
            at: activityRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "html" else { continue }
            let path = try relativePath(of: url, under: root)
            guard path.contains("/content/") || path.contains("/media/") else { continue }
            let kind = contentKind(forMetadataPath: path)
            let html = try String(contentsOf: url, encoding: .utf8)
            let document = try SwiftSoup.parse(html)
            let mediaElements = try document.select("img[src^=media/], video[src^=media/]")

            for element in mediaElements.array() {
                let sourcePath = try element.attr("src")
                guard sourcePath.hasPrefix("media/") else { continue }
                let card = nearestCard(from: element)
                let caption = try card?.select("._2pim").first()?.text()
                let timestamp = try card?.select("._a6-o").last()?.text()
                let occurrence = occurrences[sourcePath, default: 0]
                occurrences[sourcePath] = occurrence + 1
                drafts.append(Draft(
                    sourcePath: sourcePath,
                    kind: kind,
                    caption: caption,
                    timestamp: timestamp,
                    capturedAt: nil,
                    occurrence: occurrence,
                    recovered: false
                ))
            }
        }
        return drafts
    }

    private func parseJSONContent(at root: URL) throws -> [Draft] {
        let activityRoot = root.appending(path: "your_instagram_activity", directoryHint: .isDirectory)
        guard let enumerator = fileManager.enumerator(
            at: activityRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [Draft] = []
        var occurrences: [String: Int] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "json" else { continue }
            let relative = try relativePath(of: url, under: root)
            guard relative.contains("/content/") || relative.contains("/media/") else { continue }
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            collectJSONDrafts(
                from: object,
                sourcePage: relative,
                kind: contentKind(forMetadataPath: relative),
                occurrences: &occurrences,
                into: &results
            )
        }
        return results
    }

    private func relativePath(of child: URL, under parent: URL) throws -> String {
        let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
        guard childPath.hasPrefix(parentPath + "/") else {
            throw ImportError.unsafeArchivePath(child.path)
        }
        return String(childPath.dropFirst(parentPath.count + 1))
    }

    private func collectJSONDrafts(
        from value: Any,
        sourcePage: String,
        kind: ContentKind,
        occurrences: inout [String: Int],
        into results: inout [Draft]
    ) {
        if let array = value as? [Any] {
            for item in array {
                collectJSONDrafts(from: item, sourcePage: sourcePage, kind: kind, occurrences: &occurrences, into: &results)
            }
            return
        }

        guard let dictionary = value as? [String: Any] else { return }
        let sourcePath = (dictionary["uri"] as? String) ?? (dictionary["media_uri"] as? String)
        if let sourcePath, sourcePath.hasPrefix("media/") {
            let timestampNumber = (dictionary["creation_timestamp"] as? NSNumber) ?? (dictionary["timestamp"] as? NSNumber)
            let capturedAt = timestampNumber.map { Date(timeIntervalSince1970: $0.doubleValue) }
            let caption = (dictionary["title"] as? String) ?? (dictionary["caption"] as? String)
            let occurrence = occurrences[sourcePath, default: 0]
            occurrences[sourcePath] = occurrence + 1
            results.append(Draft(
                sourcePath: sourcePath,
                kind: kind,
                caption: caption,
                timestamp: capturedAt.map { Self.exportDateFormatter.string(from: $0) },
                capturedAt: capturedAt,
                occurrence: occurrence,
                recovered: false
            ))
        }

        for nested in dictionary.values where nested is [Any] || nested is [String: Any] {
            collectJSONDrafts(from: nested, sourcePage: sourcePage, kind: kind, occurrences: &occurrences, into: &results)
        }
    }

    private func contentKind(forMetadataPath path: String) -> ContentKind {
        let lowercased = path.lowercased()
        if lowercased.contains("stor") { return .story }
        if lowercased.contains("reel") { return .reel }
        if lowercased.contains("archive") { return .archivedPost }
        if lowercased.contains("profile") { return .profilePhoto }
        if lowercased.contains("post") { return .post }
        return .other
    }

    private func nearestCard(from element: Element) -> Element? {
        var current = element.parent()
        while let candidate = current {
            if candidate.hasClass("_a6-g") || candidate.hasClass("pam") { return candidate }
            current = candidate.parent()
        }
        return nil
    }

    private func recoveredDrafts(at root: URL, excluding referenced: Set<String>) throws -> [Draft] {
        let mediaRoot = root.appending(path: "media", directoryHint: .isDirectory)
        guard let enumerator = fileManager.enumerator(
            at: mediaRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [Draft] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = try relativePath(of: url, under: root)
            guard !referenced.contains(relative) else { continue }
            results.append(Draft(
                sourcePath: relative,
                kind: .recovered,
                caption: nil,
                timestamp: nil,
                capturedAt: inferredDate(fromMediaPath: relative),
                occurrence: 0,
                recovered: true
            ))
        }
        return results
    }

    private func inferredDate(fromMediaPath path: String) -> Date? {
        let expression = try? NSRegularExpression(pattern: #"/(20\d{2})(\d{2})/"#)
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let match = expression?.firstMatch(in: path, range: range),
              let yearRange = Range(match.range(at: 1), in: path),
              let monthRange = Range(match.range(at: 2), in: path),
              let year = Int(path[yearRange]),
              let month = Int(path[monthRange]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))
    }

    private func coordinatedCopy(from source: URL, to destination: URL) throws {
        let hasAccess = source.startAccessingSecurityScopedResource()
        defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            do { try fileManager.copyItem(at: coordinatedURL, to: destination) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func stableID(for draft: Draft, checksum: String) -> String {
        let timestamp = draft.capturedAt.map { String($0.timeIntervalSince1970) } ?? draft.timestamp ?? ""
        let value = [checksum, draft.kind.rawValue, timestamp, String(draft.occurrence)].joined(separator: "|")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func mergeKey(for record: MediaRecord) -> String {
        mergeKey(checksum: record.checksum, capturedAt: record.capturedAt, kind: record.contentKind)
    }

    private func mergeKey(checksum: String, capturedAt: Date?, kind: ContentKind) -> String {
        "\(checksum)|\(capturedAt?.timeIntervalSince1970 ?? -1)|\(kind.rawValue)"
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return Self.exportDateFormatter.date(from: value)
    }

    private func dateComponents(for date: Date?) -> (year: String, month: String) {
        guard let date else { return ("undated", "00") }
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return (String(format: "%04d", components.year ?? 0), String(format: "%02d", components.month ?? 0))
    }

    private func sniffMediaType(at url: URL) -> MediaType {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif"].contains(ext) { return .image }
        if ["mp4", "mov", "m4v"].contains(ext) { return .video }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe).prefix(16) else { return .unknown }
        let bytes = Array(data)
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) || bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image }
        if bytes.count >= 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" { return .video }
        return .unknown
    }

    private func preferredExtension(for url: URL, mediaType: MediaType) -> String {
        if !url.pathExtension.isEmpty { return url.pathExtension.lowercased() }
        switch mediaType {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let type = CGImageSourceGetType(source) else { return "jpg" }
            return UTType(type as String)?.preferredFilenameExtension ?? "jpg"
        case .video: return "mp4"
        case .unknown: return "bin"
        }
    }

    private func mediaDetails(at url: URL, type: MediaType) async -> (dimensions: PixelSize?, duration: TimeInterval?) {
        switch type {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return (nil, nil) }
            return (PixelSize(width: width, height: height), nil)
        case .video:
            let asset = AVURLAsset(url: url)
            let duration = try? await asset.load(.duration)
            let tracks = try? await asset.loadTracks(withMediaType: .video)
            var size: PixelSize?
            if let track = tracks?.first,
               let naturalSize = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let transformed = naturalSize.applying(transform)
                size = PixelSize(width: Int(abs(transformed.width)), height: Int(abs(transformed.height)))
            }
            let seconds = duration?.seconds
            return (size, seconds?.isFinite == true ? seconds : nil)
        case .unknown:
            return (nil, nil)
        }
    }

    private func generateThumbnail(for record: MediaRecord, mediaURL: URL) async throws {
        try fileManager.createDirectory(at: paths.thumbnails, withIntermediateDirectories: true)
        let destination = paths.thumbnail(for: record.id)
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: mediaURL,
            size: CGSize(width: 640, height: 640),
            scale: 1,
            representationTypes: .thumbnail
        )
        let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        #if canImport(UIKit)
        guard let data = representation.uiImage.jpegData(compressionQuality: 0.82) else { return }
        #elseif canImport(AppKit)
        guard let tiff = representation.nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return }
        #else
        return
        #endif
        try data.write(to: destination, options: [.atomic])
    }

    private func profileFields(inHTML html: String) throws -> [String: String]? {
        let document = try SwiftSoup.parse(html)
        let cells = try document.select("td").array()
        var fields: [String: String] = [:]

        for label in ["Username", "Name"] {
            for cell in cells where cell.ownText().trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == label.lowercased() {
                let value = try cell.select("div").first()?.text().nilIfBlank
                if let value { fields[label.lowercased()] = value }
            }
        }

        return fields.isEmpty ? nil : fields
    }

    private func profileFields(inJSON value: Any) -> [String: String] {
        if let dictionary = value as? [String: Any] {
            var fields: [String: String] = [:]
            for key in ["username", "name", "full_name"] {
                if let value = dictionary[key] as? String, let field = value.nilIfBlank {
                    fields[key] = field
                }
            }
            for nested in dictionary.values {
                let nestedFields = profileFields(inJSON: nested)
                for (key, value) in nestedFields where fields[key] == nil {
                    fields[key] = value
                }
            }
            return fields
        } else if let array = value as? [Any] {
            var fields: [String: String] = [:]
            for nested in array {
                let nestedFields = profileFields(inJSON: nested)
                for (key, value) in nestedFields where fields[key] == nil {
                    fields[key] = value
                }
            }
            return fields
        }
        return [:]
    }

    private func profileSuggestion(from fields: [String: String]) -> ArchiveProfileSuggestion? {
        let username = fields["username"]?.nilIfBlank
        let name = fields["name"]?.nilIfBlank ?? fields["full_name"]?.nilIfBlank
        guard let displayName = name ?? username else { return nil }
        let identitySource = username ?? name
        return ArchiveProfileSuggestion(
            name: displayName,
            identityKey: identitySource.map(normalizedIdentity)
        )
    }

    private func normalizedIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
    }

    private func filenameSuggestedProfileName(from sourceURL: URL) -> String {
        let raw = sourceURL.deletingPathExtension().lastPathComponent
        if let date = archiveDate(in: raw) {
            return "Instagram · \(date.formatted(.dateTime.month(.abbreviated).year()))"
        }
        if raw.lowercased().hasPrefix("ig") { return "Instagram Archive" }
        return raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private func archiveDate(in filename: String) -> Date? {
        let expression = try? NSRegularExpression(pattern: #"20\d{6}"#)
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = expression?.firstMatch(in: filename, range: range),
              let matchRange = Range(match.range, in: filename) else { return nil }
        return Self.archiveNameDateFormatter.date(from: String(filename[matchRange]))
    }

    private func recordWarnings(
        recovered: Bool,
        mediaType: MediaType,
        embeddingWarning: String?
    ) -> [String] {
        var warnings: [String] = []
        if recovered { warnings.append("Recovered without a matching metadata record") }
        if mediaType == .unknown { warnings.append("Media format could not be identified") }
        if let embeddingWarning { warnings.append(embeddingWarning) }
        return warnings
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMM dd, yyyy h:mm a"
        formatter.isLenient = true
        return formatter
    }()

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let archiveNameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

enum ImportError: LocalizedError {
    case insufficientStorage
    case unsafeArchivePath(String)

    var errorDescription: String? {
        switch self {
        case .insufficientStorage: "There isn’t enough free space to safely import this archive."
        case .unsafeArchivePath(let path): "The archive contains an unsafe file path: \(path)"
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
