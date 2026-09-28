import Foundation
import Observation

struct PendingProfileImport: Identifiable, Sendable {
    let id = UUID()
    let sourceURL: URL
    let suggestedName: String
    let sourceIdentity: String?
    let sourceChecksum: String
    let matchingProfiles: [VaultProfile]
}

@MainActor
@Observable
final class AppModel {
    private static let lastUsedProfileKey = "lastUsedProfileID"

    private let vaultStore: VaultStore
    private let importer: InstagramArchiveImporter
    private let userDefaults: UserDefaults
    @ObservationIgnored private var mediaPreferencesByProfileID: [UUID: MediaPreferences] = [:]
    @ObservationIgnored private var inspectionTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?

    var isLoadingProfiles = true
    var profiles: [VaultProfile] = []
    var selectedProfileID: UUID?
    var itemsByProfileID: [UUID: [MediaRecord]] = [:]
    var latestProfilePhotosByProfileID: [UUID: MediaRecord] = [:]
    var isInspectingArchive = false
    var isImporting = false
    var importSnapshot: ImportSnapshot?
    var importingProfileName: String?
    var pendingImport: PendingProfileImport?
    var errorMessage: String?

    convenience init(fileManager: FileManager = .default) {
        self.init(
            paths: AppPaths(fileManager: fileManager),
            fileManager: fileManager,
            userDefaults: .standard
        )
    }

    init(
        paths: AppPaths,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) {
        let store = VaultStore(paths: paths, fileManager: fileManager)
        vaultStore = store
        importer = InstagramArchiveImporter(paths: paths, store: store, fileManager: fileManager)
        self.userDefaults = userDefaults
    }

    var activityTitle: String? {
        if isInspectingArchive { return "Checking archive" }
        if let importSnapshot { return importSnapshot.phase.rawValue }
        if isImporting { return "Importing archive" }
        return nil
    }

