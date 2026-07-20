import AVFoundation
import CoreGraphics
import Foundation

protocol SwingVideoProcessing {
    func inspectVideo(at url: URL) async throws -> SwingVideoMetadata
    func extractFrame(at timestampSeconds: Double, from url: URL) async throws -> SwingExtractedFrame
}

struct AVFoundationSwingVideoProcessor: SwingVideoProcessing {
    enum VideoProcessingError: Error {
        case missingVideoTrack
        case invalidVideoDimensions
        case invalidDuration
    }

    func inspectVideo(at url: URL) async throws -> SwingVideoMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw VideoProcessingError.invalidDuration
        }

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoProcessingError.missingVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let orientedSize = try orientedDimensions(naturalSize: naturalSize, preferredTransform: preferredTransform)

        return SwingVideoMetadata(
            durationSeconds: durationSeconds,
            width: orientedSize.width,
            height: orientedSize.height,
            nominalFrameRate: nominalFrameRate,
            hasUsableVideoTrack: true
        )
    }

    func extractFrame(at timestampSeconds: Double, from url: URL) async throws -> SwingExtractedFrame {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // A narrow tolerance asks AVFoundation for a frame near the selected time without decoding the full video.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        let requestedTime = CMTime(seconds: timestampSeconds, preferredTimescale: 600)
        let result = try await generator.image(at: requestedTime)

        return SwingExtractedFrame(
            image: result.image,
            requestedTimestampSeconds: timestampSeconds,
            actualTimestampSeconds: CMTimeGetSeconds(result.actualTime)
        )
    }

    private func orientedDimensions(naturalSize: CGSize, preferredTransform: CGAffineTransform) throws -> (width: Int, height: Int) {
        let transformedSize = naturalSize.applying(preferredTransform)
        let width = abs(transformedSize.width)
        let height = abs(transformedSize.height)

        guard width > 0, height > 0 else {
            throw VideoProcessingError.invalidVideoDimensions
        }

        return (Int(width.rounded()), Int(height.rounded()))
    }
}
