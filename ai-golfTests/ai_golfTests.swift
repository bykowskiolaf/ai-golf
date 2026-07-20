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

    @Test @MainActor func staleImportCannotOverwriteNewerImport() async throws {
        let importDirectory = Self.temporaryDirectory()
        let processor = StubVideoProcessor()
        let viewModel = SwingImportViewModel(importDirectory: importDirectory, videoProcessor: processor)
        let firstSourceURL = try Self.makeVideoFile(named: "first.mov", contents: "first")
        let secondSourceURL = try Self.makeVideoFile(named: "second.mov", contents: "second")
        let firstSource = DeferredSourceURL()
        let secondSource = DeferredSourceURL()

        let firstImport = Task { await viewModel.importVideo { try await firstSource.load() } }
        await firstSource.waitForLoad()

        let secondImport = Task { await viewModel.importVideo { try await secondSource.load() } }
        await secondSource.waitForLoad()

        await secondSource.complete(with: .success(secondSourceURL))
        await secondImport.value

        guard case .ready(let secondSwing) = viewModel.state else {
            Issue.record("Expected second import to be ready")
            return
        }
        #expect(try Data(contentsOf: secondSwing.localVideoURL) == Data("second".utf8))

        await firstSource.complete(with: .success(firstSourceURL))
        await firstImport.value

        guard case .ready(let currentSwing) = viewModel.state else {
            Issue.record("Expected newer import to remain ready")
            return
        }

        #expect(currentSwing.localVideoURL == secondSwing.localVideoURL)
        #expect(FileManager.default.fileExists(atPath: secondSwing.localVideoURL.path()))
        #expect(try Data(contentsOf: currentSwing.localVideoURL) == Data("second".utf8))
    }

    @Test func confidenceFilteringCountsAcceptedAndRejectedJoints() {
        let pose = DetectedPose(
            points: [
                .leftShoulder: PosePoint(joint: .leftShoulder, x: 0.2, y: 0.3, confidence: 0.8),
                .rightShoulder: PosePoint(joint: .rightShoulder, x: 0.8, y: 0.3, confidence: 0.2)
            ],
            minimumConfidence: 0.5
        )

        #expect(pose.acceptedJointCount == 1)
        #expect(pose.rejectedOrUnavailableJointCount == BodyJoint.allCases.count - 1)
        #expect(pose.acceptedPoints.map(\.joint) == [.leftShoulder])
    }

    @Test func skeletonConnectionsRequireBothEndpointsAboveThreshold() {
        let pose = DetectedPose(
            points: [
                .leftShoulder: PosePoint(joint: .leftShoulder, x: 0.2, y: 0.3, confidence: 0.8),
                .leftElbow: PosePoint(joint: .leftElbow, x: 0.3, y: 0.5, confidence: 0.7),
                .leftWrist: PosePoint(joint: .leftWrist, x: 0.4, y: 0.7, confidence: 0.1)
            ],
            minimumConfidence: 0.5
        )

        let visibleConnections = SwingPoseSkeleton.visibleConnections(for: pose)

        #expect(visibleConnections.contains(SkeletonConnection(start: .leftShoulder, end: .leftElbow)))
        #expect(!visibleConnections.contains(SkeletonConnection(start: .leftElbow, end: .leftWrist)))
    }

    @Test func visionCoordinatesConvertToTopLeftAppCoordinates() {
        #expect(PoseCoordinateSystem.appY(fromVisionY: 0) == 1)
        #expect(PoseCoordinateSystem.appY(fromVisionY: 0.25) == 0.75)
        #expect(PoseCoordinateSystem.appY(fromVisionY: 1) == 0)
    }

    @Test func aspectFitTransformHandlesHorizontalLetterboxing() {
        let transform = PoseOverlayTransform(imageSize: CGSize(width: 100, height: 100), viewSize: CGSize(width: 200, height: 100))
        let point = PosePoint(joint: .nose, x: 0.5, y: 0.5, confidence: 1)

        #expect(transform.fittedImageRect == CGRect(x: 50, y: 0, width: 100, height: 100))
        #expect(transform.viewPoint(for: point) == CGPoint(x: 100, y: 50))
    }

    @Test func aspectFitTransformHandlesVerticalLetterboxing() {
        let transform = PoseOverlayTransform(imageSize: CGSize(width: 100, height: 100), viewSize: CGSize(width: 100, height: 200))
        let point = PosePoint(joint: .nose, x: 0.5, y: 0.5, confidence: 1)

        #expect(transform.fittedImageRect == CGRect(x: 0, y: 50, width: 100, height: 100))
        #expect(transform.viewPoint(for: point) == CGPoint(x: 50, y: 100))
    }

    @Test @MainActor func successfulPoseAnalysisTransitionsToDetected() async throws {
        let pose = Self.makePose()
        let viewModel = SwingImportViewModel(
            importDirectory: Self.temporaryDirectory(),
            videoProcessor: StubVideoProcessor(),
            poseEstimator: StubPoseEstimator(result: .success(pose))
        )
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }
        await viewModel.extractFrame()
        await viewModel.analyzePose()

        #expect(viewModel.poseAnalysisState == .detected(pose))
    }

    @Test @MainActor func noPoseAnalysisTransitionsToNoPoseDetected() async throws {
        let viewModel = SwingImportViewModel(
            importDirectory: Self.temporaryDirectory(),
            videoProcessor: StubVideoProcessor(),
            poseEstimator: StubPoseEstimator(result: .success(nil))
        )
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }
        await viewModel.extractFrame()
        await viewModel.analyzePose()

        #expect(viewModel.poseAnalysisState == .noPoseDetected)
    }

    @Test @MainActor func poseFailureDoesNotRemoveImportedVideoOrExtractedFrame() async throws {
        let viewModel = SwingImportViewModel(
            importDirectory: Self.temporaryDirectory(),
            videoProcessor: StubVideoProcessor(),
            poseEstimator: StubPoseEstimator(result: .failure(TestImportError.failed))
        )
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }
        await viewModel.extractFrame()
        await viewModel.analyzePose()

        guard case .ready(let swing) = viewModel.state else {
            Issue.record("Expected imported video to remain available")
            return
        }
        guard case .extracted = viewModel.frameExtractionState else {
            Issue.record("Expected extracted frame to remain available")
            return
        }

        #expect(FileManager.default.fileExists(atPath: swing.localVideoURL.path()))
        #expect(viewModel.poseAnalysisState == .failed(message: "Pose analysis failed. Try another frame."))
    }

    @Test @MainActor func stalePoseResultCannotOverwriteNewerExtractedFrame() async throws {
        let poseEstimator = DeferredPoseEstimator()
        let viewModel = SwingImportViewModel(
            importDirectory: Self.temporaryDirectory(),
            videoProcessor: StubVideoProcessor(),
            poseEstimator: poseEstimator
        )
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }
        await viewModel.extractFrame()
        let analysis = Task { await viewModel.analyzePose() }
        await poseEstimator.waitForAnalysisCount(1)

        await viewModel.extractFrame()
        #expect(viewModel.poseAnalysisState == .ready)

        await poseEstimator.completeAnalysis(at: 0, with: .success(Self.makePose()))
        await analysis.value

        #expect(viewModel.poseAnalysisState == .ready)
    }

    @Test @MainActor func extractingOrImportingNewMediaClearsOldPose() async throws {
        let viewModel = SwingImportViewModel(
            importDirectory: Self.temporaryDirectory(),
            videoProcessor: StubVideoProcessor(),
            poseEstimator: StubPoseEstimator(result: .success(Self.makePose()))
        )
        let firstSourceURL = try Self.makeVideoFile(named: "first.mov", contents: "first")
        let secondSourceURL = try Self.makeVideoFile(named: "second.mov", contents: "second")

        await viewModel.importVideo { firstSourceURL }
        await viewModel.extractFrame()
        await viewModel.analyzePose()
        guard case .detected = viewModel.poseAnalysisState else {
            Issue.record("Expected pose result before clearing")
            return
        }

        await viewModel.extractFrame()
        #expect(viewModel.poseAnalysisState == .ready)

        await viewModel.analyzePose()
        await viewModel.importVideo { secondSourceURL }
        #expect(viewModel.poseAnalysisState == .noExtractedFrame)
    }

    @Test func samplingTimestampGenerationIncludesBounds() throws {
        let plan = try PoseTrackSampler.makePlan(PoseTrackSamplingRequest(startTime: 1, endTime: 2, samplesPerSecond: 2, durationSeconds: 5, maximumSamples: 150))

        #expect(plan.timestamps == [1, 1.5, 2])
        #expect(plan.effectiveSamplesPerSecond == 2)
        #expect(!plan.wasReducedToMaximum)
    }

    @Test func maximumSampleEnforcementReducesEffectiveRate() throws {
        let plan = try PoseTrackSampler.makePlan(PoseTrackSamplingRequest(startTime: 0, endTime: 20, samplesPerSecond: 10, durationSeconds: 20, maximumSamples: 150))

        #expect(plan.timestamps.count == 150)
        #expect(plan.wasReducedToMaximum)
        #expect(plan.effectiveSamplesPerSecond < 10)
    }

    @Test func nonIntegralIntervalDoesNotExceedRequestedSamplingRate() throws {
        let plan = try PoseTrackSampler.makePlan(PoseTrackSamplingRequest(startTime: 0, endTime: 1.01, samplesPerSecond: 10, durationSeconds: 2, maximumSamples: 150))

        #expect(plan.timestamps.count == 11)
        #expect(plan.effectiveSamplesPerSecond <= 10)
    }

    @Test func invalidIntervalIsRejected() {
        #expect(throws: PoseTrackSamplingError.invalidInterval) {
            try PoseTrackSampler.makePlan(PoseTrackSamplingRequest(startTime: 5, endTime: 5, samplesPerSecond: 10, durationSeconds: 10, maximumSamples: 150))
        }
    }

    @Test func poseQualityClassificationAndMissingJoints() {
        let complete = PoseSampleQualityEvaluator.evaluate(pose: Self.makeCompletePose())
        let partial = PoseSampleQualityEvaluator.evaluate(pose: Self.makePose())
        let noPose = PoseSampleQualityEvaluator.evaluate(pose: nil)

        #expect(complete.category == .complete)
        #expect(partial.category == .partial)
        #expect(noPose.category == .noPose)
        #expect(partial.missingJoints.contains(.leftElbow))
        #expect(partial.hasSufficientTorso)
        #expect(!partial.hasSufficientBothArms)
    }

    @Test func progressCalculation() {
        let progress = PoseTrackProgress(processedSamples: 3, totalSamples: 10)

        #expect(progress.fractionCompleted == 0.3)
    }

    @Test func swingPoseTrackSummaryStatisticsAreConsistent() {
        let track = SwingPoseTrack(samples: [
            PoseSample(id: UUID(), requestedTime: 0, actualTime: 0, pose: Self.makeCompletePose(), quality: PoseSampleQualityEvaluator.evaluate(pose: Self.makeCompletePose())),
            PoseSample(id: UUID(), requestedTime: 1, actualTime: 1, pose: Self.makePose(), quality: PoseSampleQualityEvaluator.evaluate(pose: Self.makePose())),
            PoseSample(id: UUID(), requestedTime: 2, actualTime: 2, pose: nil, quality: PoseSampleQualityEvaluator.evaluate(pose: nil))
        ], processingDurationSeconds: 0.9)

        let summary = track.summary

        #expect(summary.totalSamples == 3)
        #expect(summary.samplesWithPose == 2)
        #expect(summary.samplesWithoutPose == 1)
        #expect(summary.completeSamples == 1)
        #expect(summary.partialSamples == 1)
        #expect(summary.averageProcessingTimePerSample == 0.3)
    }

    @Test @MainActor func mixedSuccessfulAndNoPoseSamplesProduceCompletedTrack() async throws {
        let track = Self.makeTrack(samples: [Self.makeSample(time: 0, pose: Self.makePose()), Self.makeSample(time: 1, pose: nil)])
        let analyzer = StubPoseTrackAnalyzer(result: .success(track))
        let viewModel = Self.makeSequenceViewModel(analyzer: analyzer)
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }
        viewModel.startPoseTrackAnalysis()
        await analyzer.waitForAnalysis()
        await analyzer.complete()
        await Task.yield()

        #expect(viewModel.poseTrackAnalysisState == .completed(track))
    }

    @Test @MainActor func cancellationKeepsImportedVideoIntact() async throws {
        let analyzer = StubPoseTrackAnalyzer(result: .success(Self.makeTrack(samples: [])))
        let viewModel = Self.makeSequenceViewModel(analyzer: analyzer)
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }
        viewModel.startPoseTrackAnalysis()
        await analyzer.waitForAnalysis()
        viewModel.cancelPoseTrackAnalysis()

        guard case .ready(let swing) = viewModel.state else {
            Issue.record("Expected imported video to remain")
            return
        }
        #expect(FileManager.default.fileExists(atPath: swing.localVideoURL.path()))
        #expect(viewModel.poseTrackAnalysisState == .cancelled)
    }

    @Test @MainActor func stalePoseTrackResultCannotOverwriteNewerResult() async throws {
        let analyzer = QueuePoseTrackAnalyzer()
        let viewModel = Self.makeSequenceViewModel(analyzer: analyzer)
        let sourceURL = try Self.makeVideoFile(named: "source.mov")
        let oldTrack = Self.makeTrack(samples: [Self.makeSample(time: 0, pose: nil)])
        let newTrack = Self.makeTrack(samples: [Self.makeSample(time: 1, pose: Self.makePose())])

        await viewModel.importVideo { sourceURL }
        viewModel.startPoseTrackAnalysis()
        await analyzer.waitForAnalysisCount(1)
        viewModel.startPoseTrackAnalysis()
        await analyzer.waitForAnalysisCount(2)

        await analyzer.completeAnalysis(at: 1, with: .success(newTrack))
        await analyzer.completeAnalysis(at: 0, with: .success(oldTrack))
        await Task.yield()

        #expect(viewModel.poseTrackAnalysisState == .completed(newTrack))
    }

    @Test @MainActor func videoReplacementClearsPoseTrack() async throws {
        let track = Self.makeTrack(samples: [Self.makeSample(time: 0, pose: Self.makePose())])
        let analyzer = StubPoseTrackAnalyzer(result: .success(track))
        let viewModel = Self.makeSequenceViewModel(analyzer: analyzer)
        let firstSourceURL = try Self.makeVideoFile(named: "first.mov", contents: "first")
        let secondSourceURL = try Self.makeVideoFile(named: "second.mov", contents: "second")

        await viewModel.importVideo { firstSourceURL }
        viewModel.startPoseTrackAnalysis()
        await analyzer.waitForAnalysis()
        await analyzer.complete()
        await Task.yield()
        #expect(viewModel.poseTrackAnalysisState == .completed(track))

        await viewModel.importVideo { secondSourceURL }

        #expect(viewModel.poseTrackAnalysisState == .idle)
    }

    @Test @MainActor func selectedSampleLoadsReviewFrame() async throws {
        let sample = PoseSample(
            id: UUID(),
            requestedTime: 2,
            actualTime: 2.05,
            pose: Self.makePose(),
            quality: PoseSampleQualityEvaluator.evaluate(pose: Self.makePose())
        )
        let viewModel = Self.makeSequenceViewModel(analyzer: StubPoseTrackAnalyzer(result: .success(Self.makeTrack(samples: [sample]))))
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }
        await viewModel.selectPoseSample(sample)

        guard case .loaded(let loadedSample, let frame) = viewModel.selectedPoseSampleFrameState else {
            Issue.record("Expected selected sample frame")
            return
        }

        #expect(loadedSample == sample)
        #expect(frame.requestedTimestampSeconds == 2.05)
    }

    private enum TestImportError: Error {
        case failed
    }

    private final class StubVideoProcessor: SwingVideoProcessing {
        let metadata: SwingVideoMetadata
        private let metadataResult: Result<SwingVideoMetadata, Error>
        private let frameResult: Result<SwingExtractedFrame, Error>?

        init(
            metadata: SwingVideoMetadata = SwingVideoMetadata(durationSeconds: 10, width: 1920, height: 1080, nominalFrameRate: 30, hasUsableVideoTrack: true),
            metadataResult: Result<SwingVideoMetadata, Error>? = nil,
            frameResult: Result<SwingExtractedFrame, Error>? = nil
        ) {
            self.metadata = metadata
            self.metadataResult = metadataResult ?? .success(metadata)
            self.frameResult = frameResult
        }

        func inspectVideo(at url: URL) async throws -> SwingVideoMetadata {
            try metadataResult.get()
        }

        func extractFrame(at timestampSeconds: Double, from url: URL) async throws -> SwingExtractedFrame {
            if let frameResult {
                return try frameResult.get()
            }
            return try ai_golfTests.makeFrame(requestedTimestampSeconds: timestampSeconds, actualTimestampSeconds: timestampSeconds)
        }

    }

    private final class StubPoseEstimator: PoseEstimating {
        private let result: Result<DetectedPose?, Error>

        init(result: Result<DetectedPose?, Error>) {
            self.result = result
        }

        func detectPose(in image: CGImage, minimumConfidence: Double) async throws -> DetectedPose? {
            try result.get()
        }
    }

    private final class StubPoseTrackAnalyzer: SwingPoseTrackAnalyzing, @unchecked Sendable {
        private let result: Result<SwingPoseTrack, Error>
        private var continuation: CheckedContinuation<Void, Never>?

        init(result: Result<SwingPoseTrack, Error>) {
            self.result = result
        }

        func analyze(videoURL: URL, timestamps: [Double], minimumConfidence: Double, progress: @MainActor @escaping (PoseTrackProgress) -> Void) async throws -> SwingPoseTrack {
            progress(PoseTrackProgress(processedSamples: 0, totalSamples: timestamps.count))
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
            return try result.get()
        }

        func waitForAnalysis() async {
            while continuation == nil {
                await Task.yield()
            }
        }

        func complete() async {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor QueuePoseTrackAnalyzer: SwingPoseTrackAnalyzing {
        private var continuations: [CheckedContinuation<SwingPoseTrack, Error>] = []
        private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func analyze(videoURL: URL, timestamps: [Double], minimumConfidence: Double, progress: @MainActor @escaping (PoseTrackProgress) -> Void) async throws -> SwingPoseTrack {
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
                resumeReadyWaiters()
            }
        }

        func waitForAnalysisCount(_ expectedCount: Int) async {
            if continuations.count >= expectedCount { return }
            await withCheckedContinuation { continuation in
                countWaiters.append((expectedCount, continuation))
            }
        }

        func completeAnalysis(at index: Int, with result: Result<SwingPoseTrack, Error>) {
            continuations[index].resume(with: result)
        }

        private func resumeReadyWaiters() {
            let readyWaiters = countWaiters.filter { continuations.count >= $0.0 }
            countWaiters.removeAll { continuations.count >= $0.0 }
            readyWaiters.forEach { $0.1.resume() }
        }
    }

    private actor DeferredPoseEstimator: PoseEstimating {
        private var analysisContinuations: [CheckedContinuation<DetectedPose?, Error>] = []
        private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func detectPose(in image: CGImage, minimumConfidence: Double) async throws -> DetectedPose? {
            try await withCheckedThrowingContinuation { continuation in
                analysisContinuations.append(continuation)
                resumeReadyWaiters()
            }
        }

        func waitForAnalysisCount(_ expectedCount: Int) async {
            if analysisContinuations.count >= expectedCount { return }

            await withCheckedContinuation { continuation in
                countWaiters.append((expectedCount, continuation))
            }
        }

        func completeAnalysis(at index: Int, with result: Result<DetectedPose?, Error>) {
            let continuation = analysisContinuations[index]
            continuation.resume(with: result)
        }

        private func resumeReadyWaiters() {
            let readyWaiters = countWaiters.filter { analysisContinuations.count >= $0.0 }
            countWaiters.removeAll { analysisContinuations.count >= $0.0 }
            readyWaiters.forEach { $0.1.resume() }
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

    private actor DeferredSourceURL {
        private var continuation: CheckedContinuation<URL, Error>?
        private var loadWaiter: CheckedContinuation<Void, Never>?

        func load() async throws -> URL {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                loadWaiter?.resume()
                loadWaiter = nil
            }
        }

        func waitForLoad() async {
            if continuation != nil { return }

            await withCheckedContinuation { continuation in
                loadWaiter = continuation
            }
        }

        func complete(with result: Result<URL, Error>) {
            continuation?.resume(with: result)
            continuation = nil
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

    private static func makePose(minimumConfidence: Double = 0.3) -> DetectedPose {
        DetectedPose(
            points: [
                .leftShoulder: PosePoint(joint: .leftShoulder, x: 0.3, y: 0.3, confidence: 0.8),
                .rightShoulder: PosePoint(joint: .rightShoulder, x: 0.7, y: 0.3, confidence: 0.8),
                .neck: PosePoint(joint: .neck, x: 0.5, y: 0.25, confidence: 0.8),
                .root: PosePoint(joint: .root, x: 0.5, y: 0.6, confidence: 0.8),
                .leftHip: PosePoint(joint: .leftHip, x: 0.35, y: 0.65, confidence: 0.7),
                .rightHip: PosePoint(joint: .rightHip, x: 0.65, y: 0.65, confidence: 0.7)
            ],
            minimumConfidence: minimumConfidence
        )
    }

    private static func makeCompletePose(minimumConfidence: Double = 0.3) -> DetectedPose {
        DetectedPose(
            points: Dictionary(uniqueKeysWithValues: BodyJoint.allCases.map { joint in
                (joint, PosePoint(joint: joint, x: 0.5, y: 0.5, confidence: 0.9))
            }),
            minimumConfidence: minimumConfidence
        )
    }

    private static func makeSample(time: Double, pose: DetectedPose?) -> PoseSample {
        PoseSample(
            id: UUID(),
            requestedTime: time,
            actualTime: time,
            pose: pose,
            quality: PoseSampleQualityEvaluator.evaluate(pose: pose)
        )
    }

    private static func makeTrack(samples: [PoseSample]) -> SwingPoseTrack {
        SwingPoseTrack(samples: samples, processingDurationSeconds: 1)
    }

    @MainActor private static func makeSequenceViewModel(analyzer: SwingPoseTrackAnalyzing) -> SwingImportViewModel {
        SwingImportViewModel(
            importDirectory: temporaryDirectory(),
            videoProcessor: StubVideoProcessor(metadata: SwingVideoMetadata(durationSeconds: 10, width: 1920, height: 1080, nominalFrameRate: 30, hasUsableVideoTrack: true)),
            poseEstimator: StubPoseEstimator(result: .success(makePose())),
            poseTrackAnalyzer: analyzer
        )
    }
}
