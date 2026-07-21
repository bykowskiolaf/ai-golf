import Foundation

enum JointPointSource: Equatable, Sendable {
    case observed
    case interpolated
}

struct TrackedJointPoint: Equatable, Sendable {
    let x: Double
    let y: Double
    let confidence: Double?
    let source: JointPointSource
}

struct DerivedLandmarkPoint: Equatable, Sendable {
    let x: Double
    let y: Double
    let usesInterpolatedPoint: Bool
}

struct DerivedLandmarkVector: Equatable, Sendable {
    let dx: Double
    let dy: Double
    let length: Double
    let usesInterpolatedPoint: Bool
}

struct DerivedBodyLandmarks: Equatable, Sendable {
    let shoulderMidpoint: DerivedLandmarkPoint?
    let hipMidpoint: DerivedLandmarkPoint?
    let wristMidpoint: DerivedLandmarkPoint?
    let ankleMidpoint: DerivedLandmarkPoint?
    let torsoCenter: DerivedLandmarkPoint?
    let torsoAxis: DerivedLandmarkVector?
    let shoulderLine: DerivedLandmarkVector?
    let hipLine: DerivedLandmarkVector?
    let approximateTorsoLength: Double?
    let approximateShoulderWidth: Double?
}

struct CleanedPoseSample: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Double
    let joints: [BodyJoint: TrackedJointPoint]
    let landmarks: DerivedBodyLandmarks
}

struct JointCoverageDiagnostic: Equatable, Sendable {
    let observedSampleCount: Int
    let interpolatedSampleCount: Int
    let unavailableSampleCount: Int
    let observedCoveragePercentage: Double
    let effectiveCoveragePercentage: Double
    let longestUnavailableGap: Int
    let rejectedOutlierCount: Int
}

enum PoseTrackDiagnosticGroup: String, CaseIterable, Sendable {
    case torso
    case leftArm
    case rightArm
    case leftLeg
    case rightLeg
    case bothWrists
    case wristMidpoint

    var displayName: String {
        switch self {
        case .torso: "Torso"
        case .leftArm: "Left Arm"
        case .rightArm: "Right Arm"
        case .leftLeg: "Left Leg"
        case .rightLeg: "Right Leg"
        case .bothWrists: "Both Wrists"
        case .wristMidpoint: "Wrist Midpoint"
        }
    }
}

struct PoseTrackGroupCoverageDiagnostic: Equatable, Sendable {
    let availableSampleCount: Int
    let effectiveCoveragePercentage: Double
}

struct PoseTrackDiagnostics: Equatable, Sendable {
    let jointCoverage: [BodyJoint: JointCoverageDiagnostic]
    let groupCoverage: [PoseTrackDiagnosticGroup: PoseTrackGroupCoverageDiagnostic]
    let totalRejectedOutlierCount: Int
    let totalInterpolatedPointCount: Int
}

struct CleanedPoseTrack: Equatable, Sendable {
    let samples: [CleanedPoseSample]
    let diagnostics: PoseTrackDiagnostics
    let processingDurationSeconds: Double
}

struct PoseTrackCleaningConfiguration: Equatable, Sendable {
    static let smoothingWindowSize = 3

    var outlierDistanceScaleThreshold = 1.75
    var outlierNeighborDistanceScaleThreshold = 2.5
    var maximumInterpolatedGapSamples = 2
    var smoothingNeighborWeight = 0.25
    var fallbackBodyScale = 0.25

    var smoothingCenterWeight: Double {
        1 - (2 * min(max(smoothingNeighborWeight, 0), 0.45))
    }
}

enum PoseTrackCleaner {
    // Pipeline order is intentionally conservative: keep accepted raw observations first,
    // remove only locally implausible spikes, fill only short bounded gaps, then smooth
    // continuous segments before deriving landmarks and coverage diagnostics.
    static func clean(
        track: SwingPoseTrack,
        configuration: PoseTrackCleaningConfiguration = PoseTrackCleaningConfiguration()
    ) -> CleanedPoseTrack {
        let start = ContinuousClock.now
        let observations = rawJointObservations(from: track)
        let bodyScale = medianBodyScale(from: observations, fallback: configuration.fallbackBodyScale)
        let outlierResult = rejectOutliers(
            observations: observations,
            timestamps: track.samples.map(\.actualTime),
            bodyScale: bodyScale,
            configuration: configuration
        )
        let interpolated = interpolateShortGaps(
            observations: outlierResult.observations,
            timestamps: track.samples.map(\.actualTime),
            maximumGapSamples: configuration.maximumInterpolatedGapSamples
        )
        let smoothed = smooth(
            observations: interpolated,
            timestamps: track.samples.map(\.actualTime),
            neighborWeight: configuration.smoothingNeighborWeight
        )
        let samples = makeSamples(from: track, observations: smoothed)
        let diagnostics = makeDiagnostics(
            observations: smoothed,
            rejectedOutlierCounts: outlierResult.rejectedCounts,
            landmarks: samples.map(\.landmarks)
        )

        return CleanedPoseTrack(
            samples: samples,
            diagnostics: diagnostics,
            processingDurationSeconds: start.duration(to: ContinuousClock.now).seconds
        )
    }