    func loadProfiles() async {
        defer { isLoadingProfiles = false }
        do {
            profiles = try await vaultStore.loadProfiles()
            mediaPreferencesByProfileID = Dictionary(uniqueKeysWithValues: profiles.map {
                ($0.id, $0.effectiveMediaPreferences)
            })
            var latestPhotos: [UUID: MediaRecord] = [:]
            for profile in profiles {
                if let photo = try await vaultStore.loadLatestProfilePhoto(profileID: profile.id) {
                    latestPhotos[profile.id] = photo
                }
            }
            latestProfilePhotosByProfileID = latestPhotos
            restoreLastUsedProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadItems(for profileID: UUID) async {
        do {
            setLoadedItems(
                try await vaultStore.loadItems(profileID: profileID),
                for: profileID
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func profile(withID profileID: UUID) -> VaultProfile? {
        profiles.first { $0.id == profileID }
    }

    func latestProfilePhoto(for profileID: UUID) -> MediaRecord? {
        latestProfilePhotosByProfileID[profileID]
    }

    func mediaPreferences(for profileID: UUID) -> MediaPreferences {
        mediaPreferencesByProfileID[profileID]
            ?? profile(withID: profileID)?.effectiveMediaPreferences
            ?? .all
    }

    func rememberMediaPreferences(
        _ preferences: MediaPreferences,
        for profileID: UUID
    ) {
        guard profile(withID: profileID) != nil else { return }
        mediaPreferencesByProfileID[profileID] = preferences
    }

    var selectedProfile: VaultProfile? {
        guard let selectedProfileID else { return nil }
        return profile(withID: selectedProfileID)
    }

    func selectProfile(_ profileID: UUID) {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        selectedProfileID = profileID
        userDefaults.set(profileID.uuidString, forKey: Self.lastUsedProfileKey)
    }

    func inspectArchive(from sourceURL: URL) {
        guard !isInspectingArchive, !isImporting else { return }
        isInspectingArchive = true

        inspectionTask?.cancel()
        inspectionTask = Task { [self] in
            defer {
                isInspectingArchive = false
                inspectionTask = nil
            }
            do {
                async let suggestion = importer.suggestedProfile(for: sourceURL)
                async let checksum = importer.sourceChecksum(for: sourceURL)
                let (detected, sourceChecksum) = try await (suggestion, checksum)
                let matches = matchingProfiles(for: detected)

                for profile in matches {
                    if try await vaultStore.hasImportedArchive(
                        checksum: sourceChecksum,
                        profileID: profile.id
                    ) {
                        errorMessage = "This exact archive is already in \(profile.name)."
                        return
                    }
                }

                pendingImport = PendingProfileImport(
                    sourceURL: sourceURL,
                    suggestedName: detected.name,
                    sourceIdentity: detected.identityKey,
                    sourceChecksum: sourceChecksum,
                    matchingProfiles: matches
                )
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelPendingImport() {
        inspectionTask?.cancel()
        inspectionTask = nil
        isInspectingArchive = false
        pendingImport = nil
    }

    func createProfile(from proposal: PendingProfileImport, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        pendingImport = nil
        runImport(from: proposal, targetProfileID: nil, profileName: trimmedName)
    }

    func merge(_ proposal: PendingProfileImport, into profileID: UUID) {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        pendingImport = nil
        runImport(from: proposal, targetProfileID: profileID, profileName: nil)
    }

    func renameProfile(profileID: UUID, to name: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }

        do {
            let updated = try await vaultStore.renameProfile(profileID: profileID, to: trimmedName)
            replaceProfile(updated)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateMediaPreferences(
        profileID: UUID,
        preferences: MediaPreferences
    ) async -> Bool {
        do {
            let updated = try await vaultStore.updateMediaPreferences(
                profileID: profileID,
                preferences: preferences
            )
            mediaPreferencesByProfileID[profileID] = updated.effectiveMediaPreferences
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteProfile(profileID: UUID) async -> Bool {
        do {
            try await vaultStore.deleteProfile(profileID: profileID)
            profiles.removeAll { $0.id == profileID }
            itemsByProfileID[profileID] = nil
            latestProfilePhotosByProfileID[profileID] = nil
            mediaPreferencesByProfileID[profileID] = nil
            if selectedProfileID == profileID {
                if let replacement = profiles.first {
                    selectProfile(replacement.id)
                } else {
                    selectedProfileID = nil
                    userDefaults.removeObject(forKey: Self.lastUsedProfileKey)
                }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func runImport(
        from proposal: PendingProfileImport,
        targetProfileID: UUID?,
        profileName: String?
    ) {
        guard !isImporting else { return }
        isImporting = true
        importSnapshot = nil
        importingProfileName = profileName
            ?? targetProfileID.flatMap { profile(withID: $0)?.name }

        importTask?.cancel()
        importTask = Task { [self] in
            let (progressUpdates, progressContinuation) = AsyncStream.makeStream(
                of: ImportSnapshot.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            let progressConsumer = Task { [weak self] in
                for await snapshot in progressUpdates {
                    guard !Task.isCancelled else { return }
                    self?.importSnapshot = snapshot
                }
            }
            defer {
                progressContinuation.finish()
                progressConsumer.cancel()
                isImporting = false
                importSnapshot = nil
                importingProfileName = nil
                importTask = nil
            }
            do {
                let profile = try await importer.importArchive(
                    from: proposal.sourceURL,
                    targetProfileID: targetProfileID,
                    profileName: profileName,
                    sourceIdentity: proposal.sourceIdentity,
                    defensiveMerge: targetProfileID != nil
                ) { snapshot in
                    progressContinuation.yield(snapshot)
                }

                replaceProfile(profile)
                selectProfile(profile.id)
                setLoadedItems(
                    try await vaultStore.loadItems(profileID: profile.id),
                    for: profile.id
                )
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private func matchingProfiles(for suggestion: ArchiveProfileSuggestion) -> [VaultProfile] {
        profiles.filter { profile in
            if let identity = suggestion.identityKey {
                if profile.sourceIdentity == identity { return true }
                if profile.sourceIdentity == nil,
                   normalizedIdentity(profile.name) == normalizedIdentity(suggestion.name) {
                    return true
                }
            }
            return false
        }
    }

    private func replaceProfile(_ profile: VaultProfile) {
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        profiles.sort { $0.updatedAt > $1.updatedAt }
        mediaPreferencesByProfileID[profile.id] = profile.effectiveMediaPreferences
    }

    private func setLoadedItems(_ items: [MediaRecord], for profileID: UUID) {
        itemsByProfileID[profileID] = items
        latestProfilePhotosByProfileID[profileID] = items
            .filter { $0.contentKind == .profilePhoto && $0.mediaType == .image }
            .max { left, right in
                switch (left.capturedAt, right.capturedAt) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    leftDate < rightDate
                case (nil, _?):
                    true
                case (_?, nil):
                    false
                default:
                    left.id < right.id
                }
            }
    }

    private func restoreLastUsedProfile() {
        let storedID = userDefaults.string(forKey: Self.lastUsedProfileKey).flatMap(UUID.init(uuidString:))
        if let storedID, profiles.contains(where: { $0.id == storedID }) {
            selectedProfileID = storedID
        } else if let firstProfile = profiles.first {
            selectProfile(firstProfile.id)
        } else {
            selectedProfileID = nil
            userDefaults.removeObject(forKey: Self.lastUsedProfileKey)
        }
    }

    private func normalizedIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
    }
}
