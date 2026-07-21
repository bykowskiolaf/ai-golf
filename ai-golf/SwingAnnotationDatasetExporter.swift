import Foundation

struct SwingAnnotationDatasetExporter: Sendable {
    enum ExportError: Error, Equatable {
        case stagingFailed
        case videoCopyFailed
        case jsonWriteFailed
    }

    var stagingRoot: URL
    var createDirectory: @Sendable (URL, Bool) throws -> Void
    var fileExists: @Sendable (String) -> Bool
    var removeItem: @Sendable (URL) throws -> Void
    var contentsOfDirectory: @Sendable (URL) throws -> [URL]
    var copyItem: @Sendable (URL, URL) throws -> Void
    var writeData: @Sendable (Data, URL) throws -> Void

    nonisolated init(
        stagingRoot: URL = FileManager.default.temporaryDirectory.appending(path: "SwingAnnotationExports", directoryHint: .isDirectory),
        fileManager: FileManager = .default,
        copyItem: (@Sendable (URL, URL) throws -> Void)? = nil,
        writeData: (@Sendable (Data, URL) throws -> Void)? = nil
    ) {
        self.stagingRoot = stagingRoot
        createDirectory = { url, withIntermediateDirectories in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
        }
        fileExists = { path in
            FileManager.default.fileExists(atPath: path)
        }
        removeItem = { url in
            try FileManager.default.removeItem(at: url)
        }
        contentsOfDirectory = { url in
            try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }
        self.copyItem = copyItem ?? { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
        self.writeData = writeData ?? { data, destination in
            try data.write(to: destination, options: .atomic)
        }
    }

    nonisolated func sourceVideoFilename(annotationID: UUID, sourceVideoURL: URL) -> String {
        let baseName = sanitizedFilenameComponent("swing-\(annotationID.uuidString)")
        let sourceExtension = sanitizedFilenameExtension(sourceVideoURL.pathExtension)
        if sourceExtension.isEmpty {
            return "\(baseName).mov"
        }
        return "\(baseName).\(sourceExtension)"
    }

    func export(record: SwingAnnotationRecord, sourceVideoURL: URL) throws -> SwingAnnotationDatasetExport {
        let encoder = JSONEncoder.swingAnnotationEncoder()
        let data = try encoder.encode(record)
        return try export(
            annotationID: record.annotationID,
            sourceVideoFilename: record.sourceVideoFilename,
            annotationData: data,
            sourceVideoURL: sourceVideoURL
        )
    }

    nonisolated func export(
        annotationID: UUID,
        sourceVideoFilename: String,
        annotationData: Data,
        sourceVideoURL: URL
    ) throws -> SwingAnnotationDatasetExport {
        let baseName = sanitizedFilenameComponent("swing-\(annotationID.uuidString)")
        let videoFilename = sourceVideoFilename
        let annotationFilename = "\(baseName).json"
        let stagingDirectory = stagingRoot.appending(path: baseName, directoryHint: .isDirectory)
        let videoURL = stagingDirectory.appending(path: videoFilename)
        let annotationURL = stagingDirectory.appending(path: annotationFilename)

        do {
            try createDirectory(stagingRoot, true)
            if fileExists(stagingDirectory.path) {
                try removeItem(stagingDirectory)
            }
            try createDirectory(stagingDirectory, true)
        } catch {
            throw ExportError.stagingFailed
        }

        do {
            try copyItem(sourceVideoURL, videoURL)
        } catch {
            throw ExportError.videoCopyFailed
        }

        do {
            try writeData(annotationData, annotationURL)
        } catch {
            throw ExportError.jsonWriteFailed
        }

        return SwingAnnotationDatasetExport(
            stagingDirectory: stagingDirectory,
            videoURL: videoURL,
            annotationURL: annotationURL
        )
    }

    nonisolated func cleanupStagedExports(keeping directoryToKeep: URL? = nil) {
        guard let contents = try? contentsOfDirectory(stagingRoot) else { return }
        for url in contents where url != directoryToKeep {
            try? removeItem(url)
        }
    }

    private nonisolated func sanitizedFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    private nonisolated func sanitizedFilenameExtension(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(value.lowercased().unicodeScalars.compactMap { allowed.contains($0) ? Character($0) : nil })
    }
}

extension JSONEncoder {
    static func swingAnnotationEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static func swingAnnotationDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