    static func rawJointObservations(from track: SwingPoseTrack) -> [[BodyJoint: TrackedJointPoint]] {
        track.samples.map { sample in
            guard let pose = sample.pose else { return [:] }

            return Dictionary(uniqueKeysWithValues: pose.acceptedPoints.map { point in
                (point.joint, TrackedJointPoint(x: point.x, y: point.y, confidence: point.confidence, source: .observed))
            })
        }
    }

    static func rejectOutliers(
        observations: [[BodyJoint: TrackedJointPoint]],
        timestamps: [Double],
        bodyScale: Double,
        configuration: PoseTrackCleaningConfiguration = PoseTrackCleaningConfiguration()
    ) -> (observations: [[BodyJoint: TrackedJointPoint]], rejectedCounts: [BodyJoint: Int]) {
        var cleaned = observations
        var rejectedCounts = Dictionary(uniqueKeysWithValues: BodyJoint.allCases.map { ($0, 0) })
        guard observations.count >= 3, bodyScale > 0, timestamps.count == observations.count else {
            return (cleaned, rejectedCounts)
        }

        for joint in BodyJoint.allCases {
            for index in 1..<(observations.count - 1) {
                guard let current = observations[index][joint],
                      let previousIndex = nearestObservedIndex(before: index, joint: joint, observations: observations),
                      let nextIndex = nearestObservedIndex(after: index, joint: joint, observations: observations) else {
                    continue
                }

                let previous = observations[previousIndex][joint]!
                let next = observations[nextIndex][joint]!
                let span = timestamps[nextIndex] - timestamps[previousIndex]
                guard span > 0, timestamps[index] > timestamps[previousIndex], timestamps[index] < timestamps[nextIndex] else { continue }

                let fraction = (timestamps[index] - timestamps[previousIndex]) / span
                let expectedX = previous.x + (next.x - previous.x) * fraction
                let expectedY = previous.y + (next.y - previous.y) * fraction
                let expectedDistance = distance(current.x, current.y, expectedX, expectedY)
                let neighborDistance = distance(previous.x, previous.y, next.x, next.y)

                guard neighborDistance <= configuration.outlierNeighborDistanceScaleThreshold * bodyScale else { continue }
                if expectedDistance > configuration.outlierDistanceScaleThreshold * bodyScale {
                    cleaned[index][joint] = nil
                    rejectedCounts[joint, default: 0] += 1
                }
            }
        }

        return (cleaned, rejectedCounts)
    }

    static func interpolateShortGaps(
        observations: [[BodyJoint: TrackedJointPoint]],
        timestamps: [Double],
        maximumGapSamples: Int = 2
    ) -> [[BodyJoint: TrackedJointPoint]] {
        var interpolated = observations
        guard maximumGapSamples > 0, observations.count >= 3, timestamps.count == observations.count else { return interpolated }

        for joint in BodyJoint.allCases {
            var index = 0
            while index < observations.count {
                if observations[index][joint] != nil {
                    index += 1
                    continue
                }

                let gapStart = index
                while index < observations.count, observations[index][joint] == nil {
                    index += 1
                }
                let gapEnd = index - 1
                let gapLength = gapEnd - gapStart + 1
                let beforeIndex = gapStart - 1
                let afterIndex = index

                guard gapLength <= maximumGapSamples,
                      beforeIndex >= 0,
                      afterIndex < observations.count,
                      let before = observations[beforeIndex][joint],
                      let after = observations[afterIndex][joint] else {
                    continue
                }

                let span = timestamps[afterIndex] - timestamps[beforeIndex]
                guard span > 0 else { continue }

                for missingIndex in gapStart...gapEnd {
                    let fraction = (timestamps[missingIndex] - timestamps[beforeIndex]) / span
                    guard fraction > 0, fraction < 1 else { continue }
                    let x = before.x + (after.x - before.x) * fraction
                    let y = before.y + (after.y - before.y) * fraction
                    guard (0...1).contains(x), (0...1).contains(y) else { continue }
                    interpolated[missingIndex][joint] = TrackedJointPoint(x: x, y: y, confidence: nil, source: .interpolated)
                }
            }
        }

        return interpolated
    }

