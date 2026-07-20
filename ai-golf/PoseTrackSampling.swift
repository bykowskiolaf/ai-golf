import Foundation

struct PoseTrackSamplingRequest: Equatable, Sendable {
    let startTime: Double
    let endTime: Double
    let samplesPerSecond: Double
    let durationSeconds: Double
    let maximumSamples: Int
}

enum PoseTrackSamplingError: Equatable, Error {
    case invalidInterval
    case invalidSamplingRate
}

struct PoseTrackSamplingPlan: Equatable, Sendable {
    let timestamps: [Double]
    let effectiveSamplesPerSecond: Double
    let wasReducedToMaximum: Bool
}

enum PoseTrackSampler {
    static func makePlan(_ request: PoseTrackSamplingRequest) throws -> PoseTrackSamplingPlan {
        guard request.durationSeconds > 0,
              request.startTime >= 0,
              request.endTime <= request.durationSeconds,
              request.startTime < request.endTime else {
            throw PoseTrackSamplingError.invalidInterval
        }

        guard request.samplesPerSecond > 0, request.maximumSamples > 0 else {
            throw PoseTrackSamplingError.invalidSamplingRate
        }

        let interval = request.endTime - request.startTime
        let requestedCount = max(1, Int((interval * request.samplesPerSecond).rounded(.down)) + 1)
        let count = min(requestedCount, request.maximumSamples)
        let step = count == 1 ? 0 : interval / Double(count - 1)
        let timestamps = (0..<count).map { index in request.startTime + (Double(index) * step) }
        let effectiveRate = count == 1 ? 0 : Double(count - 1) / interval

        return PoseTrackSamplingPlan(
            timestamps: timestamps,
            effectiveSamplesPerSecond: effectiveRate,
            wasReducedToMaximum: requestedCount > request.maximumSamples
        )
    }
}
