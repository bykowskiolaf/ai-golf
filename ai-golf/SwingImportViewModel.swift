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

    enum AnnotationExportState: Equatable {
        case idle
        case preparingFiles
        case readyToShare(SwingAnnotationDatasetExport)
        case failed(message: String)
    }

    enum PoseTrackOverlayMode: String, CaseIterable {
        case raw
        case cleaned

        var displayName: String {
            switch self {
            case .raw: "Raw"
            case .cleaned: "Cleaned"
            }
        }
    }

    private let fileManager: FileManager
    private let importDirectory: URL
    private let videoProcessor: SwingVideoProcessing
    private let poseEstimator: PoseEstimating
    private let poseTrackAnalyzer: SwingPoseTrackAnalyzing
    private let datasetExporter: SwingAnnotationDatasetExporter
    private var currentImportedFile: URL?
    private var activeVideoID = UUID()
    private var activeFrameID = UUID()
    private var activeTrackID = UUID()
    private var activeSelectedPoseSampleFrameID = UUID()
    private var activeAnnotationExportID = UUID()
    private var poseTrackTask: Task<Void, Never>?
    private var selectedPoseSampleFrameTask: Task<Void, Never>?

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
    private(set) var cleanedPoseTrack: CleanedPoseTrack?
    var poseTrackOverlayMode: PoseTrackOverlayMode = .cleaned
    var selectedDiagnosticJoint: BodyJoint = .leftWrist
    var annotationContext = SwingAnnotationContext()
    private(set) var annotationIdentity = SwingAnnotationIdentity()
    private(set) var annotations: [SwingPosition: SwingPositionAnnotation] = [:]
    private(set) var annotationExportState: AnnotationExportState = .idle
    private(set) var annotationMessage: String?
    private(set) var currentAnalysisConfiguration: ExportedAnalysisConfiguration?

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
        self.datasetExporter = SwingAnnotationDatasetExporter()
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
        self.datasetExporter = SwingAnnotationDatasetExporter()
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
        self.datasetExporter = SwingAnnotationDatasetExporter()
    }

    init(
        importDirectory: URL,
        fileManager: FileManager = .default,
        videoProcessor: SwingVideoProcessing,
        poseEstimator: PoseEstimating,
        poseTrackAnalyzer: SwingPoseTrackAnalyzing,
        datasetExporter: SwingAnnotationDatasetExporter = SwingAnnotationDatasetExporter()
    ) {
        self.importDirectory = importDirectory
        self.fileManager = fileManager
        self.videoProcessor = videoProcessor
        self.poseEstimator = poseEstimator
        self.poseTrackAnalyzer = poseTrackAnalyzer
        self.datasetExporter = datasetExporter
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
            annotationContext.videoDurationSeconds = metadata.durationSeconds
            annotationContext.videoWidth = metadata.width
            annotationContext.videoHeight = metadata.height
            annotationContext.reportedFrameRate = Double(metadata.nominalFrameRate)
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
        annotationContext = SwingAnnotationContext()
        resetAnnotationSession()
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
        clearAnnotations()
        updateSequenceValidation()
    }

    func setIntervalEnd(_ seconds: Double) {
        intervalEndSeconds = clampedTimestamp(seconds)
        clearAnnotations()
        updateSequenceValidation()
    }

    func setSequenceSamplesPerSecond(_ samplesPerSecond: Double) {
        sequenceSamplesPerSecond = max(0.1, samplesPerSecond)
        clearAnnotations()
        updateSequenceValidation()
    }

    func startPoseTrackAnalysis() {
        guard case .ready(let swing) = state else { return }
        let videoID = activeVideoID
        let trackID = UUID()
        activeTrackID = trackID
        selectedPoseSampleID = nil
        selectedPoseSampleFrameState = .idle
        cleanedPoseTrack = nil
        clearAnnotations()

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
                cleanedPoseTrack = PoseTrackCleaner.clean(track: track)
                currentAnalysisConfiguration = ExportedAnalysisConfiguration(
                    intervalStartSeconds: intervalStartSeconds,
                    intervalEndSeconds: intervalEndSeconds,
                    requestedSamplingRate: sequenceSamplesPerSecond,
                    analyzedSampleCount: track.samples.count,
                    confidenceThreshold: minimumPoseConfidence
                )
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
        let selectedFrameID = UUID()
        activeSelectedPoseSampleFrameID = selectedFrameID
        selectedPoseSampleID = sample.id
        selectedPoseSampleFrameState = .loading

        do {
            let frame = try await videoProcessor.extractFrame(at: sample.actualTime, from: swing.localVideoURL)
            guard !Task.isCancelled,
                  activeVideoID == videoID,
                  activeTrackID == trackID,
                  activeSelectedPoseSampleFrameID == selectedFrameID,
                  selectedPoseSampleID == sample.id else { return }
            selectedPoseSampleFrameState = .loaded(sample: sample, frame: frame)
        } catch {
            guard !Task.isCancelled,
                  activeVideoID == videoID,
                  activeTrackID == trackID,
                  activeSelectedPoseSampleFrameID == selectedFrameID,
                  selectedPoseSampleID == sample.id else { return }
            selectedPoseSampleFrameState = .failed(message: "The selected sample frame could not be loaded.")
        }
    }

    func requestPoseSampleSelection(_ sample: PoseSample) {
        selectedPoseSampleFrameTask?.cancel()
        selectedPoseSampleFrameTask = Task { [weak self] in
            await self?.selectPoseSample(sample)
        }
    }

    func requestPoseSampleSelection(at index: Int, in track: SwingPoseTrack) {
        guard !track.samples.isEmpty else { return }
        let clampedIndex = min(max(index, 0), track.samples.count - 1)
        requestPoseSampleSelection(track.samples[clampedIndex])
    }

    func requestAdjacentPoseSampleSelection(offset: Int, in track: SwingPoseTrack) {
        guard !track.samples.isEmpty else { return }
        let currentIndex = selectedPoseSampleID.flatMap { id in
            track.samples.firstIndex { $0.id == id }
        } ?? 0
        requestPoseSampleSelection(at: currentIndex + offset, in: track)
    }

    func selectPoseSample(at index: Int, in track: SwingPoseTrack) async {
        guard !track.samples.isEmpty else { return }
        let clampedIndex = min(max(index, 0), track.samples.count - 1)
        await selectPoseSample(track.samples[clampedIndex])
    }

    func selectAdjacentPoseSample(offset: Int, in track: SwingPoseTrack) async {
        guard !track.samples.isEmpty else { return }
        let currentIndex = selectedPoseSampleID.flatMap { id in
            track.samples.firstIndex { $0.id == id }
        } ?? 0
        await selectPoseSample(at: currentIndex + offset, in: track)
    }

    func selectedPoseSampleIndex(in track: SwingPoseTrack) -> Int {
        guard let selectedPoseSampleID,
              let index = track.samples.firstIndex(where: { $0.id == selectedPoseSampleID }) else {
            return 0
        }
        return index
    }

    func selectedCleanedPoseSample(in track: SwingPoseTrack) -> CleanedPoseSample? {
        guard let cleanedPoseTrack else { return nil }
        let index = selectedPoseSampleIndex(in: track)
        guard cleanedPoseTrack.samples.indices.contains(index) else { return nil }
        return cleanedPoseTrack.samples[index]
    }

    var annotationValidation: SwingAnnotationValidation {
        SwingAnnotationBuilder.validate(annotations: annotations)
    }

    func annotation(for position: SwingPosition) -> SwingPositionAnnotation? {
        annotations[position]
    }

    func markSelectedSample(as position: SwingPosition, in track: SwingPoseTrack) {
        guard let cleanedPoseTrack else {
            annotationMessage = "Analyze and clean a pose track before labeling positions."
            return
        }

        let index = selectedPoseSampleIndex(in: track)
        guard track.samples.indices.contains(index), cleanedPoseTrack.samples.indices.contains(index) else {
            annotationMessage = "Select a valid analyzed sample before labeling."
            return
        }

        let sample = track.samples[index]
        let cleanedSample = cleanedPoseTrack.samples[index]
        let existingNote = annotations[position]?.note
        annotations[position] = SwingPositionAnnotation(
            position: position,
            sampleIndex: index,
            sampleID: sample.id,
            requestedTimestamp: sample.requestedTime,
            actualTimestamp: sample.actualTime,
            poseQualityCategory: sample.quality.category,
            readiness: SwingAnnotationBuilder.readiness(for: cleanedSample),
            availability: SwingAnnotationBuilder.availability(for: cleanedSample),
            cleanedPoseSample: cleanedSample,
            missingJoints: sample.quality.missingJoints,
            note: existingNote
        )
        annotationExportState = .idle
        annotationMessage = "Marked \(position.displayName) at \(sample.actualTime.formatted(.number.precision(.fractionLength(2))))s."
    }

    func updateAnnotationNote(_ note: String, for position: SwingPosition) {
        guard var annotation = annotations[position] else { return }
        annotation.note = SwingAnnotationBuilder.normalizedNote(note)
        annotations[position] = annotation
        annotationExportState = .idle
        annotationMessage = nil
    }

    func clearAnnotation(_ position: SwingPosition) {
        annotations[position] = nil
        annotationExportState = .idle
        annotationMessage = "Cleared \(position.displayName)."
    }

    func jumpToAnnotation(_ position: SwingPosition, in track: SwingPoseTrack) {
        guard let annotation = annotations[position] else { return }
        requestPoseSampleSelection(at: annotation.sampleIndex, in: track)
    }

    func exportAnnotation() async {
        guard case .ready(let swing) = state else {
            annotationExportState = .failed(message: "Import a video before exporting.")
            annotationMessage = "Import a video before exporting."
            return
        }
        guard annotationExportState != .preparingFiles else { return }
        guard let currentAnalysisConfiguration else {
            annotationExportState = .failed(message: "Analyze a pose track before exporting.")
            annotationMessage = "Analyze a pose track before exporting."
            return
        }

        let videoID = activeVideoID
        let exportID = UUID()
        activeAnnotationExportID = exportID
        annotationExportState = .preparingFiles
        annotationMessage = "Preparing video and annotation files..."

        do {
            let sourceVideoFilename = datasetExporter.sourceVideoFilename(annotationID: annotationIdentity.annotationID, sourceVideoURL: swing.localVideoURL)
            let record = try SwingAnnotationBuilder.record(
                identity: annotationIdentity,
                sourceVideoFilename: sourceVideoFilename,
                context: annotationContext,
                analysisConfiguration: currentAnalysisConfiguration,
                annotations: annotations
            )
            let annotationData = try JSONEncoder.swingAnnotationEncoder().encode(record)
            let annotationID = record.annotationID
            let exportedVideoFilename = record.sourceVideoFilename
            let sourceVideoURL = swing.localVideoURL
            let exporter = datasetExporter
            let export = try await Task.detached(priority: .userInitiated) {
                try exporter.export(
                    annotationID: annotationID,
                    sourceVideoFilename: exportedVideoFilename,
                    annotationData: annotationData,
                    sourceVideoURL: sourceVideoURL
                )
            }.value
            guard activeVideoID == videoID, activeAnnotationExportID == exportID else {
                try? fileManager.removeItem(at: export.stagingDirectory)
                return
            }
            datasetExporter.cleanupStagedExports(keeping: export.stagingDirectory)
            annotationExportState = .readyToShare(export)
            annotationMessage = "Annotation dataset pair is ready to share."
        } catch let error as SwingAnnotationExportError {
            guard activeVideoID == videoID, activeAnnotationExportID == exportID else { return }
            switch error {
            case .invalid(let message):
                annotationExportState = .failed(message: message)
                annotationMessage = message
            }
        } catch let error as SwingAnnotationDatasetExporter.ExportError {
            guard activeVideoID == videoID, activeAnnotationExportID == exportID else { return }
            let message = switch error {
            case .stagingFailed: "Export failed while preparing temporary files. Try again."
            case .videoCopyFailed: "Export failed while copying the source video. Try again."
            case .jsonWriteFailed: "Export failed while writing the annotation JSON. Try again."
            }
            annotationExportState = .failed(message: message)
            annotationMessage = message
        } catch {
            guard activeVideoID == videoID, activeAnnotationExportID == exportID else { return }
            annotationExportState = .failed(message: "Annotation export failed. Try again.")
            annotationMessage = "Annotation export failed. Try again."
        }
    }

    func dismissAnnotationExport() {
        if case .readyToShare = annotationExportState {
            annotationExportState = .idle
        }
    }

    private func clearPoseTrackState() {
        poseTrackTask?.cancel()
        selectedPoseSampleFrameTask?.cancel()
        activeTrackID = UUID()
        activeSelectedPoseSampleFrameID = UUID()
        sequenceValidationMessage = nil
        poseTrackAnalysisState = .idle
        selectedPoseSampleID = nil
        selectedPoseSampleFrameState = .idle
        cleanedPoseTrack = nil
        currentAnalysisConfiguration = nil
        clearAnnotations()
    }

    private func clearAnnotations() {
        annotations = [:]
        resetAnnotationSession()
        annotationExportState = .idle
        annotationMessage = nil
    }

    private func resetAnnotationSession() {
        annotationIdentity = SwingAnnotationIdentity()
        activeAnnotationExportID = UUID()
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
