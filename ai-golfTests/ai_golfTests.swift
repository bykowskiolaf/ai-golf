//
//  ai_golfTests.swift
//  ai-golfTests
//
//  Created by Olaf Bykowski on 20/07/2026.
//

import Testing
import CoreGraphics
import Foundation
@testable import ai_golf

struct ai_golfTests {

    @Test @MainActor func initialStateIsEmpty() {
        let viewModel = SwingImportViewModel(importDirectory: Self.temporaryDirectory())

        #expect(viewModel.state == SwingImportViewModel.State.empty)
    }

    @Test @MainActor func successfulImportProducesPlayableLocalURL() async throws {
        let importDirectory = Self.temporaryDirectory()
        let sourceURL = try Self.makeVideoFile(named: "source.mov")
        let viewModel = SwingImportViewModel(importDirectory: importDirectory, videoProcessor: StubVideoProcessor())

        await viewModel.importVideo { sourceURL }

        guard case .ready(let swing) = viewModel.state else {
            Issue.record("Expected ready state")
            return
        }

        #expect(swing.localVideoURL.path().hasPrefix(importDirectory.path()))
        #expect(FileManager.default.fileExists(atPath: swing.localVideoURL.path()))
        #expect(try Data(contentsOf: swing.localVideoURL) == Data("video".utf8))
    }

    @Test @MainActor func failedImportProducesErrorState() async {
        let viewModel = SwingImportViewModel(importDirectory: Self.temporaryDirectory())

        await viewModel.importVideo {
            throw TestImportError.failed
        }

        guard case .failed(let message) = viewModel.state else {
            Issue.record("Expected failed state")
            return
        }

        #expect(message == "The video could not be imported. Please try another video.")
    }

    @Test @MainActor func replacingVideoUpdatesSelectedVideoAndRemovesPreviousFile() async throws {
        let importDirectory = Self.temporaryDirectory()
        let firstSourceURL = try Self.makeVideoFile(named: "first.mov", contents: "first")
        let secondSourceURL = try Self.makeVideoFile(named: "second.mov", contents: "second")
        let viewModel = SwingImportViewModel(importDirectory: importDirectory, videoProcessor: StubVideoProcessor())

        await viewModel.importVideo { firstSourceURL }
        guard case .ready(let firstSwing) = viewModel.state else {
            Issue.record("Expected first ready state")
            return
        }

        await viewModel.importVideo { secondSourceURL }
        guard case .ready(let secondSwing) = viewModel.state else {
            Issue.record("Expected second ready state")
            return
        }

        #expect(firstSwing.localVideoURL != secondSwing.localVideoURL)
        #expect(!FileManager.default.fileExists(atPath: firstSwing.localVideoURL.path()))
        #expect(FileManager.default.fileExists(atPath: secondSwing.localVideoURL.path()))
        #expect(try Data(contentsOf: secondSwing.localVideoURL) == Data("second".utf8))
    }

    @Test @MainActor func metadataIsStoredAfterSuccessfulInspection() async throws {
        let metadata = SwingVideoMetadata(durationSeconds: 12.5, width: 1080, height: 1920, nominalFrameRate: 120, hasUsableVideoTrack: true)
        let viewModel = SwingImportViewModel(importDirectory: Self.temporaryDirectory(), videoProcessor: StubVideoProcessor(metadata: metadata))
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }

