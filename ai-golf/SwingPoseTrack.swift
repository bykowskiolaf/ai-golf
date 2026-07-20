import Foundation

enum PoseSampleQualityCategory: String, Sendable {
    case complete
    case partial
    case torsoInsufficient
    case noPose
}

struct PoseSampleQuality: Equatable, Sendable {
    let category: PoseSampleQualityCategory
    let acceptedJointCount: Int
    let missingJoints: [BodyJoint]
    let hasSufficientTorso: Bool
    let hasSufficientBothArms: Bool
    let hasSufficientBothLegs: Bool
}

struct PoseSample: Identifiable, Equatable, Sendable {
    let id: UUID
    let requestedTime: Double
    let actualTime: Double
    let pose: DetectedPose?
    let quality: PoseSampleQuality
}

struct SwingPoseTrack: Equatable, Sendable {
    let samples: [PoseSample]
    let processingDurationSeconds: Double

    var summary: SwingPoseTrackSummary {
        SwingPoseTrackSummary(track: self)
    }
}

struct SwingPoseTrackSummary: Equatable, Sendable {
    let totalSamples: Int
    let samplesWithPose: Int
    let samplesWithoutPose: Int
    let completeSamples: Int
    let partialSamples: Int
    let torsoInsufficientSamples: Int
    let averageAcceptedJointCount: Double
    let processingDurationSeconds: Double
    let averageProcessingTimePerSample: Double

    init(track: SwingPoseTrack) {
        totalSamples = track.samples.count
        samplesWithPose = track.samples.filter { $0.pose != nil }.count
        samplesWithoutPose = totalSamples - samplesWithPose
        completeSamples = track.samples.filter { $0.quality.category == .complete }.count
        partialSamples = track.samples.filter { $0.quality.category == .partial }.count
        torsoInsufficientSamples = track.samples.filter { $0.quality.category == .torsoInsufficient }.count
        averageAcceptedJointCount = totalSamples == 0 ? 0 : Double(track.samples.map(\.quality.acceptedJointCount).reduce(0, +)) / Double(totalSamples)
        processingDurationSeconds = track.processingDurationSeconds
        averageProcessingTimePerSample = totalSamples == 0 ? 0 : track.processingDurationSeconds / Double(totalSamples)
    }
}

struct PoseTrackProgress: Equatable, Sendable {
    let processedSamples: Int
    let totalSamples: Int

    var fractionCompleted: Double {
        totalSamples == 0 ? 0 : Double(processedSamples) / Double(totalSamples)
    }
}
