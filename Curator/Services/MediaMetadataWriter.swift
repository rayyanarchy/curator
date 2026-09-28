import Foundation
import ImageIO

struct MetadataEmbeddingResult: Sendable {
    let status: EmbeddingStatus
    let warning: String?
}

struct MediaMetadataWriter: Sendable {
    private static let curatorNamespace = "https://curator.app/ns/1.0/" as CFString
    private static let curatorPrefix = "curator" as CFString

    func embed(
        capturedAt: Date?,
        caption: String?,
        originalExportPath: String,
        contentKind: ContentKind,
        in mediaURL: URL,
        mediaType: MediaType
    ) -> MetadataEmbeddingResult {
        guard mediaType == .image else {
            return .init(status: .sidecarOnly, warning: nil)
        }

        guard let source = CGImageSourceCreateWithURL(mediaURL as CFURL, nil),
              let type = CGImageSourceGetType(source) else {
            return .init(status: .sidecarOnly, warning: "Portable metadata could not be written to this image")
        }

        let temporaryURL = mediaURL.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString.lowercased()).metadata")
        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            type,
            CGImageSourceGetCount(source),
            nil
        ) else {
            return .init(status: .sidecarOnly, warning: "Portable metadata is not supported by this image format")
        }

        let metadata = CGImageMetadataCreateMutable()
        var registrationError: Unmanaged<CFError>?
        guard CGImageMetadataRegisterNamespaceForPrefix(
            metadata,
            Self.curatorNamespace,
            Self.curatorPrefix,
            &registrationError
        ) else {
            return .init(status: .sidecarOnly, warning: "Portable metadata could not be prepared")
        }

        setString(
            originalExportPath,
            namespace: Self.curatorNamespace,
            prefix: Self.curatorPrefix,
            name: "OriginalExportPath" as CFString,
            path: "curator:OriginalExportPath" as CFString,
            in: metadata
        )
        setString(
            contentKind.rawValue,
            namespace: Self.curatorNamespace,
            prefix: Self.curatorPrefix,
            name: "ContentKind" as CFString,
            path: "curator:ContentKind" as CFString,
            in: metadata
        )

        if let capturedAt {
            let isoDate = Self.isoDateFormatter.string(from: capturedAt)
            let exifDate = Self.exifDateFormatter.string(from: capturedAt)
            setString(
                isoDate,
                namespace: kCGImageMetadataNamespaceXMPBasic,
                prefix: kCGImageMetadataPrefixXMPBasic,
                name: "CreateDate" as CFString,
                path: "xmp:CreateDate" as CFString,
                in: metadata
            )
            setString(
                exifDate,
                namespace: kCGImageMetadataNamespaceExif,
                prefix: kCGImageMetadataPrefixExif,
                name: "DateTimeOriginal" as CFString,
                path: "exif:DateTimeOriginal" as CFString,
                in: metadata
            )
        }

        if let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty {
            setString(
                caption,
                namespace: kCGImageMetadataNamespaceTIFF,
                prefix: kCGImageMetadataPrefixTIFF,
                name: "ImageDescription" as CFString,
                path: "tiff:ImageDescription" as CFString,
                in: metadata
            )
            setAlternateText(caption, in: metadata)
        }

        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ]
        var copyError: Unmanaged<CFError>?
        let copied = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &copyError)
        guard copied,
              validateCopy(
                at: temporaryURL,
                against: source,
                expectedOriginalPath: originalExportPath,
                expectedContentKind: contentKind.rawValue
              ) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return .init(status: .sidecarOnly, warning: "Portable metadata is not supported by this image format")
        }

        do {
            _ = try FileManager.default.replaceItemAt(mediaURL, withItemAt: temporaryURL)
            return .init(status: .embedded, warning: nil)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            return .init(status: .sidecarOnly, warning: "Portable metadata could not be saved")
        }
    }

    private func setString(
        _ value: String,
        namespace: CFString,
        prefix: CFString,
        name: CFString,
        path: CFString,
        in metadata: CGMutableImageMetadata
    ) {
        guard let tag = CGImageMetadataTagCreate(
            namespace,
            prefix,
            name,
            .string,
            value as CFString
        ) else { return }
        CGImageMetadataSetTagWithPath(metadata, nil, path, tag)
    }

    private func setAlternateText(_ value: String, in metadata: CGMutableImageMetadata) {
        let localized = ["x-default": value] as CFDictionary
        guard let tag = CGImageMetadataTagCreate(
            kCGImageMetadataNamespaceDublinCore,
            kCGImageMetadataPrefixDublinCore,
            "description" as CFString,
            .alternateText,
            localized
        ) else { return }
        CGImageMetadataSetTagWithPath(metadata, nil, "dc:description" as CFString, tag)
    }

    private func validateCopy(
        at outputURL: URL,
        against source: CGImageSource,
        expectedOriginalPath: String,
        expectedContentKind: String
    ) -> Bool {
        guard let output = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              CGImageSourceGetCount(output) == CGImageSourceGetCount(source),
              CGImageSourceGetType(output) == CGImageSourceGetType(source),
              let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let outputProperties = CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any],
              let outputMetadata = CGImageSourceCopyMetadataAtIndex(output, 0, nil),
              let embeddedPath = CGImageMetadataCopyStringValueWithPath(
                outputMetadata,
                nil,
                "curator:OriginalExportPath" as CFString
              ),
              let embeddedKind = CGImageMetadataCopyStringValueWithPath(
                outputMetadata,
                nil,
                "curator:ContentKind" as CFString
              )
        else { return false }

        let sourceWidth = sourceProperties[kCGImagePropertyPixelWidth] as? Int
        let sourceHeight = sourceProperties[kCGImagePropertyPixelHeight] as? Int
        let outputWidth = outputProperties[kCGImagePropertyPixelWidth] as? Int
        let outputHeight = outputProperties[kCGImagePropertyPixelHeight] as? Int
        return sourceWidth == outputWidth &&
            sourceHeight == outputHeight &&
            embeddedPath as String == expectedOriginalPath &&
            embeddedKind as String == expectedContentKind
    }

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}