    static func smooth(
        observations: [[BodyJoint: TrackedJointPoint]],
        timestamps: [Double],
        neighborWeight: Double = 0.25
    ) -> [[BodyJoint: TrackedJointPoint]] {
        guard observations.count >= 3, timestamps.count == observations.count else { return observations }
        let clampedNeighborWeight = min(max(neighborWeight, 0), 0.45)
        let centerWeight = 1 - (2 * clampedNeighborWeight)
        var smoothed = observations

        for joint in BodyJoint.allCases {
            for index in 1..<(observations.count - 1) {
                guard let previous = observations[index - 1][joint],
                      let current = observations[index][joint],
                      let next = observations[index + 1][joint],
                      timestamps[index - 1] < timestamps[index],
                      timestamps[index] < timestamps[index + 1] else {
                    continue
                }

                let x = previous.x * clampedNeighborWeight + current.x * centerWeight + next.x * clampedNeighborWeight
                let y = previous.y * clampedNeighborWeight + current.y * centerWeight + next.y * clampedNeighborWeight
                smoothed[index][joint] = TrackedJointPoint(x: x, y: y, confidence: current.confidence, source: current.source)
            }
        }

        return smoothed
    }

    static func deriveLandmarks(from joints: [BodyJoint: TrackedJointPoint]) -> DerivedBodyLandmarks {
        let shoulderMidpoint = midpoint(.leftShoulder, .rightShoulder, joints: joints)
        let hipMidpoint = midpoint(.leftHip, .rightHip, joints: joints)
        let wristMidpoint = midpoint(.leftWrist, .rightWrist, joints: joints)
        let ankleMidpoint = midpoint(.leftAnkle, .rightAnkle, joints: joints)
        let torsoCenter = pointBetween(shoulderMidpoint, hipMidpoint)
        let torsoAxis = vector(from: hipMidpoint, to: shoulderMidpoint)
        let shoulderLine = vector(.leftShoulder, .rightShoulder, joints: joints)
        let hipLine = vector(.leftHip, .rightHip, joints: joints)

        return DerivedBodyLandmarks(
            shoulderMidpoint: shoulderMidpoint,
            hipMidpoint: hipMidpoint,
            wristMidpoint: wristMidpoint,
            ankleMidpoint: ankleMidpoint,
            torsoCenter: torsoCenter,
            torsoAxis: torsoAxis,
            shoulderLine: shoulderLine,
            hipLine: hipLine,
            approximateTorsoLength: torsoAxis?.length,
            approximateShoulderWidth: shoulderLine?.length
        )
    }

    private static func makeSamples(from track: SwingPoseTrack, observations: [[BodyJoint: TrackedJointPoint]]) -> [CleanedPoseSample] {
        zip(track.samples, observations).map { sample, joints in
            CleanedPoseSample(
                id: sample.id,
                timestamp: sample.actualTime,
                joints: joints,
                landmarks: deriveLandmarks(from: joints)
            )
        }
    }

    private static func makeDiagnostics(
        observations: [[BodyJoint: TrackedJointPoint]],
        rejectedOutlierCounts: [BodyJoint: Int],
        landmarks: [DerivedBodyLandmarks]
    ) -> PoseTrackDiagnostics {
        let totalSamples = observations.count
        let jointCoverage = Dictionary(uniqueKeysWithValues: BodyJoint.allCases.map { joint in
            var observed = 0
            var interpolated = 0
            var longestGap = 0
            var currentGap = 0

            for sample in observations {
                switch sample[joint]?.source {
                case .observed:
                    observed += 1
                    longestGap = max(longestGap, currentGap)
                    currentGap = 0
                case .interpolated:
                    interpolated += 1
                    longestGap = max(longestGap, currentGap)
                    currentGap = 0
                case nil:
                    currentGap += 1
                }
            }
            longestGap = max(longestGap, currentGap)

            let unavailable = totalSamples - observed - interpolated
            return (joint, JointCoverageDiagnostic(
                observedSampleCount: observed,
                interpolatedSampleCount: interpolated,
                unavailableSampleCount: unavailable,
                observedCoveragePercentage: percentage(observed, totalSamples),
                effectiveCoveragePercentage: percentage(observed + interpolated, totalSamples),
                longestUnavailableGap: longestGap,
                rejectedOutlierCount: rejectedOutlierCounts[joint, default: 0]
            ))
        })

        let groupCoverage = Dictionary(uniqueKeysWithValues: PoseTrackDiagnosticGroup.allCases.map { group in
            let availableCount = observations.indices.filter { index in
                isGroupAvailable(group, observations: observations[index], landmarks: landmarks[index])
            }.count
            return (group, PoseTrackGroupCoverageDiagnostic(
                availableSampleCount: availableCount,
                effectiveCoveragePercentage: percentage(availableCount, totalSamples)
            ))
        })

        return PoseTrackDiagnostics(
            jointCoverage: jointCoverage,
            groupCoverage: groupCoverage,
            totalRejectedOutlierCount: rejectedOutlierCounts.values.reduce(0, +),
            totalInterpolatedPointCount: jointCoverage.values.map(\.interpolatedSampleCount).reduce(0, +)
        )
    }

