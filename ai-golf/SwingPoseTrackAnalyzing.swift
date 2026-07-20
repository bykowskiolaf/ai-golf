import CoreGraphics
import Foundation

protocol SwingPoseTrackAnalyzing: Sendable {
    func analyze(
        videoURL: URL,
        timestamps: [Double],
        minimumConfidence: Double,
        progress: @MainActor @escaping (PoseTrackProgress) -> Void
    ) async throws -> SwingPoseTrack
}

struct SwingPoseTrackAnalyzer: SwingPoseTrackAnalyzing {
    let videoProcessor: SwingVideoProcessing
    let poseEstimator: PoseEstimating

    func analyze(
        videoURL: URL,
        timestamps: [Double],
        minimumConfidence: Double,
        progress: @MainActor @escaping (PoseTrackProgress) -> Void
    ) async throws -> SwingPoseTrack {
        let start = ContinuousClock.now
        var samples: [PoseSample] = []

        progress(PoseTrackProgress(processedSamples: 0, totalSamples: timestamps.count))

        for (index, timestamp) in timestamps.enumerated() {
            try Task.checkCancellation()

            do {
                let frame = try await videoProcessor.extractFrame(at: timestamp, from: videoURL)
                let pose = try await poseEstimator.detectPose(in: frame.image, minimumConfidence: minimumConfidence)
                samples.append(PoseSample(
                    id: UUID(),
                    requestedTime: timestamp,
                    actualTime: frame.actualTimestampSeconds,
                    pose: pose,
                    quality: PoseSampleQualityEvaluator.evaluate(pose: pose)
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                samples.append(PoseSample(
                    id: UUID(),
                    requestedTime: timestamp,
                    actualTime: timestamp,
                    pose: nil,
                    quality: PoseSampleQualityEvaluator.evaluate(pose: nil)
                ))
            }

            progress(PoseTrackProgress(processedSamples: index + 1, totalSamples: timestamps.count))
        }

        let duration = start.duration(to: .now)
        return SwingPoseTrack(samples: samples, processingDurationSeconds: Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
