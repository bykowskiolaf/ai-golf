import AVKit
import PhotosUI
import SwiftUI

struct SwingImportView: View {
    @State private var viewModel = SwingImportViewModel()
    @State private var selectedItem: PhotosPickerItem?

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
                SwingVideoPlayer(url: swing.localVideoURL)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.quaternary, lineWidth: 1)
                    }

                metadataContent
                poseTrackAnalysisContent
                frameExtractionControls
                extractedFrameContent
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
            poseTrackSummary(track)
            poseTrackSampleSelector(track)

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

    private func poseTrackSampleSelector(_ track: SwingPoseTrack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !track.samples.isEmpty {
                Picker("Sample", selection: Binding(
                    get: { viewModel.selectedPoseSampleID ?? track.samples[0].id },
                    set: { sampleID in
                        if let sample = track.samples.first(where: { $0.id == sampleID }) {
                            Task { await viewModel.selectPoseSample(sample) }
                        }
                    }
                )) {
                    ForEach(track.samples) { sample in
                        Text("\(formatSeconds(sample.actualTime))s - \(sample.quality.category.rawValue)")
                            .tag(sample.id)
                    }
                }
                .pickerStyle(.menu)

                selectedPoseSampleContent
            }
        }
    }

    @ViewBuilder
    private var selectedPoseSampleContent: some View {
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Sample at \(formatSeconds(sample.actualTime))s")
                    .font(.headline)
                Text("Quality: \(sample.quality.category.rawValue)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Missing: \(formatJoints(sample.quality.missingJoints))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                poseFrameImage(frame, pose: sample.pose)
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
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

    private func formatJoints(_ joints: [BodyJoint]) -> String {
        joints.isEmpty ? "None" : joints.map(\.displayName).joined(separator: ", ")
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
