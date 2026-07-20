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
            SwingVideoPlayer(url: swing.localVideoURL)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.quaternary, lineWidth: 1)
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
