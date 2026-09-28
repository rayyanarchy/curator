import Foundation

struct AppPaths: Sendable {
    let applicationSupport: URL
    let caches: URL

    init(fileManager: FileManager = .default) {
        applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Curator", directoryHint: .isDirectory)
        caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Curator", directoryHint: .isDirectory)
    }

    init(applicationSupport: URL, caches: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
    }

    var vaults: URL { applicationSupport.appending(path: "Vaults", directoryHint: .isDirectory) }
    var staging: URL { applicationSupport.appending(path: "ImportStaging", directoryHint: .isDirectory) }
    var thumbnails: URL { caches.appending(path: "Thumbnails", directoryHint: .isDirectory) }

    func vault(for profileID: UUID) -> URL {
        vaults.appending(path: profileID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    func manifest(for profileID: UUID) -> URL {
        vault(for: profileID).appending(path: "vault.json")
    }

    func thumbnail(for itemID: String) -> URL {
        thumbnails.appending(path: "\(itemID).jpg")
    }
}
