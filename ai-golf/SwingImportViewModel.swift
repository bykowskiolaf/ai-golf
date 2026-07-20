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

    enum PoseAnalysisState: Equatable {
        case noExtractedFrame
        case ready
        case analyzing
        case detected(DetectedPose)
        case noPoseDetected
        case failed(message: String)
    }

    enum PoseTrackAnalysisState: Equatable {
        case idle
        case analyzing(PoseTrackProgress)
        case completed(SwingPoseTrack)
        case cancelled
        case failed(message: String)
    }

    enum SelectedPoseSampleFrameState {
        case idle
        case loading
        case loaded(sample: PoseSample, frame: SwingExtractedFrame)
        case failed(message: String)
    }

    private let fileManager: FileManager
    private let importDirectory: URL
    private let videoProcessor: SwingVideoProcessing
    private let poseEstimator: PoseEstimating
    private let poseTrackAnalyzer: SwingPoseTrackAnalyzing
    private var currentImportedFile: URL?
    private var activeVideoID = UUID()
    private var activeFrameID = UUID()
    private var activeTrackID = UUID()
    private var poseTrackTask: Task<Void, Never>?

    private(set) var state: State = .empty
    private(set) var metadataState: MetadataState = .idle
    private(set) var selectedTimestampSeconds = 0.0
    private(set) var frameExtractionState: FrameExtractionState = .idle
    private(set) var poseAnalysisState: PoseAnalysisState = .noExtractedFrame
    var minimumPoseConfidence = 0.3
    var isPoseOverlayVisible = true
    var intervalStartSeconds = 0.0
    var intervalEndSeconds = 0.0
    var sequenceSamplesPerSecond = 10.0
    private(set) var sequenceValidationMessage: String?
    private(set) var poseTrackAnalysisState: PoseTrackAnalysisState = .idle
    private(set) var selectedPoseSampleID: UUID?
    private(set) var selectedPoseSampleFrameState: SelectedPoseSampleFrameState = .idle

    init(
        importDirectory: URL = FileManager.default.temporaryDirectory
            .appending(path: "ImportedSwings", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        let videoProcessor = AVFoundationSwingVideoProcessor()
        let poseEstimator = VisionPoseEstimator()
        self.importDirectory = importDirectory
        self.fileManager = fileManager
        self.videoProcessor = videoProcessor
        self.poseEstimator = poseEstimator
        self.poseTrackAnalyzer = SwingPoseTrackAnalyzer(videoProcessor: videoProcessor, poseEstimator: poseEstimator)
    }

    init(
        importDirectory: URL,
        fileManager: FileManager = .default,
        videoProcessor: SwingVideoProcessing
    ) {
        let poseEstimator = VisionPoseEstimator()
        self.importDirectory = importDirectory
        self.fileManager = fileManager
        self.videoProcessor = videoProcessor
        self.poseEstimator = poseEstimator
        self.poseTrackAnalyzer = SwingPoseTrackAnalyzer(videoProcessor: videoProcessor, poseEstimator: poseEstimator)
    }

    init(
        importDirectory: URL,
        fileManager: FileManager = .default,
        videoProcessor: SwingVideoProcessing,
        poseEstimator: PoseEstimating
    ) {
        self.importDirectory = importDirectory
        self.fileManager = fileManager
        self.videoProcessor = videoProcessor
        self.poseEstimator = poseEstimator
        self.poseTrackAnalyzer = SwingPoseTrackAnalyzer(videoProcessor: videoProcessor, poseEstimator: poseEstimator)
    }

    init(
        importDirectory: URL,
        fileManager: FileManager = .default,
        videoProcessor: SwingVideoProcessing,
        poseEstimator: PoseEstimating,
        poseTrackAnalyzer: SwingPoseTrackAnalyzing
    ) {
        self.importDirectory = importDirectory
        self.fileManager = fileManager
        self.videoProcessor = videoProcessor
        self.poseEstimator = poseEstimator
        self.poseTrackAnalyzer = poseTrackAnalyzer
    }

    func importVideo(loadSourceURL: () async throws -> URL) async {
        let videoID = UUID()
        activeVideoID = videoID
        state = .importing
        clearInspectionState()

        do {
            let sourceURL = try await loadSourceURL()
            guard activeVideoID == videoID else { return }

            let importedURL = try copyIntoImportDirectory(sourceURL)
            guard activeVideoID == videoID else {
                try? fileManager.removeItem(at: importedURL)
                return
            }

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
        clearPoseState()
        let frameID = UUID()
        activeFrameID = frameID

        do {
            let frame = try await videoProcessor.extractFrame(at: timestampSeconds, from: swing.localVideoURL)
            guard activeVideoID == videoID, activeFrameID == frameID else { return }
            frameExtractionState = .extracted(frame)
            poseAnalysisState = .ready
        } catch {
            guard activeVideoID == videoID, activeFrameID == frameID else { return }
            frameExtractionState = .failed(message: "The frame could not be extracted. Try another timestamp.")
            poseAnalysisState = .noExtractedFrame
        }
    }

    func analyzePose() async {
        guard case .extracted(let frame) = frameExtractionState else {
            poseAnalysisState = .noExtractedFrame
            return
        }

        let frameID = activeFrameID
        poseAnalysisState = .analyzing

        do {
            let pose = try await poseEstimator.detectPose(in: frame.image, minimumConfidence: minimumPoseConfidence)
            guard activeFrameID == frameID else { return }

            if let pose {
                poseAnalysisState = .detected(pose)
            } else {
                poseAnalysisState = .noPoseDetected
            }
        } catch {
            guard activeFrameID == frameID else { return }
            poseAnalysisState = .failed(message: "Pose analysis failed. Try another frame.")
        }
    }

    private func inspectImportedVideo(_ swing: ImportedSwing, videoID: UUID) async {
        do {
            let metadata = try await videoProcessor.inspectVideo(at: swing.localVideoURL)
            guard activeVideoID == videoID else { return }
            metadataState = .available(metadata)
            selectedTimestampSeconds = clampedTimestamp(selectedTimestampSeconds)
            intervalStartSeconds = 0
            intervalEndSeconds = metadata.durationSeconds
            updateSequenceValidation()
        } catch {
            guard activeVideoID == videoID else { return }
            metadataState = .failed(message: "The video metadata could not be loaded.")
        }
    }

    private func clearInspectionState() {
        metadataState = .idle
        selectedTimestampSeconds = 0
        intervalStartSeconds = 0
        intervalEndSeconds = 0
        frameExtractionState = .idle
        activeFrameID = UUID()
        clearPoseState()
        clearPoseTrackState()
    }

    private func clearPoseState() {
        poseAnalysisState = .noExtractedFrame
    }

    func setIntervalStart(_ seconds: Double) {
        intervalStartSeconds = clampedTimestamp(seconds)
        if intervalEndSeconds <= intervalStartSeconds {
            intervalEndSeconds = min(currentDurationSeconds, intervalStartSeconds + 0.01)
        }
        updateSequenceValidation()
    }

    func setIntervalEnd(_ seconds: Double) {
        intervalEndSeconds = clampedTimestamp(seconds)
        updateSequenceValidation()
    }

    func setSequenceSamplesPerSecond(_ samplesPerSecond: Double) {
        sequenceSamplesPerSecond = max(0.1, samplesPerSecond)
        updateSequenceValidation()
    }

    func startPoseTrackAnalysis() {
        guard case .ready(let swing) = state else { return }
        let videoID = activeVideoID
        let trackID = UUID()
        activeTrackID = trackID
        selectedPoseSampleID = nil
        selectedPoseSampleFrameState = .idle

        let plan: PoseTrackSamplingPlan
        do {
            plan = try makeSamplingPlan()
        } catch {
            poseTrackAnalysisState = .failed(message: "Choose a valid interval before analyzing.")
            return
        }

        sequenceValidationMessage = plan.wasReducedToMaximum ? "Sampling was reduced to stay within 150 samples." : nil
        poseTrackTask?.cancel()
        poseTrackAnalysisState = .analyzing(PoseTrackProgress(processedSamples: 0, totalSamples: plan.timestamps.count))

        poseTrackTask = Task { [poseTrackAnalyzer, minimumPoseConfidence] in
            do {
                let track = try await poseTrackAnalyzer.analyze(
                    videoURL: swing.localVideoURL,
                    timestamps: plan.timestamps,
                    minimumConfidence: minimumPoseConfidence
                ) { [weak self] progress in
                    guard let self, self.activeVideoID == videoID, self.activeTrackID == trackID else { return }
                    self.poseTrackAnalysisState = .analyzing(progress)
                }

                guard activeVideoID == videoID, activeTrackID == trackID else { return }
                poseTrackAnalysisState = .completed(track)
                if let firstSample = track.samples.first {
                    await selectPoseSample(firstSample)
                }
                poseTrackTask = nil
            } catch is CancellationError {
                guard activeVideoID == videoID, activeTrackID == trackID else { return }
                poseTrackAnalysisState = .cancelled
                poseTrackTask = nil
            } catch {
                guard activeVideoID == videoID, activeTrackID == trackID else { return }
                poseTrackAnalysisState = .failed(message: "Sequence analysis failed. Try a shorter interval.")
                poseTrackTask = nil
            }
        }
    }

    func cancelPoseTrackAnalysis() {
        poseTrackTask?.cancel()
        poseTrackTask = nil
        activeTrackID = UUID()
        poseTrackAnalysisState = .cancelled
    }

    func selectPoseSample(_ sample: PoseSample) async {
        guard case .ready(let swing) = state else { return }
        let videoID = activeVideoID
        let trackID = activeTrackID
        selectedPoseSampleID = sample.id
        selectedPoseSampleFrameState = .loading

        do {
            let frame = try await videoProcessor.extractFrame(at: sample.actualTime, from: swing.localVideoURL)
            guard activeVideoID == videoID, activeTrackID == trackID, selectedPoseSampleID == sample.id else { return }
            selectedPoseSampleFrameState = .loaded(sample: sample, frame: frame)
        } catch {
            guard activeVideoID == videoID, activeTrackID == trackID, selectedPoseSampleID == sample.id else { return }
            selectedPoseSampleFrameState = .failed(message: "The selected sample frame could not be loaded.")
        }
    }

    private func clearPoseTrackState() {
        poseTrackTask?.cancel()
        activeTrackID = UUID()
        sequenceValidationMessage = nil
        poseTrackAnalysisState = .idle
        selectedPoseSampleID = nil
        selectedPoseSampleFrameState = .idle
    }

    private func makeSamplingPlan() throws -> PoseTrackSamplingPlan {
        try PoseTrackSampler.makePlan(PoseTrackSamplingRequest(
            startTime: intervalStartSeconds,
            endTime: intervalEndSeconds,
            samplesPerSecond: sequenceSamplesPerSecond,
            durationSeconds: currentDurationSeconds,
            maximumSamples: 150
        ))
    }

    private func updateSequenceValidation() {
        do {
            let plan = try makeSamplingPlan()
            sequenceValidationMessage = plan.wasReducedToMaximum ? "Sampling will be reduced to stay within 150 samples." : nil
        } catch PoseTrackSamplingError.invalidInterval {
            sequenceValidationMessage = "Start must be before end, and both must be within the video duration."
        } catch {
            sequenceValidationMessage = "Choose a valid sampling rate."
        }
    }

    private var currentDurationSeconds: Double {
        if case .available(let metadata) = metadataState {
            return metadata.durationSeconds
        }
        return 0
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
