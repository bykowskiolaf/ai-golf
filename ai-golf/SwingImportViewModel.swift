import Foundation
import Observation

@MainActor
@Observable
final class SwingImportViewModel {
    enum State: Equatable {
        case empty
        case importing
        case ready(ImportedSwing)
        case failed(message: String)
    }

    private let fileManager: FileManager
    private let importDirectory: URL
    private var currentImportedFile: URL?

    private(set) var state: State = .empty

    init(
        importDirectory: URL = FileManager.default.temporaryDirectory
            .appending(path: "ImportedSwings", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.importDirectory = importDirectory
        self.fileManager = fileManager
    }

    func importVideo(loadSourceURL: () async throws -> URL) async {
        state = .importing

        do {
            let sourceURL = try await loadSourceURL()
            let importedURL = try copyIntoImportDirectory(sourceURL)
            removeCurrentImportedFile()

            currentImportedFile = importedURL
            state = .ready(ImportedSwing(localVideoURL: importedURL))
        } catch {
            state = .failed(message: "The video could not be imported. Please try another video.")
        }
    }

    private func copyIntoImportDirectory(_ sourceURL: URL) throws -> URL {
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true, attributes: nil)

        let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destinationURL = importDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension(fileExtension)

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func removeCurrentImportedFile() {
        guard let currentImportedFile else { return }
        try? fileManager.removeItem(at: currentImportedFile)
    }
}