    private static func medianBodyScale(from observations: [[BodyJoint: TrackedJointPoint]], fallback: Double) -> Double {
        let scales = observations.flatMap { sample -> [Double] in
            [
                vector(.neck, .root, joints: sample)?.length,
                vector(.leftShoulder, .rightShoulder, joints: sample)?.length,
                vector(.leftHip, .rightHip, joints: sample)?.length
            ].compactMap { $0 }.filter { $0 > 0 }
        }.sorted()

        guard !scales.isEmpty else { return fallback }
        return scales[scales.count / 2]
    }

    private static func nearestObservedIndex(before index: Int, joint: BodyJoint, observations: [[BodyJoint: TrackedJointPoint]]) -> Int? {
        guard index > 0 else { return nil }
        return stride(from: index - 1, through: 0, by: -1).first { observations[$0][joint] != nil }
    }

    private static func nearestObservedIndex(after index: Int, joint: BodyJoint, observations: [[BodyJoint: TrackedJointPoint]]) -> Int? {
        guard index + 1 < observations.count else { return nil }
        return ((index + 1)..<observations.count).first { observations[$0][joint] != nil }
    }

    private static func midpoint(_ first: BodyJoint, _ second: BodyJoint, joints: [BodyJoint: TrackedJointPoint]) -> DerivedLandmarkPoint? {
        guard let first = joints[first], let second = joints[second] else { return nil }
        return DerivedLandmarkPoint(
            x: (first.x + second.x) / 2,
            y: (first.y + second.y) / 2,
            usesInterpolatedPoint: first.source == .interpolated || second.source == .interpolated
        )
    }

    private static func pointBetween(_ first: DerivedLandmarkPoint?, _ second: DerivedLandmarkPoint?) -> DerivedLandmarkPoint? {
        guard let first, let second else { return nil }
        return DerivedLandmarkPoint(
            x: (first.x + second.x) / 2,
            y: (first.y + second.y) / 2,
            usesInterpolatedPoint: first.usesInterpolatedPoint || second.usesInterpolatedPoint
        )
    }

    private static func vector(_ first: BodyJoint, _ second: BodyJoint, joints: [BodyJoint: TrackedJointPoint]) -> DerivedLandmarkVector? {
        guard let first = joints[first], let second = joints[second] else { return nil }
        let usesInterpolatedPoint = first.source == .interpolated || second.source == .interpolated
        return vector(
            from: DerivedLandmarkPoint(x: first.x, y: first.y, usesInterpolatedPoint: usesInterpolatedPoint),
            to: DerivedLandmarkPoint(x: second.x, y: second.y, usesInterpolatedPoint: usesInterpolatedPoint)
        )
    }

    private static func vector(from first: DerivedLandmarkPoint?, to second: DerivedLandmarkPoint?) -> DerivedLandmarkVector? {
        guard let first, let second else { return nil }
        let dx = second.x - first.x
        let dy = second.y - first.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > .ulpOfOne else { return nil }
        return DerivedLandmarkVector(
            dx: dx,
            dy: dy,
            length: length,
            usesInterpolatedPoint: first.usesInterpolatedPoint || second.usesInterpolatedPoint
        )
    }

    private static func isGroupAvailable(
        _ group: PoseTrackDiagnosticGroup,
        observations: [BodyJoint: TrackedJointPoint],
        landmarks: DerivedBodyLandmarks
    ) -> Bool {
        switch group {
        case .torso:
            [.neck, .root, .leftShoulder, .rightShoulder, .leftHip, .rightHip].allSatisfy { observations[$0] != nil }
        case .leftArm:
            [.leftShoulder, .leftElbow, .leftWrist].allSatisfy { observations[$0] != nil }
        case .rightArm:
            [.rightShoulder, .rightElbow, .rightWrist].allSatisfy { observations[$0] != nil }
        case .leftLeg:
            [.leftHip, .leftKnee, .leftAnkle].allSatisfy { observations[$0] != nil }
        case .rightLeg:
            [.rightHip, .rightKnee, .rightAnkle].allSatisfy { observations[$0] != nil }
        case .bothWrists:
            observations[.leftWrist] != nil && observations[.rightWrist] != nil
        case .wristMidpoint:
            landmarks.wristMidpoint != nil
        }
    }

    private static func distance(_ firstX: Double, _ firstY: Double, _ secondX: Double, _ secondY: Double) -> Double {
        let dx = secondX - firstX
        let dy = secondY - firstY
        return sqrt(dx * dx + dy * dy)
    }

    private static func percentage(_ count: Int, _ total: Int) -> Double {
        total == 0 ? 0 : Double(count) / Double(total) * 100
    }
}

private extension Duration {
    var seconds: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
