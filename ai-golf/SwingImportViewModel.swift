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

    enum MetadataState: Equatable {
        case idle
        case loading
        case available(SwingVideoMetadata)
        case failed(message: String)
    }

    enum FrameExtractionState {
        case idle
        case extracting
        case extracted(SwingExtractedFrame)
        case failed(message: String)
    }

    private let fileManager: FileManager
    private let importDirectory: URL
    private let videoProcessor: SwingVideoProcessing
    private var currentImportedFile: URL?
    private var activeVideoID = UUID()

    private(set) var state: State = .empty
    private(set) var metadataState: MetadataState = .idle
    private(set) var selectedTimestampSeconds = 0.0
    private(set) var frameExtractionState: FrameExtractionState = .idle

    init(
        importDirectory: URL = FileManager.default.temporaryDirectory
            .appending(path: "ImportedSwings", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.importDirectory = importDirectory
        self.fileManager = fileManager
        self.videoProcessor = AVFoundationSwingVideoProcessor()
    }

    init(
        importDirectory: URL,
        fileManager: FileManager = .default,
        videoProcessor: SwingVideoProcessing
    ) {
        self.importDirectory = importDirectory
        self.fileManager = fileManager
        self.videoProcessor = videoProcessor
    }

    func importVideo(loadSourceURL: () async throws -> URL) async {
        let videoID = UUID()
        activeVideoID = videoID
        state = .importing
        clearInspectionState()

        do {
            let sourceURL = try await loadSourceURL()
            let importedURL = try copyIntoImportDirectory(sourceURL)
            removeCurrentImportedFile()

            currentImportedFile = importedURL
            let importedSwing = ImportedSwing(localVideoURL: importedURL)
            state = .ready(importedSwing)
            metadataState = .loading

            await inspectImportedVideo(importedSwing, videoID: videoID)
        } catch {
            state = .failed(message: "The video could not be imported. Please try another video.")
        }
    }

    func setSelectedTimestamp(_ timestampSeconds: Double) {
        selectedTimestampSeconds = clampedTimestamp(timestampSeconds)
    }

    func extractFrame() async {
        guard case .ready(let swing) = state else { return }

        let videoID = activeVideoID
        let timestampSeconds = clampedTimestamp(selectedTimestampSeconds)
        selectedTimestampSeconds = timestampSeconds
        frameExtractionState = .extracting

        do {
            let frame = try await videoProcessor.extractFrame(at: timestampSeconds, from: swing.localVideoURL)
            guard activeVideoID == videoID else { return }
            frameExtractionState = .extracted(frame)
        } catch {
            guard activeVideoID == videoID else { return }
            frameExtractionState = .failed(message: "The frame could not be extracted. Try another timestamp.")
        }
    }

    private func inspectImportedVideo(_ swing: ImportedSwing, videoID: UUID) async {
        do {
            let metadata = try await videoProcessor.inspectVideo(at: swing.localVideoURL)
            guard activeVideoID == videoID else { return }
            metadataState = .available(metadata)
            selectedTimestampSeconds = clampedTimestamp(selectedTimestampSeconds)
        } catch {
            guard activeVideoID == videoID else { return }
            metadataState = .failed(message: "The video metadata could not be loaded.")
        }
    }

    private func clearInspectionState() {
        metadataState = .idle
        selectedTimestampSeconds = 0
        frameExtractionState = .idle
    }

    private func clampedTimestamp(_ timestampSeconds: Double) -> Double {
        let durationSeconds: Double
        if case .available(let metadata) = metadataState {
            durationSeconds = metadata.durationSeconds
        } else {
            durationSeconds = 0
        }

        guard durationSeconds > 0 else { return 0 }
        return min(max(timestampSeconds, 0), durationSeconds)
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