        #expect(viewModel.metadataState == .available(metadata))
    }

    @Test @MainActor func inspectionFailureProducesRecoverableError() async throws {
        let viewModel = SwingImportViewModel(
            importDirectory: Self.temporaryDirectory(),
            videoProcessor: StubVideoProcessor(metadataResult: .failure(TestImportError.failed))
        )
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }

        guard case .ready = viewModel.state else {
            Issue.record("Expected imported video to remain available")
            return
        }
        #expect(viewModel.metadataState == .failed(message: "The video metadata could not be loaded."))
    }

    @Test @MainActor func selectedTimestampsAreClampedToDuration() async throws {
        let viewModel = SwingImportViewModel(
            importDirectory: Self.temporaryDirectory(),
            videoProcessor: StubVideoProcessor(metadata: SwingVideoMetadata(durationSeconds: 8, width: 1920, height: 1080, nominalFrameRate: 30, hasUsableVideoTrack: true))
        )
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }

        viewModel.setSelectedTimestamp(-2)
        #expect(viewModel.selectedTimestampSeconds == 0)

        viewModel.setSelectedTimestamp(3.5)
        #expect(viewModel.selectedTimestampSeconds == 3.5)

        viewModel.setSelectedTimestamp(12)
        #expect(viewModel.selectedTimestampSeconds == 8)
    }

    @Test @MainActor func successfulExtractionStoresFrame() async throws {
        let frame = try Self.makeFrame(requestedTimestampSeconds: 4, actualTimestampSeconds: 4.02)
        let viewModel = SwingImportViewModel(
            importDirectory: Self.temporaryDirectory(),
            videoProcessor: StubVideoProcessor(frameResult: .success(frame))
        )
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }
        viewModel.setSelectedTimestamp(4)
        await viewModel.extractFrame()

        guard case .extracted(let extractedFrame) = viewModel.frameExtractionState else {
            Issue.record("Expected extracted frame")
            return
        }

        #expect(extractedFrame.requestedTimestampSeconds == 4)
        #expect(extractedFrame.actualTimestampSeconds == 4.02)
    }

    @Test @MainActor func extractionFailureDoesNotRemoveImportedVideo() async throws {
        let viewModel = SwingImportViewModel(
            importDirectory: Self.temporaryDirectory(),
            videoProcessor: StubVideoProcessor(frameResult: .failure(TestImportError.failed))
        )
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }
        await viewModel.extractFrame()

        guard case .ready(let swing) = viewModel.state else {
            Issue.record("Expected imported video to remain available")
            return
        }

        #expect(FileManager.default.fileExists(atPath: swing.localVideoURL.path()))
        guard case .failed(let message) = viewModel.frameExtractionState else {
            Issue.record("Expected extraction failure")
            return
        }
        #expect(message == "The frame could not be extracted. Try another timestamp.")
    }

    @Test @MainActor func replacingVideoClearsPreviousMetadataAndFrame() async throws {
        let processor = StubVideoProcessor()
        let viewModel = SwingImportViewModel(importDirectory: Self.temporaryDirectory(), videoProcessor: processor)
        let firstSourceURL = try Self.makeVideoFile(named: "first.mov", contents: "first")
        let secondSourceURL = try Self.makeVideoFile(named: "second.mov", contents: "second")

        await viewModel.importVideo { firstSourceURL }
        await viewModel.extractFrame()
        guard case .extracted = viewModel.frameExtractionState else {
            Issue.record("Expected first extracted frame")
            return
        }

        await viewModel.importVideo { secondSourceURL }

        #expect(viewModel.metadataState == .available(processor.metadata))
        guard case .idle = viewModel.frameExtractionState else {
            Issue.record("Expected previous frame state to be cleared")
            return
        }
    }

    @Test @MainActor func staleInspectionResultsDoNotOverwriteReplacement() async throws {
        let processor = DeferredVideoProcessor()
        let viewModel = SwingImportViewModel(importDirectory: Self.temporaryDirectory(), videoProcessor: processor)
        let firstSourceURL = try Self.makeVideoFile(named: "first.mov", contents: "first")
        let secondSourceURL = try Self.makeVideoFile(named: "second.mov", contents: "second")
        let firstMetadata = SwingVideoMetadata(durationSeconds: 5, width: 640, height: 480, nominalFrameRate: 30, hasUsableVideoTrack: true)
        let secondMetadata = SwingVideoMetadata(durationSeconds: 9, width: 1080, height: 1920, nominalFrameRate: 120, hasUsableVideoTrack: true)

        let firstImport = Task { await viewModel.importVideo { firstSourceURL } }
        await processor.waitForInspectionCount(1)

        let secondImport = Task { await viewModel.importVideo { secondSourceURL } }
        await processor.waitForInspectionCount(2)

        await processor.completeInspection(at: 1, with: .success(secondMetadata))
        await secondImport.value
        #expect(viewModel.metadataState == .available(secondMetadata))

        await processor.completeInspection(at: 0, with: .success(firstMetadata))
        await firstImport.value

        #expect(viewModel.metadataState == .available(secondMetadata))
    }

    private enum TestImportError: Error {
        case failed
    }

    private final class StubVideoProcessor: SwingVideoProcessing {
        let metadata: SwingVideoMetadata
        private let metadataResult: Result<SwingVideoMetadata, Error>
        private let frameResult: Result<SwingExtractedFrame, Error>

        init(
            metadata: SwingVideoMetadata = SwingVideoMetadata(durationSeconds: 10, width: 1920, height: 1080, nominalFrameRate: 30, hasUsableVideoTrack: true),
            metadataResult: Result<SwingVideoMetadata, Error>? = nil,
            frameResult: Result<SwingExtractedFrame, Error>? = nil
        ) {
            self.metadata = metadata
            self.metadataResult = metadataResult ?? .success(metadata)
            self.frameResult = frameResult ?? .success(try! ai_golfTests.makeFrame(requestedTimestampSeconds: 1, actualTimestampSeconds: 1))
        }

        func inspectVideo(at url: URL) async throws -> SwingVideoMetadata {
            try metadataResult.get()
        }

        func extractFrame(at timestampSeconds: Double, from url: URL) async throws -> SwingExtractedFrame {
            try frameResult.get()
        }

    }

    private actor DeferredVideoProcessor: SwingVideoProcessing {
        private var inspectionContinuations: [CheckedContinuation<SwingVideoMetadata, Error>] = []
        private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func inspectVideo(at url: URL) async throws -> SwingVideoMetadata {
            try await withCheckedThrowingContinuation { continuation in
                inspectionContinuations.append(continuation)
                resumeReadyWaiters()
            }
        }

        func extractFrame(at timestampSeconds: Double, from url: URL) async throws -> SwingExtractedFrame {
            try ai_golfTests.makeFrame(requestedTimestampSeconds: timestampSeconds, actualTimestampSeconds: timestampSeconds)
        }

        func waitForInspectionCount(_ expectedCount: Int) async {
            if inspectionContinuations.count >= expectedCount { return }

            await withCheckedContinuation { continuation in
                countWaiters.append((expectedCount, continuation))
            }
        }

        func completeInspection(at index: Int, with result: Result<SwingVideoMetadata, Error>) {
            let continuation = inspectionContinuations[index]
            continuation.resume(with: result)
        }

        private func resumeReadyWaiters() {
            let readyWaiters = countWaiters.filter { inspectionContinuations.count >= $0.0 }
            countWaiters.removeAll { inspectionContinuations.count >= $0.0 }
            readyWaiters.forEach { $0.1.resume() }
        }
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "SwingImportViewModelTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private static func makeVideoFile(named name: String, contents: String = "video") throws -> URL {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let url = directory.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private static func makeFrame(requestedTimestampSeconds: Double, actualTimestampSeconds: Double) throws -> SwingExtractedFrame {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImportError.failed
        }

        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))

        guard let image = context.makeImage() else {
            throw TestImportError.failed
        }

        return SwingExtractedFrame(
            image: image,
            requestedTimestampSeconds: requestedTimestampSeconds,
            actualTimestampSeconds: actualTimestampSeconds
        )
    }
}
