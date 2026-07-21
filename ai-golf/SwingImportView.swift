import AVKit
import PhotosUI
import SwiftUI
import UIKit

struct SwingImportView: View {
    @State private var viewModel = SwingImportViewModel()
    @State private var selectedItem: PhotosPickerItem?
    @State private var reviewSampleIndex = 0.0

    private let pickerLoader = SwingVideoPickerLoader()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    content

                    PhotosPicker(
                        selection: $selectedItem,
                        matching: .videos,
                        photoLibrary: .shared()
                    ) {
                        Label(buttonTitle, systemImage: "film")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.state == .importing)
                }
                .frame(maxWidth: 720)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Swing Import")
            .task(id: selectedItem) {
                guard let selectedItem else { return }

                var sourceURL: URL?
                await viewModel.importVideo {
                    let loadedURL = try await pickerLoader.loadSourceURL(from: selectedItem)
                    sourceURL = loadedURL
                    return loadedURL
                }

                if let sourceURL {
                    pickerLoader.removeTemporarySource(at: sourceURL)
                }
            }
            .sheet(isPresented: Binding(
                get: {
                    if case .readyToShare = viewModel.annotationExportState { return true }
                    return false
                },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissAnnotationExport()
                    }
                }
            )) {
                if case .readyToShare(let export) = viewModel.annotationExportState {
                    ShareSheet(activityItems: export.shareItems)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .empty:
            ContentUnavailableView(
                "Select a Golf-Swing Video",
                systemImage: "figure.golf",
                description: Text("Choose a regular or slow-motion swing video from Photos to preview it here.")
            )
            .frame(minHeight: 320)

        case .importing:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Importing swing video...")
                    .font(.headline)
                Text("Keeping a local copy available for playback.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 320)

        case .ready(let swing):
            VStack(alignment: .leading, spacing: 20) {
                metadataContent
                poseTrackAnalysisContent
                DisclosureGroup("Video Preview") {
                    videoPreview(url: swing.localVideoURL)
                }
                DisclosureGroup("Single Frame Tools") {
                    VStack(alignment: .leading, spacing: 12) {
                        frameExtractionControls
                        extractedFrameContent
                    }
                }
            }

        case .failed(let message):
            ContentUnavailableView(
                "Import Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(minHeight: 320)
        }
    }

    private var buttonTitle: String {
        switch viewModel.state {
        case .ready:
            "Replace Swing Video"
        default:
            "Choose Swing Video"
        }
    }

    private func videoPreview(url: URL) -> some View {
        SwingVideoPlayer(url: url)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.quaternary, lineWidth: 1)
            }
    }

    @ViewBuilder
    private var metadataContent: some View {
        switch viewModel.metadataState {
        case .idle:
            EmptyView()

        case .loading:
            Label("Inspecting video metadata...", systemImage: "info.circle")
                .foregroundStyle(.secondary)

        case .available(let metadata):
            VStack(alignment: .leading, spacing: 8) {
                Text("Video Metadata")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    metadataRow("Duration", "\(formatSeconds(metadata.durationSeconds)) seconds")
                    metadataRow("Dimensions", "\(metadata.width) x \(metadata.height)")
                    metadataRow("Frame Rate", "\(formatFrameRate(metadata.nominalFrameRate)) fps")
                    metadataRow("Video Track", metadata.hasUsableVideoTrack ? "Usable" : "Not usable")
                }
                .font(.subheadline)

                if metadata.isHighFrameRateSource {
                    Label("High-frame-rate source", systemImage: "speedometer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }

    @ViewBuilder
    private var frameExtractionControls: some View {
        if case .available(let metadata) = viewModel.metadataState {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Selected Timestamp")
                        .font(.headline)
                    Spacer()
                    Text(formatSeconds(viewModel.selectedTimestampSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { viewModel.selectedTimestampSeconds },
                        set: { viewModel.setSelectedTimestamp($0) }
                    ),
                    in: 0...metadata.durationSeconds
                )

                Button {
                    Task { await viewModel.extractFrame() }
                } label: {
                    Label("Extract Frame", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExtractingFrame)
            }
        }
    }

    @ViewBuilder
    private var extractedFrameContent: some View {
        switch viewModel.frameExtractionState {
        case .idle:
            EmptyView()

        case .extracting:
            HStack(spacing: 12) {
                ProgressView()
                Text("Extracting frame...")
                    .foregroundStyle(.secondary)
            }

        case .extracted(let frame):
            VStack(alignment: .leading, spacing: 8) {
                Text("Extracted Frame")
                    .font(.headline)
                poseFrameImage(frame, pose: singleFramePose)
                Text("Requested \(formatSeconds(frame.requestedTimestampSeconds))s, received \(formatSeconds(frame.actualTimestampSeconds))s")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                poseControls
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func poseFrameImage(_ frame: SwingExtractedFrame, pose: DetectedPose?) -> some View {
        let imageSize = CGSize(width: frame.image.width, height: frame.image.height)

        return Image(decorative: frame.image, scale: 1)
            .resizable()
            .scaledToFit()
            .overlay {
                if viewModel.isPoseOverlayVisible, let pose {
                    PoseSkeletonOverlay(pose: pose, imageSize: imageSize)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.quaternary, lineWidth: 1)
            }
    }

    private var singleFramePose: DetectedPose? {
        if case .detected(let pose) = viewModel.poseAnalysisState {
            return pose
        }
        return nil
    }

    @ViewBuilder
    private var poseTrackAnalysisContent: some View {
        if case .available(let metadata) = viewModel.metadataState {
            VStack(alignment: .leading, spacing: 14) {
                Text("Sequence Pose Analysis")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Start")
                        Spacer()
                        Text(formatSeconds(viewModel.intervalStartSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { viewModel.intervalStartSeconds },
                        set: { viewModel.setIntervalStart($0) }
                    ), in: 0...metadata.durationSeconds)

                    HStack {
                        Text("End")
                        Spacer()
                        Text(formatSeconds(viewModel.intervalEndSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { viewModel.intervalEndSeconds },
                        set: { viewModel.setIntervalEnd($0) }
                    ), in: 0...metadata.durationSeconds)

                    HStack {
                        Text("Sampling Rate")
                        Spacer()
                        Text("\(formatRate(viewModel.sequenceSamplesPerSecond)) / sec")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { viewModel.sequenceSamplesPerSecond },
                        set: { viewModel.setSequenceSamplesPerSecond($0) }
                    ), in: 1...30, step: 1)
                }

                if let message = viewModel.sequenceValidationMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if metadata.isHighFrameRateSource {
                    Text("Timing uses the imported presentation timeline; Slo-mo capture timing is not recovered yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        viewModel.startPoseTrackAnalysis()
                    } label: {
                        Label("Analyze Interval", systemImage: "figure.walk.motion")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAnalyzingPoseTrack)

                    if isAnalyzingPoseTrack {
                        Button("Cancel") {
                            viewModel.cancelPoseTrackAnalysis()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                poseTrackStatus
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private var poseTrackStatus: some View {
        switch viewModel.poseTrackAnalysisState {
        case .idle:
            EmptyView()

        case .analyzing(let progress):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.fractionCompleted)
                Text("Processed \(progress.processedSamples) of \(progress.totalSamples) samples")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .completed(let track):
            DisclosureGroup("Analysis Details") {
                poseTrackSummary(track)
            }
            cleanedTrackDiagnostics(track)
            poseTrackSampleReview(track)
            swingAnnotationContent(track)

        case .cancelled:
            Label("Sequence analysis cancelled.", systemImage: "stop.circle")
                .foregroundStyle(.secondary)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func poseTrackSummary(_ track: SwingPoseTrack) -> some View {
        let summary = track.summary

        return VStack(alignment: .leading, spacing: 4) {
            Text("Track Summary")
                .font(.headline)
            Text("Total samples: \(summary.totalSamples)")
            Text("With pose: \(summary.samplesWithPose), without pose: \(summary.samplesWithoutPose)")
            Text("Complete: \(summary.completeSamples), partial: \(summary.partialSamples), torso insufficient: \(summary.torsoInsufficientSamples)")
            Text("Average accepted joints: \(formatDecimal(summary.averageAcceptedJointCount))")
            Text("Processing: \(formatSeconds(summary.processingDurationSeconds))s total, \(formatSeconds(summary.averageProcessingTimePerSample))s/sample")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func cleanedTrackDiagnostics(_ track: SwingPoseTrack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Overlay", selection: Binding(
                get: { viewModel.poseTrackOverlayMode },
                set: { viewModel.poseTrackOverlayMode = $0 }
            )) {
                ForEach(SwingImportViewModel.PoseTrackOverlayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Joint", selection: Binding(
                get: { viewModel.selectedDiagnosticJoint },
                set: { viewModel.selectedDiagnosticJoint = $0 }
            )) {
                ForEach(BodyJoint.allCases, id: \.self) { joint in
                    Text(joint.displayName).tag(joint)
                }
            }
            .pickerStyle(.menu)

            DisclosureGroup("Coverage Details") {
                if let cleanedTrack = viewModel.cleanedPoseTrack,
                   let coverage = cleanedTrack.diagnostics.jointCoverage[viewModel.selectedDiagnosticJoint] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(viewModel.selectedDiagnosticJoint.displayName): observed \(coverage.observedSampleCount), interpolated \(coverage.interpolatedSampleCount), unavailable \(coverage.unavailableSampleCount)")
                        Text("Coverage: \(formatPercent(coverage.observedCoveragePercentage)) observed, \(formatPercent(coverage.effectiveCoveragePercentage)) effective")
                        Text("Longest unavailable gap: \(coverage.longestUnavailableGap) samples, rejected outliers: \(coverage.rejectedOutlierCount)")
                        Text("Total interpolated points: \(cleanedTrack.diagnostics.totalInterpolatedPointCount), rejected outliers: \(cleanedTrack.diagnostics.totalRejectedOutlierCount)")
                        Text("Cleaning: \(formatSeconds(cleanedTrack.processingDurationSeconds))s")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(PoseTrackDiagnosticGroup.allCases, id: \.self) { group in
                            if let groupCoverage = cleanedTrack.diagnostics.groupCoverage[group] {
                                GridRow {
                                    Text(group.displayName)
                                    Text(formatPercent(groupCoverage.effectiveCoveragePercentage))
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Cleaned diagnostics are generated after sequence analysis completes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func poseTrackSampleReview(_ track: SwingPoseTrack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !track.samples.isEmpty {
                let selectedIndex = viewModel.selectedPoseSampleIndex(in: track)

                HStack(spacing: 12) {
                    Button("Previous") {
                        viewModel.requestAdjacentPoseSampleSelection(offset: -1, in: track)
                    }
                    .disabled(selectedIndex == 0)

                    Spacer()

                    Text("Sample \(selectedIndex + 1) of \(track.samples.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Next") {
                        viewModel.requestAdjacentPoseSampleSelection(offset: 1, in: track)
                    }
                    .disabled(selectedIndex >= track.samples.count - 1)
                }

                sampleTimelineScrubber(track)
                .onAppear {
                    reviewSampleIndex = Double(selectedIndex)
                }
                .onChange(of: viewModel.selectedPoseSampleID) { _, _ in
                    reviewSampleIndex = Double(viewModel.selectedPoseSampleIndex(in: track))
                }

                Text("Drag to choose a sample, then release to load its frame.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                selectedPoseSampleContent(track: track)
            }
        }
    }

    private func sampleTimelineScrubber(_ track: SwingPoseTrack) -> some View {
        let previewIndex = min(max(Int(reviewSampleIndex.rounded()), 0), max(track.samples.count - 1, 0))
        let previewSample = track.samples[previewIndex]

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Timeline")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Sample \(previewIndex + 1) - \(formatSeconds(previewSample.actualTime))s")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            SampleTimelineScrubber(
                samples: track.samples,
                annotations: viewModel.annotations,
                currentIndex: $reviewSampleIndex
            ) { index in
                viewModel.requestPoseSampleSelection(at: index, in: track)
            }
            .frame(height: 64)

            HStack(spacing: 10) {
                ForEach(SwingPosition.allCases, id: \.self) { position in
                    Label(position.displayName, systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(annotationColor(position))
                }
            }
        }
    }

    @ViewBuilder
    private func selectedPoseSampleContent(track: SwingPoseTrack) -> some View {
        switch viewModel.selectedPoseSampleFrameState {
        case .idle:
            Text("Select a sample to review its frame and skeleton.")
                .font(.footnote)
                .foregroundStyle(.secondary)

        case .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading sample frame...")
                    .foregroundStyle(.secondary)
            }

        case .loaded(let sample, let frame):
            let cleanedSample = viewModel.selectedCleanedPoseSample(in: track)
            VStack(alignment: .leading, spacing: 8) {
                Text("Frame at \(formatSeconds(sample.actualTime))s")
                    .font(.headline)
                poseTrackFrameImage(frame, rawPose: sample.pose, cleanedSample: cleanedSample)
                DisclosureGroup("Selected Sample Details") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quality: \(sample.quality.category.rawValue)")
                        Text("Missing: \(formatJoints(sample.quality.missingJoints))")
                        selectedJointDetails(rawSample: sample, cleanedSample: cleanedSample)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func selectedJointDetails(rawSample: PoseSample, cleanedSample: CleanedPoseSample?) -> some View {
        let joint = viewModel.selectedDiagnosticJoint
        let rawPoint = rawSample.pose?.points[joint]
        let cleanedPoint = cleanedSample?.joints[joint]

        return VStack(alignment: .leading, spacing: 4) {
            Text("Selected joint: \(joint.displayName)")
            Text("Provenance: \(formatSource(cleanedPoint?.source))")
            Text("Raw: \(formatRawPoint(rawPoint, minimumConfidence: rawSample.pose?.minimumConfidence))")
            Text("Cleaned: \(formatTrackedPoint(cleanedPoint))")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func swingAnnotationContent(_ track: SwingPoseTrack) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manual Swing Annotation")
                .font(.headline)

            annotationContextControls

            VStack(alignment: .leading, spacing: 8) {
                Text("Current sample: \(viewModel.selectedPoseSampleIndex(in: track) + 1) of \(track.samples.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(SwingPosition.allCases, id: \.self) { position in
                    annotationRow(position, track: track)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Mark Current Sample")
                    .font(.subheadline)
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        annotationMarkButton(.address, track: track)
                        annotationMarkButton(.top, track: track)
                    }
                    GridRow {
                        annotationMarkButton(.impact, track: track)
                        annotationMarkButton(.finish, track: track)
                    }
                }
            }

            let validation = viewModel.annotationValidation
            Text(validation.message)
                .font(.footnote)
                .foregroundStyle(validation.canExport ? Color.secondary : Color.orange)

            if let message = viewModel.annotationMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(annotationMessageColor)
            }

            if viewModel.annotationExportState == .preparingFiles {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing matched video and JSON files...")
                        .font(.footnote)
                }
            }

            Button {
                Task {
                    await viewModel.exportAnnotation()
                }
            } label: {
                Label("Export Dataset Pair", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!validation.canExport || viewModel.annotationExportState == .preparingFiles)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var annotationContextControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Handedness", selection: Binding(
                get: { viewModel.annotationContext.golferHandedness },
                set: { viewModel.annotationContext.golferHandedness = $0 }
            )) {
                ForEach(GolferHandedness.allCases, id: \.self) { handedness in
                    Text(handedness.displayName).tag(handedness)
                }
            }

            Picker("Camera", selection: Binding(
                get: { viewModel.annotationContext.cameraView },
                set: { viewModel.annotationContext.cameraView = $0 }
            )) {
                ForEach(CameraView.allCases, id: \.self) { view in
                    Text(view.displayName).tag(view)
                }
            }

            Picker("Club", selection: Binding(
                get: { viewModel.annotationContext.golfClub },
                set: { viewModel.annotationContext.golfClub = $0 }
            )) {
                ForEach(GolfClub.allCases, id: \.self) { club in
                    Text(club.displayName).tag(club)
                }
            }

            TextField("Golfer nickname", text: Binding(
                get: { viewModel.annotationContext.golferIdentifier },
                set: { viewModel.annotationContext.golferIdentifier = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            Picker("Annotator role", selection: Binding(
                get: { viewModel.annotationContext.annotatorRole },
                set: { viewModel.annotationContext.annotatorRole = $0 }
            )) {
                ForEach(AnnotatorRole.allCases, id: \.self) { role in
                    Text(role.displayName).tag(role)
                }
            }

            TextField("Annotator identifier", text: Binding(
                get: { viewModel.annotationContext.annotatorIdentifier ?? "" },
                set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.annotationContext.annotatorIdentifier = trimmed.isEmpty ? nil : value
                }
            ))
            .textFieldStyle(.roundedBorder)

            TextField("Coach notes", text: Binding(
                get: { viewModel.annotationContext.coachNotes },
                set: { viewModel.annotationContext.coachNotes = $0 }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
        }
    }

    private func annotationRow(_ position: SwingPosition, track: SwingPoseTrack) -> some View {
        let annotation = viewModel.annotation(for: position)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(position.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(position.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(annotation.map { "\(formatSeconds($0.actualTimestamp))s - \($0.readiness.displayName)" } ?? "Not marked")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Jump") {
                    viewModel.jumpToAnnotation(position, in: track)
                }
                .disabled(annotation == nil)
                Button("Clear") {
                    viewModel.clearAnnotation(position)
                }
                .disabled(annotation == nil)
            }

            if let annotation {
                TextField("\(position.displayName) note", text: Binding(
                    get: { annotation.note ?? "" },
                    set: { viewModel.updateAnnotationNote($0, for: position) }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)

                DisclosureGroup("Pose Readiness Details") {
                    Text(annotationAvailabilitySummary(annotation.availability))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func annotationMarkButton(_ position: SwingPosition, track: SwingPoseTrack) -> some View {
        Button("Mark as \(position.displayName)") {
            viewModel.markSelectedSample(as: position, in: track)
        }
        .buttonStyle(.bordered)
    }

    private func annotationAvailabilitySummary(_ availability: PositionLandmarkAvailability) -> String {
        "Shoulders midpoint: \(formatBool(availability.shoulderMidpoint)), hips midpoint: \(formatBool(availability.hipMidpoint)), torso axis: \(formatBool(availability.torsoAxis)), one wrist: \(formatBool(availability.atLeastOneWrist)), both wrists: \(formatBool(availability.bothWrists)), wrist midpoint: \(formatBool(availability.wristMidpoint))"
    }

    private var annotationMessageColor: Color {
        if case .failed = viewModel.annotationExportState {
            return .red
        }
        return .secondary
    }

    private func poseTrackFrameImage(_ frame: SwingExtractedFrame, rawPose: DetectedPose?, cleanedSample: CleanedPoseSample?) -> some View {
        let imageSize = CGSize(width: frame.image.width, height: frame.image.height)

        return Image(decorative: frame.image, scale: 1)
            .resizable()
            .scaledToFit()
            .overlay {
                if viewModel.isPoseOverlayVisible {
                    switch viewModel.poseTrackOverlayMode {
                    case .raw:
                        if let rawPose {
                            PoseSkeletonOverlay(pose: rawPose, imageSize: imageSize)
                        }
                    case .cleaned:
                        if let cleanedSample {
                            CleanedPoseSkeletonOverlay(sample: cleanedSample, imageSize: imageSize)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.quaternary, lineWidth: 1)
            }
    }

    @ViewBuilder
    private var poseControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    Task { await viewModel.analyzePose() }
                } label: {
                    Label("Analyze Pose", systemImage: "figure.stand")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAnalyzingPose)

                Toggle("Overlay", isOn: Binding(
                    get: { viewModel.isPoseOverlayVisible },
                    set: { viewModel.isPoseOverlayVisible = $0 }
                ))
                .labelsHidden()
                .disabled(!hasPoseOverlay)
            }

            poseStatus
        }
    }

    @ViewBuilder
    private var poseStatus: some View {
        switch viewModel.poseAnalysisState {
        case .noExtractedFrame:
            EmptyView()

        case .ready:
            Text("Ready for pose analysis. Threshold: \(formatConfidence(viewModel.minimumPoseConfidence))")
                .font(.footnote)
                .foregroundStyle(.secondary)

        case .analyzing:
            HStack(spacing: 12) {
                ProgressView()
                Text("Analyzing pose...")
                    .foregroundStyle(.secondary)
            }

        case .detected(let pose):
            VStack(alignment: .leading, spacing: 4) {
                Text("Pose detected")
                    .font(.headline)
                Text("Accepted joints: \(pose.acceptedJointCount)")
                Text("Rejected or unavailable joints: \(pose.rejectedOrUnavailableJointCount)")
                Text("Confidence threshold: \(formatConfidence(pose.minimumConfidence))")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

        case .noPoseDetected:
            Label("No human pose detected in this frame.", systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private var isExtractingFrame: Bool {
        if case .extracting = viewModel.frameExtractionState {
            return true
        }
        return false
    }

    private var isAnalyzingPose: Bool {
        if case .analyzing = viewModel.poseAnalysisState {
            return true
        }
        return false
    }

    private var isAnalyzingPoseTrack: Bool {
        if case .analyzing = viewModel.poseTrackAnalysisState {
            return true
        }
        return false
    }

    private var hasPoseOverlay: Bool {
        if case .detected = viewModel.poseAnalysisState {
            return true
        }
        return false
    }

    private func formatSeconds(_ seconds: Double) -> String {
        seconds.formatted(.number.precision(.fractionLength(2)))
    }

    private func formatFrameRate(_ frameRate: Float) -> String {
        Double(frameRate).formatted(.number.precision(.fractionLength(0...2)))
    }

    private func formatConfidence(_ confidence: Double) -> String {
        confidence.formatted(.number.precision(.fractionLength(2)))
    }

    private func formatRate(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0)))
    }

    private func formatDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func formatPercent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    private func formatJoints(_ joints: [BodyJoint]) -> String {
        joints.isEmpty ? "None" : joints.map(\.displayName).joined(separator: ", ")
    }

    private func formatSource(_ source: JointPointSource?) -> String {
        switch source {
        case .observed: "observed"
        case .interpolated: "interpolated"
        case nil: "unavailable"
        }
    }

    private func formatRawPoint(_ point: PosePoint?, minimumConfidence: Double?) -> String {
        guard let point, let minimumConfidence, point.confidence >= minimumConfidence else { return "unavailable" }
        return "x \(formatCoordinate(point.x)), y \(formatCoordinate(point.y)), conf \(formatConfidence(point.confidence))"
    }

    private func formatTrackedPoint(_ point: TrackedJointPoint?) -> String {
        guard let point else { return "unavailable" }
        let confidence = point.confidence.map { ", conf \(formatConfidence($0))" } ?? ""
        return "x \(formatCoordinate(point.x)), y \(formatCoordinate(point.y))\(confidence)"
    }

    private func formatCoordinate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3)))
    }

    private func formatBool(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private func annotationColor(_ position: SwingPosition) -> Color {
        switch position {
        case .address: .green
        case .top: .blue
        case .impact: .orange
        case .finish: .purple
        }
    }
}

private struct SampleTimelineScrubber: View {
    let samples: [PoseSample]
    let annotations: [SwingPosition: SwingPositionAnnotation]
    @Binding var currentIndex: Double
    let onCommit: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let maxIndex = max(samples.count - 1, 0)
            let selectedIndex = min(max(Int(currentIndex.rounded()), 0), maxIndex)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))
                    .frame(height: 12)
                    .position(x: width / 2, y: 32)

                Capsule()
                    .fill(.blue.opacity(0.35))
                    .frame(width: xPosition(for: selectedIndex, width: width) + 6, height: 12)
                    .position(x: (xPosition(for: selectedIndex, width: width) + 6) / 2, y: 32)

                ForEach(tickIndices, id: \.self) { index in
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 1, height: index == selectedIndex ? 24 : 14)
                        .position(x: xPosition(for: index, width: width), y: 32)
                }

                ForEach(SwingPosition.allCases, id: \.self) { position in
                    if let annotation = annotations[position] {
                        VStack(spacing: 2) {
                            Circle()
                                .fill(color(for: position))
                                .frame(width: 10, height: 10)
                            Rectangle()
                                .fill(color(for: position))
                                .frame(width: 3, height: 28)
                        }
                        .position(x: xPosition(for: annotation.sampleIndex, width: width), y: 22)
                    }
                }

                Circle()
                    .fill(.white)
                    .frame(width: 28, height: 28)
                    .shadow(radius: 2)
                    .overlay {
                        Circle().stroke(.blue, lineWidth: 3)
                    }
                    .position(x: xPosition(for: selectedIndex, width: width), y: 32)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        currentIndex = Double(index(for: value.location.x, width: width))
                    }
                    .onEnded { value in
                        let index = index(for: value.location.x, width: width)
                        currentIndex = Double(index)
                        onCommit(index)
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample timeline")
        .accessibilityValue("Sample \(Int(currentIndex.rounded()) + 1) of \(samples.count)")
    }

    private var tickIndices: [Int] {
        guard samples.count > 1 else { return [0] }
        let step = max(samples.count / 32, 1)
        var indices = Array(stride(from: 0, through: samples.count - 1, by: step))
        if indices.last != samples.count - 1 {
            indices.append(samples.count - 1)
        }
        return indices
    }

    private func xPosition(for index: Int, width: Double) -> Double {
        guard samples.count > 1 else { return width / 2 }
        return Double(min(max(index, 0), samples.count - 1)) / Double(samples.count - 1) * width
    }

    private func index(for xPosition: Double, width: Double) -> Int {
        guard samples.count > 1 else { return 0 }
        let fraction = min(max(xPosition / width, 0), 1)
        return Int((fraction * Double(samples.count - 1)).rounded())
    }

    private func color(for position: SwingPosition) -> Color {
        switch position {
        case .address: .green
        case .top: .blue
        case .impact: .orange
        case .finish: .purple
        }
    }
}

private struct PoseSkeletonOverlay: View {
    let pose: DetectedPose
    let imageSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            let transform = PoseOverlayTransform(imageSize: imageSize, viewSize: proxy.size)
            let acceptedPoints = pose.acceptedPoints
            let connections = SwingPoseSkeleton.visibleConnections(for: pose)

            Canvas { context, _ in
                for connection in connections {
                    guard let start = pose.points[connection.start],
                          let end = pose.points[connection.end] else {
                        continue
                    }

                    var path = Path()
                    path.move(to: transform.viewPoint(for: start))
                    path.addLine(to: transform.viewPoint(for: end))
                    context.stroke(path, with: .color(.yellow), lineWidth: 3)
                }

                for point in acceptedPoints {
                    let center = transform.viewPoint(for: point)
                    let rect = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
                    context.fill(Path(ellipseIn: rect), with: .color(.red))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CleanedPoseSkeletonOverlay: View {
    let sample: CleanedPoseSample
    let imageSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            let transform = PoseOverlayTransform(imageSize: imageSize, viewSize: proxy.size)
            let connections = SwingPoseSkeleton.connections.filter { connection in
                sample.joints[connection.start] != nil && sample.joints[connection.end] != nil
            }

            Canvas { context, _ in
                for connection in connections {
                    guard let start = sample.joints[connection.start],
                          let end = sample.joints[connection.end] else {
                        continue
                    }

                    var path = Path()
                    path.move(to: transform.viewPoint(for: start.posePoint(joint: connection.start)))
                    path.addLine(to: transform.viewPoint(for: end.posePoint(joint: connection.end)))
                    let color: Color = start.source == .interpolated || end.source == .interpolated ? .cyan.opacity(0.75) : .yellow
                    context.stroke(path, with: .color(color), lineWidth: 3)
                }

                for (joint, point) in sample.joints {
                    let center = transform.viewPoint(for: point.posePoint(joint: joint))
                    let rect = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
                    if point.source == .interpolated {
                        context.stroke(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(.cyan), lineWidth: 2)
                    } else {
                        context.fill(Path(ellipseIn: rect), with: .color(.red))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private extension TrackedJointPoint {
    func posePoint(joint: BodyJoint) -> PosePoint {
        PosePoint(joint: joint, x: x, y: y, confidence: confidence ?? 1)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    SwingImportView()
}

private struct SwingVideoPlayer: View {
    let url: URL

    @State private var player: AVPlayer?
    @State private var aspectRatio = 16.0 / 9.0

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .task(id: url) {
                player = AVPlayer(url: url)
                aspectRatio = await loadAspectRatio(for: url) ?? aspectRatio
            }
            .onDisappear {
                player?.pause()
            }
    }

    private func loadAspectRatio(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await videoTrack.load(.naturalSize),
              let preferredTransform = try? await videoTrack.load(.preferredTransform) else {
            return nil
        }

        let transformedSize = naturalSize.applying(preferredTransform)
        let width = abs(transformedSize.width)
        let height = abs(transformedSize.height)

        guard width > 0, height > 0 else { return nil }
        return width / height
    }
}
