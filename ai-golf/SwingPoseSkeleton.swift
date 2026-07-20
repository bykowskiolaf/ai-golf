import Foundation

struct SkeletonConnection: Equatable, Sendable {
    let start: BodyJoint
    let end: BodyJoint
}

enum SwingPoseSkeleton {
    static let connections: [SkeletonConnection] = [
        SkeletonConnection(start: .leftEar, end: .leftEye),
        SkeletonConnection(start: .leftEye, end: .nose),
        SkeletonConnection(start: .nose, end: .rightEye),
        SkeletonConnection(start: .rightEye, end: .rightEar),
        SkeletonConnection(start: .neck, end: .leftShoulder),
        SkeletonConnection(start: .neck, end: .rightShoulder),
        SkeletonConnection(start: .leftShoulder, end: .rightShoulder),
        SkeletonConnection(start: .leftShoulder, end: .leftElbow),
        SkeletonConnection(start: .leftElbow, end: .leftWrist),
        SkeletonConnection(start: .rightShoulder, end: .rightElbow),
        SkeletonConnection(start: .rightElbow, end: .rightWrist),
        SkeletonConnection(start: .leftShoulder, end: .leftHip),
        SkeletonConnection(start: .rightShoulder, end: .rightHip),
        SkeletonConnection(start: .root, end: .leftHip),
        SkeletonConnection(start: .root, end: .rightHip),
        SkeletonConnection(start: .leftHip, end: .rightHip),
        SkeletonConnection(start: .leftHip, end: .leftKnee),
        SkeletonConnection(start: .leftKnee, end: .leftAnkle),
        SkeletonConnection(start: .rightHip, end: .rightKnee),
        SkeletonConnection(start: .rightKnee, end: .rightAnkle)
    ]

    static func visibleConnections(for pose: DetectedPose) -> [SkeletonConnection] {
        connections.filter { connection in
            guard let start = pose.points[connection.start],
                  let end = pose.points[connection.end] else {
                return false
            }

            return start.confidence >= pose.minimumConfidence && end.confidence >= pose.minimumConfidence
        }
    }
}
