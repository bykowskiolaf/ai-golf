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

private extension SwingImportViewModel {
    var readyAnnotationExport: SwingAnnotationDatasetExport? {
        if case .readyToShare(let export) = annotationExportState {
            return export
        }
        return nil
    }
}

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
        await Self.waitForPoseTrackCompletion(viewModel)

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

    @Test @MainActor func rapidSampleSelectionOnlyDisplaysLatestFrame() async throws {
        let firstSample = Self.makeSample(time: 1, pose: Self.makePose())
        let secondSample = Self.makeSample(time: 2, pose: Self.makePose())
        let processor = DeferredFrameVideoProcessor()
        let viewModel = SwingImportViewModel(
            importDirectory: Self.temporaryDirectory(),
            videoProcessor: processor,
            poseEstimator: StubPoseEstimator(result: .success(Self.makePose())),
            poseTrackAnalyzer: StubPoseTrackAnalyzer(result: .success(Self.makeTrack(samples: [firstSample, secondSample])))
        )
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }
        viewModel.requestPoseSampleSelection(firstSample)
        await Task.yield()
        await processor.waitForFrameExtractionCount(1)
        viewModel.requestPoseSampleSelection(secondSample)
        await Task.yield()
        await processor.waitForFrameExtractionCount(2)

        await processor.completeFrameExtraction(at: 1)
        await Task.yield()
        await processor.completeFrameExtraction(at: 0)
        await Task.yield()

        guard case .loaded(let sample, let frame) = viewModel.selectedPoseSampleFrameState else {
            Issue.record("Expected latest selected sample frame")
            return
        }

        #expect(sample == secondSample)
        #expect(frame.requestedTimestampSeconds == 2)
    }

    @Test @MainActor func defaultAnnotationStateIsEmpty() {
        let viewModel = SwingImportViewModel(importDirectory: Self.temporaryDirectory())

        #expect(viewModel.annotations.isEmpty)
        #expect(!viewModel.annotationValidation.canExport)
        #expect(SwingAnnotationRecord.schemaVersion == 2)
    }

    @Test @MainActor func assigningReplacingAndClearingAnnotationLabels() async throws {
        let samples = [0.5, 1.5, 2.5, 3.5].map { Self.makeSample(time: $0, pose: Self.makeFullAnnotationPose()) }
        let track = Self.makeTrack(samples: samples)
        let viewModel = try await Self.makeCompletedAnnotationViewModel(track: track)

        for (index, position) in SwingPosition.allCases.enumerated() {
            viewModel.markSelectedSample(as: position, in: track)
            if index + 1 < samples.count {
                await viewModel.selectPoseSample(at: index + 1, in: track)
            }
        }

        #expect(viewModel.annotations.count == 4)
        #expect(viewModel.annotation(for: .address)?.actualTimestamp == 0.5)

        await viewModel.selectPoseSample(at: 1, in: track)
        viewModel.markSelectedSample(as: .address, in: track)
        #expect(viewModel.annotation(for: .address)?.actualTimestamp == 1.5)

        viewModel.clearAnnotation(.address)
        #expect(viewModel.annotation(for: .address) == nil)
    }

    @Test @MainActor func jumpingToLabeledSampleLoadsItsFrame() async throws {
        let samples = [0.5, 1.5].map { Self.makeSample(time: $0, pose: Self.makeFullAnnotationPose()) }
        let track = Self.makeTrack(samples: samples)
        let viewModel = try await Self.makeCompletedAnnotationViewModel(track: track)

        await viewModel.selectPoseSample(at: 1, in: track)
        viewModel.markSelectedSample(as: .top, in: track)
        await viewModel.selectPoseSample(at: 0, in: track)
        viewModel.jumpToAnnotation(.top, in: track)
        await Task.yield()

        #expect(viewModel.selectedPoseSampleID == samples[1].id)
    }

    @Test @MainActor func chronologicalValidationAcceptsStrictOrderAndRejectsInvalidPairs() {
        let valid = Self.makeAnnotationMap(times: [.address: 1, .top: 2, .impact: 3, .finish: 4])
        #expect(SwingAnnotationBuilder.validate(annotations: valid).canExport)

        let invalidAddressTop = Self.makeAnnotationMap(times: [.address: 2, .top: 2, .impact: 3, .finish: 4])
        #expect(!SwingAnnotationBuilder.validate(annotations: invalidAddressTop).canExport)

        let invalidTopImpact = Self.makeAnnotationMap(times: [.address: 1, .top: 4, .impact: 3, .finish: 5])
        #expect(!SwingAnnotationBuilder.validate(annotations: invalidTopImpact).canExport)

        let invalidImpactFinish = Self.makeAnnotationMap(times: [.address: 1, .top: 2, .impact: 5, .finish: 4])
        #expect(!SwingAnnotationBuilder.validate(annotations: invalidImpactFinish).canExport)
    }

    @Test @MainActor func readinessClassificationsAndMissingWrists() {
        let ready = Self.cleanedSample(joints: [.neck, .root, .leftShoulder, .rightShoulder, .leftHip, .rightHip, .leftElbow, .leftWrist])
        #expect(SwingAnnotationBuilder.readiness(for: ready) == .poseReady)

        let partial = Self.cleanedSample(joints: [.neck, .root, .leftShoulder, .rightShoulder, .leftHip, .rightHip, .leftElbow])
        #expect(SwingAnnotationBuilder.readiness(for: partial) == .posePartial)
        #expect(SwingAnnotationBuilder.availability(for: partial).bothWrists == false)

        let visualOnly = Self.cleanedSample(joints: [.leftShoulder, .rightShoulder, .leftElbow])
        #expect(SwingAnnotationBuilder.readiness(for: visualOnly) == .visualOnly)
    }

    @Test @MainActor func incompleteAnnotationCannotExport() {
        let annotations = Self.makeAnnotationMap(times: [.address: 1, .top: 2])

        #expect(throws: SwingAnnotationExportError.self) {
            _ = try Self.makeAnnotationRecord(annotations: annotations)
        }
    }

    @Test @MainActor func jsonEncodingPreservesSchemaCoordinatesAndProvenance() throws {
        let annotations = Self.makeAnnotationMap(times: [.address: 1, .top: 2, .impact: 3, .finish: 4], includeInterpolatedWrist: true)
        let record = try Self.makeAnnotationRecord(
            context: SwingAnnotationContext(golferHandedness: .leftHanded, cameraView: .downTheLine, golfClub: .midIron),
            annotations: annotations
        )
        let data = try JSONEncoder.swingAnnotationEncoder().encode(record)
        let decoded = try JSONDecoder.swingAnnotationDecoder().decode(SwingAnnotationRecord.self, from: data)

        #expect(decoded.schemaVersion == 2)
        #expect(decoded.coordinateSystem == .normalizedTopLeft)
        #expect(decoded.context.golferHandedness == .leftHanded)
        #expect(decoded.positions.count == 4)
        let address = try #require(decoded.positions.first { $0.position == "address" })
        let wrist = try #require(address.cleanedJoints.first { $0.joint == BodyJoint.leftWrist.rawValue })
        #expect(wrist.x == 0.2)
        #expect(wrist.source == "interpolated")
    }

    @Test @MainActor func schemaVersionOnlyOccursAtRoot() throws {
        let record = try Self.makeAnnotationRecord()
        let data = try JSONEncoder.swingAnnotationEncoder().encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let context = try #require(object["context"] as? [String: Any])

        #expect(object["schemaVersion"] as? Int == 2)
        #expect(context["schemaVersion"] == nil)
    }

    @Test @MainActor func annotationIDLifecycleAcrossReexportAndInvalidation() async throws {
        let samples = [0.5, 1.5, 2.5, 3.5].map { Self.makeSample(time: $0, pose: Self.makeFullAnnotationPose()) }
        let track = Self.makeTrack(samples: samples)
        let viewModel = try await Self.makeCompletedAnnotationViewModel(track: track)
        let originalID = viewModel.annotationIdentity.annotationID

        for (index, position) in SwingPosition.allCases.enumerated() {
            await viewModel.selectPoseSample(at: index, in: track)
            viewModel.markSelectedSample(as: position, in: track)
        }

        let labeledID = viewModel.annotationIdentity.annotationID
        viewModel.updateAnnotationNote("Impact appears between samples", for: .impact)
        viewModel.annotationContext.golferIdentifier = "Golfer A"

        #expect(labeledID == originalID)
        #expect(viewModel.annotationIdentity.annotationID == labeledID)

        viewModel.setSequenceSamplesPerSecond(12)
        #expect(viewModel.annotationIdentity.annotationID != labeledID)
    }

    @Test @MainActor func schemaV2EncodesISODateAnnotatorCoordinateAndConfiguration() throws {
        let createdAt = ISO8601DateFormatter().date(from: "2026-07-21T10:30:00Z")!
        var context = SwingAnnotationContext(golferHandedness: .rightHanded, cameraView: .downTheLine, golfClub: .hybrid)
        context.annotatorIdentifier = "Coach 1"
        context.annotatorRole = .coach
        let configuration = ExportedAnalysisConfiguration(
            intervalStartSeconds: 0,
            intervalEndSeconds: 2,
            requestedSamplingRate: 30,
            analyzedSampleCount: 60,
            confidenceThreshold: 0.3
        )
        let record = try Self.makeAnnotationRecord(
            identity: SwingAnnotationIdentity(annotationID: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!, createdAt: createdAt),
            sourceVideoFilename: "swing-550E8400-E29B-41D4-A716-446655440000.mov",
            context: context,
            analysisConfiguration: configuration
        )
        let data = try JSONEncoder.swingAnnotationEncoder().encode(record)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains("\"createdAt\" : \"2026-07-21T10:30:00Z\""))
        #expect(json.contains("\"annotatorRole\" : \"coach\""))
        #expect(json.contains("\"annotatorIdentifier\" : \"Coach 1\""))
        #expect(json.contains("\"coordinateSystem\" : \"normalizedTopLeft\""))
        #expect(record.analysisConfiguration.effectiveSamplingRate == 30)
        #expect(record.analysisConfiguration.maximumInterpolationGapSamples == 2)
        #expect(record.analysisConfiguration.smoothingWindowSize == 3)
        #expect(record.analysisConfiguration.smoothingCenterWeight == 0.5)
    }

    @Test @MainActor func optionalAnnotatorIdentifierMayBeOmitted() throws {
        var context = SwingAnnotationContext()
        context.annotatorIdentifier = nil
        context.annotatorRole = .unknown
        let record = try Self.makeAnnotationRecord(context: context)
        let data = try JSONEncoder.swingAnnotationEncoder().encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decodedContext = try #require(object["context"] as? [String: Any])

        #expect(decodedContext["annotatorRole"] as? String == "unknown")
        #expect(decodedContext["annotatorIdentifier"] == nil)
    }

    @Test @MainActor func effectiveSamplingRateProtectsZeroDuration() {
        let configuration = ExportedAnalysisConfiguration(
            intervalStartSeconds: 2,
            intervalEndSeconds: 2,
            requestedSamplingRate: 30,
            analyzedSampleCount: 10,
            confidenceThreshold: 0.3
        )

        #expect(configuration.effectiveSamplingRate == 0)
    }

    @Test @MainActor func positionNoteRoundTripsAndWhitespaceNormalizes() throws {
        var annotations = Self.makeAnnotationMap(times: [.address: 1, .top: 2, .impact: 3, .finish: 4])
        annotations[.impact]?.note = " Impact appears between two analyzed samples. "
        annotations[.finish]?.note = "   "
        let record = try Self.makeAnnotationRecord(annotations: annotations)
        let data = try JSONEncoder.swingAnnotationEncoder().encode(record)
        let decoded = try JSONDecoder.swingAnnotationDecoder().decode(SwingAnnotationRecord.self, from: data)

        #expect(decoded.positions.first { $0.position == "impact" }?.note == "Impact appears between two analyzed samples.")
        #expect(decoded.positions.first { $0.position == "finish" }?.note == nil)
    }

    @Test @MainActor func unsupportedFutureSchemaFailsClearly() throws {
        let json = """
        { "schemaVersion": 99, "positions": [] }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.swingAnnotationDecoder().decode(SwingAnnotationRecord.self, from: json)
        }
    }

    @Test @MainActor func matchedFilenamesPreserveVideoExtensionAndSourceFilename() throws {
        let annotationID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
        let exporter = SwingAnnotationDatasetExporter(stagingRoot: Self.temporaryDirectory())
        let videoFilename = exporter.sourceVideoFilename(annotationID: annotationID, sourceVideoURL: URL(filePath: "/tmp/internal-source.MP4"))
        let record = try Self.makeAnnotationRecord(
            identity: SwingAnnotationIdentity(annotationID: annotationID, createdAt: Date(timeIntervalSince1970: 0)),
            sourceVideoFilename: videoFilename
        )

        #expect(videoFilename == "swing-550E8400-E29B-41D4-A716-446655440000.mp4")
        #expect(record.sourceVideoFilename == videoFilename)
    }

    @Test @MainActor func reexportKeepsAnnotationIDAndMatchedBaseName() async throws {
        let samples = [0.5, 1.5, 2.5, 3.5].map { Self.makeSample(time: $0, pose: Self.makeFullAnnotationPose()) }
        let track = Self.makeTrack(samples: samples)
        let viewModel = try await Self.makeCompletedAnnotationViewModel(track: track)
        await Self.markAllPositions(in: viewModel, track: track)
        let annotationID = viewModel.annotationIdentity.annotationID

        await viewModel.exportAnnotation()
        let firstExport = try #require(viewModel.readyAnnotationExport)
        viewModel.dismissAnnotationExport()
        await viewModel.exportAnnotation()
        let secondExport = try #require(viewModel.readyAnnotationExport)

        #expect(viewModel.annotationIdentity.annotationID == annotationID)
        #expect(firstExport.videoURL.lastPathComponent == "swing-\(annotationID.uuidString).mov")
        #expect(secondExport.annotationURL.lastPathComponent == "swing-\(annotationID.uuidString).json")
    }

    @Test @MainActor func replacingSourceVideoCreatesNewAnnotationID() async throws {
        let samples = [0.5, 1.5, 2.5, 3.5].map { Self.makeSample(time: $0, pose: Self.makeFullAnnotationPose()) }
        let track = Self.makeTrack(samples: samples)
        let viewModel = try await Self.makeCompletedAnnotationViewModel(track: track)
        let originalID = viewModel.annotationIdentity.annotationID

        let replacementURL = try Self.makeVideoFile(named: "replacement.mp4")
        await viewModel.importVideo { replacementURL }

        #expect(viewModel.annotationIdentity.annotationID != originalID)
    }

    @Test @MainActor func datasetExportCopiesVideoBytesAndWritesMatchedJSON() throws {
        let stagingRoot = Self.temporaryDirectory()
        let sourceVideoURL = try Self.makeVideoFile(named: "source.mov", bytes: [0, 1, 2, 3, 255])
        let exporter = SwingAnnotationDatasetExporter(stagingRoot: stagingRoot)
        let videoFilename = exporter.sourceVideoFilename(annotationID: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!, sourceVideoURL: sourceVideoURL)
        let record = try Self.makeAnnotationRecord(sourceVideoFilename: videoFilename)
        let export = try exporter.export(record: record, sourceVideoURL: sourceVideoURL)
        let copiedBytes = try Data(contentsOf: export.videoURL)
        let decoded = try JSONDecoder.swingAnnotationDecoder().decode(SwingAnnotationRecord.self, from: Data(contentsOf: export.annotationURL))

        #expect(copiedBytes == Data([0, 1, 2, 3, 255]))
        #expect(export.videoURL.deletingPathExtension().lastPathComponent == export.annotationURL.deletingPathExtension().lastPathComponent)
        #expect(decoded.sourceVideoFilename == export.videoURL.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: sourceVideoURL.path))
    }

    @Test @MainActor func datasetExportReportsVideoCopyAndJSONWriteFailures() throws {
        let sourceVideoURL = try Self.makeVideoFile(named: "source.mov")
        let record = try Self.makeAnnotationRecord()
        let copyFailingExporter = SwingAnnotationDatasetExporter(
            stagingRoot: Self.temporaryDirectory(),
            copyItem: { _, _ in throw CocoaError(.fileNoSuchFile) }
        )
        let writeFailingExporter = SwingAnnotationDatasetExporter(
            stagingRoot: Self.temporaryDirectory(),
            writeData: { _, _ in throw CocoaError(.fileWriteUnknown) }
        )

        #expect(throws: SwingAnnotationDatasetExporter.ExportError.videoCopyFailed) {
            _ = try copyFailingExporter.export(record: record, sourceVideoURL: sourceVideoURL)
        }
        #expect(throws: SwingAnnotationDatasetExporter.ExportError.jsonWriteFailed) {
            _ = try writeFailingExporter.export(record: record, sourceVideoURL: sourceVideoURL)
        }
    }

    @Test @MainActor func failedExportDoesNotClearAnnotations() async throws {
        let samples = [0.5, 1.5, 2.5, 3.5].map { Self.makeSample(time: $0, pose: Self.makeFullAnnotationPose()) }
        let track = Self.makeTrack(samples: samples)
        let failingExporter = SwingAnnotationDatasetExporter(
            stagingRoot: Self.temporaryDirectory(),
            writeData: { _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        let viewModel = try await Self.makeCompletedAnnotationViewModel(track: track, datasetExporter: failingExporter)
        await Self.markAllPositions(in: viewModel, track: track)

        await viewModel.exportAnnotation()

        #expect(viewModel.annotations.count == 4)
        if case .failed = viewModel.annotationExportState {
            #expect(true)
        } else {
            Issue.record("Expected failed export state")
        }
    }

    @Test @MainActor func staleExportCannotPresentFilesForReplacedVideo() async throws {
        let samples = [0.5, 1.5, 2.5, 3.5].map { Self.makeSample(time: $0, pose: Self.makeFullAnnotationPose()) }
        let track = Self.makeTrack(samples: samples)
        let copyStarted = DispatchSemaphore(value: 0)
        let allowCopy = DispatchSemaphore(value: 0)
        let blockingExporter = SwingAnnotationDatasetExporter(
            stagingRoot: Self.temporaryDirectory(),
            copyItem: { source, destination in
                copyStarted.signal()
                allowCopy.wait()
                try FileManager.default.copyItem(at: source, to: destination)
            }
        )
        let viewModel = try await Self.makeCompletedAnnotationViewModel(track: track, datasetExporter: blockingExporter)
        await Self.markAllPositions(in: viewModel, track: track)

        let exportTask = Task { await viewModel.exportAnnotation() }
        _ = copyStarted.wait(timeout: .now() + 2)
        let replacementURL = try Self.makeVideoFile(named: "replacement.mov")
        await viewModel.importVideo { replacementURL }
        allowCopy.signal()
        await exportTask.value

        if case .readyToShare = viewModel.annotationExportState {
            Issue.record("Stale export should not be ready to share")
        }
    }

    @Test @MainActor func exportStagingCleanupRemovesOldDirectories() throws {
        let stagingRoot = Self.temporaryDirectory()
        let exporter = SwingAnnotationDatasetExporter(stagingRoot: stagingRoot)
        let oldDirectory = stagingRoot.appending(path: "old", directoryHint: .isDirectory)
        let keptDirectory = stagingRoot.appending(path: "kept", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keptDirectory, withIntermediateDirectories: true)

        exporter.cleanupStagedExports(keeping: keptDirectory)

        #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
        #expect(FileManager.default.fileExists(atPath: keptDirectory.path))
    }

    @Test @MainActor func videoReplacementIntervalAndSamplingClearAnnotations() async throws {
        let samples = [0.5, 1.5, 2.5, 3.5].map { Self.makeSample(time: $0, pose: Self.makeFullAnnotationPose()) }
        let track = Self.makeTrack(samples: samples)
        let viewModel = try await Self.makeCompletedAnnotationViewModel(track: track)

        viewModel.markSelectedSample(as: .address, in: track)
        #expect(!viewModel.annotations.isEmpty)
        viewModel.setIntervalStart(0.1)
        #expect(viewModel.annotations.isEmpty)

        viewModel.markSelectedSample(as: .address, in: track)
        viewModel.setSequenceSamplesPerSecond(12)
        #expect(viewModel.annotations.isEmpty)

        viewModel.markSelectedSample(as: .address, in: track)
        let replacementURL = try Self.makeVideoFile(named: "replacement.mov")
        await viewModel.importVideo { replacementURL }
        #expect(viewModel.annotations.isEmpty)
    }

    @Test @MainActor func staleFrameLoadsDoNotAlterAnnotationLabels() async throws {
        let firstSample = Self.makeSample(time: 1, pose: Self.makeFullAnnotationPose())
        let secondSample = Self.makeSample(time: 2, pose: Self.makeFullAnnotationPose())
        let processor = DeferredFrameVideoProcessor()
        let track = Self.makeTrack(samples: [firstSample, secondSample])
        let analyzer = StubPoseTrackAnalyzer(result: .success(track))
        let viewModel = SwingImportViewModel(
            importDirectory: Self.temporaryDirectory(),
            videoProcessor: processor,
            poseEstimator: StubPoseEstimator(result: .success(Self.makePose())),
            poseTrackAnalyzer: analyzer
        )
        let sourceURL = try Self.makeVideoFile(named: "source.mov")

        await viewModel.importVideo { sourceURL }
        viewModel.startPoseTrackAnalysis()
        await analyzer.waitForAnalysis()
        await analyzer.complete()
        await Task.yield()
        await processor.waitForFrameExtractionCount(1)
        await processor.completeFrameExtraction(at: 0)
        await Task.yield()
        viewModel.requestPoseSampleSelection(firstSample)
        await Task.yield()
        await processor.waitForFrameExtractionCount(2)
        viewModel.markSelectedSample(as: .address, in: track)
        viewModel.requestPoseSampleSelection(secondSample)
        await Task.yield()
        await processor.waitForFrameExtractionCount(3)
        await processor.completeFrameExtraction(at: 1)
        await processor.completeFrameExtraction(at: 2)
        await Task.yield()

        #expect(viewModel.annotation(for: .address)?.sampleID == firstSample.id)
    }

    @Test func oneSampleInterpolationUsesLinearCoordinates() {
        let observations = Self.makeJointSeries([0.2, nil, 0.4])

        let result = PoseTrackCleaner.interpolateShortGaps(observations: observations, timestamps: [0, 1, 2])

        #expect(abs((result[1][.leftWrist]?.x ?? 0) - 0.3) < 0.000001)
        #expect(Self.isInterpolated(result[1][.leftWrist]))
        #expect(result[1][.leftWrist]?.confidence == nil)
    }

    @Test func twoSampleInterpolationFillsBothMissingSamples() {
        let observations = Self.makeJointSeries([0.2, nil, nil, 0.5])

        let result = PoseTrackCleaner.interpolateShortGaps(observations: observations, timestamps: [0, 1, 2, 3])

        #expect(result[1][.leftWrist]?.x == 0.3)
        #expect(result[2][.leftWrist]?.x == 0.4)
        #expect(Self.isInterpolated(result[1][.leftWrist]))
        #expect(Self.isInterpolated(result[2][.leftWrist]))
    }

    @Test func gapExceedingInterpolationLimitRemainsUnavailable() {
        let observations = Self.makeJointSeries([0.2, nil, nil, nil, 0.6])

        let result = PoseTrackCleaner.interpolateShortGaps(observations: observations, timestamps: [0, 1, 2, 3, 4])

        #expect(result[1][.leftWrist] == nil)
        #expect(result[2][.leftWrist] == nil)
        #expect(result[3][.leftWrist] == nil)
    }

    @Test func interpolationDoesNotExtrapolateLeadingOrTrailingGaps() {
        let observations = Self.makeJointSeries([nil, 0.2, nil, 0.4, nil])

        let result = PoseTrackCleaner.interpolateShortGaps(observations: observations, timestamps: [0, 1, 2, 3, 4])

        #expect(result[0][.leftWrist] == nil)
        #expect(Self.isInterpolated(result[2][.leftWrist]))
        #expect(result[4][.leftWrist] == nil)
    }

    @Test func interpolationRespectsActualTimestamps() {
        let observations = Self.makeJointSeries([0.2, nil, 0.8])

        let result = PoseTrackCleaner.interpolateShortGaps(observations: observations, timestamps: [0, 1, 4])

        #expect(abs((result[1][.leftWrist]?.x ?? 0) - 0.35) < 0.000001)
    }

    @Test func outlierRejectionRemovesSyntheticSpike() {
        let observations = Self.makeJointSeries([0.2, 0.95, 0.22], includeBodyScale: true)

        let result = PoseTrackCleaner.rejectOutliers(
            observations: observations,
            timestamps: [0, 1, 2],
            bodyScale: 0.3,
            configuration: PoseTrackCleaningConfiguration(outlierDistanceScaleThreshold: 1, outlierNeighborDistanceScaleThreshold: 2.5)
        )

        #expect(result.observations[1][.leftWrist] == nil)
        #expect(result.rejectedCounts[.leftWrist] == 1)
    }

    @Test func legitimateFastMovementIsNotAutomaticallyRejected() {
        let observations = Self.makeJointSeries([0.1, 0.5, 0.9], includeBodyScale: true)

        let result = PoseTrackCleaner.rejectOutliers(
            observations: observations,
            timestamps: [0, 1, 2],
            bodyScale: 0.3,
            configuration: PoseTrackCleaningConfiguration(outlierDistanceScaleThreshold: 1, outlierNeighborDistanceScaleThreshold: 2.5)
        )

        #expect(result.observations[1][.leftWrist] != nil)
        #expect(result.rejectedCounts[.leftWrist] == 0)
    }

    @Test func smoothingReducesJitterWithinContinuousSegment() {
        let observations = Self.makeJointSeries([0.2, 0.5, 0.4])

        let result = PoseTrackCleaner.smooth(observations: observations, timestamps: [0, 1, 2], neighborWeight: 0.25)

        #expect(result[1][.leftWrist]?.x == 0.4)
        #expect(Self.isObserved(result[1][.leftWrist]))
    }

    @Test func smoothingDoesNotCrossUnavailableGaps() {
        let observations = Self.makeJointSeries([0.2, nil, 0.4, 0.6])

        let result = PoseTrackCleaner.smooth(observations: observations, timestamps: [0, 1, 2, 3], neighborWeight: 0.25)

        #expect(result[2][.leftWrist]?.x == 0.4)
    }

    @Test func derivedMidpointCalculationTracksInterpolatedInputs() {
        let landmarks = PoseTrackCleaner.deriveLandmarks(from: [
            .leftWrist: Self.tracked(x: 0.2, y: 0.4, source: .observed),
            .rightWrist: Self.tracked(x: 0.6, y: 0.8, source: .interpolated)
        ])

        #expect(landmarks.wristMidpoint?.x == 0.4)
        #expect(abs((landmarks.wristMidpoint?.y ?? 0) - 0.6) < 0.000001)
        #expect(landmarks.wristMidpoint?.usesInterpolatedPoint == true)
    }

    @Test func derivedLandmarkMissingWhenInputAbsent() {
        let landmarks = PoseTrackCleaner.deriveLandmarks(from: [
            .leftWrist: Self.tracked(x: 0.2, y: 0.4)
        ])

        #expect(landmarks.wristMidpoint == nil)
    }

    @Test func zeroLengthVectorIsUnavailable() {
        let landmarks = PoseTrackCleaner.deriveLandmarks(from: [
            .leftShoulder: Self.tracked(x: 0.4, y: 0.4),
            .rightShoulder: Self.tracked(x: 0.4, y: 0.4)
        ])

        #expect(landmarks.shoulderLine == nil)
        #expect(landmarks.approximateShoulderWidth == nil)
    }

    @Test func coveragePercentagesAndLongestGapAreAccurate() {
        let track = Self.makeTrack(samples: [
            Self.makeSample(time: 0, pose: Self.makePose(with: [.leftWrist: (0.2, 0.5)])),
            Self.makeSample(time: 1, pose: nil),
            Self.makeSample(time: 2, pose: Self.makePose(with: [.leftWrist: (0.4, 0.5)])),
            Self.makeSample(time: 3, pose: nil),
            Self.makeSample(time: 4, pose: nil)
        ])

        let cleaned = PoseTrackCleaner.clean(track: track)
        let coverage = cleaned.diagnostics.jointCoverage[.leftWrist]

        #expect(coverage?.observedSampleCount == 2)
        #expect(coverage?.interpolatedSampleCount == 1)
        #expect(coverage?.unavailableSampleCount == 2)
        #expect(coverage?.observedCoveragePercentage == 40)
        #expect(coverage?.effectiveCoveragePercentage == 60)
        #expect(coverage?.longestUnavailableGap == 2)
    }

    @Test func rejectedOutlierCountsAreReportedInDiagnostics() {
        let track = Self.makeTrack(samples: [
            Self.makeSample(time: 0, pose: Self.makePose(with: [.leftWrist: (0.2, 0.5)])),
            Self.makeSample(time: 1, pose: Self.makePose(with: [.leftWrist: (0.95, 0.5)])),
            Self.makeSample(time: 2, pose: Self.makePose(with: [.leftWrist: (0.22, 0.5)]))
        ])

        let cleaned = PoseTrackCleaner.clean(
            track: track,
            configuration: PoseTrackCleaningConfiguration(outlierDistanceScaleThreshold: 1, outlierNeighborDistanceScaleThreshold: 2.5)
        )

        #expect(cleaned.diagnostics.jointCoverage[.leftWrist]?.rejectedOutlierCount == 1)
        #expect(cleaned.diagnostics.totalRejectedOutlierCount == 1)
    }

    @Test func rawTrackRemainsUnchangedAfterCleaning() {
        let track = Self.makeTrack(samples: [
            Self.makeSample(time: 0, pose: Self.makePose(with: [.leftWrist: (0.2, 0.5)])),
            Self.makeSample(time: 1, pose: nil),
            Self.makeSample(time: 2, pose: Self.makePose(with: [.leftWrist: (0.4, 0.5)]))
        ])

        _ = PoseTrackCleaner.clean(track: track)

        #expect(track.samples[1].pose == nil)
    }

    @Test @MainActor func cleanedTrackClearsWhenSourceVideoChanges() async throws {
        let track = Self.makeTrack(samples: [Self.makeSample(time: 0, pose: Self.makePose(with: [.leftWrist: (0.2, 0.5)]))])
        let analyzer = StubPoseTrackAnalyzer(result: .success(track))
        let viewModel = Self.makeSequenceViewModel(analyzer: analyzer)
        let firstSourceURL = try Self.makeVideoFile(named: "first.mov", contents: "first")
        let secondSourceURL = try Self.makeVideoFile(named: "second.mov", contents: "second")

        await viewModel.importVideo { firstSourceURL }
        viewModel.startPoseTrackAnalysis()
        await analyzer.waitForAnalysis()
        await analyzer.complete()
        await Task.yield()
        #expect(viewModel.cleanedPoseTrack != nil)

        await viewModel.importVideo { secondSourceURL }

        #expect(viewModel.cleanedPoseTrack == nil)
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

    private actor DeferredFrameVideoProcessor: SwingVideoProcessing {
        private var frameRequests: [(Double, CheckedContinuation<SwingExtractedFrame, Error>)] = []
        private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func inspectVideo(at url: URL) async throws -> SwingVideoMetadata {
            SwingVideoMetadata(durationSeconds: 10, width: 1920, height: 1080, nominalFrameRate: 30, hasUsableVideoTrack: true)
        }

        func extractFrame(at timestampSeconds: Double, from url: URL) async throws -> SwingExtractedFrame {
            try await withCheckedThrowingContinuation { continuation in
                frameRequests.append((timestampSeconds, continuation))
                resumeReadyWaiters()
            }
        }

        func waitForFrameExtractionCount(_ expectedCount: Int) async {
            if frameRequests.count >= expectedCount { return }
            await withCheckedContinuation { continuation in
                countWaiters.append((expectedCount, continuation))
            }
        }

        func completeFrameExtraction(at index: Int) async {
            let timestampSeconds = frameRequests[index].0
            do {
                let frame = try ai_golfTests.makeFrame(requestedTimestampSeconds: timestampSeconds, actualTimestampSeconds: timestampSeconds)
                frameRequests[index].1.resume(returning: frame)
            } catch {
                frameRequests[index].1.resume(throwing: error)
            }
        }

        private func resumeReadyWaiters() {
            let readyWaiters = countWaiters.filter { frameRequests.count >= $0.0 }
            countWaiters.removeAll { frameRequests.count >= $0.0 }
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
        try makeVideoFile(named: name, bytes: Array(contents.utf8))
    }

    private static func makeVideoFile(named name: String, bytes: [UInt8]) throws -> URL {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let url = directory.appending(path: name)
        try Data(bytes).write(to: url)
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

    private static func makePose(
        with points: [BodyJoint: (x: Double, y: Double)],
        minimumConfidence: Double = 0.3
    ) -> DetectedPose {
        var posePoints = Dictionary(uniqueKeysWithValues: points.map { joint, point in
            (joint, PosePoint(joint: joint, x: point.x, y: point.y, confidence: 0.9))
        })
        posePoints[.neck] = posePoints[.neck] ?? PosePoint(joint: .neck, x: 0.5, y: 0.25, confidence: 0.9)
        posePoints[.root] = posePoints[.root] ?? PosePoint(joint: .root, x: 0.5, y: 0.55, confidence: 0.9)
        posePoints[.leftShoulder] = posePoints[.leftShoulder] ?? PosePoint(joint: .leftShoulder, x: 0.35, y: 0.3, confidence: 0.9)
        posePoints[.rightShoulder] = posePoints[.rightShoulder] ?? PosePoint(joint: .rightShoulder, x: 0.65, y: 0.3, confidence: 0.9)
        posePoints[.leftHip] = posePoints[.leftHip] ?? PosePoint(joint: .leftHip, x: 0.4, y: 0.6, confidence: 0.9)
        posePoints[.rightHip] = posePoints[.rightHip] ?? PosePoint(joint: .rightHip, x: 0.6, y: 0.6, confidence: 0.9)
        return DetectedPose(points: posePoints, minimumConfidence: minimumConfidence)
    }

    private static func makeFullAnnotationPose(minimumConfidence: Double = 0.3) -> DetectedPose {
        makePose(with: [
            .leftElbow: (0.25, 0.45),
            .rightElbow: (0.75, 0.45),
            .leftWrist: (0.2, 0.55),
            .rightWrist: (0.8, 0.55),
            .leftKnee: (0.4, 0.8),
            .rightKnee: (0.6, 0.8),
            .leftAnkle: (0.4, 0.95),
            .rightAnkle: (0.6, 0.95)
        ], minimumConfidence: minimumConfidence)
    }

    @MainActor private static func makeCompletedAnnotationViewModel(
        track: SwingPoseTrack,
        datasetExporter: SwingAnnotationDatasetExporter = SwingAnnotationDatasetExporter()
    ) async throws -> SwingImportViewModel {
        let analyzer = StubPoseTrackAnalyzer(result: .success(track))
        let viewModel = makeSequenceViewModel(analyzer: analyzer, datasetExporter: datasetExporter)
        let sourceURL = try makeVideoFile(named: "source.mov")
        await viewModel.importVideo { sourceURL }
        viewModel.startPoseTrackAnalysis()
        await analyzer.waitForAnalysis()
        await analyzer.complete()
        await Task.yield()
        return viewModel
    }

    @MainActor private static func markAllPositions(in viewModel: SwingImportViewModel, track: SwingPoseTrack) async {
        for (index, position) in SwingPosition.allCases.enumerated() {
            await viewModel.selectPoseSample(at: index, in: track)
            viewModel.markSelectedSample(as: position, in: track)
        }
    }

    @MainActor private static func waitForPoseTrackCompletion(_ viewModel: SwingImportViewModel) async {
        for _ in 0..<50 {
            if case .completed = viewModel.poseTrackAnalysisState {
                return
            }
            await Task.yield()
        }
    }

    @MainActor private static func makeAnnotationMap(times: [SwingPosition: Double], includeInterpolatedWrist: Bool = false) -> [SwingPosition: SwingPositionAnnotation] {
        Dictionary(uniqueKeysWithValues: times.map { position, time in
            let cleanedSample = cleanedSample(
                joints: [.neck, .root, .leftShoulder, .rightShoulder, .leftHip, .rightHip, .leftElbow, .leftWrist],
                timestamp: time,
                interpolatedJoints: includeInterpolatedWrist ? [.leftWrist] : []
            )
            return (position, SwingPositionAnnotation(
                position: position,
                sampleIndex: Int(time),
                sampleID: UUID(),
                requestedTimestamp: time,
                actualTimestamp: time,
                poseQualityCategory: .complete,
                readiness: SwingAnnotationBuilder.readiness(for: cleanedSample),
                availability: SwingAnnotationBuilder.availability(for: cleanedSample),
                cleanedPoseSample: cleanedSample,
                missingJoints: [],
                note: nil
            ))
        })
    }

    @MainActor private static func makeAnnotationRecord(
        identity: SwingAnnotationIdentity = SwingAnnotationIdentity(
            annotationID: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!,
            createdAt: Date(timeIntervalSince1970: 0)
        ),
        sourceVideoFilename: String = "swing-550E8400-E29B-41D4-A716-446655440000.mov",
        context: SwingAnnotationContext = SwingAnnotationContext(),
        analysisConfiguration: ExportedAnalysisConfiguration = ExportedAnalysisConfiguration(
            intervalStartSeconds: 0,
            intervalEndSeconds: 4,
            requestedSamplingRate: 10,
            analyzedSampleCount: 40,
            confidenceThreshold: 0.3
        ),
        annotations: [SwingPosition: SwingPositionAnnotation]? = nil
    ) throws -> SwingAnnotationRecord {
        try SwingAnnotationBuilder.record(
            identity: identity,
            sourceVideoFilename: sourceVideoFilename,
            context: context,
            analysisConfiguration: analysisConfiguration,
            annotations: annotations ?? makeAnnotationMap(times: [.address: 1, .top: 2, .impact: 3, .finish: 4])
        )
    }

    private static func cleanedSample(
        joints: [BodyJoint],
        timestamp: Double = 0,
        interpolatedJoints: Set<BodyJoint> = []
    ) -> CleanedPoseSample {
        let trackedJoints = Dictionary(uniqueKeysWithValues: joints.map { joint in
            (joint, tracked(
                x: joint == .leftWrist ? 0.2 : 0.5,
                y: joint == .leftWrist ? 0.5 : 0.4,
                source: interpolatedJoints.contains(joint) ? .interpolated : .observed
            ))
        })
        return CleanedPoseSample(
            id: UUID(),
            timestamp: timestamp,
            joints: trackedJoints,
            landmarks: PoseTrackCleaner.deriveLandmarks(from: trackedJoints)
        )
    }

    private static func makeJointSeries(_ xs: [Double?], includeBodyScale: Bool = false) -> [[BodyJoint: TrackedJointPoint]] {
        xs.map { x in
            var joints: [BodyJoint: TrackedJointPoint] = [:]
            if let x {
                joints[.leftWrist] = tracked(x: x, y: 0.5)
            }
            if includeBodyScale {
                joints[.neck] = tracked(x: 0.5, y: 0.25)
                joints[.root] = tracked(x: 0.5, y: 0.55)
                joints[.leftShoulder] = tracked(x: 0.35, y: 0.3)
                joints[.rightShoulder] = tracked(x: 0.65, y: 0.3)
            }
            return joints
        }
    }

    private static func tracked(x: Double, y: Double, source: JointPointSource = .observed) -> TrackedJointPoint {
        TrackedJointPoint(x: x, y: y, confidence: isObserved(source) ? 0.9 : nil, source: source)
    }

    private static func isObserved(_ source: JointPointSource) -> Bool {
        return switch source {
        case .observed: true
        case .interpolated: false
        }
    }

    private static func isObserved(_ point: TrackedJointPoint?) -> Bool {
        guard let point else { return false }
        return isObserved(point.source)
    }

    private static func isInterpolated(_ point: TrackedJointPoint?) -> Bool {
        guard let point else { return false }
        return switch point.source {
        case .observed: false
        case .interpolated: true
        }
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

    @MainActor private static func makeSequenceViewModel(
        analyzer: SwingPoseTrackAnalyzing,
        datasetExporter: SwingAnnotationDatasetExporter = SwingAnnotationDatasetExporter()
    ) -> SwingImportViewModel {
        SwingImportViewModel(
            importDirectory: temporaryDirectory(),
            videoProcessor: StubVideoProcessor(metadata: SwingVideoMetadata(durationSeconds: 10, width: 1920, height: 1080, nominalFrameRate: 30, hasUsableVideoTrack: true)),
            poseEstimator: StubPoseEstimator(result: .success(makePose())),
            poseTrackAnalyzer: analyzer,
            datasetExporter: datasetExporter
        )
    }
}
