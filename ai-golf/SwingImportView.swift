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
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.quaternary, lineWidth: 1)
                    }
                Text("Requested \(formatSeconds(frame.requestedTimestampSeconds))s, received \(formatSeconds(frame.actualTimestampSeconds))s")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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

    private func formatSeconds(_ seconds: Double) -> String {
        seconds.formatted(.number.precision(.fractionLength(2)))
    }

    private func formatFrameRate(_ frameRate: Float) -> String {
        Double(frameRate).formatted(.number.precision(.fractionLength(0...2)))
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
