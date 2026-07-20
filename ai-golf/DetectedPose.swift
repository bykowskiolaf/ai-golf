import Foundation

struct PosePoint: Equatable, Sendable {
    let joint: BodyJoint
    let x: Double
    let y: Double
    let confidence: Double
}

struct DetectedPose: Equatable, Sendable {
    let points: [BodyJoint: PosePoint]
    let minimumConfidence: Double

    var acceptedPoints: [PosePoint] {
        points.values
            .filter { $0.confidence >= minimumConfidence }
            .sorted { $0.joint.rawValue < $1.joint.rawValue }
    }

    var acceptedJointCount: Int {
        acceptedPoints.count
    }

    var rejectedOrUnavailableJointCount: Int {
        BodyJoint.allCases.count - acceptedJointCount
    }
}
